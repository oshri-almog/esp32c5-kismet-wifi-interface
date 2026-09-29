# Fact sheet: using Kismet (commit cfe427074) with ESP32-C5 sources

Scope: what Kismet itself does, as a user of this project meets it. Config files, login, API keys,
remote capture, `source=` options, channel hopping and splitting, REST calls, logging, the kismetdb
tools, systemd, privileges, packet de-duplication and phy names. The helper, firmware, Docker and
build details live in the sibling fact sheets (`c-helper-build.md`, `python-helper.md`,
`docker.md`, `firmware.md`, `field.md`). This sheet refers to them only where they meet Kismet.

## How to read the references

- `K/<file>:<line>` = Kismet source at
  `C:\Users\oshria\AppData\Local\Temp\claude\c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer\75fe8a4e-1aa2-48f3-9e8d-8f12a0275438\scratchpad\kismet`,
  commit `cfe427074b7ffcfcbc055a123c1df3b3cde60d59` ("Merge branch 'shrout1-ble-uuid-manufacturer-data'",
  2026-09-16). This tree has **no `docs/` directory**. `K/README.md` points to the external docs at
  kismetwireless.net. `K/README.OLD` describes an obsolete Kismet (`ncsource=`, `hop=`, `velocity=`) and
  **must not be used**.
- `P/<file>:<line>` = this project, `C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface`
  (read-only cross-check).
- `run: pi-run-notes.txt:<n>` = a finding from an earlier hardware run in this session (Raspberry Pi /
  WSL), file `scratchpad\pi-run-notes.txt`. **Nothing in this sheet was run by me.** Everything else
  is from reading the code.
- **IN FLUX** = depends on the project helpers, which other workflows are still changing.
- **UNVERIFIED** = read from the code or inferred, but not confirmed by a run (or not confirmable from
  the source).

Kismet facts are pinned to cfe427074 and do not move. Where a Kismet default looks odd, the sheet says
so in §17 "Quirks".

---

## 1. Binaries, version, install layout

- The server binary is **`kismet`** (`K/Makefile.in:284` `PS = kismet`). `kismet_server` is a shell alias
  that prints "kismet_server is now named just kismet, you may wish to update any scripts still using
  kismet_server to launch.", sleeps 1 s and runs `kismet` (`K/kismet_server:1-8`).
- `kismet --version` / `-v` prints `Kismet <MAJOR>.<MINOR>.<TINY>-<gitrev>` and **exits with status 1**
  (`K/kismet_server.cc:567-569`). `-h`/`--help` also exits 1 (`K/kismet_server.cc:570-572`).
- For a git build, the version is **made from the build date**: MAJOR = year, MINOR = month, TINY = `0`,
  gitrev = `git rev-parse --short HEAD` (`K/tools/mkversion.sh:3-19`). So a tree at cfe427074 built in
  September 2026 reports `Kismet 2026.09.0-cfe4270` (UNVERIFIED exact output, from the script). Without
  git: gitrev `non-git-release`.
- Capture helpers are named `kismet_cap_*` (`K/Makefile.in:83`, `88`...); ours is `kismet_cap_esp32c5`
  (`P/kismet/datasource_esp32c5.h:55`).
- Compile-time paths (autoconf defaults; `--prefix` default `/usr/local`):

  | Macro / expansion | From | Default (`--prefix=/usr/local`) | Pi run (`--prefix=$HOME/kismet-install`) | Docker (`--prefix=/usr --sysconfdir=/etc/kismet`) |
  |---|---|---|---|---|
  | `SYSCONF_LOC`, `%E` | `sysconfdir` (`K/configure.ac:241-247`) | `/usr/local/etc` | `~/kismet-install/etc` | `/etc/kismet` |
  | `BIN_LOC`, `%B` | `bindir` (`K/configure.ac:259-265`) | `/usr/local/bin` | `~/kismet-install/bin` | `/usr/bin` |
  | `DATA_LOC`, `%S` | `datarootdir` (`K/configure.ac:277-283`) | `/usr/local/share` | `~/kismet-install/share` | `/usr/share` |

  The web UI files go to `<datarootdir>/kismet/httpd/` (`K/Makefile.inc.in:79`, `K/conf/kismet_httpd.conf:52`).
  Pi/Docker prefixes are from `c-helper-build.md` §9.3 and `docker.md` §3.
- Install targets (`K/Makefile.in`):
  - `make install` = `commoninstall` + `configsinstall` (`:751-777`). Prints "Kismet has NOT been installed
    suid-root. This means you will need to start it as root..." (`:763-772`).
  - `make suidinstall` = `groupadd -r -f kismet` + `commoninstall` + `binsuidinstall` + `configsinstall`
    (`:721-749`). `binsuidinstall` installs the privileged helpers as **owner root, group `kismet`, mode
    4550** (`:461-549`).
  - `configsinstall` **never replaces an existing config file**: it prints
    "`<ETC>/<file> already exists; it will not be automatically replaced.`" (`:693-700`) and then a notice
    to run `make forceconfigs` (`:706-719`). `make forceconfigs` overwrites them all (`:702-704`, `:779-780`).
  - The config files installed: `kismet.conf kismet_httpd.conf kismet_alerts.conf kismet_memory.conf
    kismet_logging.conf kismet_filter.conf kismet_uav.conf kismet_80211.conf kismet_wardrive.conf`
    (`:3-12`). **`kismet_site.conf` is not installed**. The user creates it.
  - Plain `make install` still installs the `rz_killerbee` helper with `-g $(SUIDGROUP) -m 4550`
    (`:644-645`). That helper is built whenever libusb is found (`K/configure.ac:1875-1879`). So on a
    system **without a `kismet` group**, `make install` fails with `/usr/bin/install: invalid group 'kismet'`
    (run: pi-run-notes.txt:24, WSL). Fix: create the group, or
    `make install INSTGRP=root SUIDGROUP=root` (or your own user/group, as on the Pi, see `c-helper-build.md` §9.5).
  - The suid group defaults to `kismet` (`staff` on macOS) (`K/configure.ac:1884-1890`). Override with
    `./configure --with-suidgroup=<group>` (`K/configure.ac:1963-1970`).
