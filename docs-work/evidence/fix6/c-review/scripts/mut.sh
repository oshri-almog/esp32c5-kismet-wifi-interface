#!/bin/bash
# mut.sh NAME OLD NEW : run tests/c/run.sh with one replacement made in a copy of capture_esp32c5.c
M=/tmp/crev/mut/$1
rm -rf $M; mkdir -p $M
cp -a /tmp/crev/repo/kismet /tmp/crev/repo/tests $M/
python3 /tmp/crev/mut.py $M/kismet/capture_esp32c5/capture_esp32c5.c "$2" "$3" || exit 3
sh $M/tests/c/run.sh /root/src/kismet > $M/run.log 2>&1
rc=$?
echo "mutation $1: run.sh exit $rc; $(grep -c "^PASS" $M/run.log) PASS; $(grep "^FAIL" $M/run.log | head -5 | tr "\n" "|") $(tail -1 $M/run.log)"
