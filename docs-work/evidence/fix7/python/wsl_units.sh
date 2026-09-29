#!/bin/bash
# Runs both unit test files in WSL with the project's venv, then test_kismet_v3.py against older
# websocket-client wheels (pure Python, imported from the wheel on PYTHONPATH), msgpack and pyserial from
# round 1's deps/site. Output files go next to this script.
OUT=$(cd "$(dirname "$0")" && pwd)
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
SP=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad
export PYTHONDONTWRITEBYTECODE=1
cd "$REPO"
for t in test_board test_kismet_v3; do
    timeout 900 /root/esp32c5-venv/bin/python tests/$t.py > "$OUT/$t-wsl${SUFFIX:-}.txt" 2>&1
    echo "$t venv exit $? PASS $(grep -c ^PASS "$OUT/$t-wsl${SUFFIX:-}.txt") SKIP $(grep -c ^SKIP "$OUT/$t-wsl${SUFFIX:-}.txt") FAIL $(grep -c ^FAIL "$OUT/$t-wsl${SUFFIX:-}.txt")"
done
[ -n "${ONLY_VENV:-}" ] && exit 0
for w in "$SP/wsv/1.7.0/websocket_client-1.7.0-py3-none-any.whl" "$SP/wsv/1.8.0/websocket_client-1.8.0-py3-none-any.whl" \
         "$SP/linwheels/websocket_client-1.9.1-py3-none-any.whl"; do
    v=$(basename "$w" | cut -d- -f2)
    PYTHONPATH="$w:$SP/wsv/deps/site" timeout 900 python3 tests/test_kismet_v3.py > "$OUT/test_kismet_v3-ws$v${SUFFIX:-}.txt" 2>&1
    echo "test_kismet_v3 websocket-client $v exit $? PASS $(grep -c ^PASS "$OUT/test_kismet_v3-ws$v${SUFFIX:-}.txt") SKIP $(grep -c ^SKIP "$OUT/test_kismet_v3-ws$v${SUFFIX:-}.txt") FAIL $(grep -c ^FAIL "$OUT/test_kismet_v3-ws$v${SUFFIX:-}.txt"); $(grep -o 'websocket-client [0-9.]* sends as given[^)]*)' "$OUT/test_kismet_v3-ws$v${SUFFIX:-}.txt")"
done
