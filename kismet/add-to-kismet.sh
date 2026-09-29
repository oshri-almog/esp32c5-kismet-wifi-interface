#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Adds the esp32c5 datasource to a Kismet source tree.
#
#     kismet/add-to-kismet.sh ~/src/kismet
#     cd ~/src/kismet && ./configure && make && sudo make install
#
# Needs python3, which makes the edits, and autoconf and automake, which regenerate
# configure (apt install python3 autoconf automake).
#
# What it does, so that it can be reviewed and undone with git:
#   - copies datasource_esp32c5.h and capture_esp32c5/ into the tree, each file only when the
#     tree's copy differs: an unchanged file keeps its time, so that make does not recompile
#     kismet_server.cc, which includes datasource_esp32c5.h, and relink the 490 MB kismet for
#     nothing (minutes, on a Raspberry Pi)
#   - registers the source type in kismet_server.cc
#   - adds the helper to configure.ac and Makefile.in, next to the CatSniffer
#     helper, whose lines serve as anchors
#   - regenerates configure, when configure.ac has changed since it was made
#   - fixes six bugs in Kismet's capture framework that every capture helper has. They are
#     upstream bug fixes, not part of the esp32c5 source, and each goes to Kismet as a change
#     of its own. Each is skipped when it is there already, here or upstream, and skipped
#     with a note when the code it replaces has changed. All are in capture_framework.c; the
#     login's also adds three fields to capture_framework.h, so the first run that makes it
#     recompiles every capture helper (not kismet, which does not include that header).
#       - a memory leak: cf_commit_packet never frees the cf_frame_metadata holder
#         cf_prepare_packet allocated, about 32 bytes per packet, for the whole life of the
#         helper.
#       - websocket remote capture sends in 5 second bursts: a frame queued by the capture
#         thread asked for the write with lws_callback_on_writable, which libwebsockets only
#         allows on the thread that runs its service loop, so the write waited for Kismet's
#         next PING. The sending threads now wake the loop with lws_cancel_service, the one
#         call any thread may make, and the loop asks for the write itself
#         (LWS_CALLBACK_EVENT_WAIT_CANCELLED). cf_handler_spindown wakes it too, so that a
#         helper whose capture ended after its last frame was sent disconnects instead of
#         staying connected with nothing to send.
#       - a websocket that closes while the service loop is about to wait (the close
#         handshake timing out, say) left the loop asleep with shutdown set: the capture
#         process kept its port and the framework never reconnected. The close now wakes it.
#       - the websocket login went into the URI's query as it was: where a reverse proxy's
#         access log keeps it, and where a user, password or API key with a space, a '%' or
#         an '&' in it could not log in (a space breaks the request, Kismet decodes "%41" to
#         "A", and it splits the decoded query at '&'). A user and password now go in an
#         HTTP Basic Authorization header and an API key in Kismet's session cookie, which
#         Kismet takes as they are, and the URI holds no secret. Only a user name with ':',
#         which Basic cannot carry, still goes in the query, percent-encoded; such a login
#         cannot hold an '&', and kismet_cap_esp32c5 warns about that. A login too long for
#         the URI or for the request's headers fails with a message instead of being cut.
#         libwebsockets follows a redirect with the same headers, to wherever it points,
#         another server included, so a redirect is refused: Kismet never answers with one.
#       - every websocket connection printed "rejecting message on queue depth 40" (or a few)
#         from libwebsockets: its netlink role reports each of the machine's routes to lws's
#         own listeners as it starts, and on a machine with more routes than its queue's 40
#         the rest are dropped with that warning. The queue is made deep enough.
#       - every channel set a helper took printed an empty "INFO: " line on a remote helper's
#         stderr: the framework passes the channel callback's message on even when it is
#         empty. An empty one is no message now.
#
# Safe to run twice: every edit is skipped when it is already there, and a second run changes
# no file in the tree.

set -eu

KISMET=${1:?usage: $0 PATH_TO_KISMET_SOURCE}
HERE=$(cd "$(dirname "$0")" && pwd)

