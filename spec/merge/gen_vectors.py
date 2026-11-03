#!/usr/bin/env python3
"""Generates vectors.json and plan-vectors.json. Every expected value here is written by hand
from docs/m3/merge-spec.md; nothing is computed by the TypeScript code. Fake demo content only."""
import json, unicodedata

def J(*lines):
    return "\n".join(lines) + "\n"

P = J("---", "title: Demo Person", "type: person", "updated: 2026-10-01", "---",
      "# Demo Person", "",
      "## Compiled Truth", "", "Works at Demo Co.", "Likes tea.", "Lives in Demo City.", "",
      "## Timeline", "", "- 2026-09-01 met at demo event", "- 2026-10-01 follow-up call", "",
      "## See Also", "", "- [[demo-company]]")

def r(s, old, new, count=1):
    assert s.count(old) >= 1, old
    return s.replace(old, new, count)

TL_END = "- 2026-10-01 follow-up call\n"
V = []
def m(id, title, base, mine, theirs, kind, content, copy=None, reason=None, clashes=None, unions=None, options=None, spec=""):
    v = {"id": id, "title": title, "spec": spec, "base": base, "mine": mine, "theirs": theirs,
         "expect": {"kind": kind, "content": content, "copy": copy}}
    if reason: v["expect"]["reason"] = reason
    if clashes is not None: v["expect"]["clashes"] = clashes
    if unions is not None: v["expect"]["unions"] = unions
    if options: v["options"] = options
    V.append(v)

tea = r(P, "Likes tea.", "Likes green tea.")
bot = r(P, TL_END, TL_END + "- 2026-11-02 bot: new email thread\n")
m("M01", "Both sides made the identical edit", P, tea, tea, "same", tea, spec="5.1")
m("M02", "Only mine changed", P, tea, P, "take-mine", tea, spec="5.1")
m("M03", "Only theirs changed", P, P, bot, "take-theirs", bot, spec="5.1")
m("M04", "Different sections", P, tea, bot, "merged", r(bot, "Likes tea.", "Likes green tea."), unions=0, spec="5.2")
mine = r(P, "Works at Demo Co.", "Works at Demo Co. (CTO)")
th = r(P, "Lives in Demo City.", "Lives in Demo Town.")
m("M05", "Same section, lines with a stable line between", P, mine, th, "merged",
  r(mine, "Lives in Demo City.", "Lives in Demo Town."), unions=0, spec="4")
m("M06", "Same section, adjacent lines: conflict (like git)", P, mine, tea, "conflict", tea, copy=mine,
  reason="same-lines", clashes=["## Compiled Truth#1"], spec="4")
m("M07", "Same line, different text: conflict", P, tea, r(P, "Likes tea.", "Likes coffee."), "conflict",
  r(P, "Likes tea.", "Likes coffee."), copy=tea, reason="same-lines", clashes=["## Compiled Truth#1"], spec="4")
mineTL = r(P, TL_END, TL_END + "- 2026-11-03 coffee with demo person\n")
m("M08", "Both append to Timeline at the same point: theirs then mine", P, mineTL, bot, "merged",
  r(P, TL_END, TL_END + "- 2026-11-02 bot: new email thread\n- 2026-11-03 coffee with demo person\n"),
  unions=1, spec="4.3")
same_line = "- 2026-11-02 call\n"
m("M09", "Both insert the same line, mine also edits another section", P,
  r(r(P, TL_END, TL_END + same_line), "Likes tea.", "Likes green tea."), r(P, TL_END, TL_END + same_line), "merged",
  r(r(P, TL_END, TL_END + same_line), "Likes tea.", "Likes green tea."), unions=0, spec="5.2")
fm = r(P, "updated: 2026-10-01", "updated: 2026-11-02")
m("M10", "Bot bumps frontmatter, mine edits body", P, tea, fm, "merged", r(fm, "Likes tea.", "Likes green tea."), unions=0, spec="2.1")
m("M11", "Both change the same frontmatter key: conflict", P, r(P, "type: person", "type: friend"), r(P, "type: person", "type: contact"),
  "conflict", r(P, "type: person", "type: contact"), copy=r(P, "type: person", "type: friend"), reason="same-lines", clashes=["fm"], spec="2.1")
HR = J("# Meeting notes", "", "Intro line", "", "---", "", "Part two line", "", "---", "", "Part three line")
m("M12", "Thematic break --- in the body is not frontmatter", HR, r(HR, "Part three line", "Part three line, edited"),
  r(HR, "Intro line", "Intro line, edited"), "merged", r(r(HR, "Part three line", "Part three line, edited"), "Intro line", "Intro line, edited"), unions=0, spec="2.1")
DUP = J("# Demo Weekly", "", "## Meeting", "", "- item one", "", "## Meeting", "", "- item two")
m("M13", "Duplicate headings are keyed by occurrence", DUP, r(DUP, "- item two", "- item two (done)"), r(DUP, "- item one", "- item one (moved)"),
  "merged", r(r(DUP, "- item two", "- item two (done)"), "- item one", "- item one (moved)"), unions=0, spec="2.3")
FEN = J("# Script note", "", "## Setup", "", "```bash", "# install step", "echo hi", "npm install", "```", "", "## Usage", "", "run it")
m("M14", "# inside a code fence is not a heading", FEN, r(FEN, "# install step", "# install step (v2)"), r(FEN, "npm install", "npm ci"),
  "merged", r(r(FEN, "# install step", "# install step (v2)"), "npm install", "npm ci"), unions=0, spec="2.2")
m("M15", "Mine adds a section at the end, theirs edits another", P, P + "\n## Notes\n\nmine note\n", tea, "merged",
  tea + "\n## Notes\n\nmine note\n", unions=0, spec="5.3")
NOTES = "## Notes\n\nmine note\n\n"
m("M16", "Mine adds a section mid-file, theirs adds one at the end: order kept", P, r(P, "## Timeline", NOTES + "## Timeline"),
  P + "\n## Links\n\n- [[demo-school]]\n", "merged", r(P, "## Timeline", NOTES + "## Timeline") + "\n## Links\n\n- [[demo-school]]\n", unions=0, spec="5.3")
