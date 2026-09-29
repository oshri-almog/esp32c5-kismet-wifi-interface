#!/bin/bash
# p8: handshake timings and message texts of the Python helper: a silent board (ROM download mode), no PING from
# Kismet (SIGSTOP), close_source.cmd; the same silent board as a C local source; MODE -> START gap.
D=~/e2e/py; cd $D
PY=~/esp32c5-venv/bin/python
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
BYID2=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:D8:0C-if00
echo "### by-id before"; ls /dev/serial/by-id/
echo "### esptool --after no-reset chip-id on ttyACM2 ($(date +%s.%N))"
$PY -m esptool --chip esp32c5 -p $BYID2 --after no-reset chip-id 2>&1 | tail -12
echo "esptool exit=${PIPESTATUS[0]}"
sleep 1; echo "### by-id in download mode"; ls -la /dev/serial/by-id/ | grep -o "usb-.*"
./k.sh start p8 || exit 1
T0=$(date +%s)
echo "### Python source on the silent board, 42 s ($(date +%s.%N))"
STRACE=$D/p8.silent.strace ./pyh.sh $D/p8.silent.py.log $PYA --debug --source esp32c5-ttyACM2 &
P=$(pidof_log $D/p8.silent.py.log)
for i in $(seq 1 42); do sleep 1; echo "t+$i $(python3 kq.py src | awk '{print $1,$2,$3,$5}' | tr '\n' ';')"; done | awk 'NR%3==0'
kill -TERM $P; sleep 2
grep -v "DEBUG: [<-]" p8.silent.py.log | cut -c1-250
echo "### serial writes (silent board)"; grep -o '^[0-9]* [0-9:.]* write([0-9]*, "[A-Z][^\\]*' p8.silent.strace | cut -c1-80 | head -30
echo "### Kismet messages for it"; python3 kq.py msgs $T0 | grep -v "Detected new" | grep -i "ttyACM2" | cut -c1-250
echo "### C local source on the silent board (add_source), 40 s"
T1=$(date +%s)
python3 kq.py post /datasource/add_source.cmd '{"definition":"esp32c5-ttyACM2:name=c-silent"}' | cut -c1-60
for i in $(seq 1 40); do sleep 1; echo "t+$i $(python3 kq.py src | grep c-silent | awk '{print $1,$2,$3,$5}')"; done | awk 'NR%4==0'
python3 kq.py src | grep c-silent | cut -c1-300
U=$(python3 kq.py uuid c-silent); python3 kq.py post /datasource/by-uuid/$U/close_source.cmd '{}' > /dev/null
echo "### Kismet messages (C)"; python3 kq.py msgs $T1 | grep -v "Detected new" | grep -i "silent\|ttyACM2" | cut -c1-250
sleep 2
echo "### recover: esptool --after hard-reset chip-id ($(date +%s.%N))"
$PY -m esptool --chip esp32c5 -p $BYID2 chip-id 2>&1 | tail -4; echo "esptool exit=${PIPESTATUS[0]}"
sleep 2; ls /dev/serial/by-id/
timeout 20 $PY ~/e2e/hw2/probe.py /dev/ttyACM2 --secs 1 | cut -c1-200
echo "### no PING from Kismet: Python source on ttyACM0, SIGSTOP Kismet for 20 s"
./pyh.sh $D/p8.ping.py.log $PYA --source esp32c5-ttyACM0 &
P=$(pidof_log $D/p8.ping.py.log)
python3 kq.py waitrun esp32c5-ttyACM0 20; sleep 2
KP=$(pgrep -x kismet); echo "SIGSTOP $KP at $(date +%s.%N)"; kill -STOP $KP; sleep 20; kill -CONT $KP; echo "SIGCONT at $(date +%s.%N)"
sleep 10; python3 kq.py src | cut -c1-120
echo "### close_source.cmd on the Python source ($(date +%s.%N))"
U0=$(python3 kq.py uuid esp32c5-ttyACM0)
python3 kq.py post /datasource/by-uuid/$U0/close_source.cmd '{}' | cut -c1-60
for i in $(seq 1 14); do sleep 1; echo "t+$i $(python3 kq.py src | grep ttyACM0 | awk '{print $1,$2,$3,$5}')"; done | awk 'NR%2==0'
echo "### open_source.cmd ($(date +%s.%N))"
python3 kq.py post /datasource/by-uuid/$U0/open_source.cmd '{}' | cut -c1-60
for i in $(seq 1 10); do sleep 1; echo "t+$i $(python3 kq.py src | grep ttyACM0 | awk '{print $1,$2,$3,$5}')"; done | awk 'NR%2==0'
kill -TERM $P; sleep 2
sed 's/^\([0-9.]*\) [0-9:]* /\1 /' p8.ping.py.log | cut -c1-230
./k.sh stop > /dev/null
grep -v "Detected new\|802.11 Wi-Fi device" p8.log | grep -i "ttyACM0\|ping\|timeout\|closing\|shut" | cut -c1-230 | tail -30
echo "### MODE -> START gaps (p3 zigbee switch and this run)"
for f in p3.lock.strace p8.silent.strace; do grep -o '^[0-9]* [0-9:.]* write([0-9]*, "\(MODE\|CHANNELS [0-9]*\\nDWELL\)' $f | head -6; done
pkill -TERM -f "esp32c5_kismet.remote"; ./locks.sh