if [ ! -f "$KISMET/kismet_server.cc" ] || [ ! -f "$KISMET/capture_framework.c" ]; then
    echo "$KISMET does not look like a Kismet source tree" >&2
    exit 1
fi

# A new time on an unchanged file would make make rebuild everything that depends on it
copy_if_changed() {  # copy_if_changed FILE (relative to kismet/ here and to the tree)
    if ! cmp -s "$HERE/$1" "$KISMET/$1"; then
        cp "$HERE/$1" "$KISMET/$1"
        echo "  copied $1"
    fi
}
copy_if_changed datasource_esp32c5.h
mkdir -p "$KISMET/capture_esp32c5"
copy_if_changed capture_esp32c5/capture_esp32c5.c
copy_if_changed capture_esp32c5/Makefile.in

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


def edit_files(names, change):
    """edit() for a change that goes into several files or into none of them: change gets
    and returns a dict of their texts"""
    texts = {}
    for name in names:
        with open("%s/%s" % (tree, name)) as f:
            texts[name] = f.read()
    new = change(dict(texts))
    for name in names:
        if new[name] != texts[name]:
            with open("%s/%s" % (tree, name), "w") as f:
                f.write(new[name])
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


# Upstream fix: over a websocket, frames went out in 5 second bursts. The service loop,
# lws_service() in cf_handler_loop, sleeps until a socket or lws_cancel_service() wakes it.
# cf_send_ws_raw_bytes and cf_commit_ws_packet queue a frame on whichever thread sends it --
# the capture thread for every packet -- and asked for the write with
# lws_callback_on_writable(), which libwebsockets only allows on the service thread
# (lws_cancel_service() is the one call any thread may make): from the capture thread the
# request waited for the next socket event, Kismet's PING every 5 seconds. They now wake the
# loop, and the loop asks for the write in LWS_CALLBACK_EVENT_WAIT_CANCELLED, which lws sends
# every protocol on the service thread (with a stand-in wsi, hence caph->lwsclientwsi). All
# of it goes in or none of it: the wake-ups alone would never ask for a write at all.
#
# The loop only looked at spindown after writing a frame, too, so a capture thread that
# ended (cf_handler_spindown) after its last frame had gone out left the helper connected
# with nothing to do; before this fix the 5 second delay hid that. cf_handler_spindown wakes
# the loop now, and a write asked for with nothing left to send ends the connection.
WS_WAKE_OLD = """    pthread_mutex_lock(&caph->handler_lock);
    if (caph->lwsclientwsi != NULL)
        lws_callback_on_writable(caph->lwsclientwsi);
    pthread_mutex_unlock(&caph->handler_lock);
"""
WS_WAKE_NEW = """    /* Only the service thread may ask lws for the write, and this may be any thread:
     * wake the loop, which asks in LWS_CALLBACK_EVENT_WAIT_CANCELLED */
    lws_cancel_service(caph->lwscontext);
"""
WS_EMPTY_OLD = """            wmsg = (struct cf_ws_msg *) lws_ring_get_element(caph->lwsring, &caph->lwstail);
            if (wmsg == NULL)
                goto skip;
"""
WS_EMPTY_NEW = """            wmsg = (struct cf_ws_msg *) lws_ring_get_element(caph->lwsring, &caph->lwstail);
            if (wmsg == NULL) {
                /* Nothing left to send: a spindown that came after the last frame went
                 * out finishes here (cf_handler_spindown wakes the loop for it) */
                if (caph->spindown) {
                    caph->shutdown = 1;
                    lws_cancel_service(caph->lwscontext);
                    pthread_mutex_unlock(&caph->out_ringbuf_lock);
                    return -1;
                }
                goto skip;
            }
"""
WS_CLOSED_CASE = "        case LWS_CALLBACK_CLIENT_CLOSED:\n"
WS_CANCELLED_CASE = """        case LWS_CALLBACK_EVENT_WAIT_CANCELLED:
            /* Another thread queued a frame or spun down, and woke the loop with
             * lws_cancel_service(); here, on the service thread, the write can be
             * asked for.  wsi is a stand-in, not the connection. */
            pthread_mutex_lock(&caph->handler_lock);
            if (caph->lwsclientwsi != NULL)
                lws_callback_on_writable(caph->lwsclientwsi);
            pthread_mutex_unlock(&caph->handler_lock);
            break;
"""
SPINDOWN_OLD = """void cf_handler_spindown(kis_capture_handler_t *caph) {
    if (caph == NULL)
        return;

    pthread_mutex_lock(&(caph->handler_lock));
    caph->spindown = 1;
    pthread_mutex_unlock(&(caph->handler_lock));
}
"""
SPINDOWN_NEW = """void cf_handler_spindown(kis_capture_handler_t *caph) {
    if (caph == NULL)
        return;

    pthread_mutex_lock(&(caph->handler_lock));
    caph->spindown = 1;
    pthread_mutex_unlock(&(caph->handler_lock));

#ifdef HAVE_LIBWEBSOCKETS
    /* The websocket loop sleeps until something wakes it; it finishes sending and
     * disconnects once it sees spindown */
    if (caph->use_ws && caph->lwscontext != NULL)
        lws_cancel_service(caph->lwscontext);
#endif
}
"""


