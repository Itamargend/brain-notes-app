// Writes Tests/BrainMergeTests/Resources/differential.json: inputs plus the outputs that the
// TypeScript reference (spec/merge/ref) returns for them. The Swift tests assert that the port
// returns exactly the same thing, field for field.
//
// It contains:
//   - the 73 inputs from spec/merge/vectors.json and plan-vectors.json, with the reference's full
//     output (including fields the hand-written `expect` leaves out, such as `unions: 0`);
//   - seeded random cases aimed at the places where Swift and JavaScript strings differ:
//     CRLF and lone CR, missing final newline, fences, frontmatter variants, duplicate and renamed
//     headings, NFC/NFD twins, case twins, Greek final sigma, dotted I, Kelvin sign, astral-plane
//     characters (UTF-16 sort order), control characters, quotes in YAML strings.
//
// Run from the repo root (Node 22.18+ runs .ts files directly):
//   node Tools/differential/gen.ts > Tests/BrainMergeTests/Resources/differential.json
import { readFileSync } from "node:fs";
import { matchLines, diff3, splitLines } from "../../spec/merge/ref/diff3.ts";
import { splitBlocks } from "../../spec/merge/ref/sections.ts";
import { mergeFile } from "../../spec/merge/ref/merge.ts";
import { checkPath, foldKey, freePath, PathIndex } from "../../spec/merge/ref/paths.ts";
import { planCommit, yamlStr, copyStamp } from "../../spec/merge/ref/plan.ts";

const SEED = 20261103;

