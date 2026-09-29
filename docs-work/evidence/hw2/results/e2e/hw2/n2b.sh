#!/bin/bash
# n2b: --list with boards held by a C local source and a Python remote helper; port lock (check 5); caps (check 6)
D=~/e2e/hw2; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
PYB=~/esp32c5-venv/bin/python
REPO=~/esp32c5-kismet-wifi-interface
BYID0=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_10:BD:A3:CF:05:40-if00
BYID1=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:C9:10-if00
pk() { python3 kq.py src | awk "{print \$1, \$2, \$3, \$5}" | tr "\n" ";"; echo; }
locks() { for l in $(awk "{print \$5\":\"\$6}" /proc/locks); do pid=${l%%:*}; ino=${l##*:}; for t in /dev/ttyACM*; do [ "$(stat -c %i $t)" = "$ino" ] && echo "  flock $t by pid $pid ($(tr "\0" " " < /proc/$pid/cmdline 2>/dev/null | cut -c1-80))"; done; done; }
./k.sh start n2b -c esp32c5-ttyACM0 || exit 1
python3 kq.py waitrun esp32c5-ttyACM0 20
HPID=$(python3 kq.py srcjson | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"ipc_pid\"])")
echo "### helper pid $HPID: $(tr "\0" " " < /proc/$HPID/cmdline)"; echo "### pgrep: $(pgrep -a kismet_cap_esp32c5)"
echo "### check 6: /proc/$HPID/status"; grep -E "^(Uid|Gid|Groups|CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp)" /proc/$HPID/status
echo "### kismet pid $(cat kismet.pid) status"; grep -E "^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs)" /proc/$(cat kismet.pid)/status
echo "### locks"; locks
echo "### C --list while ttyACM0 held by C local source"; $C --list; echo "exit=$?"
echo "### Python --list while ttyACM0 held by C local source"; (cd $REPO; $PYB -m esp32c5_kismet.remote --list; echo "exit=$?")
echo "### check 5: openers on ttyACM0 (held by C local)"; pk; $PYB openers.py /dev/ttyACM0; $PYB openers.py $BYID0
echo "### esptool read-mac on by-id of ttyACM0"; timeout 60 $PYB -m esptool --chip esp32c5 -p $BYID0 read-mac; echo "esptool exit=$?"
sleep 2; echo "### after esptool"; pk; python3 kq.py src | cut -c1-200
echo "### Python remote on ttyACM1 (second holder)"
(cd $REPO; exec $PYB -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source esp32c5-ttyACM1 > $D/n2b.py1.log 2>&1) &
PY1=$!
python3 kq.py waitrun esp32c5-ttyACM1 20
echo "### locks"; locks
echo "### C --list while ttyACM0 (C local) and ttyACM1 (Python remote) held"; $C --list; echo "exit=$?"
echo "### Python --list, same"; (cd $REPO; $PYB -m esp32c5_kismet.remote --list; echo "exit=$?")
echo "### openers on ttyACM1 (held by Python remote)"; $PYB openers.py /dev/ttyACM1
echo "### esptool read-mac on by-id of ttyACM1"; timeout 60 $PYB -m esptool --chip esp32c5 -p $BYID1 read-mac; echo "esptool exit=$?"
sleep 1; pk
echo "### Python remote --source esp32c5-ttyACM0 (board held by the C local source), 15 s"
T5=$(date +%s.%N); echo $T5 > n2b.t5
(cd $REPO; exec $PYB -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source esp32c5-ttyACM0 > $D/n2b.py0.log 2>&1) &
PY0=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do sleep 1; echo "t+$i $(pk)"; done
kill -TERM $PY0; wait $PY0; echo "python ttyACM0 helper exit=$?"
echo "### its log"; cat n2b.py0.log
sleep 6; echo "### sources after it stopped"; python3 kq.py src | cut -c1-220
echo "### C local second source for another radio of ttyACM0 via add_source (esp32c5btle-ttyACM0)"
python3 kq.py post /datasource/add_source.cmd "{\"definition\":\"esp32c5btle-ttyACM0\"}"
sleep 3; python3 kq.py src | cut -c1-250
U0=$(python3 kq.py uuid esp32c5-ttyACM0); echo "### close_source $U0"
python3 kq.py post /datasource/by-uuid/$U0/close_source.cmd "{}"
sleep 2; echo "### locks after close"; locks; python3 kq.py src | cut -c1-200
echo "### openers on ttyACM0 after close"; $PYB openers.py /dev/ttyACM0
kill -TERM $PY1; wait $PY1; echo "python ttyACM1 helper exit=$?"; echo "### py1 log"; cat n2b.py1.log
./k.sh stop
echo "### locks at end"; locks