def ws_wake_service(text):
    if "LWS_CALLBACK_EVENT_WAIT_CANCELLED" in text:
        return text  # fixed already, here or upstream
    if (text.count(WS_WAKE_OLD) != 2 or text.count(WS_EMPTY_OLD) != 1 or
            text.count(WS_CLOSED_CASE) != 1 or text.count(SPINDOWN_OLD) != 1):
        print("  capture_framework.c: the websocket send path has changed, its 5 second "
              "bursts not fixed")
        return text
    text = text.replace(WS_WAKE_OLD, WS_WAKE_NEW)
    text = text.replace(WS_EMPTY_OLD, WS_EMPTY_NEW)
    text = text.replace(WS_CLOSED_CASE, WS_CANCELLED_CASE + WS_CLOSED_CASE)
    return text.replace(SPINDOWN_OLD, SPINDOWN_NEW)


edit("capture_framework.c", ws_wake_service)


# Upstream fix: LWS_CALLBACK_CLIENT_CLOSED sets shutdown, which the service loop only reads
# when lws_service() returns. When the close comes from lws's own timers (the close
# handshake timing out) rather than from socket activity, lws_service() goes on to sleep with
# nothing left to wake it: the capture process kept its port, and the framework, which
# reconnects only once that process has ended, never did. The close wakes the loop now.
WS_CLOSED_OLD = r"""        case LWS_CALLBACK_CLIENT_CLOSED:
            fprintf(stderr, "FATAL: Datasource websocket closed\n");
            pthread_mutex_lock(&caph->handler_lock);
            caph->lwsclientwsi = NULL;
            caph->lwsestablished = 0;
            caph->shutdown = 1;
            pthread_mutex_unlock(&caph->handler_lock);
            return -1;
"""
WS_CLOSED_NEW = r"""        case LWS_CALLBACK_CLIENT_CLOSED:
            fprintf(stderr, "FATAL: Datasource websocket closed\n");
            pthread_mutex_lock(&caph->handler_lock);
            caph->lwsclientwsi = NULL;
            caph->lwsestablished = 0;
            caph->shutdown = 1;
            pthread_mutex_unlock(&caph->handler_lock);
            /* lws_service() may be about to sleep, with no socket left to wake it:
             * wake it, so that the loop sees shutdown and the process ends */
            lws_cancel_service(caph->lwscontext);
            return -1;
"""


def ws_closed_wakes(text):
    at = text.find(WS_CLOSED_CASE)
    end = text.find("        case ", at + 1)
    if at >= 0 and end > at and "lws_cancel_service" in text[at:end]:
        return text  # fixed already, here or upstream
    if text.count(WS_CLOSED_OLD) != 1:
        print("  capture_framework.c: LWS_CALLBACK_CLIENT_CLOSED has changed, its missed "
              "wake-up not fixed")
        return text
    return text.replace(WS_CLOSED_OLD, WS_CLOSED_NEW)


