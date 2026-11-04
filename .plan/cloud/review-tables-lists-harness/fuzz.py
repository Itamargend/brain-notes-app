import random, subprocess, sys
from html.parser import HTMLParser
import cmarkgfm
from cmarkgfm.cmark import Options
class P(HTMLParser):
    def __init__(s): super().__init__(); s.t=[]; s.sec=None; s.depth=0
    def handle_starttag(s,tag,a):
        if tag=="table": s.t.append([0,0])
        elif tag=="thead": s.sec="h"
        elif tag=="tbody": s.sec="b"
        elif tag=="th" and s.sec=="h": s.t[-1][0]+=1
        elif tag=="tr" and s.sec=="b": s.t[-1][1]+=1
    def handle_endtag(s,tag):
        if tag in("thead","tbody"): s.sec=None
def gfm(note):
    p=P(); p.feed(cmarkgfm.github_flavored_markdown_to_html(note, options=Options.CMARK_OPT_UNSAFE)); return ",".join(f"{a}:{b}" for a,b in p.t)
random.seed(int(sys.argv[1])); N=int(sys.argv[2])
atoms=["a","b","שלום"," ","  ","|","|","|","\\","\\|","`","-","--","---",":",":-:","#","# ",">","> ","- ","1. ","* ","***","```","\t","x|y","  |  ","||"]
def line():
    k=random.random()
    if k<0.25: # delimiter-ish
        n=random.randint(1,3); cells=[random.choice(["-","--","---",":--","--:",":-:"," --- ","-x"]) for _ in range(n)]
        s="|".join(cells)
        if random.random()<.6: s="|"+s
        if random.random()<.6: s=s+"|"
        return random.choice(["",""," ","  ","    "])+s+random.choice(["",""," "])
    if k<0.35: return random.choice(["","  ","|","| ","|  "," |","||"])
    return random.choice(["",""," ","    "])+"".join(random.choice(atoms) for _ in range(random.randint(0,6)))
notes=["\n".join(line() for _ in range(random.randint(2,7)))+random.choice(["","\n"]) for _ in range(N)]
notes=[n for n in notes if "\x1e" not in n and "\r" not in n]
out=subprocess.run([sys.argv[3]],input="\x1e".join(notes).encode(),capture_output=True).stdout.decode().split("\n")
bad=0; misses=0; wrong=0
for n,k in zip(notes,out):
    g=gfm(n)
    if g!=k:
        bad+=1
        kl=[x for x in k.split(",") if x]; gl=[x for x in g.split(",") if x]
        if len(kl)<len(gl) and all(x in gl for x in kl): misses+=1; continue
        wrong+=1
        if wrong<=int(sys.argv[4]): print(repr(n),"kit",k,"gfm",g)
print("mismatches",bad,"misses",misses,"wrong",wrong,"of",len(notes))
