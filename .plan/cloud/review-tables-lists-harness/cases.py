import subprocess, sys
sys.path.insert(0, sys.argv[2])
from fuzz_lib import gfm
cases = [
 "| a |\n|---|\n|\nafter\n", "| a |\n|---|\n| 1 |\n|  \nafter\n", "| a |\n|---|\n| 1 |\n\t|\t\n",
 "|\n|---|\n", "| \n|---|\n", "  |\n|---|\n",
 "| a |\n|---|\n| 1 |\n    indented\n", "| a |\n|---|\n| 1 |\n\tindented\n",
 "- item\n| a | b |\n|---|---|\n", "> q\n| a |\n|---|\n", "1. item\n| a |\n|---|\n| 1 |\n",
 "- item\n\n| a |\n|---|\n", "- item\n\n    | a | b |\n    |---|---|\n    | 1 | 2 |\n", "- item\n  | a |\n  |---|\n",
 "x\n-|-\n-|-\n", "x\n|-|-|\na|b\n-|-\n", "x\n:|-\na|b\n-|-\n", "x\n===\na|b\n-|-\n", "x\n---\n| a |\n|---|\n",
 "a\n|---|\n", "x\n:-:\n", "x\n---:\n",
 "1. \n  \n\n    a|b\n     --- |--\n", "x\n2. y\na|b\n-|-\n", "a|b\n- | -\n", "*   x\n1. \n\n    a|b\n     --- |--\n",
 "intro\n    a | b\n--|--\n", "- # h\na|b\n-|-\n", "> \na|b\n-|-\n", "- \na|b\n-|-\n",
]
out = subprocess.run([sys.argv[1]], input="\x1e".join(cases).encode(), capture_output=True).stdout.decode().split("\n")
for c, k in zip(cases, out):
    g = gfm(c)
    print(("OK  " if g == k else "DIFF"), repr(c), "kit", repr(k), "gfm", repr(g))