edit("capture_framework.c", ws_closed_wakes)


# Upstream fix: the websocket login went into the URI's query as it was, and the URI is where a
# secret does not belong: a reverse proxy in front of Kismet keeps it in its access log. There,
# too, Kismet's server (kis_net_beast_httpd.cc) percent-decodes the whole query and only then
# splits it at '&', so a '%' followed by two hex digits arrived as another character, a space
# broke the request line, and an '&' cut the login short. The server looks at headers first: it
# takes an auth token (an API key is one) from the KISMET cookie when the request has a Cookie
# header, and from ?KISMET= only when it has none; and when that is no valid token, a user and
# password from an 'Authorization: Basic' header, which it takes as they are, and from
# ?user=&password= only when there is no such header. So a user and password now go as Basic
# and an API key as the cookie, percent-encoded as the server decodes a Cookie header (where a
# '+' would become a space), and the URI holds no secret. Basic ends the user name at its first
# ':', so a user name with one still goes in the query, percent-encoded, and such a login
# cannot hold an '&'. A login too long for the URI's 1024 bytes, or for the room lws leaves for
# the request's headers, fails with a message instead of going out cut short. Legacy TCP (--tcp)
# has no login, and gets none built. lws follows a redirect by making the request again, headers
# and all, to wherever it points, another server included (the login in the query was dropped
# there). Kismet builds with lws 3.1 and later, and lws before 4.0 cannot be told not to, so the
# second request of a connection attempt is refused instead, before it is sent, whatever the
# version: Kismet never redirects this one. The login's two header values and that count live in
# the handler, next to lwsuri, which is why capture_framework.h changes.
PARSE_OPTS = "int cf_handler_parse_opts(kis_capture_handler_t *caph, int argc, char *argv[]) {\n"
# What an earlier version of this script put in, which only percent-encoded the query
URI_ESCAPE_EARLIER = """#ifdef HAVE_LIBWEBSOCKETS
/* A user, password or API key for the websocket URI's query: everything but RFC 3986's
 * unreserved characters percent-encoded, as Kismet's server decodes the query.  Returns
 * an allocated string. */
static char *cf_ws_uri_escape(const char *in) {
    static const char hex[] = "0123456789ABCDEF";
    char *out = (char *) malloc(strlen(in) * 3 + 1);
    size_t n = 0;

    for (; *in != '\\0'; in++) {
        unsigned char c = (unsigned char) *in;

        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                c == '-' || c == '.' || c == '_' || c == '~') {
            out[n++] = (char) c;
        } else {
            out[n++] = '%';
            out[n++] = hex[c >> 4];
            out[n++] = hex[c & 0x0F];
        }
    }
    out[n] = '\\0';

    return out;
}
#endif

"""
LOGIN_FUNCTIONS = """#ifdef HAVE_LIBWEBSOCKETS
/* A user, password or API key with everything but RFC 3986's unreserved characters
 * percent-encoded, as Kismet's server decodes the websocket URI's query and a Cookie
 * header.  Returns an allocated string. */
static char *cf_ws_uri_escape(const char *in) {
    static const char hex[] = "0123456789ABCDEF";
    char *out = (char *) malloc(strlen(in) * 3 + 1);
    size_t n = 0;

    for (; *in != '\\0'; in++) {
        unsigned char c = (unsigned char) *in;

        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                c == '-' || c == '.' || c == '_' || c == '~') {
            out[n++] = (char) c;
        } else {
            out[n++] = '%';
            out[n++] = hex[c >> 4];
            out[n++] = hex[c & 0x0F];
        }
    }
    out[n] = '\\0';

    return out;
}

/* A user and password as the value of an HTTP Basic Authorization header: "Basic " and
 * the base64 of user:password.  Returns an allocated string. */
static char *cf_ws_basic_auth(const char *user, const char *password) {
    size_t plain_len = strlen(user) + 1 + strlen(password);
    size_t b64_len = (plain_len + 2) / 3 * 4;
    char *plain = (char *) malloc(plain_len + 1);
    char *out = (char *) malloc(6 + b64_len + 2);

    snprintf(plain, plain_len + 1, "%s:%s", user, password);
    memcpy(out, "Basic ", 6);
    /* lws_b64_encode_string wants room for its '\\0' and one byte more */
    lws_b64_encode_string(plain, (int) plain_len, out + 6, (int) b64_len + 2);
    free(plain);

    return out;
}
#endif

"""
URI_OLD = """        if (user != NULL && password != NULL) {
            snprintf(uri, 1024, "%s?user=%s&password=%s", endp_arg, user, password);
            caph->lwsuri = strdup(uri);
        } else if (token != NULL) {
            snprintf(uri, 1024, "%s?KISMET=%s", endp_arg, token);
            caph->lwsuri = strdup(uri);
        }
"""
URI_ESCAPED = """        if (user != NULL && password != NULL) {
            char *euser = cf_ws_uri_escape(user), *epassword = cf_ws_uri_escape(password);
            snprintf(uri, 1024, "%s?user=%s&password=%s", endp_arg, euser, epassword);
            caph->lwsuri = strdup(uri);
            free(euser);
            free(epassword);
        } else if (token != NULL) {
            char *etoken = cf_ws_uri_escape(token);
            snprintf(uri, 1024, "%s?KISMET=%s", endp_arg, etoken);
            caph->lwsuri = strdup(uri);
            free(etoken);
        }
"""
URI_HEADERS = r"""        /* The login goes in the request's headers, not in the URI, which a reverse proxy
         * in front of Kismet keeps in its access log: a user and password as Basic
         * authorization and an API key as Kismet's session cookie, which the server takes
         * as they are (the cookie percent-decoded).  Basic ends the user name at its first
         * ':', so a user name with one goes in the URI's query, percent-encoded; the
         * server decodes the whole query before it splits it at '&', so that login cannot
         * hold an '&'.  Legacy TCP (--tcp) has no login, and was warned about it above. */
        if (caph->use_ws) {
            if (user != NULL && password != NULL && strchr(user, ':') == NULL) {
                caph->lwsauthorization = cf_ws_basic_auth(user, password);
                caph->lwsuri = strdup(endp_arg);
            } else if (user != NULL && password != NULL) {
                char *euser = cf_ws_uri_escape(user), *epassword = cf_ws_uri_escape(password);
                int urilen = snprintf(uri, 1024, "%s?user=%s&password=%s", endp_arg, euser,
                        epassword);
                free(euser);
                free(epassword);
                if (urilen >= 1024) {
                    fprintf(stderr, "FATAL: A user name with ':' puts the login in the "
                            "websocket URI, which would be %d bytes long with it, more than "
                            "the 1023 it can be; use an API key\n", urilen);
                    ret = -1;
                    goto cleanup;
                }
                caph->lwsuri = strdup(uri);
            } else if (token != NULL) {
                char *etoken = cf_ws_uri_escape(token);
                caph->lwscookie = (char *) malloc(strlen(etoken) + 8);
                sprintf(caph->lwscookie, "KISMET=%s", etoken);
                free(etoken);
                caph->lwsuri = strdup(endp_arg);
            }
        }
"""
HANDSHAKE_CASE = r"""        case LWS_CALLBACK_CLIENT_APPEND_HANDSHAKE_HEADER: {
            unsigned char **p = (unsigned char **) in, *end = *p + len;
            const char *auth = caph->lwsauthorization, *cookie = caph->lwscookie;

            /* The login (see cf_handler_parse_opts).  lws makes the request again for a
             * redirect, headers and all, to wherever it points: a second request on one
             * connection attempt is a redirect, and is refused before it is sent.  len is
             * the room lws has left in its buffer for more headers: a login too long for it
             * fails the connection, and says so, rather than go out cut short. */
            if (caph->lwshandshakes++ > 0) {
                fprintf(stderr, "FATAL: The websocket was answered with a redirect, which is "
                        "not followed: Kismet never redirects it, and the login would go along "
                        "to wherever it points; check --connect, --endpoint and --ssl\n");
            } else if (auth != NULL && lws_add_http_header_by_token(wsi,
                        WSI_TOKEN_HTTP_AUTHORIZATION, (const unsigned char *) auth,
                        (int) strlen(auth), p, end)) {
                fprintf(stderr, "FATAL: The login does not fit in the websocket request's "
                        "headers, which have %u bytes left for it; use a shorter one, or an "
                        "API key\n", (unsigned int) len);
            } else if (cookie != NULL && lws_add_http_header_by_token(wsi,
                        WSI_TOKEN_HTTP_COOKIE, (const unsigned char *) cookie,
                        (int) strlen(cookie), p, end)) {
                fprintf(stderr, "FATAL: The API key does not fit in the websocket request's "
                        "headers, which have %u bytes left for it; the keys Kismet makes have "
                        "32 characters\n", (unsigned int) len);
            } else {
                break;
            }
            /* lws drops the connection without a CLIENT_CONNECTION_ERROR: end the loop as
             * that would, or the process would wait for good */
            pthread_mutex_lock(&caph->handler_lock);
            caph->lwsclientwsi = NULL;
            caph->lwsestablished = 0;
            caph->shutdown = 1;
            pthread_mutex_unlock(&caph->handler_lock);
            lws_cancel_service(caph->lwscontext);
            return -1;
        }
"""
CONNECT_OLD = "    caph->lwsci.pwsi = &caph->lwsclientwsi;\n"
CONNECT_NEW = CONNECT_OLD + """
    /* The first request of this connection; another is a redirect (see
     * LWS_CALLBACK_CLIENT_APPEND_HANDSHAKE_HEADER) */
    caph->lwshandshakes = 0;
"""
LOGIN_INIT_OLD = "    ch->lwsuri = NULL;\n"
LOGIN_INIT_NEW = LOGIN_INIT_OLD + """    ch->lwsauthorization = NULL;
    ch->lwscookie = NULL;
    ch->lwshandshakes = 0;
"""
LOGIN_FIELDS_OLD = "    char *lwsuri;\n"
LOGIN_FIELDS_NEW = """    char *lwsuri;

    /* The login, which goes in the websocket request's headers rather than in lwsuri:
     * the value of its Authorization header (a user and password) or of its Cookie
     * header (an API key); NULL when there is none */
    char *lwsauthorization;
    char *lwscookie;

    /* The requests lws has made on this connection attempt: it makes a second only to
     * follow a redirect, which would take the login along */
    int lwshandshakes;
"""


