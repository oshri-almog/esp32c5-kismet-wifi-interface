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


# Upstream fix: the websocket login went into the URI's query as it was. Kismet's server
# (kis_net_beast_httpd decode_get_variables) percent-decodes the query, so a '%' followed by
# two hex digits arrived as another character, and a space broke the request line. Everything
# but RFC 3986's unreserved characters is percent-encoded now. The server decodes the whole
# query before it splits it at '&', though, so a user or password with '&' in it still cannot
# log in, however it is encoded; nothing a client sends can change that.
PARSE_OPTS = "int cf_handler_parse_opts(kis_capture_handler_t *caph, int argc, char *argv[]) {\n"
URI_ESCAPE = """#ifdef HAVE_LIBWEBSOCKETS
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
URI_OLD = """        if (user != NULL && password != NULL) {
            snprintf(uri, 1024, "%s?user=%s&password=%s", endp_arg, user, password);
            caph->lwsuri = strdup(uri);
        } else if (token != NULL) {
            snprintf(uri, 1024, "%s?KISMET=%s", endp_arg, token);
            caph->lwsuri = strdup(uri);
        }
"""
URI_NEW = """        if (user != NULL && password != NULL) {
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


def escape_ws_login(text):
    if "cf_ws_uri_escape" in text:
        return text  # fixed already, here or upstream
    if text.count(URI_OLD) != 1 or text.count(PARSE_OPTS) != 1:
        print("  capture_framework.c: the websocket login URI has changed, its encoding not fixed")
        return text
    text = text.replace(PARSE_OPTS, URI_ESCAPE + PARSE_OPTS)
    return text.replace(URI_OLD, URI_NEW)


edit("capture_framework.c", escape_ws_login)
