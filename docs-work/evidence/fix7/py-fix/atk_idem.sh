#!/bin/sh
# add-to-kismet.sh on a fresh cfe427074 tree, twice, and on a tree that round 1's patch left, in copies
# under /tmp that are removed at the end. Nothing in /root/src/kismet is changed (git archive only reads).
set -u
S=/mnt/c/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad
REPO=/mnt/c/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface
T=$(mktemp -d /tmp/pyfix-atk.XXXXXX)
trap 'rm -rf "$T"' EXIT
cp -r "$REPO/kismet" "$T/kdir"
echo "add-to-kismet.sh sha1 $(sha1sum < "$T/kdir/add-to-kismet.sh" | cut -c1-16), mtime $(stat -c %y "$REPO/kismet/add-to-kismet.sh")"

snap() {  # snap TREE -> mtime and sha of every file, autom4te.cache left out
    (cd "$1" && find . -path ./autom4te.cache -prune -o -type f -printf '%p\n' | sort | while read -r f; do
        printf '%s %s %s\n' "$(stat -c %Y.%N "$f" 2>/dev/null || stat -c %Y "$f")" "$(sha1sum < "$f" | cut -c1-12)" "$f"
    done)
}
snap() {
    (cd "$1" && find . -path ./autom4te.cache -prune -o -type f -printf '%T@ %p\n' | sort -k2 > "$2.mt" &&
     find . -path ./autom4te.cache -prune -o -type f -print0 | sort -z | xargs -0 sha1sum > "$2.sha")
}

mkdir "$T/fresh"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/fresh"
echo "== run 1 on a fresh cfe427074 tree"
sh "$T/kdir/add-to-kismet.sh" "$T/fresh" 2>&1 | sed 's/^/   /'
echo "   exit $?"
snap "$T/fresh" "$T/s1"
sleep 1.2
echo "== run 2 on the same tree"
sh "$T/kdir/add-to-kismet.sh" "$T/fresh" 2>&1 | sed 's/^/   /'
snap "$T/fresh" "$T/s2"
echo "   files whose content changed in run 2:"; diff "$T/s1.sha" "$T/s2.sha" | sed 's/^/      /'
echo "   files whose mtime changed in run 2:"; diff "$T/s1.mt" "$T/s2.mt" | grep '^>' | sed 's/^/      /'

echo "== upgrade: a tree round 1 left (its capture_framework.c), then this script"
mkdir "$T/r1"
git -C /root/src/kismet archive cfe427074 | tar -x -C "$T/r1"
sh "$T/kdir/add-to-kismet.sh" "$T/r1" > /dev/null 2>&1  # everything else as this script does it
cp "$S/fix7/c/before/capture_framework.round1.c" "$T/r1/capture_framework.c"
git -C /root/src/kismet show cfe427074:capture_framework.h > "$T/r1/capture_framework.h"
sh "$T/kdir/add-to-kismet.sh" "$T/r1" 2>&1 | sed 's/^/   /'
for f in capture_framework.c capture_framework.h; do
    cmp -s "$T/fresh/$f" "$T/r1/$f" && echo "   $f: same as on a fresh tree" || { echo "   $f: DIFFERS from a fresh tree"; diff "$T/fresh/$f" "$T/r1/$f" | head -20; }
done
sleep 1.2
snap "$T/r1" "$T/r1a"
sh "$T/kdir/add-to-kismet.sh" "$T/r1" 2>&1 | sed 's/^/   /'
snap "$T/r1" "$T/r1b"
echo "   and again: content changes:"; diff "$T/r1a.sha" "$T/r1b.sha" | sed 's/^/      /'
echo "   mtime changes:"; diff "$T/r1a.mt" "$T/r1b.mt" | grep '^>' | sed 's/^/      /'

echo "== does Kismet's Makefile.in rebuild anything from configure's time?"
grep -n "^configure\|config.status:\|^Makefile:\|--recheck\|autoconf" "$T/fresh/Makefile.in" | head
echo "== the tree's copy of the helper against the repo's"
cmp "$T/fresh/capture_esp32c5/capture_esp32c5.c" "$REPO/kismet/capture_esp32c5/capture_esp32c5.c" && echo "   same"
echo "removing $T"
