#!/bin/bash
# H3: kill -TERM of a C remote helper's parent (retry on, the default) ends its capture process and frees the
# board's flock and exclusive mode. Board A, Wi-Fi. Runs: websocket, --tcp, websocket again.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h3-kill; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TA=$(tty_of $MAC_A); PORT=/dev/$TA; SRC=esp32c5-$TA
U=E5C50001-0000-0000-0000-10BDA3CF0540
kstart h3 $D || exit 1
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
run() {
    local tag=$1; shift
    echo "===== $tag: $CAP $*"
    $CAP "$@" > $D/$tag.helper.log 2>&1 &
    local P=$!
    echo "helper parent pid $P"
    python3 $T/kq.py waitrun $SRC 20 | sed 's/^/waitrun: /'
    sleep 3
    local C=$(cat /proc/$P/task/*/children 2>/dev/null | tr ' ' '\n' | grep . | head -1)
    echo "capture process (child) pid: ${C:-none}"
    ps -o pid,ppid,pgid,stat,lstart,cmd -p $P,${C:-$P} | cut -c1-160
    [ -n "$C" ] && grep -E "^(SigIgn|SigCgt)" /proc/$C/status | sed 's/^/child /'
    echo "--- /proc/locks before"; cat /proc/locks
    echo "--- port before: $(python3 $T/lockcheck.py --holders-only $PORT)"
    python3 $T/watch.py $D/$tag.watch 8 20 $PORT $U $P ${C:-} &
    local W=$!
    sleep 1
    local TK=$(now); echo "$TK" > $D/$tag.tkill
    kill -TERM $P
    echo "kill -TERM $P at $TK"
    wait $P; echo "parent exit status $?"
    wait $W
    echo "--- /proc/locks after"; cat /proc/locks
    echo "--- child ${C:-none} alive after: $([ -n "$C" ] && [ -d /proc/$C ] && echo yes || echo no)"
    echo "--- port after (open attempt): $(python3 $T/lockcheck.py $PORT)"
    python3 - $D/$tag.watch $TK $P ${C:-0} <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
tk, p, c = float(sys.argv[2]), sys.argv[3], sys.argv[4]
gone_p = next((r["t"] - tk for r in rows if r["t"] > tk and p not in r["alive"]), None)
gone_c = next((r["t"] - tk for r in rows if r["t"] > tk and c not in r["alive"]), None) if c != "0" else None
free = next((r["t"] - tk for r in rows if r["t"] > tk and r["flock"] == []), None)
before = [r["flock"] for r in rows if r["t"] < tk][-1:]
last = rows[-1]
fmt = lambda v: None if v is None else round(v, 3)
print("parent gone +%s s, child gone +%s s, flock free +%s s (holders just before the kill %s; at the end %s; "
      "Kismet running at the end %s)" % (fmt(gone_p), fmt(gone_c), fmt(free), before, last["flock"], last["running"]))
EOF
    grep -v "^$" $D/$tag.helper.log | cut -c1-220 | sed 's/^/helper: /'
    sleep 2
}
run ws1 --connect 127.0.0.1:2501 --source $SRC 2>&1 | tee $D/ws1.out
run tcp --connect 127.0.0.1:3501 --tcp --source $SRC 2>&1 | tee $D/tcp.out
run ws2 --connect 127.0.0.1:2501 --source $SRC 2>&1 | tee $D/ws2.out
python3 $T/kq.py src > $D/src-end.txt
kstop $D
echo "leftover kismet_cap_esp32c5: $(pgrep -a kismet_cap_esp | cut -c1-100)"
locks
