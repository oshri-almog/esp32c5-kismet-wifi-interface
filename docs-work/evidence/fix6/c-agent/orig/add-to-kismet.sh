#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Adds the esp32c5 datasource to a Kismet source tree.
#
#     kismet/add-to-kismet.sh ~/src/kismet
#     cd ~/src/kismet && ./configure && make && sudo make install
#
# What it does, so that it can be reviewed and undone with git:
#   - copies datasource_esp32c5.h and capture_esp32c5/ into the tree
#   - registers the source type in kismet_server.cc
#   - adds the helper to configure.ac and Makefile.in, next to the CatSniffer
#     helper, whose lines serve as anchors
#   - regenerates configure, for which autoconf and automake have to be installed
#     (apt install autoconf automake)
#   - fixes a memory leak in Kismet's capture_framework.c that every capture helper has:
#     cf_commit_packet never frees the cf_frame_metadata holder cf_prepare_packet allocated,
#     about 32 bytes per packet, for the whole life of the helper. This is an upstream bug
#     fix, not part of the esp32c5 source, and goes to Kismet as a change of its own. It is
#     skipped when cf_commit_packet already frees meta, as it will once Kismet has the fix.
#
# Safe to run twice: every edit is skipped when it is already there.

set -eu

KISMET=${1:?usage: $0 PATH_TO_KISMET_SOURCE}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ ! -f "$KISMET/kismet_server.cc" ] || [ ! -f "$KISMET/capture_framework.c" ]; then
    echo "$KISMET does not look like a Kismet source tree" >&2
    exit 1
fi

cp "$HERE/datasource_esp32c5.h" "$KISMET/"
mkdir -p "$KISMET/capture_esp32c5"
cp "$HERE/capture_esp32c5/capture_esp32c5.c" "$HERE/capture_esp32c5/Makefile.in" "$KISMET/capture_esp32c5/"

python3 - "$KISMET" <<'EOF'
import re
import sys

tree = sys.argv[1]


def edit(name, change):
    path = "%s/%s" % (tree, name)
    with open(path) as f:
        text = f.read()
    new = change(text)
    if new != text:
        with open(path, "w") as f:
            f.write(new)
        print("  edited %s" % name)


def after_line(anchor, addition, marker):
    """Inserts addition after the (whole) line containing anchor, unless marker is already there."""
    def change(text):
        if marker in text:
            return text
        at = text.find(anchor)
        if at < 0:
            sys.exit("anchor not found, Kismet has changed: %r" % anchor)
        end = text.index("\n", at) + 1
        return text[:end] + addition + text[end:]
    return change


def after_blocks(pattern, marker, separator=""):
    """Duplicates every CatSniffer block matching pattern, renamed, right after it."""
    def change(text):
        if marker in text:
            return text
        blocks = list(re.finditer(pattern, text))
        if not blocks:
            sys.exit("anchor not found, Kismet has changed: %r" % pattern)
        for m in reversed(blocks):
            ours = m.group(0).replace("CATSNIFFER_ZIGBEE", "ESP32C5")
            text = text[:m.end()] + separator + ours + text[m.end():]
        return text
    return change


edit("kismet_server.cc", after_line(
    '#include "datasource_catsniffer_zigbee.h"',
    '#include "datasource_esp32c5.h"\n',
    '"datasource_esp32c5.h"'))
edit("kismet_server.cc", after_line(
    "new datasource_catsniffer_zigbee_builder()",
    "    datasourcetracker->register_datasource(shared_datasource_builder(new datasource_esp32c5_builder()));\n",
    "datasource_esp32c5_builder()"))

edit("Makefile.in", after_line(
    "BUILD_CAPTURE_CATSNIFFER_ZIGBEE = @BUILD_CAPTURE_CATSNIFFER_ZIGBEE@",
    "CAPTURE_ESP32C5 = capture_esp32c5/kismet_cap_esp32c5\n"
    "BUILD_CAPTURE_ESP32C5 = @BUILD_CAPTURE_ESP32C5@\n",
    "BUILD_CAPTURE_ESP32C5 ="))
edit("Makefile.in", after_line(
    "(cd capture_catsniffer_zigbee && $(MAKE))",
    "\n$(CAPTURE_ESP32C5): $(DATASOURCE_COMMON_A) FORCE\n"
    "\t(cd capture_esp32c5 && $(MAKE))\n",
    "(cd capture_esp32c5 && $(MAKE))"))
# the two install blocks (setuid and not), whatever their exact permissions
edit("Makefile.in", after_blocks(
    r'\t@if test "\$\(BUILD_CAPTURE_CATSNIFFER_ZIGBEE\)"x = "1"x; then \\\n[^\n]*\n\tfi;\n',
    '"$(BUILD_CAPTURE_ESP32C5)"x', separator="\n"))