- libwebsockets: `configure` requires `libwebsockets >= 3.1.0` unless `--disable-libwebsockets`
  (`K/configure.ac:1163-1186`). The error message wrongly says `--disable-websockets` (`:1176`). The flag
  only affects the **C capture helpers' websocket client**. The server always has websockets (`:1164`).
  A helper built without it can only use `--tcp` ("FATAL:  Must specify --tcp when not compiled with
  websockets support", `K/capture_framework.c:994-999`).

## 2. Config files, load order, syntax

### 2.1 Which file is read first
- Default: `<SYSCONF_LOC>/kismet.conf`. If the environment variable **`KISMET_CONF`** is set, the file is
  `$KISMET_CONF/kismet.conf` (a directory, not a file) (`K/kismet_server.cc:690-694`).
- `-f <file>` / `--config-file <file>` reads another main file (`K/kismet_server.cc:541`, `:573-574`).
- `--confdir <path>` changes what **`%E`** expands to (the includes and `kismet_site.conf`), but **not**
  where `kismet.conf` itself is read (that is still `SYSCONF_LOC` or `$KISMET_CONF`). To move everything, use
  `--confdir <dir> -f <dir>/kismet.conf` (`K/kismet_server.cc:586-587`, `:690-694`).
- `--datadir <path>` changes `%S`; `--homedir <path>` changes `%h` (see §3) (`K/kismet_server.cc:584-589`).
- `KISMET_ETC` is exported to child processes as the expanded `%E` (`K/kismet_server.cc:734-736`).

### 2.2 Load order (`K/configfile.cc:55-77`, `K/conf/kismet.conf:15-60`)
1. `kismet.conf` top to bottom. Each `include=` line is parsed **in place** ("Including sub-config file:
   <path>", `K/configfile.cc:141-151`). A missing `include=` file is fatal: Kismet logs
   "Error reading config file '<f>': <err>" and exits 1 (`K/configfile.cc:89-96`, `K/kismet_server.cc:718-720`).
   kismet.conf includes, in this order: `%E/kismet_httpd.conf`, `%E/kismet_memory.conf`,
   `%E/kismet_alerts.conf`, `%E/kismet_80211.conf`, `%E/kismet_logging.conf`, `%E/kismet_filter.conf`,
   `%E/kismet_uav.conf` (`K/conf/kismet.conf:42-60`).
2. After all of that, the `opt_override=` files, in the order they appeared: `%E/kismet_package.conf`, then
   **`%E/kismet_site.conf`** (`K/conf/kismet.conf:18`, `:28`; `K/configfile.cc:63-71`, `:156-158`). A
   missing one is fine: "Optional sub-config file not present: <path>" (`K/configfile.cc:203-207`).
   When present: "Loading config override file '<path>'" then "Loading optional sub-config file: <path>"
   (`K/configfile.cc:220`, `:191`).
3. Last, the `--override <flavor>` file: either a path, or `%E/kismet_<flavor>.conf`, e.g.
   `kismet --override wardrive` loads `kismet_wardrive.conf` (`K/kismet_server.cc:698-716`,
   `K/conf/kismet_wardrive.conf:3-6`). If not found: FATAL "Could not find override option '<x>' as a file
   or in the Kismet config directory as '<path>'." and exit 1.

Other directives: `opt_include=<glob>` includes files if they exist, merged like `include=` (not as an
override) (`K/configfile.cc:152-155`, `:172-213`).

### 2.3 How values combine (important for the docs)
- **In the base files (step 1), the first value of a key wins** for single-value options. `fetch_opt()`
  returns element `[0]` (`K/configfile.cc:276-291`). Example: `kismet_httpd.conf` (included at
  kismet.conf line 42) sets `httpd_port=2501`. A `httpd_port=2502` appended at the end of `kismet.conf` is
  stored second and **ignored**. **Tell users to put every change in `kismet_site.conf`**, as the stock
  files themselves say (`K/conf/kismet.conf:8-11`).
- **In an override file (`kismet_site.conf`, `--override`)**, a key given with `=` **replaces all earlier
  values** of that key. A key given **only** with `+=` lines is **appended** to the earlier values
  (`K/configfile.cc:229-247`). Consequences:
  - `source=` lines in `kismet_site.conf` replace any `source=` lines from the base files; use `source+=`
    to add.
  - `log_types=kismet,pcapng` replaces the default; `log_types+=pcapng` adds (the wardrive flavour uses
    `log_types+=wiglecsv`, `K/conf/kismet_wardrive.conf:23`).
  - `helper_binary_path=<dir>` in kismet_site.conf **drops** the default `%B`; use `helper_binary_path+=<dir>`.
- Multi-value keys (`source`, `log_types`, `helper_binary_path`, `mask_datasource_type`, `httpd_mime`,
  `kis_log_device_filter`...) collect every line (`K/configfile.cc:302-318`).

### 2.4 Syntax rules (`K/configfile.cc:101-165`, `K/util.cc:1145-1155`)
- `key=value`, one per line, maximum line length 8192. A line is a comment only if its first non-blank
  character is `#`. There are no inline comments: `a=b # c` keeps `b # c` as the value.
- Keys are case-insensitive (lower-cased on read, `:161`). Values keep case.
- `key=` with an empty value logs "Illegal config option in '<file>' line <n>: <line>" and is skipped
  (`:133-139`). A line without `=` is silently ignored.
- **Booleans accept only `true`, `t`, `false`, `f`** (any case). Anything else (`yes`, `1`, `on`) falls back
  to the option's default (`K/util.cc:1145-1155`).
- `%` expansions in paths (`K/configfile.cc:394-504`): `%h` home (§3), `%E` config dir, `%S` data dir,
  `%B` bin dir, `%p` log prefix + `/`, `%n` log title, `%D` date `YYYYMMDD`, `%d` date `Mmm-DD-YYYY`,
  `%t` time `HH-MM-SS`, `%T` `HHMMSS`, `%i` log number, `%I` log number zero-padded to 6, `%l` log type.
  **Dates and times are UTC** (`gmtime_r`, `:411-452`).

### 2.5 Command-line options (`K/kismet_server.cc:257-289` usage, `:432-439`, `:539-593`; `K/logtracker.cc:88-121`, `:373-379`; `K/datasourcetracker.cc:564-567`)

| Option | Effect |
|---|---|
| `-c <definition>` / `--capture-source <def>` | Add a source; repeatable. **Any `-c` makes Kismet ignore every `source=` in the config**: "Data sources passed on the command line (via -c source), ignoring source= definitions in the Kismet config file." (`K/datasourcetracker.cc:1104-1109`) |
| `-f`, `--config-file <file>` | Alternate main config file |
| `--override <flavor or file>` | Final override file (§2.2) |
| `--homedir <path>` | Use `<path>` for `%h` instead of the passwd home |
| `--confdir <path>`, `--datadir <path>` | Change `%E` / `%S` |
| `-n`, `--no-logging` | Disable all logs (alert LOGDISABLED, §11) |
| `-T`, `--log-types <a,b>` | Replace `log_types` |
| `-t`, `--log-title <title>` | Replace `log_title` (default `Kismet`) |
| `-p`, `--log-prefix <dir>` | Replace `log_prefix` |
| `-s`, `--silent` | No stdout after setup |
| `--daemonize` | Fork to the background; prints "Silencing output and entering daemon mode..." (`:595-605`) |
| `--no-ncurses-wrapper`, `--no-console-wrapper`, `--no-ncurses` | No banner / terminal margin (use for services, logs, Docker) |
| `--debug` | No console wrapper, no crash handler, SIGINT not masked |
| `--no-line-wrap` | Do not wrap console lines |
| `--no-plugins` | Skip plugins ("Plugins disabled on the command line, plugins will NOT be loaded...") |
| `--device-timeout=n` | **Listed in `--help` (`K/devicetracker.cc:1572`) but not parsed anywhere.** Use `tracker_device_timeout` (§17) |

With the console wrapper on, Kismet prints a banner line: "KISMET - Point your browser to
http://localhost:2501 (or the address of this system) for the Kismet UI" (`K/kismet_server.cc:752-761`).
On exit (not daemonized) it prints the "WARNING: Kismet changes the configuration of network devices..."
paragraph and "Kismet exiting." (`K/kismet_server.cc:224-235`). This is generic text, not about our boards.

## 3. Per-user state: `%h/.kismet/`

- **`%h` is the home directory from the passwd entry of the user running Kismet** (`getpwuid_r(getuid())`),
  **not `$HOME`**, unless `--homedir <path>` is given (`K/configfile.cc:459-482`). Confirmed at runtime:
  a test that set `HOME=` had its login ignored and Kismet read `/root/.kismet/kismet_httpd.conf`
  (run: pi-run-notes.txt:20). Under `sudo`, that is root's home (`/root`). Under systemd with `User=x`,
  it is x's home.
- `configdir=%h/.kismet/` (`K/conf/kismet.conf:243`). If missing, Kismet creates it (one level, mode 0700)
  with "Local config and cache directory '<dir>' does not exist; creating it." (`K/kismet_server.cc:738-744`).
  If it cannot: FATAL "Could not create config and cache directory '<dir>': <err>". If it exists but is
  not a directory: FATAL "... exists, but is a file (or otherwise not a directory)".
- Files in it:

  | File | Holds | Set by |
  |---|---|---|
  | `kismet_httpd.conf` | web admin login, **plain text**: `httpd_username=...` / `httpd_password=...` | `httpd_auth_file` (`K/conf/kismet_httpd.conf:66`); written by `set_admin_login` (`K/kis_net_beast_httpd.cc:556-571`) |
  | `session.db` | JSON array of API keys (`token`, `name`, `role`, `created`, `accessed`, `expires`) | `httpd_session_db` (`K/conf/kismet_httpd.conf:63`; `K/kis_net_beast_httpd.cc:917-948`, `:1832-1843`) |
  | `kismet_server_id.conf` | `server_uuid=<uuid>`, generated on first start | `K/kismet_server.cc:352-369` (message "Generated server UUID <u> and storing in <path>") |
  | `httpd/` | extra static web content (plugins) | `httpd_user_home` (`K/conf/kismet_httpd.conf:57`) |
  | `plugins/` | user plugins | `K/plugintracker.h:25` |

## 4. Web server (httpd)

- Port: **`httpd_port=2501`** (`K/conf/kismet_httpd.conf:23`; code default 2501, `K/kis_net_beast_httpd.cc:44-45`).
- Bind address: **`httpd_bind_address`**, default **`0.0.0.0` (all interfaces)** (commented example
  `127.0.0.1` at `K/conf/kismet_httpd.conf:75`; code default `K/kis_net_beast_httpd.cc:42-43`).
  A bad address is FATAL "Invalid bind address <a> for httpd server; expected interface address: <err>"
  (`:52-54`). A port in use is FATAL "Could not initialize HTTP server on <a>:<p>, could not bind socket -
  <err>" (`:433-439`). IPv6 addresses go through `make_address` and probably work (UNVERIFIED).
- Startup messages: "Starting Beast webserver on <addr>:<port>" (`:65`), "Serving static file content from
  <dir>" (`:229`), "Starting Kismet web server..." (`K/kismet_server.cc:1034`), "HTTP server listening on
  <addr>:<port>" (`K/kis_net_beast_httpd.cc:449`).
- Reverse proxy: `httpd_uri_prefix=/kismet` strips that prefix from every request, websockets included
  (`K/conf/kismet_httpd.conf:33-40`, `K/kis_net_beast_httpd.cc:234-235`, `:1141-1148`, `:1224`). CORS:
  `httpd_allow_cors`, `httpd_allowed_origin` (`K/conf/kismet_httpd.conf:42-48`).
- **No TLS in the server at this commit.** Nothing reads `httpd_ssl`/`httpd_ssl_cert`/`httpd_ssl_key`
  (grep finds them only in `K/README.SSL`, which is stale). The code has "TODO probably need to build SSL
  here?" (`K/kis_net_beast_httpd.cc:60`). For HTTPS/WSS, put a TLS reverse proxy in front. The C helpers
  support `--ssl` / `--ssl-certificate` for that case (§9.3).
- Request body limit is 100000 bytes (`K/kis_net_beast_httpd.cc:1209`). Each request has 30 s to complete
  (`:498-500`); streams and websockets clear that timeout.
- Unauthenticated route `/system/user_status.json` returns `kismet.system.user`, the user Kismet runs as
  (`K/system_monitor.cc:118`, `:266`). The UI uses it to say where the password file is.

## 5. Web login: first login, manual login, global login

### 5.1 First start
- No password yet means Kismet logs (INFO): **"This is the first time Kismet has been run as this user.  You
  will need to set an administrator username and password before you can use any features of Kismet.
  Visit http://localhost:2501/ to configure the initial login, or consult the Kismet documentation at
  https://www.kismetwireless.net/docs/readme/configuring/webserver/ about how to set a password
  manually."** (`K/kis_net_beast_httpd.cc:184-190`). The URL is fixed text: it says localhost:2501
  whatever the real address or port.
- The browser UI calls `GET /session/check_setup_ok` (no auth). The route returns 200 "Login configured in user
  config", 406 "Login configured in global config" or **500 "Login not configured"**
  (`K/kis_net_beast_httpd.cc:238-254`).
- On 500 the UI opens a modal titled **"Set Login"** with the text "To finish setting up Kismet, you need to
  configure a login." It then says the login will be stored in `.kismet/kismet_httpd.conf` in the home
  directory of the user who launched Kismet, "This server is running as <user>, and the login will be
  saved in `~<user>/.kismet/kismet_httpd.conf`". Fields: User name, Password, Confirm ("Passwords don't
  match" if they differ). Save posts `username`, `password` form fields to `POST /session/set_password`
  (`K/http_data/js/kismet.ui.base.js:3458-3647`, `:3661-3697`).
- **`/session/set_password` needs no authentication while no password is set**
  (`K/kis_net_beast_httpd.cc:272-310`). The first person to reach port 2501 chooses the admin login. With
  the default bind of `0.0.0.0`, that means anyone on the network. Docs should say: set the login
  immediately, pre-provision it (below), or bind to 127.0.0.1 until done. Once a password exists,
  changing it needs the current admin login (403 "Login is already configured; The existing login is
  required before it can be changed via this API."). Success logs "A new administrator login and password
  have been set." and returns "Login configured".
- Later visits: if the browser's stored login fails `GET /session/check_login`, the UI shows a
  **"Login Required"** modal (`K/http_data/js/kismet.ui.base.js:3661-3683`). The UI keeps the login in
  browser local storage (`kismet.base.login.username` / `.password`, `:3624-3625`). It can be changed under
  **Settings → Login & Password** (`K/http_data/js/kismet.ui.base.js:2349-2496`,
  `K/http_data/js/kismet.ui.settings.js:366-373`).

### 5.2 Setting the login without the browser
- Per user: create `%h/.kismet/kismet_httpd.conf` with two lines `httpd_username=<name>` and
  `httpd_password=<password>` (the same format Kismet writes, `K/kis_net_beast_httpd.cc:567-570`,
  `K/configfile.cc:256-274`). If only one of the two is present: ERROR "Found a partial configuration in
  <file>, resetting login information." (`:177-181`).
- Global: put `httpd_username=` **and** `httpd_password=` in `kismet_site.conf` (or any global file). The
  per-user file is then ignored, and an INFO alert GLOBALHTTPDUSER says so (`:146-167`). `/session/set_password`
  returns 403 "Login is configured in global Kismet configuration and may not be configured via this API."
  (`:280-285`). Only one of the two gives FATAL "Found a httpd_password in a global configuration file ...
  but did not find a httpd_username configuration option." (or the reverse) (`:147-158`).
- (Docker's entrypoint provisions the login its own way, see `docker.md` §8.)

## 6. Authentication and roles; API keys

### 6.1 Ways a request authenticates (`K/kis_net_beast_httpd.cc:1284-1352`)
Checked in this order:
1. **Cookie `KISMET=<token>`** (cookie name `K/kis_net_beast_httpd.cc:39`).
2. Only **if the request has no `Cookie` header at all**: query parameter **`?KISMET=<token>`**
   (`:1293-1297`). A client that sends any Cookie header (even an unrelated one) cannot use `?KISMET=`.
3. If the token is missing or invalid: **HTTP Basic** `Authorization: Basic base64(user:pass)` with the admin
   login gives the `admin` role (`:1306-1336`).
4. Only **if there is no Authorization header**: query parameters `?user=<u>&password=<p>` (`:1337-1350`).
- A successful Basic or user/password login gets a signed JWT, returned as `Set-Cookie: KISMET=<jwt>; Path=/`
  and valid 24 h (`:1332`, `:1348`; `K/kis_net_beast_httpd.h:359-362`). The JWT signing key is random at each
  start unless `httpd_jwt_key` (at least 8 characters) is set (`:194-208`). So these cookies do not survive a
  restart. API keys do.
- Failures: HTTP 401 with "This resource requires a login or session token." (`:1444`; websockets
  `:1378-1394`). Only `Wget` user agents also get `WWW-Authenticate: Basic realm=Kismet` (`:1433-1440`).

### 6.2 Roles (`K/kis_net_beast_httpd.cc:35-37`, `:1758-1783`)
- Built-in role strings: **`admin`** (can use every endpoint), **`readonly`** (endpoints that change
  nothing), `any` (endpoint-side only). Endpoints may name other roles. The UI lists **`datasource`**
  ("allows remote capture over websockets. This role only has access to the remote capture datasource
  endpoint."), `scanreport` and `ADSB` (`K/http_data/js/kismet.ui.base.js:2498-2521`).
- An `admin` token passes every role check (`:1779-1781`). So an admin login or admin API key also works
  for remote capture. A `readonly` key does not (the websocket needs `datasource`, §9).

### 6.3 API keys: REST
All three need the `admin` role (`K/kis_net_beast_httpd.cc:312-385`):
- **`POST /auth/apikey/generate.cmd`** with JSON fields **`name`** (string, must be unique, else
  "cannot create duplicate auth"), **`role`** (string) and **`duration`** (number, **required**; `0` = no
  expiry). The response body is the token: 32 lowercase hex characters (16 random bytes, `:802-809`).
  Disabled when `httpd_allow_auth_creation=false`: "auth creation is disabled in the kismet
  configuration" (`:317-318`). **Keys never expire in this commit**: the auth record constructor ignores the
  expiry and stores `expires=0` (`:1805-1812`). Treat `duration` as ignored (quirk, §17).
- **`GET /auth/apikey/list.json`** returns an array of `{kismet.httpd.auth.name, kismet.httpd.auth.role,
  kismet.httpd.auth.expiration, kismet.httpd.auth.token}`. The token field is left out when
  `httpd_allow_auth_view=false`. The internal "web logon" record is never listed (`:357-385`).
- **`POST /auth/apikey/revoke.cmd`** with JSON `{"name": "<name>"}` returns "revoked". Errors: "cannot
  delete unknown auth record", "cannot remove autoprovisioned web logon" (`:335-355`).
- Keys are saved to `httpd_session_db` = `%h/.kismet/session.db` (§3) at each change and loaded at start
  ("(HTTPD) Could not read session data file, skipping loading saved sessions." if absent, `:950-983`).
- How to send JSON to any `.cmd` endpoint (`K/kis_net_beast_httpd.cc:1497-1526`): either a form body
  `json=<url-encoded JSON>` with `Content-Type: application/x-www-form-urlencoded` (what the UI does, and
  what `curl -d` / `--data-urlencode` send), or the raw JSON with `Content-Type: application/json`
  (exactly that, or `application/json; charset=UTF-8`). **In the form body, `+` becomes a space**
  (`decode_uri(..., true)`, `:1505`). Use `--data-urlencode` for anything with `+`, `&` or `%`.
- Errors thrown by an endpoint come back as HTTP 500 with body `ERROR: <text>` (`:1546-1557`). A missing
  or wrongly typed JSON field gives a nlohmann message such as `[json.exception.type_error.302] type must
  be string, but is null` (UNVERIFIED exact text).
- Example (constructed from the code, not run; UNVERIFIED):
  ```sh
  curl -s -u admin:PASSWORD \
    --data-urlencode 'json={"name":"esp32c5-helper","role":"datasource","duration":0}' \
    http://KISMET_HOST:2501/auth/apikey/generate.cmd
  ```

### 6.4 API keys: web UI
**Settings → API Keys** (`K/http_data/js/kismet.ui.base.js:2602-2905`). The pane has a table (Name, Role,
token) and a **"Create API Key"** button. The form takes a Name and a Role select with **readonly**
(preselected), **datasource**, **scanreport**, **admin**, **ADSB** and *custom* (a free text field). A `?` icon
explains the roles. It calls `generate.cmd` with `duration: 0` (`:2839-2847`). Each row has a delete button,
"Delete role "<name>"", which calls `revoke.cmd` (`:2551-2590`). The error text is "Failed to add API key:
<text>" (`:2850`).

## 7. Sources (`source=`, `-c`, UI)

### 7.1 Syntax
- `source=<interface>:<opt>=<val>,<opt>=<val>,...` in a config file (usually `kismet_site.conf`, as
  `source=` or `source+=`), or `-c '<same>'` on the command line (`K/conf/kismet.conf:125-139`). Kismet has no
  sources by default. With none: "No data sources defined; Kismet will not capture anything until a
  source is added." (`K/datasourcetracker.cc:1111-1114`).
- Options are split on `,`. **A value that contains a comma must be double-quoted**: `channels="1,6,11"`
  (`K/util.cc:714-760`). Unquoted, `channels=1,6,11` means `channels=1` plus junk options `6` and `11`. On a
  shell, quote the whole thing: `-c 'esp32c5-ttyACM0:channels="1,6,11"'`.
- A `,` before the first `:` (or with no `:`) is rejected when Kismet has to probe the type: "Found a ','
  in the source definition '<def>'.  Sources should be defined as interface:option1,option2,... this is
  likely a typo in your 'source=' config or in your '-c' option on the command line."
  (`K/datasourcetracker.cc:158-167`).
- Option names are lower-cased by the datasource (`K/kis_datasource.cc:759`). The `type=` lookup in
  the tracker is **not** lower-cased (`K/datasourcetracker.cc:1322-1324`). Write option names in lower
  case.
- Kismet rebuilds the definition it stores and passes on (`kismet.datasource.definition`, and what the
  helper receives on open and on every retry) as `interface:key=value,...`, **keys lower-cased and sorted
  alphabetically (a `std::map`, `K/kis_datasource.h:524`), quotes removed** (`K/kis_datasource.cc:774`,
  `:835-857`, `:3675`). So a quoted value with commas (`channels="1,6,11"`) works for Kismet's own options,
  but reaches the helper unquoted.

### 7.2 `type=` versus probing
- **With `type=esp32c5`** Kismet goes straight to that driver (`K/datasourcetracker.cc:1334-1367`). If the
  type is unknown (Kismet built without `add-to-kismet.sh`): "Unable to find datasource for 'esp32c5'.
  Make sure that any required plugins are installed, that the capture interface is available, and that
  you installed all the Kismet helper packages." (`:1351-1354`).
- **Without `type=`**, Kismet logs "Probing interface '<if>' to find datasource type" and asks every
  probe-capable helper at once. Each probe times out after 2 s ("Datasource <def> cancelling source probe
  due to timeout", `:192-198`). Success: "Found type '<t>' for '<def>'" (`:1431`). Failure: ERROR
  **"Unable to find driver for '<def>'.  Make sure that any required plugins are loaded, the interface is
  available, and any required Kismet helper packages are installed."** (`:1420-1428`).
- **Retry differs.** A source opened with a known type is *always* kept and retried on failure
  (`K/datasourcetracker.cc:1465-1470`, "Always merge it so that it gets scheduled for re-opening"). A source
  whose probe found no driver is dropped and never retried. Run evidence: with two boards attached,
  `-c esp32c5` gave only "Unable to find driver" and no retry. `-c 'esp32c5:type=esp32c5'` showed the
  helper's real reason ("2 ESP32-C5 boards found; say which one with device= ...") and retried every 5 s
  (run: pi-run-notes.txt:10). **Docs should always use `type=esp32c5`** when the name alone might not
  resolve. (Which names the helper claims without `type=` is helper behaviour, IN FLUX, see
  `c-helper-build.md` §2.)
- `mask_datasource_type=<type>` hides a type from probing and listing but still allows `type=<type>`
  (`K/conf/kismet.conf:104-112`, `K/datasourcetracker.cc:370-374`, `:1380-1394`).
  `mask_datasource_interface=<name>` hides an interface from the list (`K/conf/kismet.conf:116-121`).
- Launch messages: "Data source '<def>' launched successfully" / "Data source '<def>' failed to launch:
  <reason>" (`K/datasourcetracker.cc:1126-1136`). More than `source_stagger_threshold=16` sources open in
  groups of `source_launch_group` (config 8, code default 10), `source_launch_delay=10` s apart
  (`K/conf/kismet.conf:172-179`, `K/datasourcetracker.cc:1117-1188`).

### 7.3 Generic options Kismet itself reads
Every other option is ignored by Kismet and passed to the helper inside the rebuilt definition of 7.1
(e.g. the project's `device=`, `mode=`). Kismet also passes the options below; the helper may read them too.
Source: `K/kis_datasource.cc:731-818`, `:1845-1914`; `K/datasourcetracker.cc:1322-1328`, `:1855-1857`, `:1890`.
This is the complete list for this commit (grep of every `get_definition_opt*` / `has_definition_opt` in the
generic code):

| Option | Meaning | Default |
|---|---|---|
| `type=<t>` | driver to use, skips probing | probe |
| `name=<text>` | display name (`kismet.datasource.name`) | the interface part |
| `uuid=<8-4-4-4-12 hex>` | fixed source UUID. Invalid: "Invalid UUID for data source <name>/<if>", open fails with "Malformed source config" (`K/kis_datasource.cc:253-261`, `:786-799`) | helper-reported, else time-based |
| `retry=true\|false` | re-open after an error (local sources only, §9.6) | `retry_on_source_error` (true) |
| `timestamp=true\|false` | for **remote** sources: replace packet time with Kismet's arrival time (`K/kis_datasource.cc:807-808`, `:2092-2093`) | `override_remote_timestamp` (true) |
| `channel=<ch>` | added to the source's channel list. **Does not stop hopping by itself** (see 8.1) | none |
| `channels="<a>,<b>,..."` | hop only these channels (they are also merged into the supported list) | helper's list |
| `add_channels="<a>,..."` | add channels to the helper's list (ignored if `channels=` is given) | none |
| `block_channels="<a>,..."` | remove channels from the helper's list (ignored if `channels=` is given) | none |
| `channel_hop=true\|false` | `false`: Kismet never sends a hop command to this source | true |
| `channel_hoprate=<n>/sec\|<n>/min\|<n>/dwell` | per-source hop rate, **but only honoured when this source is split with at least one other** (see 8.2) | `channel_hop_speed` |
| `metagps=<name>` | attach a named "meta" GPS to this source (`K/kis_datasource.cc:263-274`) | none |
| `info_antenna_type`, `info_antenna_gain`, `info_antenna_orientation`, `info_antenna_beamwidth`, `info_amp_type`, `info_amp_gain` | free-form notes shown as `kismet.datasource.info.*`; gains and angles are numbers (`K/kis_datasource.cc:810-815`, `:3576-3587`) | empty / 0 |

**Not Kismet options:** `channel_hopshuffle`, `channel_hopshuffle_skip`, `hop=`, `hop_rate=`,
`channel_hop_rate=`, `velocity=`, `dwell=`, `split=` appear nowhere in the code (grep over the tree). Shuffling is
global only (`randomized_hopping`). The shuffle skip is set by the helper (`cf_handler_set_hop_shuffle_spacing`;
ours sets 4, `P/kismet/capture_esp32c5/capture_esp32c5.c:1725-1727`, IN FLUX). The per-source hop-rate option is
spelled exactly **`channel_hoprate`**. The global one is **`channel_hop_speed`**.

### 7.4 Adding sources from the web UI
Sidebar **Data Sources** (`K/http_data/js/kismet.ui.datasources.js:519-526`) lists what the helpers report
(`GET /datasource/list_interfaces.json`, admin role, `:1657`). **"Enable Source"** posts
`add_source.cmd` with the definition **`<listed interface>:type=<type>`**, e.g.
`esp32c5-ttyACM0:type=esp32c5` (`:765-795`). Per-source buttons use `open_source.cmd`, `close_source.cmd`,
`disable_source.cmd` (`:1153`, `:1192`, `:1232`), and the channel buttons use `set_channel.cmd` (8.3).

## 8. Channel hopping and splitting

### 8.1 Global defaults (`K/conf/kismet.conf:143-164`, `K/datasourcetracker.cc:437-474`)

| Option | Stock value | Meaning / startup message |
|---|---|---|
| `channel_hop` | `true` | "Enabling channel hopping by default on sources which support channel control." |
| `channel_hop_speed` | `5/sec` | format `<n>/sec`, `<n>/min` or `<n>/dwell` (seconds per channel); "Setting default channel hop rate to 5/sec". Missing: "No channel_hop_speed= in kismet config, setting hop rate to 1/sec". Unparseable: FATAL "Could not parse channel_hop_speed= config: Expected [value]/sec or [value]/min or [value]/dwell" (`K/datasourcetracker.cc:1911-1942`). A bare number is not accepted |
| `split_source_hopping` | `true` | "Enabling channel list splitting on sources which share the same list of channels" |
| `randomized_hopping` | `true` | "Enabling channel list shuffling to optimize overlaps" |
| `retry_on_source_error` | `true` | "Sources will be re-opened if they encounter an error" |

When a source opens (or a remote one connects or reconnects), Kismet decides its hopping
(`K/datasourcetracker.cc:1889-1909`, called from `merge_source` `:1509` and remote reconnect `:1730`):
- `channel_hop=false` on the source: Kismet does nothing. The source stays where the helper put it.
- Otherwise, if `channel_hop` is on and the driver is tune- and hop-capable (the `esp32c5` builder is both,
  `P/kismet/datasource_esp32c5.h:98-104`), Kismet sends a hop command with its hop list.
- **So `channel=6` alone does not lock a source**: Kismet adds 6 to the list and then hops the whole list.
  To lock, use **`channel=6,channel_hop=false`**. The project helper documents the same thing ("channel= is where to
  start, and with channel_hop=false where to stay", `P/kismet/capture_esp32c5/capture_esp32c5.c:67-69`,
  `:345-348`). One earlier run found the C helper ignoring `channel=` with `channel_hop=false`
  (run: pi-run-notes.txt:6). **IN FLUX** until the C helper review lands.

### 8.2 Splitting across boards of one type (`K/datasourcetracker.cc:1778-1887`)
- The sources split together are **the same source type (`esp32c5`) AND the same channel list** (same
  number of channels, same members, any order), and running. All three of our radios are type `esp32c5`,
  but their channel lists differ. So Wi-Fi boards split among themselves, 802.15.4 boards among themselves,
  and BTLE boards among themselves. A Wi-Fi board and a Zigbee board are never split together.
- Splitting does **not** give each board a subset. Every board hops the **whole** list, and each starts at a
  different offset: offset = (hop list size / number of sources) × index. The config comment says "hop from
  different starting positions" (`K/conf/kismet.conf:152-155`). Kismet logs "Splitting channels for
  interfaces using 'esp32c5' among <n> interfaces" (`:1842-1843`).
- In `capture_framework` helpers (our C helper) the offset is only honoured on the first pass. On wrap the
  loop restarts at `(++hoppos_start % spacing)`, which drops the offset (`K/capture_framework.c:1540-1543`).
  Run evidence: two Wi-Fi boards with 42 channels got offsets 21 and 0, and in steady state they were only
  5 positions apart, yet still never on the same channel at once (run: pi-run-notes.txt:14). Upstream behaviour.
- The shuffle flag used for split sources is the global `randomized_hopping`. It cannot be set per source.
- **`channel_hoprate` is only read inside the split branch with 2 or more matching sources** (`:1853-1867`).
  A lone source, or any source with `split_source_hopping=false`, hops at the global `channel_hop_speed`
  (`:1833-1839`, `:1902-1906`). Bad values: "Source '<name>' could not parse channel_hoprate= option: <err>,
  using default channel rate." (UNVERIFIED by run. It follows directly from the code.) To change one source's
  rate at runtime, use `set_channel.cmd` with `rate` (8.3).
- Hop timing in `capture_framework` helpers: dwell = 1/rate, **never below 50 ms** (at most 20 hops/s)
  (`K/capture_framework.c:1478-1486`). A channel the helper fails to tune is dropped from the hop list after
  one pass. If all fail: "All configured channels are in error state!" (`:1502-1560`).
- Whether the Python helper mirrors the offset, shuffle and 50 ms floor is **IN FLUX** (see `python-helper.md`).

### 8.3 Changing channels at runtime (REST)
See §10: `set_channel.cmd` (`channel` locks, and a capture_framework helper then cancels its hop thread,
`K/capture_framework.c:1952-1956`; `channels` / `rate` / `shuffle` set hopping) and `set_hop.cmd` (resume
hopping on the stored list and rate). The UI's per-source channel buttons send
`{"cmd":"hop","channels":[...],"uuid":...}` to `set_channel.cmd` (`K/http_data/js/kismet.ui.datasources.js:947-956`).

## 9. Remote capture

Two transports exist. The modern one is a websocket on the web server. The legacy one is a raw TCP port.

### 9.1 Websocket (modern; the default for `capture_framework` helpers)
- Endpoint: **`ws://<host>:<httpd_port>/datasource/remote/remotesource.ws`**, i.e. port **2501** by default,
  on `httpd_bind_address` (all interfaces by default) (`K/datasourcetracker.cc:988`,
  `K/capture_framework.c:1091-1092`). The `.ws` suffix is part of the route (`{"ws"}` extension).
  Behind `httpd_uri_prefix`, helpers use `--endpoint=/prefix/datasource/remote/remotesource.ws`
  (`K/capture_framework.c:1168-1175`).
- **Authentication is required.** Every websocket route needs a login, and this one needs role
  **`datasource`** (or `admin`) (`K/kis_net_beast_httpd.cc:1354-1394`, `K/datasourcetracker.cc:988`). A
  failure is HTTP 401 at the upgrade. The C framework sends credentials in the URL: API key as
  `?KISMET=<key>`, or login as `?user=<u>&password=<p>` (`K/capture_framework.c:1096-1102`). The recommended
  credential is an API key with role `datasource` ("A Kismet API key for the 'datasource' role",
  `:1164-1167`). The user/password form puts the admin password in the URL, where proxies may log it.
- A client that also sends a `Cookie` header cannot use `?KISMET=` (§6.1).
- Not governed by `remote_capture_enabled` / `remote_capture_listen` / `remote_capture_port`. Those settings
  are for the TCP listener only. The websocket is on whenever the web server is (code reading;
  `K/datasourcetracker.cc:476-500` vs `:988`).

### 9.2 Legacy TCP
- `remote_capture_enabled=true`, **`remote_capture_listen=127.0.0.1`**, **`remote_capture_port=3501`**
  (`K/conf/kismet.conf:84-93`). Loopback only by default. `*` or `0.0.0.0` means all IPv4 interfaces
  (`K/datasourcetracker.cc:577-580`). Message: "Launching remote capture server on <listen> <port>" (`:574`).
  Errors: FATAL "Failed to create IPV4 remote capture server; check your remote_capture_listen= and
  remote_capture_port= configuration: <err>" (`:588-592`). Missing values: "No remote_capture_listen=
  found in kismet.conf; no remote capture will be enabled." / "No remote_capture_port= line in
  kismet.conf; ..." (`:483-491`).
- **No authentication at all** on this port (`K/datasourcetracker.cc:2115-2126`). The stock config's advice:
  keep it on loopback and use an SSH tunnel (`K/conf/kismet.conf:84-89`). Helpers use it with
  `--tcp --connect <host>:3501`.
- Measured latency (C helper, Pi): over the websocket, 2.96 to 3.63 s from connect to "capturing", then bursty
  delivery (0 → 24 → 461 packets at +3.5 s, +6 s). Over `--tcp` to localhost:3501, 0.51 s and packets
  from +0.9 s. The Python websocket helper took 0.35 s (run: pi-run-notes.txt:12). The suspected cause is in
  upstream `capture_framework.c` (libwebsockets write wake-up), not verified.
- `remote_capture_allow_http_auth=false` (default) stops a remote helper from asking Kismet for a web auth
  token: "Remotely connected handler from <ip> requested a web auth token, which is blocked by the current
  Kismet config" (`K/conf/kismet.conf:95-101`, `K/kis_external.cc:588-593`, `:1491-1503`). Capture helpers do
  not need it.

### 9.3 `capture_framework` helper command line (Kismet-standard; what `kismet_cap_esp32c5 --help` inherits)
From `K/capture_framework.c:838-857`, `:870-1134`, help text `:1136-1194`:
- `--connect <host>:<port>` (port required: "FATAL: Expected host:port for --connect"), `--tcp`, `--ssl`,
  `--ssl-certificate <ca file>`, `--user <u>`, `--password <p>`, `--apikey <key>`, `--endpoint <path>`,
  `--source <definition>` (**required** with `--connect`: "FATAL: --source option required when connecting
  to a remote host"), `--disable-retry` (default: reconnect forever), `--fixed-gps lat,lon[,alt]`,
  `--gps-name <name>`, `--daemonize`, `--list`, `--autodetect[=<server uuid>]`, `--version`, `--help`.
- Websocket mode with no credentials: "FATAL: User and password or API key required for remote capture".
  Both user and key given: "WARNING: Ignoring APIKEY and using login information". `--connect x:3501` without `--tcp`:
  "WARNING: It looks like you're using a legacy TCP remote capture port, but did not specify '--tcp'; this
  probably is not what you want!" (`:1002-1005`, `:1082-1089`).
- `--version` of a helper prints `<MAJOR>.<MINOR>.<TINY>-<gitrev>` and exits 0 (`:876-878`).
- The project's C helper adds environment variables `KISMET_CAP_APIKEY`, `KISMET_CAP_USER`,
  `KISMET_CAP_PASSWORD`, so secrets stay out of the process list (`P/kismet/capture_esp32c5/capture_esp32c5.c:96-102`).
  **IN FLUX**, see `c-helper-build.md` §6. The Python helper's options are its own (`python-helper.md`, IN FLUX).

### 9.4 Discovery (`--autodetect`)
- `server_announce=false` (default), `server_announce_address=0.0.0.0`, `server_announce_port=2501`
  (`K/conf/kismet.conf:74-79`). When on, Kismet broadcasts a UDP announcement every 5 s. It carries the web
  port and the **legacy TCP remote port** (`K/kis_server_announce.cc:50-56`, `:102-118`). Helpers with
  `--autodetect` listen on UDP 2501 and connect to the announced remote port (`K/capture_framework.c:5143-5215`).
  So autodetect points at 3501, which is loopback-only by default and would need `--tcp` (UNVERIFIED by run).
  `kismet_discovery` (installed tool, `K/tools/kismet_discovery.cc`) prints the announcements it hears.

### 9.5 What Kismet does with a remote source (`K/datasourcetracker.cc:1675-1776`, `K/kis_datasource.cc:461-556`)
- The helper must announce its source within 5 s of connecting, else "Incoming connection on remote
  capture socket, but remote side did not initiate a datasource connection." (`K/datasourcetracker.cc:1946-1959`).
- Sources are matched by **UUID**. New: "New remote source <name> (<uuid>) connected". Known and closed:
  "Matching new remote source '<def>' with known source with UUID '<uuid>'" then "Remote source <name>
  (<uuid>) reconnected". Known and still running: ERROR "... matches existing source '<name>', which is still
  running.  The running instance will be closed; ..." and the old one is replaced. Same UUID but a
  different type: rejected ("mismatch device type for this uuid"). No driver for the type: "Kismet could
  not find a datasource driver for incoming remote source '<type>' defined as '<def>'; make sure that
  Kismet was compiled with all the data source drivers ..." (`:1770-1773`). A Kismet without the `esp32c5`
  builder cannot accept our remote sources.
- Kismet pings every 5 s. **No reply for more than 15 s** is an error: "did not get a ping response from the
  capture" (`K/kis_datasource.cc:520-536`).
- **Kismet never re-opens a remote source.** `retry` is forced off (`:473`), and on error the SOURCEERROR
  alert says "Source <name> (<uuid>) has encountered an error (<reason>).  Remote sources are not locally
  reconnected; waiting for the remote source to reconnect to resume capture." (`:3606-3623`). Reconnecting
  is the helper's job (C framework default: retry forever unless `--disable-retry`).
- Remote packets get Kismet's arrival time unless `override_remote_timestamp=false` or the source option
  `timestamp=false` (`K/conf/kismet.conf:181-184`). Messages a remote helper sends are prefixed with the
  source name (`K/kis_datasource.cc:952-957`).
- Splitting and hopping (§8) apply to remote sources the same way.

### 9.6 Local source errors and retry (`K/kis_datasource.cc:599-622`, `:3594-3712`)
- An error logs "Data source '<name> / <definition>' ('<interface>') encountered an error: <reason>". With
  retry on, alert SOURCEERROR: "Source <name> (<uuid>) has encountered an error (<reason>) Kismet will
  attempt to re-open the source in 5 seconds.  (<n> failures)". Then "Attempting to re-open source <name>", and
  on success the alert SOURCEOPEN "Source <name> (<uuid>) successfully re-opened". The re-open restores
  the previous hopping or fixed channel. With `retry=false`: "... but is not configured to automatically
  re-try opening; it will remain closed."
- Helper missing from `helper_binary_path` (default `%B` only, `K/conf/kismet.conf:63-69`): open fails with
  "Capture tool not installed" (`K/kis_datasource.cc:311-318`) / "Kismet external interface can not find
  IPC binary for launch: kismet_cap_esp32c5" (`K/kis_external.cc:756-759`).
- Kismet starts a local helper as `<helper_binary_path>/<binary> --in-fd=<n> --out-fd=<m>`
  (`K/kis_external.cc:837-860`).

## 10. REST calls for sources

Routes `K/datasourcetracker.cc:598-986`. `RO` = readonly or admin; `admin` = admin only. Endpoints
registered without an extension list accept any serializer suffix (`.json`, `.prettyjson`, `.ekjson`,
`.itjson`) (`K/kis_net_beast_httpd.cc:1694-1698`, `K/kismet_server.cc:800-807`). `.cmd` endpoints need `.cmd`.

| Call | Role | Body / notes |
|---|---|---|
| `GET /datasource/all_sources.json` | RO | array of sources |
| `GET /datasource/by-uuid/<uuid>/source.json` | RO | one source; "invalid uuid", "no such datasource" |
| `GET /datasource/defaults.json`, `/datasource/types.json` | RO | hop defaults; registered drivers (ours: type `esp32c5`, description "ESP32-C5 sniffer board: Wi-Fi (2.4/5 GHz), 802.15.4, or BTLE advertising", `P/kismet/datasource_esp32c5.h:95-96`) |
| `GET /datasource/list_interfaces.json` | admin | what helpers can see |
| `POST /datasource/add_source.cmd` | admin | `{"definition": "<source definition>"}`. Returns the source; on failure HTTP 500 and `{}` |
| `POST /datasource/by-uuid/<uuid>/set_channel.cmd` | admin | either `{"channel": "<ch>"}` (a **string**, e.g. `"6"`), which locks the channel; or `{"channels": ["1","6","11"], "rate": 5, "shuffle": 1}` to hop (`channels` array of strings; `rate` number of hops/s; `shuffle` 0/1 number; missing fields keep current values). Neither: "channel control API requires either 'channel' or 'channels' and 'rate'". Failure: HTTP 500 `{}` and "Source '<n>' (<uuid>) failed to set channel <ch>" (`:680-768`) |
| `GET\|POST /datasource/by-uuid/<uuid>/set_hop.cmd` | admin | resume hopping on the stored list/rate/shuffle/offset; logs "Source '<n>' (<uuid>) enabling channel hop on existing channel list" (`:770-808`) |
| `.../close_source.cmd`, `.../disable_source.cmd` | admin | both close and disable retry (error_reason "Source disabled") (`:810-844`, `K/kis_datasource.cc:558-573`) |
| `.../open_source.cmd` | admin | re-open a closed source; "source already running" (`:846-882`) |
| `.../pause_source.cmd`, `.../resume_source.cmd` | admin | stop/start processing packets without closing ("Source already paused" / "Source already running") |
| `GET /pcap/all_packets.pcapng` | RO | live pcapng stream of all packets from now on; filename `kismet-all-packets.pcapng` (`:929-952`) |
| `GET /datasource/pcap/by-uuid/<uuid>/packets.pcapng` | RO | live stream of one source (`:954-986`) |
| `GET /packetchain/packet_stats.json` (also `packet_dupe`, `packet_rate`, `packet_drop`, `packet_error`, `packet_processed`, `packet_peak`) | RO | packet-chain RRDs, incl. `dupe_packets_rrd` (`K/packetchain.cc:153-166`) |
| `GET /phy/all_phys.json`, `/devices/views/all_views.json`, `/messagebus/last-time/<ts>/messages.json`, `/alerts/all_alerts.json`, `/system/status.json` | RO | (`K/devicetracker.cc`, `K/messagebus_restclient.cc`, `K/alertracker.cc`, `K/system_monitor.cc`) |

Useful fields in a source record (`K/kis_datasource.cc:3489-3591`): `kismet.datasource.name`, `.uuid`,
`.definition`, `.interface`, `.capture_interface`, `.hardware`, `.dlt`, `.channels`, `.hopping`, `.channel`,
`.hop_rate`, `.hop_channels`, `.hop_offset`, `.hop_shuffle`, `.hop_shuffle_skip`, `.running`, `.paused`,
`.error`, `.error_reason`, `.warning`, `.num_packets`, `.num_error_packets`, `.remote`, `.remote_ip`,
`.retry`, `.retry_attempts`, `.total_retry_attempts`, `.ipc_binary`, `.ipc_pid`, `.source_number`,
`.datasource_version`, `.info.antenna_type` ...

Examples (constructed from the code, not run; UNVERIFIED):
```sh
K=http://KISMET_HOST:2501
curl -s -u admin:PASSWORD $K/datasource/all_sources.json
curl -s -b "KISMET=APIKEY" $K/datasource/all_sources.json          # readonly key is enough
curl -s -u admin:PASSWORD --data-urlencode 'json={"definition":"esp32c5-ttyACM0:type=esp32c5,name=c5-wifi"}' \
     $K/datasource/add_source.cmd
curl -s -u admin:PASSWORD --data-urlencode 'json={"channel":"36"}' $K/datasource/by-uuid/UUID/set_channel.cmd
curl -s -u admin:PASSWORD --data-urlencode 'json={"channels":["1","6","11"],"rate":2}' \
     $K/datasource/by-uuid/UUID/set_channel.cmd
curl -s -u admin:PASSWORD $K/datasource/by-uuid/UUID/set_hop.cmd
```
Run evidence that `set_channel.cmd {"channel":"20"}` works on our source: pi-run-notes.txt:6.

## 11. Logging

### 11.1 Options (`K/conf/kismet_logging.conf`, `K/logtracker.cc:83-260`)
| Option | Stock value | Notes |
|---|---|---|
| `enable_logging` | `true` | `-n`/`--no-logging` overrides. Disabled: alert LOGDISABLED "Logging has been disabled via the Kismet config files or the command line.  Pcap, database, and related logs will not be saved." and "Logging disabled, not enabling any log drivers." (`K/logtracker.cc:241-251`) |
| `log_title` | `Kismet` | `-t` |
| `log_prefix` | `./` | `-p`. **The current directory Kismet was started in**. The directory must already exist. Kismet will not create it (`K/conf/kismet_logging.conf:27-31`) |
| `log_template` | `%p/%n-%D-%t-%i.%l` | → `<prefix>/Kismet-20260928-14-03-22-1.kismet` (date/time **UTC**, `%i` = first free number from 1, `K/logtracker.cc:338-340`, `K/configfile.cc:506-538`) |
| `log_types` | `kismet` | comma list, multi-line; `-T`. Types: `kismet` (kismetdb, one per run), `pcapng`, `pcapppi` (legacy PPI pcap), `wiglecsv`, `pcapng_ring` (`K/kis_databaselogfile.h:271-274`, `K/kis_pcapnglogfile.h:136-139`, `K/kis_ppilogfile.h:136`, `K/kis_wiglecsvlogfile.h:89`, `K/kis_pcapng_ring_logfile.h:190`) |

The file extension is the type name: `.kismet`, `.pcapng`, `.pcapppi`, `.wiglecsv`.

kismetdb (`kismet`) options: `kis_log_devices` (true, every `kis_log_device_rate`=30 s), `kis_log_packets`
(true), `kis_log_duplicate_packets` (true), `kis_log_data_packets` (true), `kis_log_messages` (true),
`kis_log_alerts` (true), `kis_log_datasources` (true; the code reads `kis_log_datasource_rate`, default
30), `kis_log_gps_track`, `kis_log_system_status` (+`_rate` 30), and the `kis_log_*_timeout` pruning options and
`kis_log_ephemeral_dangerous` (`K/conf/kismet_logging.conf:73-159`; code `K/kis_databaselogfile.cc:126-240`,
`K/devicetracker.cc:199-201`, `K/datasourcetracker.cc:510-512`, `K/system_monitor.cc:138-140`).
- Messages: "Opened kismetdb log file '<path>'", "Saving packets to the Kismet database log."
  (`K/kis_databaselogfile.cc:124`, `:402`).
- **If the kismetdb cannot be created (e.g. log_prefix not writable, or not existing) Kismet stops**: FATAL
  "Unable to open KismetDB log at '<path>'; check that the directory exists and that you have write
  permissions to it." (`K/kis_databaselogfile.cc:85-88`).
- The kismetdb is SQLite. It commits **every 10 s** (`:101-118`), and while open a `<file>-journal`
  sits next to it (journal mode PERSIST, `:99`). On clean close the mode becomes DELETE (`:456`), which removes
  the journal. After a crash or power loss, the last up to 10 s may be lost and the journal stays; clean it with
  `kismetdb_clean` (§12).

pcapng options (code `K/kis_pcapnglogfile.cc:31-40`): `pcapng_log_duplicate_packets` (true),
`pcapng_truncate_duplicate_packets` (false), `pcapng_log_data_packets` (true), `pcapng_log_max_mb` (0 =
unlimited; above it: "Rotating to new pcapng log <path>"). "Opened pcapng log file '<path>'" (`:91`). The
pcapng log holds every source, each as its own interface with its own link type (radiotap for Wi-Fi, and the
802.15.4 / BTLE link types, §16). Wireshark reads it directly.

Log filters (`K/conf/kismet_filter.conf:58-110`, `K/kis_databaselogfile.cc:276-355`):
`kis_log_device_filter_default=pass|block`, `kis_log_device_filter=<phyname>,<mac or mac/mask or *>,<pass|block>`,
`kis_log_packet_filter_default`, `kis_log_packet_filter=<phyname>,<source|destination|network|other|any>,<mac>,<pass|block>`.
The phy names are those of §16.

### 11.2 Runtime and REST
- `GET /logging/active.json`, `GET /logging/drivers.json` (RO); `/logging/by-class/<type>/start.cmd`,
  `/logging/by-uuid/<uuid>/stop.cmd` (admin) (`K/logtracker.cc:179-239`).
- `GET /logging/kismetdb/pcap/<title>.pcapng` (RO) exports packets from the open kismetdb, with optional
  query filters `timestamp_start`, `timestamp_end`, `datasource`, `dlt`, `frequency`, `frequency_min`,
  `frequency_max`, `signal_min`, `signal_max`, `tag`, `limit` ... (`K/kis_databaselogfile.cc:262`, `:1423-1510`).
  (Exact filter semantics UNVERIFIED.)

## 12. kismetdb tools (installed into `bindir`; `K/Makefile.in:180-228`, `:562-569`)

Exact binary names: **`kismetdb_to_pcap`**, **`kismetdb_strip_packets`** (source file is
`kismetdb_strip_packet_content.c`), **`kismetdb_dump_devices`**, **`kismetdb_to_wiglecsv`**,
**`kismetdb_statistics`**, **`kismetdb_to_kml`**, **`kismetdb_to_gpx`**, **`kismetdb_clean`**. There is
also `kismet_discovery` (§9.4). `log_tools/elk/kismet_log_to_elk.py` is in the source but not installed.

**Most tools VACUUM the input database first, i.e. they write to it**, unless given `-s`/`--skip-clean`
(e.g. `K/log_tools/kismetdb_to_pcap.cc:887-907`). Running them on the log of a Kismet that is still
running is not advised. Copy the file or stop Kismet first (UNVERIFIED what happens on a live file).

| Tool | Usage (from each `print_help`) |
|---|---|
| `kismetdb_to_pcap` | `-i/--in <kismetdb> -o/--out <file>` `[-f/--force] [-v] [-s/--skip-clean]` `[--old-pcap] [--dlt <n>]` `[--list-datasources] [--datasource <uuid>]...` `[--split-datasource] [--split-packets <n>] [--split-size <kb>]` `[--list-tags] [--tag <t>]...` `[--skip-gps] [--skip-gps-track]`. Default output is **pcapng** (many link types in one file). `--old-pcap` needs one link type per file: with several, "ERROR:  Datasource ... has multiple link types; when ..." unless `--dlt` (`K/log_tools/kismetdb_to_pcap.cc:684-727`, `:1068-1078`). Split names: `<out>-<uuid>`, `<out>-0001`, `<out>-<uuid>-0001` |
| `kismetdb_strip_packets` | `-i <kismetdb> -o <new kismetdb> [-v] [-f]`: copy without packet contents (`K/log_tools/kismetdb_strip_packet_content.c` print_help) |
| `kismetdb_dump_devices` | `-i <kismetdb> -o <json> [-f] [-j/--json-path] [-e/--ekjson] [-v] [-s]` (`-j` renames `.` to `_` in field names; `-e` one device per line) |
| `kismetdb_to_wiglecsv` | `-i <kismetdb> -o <csv> [-f] [-r/--rate-limit <s>] [-c/--cache-limit <n>, default 1000] [-v] [-s] [-e/--exclude lat,lon,dist_m]` (an undocumented `--filter` option also exists) |
| `kismetdb_statistics` | `-i <kismetdb> [-s] [-j/--json]` |
| `kismetdb_to_kml` | `-i -o [-f] [-v] [-s] [-e lat,lon,dist] [--basic-location] [-g/--group]` |
| `kismetdb_to_gpx` | `-i -o [-f] [-v] [-s] [-e lat,lon,dist] [--basic-location]` |
| `kismetdb_clean` | `-i <kismetdb>`: "Performs a basic cleanup of Kismetdb logs with an incomplete journal file" |

Example: `kismetdb_to_pcap -i Kismet-20260928-14-03-22-1.kismet -o capture.pcapng` (UNVERIFIED by run).

## 13. systemd, udev, packaging (`K/packaging/`)

- `K/packaging/README`: distro packaging lives in the separate repo `github.com/kismetwireless/kismet-packages`.
- `K/packaging/systemd/kismet.service.in` becomes `packaging/systemd/kismet.service` at `configure` time
  (`K/configure.ac:2060-2065`). **`make install` does not install it** (no rule in `K/Makefile.in`). Copy it by hand
  (`K/packaging/systemd/README:11-13`: `sudo cp kismet.service /lib/systemd/system/`). Content:
  ```ini
  [Unit]
  Description=Kismet
  ConditionPathExists=@prefix@/bin/kismet
  After=network.target auditd.service

  [Service]
  User=root
  Group=root
  Type=simple
  ExecStart=@prefix@/bin/kismet --no-ncurses-wrapper
  KillMode=process
  TimeoutSec=0
  Restart=always

  [Install]
  WantedBy=multi-user.target
  ```
  The README recommends `make suidinstall`, then `sudo systemctl edit kismet` with `[Service]` `User=kismet`
  / `Group=kismet` (or your own user), then `sudo systemctl enable kismet` and `sudo service kismet start`
  (`K/packaging/systemd/README:15-49`).
- **The unit sets no `WorkingDirectory`, so with the stock `log_prefix=./`** logs go to the service's working
  directory. systemd's documented default for system services is `/` (external fact, UNVERIFIED here). As a
  non-root `User=`, the kismetdb cannot be created there, and Kismet exits with the FATAL in §11.1. Tell users
  to set `log_prefix=<existing, writable dir>` in `kismet_site.conf` (the Docker image does: `log_prefix=/data/`,
  `docker.md` §10). Also: `%h` is that user's passwd home (§3), which is where the login and API keys live.
- Debug variant: `K/packaging/systemd/debug/kismet-debug.service.in` + `kismet_debug` (gdb wrapper, logs to
  `/var/log/kismet/`).
- `K/packaging/udev/*.rules` cover other sniffers (TI CC2531/2540, nRF, NXP, Radiacode, WCH, u-blox GPS);
  **none for 303a:1001** (ESP32-C5). Whether the project ships a rule is an open question.

## 14. Running as a user vs root

- Running as root works, but Kismet raises alert **ROOTUSER** (high): "Kismet is running as root; this is less
  secure than running Kismet as an unprivileged user and installing it as suidroot. ... If you're starting
  Kismet on boot via systemd, be sure to use 'systemctl edit kismet.service' to configure the user."
  (`K/kismet_server.cc:1017-1032`).
- Kismet's model: the server runs unprivileged; only capture helpers that must change interfaces are
  installed **suid root, group `kismet`, mode 4550**, so only members of `kismet` can run them
  (`K/Makefile.in:461-549`, `:736-744`: "Kismet has been installed with a SUID ROOT CAPTURE HELPER executable by
  users in the group 'kismet'. ... If you have just created this group, you will need to log out and back
  in"). Add a user with `sudo usermod -aG kismet <user>` (standard Linux command, not in the Kismet source).
- If a helper is not world-executable and the user is not its owner or in its group, the open fails with
  "IPC cannot run binary '<path>', Kismet was installed setgid and you are not in that group. If you
  recently added your user to the kismet group, you will need to log out and back in to activate it.  You
  can check your groups with the 'groups' command." (`K/kis_external.cc:762-796`).
- Our helper needs only a serial port, no interface control. `add-to-kismet.sh` puts its install lines next
  to the CatSniffer helper's in both install blocks (`P/kismet/add-to-kismet.sh:103-106`). With `make suidinstall`
  it would therefore be installed 4550 root:kismet like CatSniffer (`K/Makefile.in:541`). With `make install`
  it is a normal executable that runs as the Kismet user, who then needs read/write access to
  `/dev/ttyACM*` (on Debian/Ubuntu/Raspberry Pi OS usually the `dialout` group; an OS fact, not from Kismet).
  UNVERIFIED which of these the docs should recommend (open question). See `c-helper-build.md` §7.

## 15. Packet de-duplication (why BTLE device counts look low)

- Every packet with link data gets a **CRC32 of its link frame** (after the link header is removed, if Kismet
  has a decoder for it). If that CRC matches one of the **last 1024 unique packets** (from any source, any
  phy), the packet is marked **duplicate** (`K/packetchain.cc:379-430`, ring size `K/packetchain.h:287`).
  The `packet_dedup_size=2048` line in `kismet_memory.conf` is **not read by the code** (§17).
- Which bytes are hashed:
  - Wi-Fi radiotap: the 802.11 frame without the radiotap header (radiotap DLT handler).
  - BTLE with the radio pseudo-header (DLT 256): the 10-byte header (channel, signal, flags) is stripped.
    The hash covers access address + PDU + CRC (`K/kis_dlt_btle_radio.cc:41-124`). **An advertiser repeating
    the same advertisement (same address, same data) on 37/38/39 and at every interval produces identical
    hashes.** Every repeat seen while the original is still in the 1024-entry window is a duplicate.
  - 802.15.4 without FCS (DLT 230): the whole MAC frame. A retransmission with the same sequence number is a
    duplicate. (The project's C helper sends 802.15.4 as DLT 230, `P/kismet/capture_esp32c5/capture_esp32c5.c:71-75`,
    IN FLUX.)
- What a duplicate still counts toward:
  - **Source packet count** (`kismet.datasource.num_packets`, the Data Sources panel) counts **every** packet,
    before de-duplication (`K/kis_datasource.cc:959-966`).
  - **BTLE devices**: duplicates are skipped by the BTLE dissector and never update the device, so they add
    nothing to device packets, signal or seen-by (`K/phy_btle.cc:195-197`, `:280-282`).
  - **802.15.4 devices**: the same (`K/phy_802154.cc:113-114`, `:414-416`).
  - **Wi-Fi devices**: duplicates update seen-by, signal and location of existing devices, but not packet
    counts (`K/phy_80211.cc:1240-1275`).
  - Logs: kismetdb and pcapng **keep** duplicates by default (`kis_log_duplicate_packets=true`,
    `pcapng_log_duplicate_packets=true`). The kismetdb gives a duplicate the same packet id as its original
    (`K/kis_databaselogfile.cc:550`).
  - `/packetchain/packet_stats.json` → `dupe_packets_rrd` shows the rate.
- Run evidence (Pi, Wi-Fi + BTLE boards): 18 BTLE devices showed only 1 to 3 packets each while the BTLE source
  counted 2969 packets (about 20/s), with `dupe_packets_rrd` = 87 in the last second
  (run: pi-run-notes.txt:16). The same run showed every BTLE device on channel 37 / 2402 MHz. That is a firmware
  matter (it reports RF channel 0, which Kismet maps to 37, `K/kis_dlt_btle_radio.cc:99-101`), IN FLUX, see
  `firmware.md`.
- Nothing in the config turns de-duplication off.
- Related BTLE filter: `btle_ignore_random=true` (commented out by default) drops **all** BTLE devices with
  random addresses from the device list and UI. Their packets are still logged (`K/conf/kismet_filter.conf:42-55`,
  `K/phy_btle.cc:172-173`, `:287-289`).

## 16. Phy names, link types

| Phy name (exact; for filters, REST, kismetdb) | Registered at | Our radio / link type |
|---|---|---|
| **`IEEE802.11`** | `K/phy_80211.cc:169` | Wi-Fi, radiotap (DLT 127) |
| **`802.15.4`** | `K/phy_802154.cc:77` | Zigbee/Thread. Kismet decodes DLT 230 (`IEEE802_15_4_NOFCS`) and 283 (`IEEE802_15_4_TAP`) (`K/phy_802154.cc:96`, `:127`) |
| **`BTLE`** | `K/phy_btle.cc:129` | BLE advertising. DLT 256 (`BTLE_RADIO`, LL with pseudo-header) decapsulated to 251 (`BLUETOOTH_LE_LL`) (`K/kis_dlt_btle_radio.cc:35-36`, `K/phy_btle.cc:46-52`) |
| `Bluetooth` | `K/phy_bluetooth.cc:72` | classic Bluetooth (not ours) |

Others registered: `RFSENSOR`, `Z-Wave`, `UAV`, `NrfMousejack`, `METER`, `ADSB`, `RADIATION`
(`K/kismet_server.cc:900-911`). The BTLE pseudo-header channel byte maps 0→"37" (2402 MHz), 12→"38" (2426),
39→"39" (2480); other values map to data channels (`K/kis_dlt_btle_radio.cc:99-114`). A BTLE packet whose
pseudo-header says "CRC checked" but not "CRC valid" is counted as an error, not decoded (`:80-89`).

## 17. Quirks and gotchas at cfe427074 (all from code reading unless marked run)

1. Duplicate keys in the base config: the **first** value wins. Put changes in `kismet_site.conf` (§2.3).
2. Booleans: only `true/t/false/f` (§2.4).
3. `channel=` alone does not lock a source; add `channel_hop=false` (§8.1).
4. `channel_hoprate` is ignored for a lone source (§8.2).
5. API key `duration` is ignored; keys never expire (§6.3).
6. `?KISMET=<key>` is ignored when the request carries any Cookie header (§6.1).
7. `%h` is the passwd home, not `$HOME` (§3; run-confirmed).
8. First visitor to port 2501 sets the admin password (§5.1).
9. Log file names use UTC (§2.4). The stock `log_prefix=./` means "wherever Kismet was started" (§11.1).
10. `kismet --version` and `kismet --help` exit with status 1 (§1).
11. `make install` needs a `kismet` group when libusb is present (§1; run-confirmed on WSL).
12. `--confdir` does not move `kismet.conf` itself (§2.1).
13. Config names that the code does not read, or reads under another name:
    `packet_dedup_size` (unused; ring fixed at 1024), `packet_backlog_warning` (the code reads
    `packet_log_warning`, `K/packetchain.cc:73-74`), `httpd_session_timeout` (unused), `kis_log_datasources_rate`
    (the code reads `kis_log_datasource_rate`), `kis_log_channel_history` / `_rate` (unused),
    `pcspng_log_truncate_duplicates` (typo in the comment; the code reads `pcapng_truncate_duplicate_packets`),
    `kis_log_truncate_duplicates` (unused), `server_name` vs `servername` (both exist for different things:
    `K/system_monitor.cc:98`, `K/kismet_server.cc:814`). All harmless with stock values.
14. `--device-timeout` is in `--help` but not implemented (§2.5).
15. No built-in TLS; `README.SSL` is stale (§4).
16. Every start logs `ERROR: Tried to re-register duplicate alert FLIPPERZERO`. It is harmless: both
    `K/phy_bluetooth.cc:95` and `K/phy_btle.cc:153` register it (`K/alertracker.cc:228`; run: pi-run-notes.txt:26).
    **Do not treat "ERROR" lines in Kismet's log as a test failure by themselves.**
17. Split hopping loses its offset after the first pass (§8.2; run-confirmed).
18. Websocket remote capture from the C framework is slow to start and bursty compared with `--tcp`
    (§9.2; run-measured).
19. `--autodetect` announces the legacy TCP port (§9.4; UNVERIFIED by run).
20. v3 open report: when a helper reports a hop rate, Kismet stores it and then overwrites it with `1`
    (`set_int_source_hop_rate(rate); set_int_source_hop_rate(true);`, `K/kis_datasource.cc:1766-1767`). The field
    is corrected by the next configure report after Kismet's own hop command (`:1499-1511`). Relevant for
    helper authors only. `python-helper.md` covers how the Python helper shapes that block (IN FLUX).
21. The httpd default for the login file when `httpd_auth_file` is missing from the config has a typo,
    `%h/.kismetkismet_httpd.conf` (`K/kis_net_beast_httpd.cc:143-144`). Irrelevant with the stock
    `kismet_httpd.conf`, which sets it.

---

## IN FLUX (depends on helpers or firmware still being changed)
- Whether the C helper honours `channel=` with `channel_hop=false` (run: pi-run-notes.txt:6 said no; the code
  comment says yes). Affects the "lock a channel" guide.
- Which source names the helper claims without `type=` (probing), and so whether docs can drop `type=esp32c5`.
- The helpers' remote-capture options and credentials (`KISMET_CAP_*` env vars in C; the Python helper's
  own flags and how it authenticates: `?KISMET=` vs Basic vs cookie).
- Whether the Python helper mirrors `capture_framework` hop behaviour (offset, shuffle spacing 4, 50 ms floor)
  and the v3 open-report hop block.
- The link types the helper emits (802.15.4 as DLT 230 with a signal block; BTLE as DLT 256), which decide
  what Kismet de-duplicates and decodes.
- BTLE channel reporting (firmware sends RF channel 0, so all BTLE shows as channel 37).
- Install permissions of `kismet_cap_esp32c5` under `make suidinstall` (follows CatSniffer per add-to-kismet.sh).

## UNVERIFIED (read from code or external; not run)
- All `curl` examples and exact JSON error texts.
- The `Kismet 2026.09.0-cfe4270` version string format for a September 2026 build.
- IPv6 values for `httpd_bind_address` / `remote_capture_listen`.
- `channel_hoprate` being ignored for a single source (code is clear; not observed).
- `--autodetect` connecting to the legacy port and needing `--tcp`.
- kismetdb tools on a live (open) log; the kismetdb pcap REST filter semantics.
- systemd's default working directory `/` for system units and the resulting log failure.
- The need for the `dialout` group for a non-suid helper (OS fact).

## Open questions
1. Should the docs recommend `make suidinstall` (helper 4550 root:kismet, user in `kismet`) or `make install`
   plus `dialout` for the serial port? Kismet itself is neutral for serial helpers.
2. Recommended remote transport for the Windows → Kismet setup: websocket on 2501 with a `datasource` API key
   (authenticated, reachable by default, 3 s start-up with the C helper) or `--tcp` 3501 (no auth, loopback by
   default, fast)? Which does the Python helper use by default?
3. Does the project ship a udev rule or a systemd unit of its own (Kismet ships none for 303a:1001, and its
   `kismet.service` is not installed by `make install`)?
4. Given that `channel_hoprate` only works when splitting, should the docs present only the global
   `channel_hop_speed` and the REST `rate` field?
5. Should the docs mention the first-visitor password risk with a concrete recommendation (pre-provision
   `~/.kismet/kismet_httpd.conf`, or `httpd_bind_address=127.0.0.1` until set)?
