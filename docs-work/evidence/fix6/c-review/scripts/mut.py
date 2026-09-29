import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.encode().decode("unicode_escape"); new = new.encode().decode("unicode_escape")
t = open(path).read()
n = t.count(old)
if n != 1:
    sys.exit("mutation anchor found %d times: %r" % (n, old))
open(path, "w").write(t.replace(old, new))
