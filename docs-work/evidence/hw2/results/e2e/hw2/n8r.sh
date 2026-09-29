#!/bin/bash
# n8r: C remote helper across a Kismet restart, and across close_source; is the child left holding the port?
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
locks() { for l in $(awk "{print \$5\":\"\$6}" /proc/locks); do pid=${l%%:*}; ino=${l##*:}; for t in /dev/ttyACM*; do [ "$(stat -c %i $t)" = "$ino" ] && echo "  flock $t by pid $pid ($(tr "\0" " " < /proc/$pid/cmdline 2>/dev/null | cut -c1-90))"; done; done; }
tree() { for p in $(pgrep -f "kismet_cap_esp32c5 --connect"); do echo "  pid $p ppid $(awk "{print \$4}" /proc/$p/stat) state $(awk "{print \$3}" /proc/$p/stat) threads: $(for t in /proc/$p/task/*; do printf "%s:%s " $(basename $t) $(cat $t/wchan 2>/dev/null); done)"; done; }
KEEPHOME=1 ./k.sh start n8r || exit 1
export KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99
$C --connect 127.0.0.1:2501 --source esp32c5-ttyACM1 > n8r.A.log 2>&1 &
A=$!; python3 kq.py waitrun esp32c5-ttyACM1 20; echo "### running"; tree; locks
echo "### stop kismet (SIGTERM), restart after 5 s"; date +%s.%N > n8r.tstop; ./k.sh stop; sleep 5
echo "### while kismet is down"; tree; locks
KEEPHOME=1 ./k.sh start n8r2 || exit 1
date +%s.%N > n8r.tstart
for i in $(seq 1 20); do sleep 1; echo "t+$i $(python3 kq.py src | awk "{print \$1,\$2,\$3,\$5}" | tr "\n" ";")"; done
echo "### after restart"; tree; locks
U=$(python3 kq.py uuid esp32c5-ttyACM1)
if [ -n "$U" ]; then echo "### close_source $U"; python3 kq.py post /datasource/by-uuid/$U/close_source.cmd "{}" | cut -c1-60; for i in $(seq 1 12); do sleep 1; echo "t+$i $(python3 kq.py src | awk "{print \$1,\$2,\$3,\$5}" | tr "\n" ";")"; done; tree; locks; fi
kill -TERM $A; sleep 2; tree; locks; pkill -KILL -f "kismet_cap_esp32c5 --connect"; ./k.sh stop
echo "### A log"; grep -v "lws_\|__lws\|_lws" n8r.A.log | cut -c1-250