m("M17", "Both add a section with the same heading: conflict", P, P + "\n## Notes\n\nmine\n", P + "\n## Notes\n\ntheirs\n", "conflict",
  P + "\n## Notes\n\ntheirs\n", copy=P + "\n## Notes\n\nmine\n", reason="same-lines", clashes=["## Notes#1"], spec="5.2")
TL = "## Timeline\n\n- 2026-09-01 met at demo event\n- 2026-10-01 follow-up call\n\n"
m("M18", "Mine deletes an untouched section, theirs edits another", P, r(P, TL, ""), bot.replace("Likes tea.", "Likes tea."),
  "conflict", bot, copy=r(P, TL, ""), reason="section-deleted", clashes=["## Timeline#1"], spec="5.2")
V[-1].update(title="Mine deletes a section theirs edited: conflict", id="M20")
m("M18", "Mine deletes an untouched section, theirs edits another", P, r(P, TL, ""), tea, "merged", r(tea, TL, ""), unions=0, spec="5.2")
m("M19", "Theirs deletes a section mine edited: conflict", P, mineTL, r(P, TL, ""), "conflict", r(P, TL, ""), copy=mineTL,
  reason="section-deleted", clashes=["## Timeline#1"], spec="5.2")
m("M21", "Note deleted on GitHub, edited on the phone", P, tea, None, "conflict", None, copy=tea, reason="deleted-remotely", spec="5.1")
m("M22", "Deleted on the phone, edited on GitHub: delete skipped", P, None, bot, "delete-skipped", bot, spec="5.1")
m("M23", "Both created the same path with different text", None, "# Idea\n\nmine\n", "# Idea\n\ntheirs\n", "conflict", "# Idea\n\ntheirs\n",
  copy="# Idea\n\nmine\n", reason="both-created", spec="5.1")
m("M24", "Both created the same path with identical text", None, "# Idea\n\nsame\n", "# Idea\n\nsame\n", "same", "# Idea\n\nsame\n", spec="5.1")
CR = "# CRLF note\r\n\r\n## A\r\na1\r\n\r\n## B\r\nb1\r\n"
m("M25", "CRLF line endings are kept", CR, CR.replace("a1", "a1 mine"), CR.replace("b1", "b1 theirs"), "merged",
  CR.replace("a1", "a1 mine").replace("b1", "b1 theirs"), unions=0, spec="1")
NF = P[:-1]
m("M26", "No final newline", NF, r(NF, "Likes tea.", "Likes green tea."), NF + "\n- [[demo-school]]", "merged",
  r(NF, "Likes tea.", "Likes green tea.") + "\n- [[demo-school]]", unions=0, spec="1")
JB = "# N\n\n## A\nx\n\n## B\ny\n"
m("M27", "Join adds a newline when a block without one is no longer last", JB, JB + "## C\nz\n", JB.replace("y\n", "y2"), "merged",
  "# N\n\n## A\nx\n\n## B\ny2\n## C\nz\n", unions=0, spec="5.4")
HE = J("---", "title: אדם לדוגמה", "---", "# אדם לדוגמה", "", "## תקציר", "", "עובד בחברה לדוגמה.", "גר בעיר לדוגמה.", "",
       "## ציר זמן", "", "- 2026-09-01 פגישה ראשונה \u200f(demo)")
m("M28", "Hebrew and bidi marks", HE, r(HE, "עובד בחברה לדוגמה.", "עובד בחברה לדוגמה, CTO."), HE + "- 2026-11-02 מייל \u200f(bot)\n",
  "merged", r(HE, "עובד בחברה לדוגמה.", "עובד בחברה לדוגמה, CTO.") + "- 2026-11-02 מייל \u200f(bot)\n", unions=0, spec="1")
PRE = J("Quick note line one", "line two", "line three")
m("M29", "No headings at all: one preamble block, line merge", PRE, r(PRE, "line one", "line one!"), r(PRE, "line three", "line three!"),
  "merged", "Quick note line one!\nline two\nline three!\n", unions=0, spec="2")
SA = "## See Also\n\n- [[demo-company]]\n"
REORD = r(P, TL + SA, SA + "\n" + TL[:-1])
m("M30", "Theirs reorders sections, mine edits another: theirs order kept", P, tea, REORD, "merged",
  r(REORD, "Likes tea.", "Likes green tea."), unions=0, spec="5.3")
m("M31", "Mine renames a heading theirs did not touch", P, r(P, "## See Also", "## Related"), tea, "merged",
  r(tea, "## See Also", "## Related"), unions=0, spec="5.3")
m("M32", "Empty base file, both add a section: mine-only block goes first", "", "## A\nmine\n", "## B\ntheirs\n", "merged",
  "## A\nmine\n## B\ntheirs\n", unions=0, spec="5.3")
m("M33", "Trailing space counts as a change", P, tea, r(P, "Likes tea.", "Likes tea. "), "conflict", r(P, "Likes tea.", "Likes tea. "),
  copy=tea, reason="same-lines", clashes=["## Compiled Truth#1"], spec="4")
LS = J("# List", "", "- a", "- b", "- c")
m("M34", "Both insert at the same point mid-list", LS, r(LS, "- a\n", "- a\n- m\n"), r(LS, "- a\n", "- a\n- t\n"), "merged",
  J("# List", "", "- a", "- t", "- m", "- b", "- c"), unions=1, spec="4.3")
m("M35", "Union turned off: same-point inserts conflict", P, mineTL, bot, "conflict", bot, copy=mineTL, reason="same-lines",
  clashes=["## Timeline#1"], options={"unionInsertions": False}, spec="4.3")
m("M36", "Mine edits a line, theirs inserts right after it: conflict", P, r(P, "- 2026-10-01 follow-up call", "- 2026-10-01 follow-up call (done)"),
  bot, "conflict", bot, copy=r(P, "- 2026-10-01 follow-up call", "- 2026-10-01 follow-up call (done)"), reason="same-lines",
  clashes=["## Timeline#1"], spec="4")
