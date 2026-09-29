#!/bin/sh
# /root/src/kismet: its framework files back to cfe427074 (they held an earlier version of this
# round's login patch, which the script does not upgrade), then add-to-kismet.sh three times,
# with the files each later run touched.
set -u
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
K=/root/src/kismet
W=/root/fix7cf
snap() { find "$K" -path "$K/.git" -prune -o -type f -printf '%P %T@\n' | sort; }
git -C "$K" checkout -- capture_framework.c capture_framework.h
echo "framework files back to cfe427074: $(git -C "$K" status --short capture_framework.c capture_framework.h | wc -l) modified"
touch "$W/stamp-before-patch"
sleep 1.1
echo "### run 1"; sh "$REPO/kismet/add-to-kismet.sh" "$K" 2>&1
snap > "$W/real.s1"; sleep 1.1
echo "### run 2"; sh "$REPO/kismet/add-to-kismet.sh" "$K" 2>&1
snap > "$W/real.s2"; sleep 1.1
echo "### run 3"; sh "$REPO/kismet/add-to-kismet.sh" "$K" 2>&1
snap > "$W/real.s3"
echo "### files whose time changed in run 2:"; diff "$W/real.s1" "$W/real.s2" && echo none
echo "### files whose time changed in run 3:"; diff "$W/real.s2" "$W/real.s3" && echo none
echo "### files newer than the start (outside .git):"
find "$K" -path "$K/.git" -prune -o -type f -newer "$W/stamp-before-patch" -print | sed "s|^$K/||" | sort
for f in capture_framework.c capture_framework.h configure.ac configure Makefile.in kismet_server.cc datasource_esp32c5.h capture_esp32c5/capture_esp32c5.c; do
    cmp -s "$K/$f" "$W/trees/fresh/$f" && echo "$f == the fresh tree's" || echo "$f DIFFERS from the fresh tree's"
done
