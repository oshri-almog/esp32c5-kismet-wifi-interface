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
# the request's headers, fails with a message instead of going out cut short. The login's two
# header values live in the handler, next to lwsuri, which is why capture_framework.h changes.
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
         * hold an '&'. */
        if (user != NULL && password != NULL && strchr(user, ':') == NULL) {
            caph->lwsauthorization = cf_ws_basic_auth(user, password);
            caph->lwsuri = strdup(endp_arg);
        } else if (user != NULL && password != NULL) {
            char *euser = cf_ws_uri_escape(user), *epassword = cf_ws_uri_escape(password);
            int urilen = snprintf(uri, 1024, "%s?user=%s&password=%s", endp_arg, euser, epassword);
            free(euser);
            free(epassword);
            if (urilen >= 1024) {
                fprintf(stderr, "FATAL: With the login in it, the websocket URI would be %d "
                        "bytes long, and it can be 1023; use a shorter login, or an API key\n",
                        urilen);
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
"""
HANDSHAKE_CASE = r"""        case LWS_CALLBACK_CLIENT_APPEND_HANDSHAKE_HEADER: {
            unsigned char **p = (unsigned char **) in, *end = *p + len;
            const char *auth = caph->lwsauthorization, *cookie = caph->lwscookie;

            /* The login (see cf_handler_parse_opts).  len is the room lws has left in its
             * buffer for more headers: a login too long for it fails the connection, and
             * says so, rather than go out cut short. */
            if ((auth != NULL && lws_add_http_header_by_token(wsi,
                            WSI_TOKEN_HTTP_AUTHORIZATION, (const unsigned char *) auth,
                            (int) strlen(auth), p, end)) ||
                    (cookie != NULL && lws_add_http_header_by_token(wsi,
                            WSI_TOKEN_HTTP_COOKIE, (const unsigned char *) cookie,
                            (int) strlen(cookie), p, end))) {
                fprintf(stderr, "FATAL: The login does not fit in the websocket request's "
                        "headers, which have %u bytes left for it; use a shorter one\n",
                        (unsigned int) len);
                return -1;
            }
            break;
        }
"""
LOGIN_INIT_OLD = "    ch->lwsuri = NULL;\n"
LOGIN_INIT_NEW = LOGIN_INIT_OLD + "    ch->lwsauthorization = NULL;\n    ch->lwscookie = NULL;\n"
LOGIN_FIELDS_OLD = "    char *lwsuri;\n"
LOGIN_FIELDS_NEW = """    char *lwsuri;

    /* The login, which goes in the websocket request's headers rather than in lwsuri:
     * the value of its Authorization header (a user and password) or of its Cookie
     * header (an API key); NULL when there is none */
    char *lwsauthorization;
    char *lwscookie;
"""


def login_in_headers(texts):
    c, h = texts["capture_framework.c"], texts["capture_framework.h"]
    if "lwsauthorization" in c:
        return texts  # fixed already, here
    uri = URI_ESCAPED if URI_ESCAPED in c else URI_OLD
    if (c.count(uri) != 1 or c.count(PARSE_OPTS) != 1 or c.count(LOGIN_INIT_OLD) != 1 or
            c.count(WS_CLOSED_CASE) != 1 or
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
