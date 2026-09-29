#!/bin/bash
# pyh.sh LOG [helper args...]  -- run the Python remote helper from ~/e2e/py/src (or $PYSRC) with the venv
# python ($PYBIN), each output line prefixed with the epoch time. Writes LOG.pid (the python pid) and ends
# LOG with PY_EXIT=<status>. With STRACE=file, strace -p attaches to it at once (write/openat/ioctl/flock).
# Run it in the background: pyh.sh x.log --connect ... &
LOG=$1; shift
rm -f $LOG.pid
cd ${PYSRC:-$HOME/e2e/py/src}
PYBIN=${PYBIN:-$HOME/esp32c5-venv/bin/python}
{ $PYBIN -u -m esp32c5_kismet.remote "$@" 2>&1 < /dev/null & P=$!; echo $P > $LOG.pid
  if [ -n "$STRACE" ]; then strace -f -tt -e trace=${STRACE_EV:-write} -o $STRACE -p $P 2>/dev/null & fi
  wait $P; echo "PY_EXIT=$?"; } | python3 -u $HOME/e2e/py/ts.py > $LOG
