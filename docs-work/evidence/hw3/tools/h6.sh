#!/bin/bash
# H6: websocket logins with awkward characters. (1) a Kismet whose password holds a space and '%41': the C
# helper (and the Python helper) must log in and capture. (2) a password with '&': the C helper warns and gets
# 401; the Python helper (Authorization header since the fix) logs in. (3) a user name with ':' and a password
# with '&': the Python helper warns and gets 401.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h6-login; mkdir -p $D; cd $D
echo "mapping: $(mapping)" | tee $D/mapping.txt
TB=$(tty_of $MAC_B); SRC=esp32c5-$TB
curlchk() {  # curlchk USER PASS
    printf "curl Basic %-28s -> HTTP %s\n" "'$1:$2'" "$(curl -s -o /dev/null -w '%{http_code}' -u "$1:$2" http://127.0.0.1:2501/system/status.json)"
}
try() {  # try TAG KIND SECS
    local tag=$1 kind=$2 secs=$3
    if [ $kind = c ]; then
        $CAP --connect 127.0.0.1:2501 --source $SRC > $DIR/$tag.helper.log 2>&1 &
    else
        (cd $REPO && exec $PY -u -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source $SRC > $DIR/$tag.helper.log 2>&1) &
    fi
    local P=$!
    local r=$(python3 $T/kq.py waitrun $SRC $secs)
    echo "$tag: helper pid $P; capturing in Kismet after: $r s"
    python3 $T/kq.py src | cut -c1-150 | sed "s/^/$tag src: /"
    kill -TERM $P; wait $P; echo "$tag: exit status $?"
    for c in $(cat /proc/$P/task/*/children 2>/dev/null); do echo "left child $c"; done
    echo "--- $tag helper output:"; grep -v "^$" $DIR/$tag.helper.log | grep -v "capturing\|^[0-9.]* DEBUG" | cut -c1-400 | head -20
    sleep 2
}
echo "########## (1) password 'hw3 Pass%41x'"
export KUSER=admin KPASS='hw3 Pass%41x'; DIR=$D/space; mkdir -p $DIR
kstart h6a $DIR || exit 1
cat /tmp/hw3/h6a/.kismet/kismet_httpd.conf | sed 's/^/httpd.conf: /'
curlchk admin 'hw3 Pass%41x'; curlchk admin 'hw3 PassAx'
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS HW3_AUTH="$KUSER:$KPASS"
try c1 c 20
try py1 py 20
kstop $DIR
echo "########## (2) password 'hw3&Pass'"
export KUSER=admin KPASS='hw3&Pass'; DIR=$D/amp; mkdir -p $DIR
kstart h6b $DIR || exit 1
cat /tmp/hw3/h6b/.kismet/kismet_httpd.conf | sed 's/^/httpd.conf: /'
curlchk admin 'hw3&Pass'
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS HW3_AUTH="$KUSER:$KPASS"
try c2 c 12
try py2 py 20
kstop $DIR
echo "########## (3) user 'ad:min', password 'hw3&Pass'"
export KUSER='ad:min' KPASS='hw3&Pass'; DIR=$D/colon; mkdir -p $DIR
kstart h6c $DIR || exit 1
cat /tmp/hw3/h6c/.kismet/kismet_httpd.conf | sed 's/^/httpd.conf: /'
export KISMET_CAP_USER=$KUSER KISMET_CAP_PASSWORD=$KPASS HW3_AUTH="$KUSER:$KPASS"
echo "(REST from this script cannot log in with Basic either, as ':' ends the user name: $(curl -s -o /dev/null -w '%{http_code}' -u 'ad:min:hw3&Pass' http://127.0.0.1:2501/system/status.json))"
try py3 py 12
try c3 c 12
kstop $DIR
locks
