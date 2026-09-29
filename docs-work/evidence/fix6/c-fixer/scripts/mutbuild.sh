#!/bin/bash
# mutbuild.sh NAME OLD NEW : /tmp/cfix/bin/cap_NAME, built from the repo's capture_esp32c5.c with one replacement
. $(dirname $0)/lib.sh
mkdir -p /tmp/cfix/mut-src
cp $REPO/kismet/capture_esp32c5/capture_esp32c5.c /tmp/cfix/mut-src/$1.c
python3 $(dirname $0)/mut.py /tmp/cfix/mut-src/$1.c "$2" "$3" || exit 3
build /tmp/cfix/mut-src/$1.c /tmp/cfix/bin/cap_$1 && echo "built cap_$1"