m("M37", "Frontmatter not closed: whole file is preamble", "---\ntitle: x\nbody\n", "---\ntitle: x\nbody!\n", "---\ntitle: y\nbody\n",
  "conflict", "---\ntitle: y\nbody\n", copy="---\ntitle: x\nbody!\n", reason="same-lines", clashes=["pre"], spec="2.1")
m("M38", "Setext heading is body text, not a section", J("Title", "=====", "", "one", "", "two", "", "three"),
  J("Title", "=====", "", "one!", "", "two", "", "three"), J("Title", "=====", "", "one", "", "two", "", "three!"), "merged",
  J("Title", "=====", "", "one!", "", "two", "", "three!"), unions=0, spec="2.3")
m("M40", "Both rename the same heading differently: conflict", "# A\n\nbody\n", "# B\n\nbody\n", "# C\n\nbody\n", "conflict",
  "# C\n\nbody\n", copy="# B\n\nbody\n", reason="heading-renamed", clashes=["# A#1"], spec="5.2")
m("M41", "Both delete the same section, nothing else: clean", P, r(P, TL, ""), r(tea, TL, ""), "merged", r(tea, TL, ""), unions=0, spec="5.2")
NOFM = J("# Quick idea", "", "first line", "", "second line")
m("M42", "Theirs adds frontmatter, mine edits the body: whole-file line merge", NOFM, r(NOFM, "second line", "second line, edited"),
  "---\ntype: idea\n---\n" + NOFM, "merged", "---\ntype: idea\n---\n" + r(NOFM, "second line", "second line, edited"), unions=0, spec="5.5")
m("M43", "Mine removes frontmatter, theirs edits a frontmatter line: conflict", P, r(P, "---\ntitle: Demo Person\ntype: person\nupdated: 2026-10-01\n---\n", ""),
  fm, "conflict", fm, copy=r(P, "---\ntitle: Demo Person\ntype: person\nupdated: 2026-10-01\n---\n", ""), reason="same-lines", clashes=["(file)"], spec="5.5")
# Per-section conflicts (Itamar, 3 Nov 13:16): clean sections merge, only clashing sections keep theirs; copy = all of mine.
FOLLOW = "- 2026-10-01 follow-up call"
m44_mine = r(r(P, "Likes tea.", "Likes green tea."), TL_END, TL_END + "- 2026-11-03 coffee with demo person\n")
m44_theirs = r(r(P, "Likes tea.", "Likes coffee."), "- [[demo-company]]", "- [[demo-company]]\n- [[demo-school]]")
m("M44", "Per-section conflict: clashing section keeps theirs, other sections merge", P, m44_mine, m44_theirs, "conflict",
  r(r(r(P, "Likes tea.", "Likes coffee."), TL_END, TL_END + "- 2026-11-03 coffee with demo person\n"), "- [[demo-company]]", "- [[demo-company]]\n- [[demo-school]]"),
  copy=m44_mine, reason="same-lines", clashes=["## Compiled Truth#1"], unions=0, spec="5.2")
m45_mine = r(r(P, TL, ""), "Likes tea.", "Likes green tea.")
m("M45", "Mine deletes a section theirs edited, and edits another: theirs' section kept, my other edit merged", P, m45_mine, bot, "conflict",
  r(bot, "Likes tea.", "Likes green tea."), copy=m45_mine, reason="section-deleted", clashes=["## Timeline#1"], unions=0, spec="5.2")
m46_mine = r(mineTL, "Likes tea.", "Likes green tea.")
m("M46", "Theirs deletes a section mine edited, mine edits another: section stays deleted, my other edit merged", P, m46_mine, r(P, TL, ""),
  "conflict", r(r(P, TL, ""), "Likes tea.", "Likes green tea."), copy=m46_mine, reason="section-deleted", clashes=["## Timeline#1"], unions=0, spec="5.2")
m47_mine = r(P, "Likes tea.", "Likes green tea.") + "\n## Notes\n\nmine\n"
m("M47", "Both add the same heading, mine also edits another section", P, m47_mine, P + "\n## Notes\n\ntheirs\n", "conflict",
  r(P, "Likes tea.", "Likes green tea.") + "\n## Notes\n\ntheirs\n", copy=m47_mine, reason="same-lines", clashes=["## Notes#1"], unions=0, spec="5.2")
m48_mine = r(r(r(P, "Likes tea.", "Likes green tea."), FOLLOW, FOLLOW + " (mine)"), "- [[demo-company]]", "- [[demo-company-renamed]]")
m48_theirs = r(r(fm, "Likes tea.", "Likes coffee."), FOLLOW, FOLLOW + " (bot)")
m("M48", "Two clashing sections, plus a clean edit on each side", P, m48_mine, m48_theirs, "conflict",
  r(m48_theirs, "- [[demo-company]]", "- [[demo-company-renamed]]"), copy=m48_mine, reason="same-lines",
  clashes=["## Compiled Truth#1", "## Timeline#1"], unions=0, spec="5.2")
RN = J("# A", "", "body", "", "## Other", "", "x")
m("M49", "Both rename one heading differently, plus a clean edit: whole note keeps theirs", RN, r(RN, "# A", "# B"),
  r(r(RN, "# A", "# C"), "\nx\n", "\nx2\n"), "conflict", r(r(RN, "# A", "# C"), "\nx\n", "\nx2\n"), copy=r(RN, "# A", "# B"),
  reason="heading-renamed", clashes=["# A#1"], spec="5.2")
m("M39", "Both deleted the file", P, None, None, "same", None, spec="5.1")

# Gemini review findings F-02 and F-06 (approved by Itamar, 3 Nov 2026).
def CAT(*parts): return {"$concat": list(parts)}
def REP(s, n): return {"$repeat": [s, n]}
def X(v):  # expand for hand checks only
    if v is None or isinstance(v, str): return v
    if "$repeat" in v: return v["$repeat"][0] * v["$repeat"][1]
    return "".join(X(x) for x in v["$concat"])
pb, pm, pt = (J("intro base", "# Section 1", "PRECIOUS LINE", "footer"), J("intro mine", "PRECIOUS LINE", "# Section 1", "footer"),
              J("intro theirs", "# Section 1", "PRECIOUS LINE", "footer"))
