#!/bin/bash
# p9: Python-specific definition handling: unquoted/quoted comma lists, a name with a comma, portless definitions,
# the same board twice, a /tmp symlink port, two Wi-Fi sources split, types.json by role, a live lock across a
# helper restart and when another hopping source opens.
D=~/e2e/py; cd $D
PY=~/esp32c5-venv/bin/python
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
BYID0=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_10:BD:A3:CF:05:40-if00
show() { python3 kq.py srcjson | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print('   ', {k: s.get(k) for k in ('name','definition','uuid','hardware','capture_interface','running','channel','hopping','hop_rate','hop_offset')}, 'hop_channels', s.get('hop_channels') if len(s.get('hop_channels') or [])<8 else len(s.get('hop_channels')))"; }
waitany() { for i in $(seq 1 100); do python3 kq.py src | grep -q "run=1" && break; sleep 0.1; done; }
stopall() { pkill -TERM -f "esp32c5_kismet.remote"; for i in $(seq 1 50); do pgrep -f "esp32c5_kismet.remote" >/dev/null || break; sleep 0.1; done; }
n=0
for def in 'esp32c5-ttyACM0:channels=1,6,11' 'esp32c5-ttyACM0:channels="1,6,11"' 'esp32c5-ttyACM0:name="lab, bench 2"' 'esp32c5-ttyACM0:channels=1,6,11,name=x' 'esp32c5-ttyACM0:,channels=1'; do
  n=$((n+1)); echo "=== a$n: --source '$def'"
  ./k.sh start p9a$n > /dev/null || exit 1
  ./pyh.sh $D/p9a$n.py.log $PYA --source "$def" &
  P=$(pidof_log $D/p9a$n.py.log); waitany; sleep 3; show
  stopall; ./k.sh stop > /dev/null
  grep -v "INFO" p9a$n.py.log | sed 's/^[0-9.]* //' | cut -c1-300
done
./k.sh start p9 || exit 1
echo "=== b1: portless --source esp32c5 with 4 boards, 12 s"
./pyh.sh $D/p9b1.py.log $PYA --source esp32c5 &
P=$(pidof_log $D/p9b1.py.log); sleep 6
echo "  TCP connections of the helper: $(ss -tnp 2>/dev/null | grep -c "pid=$P,")"; sleep 6
echo "  sources: $(python3 kq.py src | wc -l)"
kill -TERM $P; sleep 1; sed 's/^[0-9.]* //' p9b1.py.log | cut -c1-300
echo "=== b2: two portless definitions"
(cd src; $PY -m esp32c5_kismet.remote $PYA --source esp32c5 --source esp32c5btle 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}")
echo "=== b3: portless with a name that is not a port (esp32c5-kitchen) and with mode= only"
(cd src; timeout 7 $PY -m esp32c5_kismet.remote $PYA --source esp32c5-kitchen 2>&1 | head -2 | cut -c1-300)
echo "=== c: the same board twice in one process"
for pair in "esp32c5-ttyACM0|esp32c5btle:device=$BYID0" "esp32c5-ttyACM0|esp32c5zigbee-ttyACM0" "esp32c5:device=/dev/ttyACM0|esp32c5:device=$BYID0"; do
  a=${pair%%|*}; b=${pair##*|}
  (cd src; $PY -m esp32c5_kismet.remote $PYA --source "$a" --source "$b" 2>&1 | tail -1 | cut -c1-300; echo "exit=${PIPESTATUS[0]}")
done
echo "=== d: a /tmp symlink as the port"
ln -sf /dev/ttyACM1 /tmp/py/board1
./pyh.sh $D/p9d.py.log $PYA --source "esp32c5:device=/tmp/py/board1" &
P=$(pidof_log $D/p9d.py.log); waitany; sleep 3; show
kill -TERM $P; sleep 1.5
echo "=== d2: a /tmp symlink whose target is missing (uuid given, and not)"
ln -sf /dev/ttyACM9 /tmp/py/board9
(cd src; timeout 7 $PY -m esp32c5_kismet.remote $PYA --source "esp32c5:device=/tmp/py/board9" 2>&1 | head -3 | cut -c1-250)
./k.sh stop > /dev/null
echo "=== e: two Python Wi-Fi sources in one process, fresh Kismet"
./k.sh start p9e > /dev/null
./pyh.sh $D/p9e.py.log $PYA --source esp32c5-ttyACM2 --source esp32c5-ttyACM3 &
P=$(pidof_log $D/p9e.py.log); sleep 1; waitany; sleep 4; show
grep "Splitting" p9e.log | cut -c1-200
echo "=== f: types.json by login and key"
KEY=$(python3 -c "
import sys; sys.path.insert(0, '.'); import kq
code, body = kq.req('/auth/apikey/generate.cmd', {'name': 'p9ds', 'role': 'datasource', 'duration': 0}); print(body.strip())")
ADM=$(python3 -c "
import sys; sys.path.insert(0, '.'); import kq
code, body = kq.req('/auth/apikey/generate.cmd', {'name': 'p9adm', 'role': 'admin', 'duration': 0}); print(body.strip())")
echo "admin login: $(curl -s -o /tmp/py/t.json -w '%{http_code}' -u admin:py-Pass-77 http://127.0.0.1:2501/datasource/types.json) $(python3 -c "import json; print([t.get('kismet.datasource.type_driver.type') for t in json.load(open('/tmp/py/t.json'))][:40])" 2>&1 | cut -c1-300)"
echo "datasource key (cookie): $(curl -s -o /dev/null -w '%{http_code}' --cookie KISMET=$KEY http://127.0.0.1:2501/datasource/types.json)"
echo "datasource key (?KISMET=): $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:2501/datasource/types.json?KISMET=$KEY")"
echo "admin key (cookie): $(curl -s -o /dev/null -w '%{http_code}' --cookie KISMET=$ADM http://127.0.0.1:2501/datasource/types.json)"
echo "no auth: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:2501/datasource/types.json)"
stopall; ./k.sh stop > /dev/null
echo "=== g: live lock across a helper restart; then another hopping source opens"
./k.sh start p9g > /dev/null
STRACE=$D/p9g1.strace ./pyh.sh $D/p9g1.py.log $PYA --source esp32c5-ttyACM0 &
P=$(pidof_log $D/p9g1.py.log); waitany; sleep 2
U=$(python3 kq.py uuid esp32c5-ttyACM0)
python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd '{"channel":"48"}' | cut -c1-40; sleep 2
echo "locked:"; show
kill -TERM $P; sleep 3
STRACE=$D/p9g2.strace ./pyh.sh $D/p9g2.py.log $PYA --source esp32c5-ttyACM0 &
P=$(pidof_log $D/p9g2.py.log); sleep 1; waitany; sleep 4
echo "after helper restart:"; show
echo "  CHANNELS writes of the new helper in ~5 s: $(grep -c CHANNELS p9g2.strace); first: $(grep -o 'CHANNELS [0-9]*' p9g2.strace | head -5 | tr '\n' ' ')"
python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd '{"channel":"48"}' | cut -c1-40; sleep 2
N1=$(grep -c CHANNELS p9g2.strace)
echo "locked again; add a hopping C local Wi-Fi source (esp32c5-ttyACM1)"
python3 kq.py post /datasource/add_source.cmd '{"definition":"esp32c5-ttyACM1"}' | cut -c1-40
python3 kq.py waitrun esp32c5-ttyACM1 20 > /dev/null; sleep 4; show
echo "  CHANNELS writes of the locked helper since: $(( $(grep -c CHANNELS p9g2.strace) - N1 ))"
grep "Splitting" p9g.log | cut -c1-200
echo "  set a custom list+rate on A, then add another hopping source (Python esp32c5-ttyACM2)"
python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd '{"channels":["1","6","11"],"rate":2}' | cut -c1-40; sleep 2; show
./pyh.sh $D/p9g3.py.log $PYA --source esp32c5-ttyACM2 &
sleep 1; waitany; sleep 5; show
stopall; ./k.sh stop > /dev/null
rm -f /tmp/py/board1 /tmp/py/board9
./locks.sh
