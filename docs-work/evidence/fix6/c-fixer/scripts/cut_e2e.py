# cut_e2e.py SRC OUT CASE-TITLE-PREFIX... : kismet_e2e.sh with only the cases whose "== " title starts
# with one of the prefixes (the preamble and the ending are kept)
import sys
src, out, prefixes = sys.argv[1], sys.argv[2], sys.argv[3:]
lines = open(src).read().split("\n")
first = next(i for i, l in enumerate(lines) if l.startswith('echo "== '))
end = next(i for i, l in enumerate(lines) if l.startswith('if [ "$FAILED" -ne 0 ]'))
keep, on = lines[:first], False
for l in lines[first:end]:
    if l.startswith('echo "== '):
        on = any(l[len('echo "== '):].startswith(p) for p in prefixes)
    if on:
        keep.append(l)
open(out, "w").write("\n".join(keep + lines[end:]))
