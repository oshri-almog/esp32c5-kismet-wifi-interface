#!/bin/bash
# tests/remote_e2e.sh from the review's snapshot of the Python files (base/), on ports 2731/3731, against the
# installed Kismet. Usage: run_e2e.sh NAME -> e2e-NAME.txt next to this.
OUT=$(cd "$(dirname "$0")" && pwd)
N=${1:-1}
CAP=/root/kismet-install/bin/kismet_cap_esp32c5
cd "$OUT/oldcode"
{
    echo "cap before: $(stat -c '%y %s' $CAP) $(sha256sum $CAP | cut -c1-16)"
    echo "start: $(date '+%F %T')"
    KISMET=/root/kismet-install/bin/kismet PYTHON=/root/esp32c5-venv/bin/python HTTP_PORT=2731 TCP_PORT=3731 \
        PYTHONDONTWRITEBYTECODE=1 sh tests/remote_e2e.sh
    echo "exit: $?"
    echo "end: $(date '+%F %T')"
    echo "cap after: $(stat -c '%y %s' $CAP) $(sha256sum $CAP | cut -c1-16)"
    ss -ltn | grep -E ':(2731|3731) ' || echo "ports 2731/3731 free afterwards"
} > "$OUT/e2e-$N.txt" 2>&1
tail -3 "$OUT/e2e-$N.txt"
grep -c '^PASS' "$OUT/e2e-$N.txt"
grep '^FAIL' "$OUT/e2e-$N.txt"
exit 0
