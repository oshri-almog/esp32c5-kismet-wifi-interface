#!/bin/sh
# add-to-kismet.sh on a fresh cfe427074 tree and on a round-1-patched one, each twice (three
# times for round 1): which files a later run touched, and whether the trees end up the same.
# Trees under /root/fix7cf/trees, left there for /root/src/kismet to be compared with.
set -u
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
T=/root/fix7cf/trees
rm -rf "$T"; mkdir -p "$T/fresh" "$T/r1"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/fresh"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/r1"
snap() { find "$1" -type f -printf '%P %T@\n' | sort; }
echo "### fresh, run 1"; sh "$REPO/kismet/add-to-kismet.sh" "$T/fresh" 2>&1
snap "$T/fresh" > "$T/fresh.s1"; sleep 1.1
echo "### fresh, run 2"; sh "$REPO/kismet/add-to-kismet.sh" "$T/fresh" 2>&1
snap "$T/fresh" > "$T/fresh.s2"
echo "### fresh: files whose time changed in run 2:"; diff "$T/fresh.s1" "$T/fresh.s2" && echo none
echo "### round 1: the round-1 framework (capture_framework.c and .h) put in a tree patched otherwise"
sh "$REPO/kismet/add-to-kismet.sh" "$T/r1" > /dev/null 2>&1
cp /root/fix7c/before/capture_framework.c /root/fix7c/before/capture_framework.h "$T/r1/"
echo "round-1 markers: $(grep -c cf_ws_uri_escape "$T/r1/capture_framework.c") cf_ws_uri_escape, $(grep -c lwsauthorization "$T/r1/capture_framework.c") lwsauthorization"
echo "### round 1, run 2"; sh "$REPO/kismet/add-to-kismet.sh" "$T/r1" 2>&1
snap "$T/r1" > "$T/r1.s1"; sleep 1.1
echo "### round 1, run 3"; sh "$REPO/kismet/add-to-kismet.sh" "$T/r1" 2>&1
snap "$T/r1" > "$T/r1.s2"
echo "### round 1: files whose time changed in run 3:"; diff "$T/r1.s1" "$T/r1.s2" && echo none
for f in capture_framework.c capture_framework.h configure.ac configure Makefile.in kismet_server.cc; do
    cmp -s "$T/r1/$f" "$T/fresh/$f" && echo "round 1 $f == fresh" || echo "round 1 $f DIFFERS from fresh"
done
