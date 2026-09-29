This page lists every command this project uses, with its options, environment variables and exit codes. It covers Kismet itself (the options that matter here), the C helper `kismet_cap_esp32c5`, the Python remote helper, the Docker image's roles, the fake board, `add-to-kismet.sh`, esptool and Kismet's log tools. It is a lookup table. For explanations and walk-throughs, follow the links in each section.

## kismet

The Kismet server. Built from source with this project's source added, see [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).

With the tested home-directory install (`--prefix=$HOME/kismet-install`), `kismet`, `kismet_cap_esp32c5` and Kismet's log tools are in `~/kismet-install/bin`, which is not on your `PATH`. Call them by that path (`~/kismet-install/bin/kismet`), or add the directory to `PATH`. This page writes the bare names. In the Docker image they are in `/usr/bin`.

```text
kismet [options]
```

| Option | What it does |
|---|---|
| `-c <definition>`, `--capture-source <definition>` | Add a source. Repeat it for more sources. **Any `-c` makes Kismet ignore every `source=` line in the config files.** See [Source Definitions](Source-Definitions). |
| `-n`, `--no-logging` | Write no log files at all. Kismet raises the alert `LOGDISABLED`. |
| `--homedir <dir>` | Use `<dir>` for the per-user directory `<dir>/.kismet/` (web login, API keys). Without it Kismet uses the home directory from the password database, not `$HOME`. |
| `--override <flavour or file>` | Load one more config file last: a path, or `kismet_<flavour>.conf` from the config directory (`--override wardrive` loads `kismet_wardrive.conf`). |
| `-f <file>`, `--config-file <file>` | Read another main config file instead of `kismet.conf`. |
| `--confdir <dir>` | Change the config directory used for includes and `kismet_site.conf`. It does not move `kismet.conf` itself; use it with `-f <dir>/kismet.conf`. |
| `--datadir <dir>` | Change the data directory (web UI files and other shared data). |
| `-T <types>`, `--log-types <types>` | Replace `log_types`, e.g. `-T kismet,pcapng`. |
| `-t <title>`, `--log-title <title>` | Replace `log_title` (default `Kismet`). |
| `-p <dir>`, `--log-prefix <dir>` | Replace `log_prefix`, the directory for logs. It must exist. |
| `-s`, `--silent` | No console output after start-up. |
| `--daemonize` | Run in the background. Prints `Silencing output and entering daemon mode...`. |
| `--no-ncurses`, `--no-ncurses-wrapper`, `--no-console-wrapper` | No banner or console frame. Use this for services, scripts and Docker. |
| `--debug` | No console wrapper, no crash handler, Ctrl+C not masked. |
| `--no-line-wrap` | Do not wrap console lines. |
| `--no-plugins` | Do not load plugins. |
| `-v`, `--version` | Print `Kismet <year>.<month>.0-<commit>` and exit. |
| `-h`, `--help` | Print the usage and exit. |

- `--device-timeout` appears in `--help` but does nothing at this Kismet commit. Use `tracker_device_timeout` in the config instead.
- `kismet --version` and `kismet --help` exit with status **1**, by design. Check the printed text, not the exit status. The Raspberry Pi build printed `Kismet 2026.09.0-cfe427074`; the length of the commit hash can differ between builds (the Docker image shows `cfe42707`).
- `kismet_server` is an old name. It prints a notice, waits one second and runs `kismet`.
- Environment: `KISMET_CONF=<dir>` makes Kismet read `<dir>/kismet.conf`.

Examples. Change the device names to your boards'. The directories for `-p` and `--homedir` must exist and be writable by you: Kismet does not create a log directory, and under `--homedir` it creates only the `.kismet` folder, then stops with `Could not create config and cache directory` if it cannot. So make them first:

```bash
kismet --no-ncurses -c esp32c5-ttyACM0
kismet --no-ncurses --no-logging -c 'esp32c5zigbee-ttyACM1:channel=20,channel_hop=false'
mkdir -p ~/captures
kismet --no-ncurses -T kismet,pcapng -p ~/captures -c esp32c5-ttyACM0 -c esp32c5btle-ttyACM1
mkdir -p ~/kismet-home
kismet --homedir ~/kismet-home --no-ncurses -c esp32c5-ttyACM0
```

<!-- VERIFY: the short "-c esp32c5-ttyACM0" form on real hardware with the current C helper -->

With the console wrapper on, Kismet prints `KISMET - Point your browser to http://localhost:2501 (or the address of this system) for the Kismet UI`. The web UI is on port 2501. See [Kismet Configuration](Kismet-Configuration) for the config files.

## kismet_cap_esp32c5 (the C helper)

The capture helper that Kismet starts for every local esp32c5 source. It is installed next to `kismet`, in the same `bin` directory. You run it yourself only for three things: listing boards, printing its version, and remote capture (sending a board to a Kismet server on another machine).

When Kismet starts it, the command line holds only `--in-fd=<n> --out-fd=<m>`. You never use those by hand.

