#!/bin/sh
# build_variant.sh FRAMEWORK.c HELPER.c OUT_BINARY
# Builds kismet_cap_esp32c5 from the given helper source against the given capture_framework.c,
# with the Kismet tree's flags and the rest of its libkismetdatasource.a. Scratch only.
set -eu
T=/root/src/kismet
FW=$1; HELPER=$2; OUT=$3
B=$(mktemp -d /root/c-agent-fix6/vb.XXXXXX)
CFLAGS=$(sed -n "s/^CFLAGS[[:space:]]*+=//p" $T/Makefile.inc)
CAPLIBS=$(sed -n "s/^CAPLIBS[[:space:]]*=//p" $T/Makefile.inc)
cp "$FW" $B/capture_framework.c
(cd $T && gcc $CFLAGS -I$T -c $B/capture_framework.c -o $B/capture_framework.c.o)
cp $T/libkismetdatasource.a $B/lib.a
ar r $B/lib.a $B/capture_framework.c.o
gcc $CFLAGS -I$T/capture_esp32c5 -I$T -c "$HELPER" -o $B/helper.o
gcc -o "$OUT" $B/helper.o $B/lib.a $CAPLIBS -lpthread -lm
rm -rf $B
echo built $OUT
