#!/bin/sh
# The lws SMD queue warnings, before and after, with the machine's own routes and in a network
# namespace of its own (unshare -n, no file left behind) holding N extra routes. A listener
# there accepts the websocket and never answers, so the helper keeps servicing lws for the 4 s
# it runs; then it is killed by its pid.
#     proof_smd.sh BEFORE-HELPER AFTER-HELPER
. /mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/scripts/lib.sh
BEFORE=$1 AFTER=$2
setup_case smd
start_fake smd /root/fix7c/w/pty-smd WIFI

cat > "$WORK/inns.sh" <<'EOF'
# in the namespace: $1 extra routes, then each helper for 4 s
routes=$1 before=$2 after=$3 log=$4
ip link set lo up
ip addr add 10.255.0.1/16 dev lo
i=0
while [ $i -lt "$routes" ]; do
    echo "route add 10.$((i / 250)).$((i % 250)).0/24 dev lo"
    i=$((i + 1))
done > /root/fix7c/w/routes.$$
ip -batch /root/fix7c/w/routes.$$
rm -f /root/fix7c/w/routes.$$
echo "routes in all tables: $(ip route show table all | wc -l) IPv4, $(ip -6 route show table all | wc -l) IPv6" >> "$log/summary.txt"
python3 -c '
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 2699)); s.listen(8)
while True:
    c, _ = s.accept()
    time.sleep(3600)
' &
lpid=$!
sleep 0.5
for label in before after; do
    eval helper=\$$label
    KISMET_CAP_APIKEY=0123456789ABCDEF "$helper" --connect 127.0.0.1:2699 --disable-retry \
        --source esp32c5:device=/root/fix7c/w/pty-smd,name=ns-$label > "$log/ns-$routes-$label.stderr" 2>&1 &
    h=$!
    sleep 4
    kill $h 2>/dev/null; sleep 0.5; kill -9 $h 2>/dev/null
    wait $h 2>/dev/null
    echo "$routes extra routes, $label: $(grep -c "rejecting message on queue depth" "$log/ns-$routes-$label.stderr") 'rejecting message on queue depth' line(s)" >> "$log/summary.txt"
done
kill $lpid
EOF

# the machine's own routes, no namespace: the helper connects to a port nothing listens on
echo "this machine: $(ip route show table all | wc -l) IPv4 routes, $(ip -6 route show table all | wc -l) IPv6 routes in all tables" > "$LOG/summary.txt"
for label in before after; do
    eval helper=\$$(echo $label | tr a-z A-Z)
    KISMET_CAP_APIKEY=0123456789ABCDEF "$helper" --connect 127.0.0.1:2698 --disable-retry \
        --source esp32c5:device=/root/fix7c/w/pty-smd,name=host-$label > "$LOG/host-$label.stderr" 2>&1
    echo "host, $label: exit $?, $(grep -c "rejecting message on queue depth" "$LOG/host-$label.stderr") 'rejecting message on queue depth' line(s)" >> "$LOG/summary.txt"
done
for n in 0 200 3000 20000; do
    unshare -n sh "$WORK/inns.sh" $n "$BEFORE" "$AFTER" "$LOG"
done
stop_all
cat "$LOG/summary.txt"
