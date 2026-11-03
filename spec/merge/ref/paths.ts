/**
 * Path policy for app writes (docs/m3/merge-spec.md, section 6). Findings from spike S1:
 * GitHub stores NFC and NFD spellings, and names differing only by case, as separate files,
 * which collide on Apple file systems. New paths are normalised to NFC; clashes by case or normalisation (foldKey) are refused.
 */
export const MAX_NOTE_BYTES = 1024 * 1024;

export type PathBlock = "not-md" | "dot-segment" | "blocked-folder" | "bad-segment" | "control-char" | "too-large";

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
 * because `People/a.md` next to `people/b.md` also collides on a Mac.
 */
export class PathIndex {
  private byKey = new Map<string, string>();
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
    for (const k of [...PathIndex.prefixes(p), p]) if (!this.byKey.has(foldKey(k))) this.byKey.set(foldKey(k), k);
  }
  /** The first existing folder or file that clashes with p (same clash key, different bytes), if any. */
  clash(p: string): string | null {
    for (const k of [...PathIndex.prefixes(p), p]) {
      const e = this.byKey.get(foldKey(k));
      if (e !== undefined && e !== k) return e;
    }
    return null;
  }
  takenByAny(p: string): boolean {
    return this.byKey.has(foldKey(p));
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
