#!/bin/sh
# add-to-kismet.sh on a fresh cfe427074 tree and on a round-1 framework, twice each; mtimes and results
set -u
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
T=/tmp/review-c-trees
rm -rf "$T"; mkdir -p "$T/fresh" "$T/r1"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/fresh"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/r1"
snap() { find "$1" -type f -newer "$1/README.md" -printf '%P %T@\n' | sort; }
echo "### fresh, run 1"; sh "$REPO/kismet/add-to-kismet.sh" "$T/fresh" 2>&1
snap "$T/fresh" > "$T/fresh.s1"; sleep 1.1
echo "### fresh, run 2"; sh "$REPO/kismet/add-to-kismet.sh" "$T/fresh" 2>&1
snap "$T/fresh" > "$T/fresh.s2"
echo "### fresh: files whose time changed in run 2:"; diff "$T/fresh.s1" "$T/fresh.s2" && echo none
for f in capture_framework.c capture_framework.h configure.ac kismet_server.cc Makefile.in; do cmp "$T/fresh/$f" "/root/src/kismet/$f" && echo "fresh $f == real tree"; done
cmp "$T/fresh/configure" /root/src/kismet/configure && echo "fresh configure == real tree"
echo "### round-1 framework: run 1 (fresh), then round-1 capture_framework.c put in, run 2, run 3"
sh "$REPO/kismet/add-to-kismet.sh" "$T/r1" > /dev/null 2>&1
cp /root/fix7c/before/capture_framework.c "$T/r1/capture_framework.c"
cp /root/fix7c/before/capture_framework.h "$T/r1/capture_framework.h"
grep -c "cf_ws_uri_escape" "$T/r1/capture_framework.c"
sh "$REPO/kismet/add-to-kismet.sh" "$T/r1" 2>&1
snap "$T/r1" > "$T/r1.s1"; sleep 1.1
sh "$REPO/kismet/add-to-kismet.sh" "$T/r1" 2>&1
snap "$T/r1" > "$T/r1.s2"
diff "$T/r1.s1" "$T/r1.s2" && echo "r1: no time changed in run 3"
cmp "$T/r1/capture_framework.c" "$T/fresh/capture_framework.c" && echo "r1 capture_framework.c == fresh"
cmp "$T/r1/capture_framework.h" "$T/fresh/capture_framework.h" && echo "r1 capture_framework.h == fresh"
