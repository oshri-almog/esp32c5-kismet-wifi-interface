#!/usr/bin/env python3
"""strace_sum.py STRACE T0 [POLL]: per second since T0 (epoch), the helper's sendto calls (websocket) and bytes,
and its serial command writes; with POLL (an h1.py .poll file) also Kismet's num_packets per second."""
import collections
import datetime
import json
import re
import sys

path, t0 = sys.argv[1], float(sys.argv[2])
day = datetime.datetime.fromtimestamp(t0).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
sends = collections.Counter()
sbytes = collections.Counter()
serial = []
fds = collections.Counter()
for line in open(path, errors="replace"):
    m = re.match(r"(\d+)\s+(\d+):(\d+):([\d.]+) (sendto|write)\((\d+), \"(.{0,40})", line)
    if not m:
        continue
    ts = day + int(m.group(2)) * 3600 + int(m.group(3)) * 60 + float(m.group(4)) - t0
    b = re.search(r"= (-?\d+)", line.rsplit(")", 1)[-1])
    nb = int(b.group(1)) if b else 0
    if m.group(5) == "sendto":
        sends[int(ts)] += 1
        sbytes[int(ts)] += max(nb, 0)
        fds[("sendto", m.group(6))] += 1
    else:
        fds[("write", m.group(6))] += 1
        if re.match(r"(MODE|CHANNELS|START|DWELL)", m.group(7)):
            serial.append("%.2f %s" % (ts, m.group(7).split("\\n")[0]))
print("calls per (syscall, fd):", dict(fds))
print("serial command writes: %d; first ones: %s" % (len(serial), serial[:6]))
print("sendto per second since launch (second, calls, bytes):")
print("  " + " ".join("%d:%d/%d" % (k, sends[k], sbytes[k]) for k in sorted(sends)))
secs = sorted(sends)
if secs:
    lo, hi = secs[0], secs[-1]
    missing = [s for s in range(lo, hi + 1) if s not in sends]
    print("seconds %d..%d with no sendto: %s" % (lo, hi, missing))
if len(sys.argv) > 3:
    rows = [json.loads(x) for x in open(sys.argv[3])][1:]
    per = collections.OrderedDict()
    for r in rows:
        per.setdefault(int(r["t"]), r["pkts"])
    print("Kismet num_packets at the start of each second:", " ".join("%d:%s" % kv for kv in per.items()))
