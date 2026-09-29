#!/bin/bash
# H8: frequency in kismetdb. Zigbee on board A locked on channel 20, Wi-Fi hopping on board C, BTLE on board D;
# board B sends TXTEST 200 on channel 20. With the C local, C remote (three processes) and Python remote (one
# process) helpers; kismetdb logging on; the packets table queried after Kismet stops.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h8-freq; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TA=$(tty_of $MAC_A); TB=$(tty_of $MAC_B); TC=$(tty_of $MAC_C); TD=$(tty_of $MAC_D)
Z="esp32c5zigbee-$TA:channel=20,channel_hop=false"; ZN=esp32c5zigbee-$TA
W="esp32c5-$TC"; B="esp32c5btle-$TD"
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
waitrun3() {
    for i in $(seq 1 100); do
        n=$(python3 $T/kq.py src | grep -c "run=1")
        [ "$n" -ge 3 ] && break; sleep 0.25
    done
    sleep 3
}
body() {  # body VARIANT
    local v=$1 DV=$D/$1
    waitrun3
    python3 $T/kq.py src | tee $DV/src-before-tx.txt
    python3 $T/kq.py src | grep "$ZN" | grep -o "pkts=[0-9]*" > $DV/zb-before.txt
    $PY $T/tx.py /dev/$TB 20 200 --back-to-wifi 2>&1 | tee $DV/tx.out
    sleep 8
    python3 $T/kq.py src | tee $DV/src-after-tx.txt
    echo "zigbee packets before TXTEST $(cat $DV/zb-before.txt), after: $(grep "$ZN" $DV/src-after-tx.txt | grep -o 'pkts=[0-9]*')"
    python3 $T/kq.py devs 802.15.4 | tee $DV/devs-802154.txt | head -5
    python3 $T/kq.py devs BTLE > $DV/devs-btle.txt; head -3 $DV/devs-btle.txt
    sleep 15
}
echo "===== C local"
mkdir -p $D/clocal
LOGGING=1 kstart h8cl $D/clocal -c "$Z" -c "$W" -c "$B" || exit 1
body clocal
kstop $D/clocal
python3 $T/kdb.py /tmp/hw3/h8cl/h8cl-*.kismet | tee $D/clocal/kdb.txt
cp /tmp/hw3/h8cl/h8cl-*.kismet $D/clocal/

echo "===== C remote (three helpers)"
mkdir -p $D/cremote
LOGGING=1 kstart h8cr $D/cremote || exit 1
$CAP --connect 127.0.0.1:2501 --source "$Z" > $D/cremote/z.helper.log 2>&1 & P1=$!
$CAP --connect 127.0.0.1:2501 --source "$W" > $D/cremote/w.helper.log 2>&1 & P2=$!
$CAP --connect 127.0.0.1:2501 --source "$B" > $D/cremote/b.helper.log 2>&1 & P3=$!
body cremote
kill -TERM $P1 $P2 $P3; wait $P1 $P2 $P3
kstop $D/cremote
python3 $T/kdb.py /tmp/hw3/h8cr/h8cr-*.kismet | tee $D/cremote/kdb.txt
cp /tmp/hw3/h8cr/h8cr-*.kismet $D/cremote/

echo "===== Python remote (one helper, three sources)"
mkdir -p $D/pyremote
LOGGING=1 kstart h8py $D/pyremote || exit 1
(cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source "$Z" --source "$W" --source "$B" > $D/pyremote/py.helper.log 2>&1) &
Q=$!
body pyremote
kill -TERM $Q; wait $Q
kstop $D/pyremote
python3 $T/kdb.py /tmp/hw3/h8py/h8py-*.kismet | tee $D/pyremote/kdb.txt
cp /tmp/hw3/h8py/h8py-*.kismet $D/pyremote/
ls -la /tmp/hw3/h8cl /tmp/hw3/h8cr /tmp/hw3/h8py | grep kismet
locks
