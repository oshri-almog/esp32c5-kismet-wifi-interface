#!/bin/bash
# H4c: close_source.cmd on a remote source. C helper (websocket, retry) on board B: the capture process must
# end and free the port, and the helper reconnect about 5 s later. Then the same on a Python remote source.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h4-busy/c; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TB=$(tty_of $MAC_B); PORT=/dev/$TB; SRC=esp32c5-$TB
U=E5C50001-0000-0000-0000-3844BEBFC910
kstart h4c $D || exit 1
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
one() {
    local k=$1
    echo "===== close_source.cmd on a $k remote source"
    if [ $k = c ]; then
        $CAP --connect 127.0.0.1:2501 --source $SRC > $D/$k.helper.log 2>&1 &
    else
        (cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source $SRC --debug > $D/$k.helper.log 2>&1) &
    fi
    local P=$!
    python3 $T/kq.py waitrun $SRC 25 | sed 's/^/capturing after (s): /'
    sleep 3
    local C=$(cat /proc/$P/task/*/children 2>/dev/null | tr ' ' '\n' | grep . | head -1)
    echo "helper pid $P, capture process ${C:-none (Python: one process)}; $(python3 $T/lockcheck.py --holders-only $PORT)"
    python3 $T/watch.py $D/$k.watch 25 10 $PORT $U $P ${C:-} &
    local W=$!
    sleep 1
    local TC=$(now); echo $TC > $D/$k.tclose
    python3 $T/kq.py post /datasource/by-uuid/$U/close_source.cmd '{}' | cut -c1-120
    wait $W
    echo "after 24 s: helper alive $([ -d /proc/$P ] && echo yes || echo no), children now $(cat /proc/$P/task/*/children 2>/dev/null)"
    python3 $T/kq.py src
    kill -TERM $P; wait $P; echo "helper exit status $?"
    sleep 2
    echo "port after: $(python3 $T/lockcheck.py $PORT)"
    python3 - $D/$k.watch $TC $P ${C:-0} <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
tc, p, c = float(sys.argv[2]), sys.argv[3], sys.argv[4]
after = [r for r in rows if r["t"] >= tc]
fmt = lambda v: None if v is None else round(v, 2)
child_gone = next((r["t"] - tc for r in after if int(c) not in r["alive"].get(p, [])), None) if c != "0" else None
free = next((r["t"] - tc for r in after if r["flock"] == []), None)
stopped = next((r["t"] - tc for r in after if r["running"] and not r["running"][0]), None)
held_again = next((r["t"] - tc for r in after if free is not None and r["t"] - tc > free and r["flock"]), None)
new_child = next((r["t"] - tc for r in after if c != "0" and [x for x in r["alive"].get(p, []) if str(x) != c]), None)
run_again = next((r["t"] - tc for r in after if stopped is not None and r["t"] - tc > stopped and r["running"] and r["running"][0]), None)
base = next((r["pkts"][0] for r in after if r["pkts"]), 0)
if run_again is not None:
    b2 = next((r["pkts"][0] for r in after if r["t"] - tc >= run_again and r["pkts"]), base)
    first = next((r["t"] - tc for r in after if r["t"] - tc > run_again and r["pkts"] and r["pkts"][0] > b2), None)
else:
    first = None
print("close_source at 0: Kismet not running +%s; old capture process gone +%s; port free +%s; new capture process +%s; "
      "port held again +%s; Kismet running again +%s; packets rising again +%s; flock pids before %s, at the end %s" % (
      fmt(stopped), fmt(child_gone), fmt(free), fmt(new_child), fmt(held_again), fmt(run_again), fmt(first),
      [r["flock"] for r in rows if r["t"] < tc][-1:], rows[-1]["flock"]))
EOF
    echo "--- helper log"; grep -v "^$" $D/$k.helper.log | grep -iv "hop\|channel [0-9]" | cut -c1-220 | head -40
}
one c 2>&1 | tee $D/c.out
sleep 3
one py 2>&1 | tee $D/py.out
python3 $T/kq.py msgs 0 > $D/msgs.txt
kstop $D
locks
