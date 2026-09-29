#!/bin/sh
# A remote helper with retry on a board another process holds: its probe refuses the board every
# 5 s, before any connection. Before and after, the lws warnings each attempt printed, over 12 s.
# No Kismet is needed: nothing is ever connected to.
#     proof_busy.sh BEFORE-HELPER AFTER-HELPER
. /mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/scripts/lib.sh
BEFORE=$1 AFTER=$2
setup_case busy
start_fake busy /root/fix7c/w/pty-busy WIFI
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
time.sleep(3600)
' /root/fix7c/w/pty-busy &
LPID=$!; STARTED="$STARTED $LPID"
sleep 0.5
: > "$LOG/summary.txt"
for label in before after; do
    eval helper=\$$(echo $label | tr a-z A-Z)
    KISMET_CAP_APIKEY=0123456789ABCDEF "$helper" --connect 127.0.0.1:2698 \
        --source esp32c5:device=/root/fix7c/w/pty-busy,name=busy-$label > "$LOG/$label.stderr" 2>&1 &
    HPID=$!
    sleep 12
    stop_pids $HPID $(children_of $HPID)
    wait $HPID 2>/dev/null
    echo "$label: $(grep -c "already in use by another capture" "$LOG/$label.stderr") refusals, $(grep -c "rejecting message on queue depth" "$LOG/$label.stderr") 'rejecting message on queue depth' line(s)" >> "$LOG/summary.txt"
done
stop_all
cat "$LOG/summary.txt"
