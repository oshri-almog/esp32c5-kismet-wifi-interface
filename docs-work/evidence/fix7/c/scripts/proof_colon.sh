#!/bin/sh
# A user name with ':' (the query fallback), with and without '&' in the login, and a login too
# long for the request's headers, before and after. Kismet 2601, the logging relay on 2602.
#     proof_colon.sh BEFORE-HELPER AFTER-HELPER
. /mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/scripts/lib.sh
BEFORE=$1 AFTER=$2
# curl -u would split this user name at its ':': the REST calls log in through the query
qlogin() { python3 -c 'import sys, urllib.parse as u; print("user=%s&password=%s" % (u.quote(sys.argv[1], safe=""), u.quote(sys.argv[2], safe="")))' "$KUSER" "$KPASS"; }
api() { curl -s "$API$1?$(qlogin)"; }

run_helper() {  # run_helper NAME HELPER USER PASSWORD SECONDS
    uuid=$(printf 'BBBBBBBB-0000-0000-0000-%012d' $N)
    N=$((N + 1))
    echo "== $1 ($2)" >> "$LOG/requests.txt"
    env KISMET_CAP_USER="$3" KISMET_CAP_PASSWORD="$4" "$2" --connect 127.0.0.1:$PROXY_PORT \
        --source "esp32c5:device=/root/fix7c/w/pty-colon,name=$1,uuid=$uuid" > "$LOG/$1.stderr" 2>&1 &
    HPID=$!
    sleep "$5"
    running=$(src_field "$1" kismet.datasource.running) packets=$(src_field "$1" kismet.datasource.num_packets)
    echo "$1: running=${running:-none} packets=${packets:-none}; stderr: $(grep -c "cannot log in either way" "$LOG/$1.stderr") login warning(s), $(grep -c "FATAL" "$LOG/$1.stderr") FATAL line(s)" | tee -a "$LOG/summary.txt"
    stop_pids $HPID $(children_of $HPID)
    wait $HPID 2>/dev/null
    sleep 1
}
N=1

# 1. A user name with ':' and no '&': it goes in the query, percent-encoded, and logs in
KUSER='fx:colon' KPASS='p w%41'
setup_case colon
start_kismet || exit 1
start_proxy
start_fake colon /root/fix7c/w/pty-colon WIFI
for label in before after; do
    eval helper=\$$(echo $label | tr a-z A-Z)
    run_helper pc-$label-colon "$helper" "$KUSER" "$KPASS" 8
done
stop_all

# 2. A user name with ':' and an '&' in the password: it cannot log in, and the helper says so;
# 3. a password too long for what lws leaves for the headers (and, before, for the URI)
# No one can log in to this Kismet, the REST API included: it is up when it answers 401
KUSER='fx:colon' KPASS='p&w'
CASE_LOG=$LOG
setup_case colon-amp
api() { curl -s -o /dev/null -w 'HTTP %{http_code}' "$API$1"; }
src_field() { :; }
start_kismet() {
    (cd "$WORK" && exec "$KISMET" --homedir "$WORK/home" --no-ncurses --no-logging --override "$WORK/override.conf") > "$LOG/kismet.log" 2>&1 &
    KPID=$!; STARTED="$STARTED $KPID"
    for i in $(seq 1 120); do
        [ "$(api /system/status.json)" = "HTTP 401" ] && { echo "kismet up (pid $KPID)"; return 0; }
        sleep 0.5
    done
    return 1
}
start_kismet || exit 1
start_proxy
start_fake colon /root/fix7c/w/pty-colon WIFI
for label in before after; do
    eval helper=\$$(echo $label | tr a-z A-Z)
    run_helper pc-$label-colon-amp "$helper" "$KUSER" "$KPASS" 7
done
LONG=$(python3 -c 'print("x" * 5000)')
for label in before after; do
    eval helper=\$$(echo $label | tr a-z A-Z)
    run_helper pc-$label-long "$helper" fx "$LONG" 7
done
grep -h "FATAL\|login\|WARNING" "$LOG"/pc-*-long.stderr "$LOG"/pc-*-colon-amp.stderr | sort | uniq -c >> "$LOG/summary.txt"
# request lines only (the long ones cut to 150 characters)
grep -n "^GET\|^==\|^<-\|^authorization\|^cookie" "$LOG/requests.txt" | cut -c1-150 >> "$LOG/summary.txt"
stop_all
cat "$CASE_LOG/requests.txt" >> "$CASE_LOG/summary.txt"
