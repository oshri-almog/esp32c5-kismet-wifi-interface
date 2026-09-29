echo "== remote capture: kismet_cap_esp32c5 --connect over the websocket, with retry, started with SIGHUP ignored (nohup)"
python3 "$HERE/tools/fake_board.py" "$PORT" WIFI > "$WORK/fake-remote.log" 2>&1 &
FPID=$!
sleep 1
TTY=$(tty_name)
start_kismet remote
wait_kismet
# Every remote helper goes through the relay, which logs each request's head
start_relay
echo "   $HELPER --connect localhost:$RELAY (the relay to 2501) --source esp32c5-$TTY:name=fake-remote,channel=6,channel_hop=false"
T0=$(date +%s%N)
# The login from the environment (login_from_env), which the process list does not show
(trap '' HUP; KISMET_CAP_USER=${USER_PASS%%:*} KISMET_CAP_PASSWORD=${USER_PASS#*:} exec "$HELPER" \
    --connect "localhost:$RELAY" --source "esp32c5-$TTY:name=fake-remote,channel=6,channel_hop=false") \
    > "$WORK/helper-remote.log" 2>&1 &
HPID=$!
first=
for i in $(seq 1 50); do
    if [ "$(src fake-remote kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null; then first=$(ms_since "$T0"); break; fi
    sleep 0.2
done
echo "   first packet in Kismet ${first:-never} ms after the helper started"
# Before add-to-kismet.sh's fix libwebsockets sent what was queued only when Kismet's PING woke it,
# every 5 seconds: the first packet came after 5 s, and the others in bursts
[ -n "$first" ] && [ "$first" -lt 3000 ]; check "the first packet reaches Kismet within 3 s" $?
# Before add-to-kismet.sh's fix the login went in the request line's query, which a reverse
# proxy's access log keeps, and this one, with '&' in it, could not log in at all
echo "   $(grep -m1 "^GET " "$WORK/requests.log")"
grep "^GET " "$WORK/requests.log" > "$WORK/request-lines.txt"
[ -s "$WORK/request-lines.txt" ] && ! grep -q "[?]" "$WORK/request-lines.txt" && \
    ! grep -qiF "pass" "$WORK/request-lines.txt"
check "the request line holds no login: no query at all" $?
[ "$(basic_login "$WORK/requests.log")" = "$USER_PASS" ]
check "the login is in an Authorization header, Basic, exactly user:password with its '&', space and %41" $?
grew=0 before=$(src fake-remote kismet.datasource.num_packets)
for i in 1 2 3 4 5; do
    sleep 1
    now=$(src fake-remote kismet.datasource.num_packets)
    [ "$now" -gt "$before" ] 2>/dev/null && grew=$((grew + 1))
    before=$now
done
echo "   packets arrived in $grew of 5 seconds"
[ "$grew" -eq 5 ]; check "... and more every second, not in bursts" $?
! grep -q "\] N: " "$WORK/helper-remote.log"; check "no libwebsockets notices on the helper's stderr" $?
# A channel set the helper takes: the framework used to print an empty "INFO: " line for each
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_PASS" --data-urlencode 'json={"channel": "6"}' \
    "$API/datasource/by-uuid/$(src fake-remote kismet.datasource.uuid)/set_channel.cmd")
sleep 1
echo "   set_channel 6: HTTP $code"
[ "$code" = 200 ] && ! grep -qx "INFO: " "$WORK/helper-remote.log"
check "a channel set is taken, and leaves no empty \"INFO: \" line on the helper's stderr" $?

CPID=$(children_of "$HPID")
echo "   helper $HPID, capture process ${CPID:-none}; flock on the port held by: $(lock_holders "$PORT")"
# SigCgt, the signals a handler catches: SIGTERM is bit 14. On a pseudo-terminal the exclusive mode
# it ends is not used, so only this shows that the handler is there
caught=$(sed -n 's/^SigCgt:[[:space:]]*//p' "/proc/${CPID:-0}/status" 2>/dev/null)
[ -n "$caught" ] && [ $(( 0x$caught >> 14 & 1 )) -eq 1 ]
check "the capture process catches SIGTERM, to end the port's exclusive mode before it ends" $?
kill -HUP "$HPID" $CPID
sleep 2
before=$(src fake-remote kismet.datasource.num_packets)
sleep 1
[ -n "$CPID" ] && alive "$HPID" $CPID && [ "$(src fake-remote kismet.datasource.num_packets)" -gt "$before" ] 2>/dev/null
check "SIGHUP, which it was started ignoring, leaves the helper and its capture process capturing" $?

# The same board and radio have the same uuid, and Kismet would close the running source for the
# newcomer: a remote helper does not offer a port that another process holds
timeout 20 env "KISMET_CAP_USER=${USER_PASS%%:*}" "KISMET_CAP_PASSWORD=${USER_PASS#*:}" "$HELPER" \
    --connect "localhost:$RELAY" --disable-retry --source "esp32c5-$TTY:name=fake-remote2" \
    > "$WORK/helper-remote2.log" 2>&1
grep -qF "fake-remote2: /dev/$TTY is already in use by another capture; not offering it to Kismet" \
    "$WORK/helper-remote2.log"; check "a second remote helper on the same board is refused before it connects" $?
before=$(src fake-remote kismet.datasource.num_packets)
sleep 1
! logged remote "matches existing source" && [ "$(src fake-remote kismet.datasource.num_packets)" -gt "$before" ] 2>/dev/null
check "... and the first goes on capturing" $?

api "/datasource/by-uuid/$(src fake-remote kismet.datasource.uuid)/close_source.cmd" > /dev/null
sleep 2
[ -n "$CPID" ] && ! alive $CPID && [ -z "$(lock_holders "$PORT")" ]
check "close_source.cmd: the capture process ends, and the port is free" $?
for i in $(seq 1 30); do
    [ "$(src fake-remote kismet.datasource.running)" = 1 ] && [ -n "$(children_of "$HPID")" ] && break
    sleep 0.5
done
CPID=$(children_of "$HPID")
echo "   capture process now ${CPID:-none}"
[ "$(src fake-remote kismet.datasource.running)" = 1 ] && [ -n "$CPID" ]
check "... and the helper connects again 5 s later, and captures" $?

kill -TERM "$HPID"
sleep 1
[ -n "$CPID" ] && ! alive "$HPID" && ! alive $CPID && [ -z "$(lock_holders "$PORT")" ]
check "kill -TERM of the helper ends its capture process with it, and frees the port within 1 s" $?
for p in $HPID $CPID; do alive "$p" && kill "$p"; done
wait "$HPID" 2>/dev/null
HPID= CPID=
# libwebsockets reports each of the machine's routes to its own listeners as a connection starts,
# and its queue used to drop those past 40, with a warning each, on every connection
echo "   this machine has $(cat /proc/net/route 2>/dev/null | tail -n +2 | wc -l) IPv4 routes in its main table; libwebsockets warned when all its tables held more than 40"
! grep -q "rejecting message on queue depth" "$WORK/helper-remote.log"
check "no libwebsockets \"rejecting message on queue depth\" warnings, through two connections" $?

echo "== remote capture with an API key (KISMET_CAP_APIKEY)"
KEY=$(curl -s -u "$USER_PASS" --data-urlencode 'json={"name": "e2e", "role": "datasource", "duration": 0}' \
    "$API/auth/apikey/generate.cmd")
echo "   a datasource key from Kismet: ${KEY:-none}"
heads=$(grep -c "^== connection" "$WORK/requests.log")
(KISMET_CAP_APIKEY=$KEY exec "$HELPER" --connect "localhost:$RELAY" \
    --source "esp32c5-$TTY:name=fake-remotekey,uuid=E2E0E2E0-0000-0000-0000-00000000000A") \
    > "$WORK/helper-remotekey.log" 2>&1 &
HPID=$!
for i in $(seq 1 50); do
    [ "$(src fake-remotekey kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null && break
    sleep 0.2
done
[ "$(src fake-remotekey kismet.datasource.num_packets)" -gt 0 ] 2>/dev/null; check "the helper logs in with it, and captures" $?
sed -n "/^== connection $((heads + 1))\$/,\$p" "$WORK/requests.log" > "$WORK/requests-key.txt"
echo "   $(grep -m1 "^GET " "$WORK/requests-key.txt")"
[ -n "$KEY" ] && grep -q "^GET " "$WORK/requests-key.txt" && ! grep "^GET " "$WORK/requests-key.txt" | grep -q "[?]"
check "the request line holds no key" $?
grep -qix "cookie: KISMET=$KEY" "$WORK/requests-key.txt"; check "the key is in Kismet's session cookie, KISMET" $?
CPID=$(children_of "$HPID")
kill -TERM "$HPID"
sleep 1
for p in $HPID $CPID; do alive "$p" && kill "$p"; done
wait "$HPID" 2>/dev/null
HPID= CPID=

echo "== remote capture with a login too long for the request's headers"
heads=$(grep -c "^== connection" "$WORK/requests.log")
timeout 20 env "KISMET_CAP_USER=${USER_PASS%%:*}" "KISMET_CAP_PASSWORD=$(printf '%5000s' | tr ' ' x)" "$HELPER" \
    --connect "localhost:$RELAY" --disable-retry --source "esp32c5-$TTY:name=fake-long" \
    > "$WORK/helper-long.log" 2>&1
status=$?
grep "FATAL" "$WORK/helper-long.log" | sed 's/^/   helper: /'
grep -qF "FATAL: The login does not fit in the websocket request's headers" "$WORK/helper-long.log"
check "it is refused with a reason, rather than sent cut short" $?
[ "$status" -ne 124 ] && [ "$(grep -c "^== connection" "$WORK/requests.log")" = "$heads" ]
check "... nothing is sent, and the helper ends (--disable-retry; exit status $status) rather than wait" $?
finish_case remote
report remote
sed 's/^/   helper: /' "$WORK/helper-remote.log"
