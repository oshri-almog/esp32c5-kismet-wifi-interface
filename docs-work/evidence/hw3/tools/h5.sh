#!/bin/bash
# H5: BTLE channel 38. esp32c5btle-<D>:channel=38, then set_channel.cmd 38, 39 and 40, with the C local, C remote
# and Python remote helpers. REST channel must show 37; 40 must be refused.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h5-btle; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TD=$(tty_of $MAC_D); PORT=/dev/$TD
DEF="esp32c5btle-$TD:channel=38"; NAME=esp32c5btle-$TD
U=E5C50003-0000-0000-0000-10BDA3C87D54
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS
chk() {  # chk LABEL
    python3 - "$1" "$U" <<'EOF'
import json, sys, os
sys.path.insert(0, os.path.expanduser("~/e2e/hw3/tools")); import kq
for s in kq.sources():
    if s.get("uuid") == sys.argv[2]:
        print("%-22s running=%s channel=%r hopping=%s hop_channels=%s channels=%s pkts=%s error=%s" % (
            sys.argv[1], s.get("running"), s.get("channel"), s.get("hopping"), s.get("hop_channels"),
            s.get("channels"), s.get("num_packets"), s.get("error_reason") if s.get("error") else ""))
EOF
}
sets() {
    for ch in 38 39 40; do
        echo "--- set_channel.cmd $ch"
        python3 $T/kq.py post /datasource/by-uuid/$U/set_channel.cmd "{\"channel\":\"$ch\"}" | cut -c1-200
        sleep 3
        chk "after set $ch:"
    done
    sleep 3; chk "6 s after set 40:"
}
echo "===== C local: -c $DEF"
kstart h5l $D/local -c "$DEF" || exit 1
python3 $T/kq.py waitrun $NAME 25 | sed 's/^/capturing after (s): /'
chk "at open:"
sets
python3 $T/kq.py msgs 0 > $D/local/msgs.txt
kstop $D/local
grep -i "channel\|$NAME\|tune" $D/local/kismet.log | grep -v "Detected\|advertising" | cut -c1-250 > $D/local/kismet-channel-lines.txt
cat $D/local/kismet-channel-lines.txt

echo "===== C remote (websocket): --source $DEF"
kstart h5r $D/remote || exit 1
$CAP --connect 127.0.0.1:2501 --source "$DEF" > $D/remote/c.helper.log 2>&1 &
P=$!
python3 $T/kq.py waitrun $NAME 25 | sed 's/^/capturing after (s): /'
chk "C remote at open:"
sets
kill -TERM $P; wait $P; echo "C helper exit status $?"
sleep 3
echo "===== Python remote (websocket): --source $DEF"
(cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source "$DEF" > $D/remote/py.helper.log 2>&1) &
Q=$!
sleep 1
python3 $T/kq.py waitrun $NAME 25 | sed 's/^/capturing after (s): /'
chk "Python at open:"
sets
kill -TERM $Q; wait $Q; echo "Python helper exit status $?"
python3 $T/kq.py msgs 0 > $D/remote/msgs.txt
kstop $D/remote
grep -i "channel\|$NAME\|tune" $D/remote/kismet.log | grep -v "Detected\|advertising" | cut -c1-250 > $D/remote/kismet-channel-lines.txt
cat $D/remote/kismet-channel-lines.txt
echo "--- C helper log"; grep -v "^$" $D/remote/c.helper.log | cut -c1-220
echo "--- Python helper log"; grep -v "^$" $D/remote/py.helper.log | cut -c1-220
locks