### Options

These are Kismet's standard capture-helper options; the helper adds only the environment variables below.

| Option | What it does |
|---|---|
| `--list` | List the boards plugged in, once per radio, and exit. Linux only (it reads sysfs). Writes to **stderr** and exits with **2**. Opens no port. |
| `--connect <host>:<port>` | Remote capture to the Kismet server at `<host>:<port>`. By default a websocket on Kismet's web port, 2501. The port is required. |
| `--host <host>:<port>` | The same as `--connect`. |
| `--source <definition>` | The source to send. Required with `--connect`. One per process. |
| `--tcp` | Use Kismet's legacy TCP remote capture instead of the websocket: port 3501, **no authentication**, loopback only in Kismet's default config. |
| `--ssl` | `wss://` instead of `ws://`, for a Kismet server behind a TLS proxy. |
| `--ssl-certificate <file>` | CA certificate to check the server with. |
| `--user <user>` | Kismet web login, with `--password`. |
| `--password <password>` | Kismet web password, with `--user`. |
| `--apikey <key>` | Kismet API key instead of a login. It needs the `datasource` role (or `admin`). |
| `--endpoint <path>` | Websocket path, default `/datasource/remote/remotesource.ws`. For Kismet behind a reverse proxy with a prefix. |
| `--disable-retry` | Exit when the capture ends. By default the helper reconnects forever, 5 s after each exit. |
| `--daemonize` | Run in the background. |
| `--fixed-gps <lat>,<lon>[,<alt>]` | A fixed position for the packets of this remote source. |
| `--gps-name <name>` | The name of that GPS. |
| `--autodetect[=<server uuid>]` | Wait for a Kismet server's UDP announcement and connect to it. |
| `--version` | Print `<year>.<month>.0-<commit>` and exit with **0**. |
| `--help` | Print the usage and exit with **255**. |

<!-- VERIFY: --autodetect connects to the announced legacy TCP port (3501), which is loopback-only by default and needs --tcp; derived from Kismet's code, not run -->

### Environment variables

A login on the command line can be read by every user on the machine in the process list. So when `--connect`, `--host` or `--autodetect` is given without `--tcp`, the helper takes what the command line leaves out from its environment:

| On the command line | Taken from the environment |
|---|---|
| none of `--user`, `--password`, `--apikey` | `KISMET_CAP_APIKEY`; if that is unset, `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD` (both needed) |
| `--user` alone | `KISMET_CAP_PASSWORD` |
| `--password` alone | `KISMET_CAP_USER` |
| `--apikey`, or both `--user` and `--password` | nothing |

Empty variables count as unset. The API key wins when both kinds are set. A value on the command line always wins over the environment. The helper passes them on internally, so they do not show in the process list. This needs a helper built with libwebsockets, which is the normal build. The Docker image's `helper` role uses these variables.

> **Note:** Kismet decodes the whole query string of the remote-capture URL before it splits it on `&`. A user name or password that contains `&`, a space or `%` followed by two hex digits cannot get through, however it is escaped. Use an API key (32 hex characters), or another password.

### Messages from the framework

| Message | Cause |
|---|---|
| `FATAL: User and password or API key required for remote capture` | Websocket mode with no login anywhere. |
| `FATAL:  Must specify both username and password` | Only one of `--user` and `--password`, and the environment did not complete it. |
| `FATAL: --source option required when connecting to a remote host` | `--connect` without `--source`. |
| `FATAL: Expected host:port for --connect` | No port. |
| `WARNING: It looks like you're using a legacy TCP remote capture port, but did not specify '--tcp'; this probably is not what you want!` | Port 3501 without `--tcp`. |
| `WARNING: Ignoring APIKEY and using login information` | Both a login and a key. |
| `FATAL: Could not probe local source prior to connecting to the remote host: <reason>` | The definition names no port (a bare `esp32c5`, or a free-form name such as `esp32c5-kitchen`), and there is no board or more than one. The helper checks its definition before it connects. A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) connects anyway, and Kismet shows the open error as the source's error. |
| `INFO: Sleeping 5 seconds before attempting to reconnect to remote server` | The retry loop, after the capture ended or the server could not be reached. |

<!-- VERIFY: whether the retry loop restarts a remote helper that stopped with "Could not probe local source" every 5 s, and how often it prints the FATAL line; that a remote helper whose named port is missing connects and reports the open error (read from capture_esp32c5.c probe_callback and resolve_device) -->

### --list output

```bash
kismet_cap_esp32c5 --list 2>&1
```

For one free board on `/dev/ttyACM0` it prints:

```text
esp32c5 supported data sources:
    esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
```

<!-- VERIFY: capture the real --list output of the current C helper, idle and with one source running (the output above is derived from the code) -->

- Each board appears three times, once per radio. They are alternatives: a board captures with one radio at a time.
- A board whose port is in use by a source is left out, all three lines.
- With no free board, or no Linux sysfs: `esp32c5 - No supported data sources found...`.
- Every ESP32 on its native USB port has the same USB ID, so a listed board need not be an ESP32-C5 sniffer.

