#!/bin/bash
# H4b: two remote helpers for the same board and radio (board B, Wi-Fi): the second refuses and retries, the
# first keeps capturing; kill the first and the second takes over. Two C helpers, then two Python helpers.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h4-busy/b; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TB=$(tty_of $MAC_B); PORT=/dev/$TB; SRC=esp32c5-$TB
U=E5C50001-0000-0000-0000-3844BEBFC910
kstart h4b $D || exit 1
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
start() {  # start KIND TAG; the pid goes in LASTPID
    if [ $1 = c ]; then
        $CAP --connect 127.0.0.1:2501 --source $SRC > $D/$2.helper.log 2>&1 &
    else
        (cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source $SRC --debug > $D/$2.helper.log 2>&1) &
    fi
    LASTPID=$!
}
pair() {
    local k=$1
    echo "===== two $k helpers for $SRC"
    start $k $k-A; local A=$LASTPID
    echo "$k-A pid $A"
    python3 $T/kq.py waitrun $SRC 25 | sed 's/^/A capturing after (s): /'
    sleep 2
    echo "flock: $(python3 $T/lockcheck.py --holders-only $PORT)"
    python3 $T/watch.py $D/$k.watch 90 10 $PORT $U $A &
    local W=$!
    now > $D/$k.tB
    start $k $k-B; local B=$LASTPID
    echo "$k-B pid $B started at $(cat $D/$k.tB)"
    echo "$B" > $D/$k.pidB; echo "$A" > $D/$k.pidA
    sleep 30
    echo "after 30 s: A alive $([ -d /proc/$A ] && echo yes || echo no), B alive $([ -d /proc/$B ] && echo yes || echo no)"
    echo "flock: $(python3 $T/lockcheck.py --holders-only $PORT)"
    python3 $T/kq.py src
    now > $D/$k.tkillA
    kill -TERM $A; wait $A; echo "A exit status $? (killed at $(cat $D/$k.tkillA))"
    sleep 20
    echo "20 s after killing A: B alive $([ -d /proc/$B ] && echo yes || echo no); B children $(cat /proc/$B/task/*/children 2>/dev/null)"
    echo "flock: $(python3 $T/lockcheck.py --holders-only $PORT)"
    python3 $T/kq.py src
    now > $D/$k.tkillB
    kill -TERM $B; wait $B; echo "B exit status $?"
    sleep 3
    touch $D/$k.watch.stop; wait $W; rm -f $D/$k.watch.stop
    echo "port after both: $(python3 $T/lockcheck.py $PORT)"
    python3 - $D/$k.watch $D/$k.tB $D/$k.tkillA $D/$k.tkillB $A $B <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
tB, tkA, tkB = (float(open(x).read()) for x in sys.argv[2:5])
A, B = int(sys.argv[5]), int(sys.argv[6])
def owner(r):
    # the flock holder: A, a child of A, B, or a child of B (a C helper's capture process is a child)
    fl = r["flock"] or []
    who = []
    for p in fl:
        if p == A: who.append("A")
        elif p == B: who.append("B")
        else:
            try:
                pp = int(open("/proc/%d/stat" % p).read().rsplit(")", 1)[1].split()[1])
            except Exception:
                pp = None
            who.append("child-of-A" if pp == A else "child-of-B" if pp == B else "pid%d" % p)
    return who
w1 = [r for r in rows if tB <= r["t"] < tkA]
pk1 = [r["pkts"][0] for r in w1 if r["pkts"]]
print("B running alongside A for %.1f s: packets %s -> %s, running values %s, sources with this uuid %s, flock pids %s"
      % (tkA - tB, pk1[0] if pk1 else None, pk1[-1] if pk1 else None, sorted({str(r["running"]) for r in w1}),
         sorted({r["n_src"] for r in w1}), sorted({str(r["flock"]) for r in w1})))
per5 = []
for k in range(0, int(tkA - tB) - 4, 5):
    v = [r["pkts"][0] for r in w1 if tB + k <= r["t"] < tB + k + 5 and r["pkts"]]
    per5.append((v[-1] - v[0]) if len(v) > 1 else None)
print("  packets per 5 s while both ran: %s" % per5)
w2 = [r for r in rows if tkA <= r["t"] < tkB]
base = next((r["pkts"][0] for r in w2 if r["pkts"]), None)
free = next((r["t"] - tkA for r in w2 if r["flock"] == []), None)
fl_other = [(r["t"], r["flock"]) for r in w2 if r["flock"]]
fl_before = [r["flock"] for r in w1][-1:]
fl_after = [r["flock"] for r in w2][-1:]
new_hold = next((t - tkA for t, f in fl_other if f != (fl_before[0] if fl_before else None)), None)
run_again = None
if free is not None:
    run_again = next((r["t"] - tkA for r in w2 if r["t"] - tkA > free and r["running"] and r["running"][0]), None)
more = next((r["t"] - tkA for r in w2 if r["pkts"] and base is not None and r["pkts"][0] > base and (r["t"] - tkA) > (free or 0)), None)
print("after killing A: port free +%s s; a new holder +%s s (flock %s -> %s); Kismet running again +%s s; "
      "first new packet +%s s" % (None if free is None else round(free, 2), None if new_hold is None else round(new_hold, 2),
                                  fl_before, fl_after, None if run_again is None else round(run_again, 2),
                                  None if more is None else round(more, 2)))
last = [r for r in w2 if r["flock"]][-1:]
if last:
    print("  holder at the end of B's spell: %s" % owner(last[0]))
EOF
    echo "--- $k-A log (without packet lines)"; grep -v "^$" $D/$k-A.helper.log | cut -c1-220 | head -30
    echo "--- $k-B log"; grep -v "^$" $D/$k-B.helper.log | cut -c1-220 | head -60
}
pair c 2>&1 | tee $D/c.out
sleep 3
pair py 2>&1 | tee $D/py.out
python3 $T/kq.py msgs 0 > $D/msgs.txt
kstop $D
grep -i "remote\|matches existing\|will be closed\|$SRC\|already in use" $D/kismet.log | grep -v "Detected\|advertising" | cut -c1-250 > $D/kismet-remote-lines.txt
locks
