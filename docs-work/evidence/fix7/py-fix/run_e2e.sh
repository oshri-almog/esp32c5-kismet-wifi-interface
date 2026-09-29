#!/bin/bash
# tests/remote_e2e.sh on ports 2711/3711 against the installed Kismet, with kismet_cap_esp32c5's mtime
# recorded before and after (another agent reinstalls it). Usage: run_e2e.sh N  -> e2e-N.txt next to this.
OUT=$(cd "$(dirname "$0")" && pwd)
N=${1:-1}
CAP=/root/kismet-install/bin/kismet_cap_esp32c5
cd /mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
{
    echo "cap before: $(stat -c '%y %s' $CAP) $(sha256sum $CAP | cut -c1-16)"
    echo "start: $(date '+%F %T')"
    KISMET=/root/kismet-install/bin/kismet PYTHON=/root/esp32c5-venv/bin/python HTTP_PORT=2711 TCP_PORT=3711 \
        sh tests/remote_e2e.sh
    echo "exit: $?"
    echo "end: $(date '+%F %T')"
    echo "cap after: $(stat -c '%y %s' $CAP) $(sha256sum $CAP | cut -c1-16)"
    ss -ltn | grep -E ':(2711|3711) ' || echo "ports 2711/3711 free afterwards"
} > "$OUT/e2e-$N.txt" 2>&1
tail -3 "$OUT/e2e-$N.txt"
grep -c '^PASS' "$OUT/e2e-$N.txt"
grep '^FAIL' "$OUT/e2e-$N.txt"
exit 0