m("M50", "A line in base, mine and theirs is never dropped: mine moved it into a clashing block, so the note keeps theirs",
  pb, pm, pt, "conflict", pt, copy=pm, reason="unsafe-merge", clashes=["pre"], spec="5.5")
hm = CAT("# A\n", REP("# M\n", 2000))
m("M51", "Work budget: more than 2000 blocks on one side is too large (conflict, note keeps theirs)", "# A\n", hm, "# A\nx\n",
  "conflict", "# A\nx\n", copy=hm, reason="too-large", spec="3")
def sec(i, a, z): return [f"# S{i}\n"] + ([a] if a else []) + [REP("x\n", 1200)] + ([z] if z else [])
def three(n, a=None, z=None): return CAT(*[x for i in range(n) for x in sec(i, a, z)])
m("M52", "Work budget: two sections of 1201x1203 cells per side (5.8M in total) still merge", three(2), three(2, "m\n", "m2\n"),
  three(2, "t\n", "t2\n"), "merged", CAT(*[x for i in range(2) for x in [f"# S{i}\n", "t\n", "m\n", REP("x\n", 1200), "t2\n", "m2\n"]]),
  unions=4, spec="3")
m("M53", "Work budget: three such sections (8.7M cells in total, each under the 4M per-diff limit) are too large", three(3),
  three(3, "m\n", "m2\n"), three(3, "t\n", "t2\n"), "conflict", three(3, "t\n", "t2\n"), copy=three(3, "m\n", "m2\n"), reason="too-large", spec="3")

# M18 conflict variant above was renamed M20; check ids are unique and sort them.
V.sort(key=lambda v: v["id"])
assert len({v["id"] for v in V}) == len(V)

# ---------------- planner vectors ----------------
C = J("---", "title: Demo Company", "type: company", "---", "# Demo Company", "", "## Compiled Truth", "", "A demo company.")
N = J("# Inbox note", "", "remember the demo milk")
BASE = {"people/demo-person.md": P, "companies/demo-company.md": C, "_inbox/2026-11-01-note.md": N}
DEV, T, ST = "spike-mac", "2026-11-03T10:30:00Z", "20261103-103000"
def hdr(path):
    return f'---\ntype: conflict\nconflict_of: {json.dumps(path, ensure_ascii=False)}\ndevice: "{DEV}"\ncreated: "{T}"\n---\n'
def W(p, c): return {"path": p, "content": c}
def D(p): return {"path": p, "delete": True}
PV = []
def pv(id, title, ops, entries, attention=(), kept=(), noops=(), base=None, theirs=None, renames=None, spec=""):
    v = {"id": id, "title": title, "spec": spec, "baseTree": base if base is not None else BASE,
         "theirsTree": theirs if theirs is not None else BASE, "ops": ops, "device": DEV, "time": T,
         "expect": {"entries": sorted(entries, key=lambda e: e["path"].encode("utf-16-be")), "attention": list(attention),
                    "kept": list(kept), "noops": list(noops)}}
    if renames: v["renames"] = renames
    PV.append(v)
def tw(**kw):
    t = dict(BASE)
    for k, v in kw.items():
        t[k.replace("__", "/").replace("_DOT_", ".")] = v
    return t
def tree(*pairs, drop=()):
    t = {k: v for k, v in BASE.items() if k not in drop}
    for k, v in pairs: t[k] = v
    return t
NP = "_inbox/2026-11-01-note.md"
pv("P01", "Clean delete moves the note to _trash in the same commit", [{"kind": "delete", "path": NP}],
   [D(NP), W("_trash/" + NP, N)], spec="7.3")
pv("P02", "Delete of a note already gone on GitHub is a no-op (S1: never send sha null for a missing path)",
   [{"kind": "delete", "path": NP}], [], noops=[0], theirs=tree(drop=[NP]), spec="7.3")
pv("P03", "Delete of a note edited on GitHub is skipped", [{"kind": "delete", "path": NP}], [],
   attention=[{"path": NP, "reason": "delete-skipped"}], theirs=tree((NP, N + "bot line\n")), spec="7.3")
pv("P04", "Trash path taken by other text: -2", [{"kind": "delete", "path": NP}],
   [D(NP), W("_trash/_inbox/2026-11-01-note-2.md", N)], theirs=tree(("_trash/" + NP, "older\n")), spec="7.3")
pv("P05", "Trash path already holds the same text: delete only", [{"kind": "delete", "path": NP}], [D(NP)],
   theirs=tree(("_trash/" + NP, N)), spec="7.3")
pv("P06", "Delete follows a remote rename (same text at one new path)", [{"kind": "delete", "path": NP}],
   [D("_inbox/renamed.md"), W("_trash/_inbox/renamed.md", N)], theirs=tree(("_inbox/renamed.md", N), drop=[NP]), spec="7.2")
RP = "people/demo-person-renamed.md"
pv("P07", "Edit follows a rename reported by compare, and merges with theirs", [{"kind": "edit", "path": "people/demo-person.md", "content": tea}],
   [W(RP, r(bot, "Likes tea.", "Likes green tea."))], theirs=tree((RP, bot), drop=["people/demo-person.md"]),
   renames={"people/demo-person.md": RP}, spec="7.2")
CP = f"_inbox/conflict-people-demo-person-{ST}.md"
pv("P08", "Edit of a note deleted on GitHub: copy only, nothing else written", [{"kind": "edit", "path": "people/demo-person.md", "content": tea}],
   [W(CP, hdr("people/demo-person.md") + tea)], attention=[{"path": "people/demo-person.md", "reason": "conflict-copy", "copy": CP, "detail": "deleted-remotely"}],
   theirs=tree(drop=["people/demo-person.md"]), spec="6.1")
pv("P09", "Conflict in the only changed section: note keeps theirs there, mine goes to a copy", [{"kind": "edit", "path": "people/demo-person.md", "content": tea}],
   [W(CP, hdr("people/demo-person.md") + tea)],
   attention=[{"path": "people/demo-person.md", "reason": "conflict-copy", "copy": CP, "detail": "same-lines"}],
   theirs=tree(("people/demo-person.md", r(P, "Likes tea.", "Likes coffee."))), spec="6.1")
