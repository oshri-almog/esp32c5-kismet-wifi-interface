#!/bin/bash
# H10: firmware without the BTLE radio (tools/fake_board.py --lacks BLE, on a pseudo-terminal) as a BTLE source,
# 45 s each: C local, then Python remote. 'capturing' must never alternate with 'lost sync'.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h10-oldfw; mkdir -p $D; cd $D
$PY $REPO/tools/fake_board.py --help > $D/fake_board-help.txt 2>&1
PORT=/tmp/hw3/h10-pty/nob
fake() {  # fake LOG: start the fake board lacking BLE (boots in Wi-Fi); pid in FPID
    mkdir -p /tmp/hw3/h10-pty; rm -f $PORT
    python3 -u $REPO/tools/fake_board.py $PORT WIFI --lacks BLE > $1 2>&1 &
    FPID=$!
    for i in $(seq 1 40); do [ -e $PORT ] && break; sleep 0.1; done
    echo "fake board pid $FPID, $PORT -> $(readlink -f $PORT)"
}
count() {  # count FILE
    echo "  'capturing' lines: $(grep -c 'oldfw capturing' $1); 'lost sync' lines: $(grep -c 'oldfw: lost sync' $1); give-ups ('no capture from the board' / 'has not been capturing'): $(grep -c 'no capture from the board\|has not been capturing' $1)"
}
echo "===== C local: esp32c5:device=$PORT,mode=btle,name=oldfw"
mkdir -p $D/clocal
fake $D/clocal/fake.log
kstart h10c $D/clocal -c "esp32c5:device=$PORT,mode=btle,name=oldfw" || { kill $FPID; exit 1; }
python3 $T/kq.py poll $D/clocal/poll.jsonl 45 2
python3 $T/kq.py src | tee $D/clocal/src-end.txt
kstop $D/clocal
kill -TERM $FPID; wait $FPID
T0=$(cat $D/clocal/kismet.t0)
grep -i "oldfw" $D/clocal/kismet.log | grep -v "Detected" | awk -v t0=$T0 '{t=$1; $1=""; printf "%7.2f%s\n", t-t0, $0}' | cut -c1-300 | tee $D/clocal/oldfw-lines.txt
echo "Kismet log, C local:"; count $D/clocal/kismet.log
grep "MODE\|START\|lacks\|ignored" $D/clocal/fake.log | head -12

echo "===== Python remote: --source esp32c5:device=$PORT,mode=btle,name=oldfw"
mkdir -p $D/pyremote
fake $D/pyremote/fake.log
kstart h10p $D/pyremote || { kill $FPID; exit 1; }
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
now > $D/pyremote/helper.t0
(cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source "esp32c5:device=$PORT,mode=btle,name=oldfw" > $D/pyremote/py.helper.log 2>&1) &
Q=$!
python3 $T/kq.py poll $D/pyremote/poll.jsonl 45 2
python3 $T/kq.py src | tee $D/pyremote/src-end.txt
kill -TERM $Q; wait $Q; echo "Python helper exit status $?"
kstop $D/pyremote
kill -TERM $FPID; wait $FPID
echo "Python helper log:"; count $D/pyremote/py.helper.log
echo "Kismet log, Python remote:"; count $D/pyremote/kismet.log
T0=$(cat $D/pyremote/helper.t0)
grep -v "^$" $D/pyremote/py.helper.log | cut -c1-250 | head -30
grep -i "oldfw" $D/pyremote/kismet.log | grep -v "Detected" | awk -v t0=$T0 '{t=$1; $1=""; printf "%7.2f%s\n", t-t0, $0}' | cut -c1-300 | tee $D/pyremote/oldfw-lines.txt
