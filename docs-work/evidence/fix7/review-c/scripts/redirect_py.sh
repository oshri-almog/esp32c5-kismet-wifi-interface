#!/bin/sh
# The Python remote helper against the same redirecting server, for comparison
set -u
R=$(dirname "$0")/..
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
W=$(mktemp -d /tmp/review-c.XXXXXX)
python3 "$REPO/tools/fake_board.py" "$W/port" WIFI > "$W/fake.log" 2>&1 &
FP=$!
python3 "$R/scripts/redirect_srv.py" "$W/heads.log" > "$W/srv.log" 2>&1 &
SP=$!
sleep 1.5
cd "$REPO" && KISMET_CAP_USER=fx KISMET_CAP_PASSWORD='s3cret pw' timeout 8 /root/esp32c5-venv/bin/python -m esp32c5_kismet.remote \
    --connect 127.0.0.1:2621 --source "esp32c5:device=$W/port,name=redir" > "$W/helper.log" 2>&1
echo "python helper exit: $?"
echo "--- request heads seen"
cat "$W/heads.log"
echo "--- helper output (first lines)"
head -4 "$W/helper.log"
kill $SP $FP 2>/dev/null
wait $SP $FP 2>/dev/null
rm -rf "$W"
