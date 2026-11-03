/**
 * Commit planner (docs/m3/merge-spec.md, section 7). Runs after every pull, including each 422 retry,
 * on the new base. Produces the tree entries for one atomic commit and the Needs attention list.
 */
import { mergeFile, type MergeResult } from "./merge.ts";
import { checkPath, foldKey, freePath, MAX_NOTE_BYTES, PathIndex, type PathBlock } from "./paths.ts";

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

/**
 * Outbox coalescing (spec 7.1): ops on one path become one op, at the place of the first, in order.
 * The path existed at base if the first op is an edit or delete; it exists afterwards unless the last
 * op is a delete. So edit+edit = edit (last text), delete+create = edit, create+delete = nothing.
 */
export function coalesce(ops: Op[], baseTree: Record<string, string>): { op: Op | null; idx: number[] }[] {
  const groups: { first: Op; last: Op; idx: number[] }[] = [];
  const byPath = new Map<string, (typeof groups)[number]>();
  ops.forEach((op, i) => {
    const key = Object.prototype.hasOwnProperty.call(baseTree, op.path) ? op.path : op.path.normalize("NFC");
    let g = byPath.get(key);
    if (!g) groups.push((g = { first: op, last: op, idx: [] })), byPath.set(key, g);
    g.last = op;
    g.idx.push(i);
  });
  return groups.map(({ first, last, idx }) => {
    const path = first.path;
    const existed = first.kind !== "create";
    if (last.kind === "delete") return { op: existed ? { kind: "delete", path } : null, idx };
    // An edit of a path the old base does not have is a new note: it gets a create's checks (spec 7.1).
    const edit = existed && Object.prototype.hasOwnProperty.call(baseTree, path);
    return { op: { kind: edit ? "edit" : "create", path, content: last.content }, idx };
  });
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
  const tooBig = (s: string) => Buffer.byteLength(s, "utf8") > MAX_NOTE_BYTES;

  // Remote renames (spec 7.2): compare's report, else a base path missing in theirs whose exact content
  // sits at exactly one new path, and no other missing base path has that content (one-to-one).
  const renamed = (p: string): string | null => {
    if (!has(baseTree, p) || has(theirsTree, p)) return null;
    const r = input.renames?.[p];
    if (r !== undefined && has(theirsTree, r)) return r;
    const text = baseTree[p];
    const hits = Object.keys(theirsTree).filter((q) => !has(baseTree, q) && theirsTree[q] === text);
    const twins = Object.keys(baseTree).filter((q) => !has(theirsTree, q) && baseTree[q] === text);
    return hits.length === 1 && twins.length === 1 ? hits[0]! : null;
  };
  const write = (path: string, content: string) => {
    writes.set(path, { path, content });
    index.add(path);
  };
  const copyPath = (original: string) => {
    const slug = original.normalize("NFC").replace(/\.md$/i, "").replace(/\//g, "-");
    return freePath(index.respell(`_inbox/conflict-${slug}-${stamp}.md`), index);
  };
  const copyText = (original: string, mine: string) => copyHeader(original, device, time) + mine;
  // Size (spec 6.4, F-04): if a write of this op would be over the limit, the op writes nothing,
  // theirs stays, and the op stays in the outbox with a too-large notice (mine is not lost).
  const blockBig = (path: string, idx: number[]) => {
    attention.push({ path, reason: "blocked:too-large" });
    kept.push(...idx);
  };
  const apply = (target: string, r: MergeResult, idx: number[]) => {
    const cur = has(theirsTree, target) ? theirsTree[target]! : null;
    if ((r.content !== null && r.content !== cur && tooBig(r.content)) || (r.copy !== null && tooBig(copyText(target, r.copy))))
      return blockBig(target, idx);
    if (r.content !== null && r.content !== cur) write(target, r.content);
    if (r.content === null && cur !== null) writes.set(target, { path: target, delete: true });
    if (r.copy !== null) {
      const p = copyPath(target);
      write(p, copyText(target, r.copy));
      attention.push({ path: target, reason: "conflict-copy", copy: p, detail: r.reason });
    }
    if (r.kind === "delete-skipped") attention.push({ path: target, reason: "delete-skipped" });
    if (r.content === cur && r.copy === null && r.kind !== "delete-skipped") noops.push(...idx);
  };
  // One op per target (spec 7.1): a later op never overwrites what an earlier op wrote there.
  const claimed = new Set<string>();
  const sameTarget = (target: string, op: Op, idx: number[]) => {
    if (op.kind === "delete") return void attention.push({ path: target, reason: "delete-skipped", detail: "same-target" });
    if (tooBig(copyText(target, op.content))) return blockBig(target, idx);
    const p = copyPath(target);
    write(p, copyText(target, op.content));
    attention.push({ path: target, reason: "conflict-copy", copy: p, detail: "same-target" });
  };

  for (const { op, idx } of coalesce(input.ops, baseTree)) {
    if (op === null) {
      noops.push(...idx); // created and deleted again before sync
      continue;
    }
    if (op.kind === "create") {
      const path = op.path.normalize("NFC");
      const block = checkPath(path, op.content);
      if (block) {
        attention.push({ path, reason: `blocked:${block}` });
        kept.push(...idx);
        continue;
      }
      const clash = index.clash(path, true);
      if (clash) {
        attention.push({ path, reason: "case-clash", detail: clash });
        kept.push(...idx);
        continue;
      }
      if (claimed.has(path) || writes.has(path)) {
        sameTarget(path, op, idx);
        continue;
      }
      claimed.add(path);
      apply(path, mergeFile(null, op.content, has(theirsTree, path) ? theirsTree[path]! : null), idx);
      continue;
    }
    // edit and delete act on an existing repo path: keep its exact bytes, follow a remote rename.
    const target = renamed(op.path) ?? op.path;
    const block = checkPath(target, op.kind === "edit" ? op.content : null);
    if (block) {
      attention.push({ path: target, reason: `blocked:${block}` });
      kept.push(...idx);
      continue;
    }
    if (claimed.has(target) || writes.has(target)) {
      sameTarget(target, op, idx);
      continue;
    }
    claimed.add(target);
    const base = has(baseTree, op.path) ? baseTree[op.path]! : null;
    const theirs = has(theirsTree, target) ? theirsTree[target]! : null;
    if (op.kind === "edit") {
      apply(target, mergeFile(base, op.content, theirs), idx);
      continue;
    }
    // Delete (spec 7.3): re-checked against the new base on every retry.
    if (theirs === null) {
      noops.push(...idx); // already gone: never send sha null for a missing path
      continue;
    }
    if (theirs !== base) {
      attention.push({ path: target, reason: "delete-skipped" });
      continue;
    }
    const trash = index.respell(`_trash/${target}`.normalize("NFC"));
    const trashed = has(theirsTree, trash) && theirsTree[trash] === theirs;
    if (!trashed && tooBig(theirs)) {
      blockBig(target, idx);
      continue;
    }
    writes.set(target, { path: target, delete: true });
    if (!trashed) write(freePath(trash, index), theirs);
  }

  // Final guard (spec 7.6). A throw here is the planner's internal assert; the app shows it in Needs attention.
  // 1. Deletes only for paths present on the new base.
  // 2. No two writes share a clash key. Deletes create no file, so a write may share a key with a delete (twin cleanup, P25).
  // 3. Every write passes the path policy, and every new path is clash-free against the new base and the other writes.
  const entries = [...writes.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  for (const e of entries) if ("delete" in e && !has(theirsTree, e.path)) throw new Error(`plan bug: delete of missing ${e.path}`);
  const keys = new Set<string>();
  const guard = new PathIndex(Object.keys(theirsTree));
  for (const e of entries) {
    if ("delete" in e) continue;
    const k = foldKey(e.path);
    if (keys.has(k)) throw new Error(`plan bug: case clash ${e.path}`);
    keys.add(k);
    if (checkPath(e.path, e.content) !== null) throw new Error(`plan bug: path policy ${e.path}`);
    if (!has(theirsTree, e.path) && guard.clash(e.path) !== null) throw new Error(`plan bug: case clash ${e.path}`);
    guard.add(e.path);
  }
  kept.sort((a, b) => a - b);
  noops.sort((a, b) => a - b);
  return { entries, attention, kept, noops };
}
