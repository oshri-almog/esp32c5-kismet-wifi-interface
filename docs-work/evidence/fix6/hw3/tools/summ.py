#!/usr/bin/env python3
"""summ.py DIR [T_HELPERS]: Kismet log lines about the sources (t relative to Kismet start in DIR/kismet.t0, and
to T_HELPERS, when the remote helpers were started) and the per-source summary of DIR/poll.jsonl."""
import collections
import json
import os
import re
import sys

d = sys.argv[1]
t0 = float(open(os.path.join(d, "kismet.t0")).read())
th = float(open(sys.argv[2]).read()) if len(sys.argv) > 2 else None
keep = re.compile(r"esp32c5|capturing|lost sync|launched|connected|IPC|error|ERROR|WARN|reconnect|Splitting|closed|"
                  r"no answer|in use|remote")
drop = re.compile(r"Detected new|advertising|FLIPPERZERO|alert|Alert")
print("--- Kismet log (t since Kismet start%s)" % ("; t since the helpers started" if th else ""))
for line in open(os.path.join(d, "kismet.log"), errors="replace"):
    parts = line.split(" ", 1)
    try:
        t = float(parts[0])
    except ValueError:
        continue
    msg = parts[1].rstrip()
    if keep.search(msg) and not drop.search(msg):
        print("%7.3f %s%s" % (t - t0, ("%7.3f " % (t - th)) if th else "", msg[:300]))
p = os.path.join(d, "poll.jsonl")
if os.path.exists(p):
    rows = [json.loads(x) for x in open(p)]
    per = collections.defaultdict(list)
    for r in rows:
        for s in r["s"]:
            per[s["name"]].append((r["t"] - t0, s))
    print("--- poll: %d samples over %.1f s" % (len(rows), rows[-1]["t"] - rows[0]["t"] if rows else 0))
    for name, lst in per.items():
        first_run = next((t for t, s in lst if s["running"]), None)
        first_pkt = next((t for t, s in lst if (s["num_packets"] or 0) > 0), None)
        chans = collections.Counter(s["channel"] for t, s in lst)
        errs = sum(1 for t, s in lst if s["error"])
        notrun = sum(1 for t, s in lst if not s["running"])
        reasons = sorted({s["error_reason"] for t, s in lst if s["error"]})
        print("%-24s first running %s, first packet %s, last pkts %s, error samples %d, not-running samples %d, "
              "channel values %s%s" % (name, None if first_run is None else "%.2f" % first_run,
                                       None if first_pkt is None else "%.2f" % first_pkt, lst[-1][1]["num_packets"],
                                       errs, notrun, dict(chans.most_common(4)),
                                       (", errors %s" % reasons) if reasons else ""))
