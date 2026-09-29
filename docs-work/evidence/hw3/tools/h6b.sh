#!/bin/bash
# H6 supplement: in h6.sh (1) the Python helper ran right after the C helper, so Kismet's record of the source
# was already running with packets and the wait proved nothing. Here the Python helper alone, in a fresh Kismet
# whose password holds a space and '%41', must log in and bring packets.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h6-login/space-py; mkdir -p $D; cd $D
TB=$(tty_of $MAC_B); SRC=esp32c5-$TB
export KUSER=admin KPASS='hw3 Pass%41x'
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS HW3_AUTH="$KUSER:$KPASS"
kstart h6d $D || exit 1
cat /tmp/hw3/h6d/.kismet/kismet_httpd.conf | sed 's/^/httpd.conf: /'
python3 $T/kq.py src | sed 's/^/before the helper: /'
(cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source $SRC > $D/py.helper.log 2>&1) &
P=$!
echo "capturing in Kismet after: $(python3 $T/kq.py waitrun $SRC 20) s"
sleep 5
python3 $T/kq.py src
kill -TERM $P; wait $P; echo "exit status $?"
cat $D/py.helper.log
kstop $D
