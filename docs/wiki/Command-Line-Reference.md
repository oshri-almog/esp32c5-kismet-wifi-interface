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
| `--ssl-certificate <file>` | CA certificate to check the server with. Implies `--ssl` (a helper built from an earlier version of this project needs `--ssl` as well). The helper reads it after dropping its capabilities, so the file's own permissions must let the helper's user read it: run as root, the helper no longer overrides them. |
| `--user <user>` | Kismet web login, with `--password`. |
| `--password <password>` | Kismet web password, with `--user`. |
| `--apikey <key>` | Kismet API key instead of a login. It needs the `datasource` role (or `admin`). |
| `--endpoint <path>` | Websocket path, default `/datasource/remote/remotesource.ws`. For Kismet behind a reverse proxy with a prefix. |
| `--disable-retry` | Exit when the capture ends. By default the helper reconnects forever, 5 s after each exit. |
| `--daemonize` | Run in the background. |
| `--fixed-gps <lat>,<lon>[,<alt>]` | A fixed position for the packets of this remote source. |
| `--gps-name <name>` | The name of that GPS. |
| `--autodetect[=<server uuid>]` | Meant to wait for a Kismet server's UDP announcement on port 2501 and connect to the port it announces. With the Kismet version `add-to-kismet.sh` is written for, it never connects: a bug in Kismet's `cf_wait_announcement()` (`r = recvmsg(...) < 0` in `capture_framework.c`, which `add-to-kismet.sh` does not patch) drops every announcement with `ERROR:  Received short announcement, ignoring.`, and the helper waits for ever. Even with that fixed it would need `--tcp` and a changed Kismet config: Kismet announces itself only with `server_announce=true` (off by default), and the port it announces is its legacy TCP port, 3501, which listens on loopback only by default. Read from Kismet's code; not tested. |
| `--version` | Print `<year>.<month>.0-<commit>` and exit with **0**. |
| `--help` | Print the usage and exit with **255**. |

### Environment variables

A login on the command line can be read by every user on the machine in the process list. So when `--connect`, `--host` or `--autodetect` is given without `--tcp`, the helper takes what the command line leaves out from its environment:

| On the command line | Taken from the environment |
|---|---|
| none of `--user`, `--password`, `--apikey` | `KISMET_CAP_APIKEY`; if that is unset, `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD` (both needed) |
| `--user` alone | `KISMET_CAP_PASSWORD` |
| `--password` alone | `KISMET_CAP_USER` |
| `--apikey`, or both `--user` and `--password` | nothing |

Empty variables count as unset. The API key wins when both kinds are set. A value on the command line always wins over the environment. The helper passes them on internally, so they do not show in the process list. This needs a helper built with libwebsockets, which is the normal build. The Docker image's `helper` role uses these variables.

> **Note:** The helper sends a user and password in the websocket request's `Authorization` header (HTTP Basic) and an API key in Kismet's session cookie (`Cookie: KISMET=<key>`). Neither goes in the request's address, which a reverse proxy may log, and any character works in a password, `&`, spaces and `%41` included. The one exception is a user name that contains `:`, which Basic cannot carry: that login goes in the address's query instead, and Kismet decodes the query before it splits it at `&`, so such a login cannot log in if the user name or password also holds an `&`. The helper warns about that login before it connects (see the messages below). Use an API key instead. The Python remote helper does the same. On the Raspberry Pi both helpers were checked this way through a proxy that logs every request: no request line held a secret. The request's `Host` header names the server with its port, unless that is the scheme's own (80, or 443 with `--ssl`).

### Messages from the framework

A remote helper prints these on its standard error. All but the `the Kismet user name holds ':'` warning come from Kismet's capture framework, as `add-to-kismet.sh` patches it. The helper's own statuses, such as `capturing`, go to Kismet's log, not here.

