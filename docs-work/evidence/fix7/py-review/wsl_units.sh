#!/bin/bash
# Both unit files on the review snapshot in WSL with the venv; the redirect demo with websocket-client 1.7.0 too.
OUT=$(cd "$(dirname "$0")" && pwd)
SP=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad
export PYTHONDONTWRITEBYTECODE=1
cd "$OUT/base"
for t in test_board test_kismet_v3; do
    timeout 900 /root/esp32c5-venv/bin/python tests/$t.py > "$OUT/$t-wsl.txt" 2>&1
    echo "$t venv exit $? PASS $(grep -c ^PASS "$OUT/$t-wsl.txt") SKIP $(grep -c ^SKIP "$OUT/$t-wsl.txt") FAIL $(grep -c ^FAIL "$OUT/$t-wsl.txt")"
done
cd /tmp
echo "== redirect demo, websocket-client 1.7.0"
PYTHONPATH="$SP/wsv/1.7.0/websocket_client-1.7.0-py3-none-any.whl:$SP/wsv/deps/site" python3 "$OUT/redirect_demo.py" "$OUT/base" 2>&1 | grep -E "websocket-client|reached|Cookie"