// mulberry32: small, seeded, deterministic.
let state = SEED >>> 0;
function rnd(): number {
  state = (state + 0x6d2b79f5) >>> 0;
  let t = state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const int = (n: number) => Math.floor(rnd() * n);
const chance = (p: number) => rnd() < p;
function pick<T>(xs: readonly T[]): T {
  return xs[int(xs.length)]!;
}

const NFC_E = "Amélie";
const NFD_E = "Amélie";
const TEXT = [
  "alpha", "beta", "gamma", "delta", "Likes tea.", "Likes green tea.", "- item one", "- item two",
  "- 2026-11-03 call", "", "", "", "  ", "trailing space ", "tab\tinside", "trailing tab\t",
  "שלום עולם", "עובד ‏(demo)", NFC_E, NFD_E,
  "ΟΔΟΣ", "οδος", "emoji \u{1F600} here", "\u{1D4B3} astral", "zero​width",
  "---", "...", "***", "Title", "=====", "> quote", "a\rb", "   indented", "؀x", "[[demo-company]]",
  "﻿bom line", "nbsp here", "x".repeat(30),
];
const HEADINGS = [
  "# A", "# B", "## A", "## B", "## C", "## Meeting", "## Meeting", "### Deep", "###### Six", "####### seven",
  "#tag", "   ## indented", "    ## too-indented", "## Trailing  ", "##\ttab", "#", "##", "## עברית",
  "## " + NFC_E, "## " + NFD_E, "## ΟΔΟΣ", "  # two spaces", "## Notes", "## Timeline", "## Notes \t",
];
const FENCES = ["```", "````", "~~~", "```bash", "  ```", "    ```", "``` ", "~~~~", "`` not a fence", "```\t", "~~~ ~"];
const FM_OPEN = ["---", "---", "--- ", "---\t", "----", "---x"];
const FM_CLOSE = ["---", "...", "--- ", "..", "....", "...\t"];
const FM_BODY = ["title: Demo", "type: person", "updated: 2026-10-01", "tags: [a, b]"];

function genLines(maxSections: number, maxLines: number): string[] {
  const out: string[] = [];
  if (chance(0.35)) {
    out.push(pick(FM_OPEN));
    for (let i = int(3); i > 0; i -= 1) out.push(pick(FM_BODY));
    if (chance(0.85)) out.push(pick(FM_CLOSE));
  }
  if (chance(0.5)) for (let i = 1 + int(3); i > 0; i -= 1) out.push(pick(TEXT));
  for (let s = int(maxSections + 1); s > 0; s -= 1) {
    out.push(pick(HEADINGS));
    for (let i = int(maxLines + 1); i > 0; i -= 1) {
      if (chance(0.08)) {
        const f = pick(FENCES);
        out.push(f);
        for (let j = int(3); j > 0; j -= 1) out.push(chance(0.4) ? pick(HEADINGS) : pick(TEXT));
        if (chance(0.8)) out.push(chance(0.7) ? f.trim() : pick(FENCES));
      } else out.push(pick(TEXT));
    }
  }
  return out;
}

function render(lines: string[]): string {
  const mode = pick(["\n", "\n", "\n", "\n", "\r\n", "mixed"]);
  const finalNewline = !chance(0.15);
  return lines
    .map((l, i) => (i === lines.length - 1 && !finalNewline ? l : l + (mode === "mixed" ? pick(["\n", "\r\n"]) : mode)))
    .join("");
}

const doc = (maxSections = 4, maxLines = 4) => render(genLines(maxSections, maxLines));
const ATX = /^ {0,3}#{1,6}(?:[ \t]|\r?\n|$)/;

function mutate(text: string): string {
  const ls = splitLines(text);
  const eol = text.includes("\r\n") && chance(0.7) ? "\r\n" : "\n";
  for (let e = 1 + int(3); e > 0; e -= 1) {
    const at = int(ls.length + 1);
    const heads = ls.map((l, i) => (ATX.test(l) ? i : -1)).filter((i) => i >= 0);
    const sectionEnd = (h: number) => heads.find((i) => i > h) ?? ls.length;
    switch (int(13)) {
      case 0:
      case 1:
        if (ls.length) ls[int(ls.length)] = pick(TEXT) + eol;
        break;
      case 2:
      case 3:
        ls.splice(at, 0, pick(TEXT) + eol);
        break;
      case 4:
        if (ls.length) ls.splice(int(ls.length), 1 + int(2));
        break;
      case 5:
        if (heads.length) {
          const h = pick(heads);
          ls.splice(h, sectionEnd(h) - h);
        }
        break;
      case 6:
        ls.splice(at, 0, pick(HEADINGS) + eol, pick(TEXT) + eol);
        break;
      case 7:
        if (heads.length) ls[pick(heads)] = pick(HEADINGS) + eol;
        break;
      case 8:
        if (ls.length) {
          const i = int(ls.length);
          const l = ls[i]!;
          ls[i] = l.endsWith("\r\n") ? l.slice(0, -2) + "\n" : l.endsWith("\n") ? l.slice(0, -1) + "\r\n" : l + "\n";
        }
        break;
      case 9:
        if (ls.length) {
          const l = ls[ls.length - 1]!;
          ls[ls.length - 1] = l.endsWith("\n") ? l.replace(/\r?\n$/, "") : l + eol;
        }
        break;
      case 10:
        if (chance(0.5)) ls.unshift("---" + eol, "type: idea" + eol, "---" + eol);
        else if (ls.length && ls[0]!.startsWith("---")) ls.shift();
        break;
      case 11:
        if (heads.length) ls.splice(sectionEnd(pick(heads)), 0, pick(TEXT) + eol);
        else ls.push(pick(TEXT) + eol);
        break;
      case 12:
        if (heads.length >= 2) {
          const h = pick(heads);
          const moved = ls.splice(h, sectionEnd(h) - h);
          ls.push(...moved);
        }
        break;
    }
  }
  return ls.join("");
}

const errorOf = (e: unknown) => ({ error: e instanceof Error ? e.message : String(e) });
const expand = (c: any): any =>
  c && typeof c === "object" && Array.isArray(c.$repeat) ? String(c.$repeat[0]).repeat(c.$repeat[1]) : c;
function runMerge(base: string | null, mine: string | null, theirs: string | null, options?: { unionInsertions?: boolean }) {
  try {
    return mergeFile(base, mine, theirs, options ?? {});
  } catch (e) {
    return errorOf(e);
  }
}
function runPlan(input: any) {
  try {
    const ops = input.ops.map((o: any) => ("content" in o ? { ...o, content: expand(o.content) } : o));
    return planCommit({ ...input, ops });
  } catch (e) {
    return errorOf(e);
  }
}

const dir = new URL("../../spec/merge/", import.meta.url).pathname;
const vectors = JSON.parse(readFileSync(dir + "vectors.json", "utf8")).vectors;
const planVectors = JSON.parse(readFileSync(dir + "plan-vectors.json", "utf8")).vectors;

// ---------- line and block level ----------
const splitCases = [];
for (let n = 0; n < 250; n += 1) {
  const text = n % 5 === 0 ? mutate(doc(5, 4)) : doc(5, 4);
  splitCases.push({ text, out: splitBlocks(text) });
}

const SMALL = ["a\n", "b\n", "c\n", "a", "b\r\n", "", "\n"];
const lineList = (max: number) => Array.from({ length: int(max + 1) }, () => pick(SMALL));
const matchCases = [];
for (let n = 0; n < 200; n += 1) {
  const a = lineList(9), b = lineList(9);
  matchCases.push({ a, b, out: Array.from(matchLines(a, b)) });
}
// The 4,000,000-cell guard: 1,999 x 1,999 distinct middle lines is allowed, 2,000 x 2,000 is not.
for (const size of [1999, 2000]) {
  const a = Array.from({ length: size }, (_, i) => `a${i}\n`), b = Array.from({ length: size }, (_, i) => `b${i}\n`);
  let out;
  try {
    out = Array.from(matchLines(a, b));
  } catch (e) {
    out = errorOf(e);
  }
  matchCases.push({ a: { $lines: ["a", size] }, b: { $lines: ["b", size] }, out });
}

const diff3Cases = [];
for (let n = 0; n < 300; n += 1) {
  const o = lineList(7);
  const edit = (xs: string[]) => {
    const ys = [...xs];
    for (let k = int(3); k > 0; k -= 1) {
      const r = int(3);
      if (r === 0) ys.splice(int(ys.length + 1), 0, pick(SMALL));
      else if (r === 1 && ys.length) ys.splice(int(ys.length), 1);
      else if (ys.length) ys[int(ys.length)] = pick(SMALL);
    }
    return ys;
  };
  const a = edit(o), b = chance(0.2) ? a : edit(o);
  const union = !chance(0.2);
  diff3Cases.push({ o, a, b, union, out: diff3(o, a, b, union) });
}

// ---------- file merge ----------
const mergeCases = [];
for (const v of vectors) {
  mergeCases.push({ id: v.id, base: v.base, mine: v.mine, theirs: v.theirs, options: v.options, out: runMerge(v.base, v.mine, v.theirs, v.options) });
}
for (let n = 0; n < 900; n += 1) {
  const base0 = doc();
  let base: string | null = base0;
  let mine: string | null = chance(0.12) ? base0 : mutate(base0);
  let theirs: string | null = chance(0.12) ? base0 : chance(0.08) ? mine : mutate(base0);
  const r = rnd();
  if (r < 0.03) base = null;
  else if (r < 0.05) base = "";
  if (chance(0.03)) mine = null;
  if (chance(0.03)) theirs = null;
  const options = chance(0.15) ? { unionInsertions: false } : undefined;
  mergeCases.push({ id: `R${n}`, base, mine, theirs, options, out: runMerge(base, mine, theirs, options) });
}
// A one-block note at the cell limit (allowed) and just over it (too-large).
for (const size of [1999, 2000]) {
  const lines = (p: string) => Array.from({ length: size }, (_, i) => `${p}${i}\n`).join("");
  mergeCases.push({ id: `L${size}`, base: lines("b"), mine: lines("m"), theirs: lines("t"), out: runMerge(lines("b"), lines("m"), lines("t")) });
}

// ---------- paths ----------
const SEGS = [
  "people", "People", "PEOPLE", "notes", "Notes", "_inbox", "companies", "private", "Private", "PRIVATE", "_capture", "_Capture",
  NFC_E, NFD_E, "ΟΔΟΣ", "οδος", "οδοσ", "İstanbul", "istanbul",
  "Kelvin", "kelvin", "Straße", "STRASSE", "\u{10400}x", "\u{10428}x", ".hidden", "a b", 'say "hi"', "ǅ", "ǆ",
  "ΟΔΟΣ'", "ΆΣ", "x", "X", "Ａ", "", "\u{1F600}",
];
const NAMES = [
  "demo-person", "Demo-Person", "idea", "Idea", NFC_E, NFD_E, "ΟΔΟΣ", "οδος", "K", "k",
  "note", "Note", "\u{10400}", "\u{10428}", "ǅ", "ǆ", "x", "İ", "i̇", "\u{1F600}", "Ａ", "",
];
const EXTS = [".md", ".md", ".md", ".md", ".MD", ".Md", ".mD", ".txt", "", ".md́", ".m", "؀.md"];
function genPath(): string {
  const segs: string[] = [];
  for (let i = int(3); i > 0; i -= 1) segs.push(pick(SEGS));
  segs.push(pick(NAMES) + pick(EXTS));
  let p = segs.join("/");
  const r = rnd();
  if (r < 0.02) p = "/" + p;
  else if (r < 0.04) p = p.replace("/", "//");
  else if (r < 0.05) p = p + "\t";
  else if (r < 0.06) p = p.replace("/", "/./");
  else if (r < 0.07) p = p.replace("/", "/../");
  else if (r < 0.08) p = "a\u007fb/" + p;
  return p;
}
// Paths that pass the policy, so planner cases reach the merge instead of stopping at "blocked".
const OK_SEGS = ["people", "People", "notes", "Notes", "companies", NFC_E, NFD_E, "ΟΔΟΣ", "οδος", "Kelvin", "kelvin", "\u{10400}x", "\u{10428}x", "İstanbul", "say \"hi\""];
function okPath(): string {
  const segs: string[] = [];
  for (let i = int(3); i > 0; i -= 1) segs.push(pick(OK_SEGS));
  segs.push(pick(NAMES) + pick([".md", ".md", ".md", ".MD"]));
  return segs.join("/");
}
const pathCases = [];
for (let n = 0; n < 500; n += 1) {
  const p = genPath();
  pathCases.push({ path: p, nfc: p.normalize("NFC"), fold: foldKey(p), check: checkPath(p, null) });
}
const contentCases = [];
for (const [s, count] of [["a", 1048576], ["a", 1048577], ["é", 524288], ["é", 524289], ["\u{1F600}", 262144], ["\u{1F600}", 262145], ["א", 524288], ["א", 524289]] as const) {
  contentCases.push({ path: "notes/big.md", content: { $repeat: [s, count] }, check: checkPath("notes/big.md", s.repeat(count)) });
}

const freePathCases = [];
for (let n = 0; n < 150; n += 1) {
  const existing = Array.from({ length: int(6) }, () => (chance(0.5) ? `_trash/${pick(NAMES)}${pick(["", "-2", "-3"])}${pick([".md", ".MD"])}` : genPath()));
  const p = chance(0.6) && existing.length ? pick(existing) : `_trash/${pick(NAMES)}${pick([".md", ".MD", ".Md"])}`;
  freePathCases.push({ existing, path: p, out: freePath(p, new PathIndex(existing)) });
}

const YAML_IN = ['say "hi"', "back\\slash", "tab\there", "nl\nx", "cr\rx", "ff\fx", "bs\bx", "\u0000\u0001\u001f\u007f", "  ", NFD_E, "\u{1F600}", "/", "plain"];
const yamlCases = YAML_IN.map((s) => ({ in: s, out: yamlStr(s) }));
for (let n = 0; n < 40; n += 1) {
  const s = Array.from({ length: 1 + int(6) }, () => String.fromCodePoint(pick([0, 1, 8, 9, 10, 12, 13, 31, 34, 47, 92, 127, 0xe9, 0x2028, 0x1f600, 0x41]))).join("");
  yamlCases.push({ in: s, out: yamlStr(s) });
}

const STAMP_IN = [
  "2026-11-03T10:30:00Z", "2026-11-03T10:30:00.123Z", "2026-11-03T10:30:00.Z", "2026-11-03T10:30:00z", "2026-11-03 10:30:00Z",
  "2026-11-03T10:30:00+00:00", "2026-11-03T10:30:00Z\n", " 2026-11-03T10:30:00Z", "2026-11-03T10:30Z", "２026-11-03T10:30:00Z",
  "9999-99-99T99:99:99.000000Z", "2026-1-03T10:30:00Z", "",
];
const stampCases = STAMP_IN.map((s) => {
  try {
    return { in: s, out: copyStamp(s) };
  } catch (e) {
    return { in: s, ...errorOf(e) };
  }
});

// ---------- commit planner ----------
const has = (t: Record<string, string>, p: string) => Object.prototype.hasOwnProperty.call(t, p);
const smallDoc = () => doc(2, 3);
const planCases: any[] = [];
for (const v of planVectors) {
  const input = { baseTree: v.baseTree, theirsTree: v.theirsTree, ops: v.ops, renames: v.renames, device: v.device, time: v.time };
  planCases.push({ id: v.id, input, out: runPlan(input) });
}
const DEVICES = ["spike-mac", 'Itamar\'s "phone"', "tab\there", "דוד", "back\\slash", "ctl\u0001"];
const TIMES = ["2026-11-03T10:30:00Z", "2026-11-03T10:30:00Z", "2026-11-03T10:30:00.123Z", "2026-01-02T03:04:05Z"];
const twin = (p: string) => pick([p.toUpperCase(), p.toLowerCase(), p.normalize("NFD"), p.normalize("NFC"), p]);
for (let n = 0; n < 350; n += 1) {
  const base: Record<string, string> = {};
  for (let i = 2 + int(5); i > 0; i -= 1) base[chance(0.85) ? okPath() : genPath()] = smallDoc();
  const theirs: Record<string, string> = { ...base };
  for (const p of Object.keys(base)) {
    const r = rnd();
    if (r < 0.2) theirs[p] = mutate(base[p]!);
    else if (r < 0.27) delete theirs[p];
    else if (r < 0.35) {
      delete theirs[p];
      theirs[chance(0.5) ? genPath() : twin(p)] = base[p]!;
    }
  }
  if (chance(0.3)) theirs[chance(0.5) ? genPath() : twin(pick(Object.keys(base)))] = smallDoc();
  if (chance(0.2)) {
    const p = pick(Object.keys(base));
    theirs["_trash/" + p] = chance(0.5) ? base[p]! : "older\n";
  }
  const baseKeys = Object.keys(base);
  const ops: any[] = [];
  for (let k = 1 + int(4); k > 0; k -= 1) {
    const r = rnd();
    if (r < 0.45) {
      const p = pick(baseKeys);
      ops.push({ kind: "edit", path: p, content: chance(0.15) ? (has(theirs, p) ? theirs[p] : base[p]) : mutate(base[p]!) });
    } else if (r < 0.75) {
      const q = rnd();
      const p = q < 0.35 ? twin(pick(baseKeys)) : q < 0.8 ? okPath() : genPath();
      ops.push({ kind: "create", path: p, content: smallDoc() });
    } else {
      ops.push({ kind: "delete", path: chance(0.85) ? pick(baseKeys) : genPath() });
    }
  }
  if (chance(0.15)) {
    const stamp = "20261103-103000";
    const p = pick(baseKeys);
    theirs[`_inbox/conflict-${p.normalize("NFC").replace(/\.md$/i, "").replace(/\//g, "-")}-${stamp}.md`] = "earlier copy\n";
  }
  let renames: Record<string, string> | undefined;
  const gone = baseKeys.filter((p) => !has(theirs, p));
  if (gone.length && chance(0.4)) renames = { [pick(gone)]: chance(0.7) ? pick(Object.keys(theirs)) : genPath() };
  const time = chance(0.03) ? pick(["2026-11-03 10:30:00Z", "2026-11-03T10:30:00+00:00"]) : pick(TIMES);
  const input = { baseTree: base, theirsTree: theirs, ops, renames, device: pick(DEVICES), time };
  planCases.push({ id: `R${n}`, input, out: runPlan(input) });
}
// Final guard (spec 7.6): GitHub can hold case or NFC/NFD twins (spike S1). Editing both twins in
// one batch makes two entries with one clash key, and the reference throws "plan bug: case clash".
for (const [x, y] of [["notes/A.md", "notes/a.md"], [`people/${NFC_E}.md`, `people/${NFD_E}.md`], ["ΟΔΟΣ/x.md", "οδος/x.md"], ["ΟΔΟΣ/x.md", "οδοσ/x.md"]]) {
  const tree = { [x]: "# x\n\nbase\n", [y]: "# y\n\nbase\n" };
  const input = { baseTree: tree, theirsTree: tree, ops: [{ kind: "edit", path: x, content: "# x\n\nmine\n" }, { kind: "edit", path: y, content: "# y\n\nmine\n" }], device: "spike-mac", time: "2026-11-03T10:30:00Z" };
  planCases.push({ id: `G${planCases.length}`, input, out: runPlan(input) });
}
// Sort order: entries are sorted by UTF-16 code unit, which puts astral-plane characters
// (surrogates, 0xD800-0xDFFF) before U+E000-U+FFFF. Swift's String < would not.
const SORT_NAMES = ["a", "A", "b", "é", "Ａ", "", "\u{1F600}", "\u{10400}", "z", "_", "-", "~", "א", " x", "Z"];
for (let n = 0; n < 40; n += 1) {
  const ops = Array.from({ length: 3 + int(8) }, () => ({ kind: "create", path: `${pick(["", "notes/", "Notes/", "\u{1F600}/"])}${pick(SORT_NAMES)}${pick(SORT_NAMES)}.md`, content: "# x\n" }));
  const input = { baseTree: {}, theirsTree: {}, ops, device: "spike-mac", time: "2026-11-03T10:30:00Z" };
  planCases.push({ id: `S${n}`, input, out: runPlan(input) });
}

const tally = (xs: any[]) => {
  const t: Record<string, number> = {};
  for (const x of xs) {
    const k = "error" in x.out ? "error: " + x.out.error.slice(0, 40) : `${x.out.kind}${x.out.reason ? "/" + x.out.reason : ""}`;
    t[k] = (t[k] ?? 0) + 1;
  }
  return t;
};
const planTally: Record<string, number> = {};
for (const c of planCases) {
  const k = "error" in c.out ? "error: " + c.out.error : `entries=${Math.min(c.out.entries.length, 3)}${c.out.attention.length ? " attention" : ""}${c.out.kept.length ? " kept" : ""}${c.out.noops.length ? " noop" : ""}`;
  planTally[k] = (planTally[k] ?? 0) + 1;
}
process.stderr.write(JSON.stringify({ merge: tally(mergeCases), plan: planTally }, null, 1) + "\n");

const out = {
  about: "Inputs and the outputs spec/merge/ref returns for them. Generated by Tools/differential/gen.ts; do not edit by hand.",
  seed: SEED,
  node: process.version,
  splitBlocks: splitCases,
  matchLines: matchCases,
  diff3: diff3Cases,
  merge: mergeCases,
  paths: pathCases,
  pathContent: contentCases,
  freePath: freePathCases,
  yaml: yamlCases,
  stamp: stampCases,
  plan: planCases,
};
process.stdout.write(JSON.stringify(out) + "\n");
