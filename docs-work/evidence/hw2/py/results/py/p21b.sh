#!/bin/bash
# p21b: (screen with TERM set; minicom and screen holding)
# p21: serial terminals (pyserial miniterm, picocom, minicom, screen; extracted from their .debs, no sudo) on board
# ttyACM2: what they do to DTR/RTS, whether they lock, whether the board resets; against a helper, and the reverse.
D=~/e2e/py; cd $D
PY=~/esp32c5-venv/bin/python
R=~/e2e/term/root
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
T=/tmp/py/term; rm -rf $T; mkdir -p $T/screendir $T/home; chmod 700 $T/screendir
export SCREENDIR=$T/screendir TERM=xterm
cmd() {  # the terminal's command line for port $2
  case $1 in
    miniterm) echo "$PY -m serial.tools.miniterm $2 115200 --raw";;
    picocom) echo "$R/usr/bin/picocom -b 115200 $2";;
    minicom) echo "env HOME=$T/home $R/usr/bin/minicom -D $2 -b 115200 -o";;
    screen) echo "$R/usr/bin/screen $2 115200";;
  esac; }
probe() { timeout 20 $PY ~/e2e/hw2/probe.py /dev/ttyACM2 --secs 1 | python3 -c "import json,sys; d=json.load(sys.stdin); print('board answers START: linktype', d['start']['linktype'], 'records', d['records'])" 2>&1 | tail -1; }
echo "### (a) each terminal alone on the idle board, 5 s, under strace"
for t in screen; do
  echo "=== $t: $(cmd $t /dev/ttyACM2)"
  timeout -s TERM 5 script -qfec "strace -f -tt -e trace=openat,ioctl,flock -o $T/$t.strace $(cmd $t /dev/ttyACM2)" $T/$t.out > /dev/null 2>&1
  pkill -f "$R/usr/bin/screen" 2>/dev/null; sleep 0.5
  echo "  opens: $(grep -c 'ttyACM2' $T/$t.strace) | flock: $(grep -c 'flock(' $T/$t.strace) | TIOCEXCL: $(grep -c TIOCEXCL $T/$t.strace)"
  echo "  modem-line ioctls: $(grep -o 'TIOCM[A-Z]*, \[[^]]*\]' $T/$t.strace | sort | uniq -c | tr '\n' ';')"
  echo "  output bytes: $(wc -c < $T/$t.out); boot text seen: $(grep -c 'ESP-ROM\|rst:\|<<START>>' $T/$t.out)"
  grep -a -o 'ESP-ROM[^\r]*\|rst:[^\r]*\|<<START>>' $T/$t.out | head -3 | cut -c1-80
  grep -a -i "error\|cannot\|lock\|busy" $T/$t.out | head -2 | cut -c1-160
  probe
done
./k.sh start p21b > /dev/null || exit 1
echo "### (b) the Python helper holds ttyACM2; each terminal tries it"
./pyh.sh $D/p21b.hold.py.log $PYA --source esp32c5-ttyACM2 &
HP=$(pidof_log $D/p21b.hold.py.log)
python3 kq.py waitrun esp32c5-ttyACM2 20 > /dev/null
for t in screen minicom; do
  timeout -s TERM 4 script -qfec "$(cmd $t /dev/ttyACM2)" $T/$t.b.out > /dev/null 2>&1; pkill -f "$R/usr/bin/screen" 2>/dev/null; sleep 0.3
  echo "  $t: $(tr -d '\r' < $T/$t.b.out | grep -a -v '^$' | grep -a -iv 'Script started\|Script done' | head -3 | tr '\n' '|' | cut -c1-220)"
done
sleep 2; echo "  helper source: $(python3 kq.py src | grep ttyACM2 | awk '{print $1,$2,$3,$5}')"
kill -TERM $HP; sleep 2
echo "### (c) a terminal holds ttyACM2; the Python helper and a C local source try it"
for t in minicom screen; do
  echo "=== $t holding"
  timeout -s TERM 24 script -qfec "$(cmd $t /dev/ttyACM2)" $T/$t.c.out > /dev/null 2>&1 &
  TP=$!; sleep 2
  ./pyh.sh $D/p21b.$t.py.log $PYA --source esp32c5-ttyACM2:name=py-$t &
  P=$(pidof_log $D/p21b.$t.py.log); sleep 9
  echo "  python source: $(python3 kq.py src | grep py-$t | awk '{print $1,$2,$3,$5}')"
  grep -v "INFO: esp32c5-ttyACM2:name" $D/p21b.$t.py.log | sed 's/^[0-9.]* //' | head -4 | cut -c1-200
  kill -TERM $P; sleep 2
  python3 kq.py post /datasource/add_source.cmd "{\"definition\":\"esp32c5btle-ttyACM2:name=c-$t\"}" | head -1
  sleep 8; echo "  C local source: $(python3 kq.py src | grep c-$t | cut -c1-330)"
  U=$(python3 kq.py uuid c-$t); [ -n "$U" ] && python3 kq.py post /datasource/by-uuid/$U/close_source.cmd '{}' > /dev/null
  wait $TP
  echo "  terminal saw: $(wc -c < $T/$t.c.out) bytes, boot text $(grep -c 'ESP-ROM\|rst:\|<<START>>' $T/$t.c.out)"
  sleep 1
done
./k.sh stop > /dev/null
grep -v "Detected new\|802.11 Wi-Fi device" p21b.log | grep -i "c-picocom\|c-miniterm\|py-" | cut -c1-230 | head -16
pkill -f "$R/usr/bin/screen" 2>/dev/null
echo "### board afterwards"; probe; ls /dev/serial/by-id/ | wc -l
ls -la /var/lock/ | grep -i ttyACM
$PY ~/e2e/py/tx.py /dev/ttyACM2 --mode-only WIFI; probe
