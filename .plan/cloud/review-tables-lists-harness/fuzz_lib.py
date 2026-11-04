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
