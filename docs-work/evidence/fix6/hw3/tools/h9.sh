#!/bin/bash
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
echo "===== C local"; mkdir -p $D/clocal
prior 2>&1 | tee $D/clocal/prior.txt
defs
kstart h9cl $D/clocal -c $S1 -c $S2 -c $S3 -c $S4 || exit 1
python3 $T/kq.py poll $D/clocal/poll.jsonl 60 10
report $D/clocal
kstop $D/clocal
echo "usb devnums after: $(devnums)" | tee -a $D/clocal/prior.txt
python3 $T/summ.py $D/clocal > $D/clocal/summary.txt; grep -v "^ *[0-9.]* INFO: Detected" $D/clocal/summary.txt | tail -40

echo "===== Python remote, one process"; mkdir -p $D/pyremote
prior 2>&1 | tee $D/pyremote/prior.txt
defs
kstart h9py $D/pyremote || exit 1
now > $D/pyremote/helpers.t0
(cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source $S1 --source $S2 --source $S3 --source $S4 > $D/pyremote/py.helper.log 2>&1) &
Q=$!
python3 $T/kq.py poll $D/pyremote/poll.jsonl 60 10
report $D/pyremote
kill -TERM $Q; wait $Q; echo "Python helper exit status $?"
kstop $D/pyremote
echo "usb devnums after: $(devnums)" | tee -a $D/pyremote/prior.txt
python3 $T/summ.py $D/pyremote $D/pyremote/helpers.t0 > $D/pyremote/summary.txt; tail -40 $D/pyremote/summary.txt

echo "===== C remote, four processes (websocket)"; mkdir -p $D/cremote
prior 2>&1 | tee $D/cremote/prior.txt
defs
kstart h9cr $D/cremote || exit 1
now > $D/cremote/helpers.t0
$CAP --connect 127.0.0.1:2501 --source $S1 > $D/cremote/1.helper.log 2>&1 & P1=$!
$CAP --connect 127.0.0.1:2501 --source $S2 > $D/cremote/2.helper.log 2>&1 & P2=$!
$CAP --connect 127.0.0.1:2501 --source $S3 > $D/cremote/3.helper.log 2>&1 & P3=$!
$CAP --connect 127.0.0.1:2501 --source $S4 > $D/cremote/4.helper.log 2>&1 & P4=$!
python3 $T/kq.py poll $D/cremote/poll.jsonl 60 10
report $D/cremote
kill -TERM $P1 $P2 $P3 $P4; wait $P1 $P2 $P3 $P4; echo "C helpers exit status $?"
kstop $D/cremote
echo "usb devnums after: $(devnums)" | tee -a $D/cremote/prior.txt
python3 $T/summ.py $D/cremote $D/cremote/helpers.t0 > $D/cremote/summary.txt; tail -40 $D/cremote/summary.txt
for i in 1 2 3 4; do echo "--- C helper $i stderr"; cat $D/cremote/$i.helper.log; done
locks