### Remote capture examples

Replace `192.168.1.50` with your Kismet server, and `3F9A6C1E07B24D58A1C9E2F4608B7D35` with your API key, one with the `datasource` role ([Kismet Configuration](Kismet-Configuration) shows how to make one):

```bash
export KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
kismet_cap_esp32c5 --connect 192.168.1.50:2501 --source esp32c5zigbee-ttyACM0
```

With a login from the environment instead:

```bash
export KISMET_CAP_USER=kismet
export KISMET_CAP_PASSWORD=choose-a-password
kismet_cap_esp32c5 --connect 192.168.1.50:2501 --source 'esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=remote-c'
```

Over the legacy TCP port, from the same machine as Kismet (no login):

```bash
kismet_cap_esp32c5 --connect 127.0.0.1:3501 --tcp --source esp32c5btle-ttyACM1
```

<!-- VERIFY: these three command lines as written with the current C helper (the hardware runs used --user/--password on the command line) -->

Over the websocket, the source took about 3 to 5.4 s from connecting to capturing in the last hardware run (2.96, 3.63 and 5.38 s in three sessions), and packets came in bursts; over `--tcp` it took about 0.5 s. See [Remote Capture](Remote-Capture).

<!-- VERIFY: re-measure the websocket start-up delay (3-5.4 s) and --tcp (0.5 s) with the current C helper build -->


## python -m esp32c5_kismet.remote (the Python remote helper)

Sends boards plugged into this machine to a Kismet server elsewhere, over Kismet's remote capture. It runs wherever Python and pyserial do, and is the way to use boards on Windows. It is not in the Docker image.

### Installing and running

There is no package to install. Run it from the root of the repository, so that Python finds `esp32c5_kismet`. On Windows:

```powershell
cd esp32c5-kismet-wifi-interface
python -m pip install -r requirements.txt
python -m esp32c5_kismet.remote --list
```

On Linux, put the requirements in a virtual environment in the repository root (`.venv` is git-ignored), and run the helper with that environment's Python:

```bash
cd esp32c5-kismet-wifi-interface
sudo apt install python3-venv                          # if python3 -m venv says ensurepip is not available
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m esp32c5_kismet.remote --list
```

- `requirements.txt` asks for `pyserial>=3.5`, `msgpack>=1.0` and `websocket-client>=1.9.1`. That websocket-client needs **Python 3.10 or newer**. It has run on Python 3.13 (Windows) and 3.12 (Ubuntu 24.04).
- On Linux a virtual environment is the way to use pip: Debian 12 and later and Ubuntu 23.04 and later refuse `pip install` into the system Python with `error: externally-managed-environment`. The distributions' own packages are older than `requirements.txt` asks for: Ubuntu 24.04 packages websocket-client 1.7.0 and Debian 13 packages 1.8.0.
- pyserial and msgpack are needed even for `--help` and `--list`. websocket-client is not needed with `--tcp`.

<!-- VERIFY: whether "py -m esp32c5_kismet.remote" (the Windows launcher) works the same; whether a pyproject.toml / entry point is added before release -->

### Usage

```text
usage: python -m esp32c5_kismet.remote [-h] [--connect HOST:PORT] [--tcp] [--ssl]
                                       [--ssl-certificate CAFILE] [--user USER]
                                       [--password PASSWORD] [--apikey APIKEY]
                                       [--endpoint ENDPOINT] [--source DEF] [--list] [--debug]
```

| Option | Default | What it does |
|---|---|---|
| `--connect HOST:PORT` | required unless `--list` | The Kismet server: its web port (2501) for the websocket, or 3501 with `--tcp`. Split at the last colon, so `[::1]:2501` works. |
| `--source DEF` | required with `--connect` | One source definition. Repeat it for more boards; each gets its own connection. See [Source Definitions](Source-Definitions). |
| `--apikey APIKEY` | none | A Kismet API key with the `datasource` role, instead of a login. |
| `--user USER` | none | Kismet web login, with `--password` or with `KISMET_CAP_PASSWORD` in the environment. |
| `--password PASSWORD` | none | Kismet web password, with `--user` or with `KISMET_CAP_USER` in the environment. |
| `--tcp` | off | Legacy TCP remote capture: no login (a user, password or key is ignored with a warning). Cannot be combined with `--ssl`. |
| `--ssl` | off | `wss://` instead of `ws://`. |
| `--ssl-certificate CAFILE` | none | CA certificate to check the server with. Implies `--ssl`. |
| `--endpoint ENDPOINT` | `/datasource/remote/remotesource.ws` | Websocket path, for Kismet behind a reverse proxy. |
| `--list` | off | List the boards plugged in and exit. Needs no `--connect`. |
| `--debug` | off | Log every protocol message except packets. |
| `-h`, `--help` | | Print the usage and exit. |

