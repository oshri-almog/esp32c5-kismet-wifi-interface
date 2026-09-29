#!/bin/bash
# e2e-remote.sh HELPER-NAME : kismet_e2e.sh's remote case alone, with /tmp/cfix/bin/cap_HELPER-NAME
. $(dirname $0)/lib.sh
mkdir -p /tmp/cfix/e2e/tests
ln -sfn $REPO/tools /tmp/cfix/e2e/tools
python3 $(dirname $0)/cut_e2e.py $REPO/tests/kismet_e2e.sh /tmp/cfix/e2e/tests/remote.sh 'remote capture'
cd /tmp/cfix && KISMET=/root/kismet-install/bin/kismet HELPER=/tmp/cfix/bin/cap_$1 sh /tmp/cfix/e2e/tests/remote.sh > $OUT/outputs/e2e-remote-$1.txt 2>&1
echo "remote case with cap_$1: exit $?; $(grep -c '^PASS' $OUT/outputs/e2e-remote-$1.txt) PASS; FAILs: $(grep '^FAIL' $OUT/outputs/e2e-remote-$1.txt | tr '\n' '|')"
