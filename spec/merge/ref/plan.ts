/**
 * Commit planner (docs/m3/merge-spec.md, section 7). Runs after every pull, including each 422 retry,
 * on the new base. Produces the tree entries for one atomic commit and the Needs attention list.
 */
import { mergeFile, type MergeResult } from "./merge.ts";
import { checkPath, freePath, PathIndex, type PathBlock } from "./paths.ts";

export type Op =
  | { kind: "edit"; path: string; content: string }
  | { kind: "create"; path: string; content: string }
  | { kind: "delete"; path: string };

export type Entry = { path: string; content: string } | { path: string; delete: true };

export type AttentionReason =
  | "conflict-copy"
  | "delete-skipped"
  | "case-clash"
  | `blocked:${PathBlock}`;

export interface Attention {
  path: string;
  reason: AttentionReason;
  copy?: string;
  detail?: string;
}

export interface PlanInput {
  /** Files at the journal base (the commit the ops were made on). */
  baseTree: Record<string, string>;
  /** Files at the current head of main (after the pull). */
  theirsTree: Record<string, string>;
  ops: Op[];
  /** Renames reported by compare (`previous_filename` -> `filename`); used before the exact-content check. */
  renames?: Record<string, string>;
  device: string;
  /** Op creation time, exact UTC string ending in Z (same string as the commit date, spec 7.5). */
  time: string;
}

export interface PlanOutput {
  entries: Entry[];
  attention: Attention[];
  /** Ops that stay in the outbox (blocked); everything else is done once the commit lands. */
  kept: number[];
  /** Ops that needed nothing (already true on GitHub). */
  noops: number[];
}

export function copyHeader(original: string, device: string, time: string): string {
  return `---\ntype: conflict\nconflict_of: ${yamlStr(original)}\ndevice: ${yamlStr(device)}\ncreated: ${yamlStr(time)}\n---\n`;
}

/** JSON-style double-quoted string; valid YAML. Escapes \\, ", and C0 controls. */
export function yamlStr(s: string): string {
  return JSON.stringify(s);
}

export function copyStamp(time: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/.exec(time);
  if (!m) throw new Error("time must be UTC ISO 8601 ending in Z");
  return `${m[1]}${m[2]}${m[3]}-${m[4]}${m[5]}${m[6]}`;
}

export function planCommit(input: PlanInput): PlanOutput {
  const { baseTree, theirsTree, device, time } = input;
  const has = (t: Record<string, string>, p: string) => Object.prototype.hasOwnProperty.call(t, p);
  const index = new PathIndex(Object.keys(theirsTree));
  const writes = new Map<string, Entry>();
  const attention: Attention[] = [];
  const kept: number[] = [];
  const noops: number[] = [];
  const stamp = copyStamp(time);

  // Remote renames: a base path missing in theirs whose exact content sits at exactly one new path.
  const renamed = (p: string): string | null => {
    if (!has(baseTree, p) || has(theirsTree, p)) return null;
    const r = input.renames?.[p];
    if (r !== undefined && has(theirsTree, r)) return r;
    const hits = Object.keys(theirsTree).filter((q) => !has(baseTree, q) && theirsTree[q] === baseTree[p]);
    return hits.length === 1 ? hits[0]! : null;
  };
  const write = (path: string, content: string) => {
    writes.set(path, { path, content });
    index.add(path);
  };
  const addCopy = (original: string, mine: string) => {
    const slug = original.normalize("NFC").replace(/\.md$/i, "").replace(/\//g, "-");
    const p = freePath(`_inbox/conflict-${slug}-${stamp}.md`, index);
    write(p, copyHeader(original, device, time) + mine);
    return p;
  };
  const apply = (target: string, r: MergeResult, i: number) => {
    const cur = has(theirsTree, target) ? theirsTree[target]! : null;
    if (r.content !== null && r.content !== cur) write(target, r.content);
    if (r.content === null && cur !== null) writes.set(target, { path: target, delete: true });
    if (r.copy !== null) attention.push({ path: target, reason: "conflict-copy", copy: addCopy(target, r.copy), detail: r.reason });
    if (r.kind === "delete-skipped") attention.push({ path: target, reason: "delete-skipped" });
    if (r.content === cur && r.copy === null && r.kind !== "delete-skipped") noops.push(i);
  };

  input.ops.forEach((op, i) => {
    if (op.kind === "create") {
      const path = op.path.normalize("NFC");
      const block = checkPath(path, op.content);
      if (block) return void (attention.push({ path, reason: `blocked:${block}` }), kept.push(i));
      const clash = index.clash(path);
      if (clash) return void (attention.push({ path, reason: "case-clash", detail: clash }), kept.push(i));
      const cur = has(theirsTree, path) ? theirsTree[path]! : writes.get(path) && "content" in writes.get(path)! ? (writes.get(path) as { content: string }).content : null;
      return apply(path, mergeFile(null, op.content, cur), i);
    }
    // edit and delete act on an existing repo path: keep its exact bytes, follow a remote rename.
    const target = renamed(op.path) ?? op.path;
    const block = checkPath(target, op.kind === "edit" ? op.content : null);
    if (block) return void (attention.push({ path: target, reason: `blocked:${block}` }), kept.push(i));
    const base = has(baseTree, op.path) ? baseTree[op.path]! : null;
    const theirs = has(theirsTree, target) ? theirsTree[target]! : null;
    if (op.kind === "edit") return apply(target, mergeFile(base, op.content, theirs), i);
    // Delete (spec 7.3): re-checked against the new base on every retry.
    if (theirs === null) return void noops.push(i); // already gone: never send sha null for a missing path
    if (theirs !== base) return void attention.push({ path: target, reason: "delete-skipped" });
    writes.set(target, { path: target, delete: true });
    const trash = `_trash/${target}`;
    if (!(has(theirsTree, trash) && theirsTree[trash] === theirs)) write(freePath(trash, index), theirs);
  });

  // Final guard (spec 7.6): deletes only for paths present on the new base; no two writes clash by case.
  const entries = [...writes.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  for (const e of entries) if ("delete" in e && !has(theirsTree, e.path)) throw new Error(`plan bug: delete of missing ${e.path}`);
  const keys = new Set<string>();
  for (const e of entries) {
    const k = e.path.normalize("NFC").toLowerCase();
    if (keys.has(k)) throw new Error(`plan bug: case clash ${e.path}`);
    keys.add(k);
  }
  return { entries, attention, kept, noops };
}