| Message | Cause |
|---|---|
| `FATAL: User and password or API key required for remote capture` | Websocket mode with no login anywhere. |
| `FATAL:  Must specify both username and password` | Only one of `--user` and `--password`, and the environment did not complete it. |
| `FATAL: --source option required when connecting to a remote host` | `--connect` without `--source`. |
| `FATAL: Expected host:port for --connect` | No port. |
| `WARNING: It looks like you're using a legacy TCP remote capture port, but` / `did not specify '--tcp'; this probably is not what you want!` (two lines) | Port 3501 without `--tcp`. |
| `WARNING: Ignoring APIKEY and using login information` | Both a login and a key. |
| `WARNING: the Kismet user name holds ':' and the login '&': Kismet reads a user name in an Authorization header only up to its first ':', and cuts a login in the websocket's address at every '&' (after decoding it), so this one cannot log in either way; use an API key (--apikey or KISMET_CAP_APIKEY) instead of the login` | A user name with `:`, and an `&` in the user name or password. The helper still tries, and Kismet refuses the login. See the note above. |
| `FATAL: Could not probe local source prior to connecting to the remote host: <reason>` | The helper checks its definition before every connection, and stops there when: the definition names no port (a bare `esp32c5`, or a free-form name such as `esp32c5-kitchen`) and there is no board or more than one; `mode=` or `channel=` is wrong; or, on Linux, another capture holds the port (`<name>: <port> is already in use by another capture; not offering it to Kismet until it is free (looked at again every 5 seconds)`). A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) connects even while that port is missing; the open fails, Kismet logs `Error connecting new remote source <name> (<uuid>) - cannot open /dev/ttyACM9: No such file or directory` and does not list the source, and the helper tries again every 5 s until the board is there. |
| `FATAL: Datasource could not connect websocket client` | The websocket could not be opened: Kismet cannot be reached, or it refused the login or API key. A refusal comes after a libwebsockets line ending `got bad HTTP response '401'`. |
| `FATAL: The websocket was answered with a redirect (HTTP <status> to <where>), which is not followed: Kismet never redirects it, and the login would go along to wherever it points; check --connect, --endpoint and --ssl` | Something between the helper and Kismet, such as a proxy, answered with a redirect. Nothing connects to where it points. `<where>` is the redirect's address up to any `?` or `#` (then `?...` or `#...`), with a space and each byte that is not printable ASCII written as `%XX`; without an address the line has only `(HTTP <status>)`. A helper built against libwebsockets older than 4.0 prints the line without `(HTTP ...)`, after it has connected to where the redirect points (it sends no request there). |
| `FATAL: The login does not fit in the websocket request's headers, which have <n> bytes left for it; use a shorter one, or an API key` | A user and password of more than about 2800 bytes together. Nothing is sent. |
| `FATAL: The API key does not fit in the websocket request's headers, which have <n> bytes left for it; the keys Kismet makes have 32 characters` | An API key far longer than Kismet's own. Nothing is sent. |
| `FATAL: A user name with ':' puts the login in the websocket URI, which would be <n> bytes long with it, more than the 1023 it can be; use an API key` | A long login whose user name has `:`. The helper prints its usage and exits with 255. |
| `INFO: Sleeping 5 seconds before attempting to reconnect to remote server` | The retry loop: after the capture ended, the server could not be reached, `Could not probe local source ...`, `Datasource could not connect websocket client`, the redirect, or either `does not fit` line. The four option errors at the top of the table, like the `':'` one just above, print the usage and exit with 255 instead, and are not retried. Over the websocket, `FATAL:  Datasource exiting libwebsocket loop` and `INFO: capture process exited 0 signal 0` come before it. The helper tries again 5 s later and prints the `FATAL` line again each time, until the cause is gone. With `--disable-retry` it exits instead; after a failed probe, with status 0 over the websocket and 4 over `--tcp`. |
| `INFO: <name> cannot tune to channel 40 in btle mode` | A remote helper was asked for a channel its radio does not have. The board stays on its channel and the set is answered as a success; Kismet logs it as `ERROR: <source name> - <name> cannot tune to channel 40 in btle mode`. |

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

In the hardware test on a Raspberry Pi, each of its four boards gave these three lines, with its own MAC.

- Each board appears three times, once per radio. They are alternatives: a board captures with one radio at a time.
- A board whose port is in use by a capture, of either helper, is left out, all three lines. The helper sees that in `/proc/locks`, without opening the port, so it misses a lock taken in another container, or on the host when `--list` runs in a container; that board is listed, and opening it fails with "already in use".
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

On the Raspberry Pi, `--connect` captured from real boards with the login on the command line or from `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`, with the API key from `--apikey` or from `KISMET_CAP_APIKEY`, and over `--tcp`. With the login from the environment, the helper's command line held no secret. A remote helper there also found its board through a by-id link given with `device=`.

