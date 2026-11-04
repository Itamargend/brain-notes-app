#!/bin/bash
# Copy MarkdownEditsTests without the tests that need NoteText's Apple-only parts.
K=/home/user/brain-notes-app/Packages/BrainNotesKit
python3 -I - "$K/Tests/BrainNotesKitTests/MarkdownEditsTests.swift" "$(dirname "$0")/Tests/BrainNotesKitTests/MarkdownEditsTests.swift" <<'PY'
import sys,re
src=open(sys.argv[1]).read()
for name in ["theNoteViewAndFileNamesReadTheMarkedLines","aFileNameHasNoMarkdownMarksInIt"]:
    i=src.index("@Test func "+name)
    # cut to the matching closing brace of the func
    j=src.index("{",i); depth=0; k=j
    while True:
        if src[k]=="{": depth+=1
        elif src[k]=="}":
            depth-=1
            if depth==0: break
        k+=1
    src=src[:i]+src[k+1:]
open(sys.argv[2],"w").write(src)
PY
python3 -I - "$K/Sources/BrainNotesKit/MarkdownEdits.swift" "$(dirname "$0")/Sources/BrainNotesKit/MarkdownEdits.swift" <<'PY'
import sys
src=open(sys.argv[1]).read()
old="ns.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, word, _, stop in"
assert old in src
new='''linuxWords(in: paragraph, of: ns) { word, stop in'''
src=src.replace(old,new)
src+='''
// Linux scratch stand-in for enumerateSubstrings(.byWords): runs of letters/digits.
private func linuxWords(in r: NSRange, of ns: NSString, _ body: (NSRange, inout Bool) -> Void) {
    var i = r.location; var stop = false
    func isWord(_ c: unichar) -> Bool { Unicode.Scalar(c).map { CharacterSet.alphanumerics.contains($0) } ?? true }
    while i < NSMaxRange(r), !stop {
        if isWord(ns.character(at: i)) { var j = i; while j < NSMaxRange(r), isWord(ns.character(at: j)) { j += 1 }; body(NSRange(location: i, length: j - i), &stop); i = j } else { i += 1 }
    }
}
'''
src=src.replace("stop.pointee = true","stop = true")
open(sys.argv[2],"w").write(src)
PY
