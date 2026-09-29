#!/bin/bash
# H2: the C helper's 15 s give-up text reaches Kismet's log. A silent pseudo-terminal (tools/fake_board.py
# --silent) as a local C source; 50 s, REST polled at 2 Hz for error_reason.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h2-giveup; mkdir -p $D; cd $D
mkdir -p /tmp/hw3/h2-pty; rm -f /tmp/hw3/h2-pty/silent
python3 -u $REPO/tools/fake_board.py /tmp/hw3/h2-pty/silent --silent > $D/fake.log 2>&1 &
F=$!
for i in $(seq 1 40); do [ -e /tmp/hw3/h2-pty/silent ] && break; sleep 0.1; done
echo "fake board pid $F, port $(readlink -f /tmp/hw3/h2-pty/silent)"
kstart h2 $D -c "esp32c5:device=/tmp/hw3/h2-pty/silent,name=silent" || { kill $F; exit 1; }
python3 $T/kq.py poll $D/h2.poll 50 2
python3 $T/kq.py src | tee $D/src-end.txt
python3 $T/kq.py msgs 0 > $D/msgs.txt
kstop $D
kill -TERM $F; wait $F
echo "=== Kismet log lines about the source (t relative to Kismet start)"
T0=$(cat $D/kismet.t0)
grep -i "silent\|IPC\|no capture\|no answer" $D/kismet.log | awk -v t0=$T0 '{t=$1; $1=""; printf "%7.2f%s\n", t-t0, $0}' | cut -c1-330
echo "=== error_reason values over time (REST, 2 Hz)"
python3 - $D/h2.poll $T0 <<'EOF'
import json, sys
t0 = float(sys.argv[2]); prev = None
for l in open(sys.argv[1]):
    r = json.loads(l)
    for s in r["s"]:
        cur = (s["running"], s["error"], s["error_reason"])
        if cur != prev:
            print("%7.2f running=%s error=%s error_reason=%r" % (r["t"] - t0, *cur)); prev = cur
EOF
echo "=== messagebus (REST) lines with the give-up text"; grep -c "no capture from the board" $D/msgs.txt; grep "no capture from the board" $D/msgs.txt | head -3
echo "=== fake board log (first lines)"; head -5 $D/fake.log

echo "########## the same silent port through the C remote helper (websocket, retry), 40 s"
mkdir -p $D/remote /tmp/hw3/h2-pty; rm -f /tmp/hw3/h2-pty/silent
python3 -u $REPO/tools/fake_board.py /tmp/hw3/h2-pty/silent --silent > $D/remote/fake.log 2>&1 &
F=$!
for i in $(seq 1 40); do [ -e /tmp/hw3/h2-pty/silent ] && break; sleep 0.1; done
kstart h2r $D/remote || { kill $F; exit 1; }
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
now > $D/remote/helper.t0
$CAP --connect 127.0.0.1:2501 --source "esp32c5:device=/tmp/hw3/h2-pty/silent,name=silent" > $D/remote/c.helper.log 2>&1 &
P=$!
python3 $T/kq.py poll $D/remote/h2.poll 40 2
python3 $T/kq.py src | tee $D/remote/src-end.txt
kill -TERM $P; wait $P; echo "C helper exit status $?"
kstop $D/remote
kill -TERM $F; wait $F
T0=$(cat $D/remote/helper.t0)
echo "=== Kismet log lines about the source (t relative to the helper's start)"
grep -i "silent\|IPC\|no capture\|no answer\|remote" $D/remote/kismet.log | grep -v "Launching remote capture server" | awk -v t0=$T0 '{t=$1; $1=""; printf "%7.2f%s\n", t-t0, $0}' | cut -c1-330
echo "=== C helper stderr"; cat $D/remote/c.helper.log
