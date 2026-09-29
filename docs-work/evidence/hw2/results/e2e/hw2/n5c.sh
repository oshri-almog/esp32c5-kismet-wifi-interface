#!/bin/bash
# n5c: where does a C remote helper child hang after Kismet drops it for a duplicate UUID?
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
tree() { for p in $(pgrep kismet_cap_esp3); do echo "  pid $p ppid $(awk "{print \$4}" /proc/$p/stat) threads: $(for t in /proc/$p/task/*; do printf "%s:%s:%s " $(basename $t) $(cat $t/wchan 2>/dev/null) "$(cut -d" " -f1 $t/syscall 2>/dev/null)"; done)"; done; }
./k.sh start n5c || exit 1
export KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99
$C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > n5c.A.log 2>&1 &
A=$!; python3 kq.py waitrun esp32c5-ttyACM1 20; echo "### A running"; tree
$C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > n5c.B.log 2>&1 &
B=$!; sleep 3; echo "### 3 s after B"; tree
AC=$(pgrep -P $A); echo "A child $AC"; [ -n "$AC" ] && timeout 8 strace -f -tt -p $AC -o n5c.strace 2>/dev/null; echo "### A child strace 8 s (first 40 lines)"; head -40 n5c.strace | cut -c1-160
kill -TERM $B; sleep 1; kill -KILL $(pgrep -P $B) 2>/dev/null
kill -TERM $A; sleep 1; for p in $(pgrep kismet_cap_esp3); do kill -KILL $p; done
./k.sh stop; tree; echo "### A log"; grep -v "lws_\|__lws\|_lws" n5c.A.log
