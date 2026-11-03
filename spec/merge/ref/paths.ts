/**
 * Path policy for app writes (docs/m3/merge-spec.md, section 6). Findings from spike S1:
 * GitHub stores NFC and NFD spellings, and names differing only by case, as separate files,
 * which collide on Apple file systems. New paths are normalised to NFC; clashes by case or normalisation (foldKey) are refused.
 */
export const MAX_NOTE_BYTES = 1024 * 1024;

export type PathBlock = "not-md" | "dot-segment" | "blocked-folder" | "bad-segment" | "control-char" | "invisible-char" | "too-large";

/**
 * Clash key (spec 6.3): full Unicode case folding, insensitive to NFC/NFD, matching how APFS
 * (Mac and iPhone) decides that two names are the same file. Steps:
 *   1. NFD, so a precomposed letter folds like its base letter plus marks;
 *   2. each code point on its own: lowercase, uppercase, lowercase (so "ß" and "ẞ" become "ss",
 *      "ﬁ" becomes "fi", "ſ" becomes "s", Kelvin sign becomes "k");
 *      except dotless "ı", which stays "ı" (case folding and APFS keep it apart from "i" and "I");
 *   3. final sigma "ς" becomes "σ" (one key for both sigmas, with no context rule);
 *   4. NFC.
 * Per code point and locale-independent, so it is the same in TypeScript and Swift. Over all of
 * Unicode 17 it groups code points exactly like CaseFolding.txt (status C+F). It does not apply
 * compatibility folding (NFKC): APFS keeps "Ａ"/"A", "²"/"2" and "Ǳ"/"dz" apart, and so does this.
 */
export function foldKey(path: string): string {
  let out = "";
  for (const c of path.normalize("NFD")) out += c === "\u0131" ? c : c.toLowerCase().toUpperCase().toLowerCase().replace(/\u03c2/g, "\u03c3");
  return out.normalize("NFC");
}

export function checkPath(path: string, content?: string | null): PathBlock | null {
  if (/[\u0000-\u001f\u007f]/.test(path)) return "control-char";
  // Default_Ignorable_Code_Point (ZWSP, ZWJ, ZWNJ, BOM, soft hyphen, bidi marks, variation selectors, ...):
  // invisible in a file name, and APFS keeps them, so "a\u200bb.md" and "ab.md" look the same but are two files.
  if (/\p{Default_Ignorable_Code_Point}/u.test(path)) return "invisible-char";
  const segs = path.split("/");
  if (segs.some((s) => s === "" || s === "." || s === "..")) return "bad-segment";
  if (segs.some((s) => s.startsWith("."))) return "dot-segment";
  if (segs.slice(0, -1).some((s) => ["private", "_capture"].includes(foldKey(s)))) return "blocked-folder";
  if (!path.toLowerCase().endsWith(".md")) return "not-md";
  if (content != null && Buffer.byteLength(content, "utf8") > MAX_NOTE_BYTES) return "too-large";
  return null;
}

/**
 * Index of a tree's paths by clash key. Folder prefixes are indexed too (with a trailing "/"),
 * because `People/a.md` next to `people/b.md` also collides on a Mac. The first spelling seen for a
 * key wins (tree order); a second spelling of a folder already on GitHub is remembered as its twin.
 */
export class PathIndex {
  private byKey = new Map<string, string>();
  private twins = new Map<string, string>();
  constructor(paths: Iterable<string>) {
    for (const p of paths) this.add(p);
  }
  private static prefixes(p: string): string[] {
    const segs = p.split("/");
    const out: string[] = [];
    for (let i = 1; i < segs.length; i += 1) out.push(segs.slice(0, i).join("/") + "/");
    return out;
  }
  add(p: string) {
    for (const k of [...PathIndex.prefixes(p), p]) {
      const fk = foldKey(k);
      const e = this.byKey.get(fk);
      if (e === undefined) this.byKey.set(fk, k);
      else if (e !== k && k.endsWith("/") && !this.twins.has(fk)) this.twins.set(fk, k);
    }
  }
  /**
   * The first existing folder or file that clashes with p, if any (spec 6.3): same clash key with
   * different bytes; a folder of p that is a file, or p itself is a folder; and with `strict` (new
   * paths the user made), a folder of p that already has case twins on GitHub.
   */
  clash(p: string, strict = false): string | null {
    for (const k of [...PathIndex.prefixes(p), p]) {
      const fk = foldKey(k);
      const e = this.byKey.get(fk);
      if (e !== undefined && e !== k) return e;
      const tw = strict ? this.twins.get(fk) : undefined;
      if (tw !== undefined) return tw;
    }
    for (const k of PathIndex.prefixes(p)) {
      const e = this.byKey.get(foldKey(k.slice(0, -1)));
      if (e !== undefined) return e;
    }
    return this.byKey.get(foldKey(p + "/")) ?? null;
  }
  takenByAny(p: string): boolean {
    return this.byKey.has(foldKey(p)) || this.byKey.has(foldKey(p + "/"));
  }
  /** p with each folder spelled as the folder already in the index (spec 6.3), for paths the app names itself. */
  respell(p: string): string {
    const segs = p.split("/");
    let out = "";
    for (let i = 0; i < segs.length - 1; i += 1) {
      const k = out + segs[i] + "/";
      out = this.byKey.get(foldKey(k)) ?? k;
    }
    return out + segs[segs.length - 1];
  }
}

/** Add -2, -3, ... before ".md" until the path is free (by clash key). */
export function freePath(path: string, index: PathIndex): string {
  if (!index.takenByAny(path)) return path;
  const stem = path.replace(/\.md$/i, "");
  for (let n = 2; ; n += 1) {
    const p = `${stem}-${n}.md`;
    if (!index.takenByAny(p)) return p;
  }
}
