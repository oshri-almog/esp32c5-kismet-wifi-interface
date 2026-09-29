#!/bin/sh
# Runs a helper against a server that redirects the websocket upgrade to another host, and shows
# what that other host receives.  HELPER=... LOGIN=user|key
set -u
R=$(dirname "$0")/..
HELPER=${HELPER:-/root/kismet-install/bin/kismet_cap_esp32c5}
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
W=$(mktemp -d /tmp/review-c.XXXXXX)
python3 "$REPO/tools/fake_board.py" "$W/port" WIFI > "$W/fake.log" 2>&1 &
FP=$!
python3 "$R/scripts/redirect_srv.py" "$W/heads.log" > "$W/srv.log" 2>&1 &
SP=$!
sleep 1.5
if [ "${LOGIN:-user}" = key ]; then
    KISMET_CAP_APIKEY=DEADBEEF0123456789 timeout 12 "$HELPER" --connect 127.0.0.1:2621 --disable-retry \
        --source "esp32c5:device=$W/port,name=redir" > "$W/helper.log" 2>&1
else
    KISMET_CAP_USER=fx KISMET_CAP_PASSWORD='s3cret pw' timeout 12 "$HELPER" --connect 127.0.0.1:2621 --disable-retry \
        --source "esp32c5:device=$W/port,name=redir" > "$W/helper.log" 2>&1
fi
echo "helper exit: $?"
echo "--- request heads seen"
cat "$W/heads.log"
echo "--- helper stderr (last lines)"
tail -5 "$W/helper.log"
kill $SP $FP 2>/dev/null
wait $SP $FP 2>/dev/null
rm -rf "$W"
