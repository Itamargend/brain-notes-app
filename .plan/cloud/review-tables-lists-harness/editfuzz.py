import random, subprocess, sys, html
from html.parser import HTMLParser
import cmarkgfm
sys.path.insert(0, sys.argv[3]); import fuzz_lib
class P(HTMLParser):
    def __init__(s): super().__init__(convert_charrefs=True); s.t=[]; s.cell=None
    def handle_starttag(s,tag,a):
        if tag=="table": s.t.append([])
        elif tag=="tr" and s.t: s.t[-1].append([])
        elif tag in("th","td") and s.t: s.cell=""
    def handle_endtag(s,tag):
        if tag in("th","td") and s.cell is not None: s.t[-1][-1].append(s.cell.strip()); s.cell=None
    def handle_data(s,d):
        if s.cell is not None: s.cell+=d
random.seed(int(sys.argv[1])); N=int(sys.argv[2])
words=["a","b","שלום","run","5K"," ","  ","|","|","\t"]
def row(n):
    cells=[random.choice(["",""," "])+" ".join(random.choice(words[:5]) for _ in range(random.randint(0,2)))+random.choice(["",""," "]) for _ in range(n)]
    s="|".join(cells)
    if random.random()<.6: s="|"+s
    if random.random()<.6 or n==1: s=s+"|"
    return random.choice(["","",""," ","  "])+s
def delim(n):
    s="|".join(random.choice(["---",":--","--:",":-:"," --- "]) for _ in range(n))
    if random.random()<.6: s="|"+s
    if random.random()<.6 or n==1: s=s+"|"
    return s
def note():
    parts=[]
    for _ in range(random.randint(1,3)):
        k=random.random()
        if k<0.6:
            n=random.randint(1,4)
            lines=[row(n),delim(n)]+[row(random.choice([n,n,n,n-1,n+1]) or 1) for _ in range(random.randint(0,4))]
            if random.random()<.2: lines=["- item","",]+["    "+l for l in lines]
            parts.append("\n".join(lines))
        else:
            parts.append(random.choice(["para","- item","# h","> q","1. one","```\ncode\n```"]))
        parts.append(random.choice(["\n\n","\n\n","\n"]))
    return "".join(parts)
notes=[note() for _ in range(N)]
proc=subprocess.run([sys.argv[4]],input="\x1e".join(notes).encode(),capture_output=True)
recs=proc.stdout.decode().split("\x1e")
bad=0; checked=0
for src,rec in zip(notes,recs):
    out,views=rec.split("\x1f")
    model=[[r.split("\x1d") for r in v[1:].split("\x1c")] for v in views.split("\x1b")] if views else []
    p=P(); p.feed(cmarkgfm.github_flavored_markdown_to_html(out))
    gh=[[[html.unescape(c) for c in r] for r in t] for t in p.t]
    norm=lambda tables:[[[c.replace(" "," ") for c in r] for r in t] for t in tables]
    checked+=1
    if norm(gh)!=norm(model):
        bad+=1
        if bad<=int(sys.argv[5]): print("SRC",repr(src),"\nOUT",repr(out),"\nKIT",model,"\nGFM",gh,"\n")
print("bad",bad,"of",checked)
