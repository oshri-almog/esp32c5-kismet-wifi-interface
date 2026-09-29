import json, os, sys
d = sys.argv[1]
for n in ("ws1", "tcp", "ws2"):
    tk = float(open(os.path.join(d, n + ".tkill")).read().split()[0])
    rows = [json.loads(l) for l in open(os.path.join(d, n + ".watch"))]
    print("==", n, "kill", tk, "rows", len(rows), "first %.3f last %.3f" % (rows[0]["t"] - tk, rows[-1]["t"] - tk))
    for r in rows:
        dt = r["t"] - tk
        if -0.4 < dt < 0.2:
            print("  %.3f" % dt, r["alive"], r["flock"], r["running"], r["pkts"], r["err"])
    fl = [(round(r["t"] - tk, 3), r["flock"]) for r in rows]
    nz = [x for x in fl if x[1]]
    print("  flock nonempty count", len(nz), "first", nz[:2], "last", nz[-2:])
