#!/bin/sh
# Builds and runs tests/c/test_parser.c: the C helper's stream parser, when it says "capturing",
# radio handling and the signal blocks (frequency and all), source names, channel= and BTLE channel
# sets and refused channels, the probe (a remote helper's refusal of a port in use included),
# --list, finding a board by its MAC, port lock, the reason told to Kismet, the websocket PING
# watchdog, the signals that end a remote helper (not one it was started ignoring) and its capture
# process ending with its parent (setuid root too), and remote login (read as the framework reads
# it, abbreviations included; the framework's Basic Authorization header and KISMET cookie, or for a
# user name with ':' its percent-encoded URI, refused rather than cut when too long, and none of
# them over legacy TCP; the warning for a login that cannot log in), without a board or a Kismet
# server. Linux. Where the login goes is the framework's own doing, so the tree has to be patched
# by this add-to-kismet.sh and rebuilt. The boards it lists and finds are on a sysfs tree it makes
# up under /tmp, so what is plugged into the machine makes no difference. Run as root, it also
# checks the tty's exclusive mode (on a /dev/ttyS* with no hardware behind it, where the machine has
# one; a port with hardware is not touched), that the helper runs with no capability as root, in a
# container and setuid root, and that setuid root it still opens a pseudo-terminal of the user's.
#
#     tests/c/run.sh [PATH_TO_KISMET_SOURCE]        default: $KISMET_SRC, else ~/src/kismet
#
# The Kismet tree must have been through kismet/add-to-kismet.sh, ./configure and make: the test
# takes config.h, capture_framework.h and libkismetdatasource.a from it. It compiles this
# repository's kismet/capture_esp32c5/capture_esp32c5.c, not the tree's copy, so an edit is tested
# without copying it into the tree or rebuilding Kismet. CC picks another compiler.
#
# Exit status 0 when every check passed (the last line is ALL OK), 1 when one failed or the build
# did, 2 when the tree lacks a file it needs. Not run as root, or on a Kismet configured without
# libcap, or on a machine without such a /dev/ttyS*, the checks that need them print SKIP instead.
# The wiki's Development-and-Testing page describes the tests for users.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
KISMET_SRC=${1:-${KISMET_SRC:-$HOME/src/kismet}}

for f in config.h capture_framework.h libkismetdatasource.a capture_esp32c5; do
    if [ ! -e "$KISMET_SRC/$f" ]; then
        echo "$KISMET_SRC/$f is missing: give a Kismet tree patched with kismet/add-to-kismet.sh and built" >&2
        exit 2
    fi
done

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# The helper includes "../capture_framework.h" and "../config.h"; from the tree's
# capture_esp32c5 directory those are the tree's own. The libraries are the ones Kismet links its
# helpers with (CAPLIBS in Makefile.inc). capture_framework.h declares static websocket functions
# it never defines, which is why Kismet builds with -Wno-unused-function, and so does this.
CAPLIBS=$(sed -n 's/^CAPLIBS[[:space:]]*=//p' "$KISMET_SRC/Makefile.inc")
${CC:-gcc} -Wall -Wno-unused-function -g -O1 -pthread -I"$KISMET_SRC/capture_esp32c5" -I"$KISMET_SRC" \
    -o "$OUT/test_parser" "$HERE/test_parser.c" "$KISMET_SRC/libkismetdatasource.a" \
    $CAPLIBS -lpthread -lm
"$OUT/test_parser"