pv("P10", "Copy name already taken: -2", [{"kind": "edit", "path": "people/demo-person.md", "content": tea}],
   [W(CP.replace(".md", "-2.md"), hdr("people/demo-person.md") + tea)],
   attention=[{"path": "people/demo-person.md", "reason": "conflict-copy", "copy": CP.replace(".md", "-2.md"), "detail": "same-lines"}],
   theirs=tree(("people/demo-person.md", r(P, "Likes tea.", "Likes coffee.")), (CP, "earlier copy\n")), spec="6.1")
nfd = unicodedata.normalize("NFD", "people/Amélie.md"); nfc = unicodedata.normalize("NFC", nfd)
assert nfd != nfc
pv("P11", "New path typed as NFD is written as NFC", [{"kind": "create", "path": nfd, "content": "# Amélie\n"}],
   [W(nfc, "# Amélie\n")], spec="6.2")
pv("P12", "Edit of an existing NFD-named note keeps its exact bytes", [{"kind": "edit", "path": nfd, "content": "# Amélie\n\nedited\n"}],
   [W(nfd, "# Amélie\n\nedited\n")], base=tree((nfd, "# Amélie\n")), theirs=tree((nfd, "# Amélie\n")), spec="6.2")
pv("P13", "Create whose NFC form matches an existing NFD name: blocked", [{"kind": "create", "path": nfc, "content": "# A\n"}], [],
   attention=[{"path": nfc, "reason": "case-clash", "detail": nfd}], kept=[0], theirs=tree((nfd, "# Amélie\n")), spec="6.3")
pv("P14", "Create differing only by case from an existing note: blocked", [{"kind": "create", "path": "people/Demo-Person.md", "content": "# X\n"}], [],
   attention=[{"path": "people/Demo-Person.md", "reason": "case-clash", "detail": "people/demo-person.md"}], kept=[0], spec="6.3")
pv("P15", "Create in a folder differing only by case: blocked", [{"kind": "create", "path": "People/new-person.md", "content": "# X\n"}], [],
   attention=[{"path": "People/new-person.md", "reason": "case-clash", "detail": "people/"}], kept=[0], spec="6.3")
pv("P16", "Two creates in one batch that clash by case: second blocked", [{"kind": "create", "path": "_inbox/Idea.md", "content": "# A\n"},
   {"kind": "create", "path": "_inbox/idea.md", "content": "# B\n"}], [W("_inbox/Idea.md", "# A\n")],
   attention=[{"path": "_inbox/idea.md", "reason": "case-clash", "detail": "_inbox/Idea.md"}], kept=[1], spec="6.3")
pv("P17", "Create on a path that already exists on GitHub: conflict copy", [{"kind": "create", "path": "companies/demo-company.md", "content": "# Mine\n"}],
   [W(f"_inbox/conflict-companies-demo-company-{ST}.md", hdr("companies/demo-company.md") + "# Mine\n")],
   attention=[{"path": "companies/demo-company.md", "reason": "conflict-copy", "copy": f"_inbox/conflict-companies-demo-company-{ST}.md", "detail": "both-created"}], spec="5.1")
blocked = [("private/x.md", "blocked-folder"), ("notes/.obsidian/x.md", "dot-segment"), ("notes/x.txt", "not-md"), ("_capture/x.md", "blocked-folder"),
           ("people/../x.md", "bad-segment"), ("/abs.md", "bad-segment"), ("Private/y.md", "blocked-folder"), ("a\tb.md", "control-char")]
pv("P18", "Path policy blocks", [{"kind": "create", "path": p, "content": "# x\n"} for p, _ in blocked], [],
   attention=[{"path": p, "reason": "blocked:" + why} for p, why in blocked], kept=list(range(len(blocked))), spec="6.4")
pv("P19", "Over 1 MiB: blocked", [{"kind": "create", "path": "_inbox/big.md", "content": {"$repeat": ["a", 1048577]}}], [],
   attention=[{"path": "_inbox/big.md", "reason": "blocked:too-large"}], kept=[0], spec="6.4")
pv("P20", "Edit that matches GitHub already: no-op", [{"kind": "edit", "path": "people/demo-person.md", "content": tea}], [], noops=[0],
   theirs=tree(("people/demo-person.md", tea)), spec="7")
pv("P21", "Mixed batch: clean edit, conflict, delete in one commit", [
    {"kind": "edit", "path": "companies/demo-company.md", "content": C.replace("A demo company.", "A demo company in Demo City.")},
    {"kind": "edit", "path": "people/demo-person.md", "content": tea},
    {"kind": "delete", "path": NP}],
   [W("companies/demo-company.md", C.replace("A demo company.", "A demo company in Demo City.")), W(CP, hdr("people/demo-person.md") + tea),
    D(NP), W("_trash/" + NP, N)],
   attention=[{"path": "people/demo-person.md", "reason": "conflict-copy", "copy": CP, "detail": "same-lines"}],
   theirs=tree(("people/demo-person.md", r(P, "Likes tea.", "Likes coffee."))), spec="7")
pv("P24", "Per-section conflict: merged note and copy land in one commit", [{"kind": "edit", "path": "people/demo-person.md", "content": m44_mine}],
   [W("people/demo-person.md", r(r(r(P, "Likes tea.", "Likes coffee."), TL_END, TL_END + "- 2026-11-03 coffee with demo person\n"), "- [[demo-company]]", "- [[demo-company]]\n- [[demo-school]]")),
    W(CP, hdr("people/demo-person.md") + m44_mine)],
   attention=[{"path": "people/demo-person.md", "reason": "conflict-copy", "copy": CP, "detail": "same-lines"}],
   theirs=tree(("people/demo-person.md", m44_theirs)), spec="7")
pv("P22", "Clean merge with theirs is written in full", [{"kind": "edit", "path": "people/demo-person.md", "content": tea}],
   [W("people/demo-person.md", r(bot, "Likes tea.", "Likes green tea."))], theirs=tree(("people/demo-person.md", bot)), spec="7")
