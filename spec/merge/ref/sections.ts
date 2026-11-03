/**
 * Block splitter for the merge spec (docs/m3/merge-spec.md, section 2).
 * A note is a list of blocks: optional frontmatter, optional preamble, then one block per ATX heading.
 * Joining the blocks gives back the exact input bytes.
 */
import { splitLines } from "./diff3.ts";

export interface Block {
  /** "fm" for frontmatter, "pre" for text before the first heading, else the heading line without its EOL and trailing spaces, plus "#<n>" (1-based occurrence). */
  key: string;
  lines: string[];
}

const ATX = /^ {0,3}#{1,6}(?:[ \t]|\r?\n|$)/;
const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/;
const FM_DELIM = /^---[ \t]*\r?\n?$/;
const FM_CLOSE = /^(?:---|\.\.\.)[ \t]*\r?\n?$/;

export function splitBlocks(text: string): Block[] {
  const lines = splitLines(text);
  const blocks: Block[] = [];
  let i = 0;
  if (lines.length > 0 && FM_DELIM.test(lines[0]!)) {
    let close = -1;
    for (let j = 1; j < lines.length; j += 1) {
      if (FM_CLOSE.test(lines[j]!)) {
        close = j;
        break;
      }
    }
    if (close > 0) {
      blocks.push({ key: "fm", lines: lines.slice(0, close + 1) });
      i = close + 1;
    }
  }
  const seen = new Map<string, number>();
  let cur: Block | null = null;
  let fence: { ch: string; len: number } | null = null;
  for (; i < lines.length; i += 1) {
    const line = lines[i]!;
    if (fence) {
      const m = /^ {0,3}(`+|~+)[ \t]*\r?\n?$/.exec(line);
      if (m && m[1]![0] === fence.ch && m[1]!.length >= fence.len) fence = null;
    } else {
      const f = FENCE_OPEN.exec(line);
      if (f) fence = { ch: f[1]![0]!, len: f[1]!.length };
      else if (ATX.test(line)) {
        const head = line.replace(/\r?\n$/, "").replace(/[ \t]+$/, "");
        const n = (seen.get(head) ?? 0) + 1;
        seen.set(head, n);
        cur = { key: `${head}#${n}`, lines: [line] };
        blocks.push(cur);
        continue;
      }
    }
    if (!cur) {
      cur = { key: "pre", lines: [] };
      blocks.push(cur);
    }
    cur.lines.push(line);
  }
  return blocks;
}

/** Concatenate blocks; a block that is not last and lacks a final EOL gets one (spec 5.4), using eol. */
export function joinBlocks(blocks: readonly Block[], eol: string): string {
  let s = "";
  blocks.forEach((b, idx) => {
    let t = b.lines.join("");
    if (idx < blocks.length - 1 && t.length > 0 && !t.endsWith("\n")) t += eol;
    s += t;
  });
  return s;
}

export function detectEol(text: string): string {
  const crlf = (text.match(/\r\n/g) ?? []).length;
  const lf = (text.match(/\n/g) ?? []).length - crlf;
  return crlf > lf ? "\r\n" : "\n";
}
