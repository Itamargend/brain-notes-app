/**
 * File-level 3-way merge for Brain Notes (docs/m3/merge-spec.md, section 5).
 * Rule: never discard text. Sections that merge cleanly are merged; a section that clashes keeps
 * the GitHub version (theirs) in the note, and the caller writes mine, whole, to an _inbox conflict copy.
 * Safety net: if the per-section result fails the line check, the whole note keeps theirs.
 */
import { diff3, DiffTooLarge, splitLines } from "./diff3.ts";
import { splitBlocks, joinBlocks, detectEol, type Block } from "./sections.ts";

/** null means the file does not exist on that side. */
export type Doc = string | null;

export type MergeKind =
  | "same" // mine and theirs are identical
  | "take-theirs" // only theirs changed (or nothing changed)
  | "take-mine" // only mine changed
  | "merged" // both changed, merged cleanly
  | "conflict" // clashing sections keep theirs, clean sections merged; copy = mine (whole)
  | "delete-skipped"; // I deleted, GitHub edited: theirs stays, needs attention

export type ConflictReason = "same-lines" | "deleted-remotely" | "both-created" | "section-deleted" | "heading-renamed" | "unsafe-merge" | "too-large";

export interface MergeResult {
  kind: MergeKind;
  /** Resulting file content; null means the file is absent afterwards. */
  content: Doc;
  /** Text for the conflict copy (mine, verbatim) or null. */
  copy: string | null;
  reason?: ConflictReason;
  /** Keys of the blocks that clashed, for the review list. */
  clashes?: string[];
  /** Number of points where both sides inserted text and both were kept (spec 4.3). */
  unions?: number;
}

export interface MergeOptions {
  unionInsertions?: boolean;
}

export function mergeFile(base: Doc, mine: Doc, theirs: Doc, opts: MergeOptions = {}): MergeResult {
  const union = opts.unionInsertions ?? true;
  if (mine === theirs) return { kind: "same", content: theirs, copy: null };
  if (mine === base) return { kind: "take-theirs", content: theirs, copy: null };
  if (theirs === base) return { kind: "take-mine", content: mine, copy: null };
  // Both sides changed and differ from each other.
  if (mine === null) return { kind: "delete-skipped", content: theirs, copy: null };
  if (theirs === null) return { kind: "conflict", content: null, copy: mine, reason: "deleted-remotely" };
  if (base === null) return { kind: "conflict", content: theirs, copy: mine, reason: "both-created" };
  try {
    const bb = splitBlocks(base), mb = splitBlocks(mine), tb = splitBlocks(theirs);
    const hasFm = (x: Block[]) => x[0]?.key === "fm";
    let text: string;
    let unions: number;
    if (hasFm(bb) === hasFm(mb) && hasFm(bb) === hasFm(tb)) {
      const r = mergeBlocks(bb, mb, tb, union, detectEol(theirs));
      if (r.clashes.length) {
        // Two different renames of one heading: no safe per-section answer, whole note keeps theirs (spec 5.2).
        if (r.renamed) return { kind: "conflict", content: theirs, copy: mine, reason: r.reason, clashes: r.clashes };
        // Per-section conflict (spec 5.2): mine's lines may be missing from the note, they are all in the copy.
        if (!safe(base, mine, theirs, r.text, false)) return { kind: "conflict", content: theirs, copy: mine, reason: "unsafe-merge", clashes: r.clashes };
        return { kind: "conflict", content: r.text, copy: mine, reason: r.reason, clashes: r.clashes, unions: r.unions };
      }
      text = r.text;
      unions = r.unions;
    } else {
      // Frontmatter added or removed on one side (spec 5.5): block keys shift, so merge the whole file by lines.
      const d = diff3(splitLines(base), splitLines(mine), splitLines(theirs), union);
      if (!d.clean) return { kind: "conflict", content: theirs, copy: mine, reason: "same-lines", clashes: ["(file)"] };
      text = d.lines.join("");
      unions = d.unions;
    }
    // Safety check (spec 5.5): a clean result must keep every added line, invent no line, duplicate nothing.
    if (!safe(base, mine, theirs, text)) return { kind: "conflict", content: theirs, copy: mine, reason: "unsafe-merge" };
    return { kind: "merged", content: text, copy: null, unions };
  } catch (e) {
    if (e instanceof DiffTooLarge) return { kind: "conflict", content: theirs, copy: mine, reason: "too-large" };
    throw e;
  }
}