edit("Makefile.in", after_line(
    "@(cd capture_catsniffer_zigbee &&  make clean)",
    "\t@(cd capture_esp32c5 && make clean)\n",
    "(cd capture_esp32c5 && make clean)"))

edit("configure.ac", after_line(
    'DATASOURCE_BINS="$DATASOURCE_BINS \\$(CAPTURE_CATSNIFFER_ZIGBEE)"',
    '\n# The ESP32-C5 boards only need a serial port, too\n'
    'BUILD_CAPTURE_ESP32C5=1\n'
    'DATASOURCE_BINS="$DATASOURCE_BINS \\$(CAPTURE_ESP32C5)"\n',
    "BUILD_CAPTURE_ESP32C5=1"))
edit("configure.ac", after_line(
    "AC_SUBST(BUILD_CAPTURE_CATSNIFFER_ZIGBEE)",
    "AC_SUBST(BUILD_CAPTURE_ESP32C5)\n",
    "AC_SUBST(BUILD_CAPTURE_ESP32C5)"))
edit("configure.ac", after_line(
    "    capture_catsniffer_zigbee/Makefile",
    "    capture_esp32c5/Makefile\n",
    "capture_esp32c5/Makefile"))
edit("configure.ac", after_blocks(
    r'printf "     catsniffer-zigbee: "\n(?:[^\n]*\n){4}fi\n',
    'BUILD_CAPTURE_ESP32C5" = 1; then'))
edit("configure.ac", lambda text: text.replace(
    'printf "     catsniffer-zigbee: "\nif test "$BUILD_CAPTURE_ESP32C5"',
    'printf "              ESP32-C5: "\nif test "$BUILD_CAPTURE_ESP32C5"'))

edit(".gitignore", after_line(
    "capture_catsniffer_zigbee/kismet_cap_catsniffer_zigbee",
    "capture_esp32c5/kismet_cap_esp32c5\n",
    "capture_esp32c5/kismet_cap_esp32c5"))


# Upstream fix: cf_commit_packet leaks the cf_frame_metadata of every frame sent. Only the
# holder is freed: the frame itself now belongs to the ring buffer (or, over a websocket, to
# the lws ring, cf_commit_ws_packet having freed its own holder), so meta->free_record must
# not run here -- it would commit the ring buffer region a second time, with length 0.
COMMIT_START = "int cf_commit_packet(kis_capture_handler_t *caph, cf_frame_metadata *meta, size_t final_len) {\n"
COMMIT_LEAKY = """
    if (caph->use_tcp || caph->use_ipc) {
        return cf_commit_rb_packet(caph, meta->frame, final_len);
#ifdef HAVE_LIBWEBSOCKETS
    } else if (caph->use_ws) {
        return cf_commit_ws_packet(caph, (struct cf_ws_msg *) meta->metadata, final_len);
#endif
    }

    return -1;
}
"""
COMMIT_FIXED = """    int r = -1;

    if (caph->use_tcp || caph->use_ipc) {
        r = cf_commit_rb_packet(caph, meta->frame, final_len);
#ifdef HAVE_LIBWEBSOCKETS
    } else if (caph->use_ws) {
        r = cf_commit_ws_packet(caph, (struct cf_ws_msg *) meta->metadata, final_len);
#endif
    }

    /* The frame is committed and belongs to the ring buffer now; only the holder
     * cf_prepare_packet allocated is left, and it is freed here, not with
     * meta->free_record, which would release the frame as well. */
    free(meta);

    return r;
}
"""


def free_commit_meta(text):
    start = text.find(COMMIT_START)
    if start < 0:
        print("  capture_framework.c: cf_commit_packet not found, its metadata leak not fixed")
        return text
    body_at = start + len(COMMIT_START)
    end = text.find("\n}\n", body_at)
    if "free(meta)" in text[body_at:end]:
        return text  # fixed already, here or upstream
    if not text.startswith(COMMIT_LEAKY, body_at):
        print("  capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed")
        return text
    return text[:body_at] + COMMIT_FIXED + text[body_at + len(COMMIT_LEAKY):]


edit("capture_framework.c", free_commit_meta)
EOF

# configure.ac pulls pkg-config's macros and its own m4/ in through aclocal, so
# autoconf on its own fails with "possibly undefined macro: AC_DEFINE"
echo "  regenerating configure (needs autoconf and automake)"
(cd "$KISMET" && aclocal -I m4 && autoconf)

echo "Done. Now: cd $KISMET && ./configure && make"
