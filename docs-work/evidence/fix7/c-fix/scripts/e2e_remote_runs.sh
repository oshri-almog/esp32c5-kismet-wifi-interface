#!/bin/sh
# The remote cases of kismet_e2e.sh with each helper given: NAME=HELPER...
O=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c-fix
python3 "$O/scripts/cut_e2e.py" /root/fix7cf/e2e_remote.sh
for arg in "$@"; do
    name=${arg%%=*} helper=${arg#*=}
    KISMET=/root/kismet-install/bin/kismet HELPER=$helper sh /root/fix7cf/e2e_remote.sh > "$O/outputs/e2e-remote-$name.log" 2>&1
    echo "$name: exit $?, $(grep -c '^PASS' "$O/outputs/e2e-remote-$name.log") PASS, $(grep -c '^FAIL' "$O/outputs/e2e-remote-$name.log") FAIL"
    grep '^FAIL' "$O/outputs/e2e-remote-$name.log" | sed 's/^/    /'
done
