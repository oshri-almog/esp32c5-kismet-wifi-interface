#!/bin/sh
# A helper against a server that redirects the websocket to another host: what that host gets.
#     redirect_demo.sh HELPER
set -u
HELPER=$1
R=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c-fix/scripts
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
W=$(mktemp -d /root/fix7cf/redir.XXXXXX)
python3 "$REPO/tools/fake_board.py" "$W/port" WIFI > "$W/fake.log" 2>&1 &
FP=$!
python3 "$R/redirect_srv.py" "$W/heads.log" > "$W/srv.log" 2>&1 &
SP=$!
sleep 1.5
for login in user key; do
    : > "$W/heads.log"
    echo "##### $HELPER, $login"
    if [ $login = key ]; then
        KISMET_CAP_APIKEY=DEADBEEF0123456789 timeout 12 "$HELPER" --connect 127.0.0.1:2601 --disable-retry \
            --source "esp32c5:device=$W/port,name=redir" > "$W/helper.log" 2>&1
    else
        KISMET_CAP_USER=fx KISMET_CAP_PASSWORD='s3cret pw' timeout 12 "$HELPER" --connect 127.0.0.1:2601 --disable-retry \
            --source "esp32c5:device=$W/port,name=redir" > "$W/helper.log" 2>&1
    fi
    echo "helper exit: $?"
    sleep 0.5
    echo "--- request heads seen"
    cat "$W/heads.log"
    echo "--- helper stderr"
    cat "$W/helper.log"
done
kill $SP $FP 2>/dev/null
wait $SP $FP 2>/dev/null
rm -rf "$W"
