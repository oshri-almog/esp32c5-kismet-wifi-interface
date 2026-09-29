#!/bin/sh
# build_fw.sh FRAMEWORK.c HELPER.c OUT : kismet_cap_esp32c5 from HELPER.c against FRAMEWORK.c, with the
# Kismet tree's flags and the rest of its libkismetdatasource.a
set -eu
T=/root/src/kismet
B=$(mktemp -d /tmp/cfix/fw.XXXXXX)
CFLAGS=$(sed -n "s/^CFLAGS[[:space:]]*+=//p" $T/Makefile.inc)
CAPLIBS=$(sed -n "s/^CAPLIBS[[:space:]]*=//p" $T/Makefile.inc)
cp "$1" $B/capture_framework.c
(cd $T && gcc $CFLAGS -I$T -c $B/capture_framework.c -o $B/capture_framework.c.o)
cp $T/libkismetdatasource.a $B/lib.a
ar r $B/lib.a $B/capture_framework.c.o
gcc $CFLAGS -I$T/capture_esp32c5 -I$T -c "$2" -o $B/helper.o
gcc -o "$3" $B/helper.o $B/lib.a $CAPLIBS -lpthread -lm
rm -rf $B
echo "built $3"
