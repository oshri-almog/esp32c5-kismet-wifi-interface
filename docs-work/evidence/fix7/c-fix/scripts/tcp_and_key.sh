#!/bin/sh
# --tcp with an unused ':' login too long for the websocket URI; a 5000 character API key.
#     tcp_and_key.sh HELPER...
set -u
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
W=$(mktemp -d /root/fix7cf/tk.XXXXXX)
python3 "$REPO/tools/fake_board.py" "$W/port" WIFI > "$W/fake.log" 2>&1 &
FP=$!
# listeners that take a connection and say nothing: 3601 for the TCP case, 2601 for the websocket
python3 -c '
import socket, time
for port in (3601, 2601):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(8)
    globals()["s%d" % port] = s
time.sleep(60)' &
LP=$!
sleep 1.5
long=$(printf '%1000s' | tr ' ' x)
key=$(printf '%5000s' | tr ' ' k)
for h in "$@"; do
    echo "##### $h --tcp --user a:b --password <1000 x>"
    timeout 4 "$h" --connect 127.0.0.1:3601 --tcp --disable-retry --user a:b --password "$long" \
        --source "esp32c5:device=$W/port,name=tcp" > "$W/out" 2>&1
    echo "exit $? (124: still running after 4 s, connected)"
    head -4 "$W/out" | cut -c1-200
    echo "##### $h KISMET_CAP_APIKEY=<5000 k>"
    KISMET_CAP_APIKEY=$key timeout 10 "$h" --connect 127.0.0.1:2601 --disable-retry \
        --source "esp32c5:device=$W/port,name=key" > "$W/out" 2>&1
    echo "exit $?"
    cut -c1-200 "$W/out"
done
kill $LP $FP 2>/dev/null
wait $LP $FP 2>/dev/null
rm -rf "$W"
