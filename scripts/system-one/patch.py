import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
for i in range(0, len(pairs), 2):
    old, new = pairs[i].replace("\\n", "\n"), pairs[i + 1].replace("\\n", "\n")
    if old not in s:
        sys.exit("missing anchor: " + old[:60])
    s = s.replace(old, new, 1)
open(dst, "w").write(s)
import ast; ast.parse(s)
print("patched ok")