def login_in_headers(texts):
    c, h = texts["capture_framework.c"], texts["capture_framework.h"]
    if "lwsauthorization" in c:
        return texts  # fixed already, here
    uri = URI_ESCAPED if URI_ESCAPED in c else URI_OLD
    if (c.count(uri) != 1 or c.count(PARSE_OPTS) != 1 or c.count(LOGIN_INIT_OLD) != 1 or
            c.count(WS_CLOSED_CASE) != 1 or c.count(CONNECT_OLD) != 1 or
            ("cf_ws_uri_escape" in c and c.count(URI_ESCAPE_EARLIER) != 1) or
            ("lwsauthorization" not in h and h.count(LOGIN_FIELDS_OLD) != 1)):
        print("  capture_framework.c: the websocket login has changed, it still goes in the URI")
        return texts
    if URI_ESCAPE_EARLIER in c:
        c = c.replace(URI_ESCAPE_EARLIER, LOGIN_FUNCTIONS)
    else:
        c = c.replace(PARSE_OPTS, LOGIN_FUNCTIONS + PARSE_OPTS)
    c = c.replace(uri, URI_HEADERS)
    c = c.replace(WS_CLOSED_CASE, HANDSHAKE_CASE + WS_CLOSED_CASE)
    c = c.replace(CONNECT_OLD, CONNECT_NEW)
    texts["capture_framework.c"] = c.replace(LOGIN_INIT_OLD, LOGIN_INIT_NEW)
    if "lwsauthorization" not in h:
        texts["capture_framework.h"] = h.replace(LOGIN_FIELDS_OLD, LOGIN_FIELDS_NEW)
    return texts


