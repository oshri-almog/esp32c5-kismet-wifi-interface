#!/bin/bash
# n8b: C websocket helper: when does it send, and when does Kismet count packets?
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
./k.sh start n8b || exit 1
export KISMET_CAP_APIKEY=$(python3 - <<PY
import sys; sys.path.insert(0, "$D"); import kq
code, body = kq.req("/auth/apikey/generate.cmd", {"name": "n8b", "role": "datasource", "duration": 0}); print(body.strip())
PY
)
date +%s.%N > n8b.t0
strace -f -tt -e trace=sendto,write,writev -o n8b.strace $C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > n8b.helper.log 2>&1 &
S=$!
python3 kq.py poll n8b.poll 30 10
kill -TERM $S; sleep 1; for p in $(pgrep kismet_cap_esp3); do kill -KILL $p; done; wait
./k.sh stop
python3 - <<PY
import json, re, collections
t0 = float(open("n8b.t0").read())
rows = [json.loads(l) for l in open("n8b.poll")]
prev = None
for r in rows:
    s = [x for x in r["s"] if x["name"] == "esp32c5-ttyACM1"]
    if not s: continue
    n = s[0]["num_packets"]
    if n != prev:
        print("REST t=%.1f pkts=%s" % (r["t"] - t0, n)); prev = n
# helper-side sends to the websocket (sendto) and serial writes, per second
import datetime
sends = collections.Counter(); sbytes = collections.Counter(); ser = []
for l in open("n8b.strace"):
    m = re.match(r"(\d+) (\d+):(\d+):([\d.]+) (\w+)\((\d+), \"(.{0,30})", l)
    if not m: continue
    hh, mm, ss = int(m.group(2)), int(m.group(3)), float(m.group(4))
    d = datetime.datetime.fromtimestamp(t0)
    ts = d.replace(hour=hh, minute=mm, second=0, microsecond=0).timestamp() + ss - t0
    if m.group(5) == "sendto":
        sends[int(ts)] += 1
        b = re.search(r"= (\d+)$", l.strip()); sbytes[int(ts)] += int(b.group(1)) if b else 0
    elif m.group(5) == "write" and ("CHANNELS" in l or "START" in l or "MODE" in l):
        ser.append("%.2f %s" % (ts, m.group(7)))
print("serial writes:", ser[:6], "... total", len(ser))
print("sendto per second:", [(k, sends[k], sbytes[k]) for k in sorted(sends)])
PY
