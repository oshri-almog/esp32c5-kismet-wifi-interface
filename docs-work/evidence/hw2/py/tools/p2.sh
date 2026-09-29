#!/bin/bash
# p2: three sources in one Python process (short names and a by-id path), then the same boards/radios as C local
# and C remote sources; identity fields compared. Also: channel field while hopping (Python), CHANNELS writes,
# BTLE flags in /pcap/all_packets.pcapng.
D=~/e2e/py; cd $D
C=~/kismet-install/bin/kismet_cap_esp32c5
BYID2=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_38:44:BE:BF:D8:0C-if00
S1="esp32c5-ttyACM0"; S2="esp32c5btle-ttyACM3"; S3="esp32c5zigbee:device=$BYID2"
echo "##### A: Python remote, one process, three sources"
./k.sh start p2a || exit 1
./pyh.sh $D/p2a.py.log --connect 127.0.0.1:2501 --user admin --password py-Pass-77 --source "$S1" --source "$S2" --source "$S3" &
sleep 1; PP=$(cat $D/p2a.py.log.pid)
python3 kq.py waitrun esp32c5-ttyACM0 20
rm -f p2a.poll
timeout 20 strace -f -tt -e trace=write -o p2a.strace -p $PP 2>/dev/null &
ST=$!
curl -s -u admin:py-Pass-77 --max-time 30 -o p2a.pcapng http://127.0.0.1:2501/pcap/all_packets.pcapng &
CU=$!
python3 kq.py poll p2a.poll 45 5
wait $ST $CU
python3 srcsum.py | tee p2a.src
python3 kq.py devs BTLE | head -12
python3 kq.py devs | head -1
echo "### CHANNELS writes by the Python helper in 20 s (per fd)"; grep -o 'write([0-9]*, "CHANNELS [0-9]*' p2a.strace | sed 's/write(//; s/, "/ /' | awk '{print "fd"$1}' | sort | uniq -c
grep -o 'write([0-9]*, "[A-Z][A-Z]*[^"]*' p2a.strace | sed 's/write(//' | sort | uniq -c | sort -rn | head -12
python3 - <<'PY'
import json, collections
rows = [json.loads(l) for l in open("p2a.poll")]
per = collections.defaultdict(collections.Counter)
for r in rows:
    for s in r["s"]:
        per[s["name"]][(s["channel"], s["hopping"])] += 1
for k, v in per.items():
    print("REST channel/hopping over %d samples, %s: %s" % (len(rows), k, dict(v)))
PY
~/esp32c5-venv/bin/python pcapng.py p2a.pcapng | head -60
kill -TERM $PP; sleep 2
./k.sh stop
grep -v Detected p2a.log | grep -i "remote source\|capturing\|opened\|Splitting\|error" | cut -c1-220
echo "### python log"; cat p2a.py.log

echo "##### B: C local sources, same boards and radios"
./k.sh start p2b -c "$S1" -c "$S2" -c "$S3" || exit 1
for n in esp32c5-ttyACM0 esp32c5btle-ttyACM3; do python3 kq.py waitrun $n 25; done
sleep 8
python3 srcsum.py | tee p2b.src
./k.sh stop
grep -v Detected p2b.log | grep -i "capturing\|launched\|Splitting\|error" | cut -c1-220

echo "##### C: C remote sources (one process each)"
./k.sh start p2c || exit 1
export KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=py-Pass-77
for s in "$S1" "$S2" "$S3"; do $C --connect 127.0.0.1:2501 --source "$s" > p2c.$(echo $s | cut -c1-14 | tr -c 'a-zA-Z0-9\n' _).log 2>&1 & done
for n in esp32c5-ttyACM0 esp32c5btle-ttyACM3; do python3 kq.py waitrun $n 25; done
sleep 8
python3 srcsum.py | tee p2c.src
pkill -TERM -f "kismet_cap_esp32c5 --connect"; sleep 2; pkill -KILL -f "kismet_cap_esp32c5 --connect"
./k.sh stop
grep -v Detected p2c.log | grep -i "remote source\|capturing\|error" | cut -c1-220
./locks.sh
