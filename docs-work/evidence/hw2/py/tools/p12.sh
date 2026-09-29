#!/bin/bash
# p12: the Python helper's radio switch, 5 rounds on board 10:BD:A3:C8:7D:54 (ttyACM3, the one whose Wi-Fi -> BLE
# switch hung once under the C helper): wifi (same radio), zigbee, wifi, btle, wifi. 'opened' -> 'capturing' and
# helper start -> 'capturing' from the helper log; a switch that does not capture in 25 s counts as a failure.
D=~/e2e/py; cd $D
pidof_log() { for i in $(seq 1 50); do [ -s $1.pid ] && break; sleep 0.1; done; cat $1.pid; }
PYA="--connect 127.0.0.1:2501 --user admin --password py-Pass-77"
./k.sh start p12 > /dev/null || exit 1
rm -f p12.res
prev=wifi
for r in 1 2 3 4 5; do
  for m in wifi zigbee wifi btle wifi; do
    case $m in wifi) def=esp32c5-ttyACM3;; zigbee) def=esp32c5zigbee-ttyACM3;; btle) def=esp32c5btle-ttyACM3;; esac
    L=$D/p12.r$r.$m.$prev.py.log
    t0=$(date +%s.%N)
    ./pyh.sh $L $PYA --source $def &
    P=$(pidof_log $L)
    ok=0; for i in $(seq 1 250); do grep -q "capturing$" $L 2>/dev/null && { ok=1; break; }; sleep 0.1; done
    tu=$(awk '/ opened$/{print $1; exit}' $L); tc=$(awk '/ capturing$/{print $1; exit}' $L)
    echo "$r $prev->$m ok=$ok start_to_capturing=$(awk -v a=$t0 -v b=$tc 'BEGIN{if(b) printf "%.2f", b-a; else print "-"}') opened_to_capturing=$(awk -v a=$tu -v b=$tc 'BEGIN{if(b&&a) printf "%.2f", b-a; else print "-"}')" | tee -a p12.res
    [ $ok = 0 ] && { echo "--- log of the failed switch"; sed 's/^[0-9.]* //' $L | cut -c1-200; ls /dev/serial/by-id/; }
    kill -TERM $P; for i in $(seq 1 50); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
    prev=$m
  done
done
./k.sh stop > /dev/null
python3 - <<'PY'
import collections, statistics
d = collections.defaultdict(list); fails = collections.Counter()
for l in open("p12.res"):
    f = l.split(); k = f[1]
    if f[2] == "ok=1":
        d[k].append((float(f[3].split("=")[1]), float(f[4].split("=")[1])))
    else:
        fails[k] += 1
for k, v in d.items():
    s = [a for a, b in v]; o = [b for a, b in v]
    print("%-14s n=%d fails=%d start->capturing min %.2f med %.2f max %.2f | opened->capturing min %.2f med %.2f max %.2f" % (
        k, len(v), fails[k], min(s), statistics.median(s), max(s), min(o), statistics.median(o), max(o)))
PY
grep -h "reconnect\|no answer\|lost\|error" p12.r*.py.log | cut -c1-200 | head
ls /dev/serial/by-id/ | wc -l
