#!/usr/bin/env python3
"""summ.py TAG: summarise TAG.log and TAG.poll (times relative to Kismet start in TAG.t0)."""
import collections
import json
import os
import re
import sys

D = os.path.expanduser("~/e2e/hw2")
tag = sys.argv[1]
t0 = float(open(os.path.join(D, tag + ".t0")).read())
skip = re.compile(r"Using default rates|OUI|FLIPPERZERO|http server|HTTP server|Starting|Loading|Registered|registered|"
                  r"Enabling|Saving|plugin|Plugin|timezone|Opened|memory|Memory|scheduler|Sources will|Setting default|"
                  r"Remote capture server|Launching remote|log|Log|ADSB|uav|UAV|alert|Alert|kismet_80211|override|DOT11|"
                  r"Device tracker|Kismet |system|allowkeytransmit|gps|GPS|manuf|ICAO|icao|packet|Packet|config")
print("--- log (t relative to kismet start)")
for line in open(os.path.join(D, tag + ".log"), errors="replace"):
    parts = line.split(" ", 1)
    try:
        t = float(parts[0])
    except ValueError:
        continue
    msg = parts[1].rstrip()
    if skip.search(msg) and not re.search(r"esp32c5|capturing|source|Source|error|ERROR", msg):
        continue
    print("%7.3f %s" % (t - t0, msg[:400]))
p = os.path.join(D, tag + ".poll")
if os.path.exists(p):
    rows = [json.loads(l) for l in open(p)]
    per = collections.defaultdict(list)
    for r in rows:
        for s in r["s"]:
            per[s["name"]].append((r["t"] - t0, s))
    print("--- poll: %d samples" % len(rows))
    for name, lst in per.items():
        first_run = next((t for t, s in lst if s["running"]), None)
        first_pkt = next((t for t, s in lst if (s["num_packets"] or 0) > 0), None)
        chans = collections.Counter(s["channel"] for t, s in lst)
        errs = sum(1 for t, s in lst if s["error"])
        notrun = sum(1 for t, s in lst if not s["running"])
        print("%-28s first running %s, first packet %s, last pkts %s, error samples %d, not-running samples %d, "
              "channel values %s" % (name, None if first_run is None else "%.2f" % first_run,
                                     None if first_pkt is None else "%.2f" % first_pkt, lst[-1][1]["num_packets"],
                                     errs, notrun, dict(chans.most_common(6))))