edit_files(["capture_framework.c", "capture_framework.h"], login_in_headers)


# Upstream fix: libwebsockets (4.2 and later, built with its netlink role and SMD) reads the
# machine's routing table when a context is created, and tells its own SMD listeners about
# every route and address in it, one message each, which wait in a queue for the next pass of
# the service loop. The queue holds 40 by default and drops the rest with a warning each,
# "_lws_smd_msg_send: rejecting message on queue depth 40": a remote helper printed a few for
# every connection, retries included, on a machine with more routes than that (Docker's
# networks add some). Nothing in the framework listens (lws's own listener only starts captive
# portal checks), and the loop empties the queue at every pass, each of which reads the netlink
# socket once, at most 4096 bytes, fewer than 150 routes: a queue of 1024 keeps them all.
SMD_OLD = "                caph->lwscontext = lws_create_context(&caph->lwsinfo);\n"
SMD_NEW = """#if defined(LWS_WITH_SYS_SMD) && defined(LWS_WITH_NETLINK)
                /* lws tells its own listeners about each of the machine's routes as it
                 * starts, and its queue of 40 would drop the rest with a warning each */
                caph->lwsinfo.smd_queue_depth = 1024;
#endif

""" + SMD_OLD


def smd_queue_depth(text):
    if "smd_queue_depth" in text:
        return text  # fixed already, here or upstream
    if text.count(SMD_OLD) != 1:
        print("  capture_framework.c: lws_create_context has changed, its queue warnings not fixed")
        return text
    return text.replace(SMD_OLD, SMD_NEW)


