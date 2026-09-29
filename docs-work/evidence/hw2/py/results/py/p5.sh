#!/bin/bash
# p5: port lock with the Python helper as holder (check 4); a port the C helper holds (check 8); clean stops (check 6)
D=~/e2e/py; cd $D
PY=~/esp32c5-venv/bin/python
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
BYID0=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_10:BD:A3:CF:05:40-if00
U0=E5C50001-0000-0000-0000-10BDA3CF0540
pk() { python3 kq.py src | awk '{print $1, $2, $3, $5}' | tr '\n' ';'; echo; }
./k.sh start p5 -c esp32c5-ttyACM1 || exit 1
python3 kq.py waitrun esp32c5-ttyACM1 20 >/dev/null
echo "##### check 4: Python helper holds ttyACM0"
./pyh.sh $D/p5.hold.log $PYA --source esp32c5-ttyACM0 &
HP=$(pidof_log $D/p5.hold.log)
python3 kq.py waitrun esp32c5-ttyACM0 20
echo "### locks"; ./locks.sh
echo "### tty exclusive flag? (TIOCGEXCL via python)"
$PY - <<'PY'
import fcntl, struct, os, errno
TIOCGEXCL = 0x80045440
for p in ("/dev/ttyACM0",):
    try:
        fd = os.open(p, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as e:
        print(p, "open:", errno.errorcode.get(e.errno), e.strerror); continue
    print(p, "TIOCGEXCL:", struct.unpack("i", fcntl.ioctl(fd, TIOCGEXCL, b"\0\0\0\0"))[0]); os.close(fd)
PY
echo "### openers on ttyACM0 and its by-id link"; $PY ~/e2e/hw2/openers.py /dev/ttyACM0; $PY ~/e2e/hw2/openers.py $BYID0
echo "### esptool chip-id on the by-id link"; timeout 60 $PY -m esptool --chip esp32c5 -p $BYID0 chip-id 2>&1 | tail -4; echo "esptool exit=${PIPESTATUS[0]}"
echo "### the wiki TXTEST opener (board.open_serial) on ttyACM0"
(cd src; $PY -c "from esp32c5_kismet import board; board.open_serial('/dev/ttyACM0')" 2>&1 | tail -2)
echo "### Kismet local source for another radio of the same board (add_source esp32c5btle-ttyACM0)"
T1=$(date +%s)
python3 kq.py post /datasource/add_source.cmd '{"definition":"esp32c5btle-ttyACM0"}' | cut -c1-120
sleep 4; python3 kq.py src | grep -v ttyACM1 | cut -c1-330
echo "### second Python helper, other radio (esp32c5zigbee-ttyACM0), 14 s"
./pyh.sh $D/p5.second.log $PYA --source esp32c5zigbee-ttyACM0 &
SP=$(pidof_log $D/p5.second.log)
for i in 1 2 3 4 5 6 7; do sleep 2; echo "t+$((i*2)) $(pk)"; done
python3 kq.py src | grep zigbee | cut -c1-330
kill -TERM $SP; sleep 1.5
echo "### third Python helper, same radio and UUID as the holder (esp32c5-ttyACM0), 14 s"
./pyh.sh $D/p5.third.log $PYA --source esp32c5-ttyACM0 &
TP=$(pidof_log $D/p5.third.log)
for i in 1 2 3 4 5 6 7; do sleep 2; echo "t+$((i*2)) $(pk)"; done
kill -TERM $TP; sleep 1.5
echo "### holder still capturing?"; sleep 3; pk; ./locks.sh; kill -TERM $HP
echo "### messages since T1"; python3 kq.py msgs $T1 | grep -v "Detected new" | cut -c1-260
echo "### second/third helper logs"; cat p5.second.log p5.third.log | cut -c1-260
echo "##### check 8: Python source on the board the C local source holds (esp32c5btle-ttyACM1), 32 s"
python3 kq.py post /datasource/by-uuid/E5C50003-0000-0000-0000-10BDA3CF0540/close_source.cmd '{}' > /dev/null
T2=$(date +%s)
./pyh.sh $D/p5.busy.log $PYA --source esp32c5btle-ttyACM1 &
BP=$(pidof_log $D/p5.busy.log)
sleep 32
python3 kq.py srcjson | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if 'btle-ttyACM1' in s['name']: print(json.dumps({k: s.get(k) for k in ('name','running','error','error_reason','retry','retry_attempts','total_retry_attempts','uuid')}))"
echo "### messagebus over 32 s"; python3 kq.py msgs $T2 | grep -v "Detected new" | cut -c1-260
echo "count: $(python3 kq.py msgs $T2 | grep -c 'btle-ttyACM1')"
kill -TERM $BP; sleep 1.5
echo "### helper log"; cat p5.busy.log | cut -c1-260
echo "##### check 6: stops"
for sig in INT TERM; do
  ./pyh.sh $D/p5.stop$sig.log $PYA --source esp32c5-ttyACM2 --source esp32c5-ttyACM3 &
  P=$(pidof_log $D/p5.stop$sig.log)
  python3 kq.py waitrun esp32c5-ttyACM2 20 >/dev/null; python3 kq.py waitrun esp32c5-ttyACM3 20 >/dev/null; sleep 2
  echo "--- SIG$sig to $P at $(date +%s.%N)"; ./locks.sh | grep -c "pid $P" | sed 's/^/flocks held before: /'
  kill -$sig $P
  for i in $(seq 1 100); do kill -0 $P 2>/dev/null || break; sleep 0.05; done
  echo "gone at $(date +%s.%N)"; sleep 0.5
  tail -4 p5.stop$sig.log; ./locks.sh | grep -c "pid $P" | sed 's/^/flocks held after: /'
  python3 kq.py src | grep "ttyACM[23]" | cut -c1-110
  python3 kq.py srcjson | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['name'] in ('esp32c5-ttyACM2','esp32c5-ttyACM3'): print(s['name'], 'running', s['running'], 'error', s['error'], 'reason', repr(s.get('error_reason')))"
done
echo "--- a source whose board is not there (esp32c5-ttyACM9) and one held by the C helper (esp32c5zigbee-ttyACM1), 14 s"
./pyh.sh $D/p5.absent.log $PYA --source esp32c5-ttyACM9 &
P9=$(pidof_log $D/p5.absent.log)
./pyh.sh $D/p5.held.log $PYA --source esp32c5zigbee-ttyACM1 &
PH=$(pidof_log $D/p5.held.log)
sleep 14; kill -TERM $P9 $PH; sleep 2
cat p5.absent.log p5.held.log | cut -c1-240
./k.sh stop
./locks.sh
