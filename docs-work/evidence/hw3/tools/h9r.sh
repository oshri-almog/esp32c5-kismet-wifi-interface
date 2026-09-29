#!/bin/bash
# H9 repeat of the C remote part (four C remote helpers over the websocket), into h9-regress/TAG.
# H9: four sources at once for 60 s by the short names (two Wi-Fi, zigbee, btle), with the prior radios set as in
# hw2's n1c (A in BLE, B, C, D in Wi-Fi): C local; then one Python remote helper with the four sources; then
# four C remote helpers over the websocket.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h9-regress; mkdir -p $D; cd $D
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
devnums() { for d in /sys/bus/usb/devices/1-1.2.*; do [ -f $d/serial ] && printf "%s=%s " "$(cat $d/serial)" "$(cat $d/devnum)"; done; echo; }
prior() {  # prior DIR: A to BLE, the others to Wi-Fi
    $PY $T/tx.py /dev/$(tty_of $MAC_A) --mode-only BLE
    $PY $T/tx.py /dev/$(tty_of $MAC_B) --mode-only WIFI
    $PY $T/tx.py /dev/$(tty_of $MAC_C) --mode-only WIFI
    $PY $T/tx.py /dev/$(tty_of $MAC_D) --mode-only WIFI
    sleep 2
    echo "mapping: $(mapping)"; echo "usb devnums: $(devnums)"
}
defs() {
    S1=esp32c5-$(tty_of $MAC_A); S2=esp32c5-$(tty_of $MAC_B)
    S3=esp32c5zigbee-$(tty_of $MAC_C); S4=esp32c5btle-$(tty_of $MAC_D)
}
report() {  # report DIR
    python3 $T/kq.py src | tee $1/src-end.txt
    python3 $T/kq.py srcjson > $1/src.json
    python3 $T/kq.py devs > $1/devs.txt; echo "devices per phy: $(head -1 $1/devs.txt)"
}
TAG=${1:?tag}
echo "===== C remote, four processes (websocket), repeat $TAG"; mkdir -p $D/$TAG
prior 2>&1 | tee $D/$TAG/prior.txt
defs
kstart h9$TAG $D/$TAG || exit 1
now > $D/$TAG/helpers.t0
$CAP --connect 127.0.0.1:2501 --source $S1 > $D/$TAG/1.helper.log 2>&1 & P1=$!
$CAP --connect 127.0.0.1:2501 --source $S2 > $D/$TAG/2.helper.log 2>&1 & P2=$!
$CAP --connect 127.0.0.1:2501 --source $S3 > $D/$TAG/3.helper.log 2>&1 & P3=$!
$CAP --connect 127.0.0.1:2501 --source $S4 > $D/$TAG/4.helper.log 2>&1 & P4=$!
python3 $T/kq.py poll $D/$TAG/poll.jsonl 60 10
report $D/$TAG
kill -TERM $P1 $P2 $P3 $P4; wait $P1 $P2 $P3 $P4; echo "C helpers exit status $?"
kstop $D/$TAG
echo "usb devnums after: $(devnums)" | tee -a $D/$TAG/prior.txt
python3 $T/summ.py $D/$TAG $D/$TAG/helpers.t0 > $D/$TAG/summary.txt; tail -40 $D/$TAG/summary.txt
for i in 1 2 3 4; do echo "--- C helper $i stderr"; cat $D/$TAG/$i.helper.log; done
locks
