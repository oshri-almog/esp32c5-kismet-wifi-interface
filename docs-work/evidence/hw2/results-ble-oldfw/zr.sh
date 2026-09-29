#!/bin/bash
# zr.sh TAG TXPORT: zigbee channel 20 (no hopping) on ttyACM2 through the C remote helper, then the Python remote helper;
# TXTEST 200 on channel 20 from TXPORT in each phase; source packet count per phase; then wifi through each for 20 s.
D=~/e2e/hw2; cd $D
TAG=$1; TX=$2
C=~/kismet-install/bin/kismet_cap_esp32c5
ZSRC="esp32c5zigbee-ttyACM2:channel=20,channel_hop=false"
./k.sh start $TAG >/dev/null || exit 1
start_helper() {  # which source logfile
  if [ $1 = c ]; then KISMET_CAP_USER=admin KISMET_CAP_PASSWORD=hw2-Pass-99 setsid $C --connect 127.0.0.1:2501 --source "$2" > $3 2>&1 & HP=$!
  else (cd ~/esp32c5-kismet-wifi-interface; exec ~/esp32c5-venv/bin/python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --user admin --password hw2-Pass-99 --source "$2" > $3 2>&1) & HP=$!; fi
}
stop_helper() { if [ $1 = c ]; then kill -TERM -$HP; else kill -TERM $HP; fi; wait $HP 2>/dev/null; sleep 3; }
pk() { python3 kq.py src | awk '{print $1, $2, $5, $6, $7}'; }
for h in c py; do
  echo "### zigbee via $h"
  n0=$(grep -c "capturing" $TAG.log)
  start_helper $h "$ZSRC" $TAG.z$h.log
  for i in $(seq 1 100); do [ $(grep -c "capturing" $TAG.log) -gt $n0 ] && break; sleep 0.2; done
  grep "capturing" $TAG.log | tail -1 | cut -c1-200
  pk
  ~/esp32c5-venv/bin/python tx.py $TX 20 200 --back-to-wifi > $TAG.z$h.tx.out 2>&1; tail -2 $TAG.z$h.tx.out
  sleep 7
  pk
  stop_helper $h
done
for h in c py; do
  echo "### wifi via $h"
  start_helper $h esp32c5-ttyACM2 $TAG.w$h.log
  sleep 25
  pk
  stop_helper $h
done
python3 kq.py devs
./k.sh stop >/dev/null
grep KISMET_EXIT $TAG.log
grep -v "Detected new\|advertising" $TAG.log | grep -i "esp32c5\|lost sync\|error" | cut -c1-250
for f in $TAG.z*.log $TAG.w*.log; do echo "## $f"; grep -v "lws_\|__lws\|_lws" $f | grep -v "^$" | cut -c1-250; done