pv("P23", "Path with quotes gets an escaped copy header", [{"kind": "edit", "path": 'notes/say "hi".md', "content": "# T\n\nmine\n"}],
   [W(f'_inbox/conflict-notes-say "hi"-{ST}.md', hdr('notes/say "hi".md') + "# T\n\nmine\n")],
   attention=[{"path": 'notes/say "hi".md', "reason": "conflict-copy", "copy": f'_inbox/conflict-notes-say "hi"-{ST}.md', "detail": "same-lines"}],
   base=tree(('notes/say "hi".md', "# T\n\nbase\n")), theirs=tree(('notes/say "hi".md', "# T\n\ntheirs\n")), spec="6.1")

# S3 findings F1 and F2 (approved by Itamar, 3 Nov 2026).
TW = tree(("notes/\u01c5.md", "# Dz\n\nbase\n"), ("notes/\u01c6.md", "# dz\n\nbase\n"))
pv("P25", "Twin cleanup: edit one case twin and delete the other in one batch (a delete creates no file)",
   [{"kind": "edit", "path": "notes/\u01c5.md", "content": "# Dz\n\nedited\n"}, {"kind": "delete", "path": "notes/\u01c6.md"}],
   [W("notes/\u01c5.md", "# Dz\n\nedited\n"), D("notes/\u01c6.md"), W("_trash/notes/\u01c6.md", "# dz\n\nbase\n")],
   base=TW, theirs=TW, spec="7.6")
pv("P26", "Full case fold: STRASSE clashes with Straße (one file on APFS)", [{"kind": "create", "path": "notes/STRASSE.md", "content": "# X\n"}], [],
   attention=[{"path": "notes/STRASSE.md", "reason": "case-clash", "detail": "notes/Stra\u00dfe.md"}], kept=[0],
   theirs=tree(("notes/Stra\u00dfe.md", "# S\n")), spec="6.3")
pv("P27", "Full case fold: final sigma, in a file name and in a folder name", [
    {"kind": "create", "path": "notes/\u03bf\u03b4\u03bf\u03c3.md", "content": "# X\n"},
    {"kind": "create", "path": "\u03bf\u03b4\u03bf\u03c3/y.md", "content": "# Y\n"}], [],
   attention=[{"path": "notes/\u03bf\u03b4\u03bf\u03c3.md", "reason": "case-clash", "detail": "notes/\u03bf\u03b4\u03bf\u03c2.md"},
              {"path": "\u03bf\u03b4\u03bf\u03c3/y.md", "reason": "case-clash", "detail": "\u039f\u0394\u039f\u03a3/"}], kept=[0, 1],
   theirs=tree(("notes/\u03bf\u03b4\u03bf\u03c2.md", "# S\n"), ("\u039f\u0394\u039f\u03a3/x.md", "# X\n")), spec="6.3")
pv("P28", "Not a clash: dotless \u0131 vs I, and \u0130 vs plain i, are different files on APFS", [
    {"kind": "create", "path": "notes/\u0131dea.md", "content": "# A\n"},
    {"kind": "create", "path": "notes/izmir.md", "content": "# B\n"}],
   [W("notes/\u0131dea.md", "# A\n"), W("notes/izmir.md", "# B\n")],
   theirs=tree(("notes/Idea.md", "# I\n"), ("notes/\u0130zmir.md", "# Z\n")), spec="6.3")
pv("P29", "Not a clash: compatibility forms such as full-width \uff21 stay apart from A (as on APFS)",
   [{"kind": "create", "path": "notes/\uff21.md", "content": "# A\n"}], [W("notes/\uff21.md", "# A\n")],
   theirs=tree(("notes/A.md", "# a\n")), spec="6.3")

# Gemini review findings F-01 to F-07 (approved by Itamar, 3 Nov 2026).
TM = {"notes/a.md": "tmpl\n", "notes/b.md": "tmpl\n"}
CA = "_inbox/conflict-notes-a-" + ST + ".md"
pv("P30", "Two base notes with one text, one renamed and one deleted on GitHub: no rename is guessed, the edit goes to a copy",
   [{"kind": "edit", "path": "notes/a.md", "content": "tmpl\nEDIT A\n"}, {"kind": "delete", "path": "notes/b.md"}],
   [W(CA, hdr("notes/a.md") + "tmpl\nEDIT A\n")],
   attention=[{"path": "notes/a.md", "reason": "conflict-copy", "copy": CA, "detail": "deleted-remotely"}], noops=[1],
   base=TM, theirs={"notes/r.md": "tmpl\n"}, spec="7.2")
pv("P31", "Outbox coalescing: edit, then edit back to the base text, is one no-op", [
    {"kind": "edit", "path": NP, "content": N + "edit1\n"}, {"kind": "edit", "path": NP, "content": N}], [], noops=[0, 1], spec="7.1")
pv("P32", "Outbox coalescing: delete then create on one path is one edit (replace)", [
    {"kind": "delete", "path": NP}, {"kind": "create", "path": NP, "content": "# New\n"}], [W(NP, "# New\n")], spec="7.1")
pv("P33", "Outbox coalescing: create then delete is nothing", [
    {"kind": "create", "path": "_inbox/tmp.md", "content": "# T\n"}, {"kind": "edit", "path": "_inbox/tmp.md", "content": "# T2\n"},
    {"kind": "delete", "path": "_inbox/tmp.md"}], [], noops=[0, 1, 2], spec="7.1")
pv("P34", "Outbox coalescing: create then edit is one create with the last text; edit then delete is one delete", [
    {"kind": "create", "path": "_inbox/new.md", "content": "# N\n"}, {"kind": "edit", "path": NP, "content": N + "x\n"},
    {"kind": "edit", "path": "_inbox/new.md", "content": "# N2\n"}, {"kind": "delete", "path": NP}],
   [W("_inbox/new.md", "# N2\n"), D(NP), W("_trash/" + NP, N)], spec="7.1")
RT = {"a.md": "# A\n", "r.md": "# R\n"}
CR = "_inbox/conflict-r-" + ST + ".md"
pv("P35", "Two ops resolve to one target (compare renamed a.md onto r.md): the first wins, the second goes to a copy",
   [{"kind": "edit", "path": "r.md", "content": "# R2\n"}, {"kind": "edit", "path": "a.md", "content": "# A2\n"}],
   [W("r.md", "# R2\n"), W(CR, hdr("r.md") + "# A2\n")],
   attention=[{"path": "r.md", "reason": "conflict-copy", "copy": CR, "detail": "same-target"}],
   base=RT, theirs={"r.md": "# R\n"}, renames={"a.md": "r.md"}, spec="7.1")
