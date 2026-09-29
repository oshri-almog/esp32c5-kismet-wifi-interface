/* stderr, caught in a file between catch_stderr and caught (which returns it) */
static int stderr_saved = -1, stderr_file = -1;

static void catch_stderr(void) {
    char path[128];

    snprintf(path, sizeof(path), "%s/stderr", tree);
    fflush(stderr);
    stderr_saved = dup(2);
    stderr_file = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    unlink(path);
    dup2(stderr_file, 2);
}

static const char *caught(void) {
    static char buf[8192];
    ssize_t n;

    fflush(stderr);
    dup2(stderr_saved, 2);
    close(stderr_saved);
    lseek(stderr_file, 0, SEEK_SET);
    n = read(stderr_file, buf, sizeof(buf) - 1);
    buf[n > 0 ? n : 0] = '\0';
    close(stderr_file);
    return buf;
}

/* Does warn_login_cannot_pass warn about these arguments? */
static bool warns_cannot_pass(char **argv) {
    const char *err;
    int argc = 0;

    while (argv[argc] != NULL)
        argc++;
    catch_stderr();
    warn_login_cannot_pass(argc, argv);
    err = caught();
    return strstr(err, "WARNING: the Kismet user name holds ':' and the login '&'") != NULL &&
        strstr(err, "use an API key (--apikey or KISMET_CAP_APIKEY) instead of the login") != NULL;
}

/* What the framework said on stderr in the last parsed() */
static char parse_said[8192];

/* The framework's reading of argv, on a handler of its own */
static kis_capture_handler_t *parsed(char **argv, int *r) {
    kis_capture_handler_t *h = cf_handler_init("esp32c5");
    int argc = 0;

    while (argv[argc] != NULL)
        argc++;
    catch_stderr();
    *r = cf_handler_parse_opts(h, argc, argv);
    snprintf(parse_said, sizeof(parse_said), "%s", caught());
    return h;
}

/* What the value of an "Authorization: Basic" header says, decoded; "" for anything
 * else */
static const char *basic_login(const char *auth) {
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    static char out[8192];
    unsigned int acc = 0, bits = 0;
    size_t n = 0;
    const char *p;

    out[0] = '\0';
    if (auth == NULL || strncmp(auth, "Basic ", 6) != 0 || strlen(auth + 6) % 4 != 0)
        return out;
    for (p = auth + 6; *p != '\0' && *p != '='; p++) {
        const char *at = strchr(b64, *p);
        if (at == NULL || n + 1 >= sizeof(out)) {
            out[0] = '\0';
            return out;
        }
        acc = (acc << 6) | (unsigned int) (at - b64);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = (char) ((acc >> bits) & 0xFF);
        }
    }
    out[n] = '\0';
    return out;
}

#define WS_ENDPOINT "/datasource/remote/remotesource.ws"

/* The login in an Authorization header as user:password, and none in the URI or a cookie */
static bool login_in_basic(kis_capture_handler_t *h, const char *user_password) {
    return strcmp(basic_login(h->lwsauthorization), user_password) == 0 && h->lwscookie == NULL &&
        h->lwsuri != NULL && strcmp(h->lwsuri, WS_ENDPOINT) == 0;
}

/* The API key in the KISMET cookie, as cookie says it, and none in the URI */
static bool key_in_cookie(kis_capture_handler_t *h, const char *cookie) {
    return h->lwscookie != NULL && strcmp(h->lwscookie, cookie) == 0 && h->lwsauthorization == NULL &&
        h->lwsuri != NULL && strcmp(h->lwsuri, WS_ENDPOINT) == 0;
}
#endif

/* lwsuri and the login options exist only in a Kismet built with libwebsockets;
 * without it login_from_env adds nothing, and this checks just that */
