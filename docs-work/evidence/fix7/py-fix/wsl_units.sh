#!/bin/bash
# Runs both unit test files in WSL with the project's venv, then test_kismet_v3.py against older
# websocket-client wheels (pure Python, imported from the wheel on PYTHONPATH), msgpack and pyserial from
# round 1's deps/site, then the one mutation that only websocket-client before 1.9 can catch, under 1.7.0 and
# 1.8.0. Output files go next to this script, with SUFFIX in their names.
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
    f="$OUT/test_kismet_v3-ws$v${SUFFIX:-}.txt"
    PYTHONPATH="$w:$SP/wsv/deps/site" timeout 900 python3 tests/test_kismet_v3.py > "$f" 2>&1
    echo "test_kismet_v3 websocket-client $v exit $? PASS $(grep -c ^PASS "$f") SKIP $(grep -c ^SKIP "$f") FAIL $(grep -c ^FAIL "$f"); $(grep -o 'websocket-client [0-9.]* sends as given[^)]*)' "$f"); $(grep -c 'redirect to another address is not followed' "$f") redirect checks"
done
for v in 1.7.0 1.8.0; do
    echo "mutation no_redirect_check_after_connect under websocket-client $v: $(cd "$OUT" && MUT_TAG="-ws$v" \
        PYTHONPATH="$SP/wsv/$v/websocket_client-$v-py3-none-any.whl:$SP/wsv/deps/site" REPO="$REPO" \
        python3 -c 'import mutate; print(mutate.run("no_redirect_check_after_connect")[1])')"
done
