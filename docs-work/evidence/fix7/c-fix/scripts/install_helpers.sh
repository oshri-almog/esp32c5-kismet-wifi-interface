#!/bin/sh
# Installs every kismet_cap_* the tree built that differs from the installed one, atomically: a
# temporary name in the same directory, with the installed file's mode, then mv over it.
K=/root/src/kismet
BIN=/root/kismet-install/bin
for f in $(find "$K" -maxdepth 2 -type f -name 'kismet_cap_*' ! -name '*.c' ! -name '*.o' ! -name '*.d' | sort); do
    name=${f##*/}
    dest=$BIN/$name
    if [ ! -e "$dest" ]; then echo "not installed before, skipped: $name"; continue; fi
    if cmp -s "$f" "$dest"; then echo "same: $name"; continue; fi
    mode=$(stat -c %a "$dest")
    install -m "$mode" "$f" "$BIN/.$name.new" && mv -f "$BIN/.$name.new" "$dest" && echo "installed: $name (mode $mode)"
done
