/**
 * Line diff and diff3 for the Brain Notes merge spec (docs/m3/merge-spec.md, sections 3 and 4).
 * Pure and deterministic: the Swift port must produce the same output for the same input.
 */

/** Split into lines, keeping each line's terminator ("\n" or "\r\n"). The last line may have none. */
export function splitLines(text: string): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < text.length) {
    const j = text.indexOf("\n", i);
    if (j < 0) {
      out.push(text.slice(i));
      break;
    }
    out.push(text.slice(i, j + 1));
    i = j + 1;
  }
  return out;
}

/** Above this many DP cells (after trimming the common prefix and suffix) a merge is refused as a conflict. */
export const MAX_DIFF_CELLS = 4_000_000;

export class DiffTooLarge extends Error {}

/**
 * Longest common subsequence matching of a against b (spec 3.2).
 * Returns m where m[i] is the index in b that a[i] is matched to, or -1.
 * Steps: match the common prefix greedily, then the common suffix greedily,
 * then a DP LCS on the middle walked forward: match when the lines are equal and
 * matching keeps the LCS length; otherwise skip a[i] if lcs[i+1][j] >= lcs[i][j+1], else skip b[j].
 */
export function matchLines(a: readonly string[], b: readonly string[]): Int32Array {
  const m = new Int32Array(a.length).fill(-1);
  let pre = 0;
  while (pre < a.length && pre < b.length && a[pre] === b[pre]) {
    m[pre] = pre;
    pre += 1;
  }
  let suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] === b[b.length - 1 - suf]) {
    m[a.length - 1 - suf] = b.length - 1 - suf;
    suf += 1;
  }
  const n = a.length - pre - suf;
  const k = b.length - pre - suf;
  if (n === 0 || k === 0) return m;
  if ((n + 1) * (k + 1) > MAX_DIFF_CELLS) throw new DiffTooLarge(`diff of ${n}x${k} lines is too large`);
  const w = k + 1;
  const lcs = new Uint32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = k - 1; j >= 0; j -= 1) {
      lcs[i * w + j] =
        a[pre + i] === b[pre + j]
          ? lcs[(i + 1) * w + j + 1]! + 1
          : Math.max(lcs[(i + 1) * w + j]!, lcs[i * w + j + 1]!);
    }
  }
  let i = 0;
  let j = 0;
  while (i < n && j < k) {
    if (a[pre + i] === b[pre + j] && lcs[i * w + j] === lcs[(i + 1) * w + j + 1]! + 1) {
      m[pre + i] = pre + j;
      i += 1;
      j += 1;
    } else if (lcs[(i + 1) * w + j]! >= lcs[i * w + j + 1]!) {
      i += 1;
    } else {
      j += 1;
    }
  }
  return m;
}

export type Diff3Result =
  | { clean: true; lines: string[]; unions: number }
  | { clean: false; conflicts: number };

const eq = (x: readonly string[], y: readonly string[]) => x.length === y.length && x.every((v, i) => v === y[i]);

/**
 * diff3 (spec 4). o = base, a = mine, b = theirs.
 * Stable lines are base lines matched in both sides at the current position. Between stable runs,
 * an unstable chunk resolves as: a == o -> b; b == o -> a; a == b -> a;
 * o empty and unionInsertions -> b then a (both sides only inserted text at the same point);
 * otherwise a conflict.
 */
export function diff3(o: readonly string[], a: readonly string[], b: readonly string[], unionInsertions = true): Diff3Result {
  const ma = matchLines(o, a);
  const mb = matchLines(o, b);
  const out: string[] = [];
  let conflicts = 0;
  let unions = 0;
  let io = 0;
  let ia = 0;
  let ib = 0;
  for (;;) {
    if (io < o.length && ma[io] === ia && mb[io] === ib) {
      out.push(o[io]!);
      io += 1;
      ia += 1;
      ib += 1;
      continue;
    }
    let so = io;
    while (so < o.length && (ma[so] === -1 || mb[so] === -1)) so += 1;
    const sa = so < o.length ? ma[so]! : a.length;
    const sb = so < o.length ? mb[so]! : b.length;
    const co = o.slice(io, so);
    const ca = a.slice(ia, sa);
    const cb = b.slice(ib, sb);
    if (co.length === 0 && ca.length === 0 && cb.length === 0) {
      if (so >= o.length) break;
      // Defensive: cannot happen with monotonic matchings, but never loop forever.
      throw new Error("diff3: no progress");
    }
    if (eq(ca, co)) out.push(...cb);
    else if (eq(cb, co)) out.push(...ca);
    else if (eq(ca, cb)) out.push(...ca);
    else if (co.length === 0 && unionInsertions) {
      out.push(...cb, ...ca);
      unions += 1;
    } else conflicts += 1;
    io = so;
    ia = sa;
    ib = sb;
  }
  return conflicts ? { clean: false, conflicts } : { clean: true, lines: out, unions };
}
