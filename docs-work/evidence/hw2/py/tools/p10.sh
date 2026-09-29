#!/bin/bash
# p10: four sources in one Python process (by-id paths: 2 x Wi-Fi, zigbee, btle) for 10 min, REST at 1 Hz,
# CPU and RSS every 10 s; then a mix of C local and Python remote sources for 3 min.
D=~/e2e/py; cd $D
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
B=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_
B0=${B}10:BD:A3:CF:05:40-if00; B1=${B}38:44:BE:BF:C9:10-if00; B2=${B}38:44:BE:BF:D8:0C-if00; B3=${B}10:BD:A3:C8:7D:54-if00
cpu() {  # cpu PID SECS -> average %CPU over SECS from /proc/PID/stat
  local p=$1 s=$2 a b; a=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null); sleep $s; b=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null)
  awk -v a=$a -v b=$b -v s=$s -v t=$(getconf CLK_TCK) 'BEGIN{printf "%.1f", (b-a)*100/(t*s)}'; }
rss() { awk '/VmRSS/{print $2" kB"}' /proc/$1/status 2>/dev/null; }
summary() {  # summary POLLFILE
python3 - $1 <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1])]
names = sorted({s["name"] for r in rows for s in r["s"]})
for n in names:
    ss = [s for r in rows for s in r["s"] if s["name"] == n]
    notrun = sum(1 for s in ss if not s["running"]); err = sum(1 for s in ss if s["error"])
    print("  %-45s samples %d not-running %d error %d packets %s -> %s error_packets %s" % (
        n[:45], len(ss), notrun, err, ss[0]["num_packets"], ss[-1]["num_packets"], ss[-1]["num_error_packets"]))
PY
}
echo "##### A: one Python process, four sources by by-id path, 600 s"
./k.sh start p10a || exit 1
KP=$(pgrep -x kismet)
./pyh.sh $D/p10a.py.log $PYA --source "esp32c5:device=$B0,mode=wifi,name=pw0" --source "esp32c5:device=$B1,mode=wifi,name=pw1" \
  --source "esp32c5:device=$B2,mode=zigbee,name=pz2" --source "esp32c5:device=$B3,mode=btle,name=pb3" &
P=$(pidof_log $D/p10a.py.log)
python3 kq.py waitrun pw0 20 >/dev/null
rm -f p10a.poll; python3 kq.py poll p10a.poll 600 1 &
POLL=$!
for i in $(seq 1 30); do
  echo "t+$((i*20)) python cpu $(cpu $P 10)% rss $(rss $P) threads $(ls /proc/$P/task | wc -l) | kismet cpu $(cpu $KP 10)% rss $(rss $KP) | load $(cut -d' ' -f1-3 /proc/loadavg)"
done > p10a.res
wait $POLL
awk 'NR%5==0' p10a.res
summary p10a.poll
python3 kq.py devs | head -1
echo "helper log lines other than the normal start: $(grep -vc 'connected, offering\|opening\|opened\|capturing' p10a.py.log)"
grep -v 'connected, offering\|opening\|opened$\|capturing$' p10a.py.log | head -10 | cut -c1-200
grep -c "lost sync\|damaged\|dropped\|malformed" p10a.py.log | sed 's/^/sync\/damage lines: /'
kill -TERM $P; sleep 2
./k.sh stop > /dev/null
grep -v "Detected new\|802.11 Wi-Fi device" p10a.log | grep -i "error\|warn" | grep -v "FLIPPERZERO\|LOGDISABLED\|websocket connection closed" | head -10 | cut -c1-200
echo "##### B: mix -- C local Wi-Fi ttyACM0 and btle ttyACM3, Python remote Wi-Fi ttyACM1 and zigbee ttyACM2, 180 s"
./k.sh start p10b -c esp32c5-ttyACM0 -c esp32c5btle-ttyACM3 || exit 1
./pyh.sh $D/p10b.py.log $PYA --source esp32c5-ttyACM1 --source esp32c5zigbee-ttyACM2 &
P=$(pidof_log $D/p10b.py.log)
python3 kq.py waitrun esp32c5-ttyACM1 20 >/dev/null
rm -f p10b.poll; python3 kq.py poll p10b.poll 180 1
summary p10b.poll
python3 kq.py src | cut -c1-150
python3 kq.py devs | head -1
kill -TERM $P; sleep 2
./k.sh stop > /dev/null
grep "Splitting\|capturing" p10b.log | grep -v Detected | cut -c1-160
./locks.sh
