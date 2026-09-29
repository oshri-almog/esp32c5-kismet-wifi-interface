#ifdef HAVE_LIBWEBSOCKETS
/* What a command line says about remote capture and its login */
typedef struct {
    bool remote, tcp;
    const char *user, *password, *apikey;
} login_args_t;

/* Reads a command line the way the capture framework does (cf_handler_parse_opts):
 * with getopt_long and the framework's own table of long options.  getopt_long takes
 * any abbreviation that fits one option alone (--pass for --password, not --s), which
 * only the whole table tells; it takes the word after an option that needs a value
 * as that value, whatever it looks like; it stops at "--"; and a later option wins
 * over an earlier one.  The '-' that starts the short options makes it read argv in
 * its order, where the framework's getopt moves the operands to the end; the options
 * it finds are the same.  The values point into argv. */
static void read_login_args(int argc, char *argv[], login_args_t *args) {
    static const struct option longopt[] = {
        { "in-fd", required_argument, 0, 1 },
        { "out-fd", required_argument, 0, 2 },
        { "connect", required_argument, 0, 3 },
        { "source", required_argument, 0, 4 },
        { "disable-retry", no_argument, 0, 5 },
        { "daemonize", no_argument, 0, 6 },
        { "list", no_argument, 0, 7 },
        { "fixed-gps", required_argument, 0, 8 },
        { "gps-name", required_argument, 0, 9 },
        { "host", required_argument, 0, 10 },
        { "autodetect", optional_argument, 0, 11 },
        { "tcp", no_argument, 0, 12 },
        { "ssl", no_argument, 0, 13 },
        { "user", required_argument, 0, 14 },
        { "password", required_argument, 0, 15 },
        { "apikey", required_argument, 0, 16 },
        { "endpoint", required_argument, 0, 17 },
        { "ssl-certificate", required_argument, 0, 18 },
        { "help", no_argument, 0, 'h' },
        { "version", no_argument, 0, 'v' },
        { 0, 0, 0, 0 }
    };
    int r;

    memset(args, 0, sizeof(*args));
    /* 0 starts getopt afresh, as the framework does before it reads argv itself */
    optind = 0;
    opterr = 0;
    while ((r = getopt_long(argc, argv, "-vh", longopt, NULL)) != -1) {
        if (r == 3 || r == 10 || r == 11)
            args->remote = true;
        else if (r == 12)
            args->tcp = true;
        else if (r == 14)
            args->user = optarg;
        else if (r == 15)
            args->password = optarg;
        else if (r == 16)
            args->apikey = optarg;
    }
}
#endif

/* Remote capture over websockets needs a Kismet login, and one on the command line
 * can be read by every user in the process list.  So with --connect, --host or
 * --autodetect, what the command line leaves out of the login comes from the
 * environment: with none of --user, --password and --apikey, KISMET_CAP_APIKEY or
 * else KISMET_CAP_USER and KISMET_CAP_PASSWORD; with --user alone,
 * KISMET_CAP_PASSWORD; with --password alone, KISMET_CAP_USER.  An empty variable
 * counts as unset, and the command line is read as the framework will read it
 * (read_login_args: --pass is --password, and nothing after a "--" counts).  They go
 * to the framework as options in a copy of argv, right after the program's name,
 * where no "--" can make operands of them; the process's own command line,
 * /proc/<pid>/cmdline, keeps the original.  Legacy TCP (--tcp) has no login, and a
 * Kismet built without libwebsockets has no login options: nothing is added then.
 * Returns argv itself when nothing is added. */
static char **login_from_env(int argc, char *argv[], int *ret_argc) {
    *ret_argc = argc;
#ifdef HAVE_LIBWEBSOCKETS
    const char *apikey = getenv("KISMET_CAP_APIKEY");
    const char *user = getenv("KISMET_CAP_USER"), *password = getenv("KISMET_CAP_PASSWORD");
    login_args_t given;
    char **copy;
    int n = 0;

    read_login_args(argc, argv, &given);
    if (!given.remote || given.tcp || given.apikey != NULL ||
            (given.user != NULL && given.password != NULL))
        return argv;

    if (apikey != NULL && apikey[0] == '\0')
        apikey = NULL;
    if (user != NULL && user[0] == '\0')
        user = NULL;
    if (password != NULL && password[0] == '\0')
        password = NULL;

    if (given.user != NULL || given.password != NULL) {
        /* half a login given: only the other half can complete it */
        apikey = NULL;
        if (given.user != NULL)
            user = NULL;
        else
            password = NULL;
    } else if (apikey != NULL) {
        user = password = NULL;
    } else if (user == NULL || password == NULL) {
        return argv;
    }
    if (apikey == NULL && user == NULL && password == NULL)
        return argv;

    /* at most four options added, and the NULL that ends argv */
    copy = (char **) calloc(argc + 5, sizeof(char *));
    copy[n++] = argv[0];
    if (apikey != NULL) {
        copy[n++] = (char *) "--apikey";
        copy[n++] = (char *) apikey;
    }
    if (user != NULL) {
        copy[n++] = (char *) "--user";
        copy[n++] = (char *) user;
    }
    if (password != NULL) {
        copy[n++] = (char *) "--password";
        copy[n++] = (char *) password;
    }
    memcpy(copy + n, argv + 1, sizeof(char *) * (argc - 1));
    n += argc - 1;
    copy[n] = NULL;
    *ret_argc = n;
    return copy;
#else
    return argv;
#endif
}

/* Kismet's server percent-decodes the websocket URI's query and only then splits it at
 * '&' (kis_net_beast_httpd.cc, decode_get_variables), so a user or password with '&'
 * in it is cut short there however the framework encodes it, and cannot log in.  Said
 * on stderr before the framework tries, for a login from the command line as for one
 * from the environment (argv is login_from_env's), when the framework logs in with a
 * user and password: it does when it has both, and with the API key otherwise.  An
 * API key is hex digits. */
static void warn_login_ampersand(int argc, char *argv[]) {
#ifdef HAVE_LIBWEBSOCKETS
    login_args_t given;

    read_login_args(argc, argv, &given);
    if (given.remote && !given.tcp && given.user != NULL && given.password != NULL &&
            (strchr(given.user, '&') != NULL || strchr(given.password, '&') != NULL))
        fprintf(stderr, "WARNING: the Kismet user name or password contains '&', and Kismet's "
                "server splits the login at '&' after decoding it, so it cannot log in with "
                "this one; use an API key (--apikey or KISMET_CAP_APIKEY) or a password "
                "without '&'\n");
#endif
}
