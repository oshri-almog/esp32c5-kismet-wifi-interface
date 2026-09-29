#!/bin/bash
# p4: channel= on Wi-Fi (36 locked, 36 then hop) and BTLE (38); set_channel.cmd on Python sources (bad channels in
# a hop list, a single bad channel, BTLE 38) with a C local source for parity; bad channel= at startup.
D=~/e2e/py; cd $D
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
U0=E5C50001-0000-0000-0000-10BDA3CF0540   # ttyACM0 wifi
U1=E5C50001-0000-0000-0000-3844BEBFC910   # ttyACM1 wifi (C local)
U3=E5C50003-0000-0000-0000-10BDA3C87D54   # ttyACM3 btle
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
chw() { grep -o 'write([0-9]*, "CHANNELS [^"]*' $1 | head -${2:-12} | tr '\n' ' '; echo; grep -c 'CHANNELS' $1 | sed 's/^/total CHANNELS writes: /'; }
echo "##### e: bad channel= at startup (Python)"
for s in "esp32c5-ttyACM0:channel=200" "esp32c5-ttyACM0:channel=15" "esp32c5zigbee-ttyACM2:channel=30" "esp32c5btle-ttyACM3:channel=40" "esp32c5btle-ttyACM3:channel=38"; do
  echo "--- $s"; (cd src; timeout 5 ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote $PYA --source "$s" 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}")
done
./k.sh start p4 || exit 1
T0=$(date +%s)
echo "##### a: Wi-Fi channel=36,channel_hop=false (Python)"
STRACE=$D/p4a.strace ./pyh.sh $D/p4a.log $PYA --source "esp32c5-ttyACM0:channel=36,channel_hop=false,name=w36" &
P=$(pidof_log $D/p4a.log)
python3 kq.py waitrun w36 15
curl -s -u admin:py-Pass-77 --max-time 12 -o p4a.pcapng http://127.0.0.1:2501/pcap/all_packets.pcapng
python3 srcsum.py | grep w36
~/esp32c5-venv/bin/python pcapng.py p4a.pcapng | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['interfaces'], d['per_interface'])"
kill -TERM $P; sleep 2; echo "writes:"; chw p4a.strace
echo "##### b: Wi-Fi channel=36 without channel_hop=false (Python)"
STRACE=$D/p4b.strace ./pyh.sh $D/p4b.log $PYA --source "esp32c5-ttyACM0:channel=36,name=w36h" &
P=$(pidof_log $D/p4b.log)
python3 kq.py waitrun w36h 15; sleep 4
python3 srcsum.py | grep w36h
kill -TERM $P; sleep 2; echo "writes (first 12, with times):"; grep 'CHANNELS' p4b.strace | head -12 | cut -c1-60
echo "##### c: BTLE channel=38 (Python), then set_channel 38"
STRACE=$D/p4c.strace ./pyh.sh $D/p4c.log $PYA --debug --source "esp32c5btle-ttyACM3:channel=38" &
P=$(pidof_log $D/p4c.log)
python3 kq.py waitrun esp32c5btle-ttyACM3 20; sleep 2
python3 srcsum.py | grep btle
python3 kq.py post /datasource/by-uuid/$U3/set_channel.cmd '{"channel":"38"}' | cut -c1-200
sleep 2; python3 srcsum.py | grep btle
kill -TERM $P; sleep 2; echo "writes:"; grep -o 'write([0-9]*, "[A-Z][^"]*' p4c.strace | sort | uniq -c
grep -i "config\|chan" p4c.log | cut -c1-200 | head -10
echo "##### c2: BTLE channel=38,channel_hop=false (Python)"
./pyh.sh $D/p4c2.log $PYA --source "esp32c5btle-ttyACM3:channel=38,channel_hop=false" &
P=$(pidof_log $D/p4c2.log)
python3 kq.py waitrun esp32c5btle-ttyACM3 20; sleep 2
python3 srcsum.py | grep btle
kill -TERM $P; sleep 2
echo "##### d: set_channel on a hopping Python Wi-Fi source, and on a C local Wi-Fi source"
python3 kq.py post /datasource/add_source.cmd '{"definition":"esp32c5-ttyACM1"}' | cut -c1-80
./pyh.sh $D/p4d.log $PYA --source "esp32c5-ttyACM0" &
P=$(pidof_log $D/p4d.log)
python3 kq.py waitrun esp32c5-ttyACM0 20; python3 kq.py waitrun esp32c5-ttyACM1 20; sleep 2
python3 kq.py poll p4d.poll 200 2 &
POLL=$!
python3 kq.py src | cut -c1-170
for U in $U0 $U1; do
  echo "=== $U: channels 1,6,15,38 at $(date +%s.%N)"
  python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd '{"channels":["1","6","15","38"]}' | cut -c1-120
  sleep 4; python3 srcsum.py | grep $U | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print({k: d[k] for k in ('name','running','error','error_reason','channel','hopping','hop_channels','hop_rate')})"
done
sleep 3
for U in $U0 $U1; do
  echo "=== $U: channel 15 at $(date +%s.%N)"
  python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd '{"channel":"15"}' | cut -c1-160
  sleep 2; python3 srcsum.py | grep $U | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print({k: d[k] for k in ('name','running','error','error_reason','channel','hopping','hop_channels')})"
done
sleep 10; echo "=== 10 s later"; python3 kq.py src | cut -c1-200
for U in $U0 $U1; do
  echo "=== $U: channel 200 at $(date +%s.%N)"
  python3 kq.py post /datasource/by-uuid/$U/set_channel.cmd '{"channel":"200"}' | cut -c1-160
  sleep 2; python3 srcsum.py | grep $U | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print({k: d[k] for k in ('name','running','error','error_reason','channel','hopping','hop_channels')})"
done
sleep 10; echo "=== 10 s later"; python3 kq.py src | cut -c1-200
echo "=== $U0: channel 48 (valid) at $(date +%s.%N)"
python3 kq.py post /datasource/by-uuid/$U0/set_channel.cmd '{"channel":"48"}' | cut -c1-100
sleep 3; python3 kq.py src | cut -c1-200
kill $POLL
echo "### messagebus since start"; python3 kq.py msgs $T0 | grep -v "Detected new" | cut -c1-250
kill -TERM $P; sleep 2
./k.sh stop
echo "### Python helper log (d)"; cat p4d.log | cut -c1-250
grep -v "Detected new" p4.log | grep -i "error\|channel\|remote source\|capturing\|Removed" | cut -c1-250 | tail -40
