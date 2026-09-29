import sys
p, start_s, end_s, newfile = sys.argv[1:5]
t = open(p, newline="").read()
start = t.index(start_s)
end = t.index(end_s, start) + len(end_s)
new = open(newfile, newline="").read()
open(p, "w", newline="").write(t[:start] + new + t[end:])
print("spliced %d..%d" % (start, end))
