#!/bin/bash
# locks.sh: which process holds a flock on which /dev/ttyACM*
for l in $(awk '{print $5":"$6}' /proc/locks); do
  pid=${l%%:*}; ino=${l##*:}; ino=${ino##*:}
  for t in /dev/ttyACM*; do
    [ "$(stat -c %i $t)" = "$ino" ] && echo "  flock $t by pid $pid ($(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-100))"
  done
done