Option names can be shortened while they stay unambiguous (`--conn`). When both a login and a key are given, the login wins, with the warning `ignoring --apikey and using the login`.

`localhost` is tried as `127.0.0.1` first, then `::1`. On Windows `localhost` resolves to `::1` first, and WSL2's port forwarder listens on `127.0.0.1` only, which used to cost about 2 s per connection. Docker Desktop was not measured separately.

<!-- VERIFY: localhost tries 127.0.0.1 first (P16), re-measured on Windows against WSL2 and Docker Desktop; whether Docker Desktop's published port refuses ::1 at all -->

### Environment variables

The Python remote helper follows the same rules as the C helper ([its table above](#environment-variables)), with the same variable names. With `--tcp`, which needs no login, it reads none of them.

- With none of `--user`, `--password` and `--apikey`, it reads `KISMET_CAP_APIKEY`, or else `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD` (both needed).
- Half a login is completed from the environment: `--user` alone takes `KISMET_CAP_PASSWORD`, and `--password` alone takes `KISMET_CAP_USER`. An API key from the environment is never used for that.
- Empty variables count as unset. Anything on the command line wins.

In PowerShell, with `3F9A6C1E07B24D58A1C9E2F4608B7D35` changed to your API key:

```powershell
$env:KISMET_CAP_APIKEY = "3F9A6C1E07B24D58A1C9E2F4608B7D35"
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5-COM14
```

<!-- VERIFY: environment login (P17), including half a login completed from the environment, against a real Kismet -->

### --list

Output goes to stdout. The helper finds boards by USB ID and never opens a port. On Windows:

```text
COM14  F0:F5:BD:01:02:03
    --source esp32c5-COM14
    --source esp32c5zigbee-COM14
    --source esp32c5btle-COM14
One source per board: it captures with one radio at a time. Every ESP32 on its native USB port has this USB ID, so a board listed here need not be an ESP32-C5 sniffer.
```

On Linux the lines read `/dev/ttyACM0  F0:F5:BD:01:02:03` and `--source esp32c5-ttyACM0`. A board whose USB serial number is not a MAC shows `(no MAC in its USB serial number)`. With nothing plugged in: `No Espressif USB-Serial-JTAG device (USB ID 303a:1001) found.` and exit code 1.

<!-- VERIFY: --list wording with the current Python remote helper (P2, P14) -->

### Exit codes

| Code | When |
|---|---|
| 0 | `--help`; `--list` found at least one board; stopped with Ctrl+C, Ctrl+Break or SIGTERM |
| 1 | `--list` found no board; every source stopped by itself (`ERROR: every source has stopped by itself`) |
| 2 | a command-line or definition error |

A source whose board is missing, whose port is busy or whose Kismet server is down does not stop the helper. It logs an ERROR and tries again every 5 s. Exit code 1 for "every source stopped" is meant for a service manager such as systemd with `Restart=on-failure`.

### Command-line errors

All of these print the usage, then `python -m esp32c5_kismet.remote: error: <text>`, and exit with 2.

| Message | Cause |
|---|---|
| `--connect HOST:PORT is required (or --list to see the boards)` | Neither `--connect` nor `--list`. |
| `expected host:port, not '127.0.0.1'` | No port in `--connect`. |
| `--source is required when connecting to Kismet` | No `--source`. |
| `a user and password, or an API key, are required for the websocket protocol (...)` | No login on the command line or in the environment. |
| `give both --user and --password (the one left out may also be in KISMET_CAP_USER or KISMET_CAP_PASSWORD)` | Only one of them, and the environment did not complete it. Without the part in brackets when `--apikey` was given too. |
| `--ssl needs the websocket protocol, not --tcp` | `--tcp` with `--ssl` or `--ssl-certificate`. |
| `the websocket protocol needs websocket-client (pip install websocket-client), or use --tcp` | websocket-client is missing. |
| `esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14` | Two definitions for one board. |
| `esp32c5:mode=wifi and esp32c5:mode=zigbee name no port, so both would take the same board; ...` | Two definitions without a port. |
| `esp32c5-COM14:channel=15: esp32c5-COM14: channel=15 is not a channel the board can tune to in wifi mode` | A `channel=` the radio does not have. The whole definition comes first. |
| `esp32c5-COM14:mode=lora: unknown mode 'lora': use wifi, zigbee (802154, 802.15.4, thread) or btle (ble, bluetooth)` | A `mode=` that is not a radio. |
| `esp32c5-COM14:zigbee: option 'zigbee' has no value` | A piece without `=` right after the `:`, before any option. Write `mode=zigbee`. |

Warnings that do not stop it: `ignoring the user, password and API key in legacy TCP mode`, `ignoring --apikey and using the login`, `port 3501 is Kismet's legacy TCP port; did you mean --tcp, or port 2501?`, and `<definition>: the comma list in channels= is not in double quotes, so Kismet reads only its first item and takes the rest for another option; write channels="1,6,11"` (see [Source Definitions](Source-Definitions) for quoting in PowerShell and cmd).

<!-- VERIFY: the unquoted comma-list warning is in the Python remote helper's final code (seen in the current code, which is still under review) -->

### Logging

The log goes to stderr, one line per event: `HH:MM:SS LEVEL: message`. For example:

```text
13:58:30 INFO: esp32c5-COM14:name=desk-wifi: connected, offering it to Kismet as E5C50001-0000-0000-0000-F0F5BD010203
13:58:30 INFO: esp32c5-COM14:name=desk-wifi: opening COM14 for wifi
13:58:30 INFO: COM14 opened
13:58:30 INFO: COM14 capturing
```

`--debug` adds every protocol message except packets (`-> KDS_OPENREPORT, 269 bytes`, `<- KDS_CONFIGREQ seqno 2`), the stop signal received, and where the login came from.

### Stopping

- **Windows:** press Ctrl+C, or Ctrl+Break, in the helper's console window. For a helper you cannot reach, `taskkill /F /PID <pid>` is safe: the COM port is released at once.
- **Linux and macOS:** Ctrl+C, or SIGTERM (`kill <pid>`, `systemctl stop`).

It logs `INFO: stopping`, closes every connection and port, and exits with 0, in well under a second on Windows in the last test. Kismet then shows the source in error with the reason `websocket connection closed`; that is expected.

<!-- VERIFY: stop handling (P15) on Windows with the current code, including Ctrl+Break and a helper started as a Git Bash background job -->

### Examples

Change the ports, the address and the key to yours:

```powershell
python -m esp32c5_kismet.remote --list
python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-COM14
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-COM14:name=desk-wifi --source esp32c5btle-COM15:name=desk-ble
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --user kismet --password choose-a-password --source esp32c5zigbee-COM14:channel=20,channel_hop=false --debug
```

On Linux, the same with the virtual environment's Python and tty names, from the repository root:

```bash
.venv/bin/python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5zigbee-ttyACM0
```

## The Docker image (esp32c5-kismet)

The image's entrypoint, `/usr/local/bin/esp32c5-kismet`, has three roles. The first argument picks one; the default is `kismet`. Its own messages start with `[esp32c5-kismet]` and go to stderr. Full details: [Docker Reference](Docker-Reference).

| Role | Command | What it does |
|---|---|---|
| `kismet` (default) | `kismet [ARGS]` | Sets the web login, makes device nodes for the boards, adds a source per board (or `KISMET_SOURCES`), then runs `kismet --no-ncurses ARGS -c ...`. `ARGS` go to Kismet unchanged. |
| `helper` | `helper` | No Kismet here: runs `kismet_cap_esp32c5 --connect "$KISMET_SERVER" --source <def>` for each source, each in a loop that restarts it 5 s after it exits. |
| anything else | e.g. `kismet_cap_esp32c5 --list`, `sh` | Runs the command, with the boards' device nodes kept up to date. |

- To pass options to Kismet, keep the word `kismet` first: `docker run ... esp32c5-kismet kismet --no-logging`. A first argument that is not a role is run as a command.
- With `-v`, `--version`, `-h` or `--help` among the arguments, the `kismet` role runs Kismet straight away: no login, board scan or demo.
- The `helper` role hands the login to `kismet_cap_esp32c5` through `KISMET_CAP_*` in its environment, never on its command line. `KISMET_APIKEY` wins; otherwise `KISMET_USER` and `KISMET_PASSWORD` are used, and they may not contain `&`, a space or `%` followed by two hex digits (`helper: KISMET_USER and KISMET_PASSWORD cannot contain '&', a space or %XX for remote capture; use KISMET_APIKEY, or another password`, exit 2). Without either: `helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD`, exit 2.
- The `helper` role does not wait for a first board, but like the `kismet` role it checks the board list again every 2 s until two checks agree, at most 10 s, unless `ESP32C5_WAIT=0` or `KISMET_SOURCES` is set. With none found and `KISMET_SOURCES` empty it prints `helper: no ESP32-C5 board found and KISMET_SOURCES is empty` and exits 1; compose's `restart: unless-stopped` then starts it again.

| Variable | Default | Role | Meaning |
|---|---|---|---|
| `KISMET_SOURCES` | empty | kismet, helper | Source definitions separated by spaces. Empty: one source per board found. |
| `ESP32C5_MODE` | `wifi` | kismet, helper | The radio for boards found by themselves: `wifi`, `zigbee` or `btle`. |
| `ESP32C5_WAIT` | `30` | kismet, helper | kismet: seconds to wait at start for a board, then until no more turn up (up to 10 s longer). helper: no wait for a first board, only the wait until no more turn up. `0` turns both off. compose.yaml does not pass it. |
| `KISMET_USER`, `KISMET_PASSWORD` | empty | kismet, helper | kismet: the web login, written at every start. helper: the remote-capture login when there is no API key. They work only as a pair. |
| `KISMET_SERVER` | none | helper | `HOST:PORT` of the Kismet to feed, on its web port. Required. |
| `KISMET_APIKEY` | empty | helper | An API key with the `datasource` role. Wins over the login. |
| `ESP32C5_DEMO` | `wifi` in the demo image | kismet | The fake board's radio: `wifi`, `zigbee` (or `802154`) or `btle` (or `ble`). Empty turns it off. |

<!-- VERIFY: ESP32C5_WAIT waiting until the board list settles (in the kismet and helper roles), the demo not looking for boards, and device nodes in the exec role: all changed in the entrypoint after the last Docker test -->

Examples, from the root of the repository (see [Install with Docker](Install-with-Docker)). With Docker Compose, which builds the images when it cannot pull them:

```bash
docker compose up -d
docker compose --profile demo up demo
docker compose --profile helper up -d helper
```

With plain `docker`, build the images under the local names `esp32c5-kismet` and `esp32c5-kismet:demo` first, then run them. Images that Compose built carry the `ghcr.io/...` names from compose.yaml instead (see the note at the end of this section), so the `docker run` lines below do not find those.

```bash
docker build -f docker/Dockerfile -t esp32c5-kismet .
docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
docker run --rm --cap-add NET_ADMIN -p 127.0.0.1:2501:2501 -e KISMET_USER=demo -e KISMET_PASSWORD=demo esp32c5-kismet:demo
docker run --rm esp32c5-kismet kismet_cap_esp32c5 --list
docker run --rm esp32c5-kismet kismet --version
```

<!-- VERIFY: NET_ADMIN removed? -->

On the Raspberry Pi, where the tested setup uses `sudo` rather than the `docker` group, put `sudo` before each of these. The `docker compose` lines also need the Compose plugin, which the tested Pi did not have: it had only Debian's `docker.io` and `docker-buildx` packages, and the image was built there with `sudo docker build`. See [Install with Docker](Install-with-Docker) for getting Compose, or for the plain `docker` route.

`kismet_cap_esp32c5 --list` reads only sysfs, so it works without any device access. A container that opens boards needs permission for the two USB serial device classes (166 is ttyACM, 188 is ttyUSB) and, for now, `NET_ADMIN`. compose.yaml sets both. With plain `docker run`, the `kismet` service's equivalent is (change the port and the volume names if you like):

```bash
docker run -d --name esp32c5-kismet --restart unless-stopped --init --cap-add NET_ADMIN --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet esp32c5-kismet
```

<!-- VERIFY: NET_ADMIN removed? -->
<!-- VERIFY: this docker run line is derived from compose.yaml and has not been run; no container has been run with real boards yet -->

Without the device rules, the entrypoint names the missing one:

```text
[esp32c5-kismet] found ttyACM0 in sysfs but the container may not use it: allow it with
[esp32c5-kismet] compose.yaml's device_cgroup_rules, or docker run --device-cgroup-rule 'c 166:* rmw'
```

> **Note:** The image names in compose.yaml are `ghcr.io/oshri-almog/esp32c5-kismet:latest` and `:demo`. Until images are published there, compose builds them locally.

<!-- VERIFY: once published, the ghcr.io image names and tags (latest, <version>, demo) -->

## tools/fake_board.py

A stand-in for a board, on a pseudo-terminal, for trying Kismet and the helpers without hardware. **POSIX only**: it has run on Linux and in WSL2, has not been tried on macOS, and does not run on Windows. See [Try It Without Hardware](Try-It-Without-Hardware).

```text
python3 tools/fake_board.py PATH [MODE] [--garble N] [--inject N] [--restart-every N] [--vanish] [--old-firmware]
```

| Argument | What it does |
|---|---|
| `PATH` | Where to put the port: a symbolic link to the pseudo-terminal, e.g. `/tmp/esp32c5-fake`. |
| `MODE` | The radio to boot with: `WIFI` (default), `802154` (or `ZIGBEE`, `THREAD`) or `BLE` (or `BT`, `BLUETOOTH`). Any case. Anything else boots Wi-Fi. |
| `--garble N` | Damage every Nth record, to test resynchronisation. |
| `--inject N` | Make every Nth record a frame whose payload holds the restart signature, as anyone on the air could send. |
| `--restart-every N` | Restart the stream in place every Nth record, as after a reset. |
| `--vanish` | On a change of radio, close the port and come back on a new pseudo-terminal two seconds later. |
| `--old-firmware` | Send BTLE records without the CRC flags and with a zeroed CRC, as older firmware does. |

The Nth record is counted from the last START the fake board answered. Without options it behaves like a board: it remembers its radio, reboots in about 0.53 s when asked for another one (the port stays open), and sends about 100 records a second on a channel with traffic:

| Radio | What it sends |
|---|---|
| Wi-Fi | beacons from `ESP32C5-FAKE-24` on channel 6, `ESP32C5-FAKE-5LOW` on 36 and `ESP32C5-FAKE-5HIGH` on 149 |
| 802.15.4 | data frames from a node on channel 15 and another on 25 |
| BTLE | an advertiser called `ESP32C5-FAKE` |

It runs in the foreground and logs to stdout, one line per event, starting with `[fake]`. Stop it with Ctrl+C.

To try it with Kismet, start the fake board in one terminal, from the root of the repository:

```bash
python3 tools/fake_board.py /tmp/esp32c5-fake
```

Then start Kismet in a second terminal. The path is the tested home-directory install's; see the `PATH` note under [kismet](#kismet):

```bash
~/kismet-install/bin/kismet --no-ncurses -c esp32c5:device=/tmp/esp32c5-fake
```

## kismet/add-to-kismet.sh

Adds the esp32c5 source to a Kismet source tree. See [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).

```bash
sh kismet/add-to-kismet.sh ~/src/kismet
```

- One argument: the path to the Kismet source tree. It needs `python3`, `aclocal` (from automake) and `autoconf`.
- It copies `datasource_esp32c5.h` and `capture_esp32c5/` into the tree, registers the source in `kismet_server.cc`, `Makefile.in` and `configure.ac`, adds a `.gitignore` line, fixes a small upstream memory leak in `capture_framework.c`, and regenerates `configure`. Each edit prints `  edited <file>`.
- It is safe to run again: every edit is skipped when it is already there. Re-running it is how an updated helper gets into the tree.
- At the end it prints `Done. Now: cd <tree> && ./configure && make`.

| Message | Meaning |
|---|---|
| `usage: <script> PATH_TO_KISMET_SOURCE` | No argument. |
| `<path> does not look like a Kismet source tree` | No `kismet_server.cc` or `capture_framework.c` there. Exit 1. |
| `anchor not found, Kismet has changed: <anchor>` | This Kismet commit differs from the one the script knows (`cfe427074`). |
| `  capture_framework.c: cf_commit_packet not found, its metadata leak not fixed` (or `... has changed, ...`) | The leak fix was skipped; the script carries on. |

After the script, run `./configure` again, with the options you used before. The script regenerates `configure`, so until then every `make` prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` That is only a notice, and `make` carries on. But a tree configured before the script's first run then builds Kismet without the helper, because its old Makefile does not know it.
<!-- VERIFY: that make on a tree configured before add-to-kismet.sh builds without kismet_cap_esp32c5 (the notice itself was checked: Kismet's Makefile rule only echoes it, and GNU Make 4.3 printed it on every run, carried on and exited 0) -->

## esptool and idf.py

Commands for flashing the firmware. See [Flashing the Firmware](Flashing-the-Firmware) for the full procedure. Replace `COM14` or `/dev/ttyACM0` with your board's port.

> **Warning:** Stop Kismet, the helpers and any serial monitor before you flash. esptool needs the port to itself.

### Flash the merged image

The merged image, `esp32c5-kismet-merged.bin`, goes at offset **0x0**. It holds the bootloader (at 0x2000), the partition table and the app. Building it is shown below; the build writes it to `firmware/build/`. Run these from the root of the repository:

```bash
# esptool v4, as shipped with ESP-IDF 5.5
python -m esptool --chip esp32c5 -p /dev/ttyACM0 -b 460800 write_flash 0x0 firmware/build/esp32c5-kismet-merged.bin
# esptool v5, from pip install esptool
esptool --chip esp32c5 -p /dev/ttyACM0 -b 460800 write-flash 0x0 firmware/build/esp32c5-kismet-merged.bin
```

- The underscore names (`write_flash`, `read_flash`, `verify_flash`, `erase_flash`, `merge_bin`) work in esptool v4 and v5; v5 prints a deprecation warning. The hyphenated names work in v5 only.
- `python -m esptool` works with both. The console command is `esptool.py` in v4 and `esptool` in v5.
- Flashing the merged image erases the board's stored radio, so it comes up in Wi-Fi.
- esptool resets the board into its bootloader by itself; no BOOT button is needed normally.

### Build and flash from source

From an ESP-IDF 5.5 shell, in the repository:

```bash
cd firmware
idf.py set-target esp32c5
idf.py build
idf.py -p /dev/ttyACM0 flash
idf.py merge-bin -o esp32c5-kismet-merged.bin
```

- `set-target` is needed once.
- `idf.py flash` writes the bootloader, partition table and app, at 460800 baud by default (`ESPBAUD`). It keeps the stored radio.
- `idf.py merge-bin` builds first, then writes `firmware/build/esp32c5-kismet-merged.bin`.
- `idf.py monitor` on the board's USB port shows the binary capture stream, not logs. The logs are on UART0; see [Firmware Protocol](Firmware-Protocol).

### Back up, verify, restore, erase

```bash
python -m esptool --chip esp32c5 -p /dev/ttyACM0 read_flash 0 ALL backup.bin
python -m esptool --chip esp32c5 -p /dev/ttyACM0 verify_flash 0x0 backup.bin
python -m esptool --chip esp32c5 -p /dev/ttyACM0 write_flash 0x0 backup.bin
python -m esptool --chip esp32c5 -p /dev/ttyACM0 erase_flash
idf.py -p /dev/ttyACM0 erase-flash
```

- `read_flash 0 ALL` reads the whole flash. An 8 MB board took 61 to 86 s over its native USB.
- `verify_flash` works in esptool v4 and v5 (v5 prints a deprecation warning). The test run used the v5 spelling, `esptool ... verify-flash 0x0 backup.bin`, and it reported `Verification successful (digest matched)`.
- Erasing also forgets the stored radio.

## Kismet's log tools

Installed next to `kismet`, and in the Docker image. See [Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark).

| Tool | Usage |
|---|---|
| `kismetdb_to_pcap` | `-i <kismetdb> -o <file> [-f] [-v] [-s] [--old-pcap] [--dlt <n>] [--list-datasources] [--datasource <uuid>] [--split-datasource] [--split-packets <n>] [--split-size <kb>] [--list-tags] [--tag <t>] [--skip-gps] [--skip-gps-track]`. Writes pcapng by default, which holds all link types in one file. |
| `kismetdb_strip_packets` | `-i <kismetdb> -o <new kismetdb> [-v] [-f]`: a copy without packet contents. |
| `kismetdb_dump_devices` | `-i <kismetdb> -o <json> [-f] [-j] [-e] [-v] [-s]` |
| `kismetdb_to_wiglecsv` | `-i <kismetdb> -o <csv> [-f] [-r <s>] [-c <n>] [-v] [-s] [-e lat,lon,dist_m]` |
| `kismetdb_statistics` | `-i <kismetdb> [-s] [-j]` |
| `kismetdb_to_kml` | `-i <kismetdb> -o <kml> [-f] [-v] [-s] [-e lat,lon,dist] [--basic-location] [-g]` |
| `kismetdb_to_gpx` | `-i <kismetdb> -o <gpx> [-f] [-v] [-s] [-e lat,lon,dist] [--basic-location]` |
| `kismetdb_clean` | `-i <kismetdb>`: clean up a log left with an incomplete journal after a crash. |
| `kismet_discovery` | Prints the UDP announcements of Kismet servers it hears. |

> **Note:** Most of these tools clean (VACUUM) the database first, which writes to it. Run them on a copy, or after Kismet has stopped, or pass `-s` (`--skip-clean`).

```bash
kismetdb_to_pcap -i Kismet-20260928-14-03-22-1.kismet -o capture.pcapng
```

<!-- VERIFY: this kismetdb_to_pcap command on a log with the three link types (not run) -->

## Test scripts

For development; see [Development and Testing](Development-and-Testing).

| Command | What it runs |
|---|---|
| `python tests/test_board.py` | Offline tests of the Python board link. No board needed. |
| `python tests/test_kismet_v3.py` | Offline tests of the Python remote helper's protocol, against a fake Kismet. `TEST_DEBUG=1` shows the helper's log. |
| `sh tests/c/run.sh [KISMET_TREE]` | The C helper's parser and logic tests. Needs a Kismet tree that went through `add-to-kismet.sh`, `configure` and `make` (default `$KISMET_SRC`, else `~/src/kismet`). Linux. Prints `ALL OK`. |
| `KISMET=~/kismet-install/bin/kismet sh tests/kismet_e2e.sh` | The fake board, the C helper and a real Kismet on port 2501. Stop any other Kismet first. |
| `KISMET=~/kismet-install/bin/kismet PYTHON="$PWD/.venv/bin/python" sh tests/remote_e2e.sh` | The fake board, the Python remote helper and a real Kismet on ports 2511 (websocket) and 3511 (legacy TCP), so a Kismet on 2501 is left alone. `PYTHON` must be an absolute path to a Python with pyserial, msgpack and websocket-client, such as the virtual environment's. Linux or WSL2; the test runs were as root in WSL2. Prints `ALL OK`. |
| `sh tests/docker_smoke.sh esp32c5-kismet:demo` | The demo image, every radio and the helper role. Uses host port 2599. On Windows in Git Bash: `PYTHON=python sh tests/docker_smoke.sh esp32c5-kismet:demo`. |

## Exit codes at a glance

Several of these look like failures and are not.

| Command | Exit code |
|---|---|
| `kismet --version`, `kismet --help` | 1 |
| `kismet_cap_esp32c5 --version` | 0 |
| `kismet_cap_esp32c5 --list` | 2, output on stderr |
| `kismet_cap_esp32c5 --help` | 255 |
| `python -m esp32c5_kismet.remote --list` | 0 with boards, 1 without |
| `python -m esp32c5_kismet.remote`, stopped | 0 |
| `python -m esp32c5_kismet.remote`, every source stopped by itself | 1 |
| `python -m esp32c5_kismet.remote`, a usage or definition error | 2 |
| Docker `helper` role without `KISMET_SERVER`, or without credentials | 2 |
| Docker `helper` role with no board and no `KISMET_SOURCES` | 1 |
