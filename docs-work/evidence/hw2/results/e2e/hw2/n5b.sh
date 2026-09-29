#!/bin/bash
# n5b: (a) close_source releases the port; (b) two C remote helpers for the same board
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
PYB=~/esp32c5-venv/bin/python
locks() { for l in $(awk "{print \$5\":\"\$6}" /proc/locks); do pid=${l%%:*}; ino=${l##*:}; for t in /dev/ttyACM*; do [ "$(stat -c %i $t)" = "$ino" ] && echo "  flock $t by pid $pid ($(tr "\0" " " < /proc/$pid/cmdline 2>/dev/null | cut -c1-90))"; done; done; }
./k.sh start n5b -c esp32c5-ttyACM0 || exit 1
python3 kq.py waitrun esp32c5-ttyACM0 20
echo "### (a) locks while local source runs"; locks
U0=$(python3 kq.py uuid esp32c5-ttyACM0)
python3 kq.py post /datasource/by-uuid/$U0/close_source.cmd "{}" | cut -c1-80
sleep 1; echo "### locks after close_source"; locks; python3 kq.py src | cut -c1-160
echo "### openers after close_source"; $PYB openers.py /dev/ttyACM0
echo "### (b) C remote helper A on ttyACM1"
export KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99
date +%s.%N > n5b.tA
$C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > n5b.A.log 2>&1 &
A=$!; python3 kq.py waitrun esp32c5-ttyACM1 20; echo "A pid $A"; locks
date +%s.%N > n5b.tB
echo "### start helper B, same source"
$C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > n5b.B.log 2>&1 &
B=$!
for i in $(seq 1 25); do sleep 1; echo "t+$i $(python3 kq.py src | awk "{print \$1,\$2,\$3,\$5}" | tr "\n" ";") A=$(kill -0 $A 2>/dev/null && echo alive || echo dead) B=$(kill -0 $B 2>/dev/null && echo alive || echo dead)"; done
echo "### locks"; locks
echo "### kill B"; kill -TERM $B; wait $B; echo "B exit=$?"
for i in $(seq 1 15); do sleep 1; echo "t+$i $(python3 kq.py src | awk "{print \$1,\$2,\$3,\$5}" | tr "\n" ";") A=$(kill -0 $A 2>/dev/null && echo alive || echo dead)"; done
echo "### locks"; locks
kill -TERM $A; wait $A; echo "A exit=$?"
./k.sh stop
echo "### A log"; grep -v "lws_\|__lws\|_lws" n5b.A.log | cut -c1-250; echo "### B log"; grep -v "lws_\|__lws\|_lws" n5b.B.log | cut -c1-250
