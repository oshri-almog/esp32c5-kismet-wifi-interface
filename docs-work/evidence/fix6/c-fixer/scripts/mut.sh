#!/bin/bash
# mut.sh NAME OLD NEW : run tests/c/run.sh with one replacement made in a copy of capture_esp32c5.c
# (or, with NAME "old", the new tests against the capture_esp32c5.c from before the fixes)
. $(dirname $0)/lib.sh
M=/tmp/cfix/mut/$1
rm -rf $M; mkdir -p $M
cp -a $REPO/kismet $REPO/tests $M/
if [ "$1" = old ]; then
    cp $OUT/before/kismet/capture_esp32c5/capture_esp32c5.c $M/kismet/capture_esp32c5/capture_esp32c5.c
else
    python3 $(dirname $0)/mut.py $M/kismet/capture_esp32c5/capture_esp32c5.c "$2" "$3" || exit 3
fi
sh $M/tests/c/run.sh /root/src/kismet > $M/run.log 2>&1
rc=$?
cp $M/run.log $OUT/outputs/mut-$1.log
echo "mutation $1: run.sh exit $rc; $(grep -c "^PASS" $M/run.log) PASS; $(grep -c "^FAIL" $M/run.log) FAIL: $(grep "^FAIL" $M/run.log | cut -c1-110 | tr "\n" "|") $(tail -1 $M/run.log)"