In an earlier hardware run, the first packet reached Kismet about 1.2 s after the helper started (1.2 to 1.4 s in five runs over the websocket, 1.2 to 1.6 s over `--tcp`), and packets then came in every second or two. Helpers built before the fix in `add-to-kismet.sh` took about 5 s and sent in 5 s bursts over the websocket; to update, see [Guide: Updating](Guide-Updating). See [Remote Capture](Remote-Capture).


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

- `requirements.txt` asks for `pyserial>=3.5`, `msgpack>=1.0` and `websocket-client>=1.9.1`. That websocket-client needs **Python 3.10 or newer**. The helper has run with real boards on Python 3.13 (3.13.2 on Windows 11, 3.13.5 on Raspberry Pi OS with Debian 13), and its tests also on 3.12.3 (Ubuntu 24.04 in WSL2). On the Pi an earlier version of it also passed its tests and captured from a board on 3.10, 3.11 and 3.12. Python 3.9 cannot install `requirements.txt`; with websocket-client 1.8.0 instead, that earlier version's tests passed and a capture ran there too.
- On Linux a virtual environment is the way to use pip: Debian 12 and later and Ubuntu 23.04 and later refuse `pip install` into the system Python with `error: externally-managed-environment`. The distributions' own packages are older than `requirements.txt` asks for: Ubuntu 24.04 packages websocket-client 1.7.0 and Debian 13 packages 1.8.0.
- pyserial and msgpack are needed even for `--help` and `--list`. websocket-client is not needed with `--tcp`.
- The tests ran it as `python -m ...`. The Windows launcher's form, `py -m esp32c5_kismet.remote`, has not been tried.

### Usage

```text
usage: python -m esp32c5_kismet.remote [-h] [--connect HOST:PORT] [--tcp]
                                       [--ssl] [--ssl-certificate CAFILE]
                                       [--user USER] [--password PASSWORD]
                                       [--apikey APIKEY] [--endpoint ENDPOINT]
                                       [--source DEF] [--list] [--debug]
```

That is the usage in an 80-column terminal; Python wraps it to the terminal's width. `--help` goes on with the options, the forms of a source definition, the login from the environment, the exit status and examples.

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
| `--list` | off | List the boards plugged in and exit. Needs no `--connect`. On Linux, boards in use are left out. |
| `--debug` | off | Log every protocol message except packets. |
| `-h`, `--help` | | Print the usage and exit. |

Option names can be shortened while they stay unambiguous (`--conn`). When both a login and a key are given, the login wins, with the warning `ignoring --apikey and using the login`.

`localhost` is tried as `127.0.0.1` first, then `::1`, which is tried only when `127.0.0.1` refuses, cannot be reached or times out. The name itself stays in the request's `Host` header and in the TLS check. The reason: on Windows `localhost` resolves to `::1` first, and WSL2's port forwarder listens on `127.0.0.1` only, which cost earlier builds about 2 s per connection. Against Kismet in WSL2, `localhost` now connects as fast as `127.0.0.1` while Kismet is up; while it is down, each refused try takes about 2 s longer, since both addresses are tried. Docker Desktop was not measured.

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

