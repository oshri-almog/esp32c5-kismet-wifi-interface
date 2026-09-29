#!/bin/bash
# p3: Python remote zigbee source: hopping first, then channel=20,channel_hop=false on the same UUID;
# TXTEST 200 from board B with the wiki's script (venv python, then /usr/bin/python3 with apt's python3-serial);
# 802.15.4 devices (channel, frequency, signal), link type 230 in /pcap/all_packets.pcapng.
D=~/e2e/py; cd $D
PY=~/esp32c5-venv/bin/python
A=esp32c5zigbee-ttyACM2   # board 38:44:BE:BF:D8:0C
B=/dev/ttyACM1            # board 38:44:BE:BF:C9:10, the transmitter
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
LOGGING=1 ./k.sh start p3 -t p3 || exit 1
echo "### 1: hopping zigbee source for 10 s"
./pyh.sh $D/p3.hop.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source "$A" &
P=$(pidof_log $D/p3.hop.log)
python3 kq.py waitrun $A 3 >/dev/null; sleep 10
python3 srcsum.py
kill -TERM $P; sleep 3
echo "### after stop: $(python3 kq.py src | cut -c1-120)"
echo "### 2: locked source, same UUID"
STRACE=$D/p3.lock.strace ./pyh.sh $D/p3.lock.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source "$A:channel=20,channel_hop=false" &
P=$(pidof_log $D/p3.lock.log)
for i in $(seq 1 100); do python3 kq.py src | grep -q "run=1" && break; sleep 0.1; done; sleep 3
python3 srcsum.py
python3 kq.py poll p3.poll 3 5
curl -s -u admin:py-Pass-77 --max-time 22 -o p3.pcapng http://127.0.0.1:2501/pcap/all_packets.pcapng &
CU=$!
sleep 1
echo "### TXTEST with the wiki script, venv python, from the repo root ($(date +%s.%N))"
cd $D/src
$PY - $B <<'EOF'
import sys
import time
from esp32c5_kismet import board

ser = board.open_serial(sys.argv[1])  # DTR and RTS stay low; refused if a source holds the board
ser.write(b"MODE 802154\n")           # reboots the board if it is on another radio
time.sleep(1.5)                       # the reboot takes about 0.5 s; anything sent meanwhile is lost
ser.write(b"CHANNELS 20\n")           # one channel is a lock; the default 802.15.4 list hops 11-26
time.sleep(0.5)                       # let the board retune before it transmits
ser.write(b"TXTEST 200\n")            # 200 frames, 20 ms apart: about 4 s
time.sleep(5)
board.close_serial(ser)
EOF
echo "script exit=$? ($(date +%s.%N))"
cd $D; sleep 2
echo "### after TXTEST 1: $(python3 kq.py src | cut -c1-140)"
echo "### TXTEST again with /usr/bin/python3 (dpkg python3-serial $(dpkg-query -W -f='${Version}' python3-serial))"
cd $D/src
/usr/bin/python3 - $B <<'EOF'
import sys
import time
from esp32c5_kismet import board

ser = board.open_serial(sys.argv[1])  # DTR and RTS stay low; refused if a source holds the board
ser.write(b"MODE 802154\n")           # reboots the board if it is on another radio
time.sleep(1.5)                       # the reboot takes about 0.5 s; anything sent meanwhile is lost
ser.write(b"CHANNELS 20\n")           # one channel is a lock; the default 802.15.4 list hops 11-26
time.sleep(0.5)                       # let the board retune before it transmits
ser.write(b"TXTEST 200\n")            # 200 frames, 20 ms apart: about 4 s
time.sleep(5)
board.close_serial(ser)
EOF
echo "script exit=$? ($(date +%s.%N))"
cd $D; sleep 2
wait $CU
echo "### after TXTEST 2: $(python3 kq.py src | cut -c1-140)"
python3 srcsum.py
python3 kq.py devs 802.15.4
python3 kq.py get "/devices/views/all/devices.json" > /dev/null
python3 - <<'PY'
import sys, json
sys.path.insert(0, ".")
import kq
code, devs = kq.req("/devices/views/phy-802.15.4/devices.json")
if not isinstance(devs, list):
    code, devs = kq.req("/devices/views/all/devices.json")
for d in devs:
    if d.get("kismet.device.base.phyname") != "802.15.4":
        continue
    sig = d.get("kismet.device.base.signal", {})
    print(json.dumps({"mac": d.get("kismet.device.base.macaddr"), "name": d.get("kismet.device.base.name"),
                      "type": d.get("kismet.device.base.type"), "channel": d.get("kismet.device.base.channel"),
                      "frequency": d.get("kismet.device.base.frequency"),
                      "packets": d.get("kismet.device.base.packets.total"),
                      "rx": d.get("kismet.device.base.packets.rx_total"), "tx": d.get("kismet.device.base.packets.tx_total"),
                      "last_signal": sig.get("kismet.common.signal.last_signal"),
                      "min_signal": sig.get("kismet.common.signal.min_signal"),
                      "max_signal": sig.get("kismet.common.signal.max_signal"),
                      "freq_khz_map": d.get("kismet.device.base.freq_khz_map")}))
    print("   keys:", sorted(k for k in d.keys() if "802154" in k or "zigbee" in k.lower())[:20])
PY
$PY pcapng.py p3.pcapng --list 2 | head -40
kill -TERM $P; sleep 3
./k.sh stop
echo "### serial writes by the locked Python helper (strace)"
grep -o 'write([0-9]*, "[A-Z][A-Z]*[^"]*' p3.lock.strace | sort | uniq -c | sort -rn | head
grep -v "Detected new BTLE\|Detected new IEEE802.11\|Detected new 802.11" p3.log | grep -i "remote source\|capturing\|opened\|802.15.4\|error\|Detected" | cut -c1-220
echo "### helper logs"; cat p3.hop.log p3.lock.log
echo "### kismetdb 802.15.4 packets (frequency, signal, dlt)"
DB=$(ls /tmp/py/p3/*.kismet 2>/dev/null | head -1); echo "db: $DB"
[ -n "$DB" ] && python3 - "$DB" <<'PY'
import sqlite3, sys, collections
c = sqlite3.connect(sys.argv[1])
rows = c.execute("select phyname, dlt, frequency, signal, sourcemac, destmac from packets").fetchall()
agg = collections.Counter((r[0], r[1], r[2]) for r in rows)
print("packets by (phy, dlt, frequency):", dict(agg))
sig = collections.Counter(r[3] for r in rows if r[1] == 230)
print("802.15.4 signal histogram:", dict(sorted(sig.items())))
print("802.15.4 src/dst:", dict(collections.Counter((r[4], r[5]) for r in rows if r[1] == 230)))
PY
