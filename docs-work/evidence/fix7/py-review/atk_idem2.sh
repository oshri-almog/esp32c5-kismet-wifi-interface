#!/bin/sh
# Why does a second add-to-kismet.sh run on a fresh tree touch aclocal.m4 and configure? Runs 1, 2 and 3 with
# 3 s between them, in a copy under /tmp that is removed at the end.
set -u
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
T=$(mktemp -d /tmp/pyrev-atk2.XXXXXX)
trap 'rm -rf "$T"' EXIT
cp -r "$REPO/kismet" "$T/kdir"
mkdir "$T/fresh"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/fresh"
cd "$T/fresh"
show() { stat -c '      %y %n' configure.ac aclocal.m4 configure; }
echo "== archive times"; show
sh "$T/kdir/add-to-kismet.sh" "$T/fresh" > /dev/null 2>&1
echo "== after run 1"; show
sleep 3
echo "== run 2, aclocal --verbose on its own first (what it decides)"
aclocal -I m4 --verbose 2>&1 | grep -i "unchanged\|writing\|younger\|older\|up to date\|output" | sed 's/^/      /'
show
sleep 3
sh "$T/kdir/add-to-kismet.sh" "$T/fresh" > /dev/null 2>&1
echo "== after run 3"; show
sleep 3
sh "$T/kdir/add-to-kismet.sh" "$T/fresh" > /dev/null 2>&1
echo "== after run 4"; show