pv("P36", "Two ops resolve to one target: a second delete is skipped",
   [{"kind": "edit", "path": "r.md", "content": "# R2\n"}, {"kind": "delete", "path": "a.md"}], [W("r.md", "# R2\n")],
   attention=[{"path": "r.md", "reason": "delete-skipped", "detail": "same-target"}],
   base=RT, theirs={"r.md": "# R\n"}, renames={"a.md": "r.md"}, spec="7.1")
pv("P37", "Delete of an NFD-named note: the _trash copy is written in NFC", [{"kind": "delete", "path": nfd}],
   [D(nfd), W("_trash/" + nfc, "# Am\u00e9lie\n")], base=tree((nfd, "# Am\u00e9lie\n")), theirs=tree((nfd, "# Am\u00e9lie\n")), spec="6.2")
BIG = REP("a", 600000)
SB = "# A\nx\n# B\ny\n"
pv("P38", "Merge result over 1 MiB: nothing written, theirs stays, the op stays in the outbox",
   [{"kind": "edit", "path": "n.md", "content": CAT("# A\nx\n", BIG, "\n# B\ny\n")}], [],
   attention=[{"path": "n.md", "reason": "blocked:too-large"}], kept=[0],
   base={"n.md": SB}, theirs={"n.md": CAT(SB, BIG, "\n")}, spec="6.4")
pv("P39", "Conflict copy over 1 MiB (mine plus the copy header): no copy, the op stays in the outbox",
   [{"kind": "edit", "path": "n.md", "content": REP("a", 1048570)}], [],
   attention=[{"path": "n.md", "reason": "blocked:too-large"}], kept=[0], base={"n.md": "a\n"}, theirs={}, spec="6.4")
pv("P40", "Delete of a note over 1 MiB already on GitHub: its _trash copy would be over the limit, so the delete waits",
   [{"kind": "delete", "path": "n.md"}], [], attention=[{"path": "n.md", "reason": "blocked:too-large"}], kept=[0],
   base={"n.md": REP("a", 1048577)}, theirs={"n.md": REP("a", 1048577)}, spec="6.4")
pv("P41", "A file and a folder with one name: refused both ways", [
    {"kind": "create", "path": "notes/foo.md/bar.md", "content": "# B\n"}, {"kind": "create", "path": "notes/Proj.md", "content": "# P\n"}], [],
   attention=[{"path": "notes/foo.md/bar.md", "reason": "case-clash", "detail": "notes/foo.md"},
              {"path": "notes/Proj.md", "reason": "case-clash", "detail": "notes/proj.md/"}], kept=[0, 1],
   base={"notes/foo.md": "# F\n"}, theirs={"notes/foo.md": "# F\n", "notes/proj.md/plan.md": "# P\n"}, spec="6.3")
C1 = "_Inbox/conflict-n-" + ST + ".md"
pv("P42", "Conflict copy uses the inbox folder spelling already in the batch (_Inbox), not a second _inbox", [
    {"kind": "create", "path": "_Inbox/new.md", "content": "# New\n"}, {"kind": "edit", "path": "n.md", "content": "m\n"}],
   [W("_Inbox/new.md", "# New\n"), W(C1, hdr("n.md") + "m\n")],
   attention=[{"path": "n.md", "reason": "conflict-copy", "copy": C1, "detail": "same-lines"}],
   base={"n.md": "a\n"}, theirs={"n.md": "t\n"}, spec="6.1")
pv("P43", "Conflict copy uses the inbox folder spelling already on GitHub (_Inbox)", [{"kind": "edit", "path": "n.md", "content": "m\n"}],
   [W(C1, hdr("n.md") + "m\n")], attention=[{"path": "n.md", "reason": "conflict-copy", "copy": C1, "detail": "same-lines"}],
   base={"n.md": "a\n", "_Inbox/old.md": "# O\n"}, theirs={"n.md": "t\n", "_Inbox/old.md": "# O\n"}, spec="6.1")
TWF = {"People/a.md": "# A\n", "people/b.md": "# B\n"}
pv("P44", "Folder twins already on GitHub (People/, people/): a new note goes in neither", [
    {"kind": "create", "path": "people/c.md", "content": "# C\n"}, {"kind": "create", "path": "People/d.md", "content": "# D\n"}], [],
   attention=[{"path": "people/c.md", "reason": "case-clash", "detail": "People/"}, {"path": "People/d.md", "reason": "case-clash", "detail": "people/"}],
   kept=[0, 1], base=TWF, theirs=TWF, spec="6.3")
TWG = {"\u039f\u0394\u039f\u03a3/x.md": "# 1\n", "\u03bf\u03b4\u03bf\u03c2/x.md": "# 2\n"}
pv("P45", "Deleting two folder twins: both _trash copies go into one folder spelling", [
    {"kind": "delete", "path": "\u039f\u0394\u039f\u03a3/x.md"}, {"kind": "delete", "path": "\u03bf\u03b4\u03bf\u03c2/x.md"}],
   [D("\u039f\u0394\u039f\u03a3/x.md"), D("\u03bf\u03b4\u03bf\u03c2/x.md"), W("_trash/\u039f\u0394\u039f\u03a3/x.md", "# 1\n"),
    W("_trash/\u039f\u0394\u039f\u03a3/x-2.md", "# 2\n")], base=TWG, theirs=TWG, spec="6.3")
invis = ["notes/a\u200bb.md", "notes/\ufeffbom.md", "notes/soft\u00adhyphen.md", "notes/zw\u200dj.md", "notes/rtl\u200f.md", "notes/vs\ufe0f.md"]
pv("P46", "Invisible characters (Default_Ignorable_Code_Point) in a new path: blocked",
   [{"kind": "create", "path": p, "content": "# x\n"} for p in invis], [],
   attention=[{"path": p, "reason": "blocked:invisible-char"} for p in invis], kept=list(range(len(invis))), spec="6.4")