On the Raspberry Pi and on Windows, the environment login worked in each of these ways against a real Kismet, a half login completed from the environment included, and with all three variables set the API key was used. On the Pi a systemd unit with `EnvironmentFile=` worked too. The login and the key go in the request's headers, as the C helper's do ([see the note above](#environment-variables)); on the Pi that was checked through a proxy that logs every request.

### --list

Output goes to stdout. The helper finds boards by USB ID and never opens a port. On Windows:

```text
COM14  F0:F5:BD:01:02:03
    --source esp32c5-COM14
    --source esp32c5zigbee-COM14
    --source esp32c5btle-COM14
One source per board: it captures with one radio at a time. Every ESP32 on its native USB port has this USB ID, so a board listed here need not be an ESP32-C5 sniffer.
```

On Linux the lines read `/dev/ttyACM0  F0:F5:BD:01:02:03` and `--source esp32c5-ttyACM0`, as on the Raspberry Pi. A board whose USB serial number is not a MAC shows `(no MAC in its USB serial number)`. A listed port that no short name can reach would get `--source esp32c5:device=<port>,mode=wifi` and the like. With nothing plugged in: `No Espressif USB-Serial-JTAG device (USB ID 303a:1001) found.` and exit code 1.

On Linux, a board whose port another capture holds is left out, all three lines, as the C helper's `--list` leaves it out, and a line after the list names it: `Left out, in use by another capture: /dev/ttyACM1`. When every board is left out, the list ends with that line and exit code 1. The helper reads that from `/proc/locks`, so it misses a lock taken in another container. On Windows, and elsewhere, every board is listed, in use or not: only opening the port could tell, and that can reset the board.

### Exit codes

| Code | When |
|---|---|
| 0 | `--help`; `--list` listed at least one board; stopped with Ctrl+C, Ctrl+Break or SIGTERM, also when it comes again while the helper stops |
| 1 | `--list` listed no board (none plugged in, or on Linux every one in use); an internal error (`every source thread has died, which is an internal error; stopping`) |
| 2 | a command-line or definition error; a proxy the websocket would go through (`http_proxy`, `https_proxy`, or in capitals) that cannot be read; websocket-client missing without `--tcp` |

A source never stops by itself. One whose board is missing or whose Kismet server cannot be reached logs why and tries again every 5 s. On Linux, one whose port another capture holds logs a single WARNING, `<name>: <port> is already in use by another capture; not offering it to Kismet until it is free (looked at again every 5 seconds)`, and looks at the port again every 5 s. So under a service manager such as systemd, exit code 1 means something went wrong inside the helper, and `Restart=on-failure` starts it again.

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
| `the proxy in http_proxy is not http://HOST:PORT with a port up to 65535` | The proxy the websocket would go through, in `http_proxy`, or `https_proxy` with `--ssl` (or either in capitals), cannot be read: its port is not a number or is above 65535, or the address is malformed. The message names the variable but never shows its value, which may hold a password. Not given for `localhost`, `127.0.0.0/8`, `::1`, a host `no_proxy` covers, or `--tcp`, which use no proxy. |
| `esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14` | Two definitions for one board. |
| `esp32c5:mode=wifi and esp32c5:mode=zigbee name no port, so both would take the same board; ...` | Two definitions without a port. |
| `esp32c5-COM14:channel=15: esp32c5-COM14: channel=15 is not a channel the board can tune to in wifi mode` | A `channel=` the radio does not have. The whole definition comes first. |
| `esp32c5-COM14:mode=lora: unknown mode 'lora': use wifi, zigbee (802154, 802.15.4, thread) or btle (ble, bluetooth)` | A `mode=` that is not a radio. |
| `esp32c5-COM14:zigbee: option 'zigbee' has no value` | A piece without `=` right after the `:`, before any option. Write `mode=zigbee`. |

Warnings that do not stop it:

- `ignoring the user, password and API key in legacy TCP mode` (only for a login on the command line; one in the environment is ignored without a word)
- `ignoring --apikey and using the login`
- `the Kismet user name holds ':' and the login '&': Kismet reads a user name in an Authorization header only up to its first ':', and cuts a login in the websocket's address at every '&' (after decoding it), so this one cannot log in either way; use an API key (--apikey or KISMET_CAP_APIKEY) instead of the login`, the C helper's warning word for word (see [the note on logins](#environment-variables))
- `port 3501 is Kismet's legacy TCP port; did you mean --tcp, or port 2501?`
- `<definition>: the comma list in channels= is not in double quotes, so Kismet reads only its first item and takes the rest for another option; write channels="1,6,11"` (see [Source Definitions](Source-Definitions) for quoting in PowerShell and cmd)
- `<definition>: <port> is not there; is the board plugged in? (waiting for it)`, for a named port that is not there yet, such as `esp32c5-COM99: COM99 is not there; is the board plugged in? (waiting for it)`
- `<definition>: <reason> (will keep looking)`, for a definition that names no port when no board, or more than one, is found

Connection errors, logged as `ERROR: <definition>: ...`, each on one line, and tried again every 5 s ([Troubleshooting](Troubleshooting#the-login-is-refused)):

- `Kismet refused the websocket: 401 Unauthorized (check the login -- --user/--password or KISMET_CAP_USER/KISMET_CAP_PASSWORD -- or the API key -- --apikey or KISMET_CAP_APIKEY; the key needs the datasource role)`, for HTTP 401; other refusals give only the status, such as `Kismet refused the websocket: 404 Not Found`
- `the websocket was answered with a redirect (HTTP <status> to <where>), which the helper does not follow: Kismet never redirects it, and the login would go along to wherever it points; check --connect, --endpoint and --ssl`, with `<where>` written as in the C helper's line ([its messages above](#messages-from-the-framework)). This is for 301, 302, 303, 307 and 308; another 3xx answer is reported as `Kismet refused the websocket: <status> <reason>`.

### Logging

The log goes to stderr, one line per event: `HH:MM:SS LEVEL: message`. For example:

```text
13:58:30 INFO: esp32c5-COM14:name=desk-wifi: connected, offering it to Kismet as E5C50001-0000-0000-0000-F0F5BD010203
13:58:30 INFO: esp32c5-COM14:name=desk-wifi: opening COM14 for wifi
13:58:30 INFO: desk-wifi: COM14 opened
13:58:31 INFO: desk-wifi capturing (wifi)
```

The board's own statuses start with the source's name: `name=` if the definition has one (here `desk-wifi`), otherwise the part before the `:`, such as `esp32c5-COM14`. Kismet's log shows them as `<source name> - <status>`. This is what real boards gave on Windows and on the Raspberry Pi.

When the websocket goes through an HTTP proxy from the environment, the helper says so at start, for example `the websocket to 192.168.1.50 goes through the HTTP proxy in http_proxy (<proxy host>:<port>)`. It does not for `localhost`, `127.0.0.0/8`, `::1` or a host `no_proxy` covers, which it never sends through a proxy ([Remote Capture](Remote-Capture#security-and-firewalls)).

`--debug` adds every protocol message except packets (`-> KDS_OPENREPORT, 269 bytes`, `<- KDS_CONFIGREQ seqno 2`), the stop signal received, and where the login came from.

### Stopping

- **Windows:** press Ctrl+C, or Ctrl+Break, in the helper's console window. In Git Bash, a helper started in the background with `&` also stops on `kill -INT <pid>`. For a helper you cannot reach, `taskkill /F /PID <pid>` is safe: the COM port is released at once. Without `/F`, Windows refuses: `This process can only be terminated forcefully (with /F option).`
- **Linux:** Ctrl+C, or SIGTERM (`kill <pid>`, `systemctl stop`). macOS has not been tried.

It logs `INFO: stopping` and `<definition>: connection ended: stopped` for each source connected at the time, closes every connection and port, and exits with 0. Pressing Ctrl+C or Ctrl+Break again, or sending another SIGTERM, while it stops changes nothing: it still exits with 0. Kismet then shows the source in error with the reason `websocket connection closed`; that is expected.

With a real board on Windows, feeding Kismet in WSL2, the current helper stopped with 0 on one, two or three presses of Ctrl+C or Ctrl+Break: in about 0.2 s at most while it captured, and in 1.21 s at most when the stop came while a refused connection was still failing. An earlier build stopped in 0.06 to 0.55 s from PowerShell, cmd and Git Bash, and `kill -INT` stopped one that Git Bash had started in the background in about 0.5 s. On the Pi, with real boards, SIGTERM stopped it with 0, about 0.1 s after `stopping` with one source; the current helper, with four sources, was gone within 0.31 s of the signal, and a second SIGTERM during the stop was ignored. The unit tests and `tests/remote_e2e.sh`, which stops the helper with SIGTERM and SIGINT, cover the stop too.

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
- The `helper` role hands the login to `kismet_cap_esp32c5` through `KISMET_CAP_*` in its environment, never on its command line. `KISMET_APIKEY` wins; otherwise `KISMET_USER` and `KISMET_PASSWORD` are used. Any character works in them, `&`, spaces and `%41` included, except for the one login that cannot log in (see [the note on logins](#environment-variables)): a `KISMET_USER` with `:` in it together with an `&` in either. That one is refused with `helper: a KISMET_USER with ':' in it cannot log in over remote capture when KISMET_USER or KISMET_PASSWORD holds '&'; use KISMET_APIKEY`, exit 2. Without either kind of login: `helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD`, exit 2.
- The `helper` role does not wait for a first board, but like the `kismet` role it checks the board list again every 2 s until two checks agree, at most 10 s, unless `ESP32C5_WAIT=0` or `KISMET_SOURCES` is set. With none found and `KISMET_SOURCES` empty it prints `helper: no ESP32-C5 board found and KISMET_SOURCES is empty` and exits 1; compose's `restart: unless-stopped` then starts it again.

| Variable | Default | Role | Meaning |
|---|---|---|---|
| `KISMET_SOURCES` | empty | kismet, helper | Source definitions separated by spaces. Empty: one source per board found. |
| `ESP32C5_MODE` | `wifi` | kismet, helper | The radio for boards found by themselves: `wifi`, `zigbee` or `btle`. |
| `ESP32C5_WAIT` | `30` | kismet, helper | kismet: seconds to wait at start for a board, then until no more turn up (up to 10 s longer). helper: no wait for a first board, only the wait until no more turn up. `0` turns both off. compose.yaml passes it to the `kismet` and `helper` services, default `30`. |
| `KISMET_USER`, `KISMET_PASSWORD` | empty | kismet, helper | kismet: the web login, written at every start. helper: the remote-capture login when there is no API key. They work only as a pair. |
| `KISMET_SERVER` | none | helper | `HOST:PORT` of the Kismet to feed, on its web port. Required. |
| `KISMET_APIKEY` | empty | helper | An API key with the `datasource` role. Wins over the login. |
| `ESP32C5_DEMO` | `wifi` in the demo image | kismet | The fake board's radio: `wifi`, `zigbee` (or `802154`) or `btle` (or `ble`). Empty turns it off. With the fake board running, the entrypoint does not look for boards. |

<!-- VERIFY: the look again until two checks agree, with boards that come up one after another during the ESP32C5_WAIT wait (a hub), and a capture started from the exec role ("anything else"), have not been tried with real boards; the Pi's Docker tests (results/pi-docker-test.log, and the current image on 2026-10-02) covered four boards found at start, the demo leaving the host's boards alone, by-id links and the missing-rule hint -->

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
docker run --rm -p 127.0.0.1:2501:2501 -e KISMET_USER=demo -e KISMET_PASSWORD=demo esp32c5-kismet:demo
docker run --rm esp32c5-kismet kismet_cap_esp32c5 --list
docker run --rm esp32c5-kismet kismet --version
```

On the Raspberry Pi, where the tested setup uses `sudo` rather than the `docker` group, put `sudo` before each of these. The `docker compose` lines also need the Compose plugin, which Debian's `docker.io` and `docker-buildx` packages do not include. See [Install with Docker](Install-with-Docker) for getting Compose, or for the plain `docker` route.

`kismet_cap_esp32c5 --list` reads only sysfs and `/proc/locks` and opens no port, so it works without any device access. A container that opens boards needs permission for the two USB serial device classes (166 is ttyACM, 188 is ttyUSB), and no added capability: `kismet_cap_esp32c5` drops every capability it has. compose.yaml sets the device rules. With plain `docker run`, the `kismet` service's equivalent is (change the port and the volume names if you like):

```bash
docker run -d --name esp32c5-kismet --restart unless-stopped --init --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet esp32c5-kismet
```

<!-- VERIFY: this docker run line is derived from compose.yaml and has not been run as written; the Pi's tests with four real boards (results/pi-docker-test.log, and the current image on 2026-10-02) used docker compose, and plain docker run only without the device rules -->

Without the device rules, the entrypoint names the missing one:

```text
[esp32c5-kismet] found ttyACM0 in sysfs but the container may not use it: allow it with
[esp32c5-kismet] compose.yaml's device_cgroup_rules, or docker run --device-cgroup-rule 'c 166:* rmw'
```

> **Note:** The image names in compose.yaml are `ghcr.io/oshri-almog/esp32c5-kismet:latest` and `:demo`. Until images are published there, compose builds them locally.

<!-- VERIFY: no image has been published yet (CI publishes only for a version tag or a manual run); check the ghcr.io names and tags (latest, <version>, demo) once one is -->

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
- It copies `datasource_esp32c5.h` and `capture_esp32c5/` into the tree, each file only when it differs from the tree's copy (`  copied <file>`), so that an unchanged file keeps its time and `make` does not rebuild Kismet for nothing. It registers the source in `kismet_server.cc`, `Makefile.in` and `configure.ac`, adds a `.gitignore` line, and applies seven upstream bug fixes to Kismet's capture framework (`capture_framework.c`, and `capture_framework.h` for two of them): a memory leak; websocket remote capture sending in 5 s bursts; a websocket closing at the wrong moment, which left the capture process holding its port and never reconnecting; the websocket login moved out of the address into the request's headers, with redirects refused (with libwebsockets 4.0 and later, without connecting to where they point); libwebsockets' `rejecting message on queue depth 40` warnings; an empty `INFO: ` line after every channel set; and the websocket request's `Host` header, which now carries the port. Each edit prints `  edited <file>`. It regenerates `configure` when `configure.ac` is newer than it (`  regenerating configure (needs autoconf and automake)`).
- It is safe to run again: every edit is skipped when it is already there, and a second run changes no file. Re-running it is how an updated helper gets into the tree.
- At the end it prints `Done. Now: cd <tree> && ./configure && make`.

| Message | Meaning |
|---|---|
| `usage: <script> PATH_TO_KISMET_SOURCE` | No argument. |
| `<path> does not look like a Kismet source tree` | No `kismet_server.cc` or `capture_framework.c` there. Exit 1. |
| `anchor not found, Kismet has changed: <anchor>` | This Kismet commit differs from the one the script knows (`cfe427074`). |
| `  capture_framework.c: <what> has changed, <fix> not fixed`, such as `  capture_framework.c: the websocket send path has changed, its 5 second bursts not fixed` (and `  capture_framework.c: cf_commit_packet not found, its metadata leak not fixed`; for the login, `  capture_framework.c: the websocket login has changed, it still goes in the URI`; for redirects, `  capture_framework.c: the websocket's connection has changed, where a redirect points still connected to`; for the `Host` header, `  capture_framework.c: the websocket's Host header has changed, its port not added`) | The code that fix replaces is not as the script expects, so that fix was skipped; the script carries on with the rest. |

After the script, run `./configure` again, with the options you used before. The script regenerates `configure`, so until then every `make` prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` That is only a notice, and `make` carries on. But a tree configured before the script's first run then builds Kismet without the helper, because its old Makefile does not know it: in a test on a freshly configured `cfe427074` tree, the script left a Makefile with no trace of the helper and no Makefile in `capture_esp32c5/`.

## esptool and idf.py

Commands for flashing the firmware from the command line. Without them, the [web flasher](https://oshri-almog.github.io/esp32c5-kismet-wifi-interface/) installs it from Chrome or Edge. See [Flashing the Firmware](Flashing-the-Firmware) for the full procedure. Replace `COM14` or `/dev/ttyACM0` with your board's port.

> **Warning:** Stop Kismet, the helpers and any serial monitor before you flash. esptool needs the port to itself.

### Flash the merged image

The merged image, `esp32c5-kismet-merged.bin`, goes at offset **0x0**. It holds the bootloader (at 0x2000), the partition table and the app. Building it is shown below; the build writes it to `firmware/build/`. The web flasher's site has it too, as `firmware/esp32c5-kismet-merged.bin`, and so does each release tagged since the flasher was added, as `esp32c5-kismet-<version>-merged.bin` ([Download the merged image](Flashing-the-Firmware#download-the-merged-image)); give the path of a downloaded file instead. Run these from the root of the repository:

```bash
# esptool v4, as shipped with ESP-IDF 5.5
python -m esptool --chip esp32c5 -p /dev/ttyACM0 -b 460800 write_flash 0x0 firmware/build/esp32c5-kismet-merged.bin
# esptool v5, from pip install esptool
esptool --chip esp32c5 -p /dev/ttyACM0 -b 460800 write-flash 0x0 firmware/build/esp32c5-kismet-merged.bin
```

- The underscore names (`write_flash`, `read_flash`, `verify_flash`, `erase_flash`, `merge_bin`) work in esptool v4 and v5; v5 prints a deprecation warning. The hyphenated names work in v5 only.
- `python -m esptool` works with both. The console command is `esptool.py` in v4 and `esptool` in v5.
- Flashing the merged image erases the board's stored radio, so it comes up in Wi-Fi.
- A board that was capturing 802.15.4 when it was flashed can come up deaf to Wi-Fi: it reports `capturing (wifi)` but sends nothing, and no error ever follows. An esptool reset does not cure it. It happened both times one test board was flashed from 802.15.4. Before you flash, run a Wi-Fi source on the board for a moment, then stop it; to cure a deaf board, run a BTLE source on it, then a Wi-Fi source again. See [Troubleshooting](Troubleshooting).
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
- `verify_flash` works in esptool v4 and v5 (v5 prints a deprecation warning). The test run used the v5 spelling, `esptool ... verify-flash 0x0 backup.bin`, and it reported `Verification successful (digest matched).`.
- A board that has booted this firmware no longer matches the merged image: at its first boot about 2.2 KB of the NVS partition (0x9000 to 0x991b) is written, where the image has 0xFF; what writes it was not identified. So `verify_flash 0x0 firmware/build/esp32c5-kismet-merged.bin` then fails with `Verification failed (digest mismatch).`. Verify before the board's first boot, or verify the image's first 0x9000 bytes at 0x0 and its app at 0x10000 separately ([Flashing the Firmware](Flashing-the-Firmware)); both parts matched on all four test boards.
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

This was run on a log of simulated boards on all three radios; the resulting pcapng holds one interface per source with link types 127, 230 and 256 ([Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark)). It has not been run on a log from real boards.

In the kismetdb log itself, the packets' `frequency` column is 0 for 802.15.4 and BTLE, whatever the helper sends: Kismet fills it in for Wi-Fi only. The device records have the right frequency.

## Test scripts

For development; see [Development and Testing](Development-and-Testing).

| Command | What it runs |
|---|---|
| `python tests/test_board.py` | Offline tests of the Python board link. No board needed. |
| `python tests/test_kismet_v3.py` | Offline tests of the Python remote helper's protocol, against a fake Kismet. `TEST_DEBUG=1` shows the helper's log. |
| `sh tests/c/run.sh [KISMET_TREE]` | The C helper's parser and logic tests. Needs a Kismet tree that went through `add-to-kismet.sh`, `configure` and `make` (default `$KISMET_SRC`, else `~/src/kismet`). Linux. Prints `ALL OK`. |
| `KISMET=~/kismet-install/bin/kismet sh tests/kismet_e2e.sh` | The fake board, the C helper and a real Kismet on port 2501. Stop any other Kismet first. Its TLS cases need `openssl`, and print SKIP without it. |
| `KISMET=~/kismet-install/bin/kismet PYTHON="$PWD/.venv/bin/python" sh tests/remote_e2e.sh` | The fake board, the Python remote helper and a real Kismet on ports 2511 (websocket) and 3511 (legacy TCP), so a Kismet on 2501 is left alone. `PYTHON` must be an absolute path to a Python with pyserial, msgpack and websocket-client, such as the virtual environment's. It also needs `curl`, `ss` and `ip`; its HTTP proxy cases print SKIP when the machine has no address but loopback. Linux or WSL2; it has run as root in WSL2 and as an ordinary user on the Raspberry Pi. Prints `ALL OK`. |
| `sh tests/docker_smoke.sh esp32c5-kismet:demo` | The demo image, every radio and the helper role. Uses host port 2599. On Windows in Git Bash: `PYTHON=python sh tests/docker_smoke.sh esp32c5-kismet:demo`. |

## Exit codes at a glance

Several of these look like failures and are not.

| Command | Exit code |
|---|---|
| `kismet --version`, `kismet --help` | 1 |
| `kismet_cap_esp32c5 --version` | 0 |
| `kismet_cap_esp32c5 --list` | 2, output on stderr |
| `kismet_cap_esp32c5 --help` | 255 |
| `python -m esp32c5_kismet.remote --list` | 0 with boards listed, 1 without |
| `python -m esp32c5_kismet.remote`, stopped | 0 |
| `python -m esp32c5_kismet.remote`, an internal error | 1 |
| `python -m esp32c5_kismet.remote`, a usage or definition error | 2 |
| Docker `helper` role without `KISMET_SERVER`, without credentials, or with a `KISMET_USER` holding `:` and an `&` in the login | 2 |
| Docker `helper` role with no board and no `KISMET_SOURCES` | 1 |