static void test_login(void) {
    char *base[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    int n;

    unsetenv("KISMET_CAP_APIKEY");
    unsetenv("KISMET_CAP_USER");
    unsetenv("KISMET_CAP_PASSWORD");

#ifdef HAVE_LIBWEBSOCKETS
    char *eq[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect=localhost:2501",
        (char *) "--source=esp32c5-ttyACM0", NULL };
    char *given[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--apikey=abc", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *tcp[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:3501",
        (char *) "--tcp", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *local_only[] = { (char *) "kismet_cap_esp32c5", (char *) "--list", NULL };
    char *autodetect[] = { (char *) "kismet_cap_esp32c5", (char *) "--autodetect",
        (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *dashdash[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--source", (char *) "esp32c5-ttyACM0", (char *) "--", NULL };
    char *user_only[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--user", (char *) "kismet", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *password_only[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--password=pw", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    char *both[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
        (char *) "--user", (char *) "me", (char *) "--password", (char *) "mine",
        (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
    kis_capture_handler_t *h;
    char **out;
    int r;

    check(login_from_env(5, base, &n) == base && n == 5, "no login in the environment: argv as it is");

    setenv("KISMET_CAP_APIKEY", "k3y", 1);
    out = login_from_env(5, base, &n);
    check(out != base && n == 7 && strcmp(out[1], "--apikey") == 0 && strcmp(out[2], "k3y") == 0 &&
            strcmp(out[3], "--connect") == 0 && out[n] == NULL && base[5] == NULL,
            "KISMET_CAP_APIKEY becomes --apikey in a copy of argv, right after the name");
    h = parsed(out, &r);
    check(r == 2 && key_in_cookie(h, "KISMET=k3y"),
            "the framework takes it, and sends it as the cookie KISMET=k3y (URI %s)", h->lwsuri ? h->lwsuri : "");
    out = login_from_env(3, eq, &n);
    check(n == 5 && has_args(out, n, "--apikey", "k3y"), "--connect=host:port works too");
    check(login_from_env(6, given, &n) == given && n == 6, "an --apikey given on the command line wins");
    check(login_from_env(6, tcp, &n) == tcp, "legacy TCP takes no login");
    check(login_from_env(2, local_only, &n) == local_only, "not remote: nothing added");

    /* --autodetect finds the server by its announcement and is as remote as
     * --connect.  Only the arguments are checked: parsing them would wait for an
     * announcement on UDP 2501. */
    out = login_from_env(4, autodetect, &n);
    check(n == 6 && has_args(out, n, "--apikey", "k3y"), "--autodetect gets the login too");

    /* after a "--" getopt reads no options, so an appended login would be lost */
    out = login_from_env(6, dashdash, &n);
    h = parsed(out, &r);
    check(n == 8 && r == 2 && key_in_cookie(h, "KISMET=k3y"),
            "a \"--\" on the command line does not hide it (%s)", h->lwscookie ? h->lwscookie : "");

    setenv("KISMET_CAP_USER", "kismet", 1);
    setenv("KISMET_CAP_PASSWORD", "pw", 1);
    out = login_from_env(5, base, &n);
    check(n == 7 && has_args(out, n, "--apikey", "k3y"), "an API key is used before user and password");
    unsetenv("KISMET_CAP_APIKEY");
    out = login_from_env(5, base, &n);
    check(n == 9 && has_args(out, n, "--user", "kismet") && has_args(out, n, "--password", "pw"),
            "KISMET_CAP_USER and KISMET_CAP_PASSWORD become --user and --password");
    h = parsed(out, &r);
    check(r == 2 && login_in_basic(h, "kismet:pw") &&
            strcmp(h->lwsauthorization, "Basic a2lzbWV0OnB3") == 0,
            "the framework takes them, and sends them as Basic authorization (%s)",
            h->lwsauthorization ? h->lwsauthorization : "");
    check(login_from_env(9, both, &n) == both, "a whole login on the command line is used as it is");

    /* half a login on the command line, the secret in the environment */
    setenv("KISMET_CAP_APIKEY", "k3y", 1);
    unsetenv("KISMET_CAP_USER");
    out = login_from_env(7, user_only, &n);
    check(n == 9 && has_args(out, n, "--password", "pw") && !has_args(out, n, "--apikey", "k3y"),
            "--user alone gets KISMET_CAP_PASSWORD, and nothing else");
    h = parsed(out, &r);
    check(r == 2 && login_in_basic(h, "kismet:pw"), "the framework takes the two halves");
    setenv("KISMET_CAP_USER", "kismet", 1);
    out = login_from_env(6, password_only, &n);
    check(n == 8 && has_args(out, n, "--user", "kismet") && !has_args(out, n, "--apikey", "k3y"),
            "--password alone gets KISMET_CAP_USER");
    h = parsed(out, &r);
    check(r == 2 && login_in_basic(h, "kismet:pw"), "the framework takes those too");

    /* The framework's getopt_long takes any abbreviation that fits one option alone,
     * and so does login_from_env: --pass is --password, --conn is --connect */
    {
        char *pass_abbrev[] = { (char *) "kismet_cap_esp32c5", (char *) "--conn", (char *) "localhost:2501",
            (char *) "--pass", (char *) "pw", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *source_value[] = { (char *) "kismet_cap_esp32c5", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--source", (char *) "--user=x", NULL };
        out = login_from_env(7, pass_abbrev, &n);
        check(n == 9 && has_args(out, n, "--user", "kismet") && !has_args(out, n, "--apikey", "k3y"),
                "--pass alone, --password abbreviated, gets KISMET_CAP_USER and not the API key");
        h = parsed(out, &r);
        check(r == 2 && login_in_basic(h, "kismet:pw"), "the framework takes it as the password");
        out = login_from_env(5, source_value, &n);
        check(n == 7 && has_args(out, n, "--apikey", "k3y"),
                "a word that is an option's value (--source --user=x) is no login option");
    }
    unsetenv("KISMET_CAP_APIKEY");

    unsetenv("KISMET_CAP_PASSWORD");
    check(login_from_env(5, base, &n) == base, "a user without a password is not enough");
    check(login_from_env(7, user_only, &n) == user_only, "--user with no password anywhere: nothing added");
    unsetenv("KISMET_CAP_USER");

    /* The framework (add-to-kismet.sh) sends the login in the request's headers, where
     * Kismet takes it as it is and a reverse proxy does not log it: a user and password
     * as Basic authorization, whatever they hold, an API key as the KISMET cookie,
     * percent-encoded as Kismet decodes it ('+' would be a space).  Only a user name
     * with ':', where Basic ends the user name, goes in the URI's query, percent-encoded,
     * and a URI too long for the framework's 1024 bytes is refused, not cut. */
    {
        char *odd[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "me you", (char *) "--password", (char *) "p&%41 s+w/rd~:x",
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *odd_key[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--apikey", (char *) "k 3y+%41", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "me:you", (char *) "--password", (char *) "a b%41",
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *key_and_login[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--apikey", (char *) "k3y", (char *) "--user", (char *) "me", (char *) "--password",
            (char *) "pw", (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *endpoint[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--apikey", (char *) "k3y", (char *) "--endpoint", (char *) "/proxied/remote.ws",
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char long_pw[3001], fits[969], too_long[970], amps[401];
        char *long_basic[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "me", (char *) "--password", long_pw,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon_fits[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "a:b", (char *) "--password", fits,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon_too_long[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "a:b", (char *) "--password", too_long,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char *colon_amps[] = { (char *) "x", (char *) "--connect", (char *) "localhost:2501",
            (char *) "--user", (char *) "a:b", (char *) "--password", amps,
            (char *) "--source", (char *) "esp32c5-ttyACM0", NULL };
        char want[1100];

        h = parsed(odd, &r);
        check(r == 2 && login_in_basic(h, "me you:p&%41 s+w/rd~:x"),
                "a login with '&', a space, %%41, '+' and ':' goes in the Authorization header as it "
                "is, and the URI holds none of it (%s)", h->lwsuri ? h->lwsuri : "");
        h = parsed(odd_key, &r);
        check(r == 2 && key_in_cookie(h, "KISMET=k%203y%2B%2541"),
                "an API key goes in the cookie, percent-encoded, '+' too (%s)",
                h->lwscookie ? h->lwscookie : "");
        h = parsed(colon, &r);
        check(r == 2 && h->lwsauthorization == NULL && h->lwscookie == NULL && h->lwsuri != NULL &&
                strcmp(h->lwsuri, WS_ENDPOINT "?user=me%3Ayou&password=a%20b%2541") == 0,
                "a user name with ':' goes in the URI's query instead, percent-encoded (%s)",
                h->lwsuri ? h->lwsuri : "");
        h = parsed(key_and_login, &r);
        check(r == 2 && login_in_basic(h, "me:pw") &&
                strstr(parse_said, "WARNING: Ignoring APIKEY and using login information") != NULL,
                "a login and an API key: the login is used, as before, and the framework says so");
        h = parsed(endpoint, &r);
        check(r == 2 && h->lwsuri != NULL && strcmp(h->lwsuri, "/proxied/remote.ws") == 0 &&
                h->lwscookie != NULL && strcmp(h->lwscookie, "KISMET=k3y") == 0,
                "--endpoint is the URI as it is, and the key still goes in the cookie (%s)",
                h->lwsuri ? h->lwsuri : "");

        memset(long_pw, 'p', sizeof(long_pw) - 1);
        long_pw[sizeof(long_pw) - 1] = '\0';
        h = parsed(long_basic, &r);
        snprintf(want, sizeof(want), "me:%.40s", long_pw);
        check(r == 2 && strlen(basic_login(h->lwsauthorization)) == 3003 &&
                strncmp(basic_login(h->lwsauthorization), want, strlen(want)) == 0 &&
                strcmp(h->lwsuri, WS_ENDPOINT) == 0,
                "a 3000 character password goes whole in the header (whether it fits in the "
                "request is lws's to say, when it is sent)");

        /* 55 bytes of URI around the password, which is not encoded: 968 make 1023 */
        memset(fits, 'x', sizeof(fits) - 1);
        fits[sizeof(fits) - 1] = '\0';
        h = parsed(colon_fits, &r);
        snprintf(want, sizeof(want), WS_ENDPOINT "?user=a%%3Ab&password=%s", fits);
        check(r == 2 && h->lwsuri != NULL && strlen(h->lwsuri) == 1023 && strcmp(h->lwsuri, want) == 0,
                "a user name with ':': a URI of 1023 bytes is whole");
        memset(too_long, 'x', sizeof(too_long) - 1);
        too_long[sizeof(too_long) - 1] = '\0';
        h = parsed(colon_too_long, &r);
        check(r < 0 && h->lwsuri == NULL &&
                strstr(parse_said, "FATAL: A user name with ':' puts the login in the websocket URI, "
                    "which would be 1024 bytes long with it, more than the 1023 it can be; use an "
                    "API key") != NULL,
                "... and one of 1024 is refused with a reason, not cut short");
        memset(amps, '&', sizeof(amps) - 1);
        amps[sizeof(amps) - 1] = '\0';
        h = parsed(colon_amps, &r);
        check(r < 0 && strstr(parse_said, "which would be 1255 bytes long") != NULL,
                "400 '&' in the password are 1200 bytes encoded, and counted so");
    }

    /* A login cannot pass only when the user name holds ':', and so goes in the URI's
     * query, where Kismet cuts it at every '&' after decoding it: a warning then, however
     * the login came */
    {
        char *pw[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user", (char *) "me:x",
            (char *) "--password", (char *) "a&b", (char *) "--source", (char *) "esp32c5", NULL };
        char *pw_eq[] = { (char *) "x", (char *) "--connect=h:2501", (char *) "--password=a&b",
            (char *) "--user=me:x", NULL };
        char *usr[] = { (char *) "x", (char *) "--host", (char *) "h:2501", (char *) "--user", (char *) "m&e:x",
            (char *) "--password", (char *) "pw", NULL };
        char *abbrev[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--use", (char *) "me:x",
            (char *) "--pass", (char *) "a&b", NULL };
        char *abbrev_eq[] = { (char *) "x", (char *) "--conn=h:2501", (char *) "--us=m&e:x", (char *) "--passw=pw", NULL };
        char *amp_basic[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user", (char *) "m&e",
            (char *) "--password", (char *) "a&b c%41", NULL };
        char *colon_plain[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user",
            (char *) "me:x", (char *) "--password", (char *) "a%41 b", NULL };
        char *tcp_amp[] = { (char *) "x", (char *) "--connect", (char *) "h:3501", (char *) "--tcp",
            (char *) "--user", (char *) "me:x", (char *) "--password", (char *) "a&b", NULL };
        char *after_dashes[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--apikey",
            (char *) "k", (char *) "--", (char *) "--user", (char *) "me:x", (char *) "--password", (char *) "a&b", NULL };
        char *key_no_pw[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--apikey", (char *) "k",
            (char *) "--user", (char *) "a:b&c", NULL };
        char *value_amp[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--source",
            (char *) "--password=a&b", (char *) "--user", (char *) "me:x", (char *) "--password", (char *) "pw", NULL };
        char *later_wins[] = { (char *) "x", (char *) "--connect", (char *) "h:2501", (char *) "--user", (char *) "me:x",
            (char *) "--password", (char *) "a&b", (char *) "--password", (char *) "pw", NULL };
        check(warns_cannot_pass(pw) && warns_cannot_pass(pw_eq) && warns_cannot_pass(usr),
                "a user name with ':' and an '&' in the password or the user name: warned about, "
                "--opt value and --opt=value");
        check(warns_cannot_pass(abbrev) && warns_cannot_pass(abbrev_eq),
                "... and with the options abbreviated, as getopt_long takes them (--use, --pass, --us=)");
        check(!warns_cannot_pass(amp_basic) && !warns_cannot_pass(colon_plain),
                "not for an '&' in a login without ':' in its user name, which goes as Basic, nor for "
                "a user name with ':' and no '&'");
        check(!warns_cannot_pass(tcp_amp) && !warns_cannot_pass(after_dashes),
                "not over legacy TCP, which has no login, nor for options after \"--\"");
        check(!warns_cannot_pass(key_no_pw) && !warns_cannot_pass(value_amp) && !warns_cannot_pass(later_wins),
                "nor for a user without a password, a '&' in another option's value, or a password "
                "that a later one replaces");
        setenv("KISMET_CAP_USER", "me:x", 1);
        setenv("KISMET_CAP_PASSWORD", "a&b", 1);
        out = login_from_env(5, base, &n);
        check(warns_cannot_pass(out), "and for a login from KISMET_CAP_USER and KISMET_CAP_PASSWORD");
        setenv("KISMET_CAP_USER", "me", 1);
        out = login_from_env(5, base, &n);
        check(!warns_cannot_pass(out), "... but not when the user name there has no ':'");
        unsetenv("KISMET_CAP_USER");
        unsetenv("KISMET_CAP_PASSWORD");
    }
#else
    setenv("KISMET_CAP_APIKEY", "k3y", 1);
    check(login_from_env(5, base, &n) == base && n == 5, "no libwebsockets: no remote login, argv as it is");
    unsetenv("KISMET_CAP_APIKEY");
#endif
}

