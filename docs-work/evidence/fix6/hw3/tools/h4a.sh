#!/bin/bash
# H4a: a C local source holds board A in Kismet; a C remote helper, then a Python remote helper, is started for
# the same board and radio against the same Kismet, 30 s each. They must refuse and retry, and the local source
# must keep capturing.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h4-busy/a; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TA=$(tty_of $MAC_A); PORT=/dev/$TA; SRC=esp32c5-$TA
U=E5C50001-0000-0000-0000-10BDA3CF0540
kstart h4a $D -c $SRC || exit 1
python3 $T/kq.py waitrun $SRC 20 | sed 's/^/local source capturing after (s): /'
LP=$(python3 $T/kq.py srcjson | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['ipc_pid'])")
echo "local helper pid $LP; port: $(python3 $T/lockcheck.py --holders-only $PORT)"
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
python3 $T/watch.py $D/a.watch 75 5 $PORT $U &
W=$!
sleep 2
echo "=== C remote helper for $SRC (websocket, retry), 30 s"; now > $D/c.t0
$CAP --connect 127.0.0.1:2501 --source $SRC > $D/c.helper.log 2>&1 &
P=$!
sleep 30
echo "C helper pid $P alive after 30 s: $([ -d /proc/$P ] && echo yes || echo no); its children: $(cat /proc/$P/task/*/children 2>/dev/null)"
python3 $T/kq.py src | tee $D/c.src.txt
kill -TERM $P; wait $P; echo "C helper exit status $?"; now > $D/c.t1
sleep 2
echo "=== Python remote helper for $SRC (websocket, --debug), 30 s"; now > $D/py.t0
(cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source $SRC --debug > $D/py.helper.log 2>&1) &
Q=$!
sleep 30
echo "Python helper pid $Q alive after 30 s: $([ -d /proc/$Q ] && echo yes || echo no)"
python3 $T/kq.py src | tee $D/py.src.txt
kill -TERM $Q; wait $Q; echo "Python helper exit status $?"; now > $D/py.t1
sleep 5
touch $D/a.watch.stop; wait $W
python3 $T/kq.py src | tee $D/src-end.txt
python3 $T/kq.py msgs 0 > $D/msgs.txt
kstop $D
locks
echo "=== C helper stderr"; cat $D/c.helper.log
echo "=== Python helper log (lines with use/offer/connect/error)"; grep -i "use\|offer\|connect\|error\|warn" $D/py.helper.log | cut -c1-250 | head -40
echo "=== Kismet log lines about the source / remote connections"
grep -i "remote\|matches existing\|will be closed\|$SRC\|already in use" $D/kismet.log | grep -v "Detected\|advertising" | cut -c1-250
python3 - $D/a.watch $D/c.t0 $D/c.t1 $D/py.t0 $D/py.t1 <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
for name, a, b in (("C remote", sys.argv[2], sys.argv[3]), ("Python remote", sys.argv[4], sys.argv[5])):
    t0, t1 = float(open(a).read()), float(open(b).read())
    w = [r for r in rows if t0 <= r["t"] <= t1]
    pk = [r["pkts"][0] for r in w if r["pkts"]]
    run = sorted({str(r["running"]) for r in w})
    nsrc = sorted({r["n_src"] for r in w})
    flock = sorted({str(r["flock"]) for r in w})
    per5 = []
    for k in range(0, int(t1 - t0), 5):
        v = [r["pkts"][0] for r in w if t0 + k <= r["t"] < t0 + k + 5 and r["pkts"]]
        per5.append((v[-1] - v[0]) if len(v) > 1 else None)
    print("%s window %.1f s: local source packets %s -> %s; running values %s; sources with this uuid %s; "
          "flock holders %s; packets per 5 s: %s" % (name, t1 - t0, pk[0] if pk else None, pk[-1] if pk else None,
                                                     run, nsrc, flock, per5))
EOF