pv("P47", "An edit of a path the old base lacks is checked as a create (folder clash with People/ on GitHub)",
   [{"kind": "edit", "path": "people/c.md", "content": "# C\n"}], [],
   attention=[{"path": "people/c.md", "reason": "case-clash", "detail": "People/"}], kept=[0],
   base={"People/a.md": "# A\n"}, theirs={"People/a.md": "# A\n"}, spec="7.1")

# Follow-up review (review2) of F-01 and F-05, 3 Nov 2026.
IMP = "# Important Note\n"
TA = {"a.md": IMP, "_trash/a.md": IMP}
pv("P48", "A same-text _trash copy that the batch edits first does not count: the delete writes _trash/a-2.md",
   [{"kind": "edit", "path": "_trash/a.md", "content": "# Replaced\n"}, {"kind": "delete", "path": "a.md"}],
   [W("_trash/a.md", "# Replaced\n"), D("a.md"), W("_trash/a-2.md", IMP)], base=TA, theirs=TA, spec="7.3")
pv("P49", "A delete that relies on a same-text _trash copy claims it: a later edit of that copy goes to a conflict copy",
   [{"kind": "delete", "path": "a.md"}, {"kind": "edit", "path": "_trash/a.md", "content": "# Replaced\n"}],
   [D("a.md"), W(f"_inbox/conflict-_trash-a-{ST}.md", hdr("_trash/a.md") + "# Replaced\n")],
   attention=[{"path": "_trash/a.md", "reason": "conflict-copy", "copy": f"_inbox/conflict-_trash-a-{ST}.md", "detail": "same-target"}],
   base=TA, theirs=TA, spec="7.1, 7.3")
AMC, AMD = "people/Am\u00e9lie.md", "people/Ame\u0301lie.md"
pv("P50", "Edit with an NFD spelling, then delete, of an NFC note: one group on the base spelling, so the delete happens",
   [{"kind": "edit", "path": AMD, "content": "# Edit\n"}, {"kind": "delete", "path": AMC}],
   [D(AMC), W("_trash/" + AMC, "# Base\n")], base={AMC: "# Base\n"}, theirs={AMC: "# Base\n"}, spec="7.1")
pv("P51", "Two edits of one NFC note, the first spelled NFD: one edit of the base spelling with the last text",
   [{"kind": "edit", "path": AMD, "content": "# V1\n"}, {"kind": "edit", "path": AMC, "content": "# V2\n"}],
   [W(AMC, "# V2\n")], base={AMC: "# Base\n"}, theirs={AMC: "# Base\n"}, spec="7.1")
pv("P52", "Edit then delete of a path the old base lacks: counts as create then delete, so nothing",
   [{"kind": "edit", "path": "a.md", "content": "# Mine\n"}, {"kind": "delete", "path": "a.md"}], [], noops=[0, 1],
   base={}, theirs={"a.md": "# Theirs\n"}, spec="7.1")
TT = {"_trash/Notes/old.md": "# 1\n", "_trash/notes/sub/old2.md": "# 2\n", "notes/sub/x.md": "# X\n"}
pv("P53", "Folder twins nested in _trash on GitHub: the _trash copy goes into folders that exist with those exact bytes",
   [{"kind": "delete", "path": "notes/sub/x.md"}], [D("notes/sub/x.md"), W("_trash/notes/sub/x.md", "# X\n")],
   base=TT, theirs=TT, spec="6.1, 6.3")
pv("P54", "Delete of an NFD note, then a create of its NFC spelling: one edit of the base (NFD) spelling",
   [{"kind": "delete", "path": AMD}, {"kind": "create", "path": AMC, "content": "# New\n"}],
   [W(AMD, "# New\n")], base={AMD: "# Base\n"}, theirs={AMD: "# Base\n"}, spec="7.1")
pv("P55", "An op blocked as too large after its merge takes no target: a later op renamed onto it is merged normally",
   [{"kind": "edit", "path": "n.md", "content": CAT("# A\nx\n", BIG, "\n# B\ny\n")},
    {"kind": "edit", "path": "o.md", "content": "# O\nmine\n"}],
   [W("n.md", CAT(SB, BIG, "\n# O\nmine\n"))], attention=[{"path": "n.md", "reason": "blocked:too-large"}], kept=[0],
   base={"n.md": SB, "o.md": "# O\n"}, theirs={"n.md": CAT(SB, BIG, "\n# O\n")}, renames={"o.md": "n.md"}, spec="6.4, 7.1")
TWN = {AMC: "# C\n", AMD: "# D\n"}
pv("P56", "NFC/NFD twins already on GitHub, both edited in one batch: two edits of existing files, no new clash",
   [{"kind": "edit", "path": AMC, "content": "# C2\n"}, {"kind": "edit", "path": AMD, "content": "# D2\n"}],
   [W(AMD, "# D2\n"), W(AMC, "# C2\n")], base=TWN, theirs=TWN, spec="7.6")
pv("P57", "Delete then edit of a path the old base lacks: comes out as a create, so a create's clash check refuses it",
   [{"kind": "delete", "path": "Notes/y.md"}, {"kind": "edit", "path": "Notes/y.md", "content": "# Y\n"}], [],
   attention=[{"path": "Notes/y.md", "reason": "case-clash", "detail": "notes/"}], kept=[0, 1],
   base={"notes/x.md": "# X\n"}, theirs={"notes/x.md": "# X\n"}, spec="7.1")

out = {"version": 1, "spec": "docs/m3/merge-spec.md", "note": "Expected values are hand-written. Content is fake demo text.", "vectors": V}
json.dump(out, open("vectors.json", "w"), ensure_ascii=False, indent=1); open("vectors.json", "a").write("\n")
out = {"version": 1, "spec": "docs/m3/merge-spec.md", "note": "Expected values are hand-written. {\"$repeat\": [s, n]} means s repeated n times.", "vectors": PV}
json.dump(out, open("plan-vectors.json", "w"), ensure_ascii=False, indent=1); open("plan-vectors.json", "a").write("\n")
print(len(V), "merge vectors,", len(PV), "plan vectors")
