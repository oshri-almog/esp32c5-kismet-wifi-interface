#!/bin/sh
# tests/c/test_parser.c built as run.sh builds it, then run as nobody (the root-only checks SKIP)
set -eu
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
K=/root/src/kismet
D=$(mktemp -d /tmp/fix7cf-nobody.XXXXXX)
CAPLIBS=$(sed -n 's/^CAPLIBS[[:space:]]*=//p' "$K/Makefile.inc")
gcc -Wall -Wno-unused-function -g -O1 -pthread -I"$K/capture_esp32c5" -I"$K" \
    -o "$D/test_parser" "$REPO/tests/c/test_parser.c" "$K/libkismetdatasource.a" $CAPLIBS -lpthread -lm
chmod 755 "$D" "$D/test_parser"
cd /tmp
setpriv --reuid=65534 --regid=65534 --clear-groups "$D/test_parser" && r=0 || r=$?
rm -rf "$D"
exit $r
