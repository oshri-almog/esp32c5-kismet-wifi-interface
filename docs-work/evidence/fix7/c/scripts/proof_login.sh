#!/bin/sh
# Before/after: where the websocket login goes, whether it logs in, the lws queue warnings and
# the empty "INFO: " lines. Kismet 2601 with a password holding '&', a space and %41; the
# helpers connect through the logging relay on 2602, which records each request's head.
#     proof_login.sh BEFORE-HELPER AFTER-HELPER
. /mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/scripts/lib.sh
KPASS='p&w %41x'
BEFORE=$1 AFTER=$2
setup_case login
start_kismet || exit 1
start_proxy
KEY=$(new_apikey proof)
echo "api key: $KEY" | tee "$LOG/summary.txt"
start_fake login /root/fix7c/w/pty-login WIFI
n=0
for label in before after; do
    eval helper=\$$(echo $label | tr a-z A-Z)
    for how in login key; do
        n=$((n + 1))
        name=pf-$label-$how
        uuid=$(printf 'AAAAAAAA-0000-0000-0000-%012d' $n)
        : > "$LOG/$name.stderr"
        echo "== $name ($helper)" | tee -a "$LOG/requests.txt"
        if [ $how = login ]; then
            env KISMET_CAP_USER="$KUSER" KISMET_CAP_PASSWORD="$KPASS" "$helper" --connect 127.0.0.1:$PROXY_PORT \
                --source "esp32c5:device=/root/fix7c/w/pty-login,name=$name,uuid=$uuid" > "$LOG/$name.stderr" 2>&1 &
        else
            env KISMET_CAP_APIKEY="$KEY" "$helper" --connect 127.0.0.1:$PROXY_PORT \
                --source "esp32c5:device=/root/fix7c/w/pty-login,name=$name,uuid=$uuid" > "$LOG/$name.stderr" 2>&1 &
        fi
        HPID=$!
        sleep 8
        code=$(curl -s -o /dev/null -w '%{http_code}' -u "$KUSER:$KPASS" --data-urlencode 'json={"channel": "11"}' \
            "$API/datasource/by-uuid/$uuid/set_channel.cmd")
        sleep 2
        running=$(src_field $name kismet.datasource.running) packets=$(src_field $name kismet.datasource.num_packets)
        chan=$(src_field $name kismet.datasource.channel)
        smd=$(grep -c "rejecting message on queue depth" "$LOG/$name.stderr")
        empty=$(grep -cx "INFO: " "$LOG/$name.stderr")
        echo "$name: running=${running:-none} packets=${packets:-none} set_channel 11: HTTP $code, channel now ${chan:-none}; stderr: $smd 'rejecting message on queue depth' line(s), $empty empty 'INFO: ' line(s)" | tee -a "$LOG/summary.txt"
        stop_pids $HPID $(children_of $HPID)
        wait $HPID 2>/dev/null
        sleep 1
    done
done
echo "--- request heads through the relay:" >> "$LOG/summary.txt"
cat "$LOG/requests.txt" >> "$LOG/summary.txt"
grep -n "Unauthorized\|401\|login\|remote" "$LOG/kismet.log" | tail -20 > "$LOG/kismet-login-lines.txt"
stop_all
