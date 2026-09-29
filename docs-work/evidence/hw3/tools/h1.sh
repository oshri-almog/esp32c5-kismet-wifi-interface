#!/bin/bash
# H1: websocket latency. 5 runs each of the C helper over the websocket, the C helper over --tcp and the
# Python helper over the websocket, one Wi-Fi board (B); then one C websocket run under strace.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h1-latency; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TB=$(tty_of $MAC_B)
SRC=esp32c5-$TB
U=E5C50001-0000-0000-0000-3844BEBFC910
kstart h1 $D || exit 1
for k in c-ws c-tcp py; do
    echo "##### $k"
    python3 $T/h1.py $D $k 5 $SRC $U 30
done 2>&1 | tee $D/h1.summary.txt
echo "##### strace c-ws" | tee -a $D/h1.summary.txt
mkdir -p $D/strace
python3 $T/h1.py $D/strace c-ws 1 $SRC $U 30 --strace 2>&1 | tee -a $D/h1.summary.txt
T0=$(head -1 $D/strace/c-ws-0.poll | python3 -c "import json,sys; print(json.load(sys.stdin)['t0'])")
python3 $T/strace_sum.py $D/strace/c-ws-0.strace $T0 $D/strace/c-ws-0.poll 2>&1 | tee $D/strace/c-ws-0.strace-summary.txt
python3 $T/kq.py src > $D/src-end.txt
kstop $D
locks | tee $D/locks-end.txt