/** Counts lines by text without the line ending. */
function counts(text: string): Map<string, number> {
  const c = new Map<string, number>();
  for (const l of splitLines(text)) {
    const k = l.replace(/\r?\n$/, "");
    c.set(k, (c.get(k) ?? 0) + 1);
  }
  return c;
}

/**
 * Line check (spec 5.5). requireMine=false for a per-section conflict, whose copy holds all of mine:
 * then only theirs' added lines must be in the note.
 */
export function safe(base: string, mine: string, theirs: string, result: string, requireMine = true): boolean {
  const b = counts(base), m = counts(mine), t = counts(theirs), r = counts(result);
  const get = (x: Map<string, number>, k: string) => x.get(k) ?? 0;
  for (const [k, n] of r) {
    const cb = get(b, k), cm = get(m, k), ct = get(t, k);
    if (cb + cm + ct === 0) return false; // invented line
    if (n > Math.max(cm, ct, cm + ct - cb)) return false; // duplicated line
  }
  for (const side of requireMine ? [m, t] : [t])
    for (const [k, n] of side) if (n > get(b, k) && get(r, k) === 0) return false; // lost an added line
  return true;
}

function mergeBlocks(b: Block[], m: Block[], t: Block[], union: boolean, eol: string) {
  const B = new Map(b.map((x) => [x.key, x.lines]));
  const M = new Map(m.map((x) => [x.key, x.lines]));
  const T = new Map(t.map((x) => [x.key, x.lines]));
  const same = (x?: string[], y?: string[]) =>
    x === y || (x !== undefined && y !== undefined && x.length === y.length && x.every((v, i) => v === y[i]));
  const result = new Map<string, string[]>();
  const clashes: string[] = [];
  let sectionDeleted = false;
  let unions = 0;
  const keys = [...new Set([...b, ...m, ...t].map((x) => x.key))];
  for (const k of keys) {
    const vb = B.get(k);
    const vm = M.get(k);
    const vt = T.get(k);
    let r: string[] | undefined;
    if (same(vm, vt)) r = vt;
    else if (same(vm, vb)) r = vt;
    else if (same(vt, vb)) r = vm;
    else if (vm === undefined || vt === undefined) {
      clashes.push(k); // one side removed the block, the other changed it: theirs wins in the note
      sectionDeleted = true;
      r = vt;
    } else if (vb === undefined) {
      clashes.push(k); // both added a block with the same key and different text
      r = vt;
    } else {
      const d = diff3(vb, vm, vt, union);
      if (!d.clean) {
        clashes.push(k);
        r = vt;
        if (r !== undefined) result.set(k, r);
        continue;
      }
      unions += d.unions;
      r = d.lines;
    }
    if (r !== undefined) result.set(k, r);
  }
  // Both sides renamed the same heading differently (spec 5.2, last rule): base key gone on both sides
  // while each side has a key the other lacks. Without this the body would be kept twice.
  const droppedBoth = b.filter((x) => !M.has(x.key) && !T.has(x.key)).map((x) => x.key);
  const onlyM = m.some((x) => !B.has(x.key) && !T.has(x.key));
  const onlyT = t.some((x) => !B.has(x.key) && !M.has(x.key));
  let renamed = false;
  if (droppedBoth.length && onlyM && onlyT) {
    clashes.push(...droppedBoth);
    renamed = true;
  }
  const reason: ConflictReason = sectionDeleted ? "section-deleted" : renamed && clashes.length === droppedBoth.length ? "heading-renamed" : "same-lines";
  // Order (spec 5.3): theirs order, then blocks only in mine after their nearest kept predecessor in mine.
  const order = t.map((x) => x.key).filter((k) => result.has(k));
  let prev: string | null = null;
  for (const x of m) {
    if (!result.has(x.key)) continue;
    if (!order.includes(x.key)) {
      const at = prev === null ? 0 : order.indexOf(prev) + 1;
      order.splice(at, 0, x.key);
    }
    prev = x.key;
  }
  const text = joinBlocks(order.map((k) => ({ key: k, lines: result.get(k)! })), eol);
  return { text, clashes, reason, unions, renamed };
}