edit("capture_framework.c", smd_queue_depth)


# Upstream fix: a channel set passes the channel callback's message buffer on to
# cf_send_configresp whether or not the callback wrote anything in it, and cf_send_configresp,
# unlike cf_send_proberesp and cf_send_openresp, took an empty message for one: a remote helper
# printed an empty "INFO: " line for every channel set it took, and sent Kismet an empty
# message, which it ignores. An empty message is none now.
CONFIGRESP_START = ("int cf_send_configresp(kis_capture_handler_t *caph, unsigned int in_seqno,\n"
                    "        unsigned int success, const char *msg) {\n")
CONFIGRESP_OLD = "    /* Send messages independently */\n    if (msg != NULL) {\n"
CONFIGRESP_NEW = """    /* A channel set passes the callback's message buffer on, written in or not: an
     * empty one is no message */
    if (msg != NULL && msg[0] == '\\0')
        msg = NULL;

""" + CONFIGRESP_OLD


def configresp_empty_message(text):
    start = text.find(CONFIGRESP_START)
    body = start + len(CONFIGRESP_START)
    end = text.find("\n}\n", body)
    if start >= 0 and "msg[0] == '\\0'" in text[body:end]:
        return text  # fixed already, here or upstream
    at = text.find(CONFIGRESP_OLD, body)
    if start < 0 or at < 0 or at > end:
        print("  capture_framework.c: cf_send_configresp has changed, its empty INFO line not fixed")
        return text
    return text[:at] + CONFIGRESP_NEW + text[at + len(CONFIGRESP_OLD):]


edit("capture_framework.c", configresp_empty_message)
EOF

# configure.ac pulls pkg-config's macros and its own m4/ in through aclocal, so
# autoconf on its own fails with "possibly undefined macro: AC_DEFINE". Only when configure.ac
# is newer than configure: run again right after it edited configure.ac, autom4te cannot tell by
# the second that its cache is fresh, and writes the same configure and aclocal.m4 anew.
if [ "$KISMET/configure.ac" -nt "$KISMET/configure" ]; then
    echo "  regenerating configure (needs autoconf and automake)"
    (cd "$KISMET" && aclocal -I m4 && autoconf)
fi

echo "Done. Now: cd $KISMET && ./configure && make"
