# Fact sheet: the Python remote helper (`python -m esp32c5_kismet.remote`)

For the documentation writer. Everything here was read from the code or observed in a run; each fact says where.

## How to read this sheet

- **Snapshot.** Line numbers (`remote.py:123`) refer to a copy taken at 17:18 on 2026-09-28 (+0300). It is saved at
  `C:\Users\oshria\AppData\Local\Temp\claude\c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer\75fe8a4e-1aa2-48f3-9e8d-8f12a0275438\scratchpad\docs-facts\snap2\`.
  The repo paths are `esp32c5_kismet/remote.py`, `board.py`, `kismet_v3.py`, `requirements.txt` and `tests/test_*.py`.
  The md5 of each file:

  | file | md5 | modified |
  |---|---|---|
  | `esp32c5_kismet/remote.py` (1227 lines) | b80bf4d104924763058d0510cff67e9c | 17:15:42 |
  | `esp32c5_kismet/board.py` (828) | dfd4d9d429b38e03373b61d316791831 | 17:02:25 |
  | `esp32c5_kismet/kismet_v3.py` (339) | 363722e0b66627338267aa66f72c1489 | 17:05:42 |
  | `esp32c5_kismet/__init__.py` (`__version__ = "0.1.0"`) | 7b7e75319262c293c36b351655594b6a | 11:57 |
  | `requirements.txt` | d2bad9a5899ed40b6a8e98cd619a04b0 | 17:05:44 |
  | `tests/test_board.py` (564) | a16e110538b8516d651dd9294fa42d5c | 17:09:03 |
  | `tests/test_kismet_v3.py` (1214) | 4f7fbbf3c14e3ac858f9d8095770ba56 | 17:15:25 |

- **IN FLUX.** Another workflow is changing this now (P1-P17 below). The sheet records the *intended* behaviour.
  Nearly all of it is already in the snapshot code and passes the offline tests. None of it has been re-run on hardware or
  against a real Kismet since the changes.
- **UNVERIFIED.** Not confirmed by code or run. It may be true, but it must be checked before it is published.
- **"run"** means I ran the snapshot myself, read-only: port lists stubbed, no COM port opened, no Kismet, no Docker. The
  probe scripts are `docs-facts\probe.py` and `docs-facts\probe2.py`, and their output is quoted below.

---

## 1. What it is, and when to use it

- It is a pure-Python capture helper. It opens ESP32-C5 sniffer boards on this machine's serial ports and feeds each one to a
  Kismet server **elsewhere**, over Kismet's remote capture protocol v3. It supports the websocket on the web port (default)
  or the legacy TCP port (`remote.py:1-31` docstring).
- It exists mainly for **Windows**: Kismet does not run there, and Docker Desktop cannot see USB boards unless they are attached
  to WSL with usbipd (`compose.yaml:25-26`). It runs on any OS with Python and pyserial (`remote.py:3`).
- Each `--source` is **one board on one radio, with its own connection to Kismet** (`remote.py:8`).
- **It is not the Docker "helper" role.** `docker compose --profile helper up` runs the **C** helper `kismet_cap_esp32c5`
  (`docker/entrypoint.sh:207-253`, which calls `kismet_cap_esp32c5 --connect "$KISMET_SERVER" --source "$def"`). The image
  does not contain the Python package at all: `.dockerignore` admits only `kismet/`, `docker/` and `tools/fake_board.py`.
- **The Kismet server must know the `esp32c5` source type.** The helper announces itself as source type `"esp32c5"`
  (`remote.py:55`, sent in NEWSOURCE). A Kismet built from source with `kismet/add-to-kismet.sh` has that type, as does the
  project's Docker image (`kismet/datasource_esp32c5.h`: `set_source_type("esp32c5")`, `set_remote_capable(true)`).
  - What a stock Kismet does with an unknown type: UNVERIFIED. It presumably refuses the source.
- The helper follows the C helper's names and rules on purpose ("These are the names and rules of kismet_cap_esp32c5, the C
  helper", `remote.py:19`). Section 13 lists where the two still differ.

## 2. Requirements and installation

- **`requirements.txt`**, exactly:
  ```
  pyserial>=3.5
  # Kismet's v3 external protocol is msgpack; C-accelerated wheels for Windows, Linux and macOS
  msgpack>=1.0
  # Websocket remote capture (the default); synchronous, pure Python, fits the threaded board link.
  # 1.9.1 is the first whose abort() survives a connection the peer has reset; the helper copes with older
  # ones (Ubuntu 24.04 packages 1.7.0), but this is what pip should bring.
  websocket-client>=1.9.1
  ```
  - The floor was `websocket-client>=1.6` before today (`scratchpad\py-before\requirements.txt`). IN FLUX (P5).
- **Python version.** websocket-client 1.9.1 and 1.9.2 declare `Requires-Python: >=3.10`, and 1.9.0 declares `>=3.9` (from
  the wheel METADATA in `scratchpad\linwheels\`, `scratchpad\wsv\`). So `pip install -r requirements.txt` needs **Python
  3.10 or newer**.
  - The helper's own code needs at least 3.7 (`time.time_ns()`, `board.py:678`).
  - `--tcp` mode does not import websocket-client (`remote.py:554`, the import sits inside `WsTransport`).
  - The minimum Python has never been tested. Only 3.13.2 (Windows) and 3.12 (WSL, Ubuntu 24.04) have run it. UNVERIFIED.
- **pyserial and msgpack are always required.** `board.py:27` imports `serial` and `kismet_v3.py:18` imports `msgpack` at
  module load, so even `--help` and `--list` fail with ModuleNotFoundError without them.
  - Without websocket-client (and without `--tcp`) the helper stops with: `error: the websocket protocol needs
    websocket-client (pip install websocket-client), or use --tcp`, exit 2 (`remote.py:1186-1188`; run: test_kismet_v3.py
    "no websocket-client").
- **There is no package to install.** There is no `setup.py` or `pyproject.toml` in the repo (run: repo listing). Run it
  **from the repo root**, so that `esp32c5_kismet` can be imported:
  ```
  cd esp32c5-kismet-wifi-interface
  python -m pip install -r requirements.txt
  python -m esp32c5_kismet.remote --list
  ```
  - All test launches ran it that way, with `cwd` set to the repo root (`scratchpad\launch.py`, `runhelper.sh`).
  - Whether `py -m ...` (the Windows Python launcher) works equally: UNVERIFIED, but the call is standard.
- **Versions on the Windows test PC** (run): Python 3.13.2, pyserial 3.5, msgpack 1.2.2, websocket-client 1.9.2.
- **The Ubuntu 24.04 trap.** Its packaged `python3-websocket` is 1.7.0 (`apt-cache policy`, in `windows-review.txt` W3). An
  apt-installed 1.7.0 satisfied the old `>=1.6` floor, so pip would not upgrade it. The helper now survives old versions
  anyway (P5), but the docs should still say to use pip, or a venv.

## 3. Command line reference

### 3.1 `--help` output (run, `COLUMNS=100`, exit 0)

```
usage: python -m esp32c5_kismet.remote [-h] [--connect HOST:PORT] [--tcp] [--ssl]
                                       [--ssl-certificate CAFILE] [--user USER]
                                       [--password PASSWORD] [--apikey APIKEY]
                                       [--endpoint ENDPOINT] [--source DEF] [--list] [--debug]

Send ESP32-C5 sniffer boards to a Kismet server over remote capture.

options:
  -h, --help            show this help message and exit
  --connect HOST:PORT   Kismet server; the websocket on its web port (2501) unless --tcp
  --tcp                 legacy TCP remote capture protocol (port 3501)
  --ssl                 wss:// instead of ws://
  --ssl-certificate CAFILE
                        CA certificate to check the server with (implies --ssl)
  --user USER           Kismet login, with --password (or KISMET_CAP_USER and KISMET_CAP_PASSWORD)
  --password PASSWORD
  --apikey APIKEY       Kismet API key with the datasource role, instead of a login (or
                        KISMET_CAP_APIKEY)
  --endpoint ENDPOINT   websocket path, for Kismet behind a proxy
  --source DEF          source definition; repeat for more boards or radios
  --list                list the boards plugged in and exit
  --debug               log every protocol message except packets
```
Defined at `remote.py:1134-1151`. Argparse accepts unambiguous prefixes (`--conn`), since `allow_abbrev` is left at its
default. The `--user`/`--apikey` help text mentions the environment variables, which is new today: IN FLUX (P17).

### 3.2 Each option

| Option | Default | What it does | Source |
|---|---|---|---|
| `--connect HOST:PORT` | none; required unless `--list` | The Kismet server. The port is **Kismet's web port (2501)** for the websocket, or **3501** with `--tcp`. `HOST:PORT` is split at the **last** colon; `[::1]:2501` gives `::1`; the port must be all digits. | `remote.py:1023-1027`, `1137` |
| `--tcp` | off | Legacy TCP remote capture: raw frames on a TCP stream, **no login**. User, password and API key are ignored with a warning. Cannot be combined with `--ssl`. | `remote.py:521-547`, `1165-1170` |
| `--ssl` | off | `wss://` instead of `ws://`. | `remote.py:1065` |
| `--ssl-certificate CAFILE` | none | CA file to check the server with; passed as websocket-client `sslopt={"ca_certs": CAFILE}`. **Implies `--ssl`.** | `remote.py:1064`, `1165` |
| `--user USER` / `--password PASSWORD` | none | Kismet web login. The two must come together. Sent as the query `user=<u>&password=<p>`, each percent-encoded with `quote(..., safe="")`. | `remote.py:1060-1061`, `1175-1176` |
| `--apikey APIKEY` | none | Kismet API key, which needs the **datasource** role (help text). Sent as the query `KISMET=<key>`, percent-encoded. When both are given, the login wins, with the warning `ignoring --apikey and using the login`. | `remote.py:1063`, `1181-1182` |
| `--endpoint ENDPOINT` | `/datasource/remote/remotesource.ws` | Websocket path, for Kismet behind a reverse proxy. | `remote.py:57`, `1146` |
| `--source DEF` | none; required with `--connect` | One source definition (section 5). Repeat it for more boards; each source gets its own connection. | `remote.py:1147` |
| `--list` | off | Lists the boards and exits (section 4). It needs no `--connect` and no websocket-client. | `remote.py:1120-1131`, `1155-1156` |
| `--debug` | off | Log level DEBUG instead of INFO (section 9). | `remote.py:1150-1153` |

**The websocket URL it builds** (`remote.py:1055-1067`):
`ws://<host>:<port>/datasource/remote/remotesource.ws?KISMET=<apikey>`, or `?user=<u>&password=<p>`. An IPv6 host goes in
brackets. The handshake sends the header `Sec-WebSocket-Protocol: kismet-remote`, added by hand because Kismet does not echo
it back (`remote.py:557-561`; run: test_kismet_v3.py "WS: the endpoint and the API key" expects
`GET /datasource/remote/remotesource.ws?KISMET=k3y%2F%2B%3D HTTP/1.1`).

**Login from the environment** (`login_from_env`, `remote.py:1070-1085`): IN FLUX (P17).
- It applies only when none of `--user`, `--password`, `--apikey` is given and `--tcp` is not set.
- It takes `KISMET_CAP_APIKEY` first. Failing that, it takes `KISMET_CAP_USER` **and** `KISMET_CAP_PASSWORD`, both
  non-empty. A user without a password is ignored.
- Anything on the command line wins over the environment.
- With `--debug` it logs `the Kismet login comes from KISMET_CAP_APIKEY`, or `... from KISMET_CAP_USER and
  KISMET_CAP_PASSWORD` (`remote.py:1174`).
- The reason for it: an option on the command line "can be read by every user in the process list" (`remote.py:1072-1073`).
- These are the same names the C helper reads (`capture_esp32c5.c` header comment and its login function) and that
  `docker/entrypoint.sh:212,223` exports.
- Run: env `{KISMET_CAP_APIKEY:K, KISMET_CAP_USER:u, KISMET_CAP_PASSWORD:p}` gives apikey K; `{KISMET_CAP_USER:u}` alone
  gives nothing.

**Passwords with `&`, spaces or `%XX`.** `docker/entrypoint.sh:214-221` says "Kismet decodes the whole query string of the
remote capture URL before splitting it on '&', so these characters cannot get through, however they are escaped". It refuses
such a login and asks for an API key instead. The Python helper builds the same kind of query, so the same limit very likely
applies. It performs no such check itself. UNVERIFIED for the Python helper; recommend an API key in the docs.

**Connecting to `localhost`** (`connect_order`, `remote.py:1030-1034`; `_first_that_connects`, `1042-1052`): IN FLUX (P16).
- `localhost` (any case) is tried as **`127.0.0.1` first, then `::1`**. Other names and IPv6 addresses are used as given.
- It moves on to the next address only when a connection is refused, times out, or the address or network is unreachable
  (`ECONNREFUSED, EADDRNOTAVAIL, ENETUNREACH, EHOSTUNREACH, EAFNOSUPPORT`). A refused login (HTTP 401) does not fall through.
  When every address fails, the first error is the one reported.
- Why: on Windows, `localhost` resolves to `::1` first, and wslrelay (WSL) and Docker Desktop forward on IPv4 only. A
  `::1` attempt took about 2.05 s to be refused, so each connection took about 2 s longer and a refused one about 4 s
  (`windows-review.txt`, "PROBLEMS" list, localhost item).
- The docs can say `--connect localhost:2501` or `127.0.0.1:2501`. Before this change, `127.0.0.1` was the recommendation.

### 3.3 Command-line checks and their exact messages

All of these go to stderr as `python -m esp32c5_kismet.remote: error: <text>` after the usage lines, with **exit 2** (argparse
`p.error`). Run for the first six; the source lines are given.

| Situation | Message | Source |
|---|---|---|
| no `--connect`, no `--list` | `--connect HOST:PORT is required (or --list to see the boards)` | `remote.py:1158` |
| bad `HOST:PORT` | `expected host:port, not '127.0.0.1'` | `remote.py:1026` |
| no `--source` | `--source is required when connecting to Kismet` | `remote.py:1164` |
| websocket, no login anywhere | `a user and password, or an API key, are required for the websocket protocol (--user and --password, --apikey, or KISMET_CAP_APIKEY or KISMET_CAP_USER and KISMET_CAP_PASSWORD in the environment)` | `remote.py:1178-1180` |
| only one of `--user`/`--password` | `give both --user and --password` | `remote.py:1176` |
| `--tcp` with `--ssl` or `--ssl-certificate` | `--ssl needs the websocket protocol, not --tcp` | `remote.py:1170` |
| websocket-client missing | `the websocket protocol needs websocket-client (pip install websocket-client), or use --tcp` | `remote.py:1188` |
| a definition is wrong, or two want one board | the definition's error (section 5.6) | `remote.py:1190-1193` |

Warnings that do not stop the helper:
- `ignoring the user, password and API key in legacy TCP mode`
- `ignoring --apikey and using the login`
- `port 3501 is Kismet's legacy TCP port; did you mean --tcp, or port 2501?` (websocket mode with port 3501)

These are at `remote.py:1168, 1182, 1184`.

### 3.4 Exit codes

| Code | When | Source |
|---|---|---|
| 0 | `--help`; `--list` found at least one board; stopped by Ctrl+C, Ctrl+Break or SIGTERM | `remote.py:1131`, `1223`; run: probe2 (SIGINT and SIGBREAK returned 0), test_kismet_v3.py (SIGINT, SIGTERM, SIGBREAK) |
| 1 | `--list` found no board | `remote.py:1123-1124`; run |
| 1 | every source thread ended without a stop request; logs `ERROR: every source has stopped by itself`. IN FLUX (P5). In practice a source thread catches every exception and keeps retrying (section 8), so this is a safety net meant for a supervisor such as systemd `Restart=on-failure`. | `remote.py:1219-1222`; run: probe2 returned 1, test_kismet_v3.py "exit status 1" |
| 2 | any command-line or definition error (section 3.3) | argparse |

- Before today, the helper returned 0 even when every source had died (`py-before\...\remote.py` main).
- A Ctrl+C that arrives during startup, before the handlers are installed (`remote.py:1198`), gives Python's default
  KeyboardInterrupt traceback and exit code. Not specifically handled. UNVERIFIED.

## 4. `--list`

It finds boards by USB ID only and **never opens a port**. Each board is printed with its MAC and then three lines, one per
radio (`remote.py:1120-1131`, `board.py:449-468`). The boards come in natural order by device (COM2 before COM10;
`board.py:455-460`). Output goes to **stdout**.

Output with the port list stubbed (run, `probe.py`):
```
COM14  74:4D:BD:A1:B2:C3
    --source esp32c5-COM14
    --source esp32c5zigbee-COM14
    --source esp32c5btle-COM14
COM15  (no MAC in its USB serial number)
    --source esp32c5-COM15
    --source esp32c5zigbee-COM15
    --source esp32c5btle-COM15
One source per board: it captures with one radio at a time. Every ESP32 on its native USB port has this USB ID, so a board listed here need not be an ESP32-C5 sniffer.
```
- On Linux the lines read `/dev/ttyACM0  74:4D:...` and `--source esp32c5-ttyACM0`, `esp32c5zigbee-ttyACM0`,
  `esp32c5btle-ttyACM0` (run).
- A port that cannot be written as a name is printed as `--source esp32c5:device=/dev/serial0,mode=btle`
  (`short_definition`, `remote.py:203-208`; run).
- With nothing plugged in it prints `No Espressif USB-Serial-JTAG device (USB ID 303a:1001) found.` and exits 1. This came
  from a real run on this PC, which had no boards attached.
- The three names per board, and the wording, are new today. The old code printed `esp32c5-COM14:mode=wifi` and
  `No ESP32-C5 board found (looking for Espressif USB-JTAG, 303A:1001).`. IN FLUX (P2, P14).
- **What it matches.** Every port whose USB VID:PID is `303a:1001` (`board.py:30,454`). That ID is shared by every Espressif
  chip on its native USB-Serial-JTAG port (ESP32-C3, C5, C6, H2, S3, P4, ...), so other ESP32 boards show up too
  (`board.py:452-453`).
- **The MAC** is the board's USB serial number when it looks like a MAC, normalised to `AA:BB:CC:DD:EE:FF`
  (`board.py:446,463-468`). Real boards reported their MAC this way: COM32 = `38:44:BE:BF:C9:10`, COM30 = `10:BD:A3:CF:05:40`
  (`windows-review.txt` W1/W4; helper logs).
- **Platforms.** It uses pyserial's `list_ports.comports()`. Unlike the C helper's `--list`, which needs Linux sysfs, it
  should therefore work on Windows, Linux and macOS.
  - Windows and Linux: covered by tests and the Windows runs.
  - macOS and BSD: UNVERIFIED, never run. Whether pyserial on macOS reports `/dev/cu.*` or `/dev/tty.*` names is also
    unconfirmed.
- On Windows, a board that is **enumerated but wedged** (Windows error 31) is still listed with its MAC
  (`windows-review.txt` W1: "--list confirms the wedged COM30 still enumerates with its MAC").

## 5. Source definitions

### 5.1 Syntax

```
<interface>[:<option>=<value>[,<option>=<value>...]]
```
- `<interface>` must **start with `esp32c5`**, case-sensitively: `ESP32C5-COM14` is refused
  (`remote.py:270-271`; run: `the interface must start with esp32c5, not 'ESP32C5-COM14'`).
- The name reads `esp32c5<radio>-<port>`. IN FLUX (P2).
  - **Radio**: the text between `esp32c5` and the **first `-`**, case-insensitive:
    - `zigbee`, `802154`, `802.15.4` or `thread` mean 802.15.4;
    - `btle`, `ble` or `bluetooth` mean Bluetooth LE;
    - `wifi`, empty, or **anything else** means Wi-Fi.

    So `esp32c5foo-COM14` and `esp32c5-kitchen` are Wi-Fi (`remote.py:61-63,189-200`; run).
  - **Port**: what follows the first `-` (`remote.py:152-173`):
    - **Windows**: only `COM<n>`, in any case, normalised to `COM<n>` (`esp32c5-com7` → `COM7`). Any other name, such as
      `esp32c5-ttyACM0` or `esp32c5-kitchen`, names no port (run: test_kismet_v3.py "tty names mean nothing on Windows").
    - **Elsewhere**: `/dev/<name>`. A name starting with `tty` or `cu.` is taken as it is, even when absent, so a
      rebooting board is waited for. Any other name counts only if `/dev/<name>` is a character device (`cuaU0` on the
      BSDs). Otherwise it names no port, so `esp32c5-kitchen` works as a plain name. `esp32c5-COM3` names no port on
      Linux.
  - A name without a `-` names no port: `esp32c5`, `esp32c5zigbee`, `esp32c5kitchen` (run: test_kismet_v3.py).
- **Examples**, all from runs:
  - `esp32c5-COM14` is Wi-Fi on COM14; `esp32c5zigbee-COM14` is 802.15.4 on COM14; `esp32c5btle-ttyACM0` is BTLE on
    `/dev/ttyACM0`.
  - `esp32c5zigbee-COM14:mode=wifi` is **Wi-Fi**, because `mode=` wins over the name.
  - `esp32c5:device=com14,mode=btle` is BTLE on COM14.
  - `esp32c5` alone is Wi-Fi on the only board plugged in.

### 5.2 Options the helper reads

| Option | Values | Default | Meaning | Source |
|---|---|---|---|---|
| `mode=` | the radio aliases in 5.1, case-insensitive | from the name | The radio. **Wins over the name.** An unknown value is an error: `unknown mode 'lora': use wifi, zigbee (802154, 802.15.4, thread) or btle (ble, bluetooth)`. | `remote.py:189-200` |
| `device=` | a port | from the name, else the only board | The serial port. **Wins over the name.** On Windows `com14`, `COM14` and `\\.\COM14` all become `COM14`. Elsewhere the value is kept as typed, for example a `/dev/serial/by-id/...` link. | `remote.py:176-186` |
| `name=` | text | the interface | Kismet's name for the source. The helper also uses it in its own messages to Kismet. | `remote.py:238`, `863-881` |
| `uuid=` | a UUID | computed (5.4) | A fixed Kismet UUID. It also lets a named port that is absent be offered anyway (5.3). | `remote.py:301`, `322` |
| `dwell=` | integer ms, 20 to 60000 | 250 | Validated and sent to the board, but **it has no practical effect**: the helper only ever gives the board one channel at a time, and Kismet's hop rate sets the timing ("only used if the board is given several channels, which this helper never does"). | `remote.py:72`, `273-278`, `board.py:55` |
| `channel=` | a channel number | 6 (Wi-Fi), 15 (802.15.4), 37 (BTLE) | The channel to **start** on, and with `channel_hop=false` the one to **stay** on. Strict checking, see 5.5. IN FLUX (P3). | `remote.py:280-293` |
| `channel_hop=` | Kismet's | hop | The helper reads it only to know whether Kismet will hop the source: `false` or `f`, any case, means no. `no` and `0` count as hopping, which is how Kismet's string_to_bool reads it according to the code comment (UNVERIFIED against Kismet). | `remote.py:294-295` |

- Any other option (`channels=`, `channel_hop_rate=`, `info_*`, ...) is **Kismet's business**. The helper ignores it and
  raises no error (`remote.py:17-18`).
- The key is case-insensitive (`MODE=btle` works), and **the first of a repeated key wins** (`remote.py:114-141`; run:
  `mode=wifi,MODE=zigbee` gives wifi).

### 5.3 How the port is chosen, and a port that is not there (IN FLUX: P7, P9)

The order is `parse_definition`, `remote.py:259-324`:

1. `device=`, if given.
2. Otherwise the port in the name.
3. Otherwise, **for a definition that has found its board before, that board by its MAC**, wherever it is plugged in now
   (`pinned_mac`, `remote.py:306-310`).
4. Otherwise **the only** Espressif USB-Serial-JTAG device plugged in.

The messages (all run, `BoardNotFound`):
- none plugged in: `no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition`
- several plugged in: `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found (COM14, COM15), and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-COM14`
  - The suggested name follows the radio: `esp32c5zigbee-COM14` for a zigbee definition.
- pinned board gone: `the board 11:22:33:44:55:66 is not plugged in (waiting for it)`
- **a named port that does not exist right now**: `COM99 is not there; is the board plugged in? (waiting for it)`
  (`remote.py:298-302`).
  - "Exists" means different things per platform (`board.py:487-493`). On Windows the port must be in pyserial's
    list of present devices, which includes a wedged board that is still enumerated. Elsewhere `os.path.exists(path)`.
  - **`uuid=` skips this check**: the source is then offered even while the port is absent.
  - The reason: before this change, an absent board was offered under a made-up UUID, and Kismet counted it as a second
    source once the board came back (`windows-review.txt` W1/W4).

All of these are "not yet", not fatal. At startup each one gives a warning (5.6), and the source keeps trying every 5 s
(section 8).

### 5.4 Identity Kismet sees: UUID and hardware label (IN FLUX: P14)

- **UUID**: `E5C5000M-0000-0000-0000-<MAC>`, where M is 1 for Wi-Fi, 2 for 802.15.4 and 3 for BTLE, and `<MAC>` is 12
  upper-case hex digits without colons (`remote.py:219-223`).
  - Example: `E5C50001-0000-0000-0000-744DBDA1B2C3`.
  - Stable per board and radio, so Kismet recognises a source it has seen before.
  - **Without a MAC**, the port path as given stands in, hashed with 64-bit FNV-1a and truncated to 48 bits
    (`remote.py:211-216`). Example: `/dev/ttyACM0` → `E5C50001-0000-0000-0000-931F359CC900`.
  - `uuid=` overrides both.
  - It is the same as the C helper's `make_uuid()` for the same inputs. Run: test_kismet_v3.py "uuids as the C helper makes
    them" compares against values compiled from the C code (`C_UUIDS`, test lines 184-192).
- **Hardware label**: `Espressif USB-Serial-JTAG (74:4D:BD:A1:B2:C3)`, or `ESP32-C5` when no MAC is known
  (`remote.py:226-228`; run). The C helper uses the same label.
  - The old label was `ESP32-C5 (<MAC>)` (logs, `pi-run-notes.txt`). The docs must not say that every listed board is an
    ESP32-C5.
- **The MAC of a named port** is looked up whatever the port's spelling: `com14`, `\\.\COM14`, or a `/dev/serial/by-id/...`
  link resolved to its ttyACM with `realpath` (`board.py:471-502`; run: test_kismet_v3.py "a /dev/serial/by-id link gets the
  board's MAC"). Before today a by-id link lost the MAC and got a hashed UUID (`pi-run-notes.txt` item on remote.py:181).
- **The identity is kept across reconnects** (`RemoteSource.resolve`, `remote.py:961-983`):
  - A definition **with no port** follows its board by MAC, even after other boards are plugged in. It waits for that board
    and does not fall back to "the only board".
  - A **named** port whose board is briefly not identifiable keeps the MAC and UUID it had.
  - If a **different** board is on the named port now, the helper logs the warning
    `<def>: COM14 holds board <new MAC> now, not <old MAC>; Kismet will see it as another source (<uuid>)`
    (`remote.py:975-976`). It uses the new board's UUID, which is correct: it is another board.

### 5.5 `channel=`: strict (IN FLUX: P3)

The rule is at `remote.py:280-293`. It is checked **before any port is looked at**; run: test_kismet_v3.py "channel= is
checked before the port is looked for".

- It must be digits only and at most 177. Leading zeros are allowed (`0177` is 177, as `strtoul` reads it), and surrounding
  spaces are stripped.
- It must be a channel the radio can tune to:
  - **Wi-Fi**: 1-14, 36-64, 100-144 and 149-177, the last three in steps of 4. That is 42 channels (`board.py:77-93`; run).
  - **802.15.4**: 11-26.
  - **BTLE**: 37, 38 or 39 are accepted, and the source **stays on 37**. The controller scans all three advertising
    channels together and cannot be restricted to one.
- Refused values, all run: `channel=15` (Wi-Fi), `38` (Wi-Fi), `178`, `6HT40`, `+6`, `6.0`, `-6`, `27` (802.15.4), `6` and
  `40` (BTLE).
- The message, for example: `esp32c5-COM14: channel=15 is not a channel the board can tune to in wifi mode`.
- At startup this stops the helper with exit 2 (run: test_kismet_v3.py "a channel the radio lacks is refused at startup").
- The board starts on that channel, and Kismet is told it in the open report (`remote.py:758-777`). Run (probe2) for
  `esp32c5zigbee-COM14:channel=20,channel_hop=false`: OPENREPORT channel `"20"` with hop block `{enabled: False}`.
- `channel_hop=false` sends a hop block with enabled=false and no rate. That is the only thing that makes Kismet show the
  source as not hopping, even when Kismet remembers the UUID from an earlier session (`kismet_v3.py:214-244`).
- Before this change, `channel=` was ignored completely: `channel_hop=false,channel=20` left an 802.15.4 board on 15
  (`windows-review.txt` "PROBLEMS" list; `helper-review.txt:85`).

### 5.6 One board, one source (IN FLUX: P6, P8)

A board listens with one radio at a time, and each MODE change reboots it. So at most **one** source may use a board, and
the helper enforces that three ways.

1. **At startup**, `check_sources` (`remote.py:327-362`) refuses, with exit 2:
   - Two definitions that want the same port, however it is written: `com14`, `COM14` and `\\.\COM14` are one port, and so
     are a by-id link and its ttyACM. Message: `esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14`.
   - Two definitions that **name no port**. They could only ever take the same board, so they are refused whether or not
     a board is plugged in. Message: `esp32c5:mode=wifi and esp32c5:mode=zigbee name no port, so both would take the same board; say which with device= or a source name like esp32c5-<port>`.
   - Any wrong definition, as `<definition>: <error>`.
   - A board that is not there yet is only a warning, logged at startup:
     `WARNING: <def>: COM99 is not there; is the board plugged in? (waiting for it) (will keep looking)`.

   (Run for all of the above, probe.py and test_kismet_v3.py. The portless check moved to the front at 17:15, so no
   "will keep looking" warnings come first any more.)
2. **While running**, within one helper process (`PortClaims`, `remote.py:924-943`). The first source to resolve to a port
   keeps it **for the life of the process**, and the claim is never given up when a connection ends. A later source that
   resolves to that port is refused with `PortTaken`: `COM14 is esp32c5-COM14:mode=wifi's port already; a board captures
   with one radio at a time` (`remote.py:979-980`). It is logged as an ERROR every 5 s and never offered to Kismet (run:
   test_kismet_v3.py). A source whose board moved to another port gives up its old one.
3. **Across processes**, the port is opened **exclusively** (`board.py:365-412`).
   - POSIX: pyserial `exclusive=True`, which is an `flock` on the device node. It covers by-id links, and it is **the same
     lock the C helper takes**, so the C and Python helpers exclude each other.
   - Windows: COM ports are exclusive by nature, and "access denied" is read as busy.
   - A busy port gives: `COM14 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time`
     (`board.py:69-70`; run).
   - "Another program" includes serial monitors (`idf.py monitor`, PuTTY, Arduino IDE). The examples are mine; the code
     only says "a serial monitor", `board.py:350`.

### 5.7 Definitions Kismet rewrites (IN FLUX: P4)

Kismet does not send back the definition it was given. The OPENREQ carries **its own rewrite**: keys sorted, every value
unquoted, so `channels="1,6,11"` comes back as `channels=1,6,11`. The Windows test log shows an example:
`esp32c5-COM32:channel=20,channel_hop=false,mode=zigbee,name=win-zigbee` (`scratchpad\logs\t4lock.log`).

The helper reads definitions the way Kismet's `string_to_opts()` does (`split_definition`, `remote.py:114-141`):
- a comma inside double quotes does not separate options;
- quotes are dropped wherever they are in a value;
- a piece without `=` continues the previous option's value;
- a trailing comma is ignored;
- a *first* piece without `=` is an error: `option 'foo' has no value`.

`same_definition` (`remote.py:144-149`) treats the rewrite as the same source, so an OPENREQ carrying the rewrite opens the
source as it was announced, with the same port, radio and UUID (run: probe2 2c; test_kismet_v3.py "OPENREQ with Kismet's
rewrite").

For the writer: quote a value with commas on the command line (`name="lab, bench 2"`, `channels="1,6,11"`) and it survives
the rewrite. How to type the quotes in each shell (PowerShell, cmd, bash) is not documented anywhere. UNVERIFIED; worth one
tested example per shell.

## 6. What Kismet receives, per radio

| | Wi-Fi | 802.15.4 (Zigbee/Thread) | Bluetooth LE advertising |
|---|---|---|---|
| Board command | `MODE WIFI` | `MODE 802154` | `MODE BLE` |
| Link type from the board | 127 radiotap | 283 IEEE 802.15.4 TAP | 256 BLUETOOTH_LE_LL_WITH_PHDR |
| DLT sent to Kismet | **127**, unchanged | **230** (802.15.4 without FCS) with a signal block | **256**, unchanged (see the fix-up below) |
| Channels offered to Kismet | the 42 channels in 5.5 | `11`...`26` | `37` only |
| Start channel | 6 | 15 | 37 |
| UUID digit | 1 | 2 | 3 |

Sources: `remote.py:61-70`, `board.py:43-53`, `kismet_v3.py`.

- **802.15.4.** The board's TAP header is split apart (`rewrap_tap`, `remote.py:370-402`), because Kismet's TAP parser
  assumes a fixed 28-byte header and would misread the board's 48-byte one. The bare MAC frame goes to Kismet with a signal
  block that holds:
  - the channel;
  - the RSS in dBm, rounded half away from zero as C does;
  - the frequency in kHz, which is `(2405 + 5*(ch-11))*1000`.

  Records with a malformed TAP header are dropped and counted. The count is said at the 1st drop and every 1000th:
  `<name>: <n> 802.15.4 frames with a malformed TAP header dropped` (Kismet message at error level; helper log WARNING;
  `remote.py:878-883`).
- **BTLE fix-up for older firmware** (`fix_btle`, `remote.py:441-463`). IN FLUX (P11).
  - Kismet trusts a packet's CRC only when the pseudo-header says it was checked, and otherwise drops the packet.
  - Current firmware sets "CRC checked" (0x0400) and "CRC valid" (0x0800).
  - Older firmware (the published esp32c5-wireshark-sniffer builds) leaves both clear and the CRC zeroed. The helper then
    computes the CRC over the PDU, writes it, and sets both flags.
  - It says so **once per connection**, as a Kismet message and an INFO log line:
    `<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary`
    (`remote.py:867-873`).
  - A record too short to be BTLE (under 19 bytes) is dropped and counted: `<name>: <n> BTLE records of impossible length dropped`.
  - Run: test_kismet_v3.py "BTLE: ..." checks.
- **Other fields in Kismet's open report** (probe2 run): capture interface = the port as the helper opens it (`COM14`,
  `/dev/ttyACM0`); hardware label; UUID; version string **`esp32c5_kismet-0.1.0`** (`remote.py:56`).
- **Seen on real hardware (old code, still true).** Kismet marks nearly all BLE packets as duplicates: 1094 of 1099 in one
  minute. Advertisements repeat byte for byte, and Kismet deduplicates on content, so a BTLE device's packet count, last-seen
  time and signal stop updating after its first few packets. Every BLE packet also shows as channel 37 / 2402 MHz, because
  the firmware reports RF channel 0. This is upstream Kismet behaviour plus a firmware field, not the helper
  (`windows-review.txt`, "PROBLEMS" list, last item). It belongs in a BTLE guide or a "known limits" section.

## 7. Channels and hopping

- **Kismet does not hop a remote source itself.** It sends the helper a channel list plus a rate, shuffle and offset
  (CONFIGREQ), and the **helper retunes the board on its own timer**. It sends `CHANNELS <n>` to the board once per hop, the
  way `capture_framework.c` does for the C tools (`remote.py:25-26`, `470-514`, `788-826`).
  - Interval: `1/rate`, but **never less than 50 ms**, so at most 20 hops per second (`remote.py:79`, `491-493`).
  - A rate of 0 means no hopping.
  - Shuffle walks the list with a skip of 4, which is `HOP_SHUFFLE_SPACING`, so every channel is visited once in four laps.
    The walk starts at the offset Kismet gives; that offset is how Kismet splits one list among several sources.
  - Tests: test_kismet_v3.py "Hopping, without a clock".
- **A single channel from Kismet** (set in the UI, or a channel lock) cancels hopping and tunes the board to that channel.
- **A channel the radio lacks** in a single-channel request fails the config, and the connection closes (then reconnects):
  `<ch> is not a channel the board can tune to in <mode> mode`.
- **A hop list with some channels the radio lacks**: those are dropped and Kismet is told, at error level (probe2 run):
  `Removed 2 channels from the channel list because the source could not tune to them: 15, 38`.
  - If **none** can be tuned, the config fails and the connection closes:
    `none of the channels 15,6HT40 can be tuned in wifi mode` (probe2 run).
- **BTLE** accepts any channel request or hop list and ignores it (`remote.py:827-839`). A single-channel request is
  reported back as the channel asked for.
- **The Wi-Fi list includes 12-14 and 169-177**, which are not legal everywhere. The helper offers what the radio can tune
  to; staying within local rules is the operator's job (for example Kismet's `channels=`). The code states no legal
  position; this is the writer's point to make.
- Kismet's default hop rate for these sources is not recorded here. Kismet's usual default is `channel_hop_speed=5/sec`
  (UNVERIFIED for this build).

## 8. Connections, reconnects, backoff, timeouts

### 8.1 Timing constants

| Constant | Value | Meaning | Source |
|---|---|---|---|
| `RECONNECT_BACKOFF_S` | 5 s | Wait after any failed attempt or ended connection before offering the source again. | `remote.py:75`, `1010` |
| `PING_TIMEOUT_S` | 15 s | No PING from Kismet for this long ends the connection: `no PING from Kismet for 15 s`. Kismet pings about every 5 s. | `remote.py:74`, `699-702` |
| `SOCKET_TIMEOUT_S` | 30 s | Socket timeout for connect and receive. | `remote.py:76`, `525`, `560` |
| `SYNC_TIMEOUT_S` | 15 s | An opened board not capturing for this long gives the source up (8.3). | `remote.py:73`, `699-713` |
| `FIRST_OPEN_WAIT_S` | 2 s | How long an OPENREQ waits for the board's first open attempt. | `remote.py:77`, `766` |
| `STATUS_REPEAT_S` | 10 s | The same board error goes to Kismet at most this often. | `remote.py:78`, `893-918` |
| `START_RETRY_S` | 2 s | The board handshake is repeated this often until the stream syncs. | `board.py:61` |
| `STALL_TIMEOUT_S` | 6 s | Before sync, a port that sends no bytes at all for this long is closed and reopened: `no answer for 6 s, reopening`. Never applied once synced, when silence is just a quiet channel. | `board.py:62`, `735-739` |
| `MODE_SETTLE_S` | 0.8 s | Wait between `MODE` and `START`. IN FLUX (P12). | `board.py:67` |
| board reopen wait | 1 s | After a port error, wait 1 s before trying the port again. | `board.py:822` |
| stop joins | 5 s per source (connection 2 s, board 3 s, hopper 2 s) | Upper bounds while stopping. | `remote.py:1216-1219`, `684-685`, `852` |

### 8.2 The life of one source (`RemoteSource.run`, `remote.py:985-1010`)

Each source loops until it is stopped:

1. **Resolve the definition** (section 5): find the port and board and claim the port. This happens before every
   connection, "which is how a board plugged in later is found" (`remote.py:988-989`).
   - On `BoardNotFound`, `PortTaken`, another `DefinitionError`, or an OSError while connecting, it logs
     `ERROR: <definition>: <message>`, waits 5 s and tries again. **Kismet is not contacted at all while the board is
     missing.**
2. **Connect** to Kismet. The log shows `INFO: <definition>: connected, offering it to Kismet as <uuid>`, and NEWSOURCE is
   sent.
3. Kismet sends **OPENREQ**. The helper starts the board link and waits up to 2 s for the first open attempt (IN FLUX, P10).
   - If the port cannot be opened, the open report **fails with the OS error**, and Kismet shows that as the source's
     error. The connection then closes, and the loop reconnects after 5 s. Probe2 run:
     - busy: `COM14 is already in use by another capture (...)`
     - Windows error 31: `could not open port 'COM14': OSError(22, 'A device attached to the system is not functioning.', None, 31)`
   - Otherwise the open succeeds and the log shows `INFO: <definition>: opening COM14 for wifi`.
   - Before this change the open report said success before the port had been tried. A wedged board then showed as
     "running" for about 15 s of every 22 s, and the real error never reached Kismet (`windows-review.txt` W5).
4. **Stream** until something ends the connection: Kismet closes it, a PING goes missing, a send fails, the board stops
   syncing, a config fails, Kismet sends SHUTDOWN, or the helper is stopped. Then
   `INFO: <definition>: connection ended: <reason>`, a 5 s wait, and back to step 1.
5. **Nothing that goes wrong in one connection ends the source.** Exceptions in a connection are caught and logged
   (`<definition>: connection failed` with a traceback), and the loop goes on (`remote.py:999-1009`).
   - The websocket close is best-effort (`remote.py:586-594`). websocket-client before 1.9.1 raised ENOTCONN on Linux after
     a connection reset, which killed the source for good (`windows-review.txt` W3, reproduced with 1.7.0, 1.8.0 and 1.9.0).
   - Run: test_kismet_v3.py "an exception in a connection does not end its source". IN FLUX (P5).

### 8.3 Board trouble while connected (`board.py` `BoardLink`, `remote.py:699-713`)

- **The board reboots** (on every radio change): the link reads through it and asks again. MODE goes first, and START
  follows **0.8 s later** so it is not lost during the ~0.53 s the board is deaf (IN FLUX, P12; `board.py:663-680`, `714-739`).
  - A resync while the board is already on the right radio skips MODE (`board.py:728-731`).
- **The stream loses sync** (damaged record, restart): the link resyncs by itself. It uses the same parser rule as the C
  helper, and frames on the air that happen to contain the restart signature cannot fake a restart (IN FLUX, P1;
  `board.py:246-342`).
- **Unplugged or re-enumerated**: the link retries the port every ~1 s. A reopened port is checked to still hold the same
  board, by MAC. If it holds another board, the helper looks for its own board by MAC for that attempt, while the configured
  port stays the one tried first (IN FLUX, P9; `board.py:747-784`). The messages:
  - `COM14 now holds another board, looking for <MAC>`
  - `board <MAC> is on COM15 now`
  - The identity check works on Linux (sysfs via the open fd) and Windows (device list). On macOS and BSD it cannot tell
    and trusts the port (`board.py:544-576`); UNVERIFIED there.
- **Not capturing for 15 s** after the open, or since the last loss of sync: the helper gives the source up with an ERROR and
  a SHUTDOWN to Kismet, closes the connection and reconnects after 5 s. The reason reads
  `the board on COM14 has not been capturing for 15 s (last: <the board's last status>)` (`remote.py:709-713`; run:
  test_kismet_v3.py "the sync timeout says what the board last said").
  - In Kismet the source then shows `remote connection triggered shutdown: <reason>` as its error (`windows-review.txt`
    W5, observed with a live Kismet).
- **If the board is gone for good**, a named port is then waited for at step 1 (`COM14 is not there; ...`), every 5 s. It
  is not followed to another port at that level. A definition with no port waits for its MAC.
  - Practical advice for Linux docs: name boards by `/dev/serial/by-id/...` or leave the port out, so a board that returns
    as another ttyACM is still found. This is my inference from the code; UNVERIFIED on hardware.

### 8.4 Kismet trouble

- **Kismet not running, or refusing**: `ERROR: <def>: [WinError 10061] No connection could be made because the target machine actively refused it`
  on Windows (`scratchpad\logs\t5d.log`), `[Errno 111] Connection refused` on Linux. Retried every 5 s, plus the time the
  attempt itself takes.
- **Kismet restarted or killed mid-stream**: `connection ended: Connection to remote host was lost.` (t5d.log, old code)
  or a reset. The helper reconnects when Kismet is back, and Kismet recognises the source by its UUID.
- **Login refused (HTTP 401)**: `Kismet refused the websocket: <websocket-client's text> (check --user/--password, or --apikey: the key needs the datasource role)`
  (`remote.py:562-565`). Retried every 5 s. The exact text websocket-client puts in `<...>` is UNVERIFIED.
- **Kismet sends SHUTDOWN**: `connection ended: Kismet shut the source down: <reason>` (`remote.py:733`).

## 9. Logging and `--debug`

- **Format**: `HH:MM:SS LEVEL: message`, time only with no date (`logging.basicConfig(format="%(asctime)s %(levelname)s: %(message)s", datefmt="%H:%M:%S")`,
  `remote.py:1152-1153`). Levels are DEBUG, INFO, WARNING and ERROR.
  - It goes to **stderr**. `--list` output goes to stdout.
  - Example: `14:36:23 INFO: esp32c5-COM32:mode=wifi,name=docker-win-wifi: connected, offering it to Kismet as E5C50001-0000-0000-0000-3844BEBFC910`
    (`scratchpad\helper1.log`).
- **Without `--debug`** (INFO) you see:
  - connected, opening, and connection-ended lines;
  - board status (`COM32 opened`, `COM32 capturing`, `COM32: lost sync (<why>)`, `<port>: <error>`,
    `<busy text>; waiting for it`);
  - messages from Kismet as `INFO: Kismet: <text>`, and Kismet's errors as `ERROR: Kismet: <text>`;
  - `stopping`;
  - the warnings and errors quoted elsewhere in this sheet.
- **With `--debug`**, in addition (`remote.py:643`, `720`, `903-910`, `1099`, `1174`):
  - every frame sent **except packets**: `-> KDS_OPENREPORT, 269 bytes`, `-> CMD_MESSAGE, 37 bytes`, and
    `-> CMD_PONG, 20 bytes` about every 5 s per source;
  - every frame received **except PING and PONG**: `<- KDS_OPENREQ seqno 1`, `<- KDS_CONFIGREQ seqno 2`;
  - the board statuses held back by throttling;
  - `stop signal SIGINT`, `SIGTERM` or `SIGBREAK`;
  - `the Kismet login comes from ...`;
  - errors while closing the transport.
  - Real debug output: `scratchpad\helper1.log`, `helper99.log`, `logs\t*.log` (all from the old code, but the line shapes
    are unchanged).
- **Board status sent to Kismet** as messages (IN FLUX, P10; `remote.py:893-918`). Run, probe2 and test_kismet_v3.py:
  - `opened`, `capturing` and `lost sync` go once per change between them. A port that opens and fails every second says
    "opened" once.
  - The same error text goes at most once every 10 s, then with a count:
    `COM30: Write timeout (2 more times in the last 11 s)`.
  - Everything also goes to the helper's log: INFO for what is sent, DEBUG for what is held back.
  - Before this change, one wedged COM30 filled 28 of the last 50 Kismet messages in 30 s (`windows-review.txt`, "PROBLEMS"
    list).
- The code comment says Kismet shows these messages as `<source name> - <text>` (`remote.py:891`). UNVERIFIED.
- **Repeated ERROR lines in the helper's own log**: while a board is absent or a port is taken, step 1 logs the same ERROR
  every 5 s. The helper log is not throttled. See the open questions.

## 10. Stopping (IN FLUX: P15)

- Ctrl+C (SIGINT), SIGTERM and, on Windows, Ctrl+Break (SIGBREAK) set a stop flag (`remote.py:1088-1117`). The main thread
  waits on that flag, not on KeyboardInterrupt alone.
- Stopping logs `INFO: stopping`, closes every connection and the ports, and exits **0**.
  - Run with stubbed sources: SIGINT, SIGTERM and SIGBREAK each returned 0 within 3 s, and the previous signal handlers
    were restored.
  - Real stop times with the old code: 0.54-0.56 s (`windows-review.txt`, t5c/t5d).
- **On Windows it also clears an inherited "ignore Ctrl+C" flag at startup** (`SetConsoleCtrlHandler(NULL, FALSE)`,
  `remote.py:1111-1116`). Windows passes that flag from parent to child, and Git Bash starts background jobs with it set.
  With the old code, a helper started with `&` from Git Bash ignored `kill -INT`, Ctrl+C and `taskkill` without `/F`
  (`windows-review.txt`, "PROBLEMS" list; `scratchpad\logs\sig.out` = "not interrupted" and `sig--enable.out` =
  "KeyboardInterrupt").
- Guidance the Windows review recommended for the docs:
  - Run the helper in its own console window, and stop it with **Ctrl+C or Ctrl+Break**.
  - For a background job: Ctrl+Break, or a force kill (`taskkill /F /PID <pid>`). A force kill still releases the COM port
    at once, and Kismet marks the source errored with the reason `websocket connection closed` (observed, old code).
  - Whether `kill -INT` or `kill -TERM` from Git Bash reaches the new code: UNVERIFIED.
- One unexplained case, old code: once, two Ctrl+C events a minute apart were ignored, and two exact repeats stopped cleanly
  (`windows-review.txt`, "PROBLEMS" list, t5restart). Ctrl+Break is the second stop path added for this; that it helps is
  UNVERIFIED on hardware.
- Linux and macOS: SIGTERM (systemd stop, `kill`) stops it cleanly with exit 0. That suits a systemd unit with
  `Restart=on-failure`, since exit 1 means "every source stopped by itself". The unit file itself is UNVERIFIED; nobody has
  written or tested one.

## 11. Windows specifics

- **Ports** are `COM<n>`. In a definition, `COM14`, `com14` and `\\.\COM14` are the same port (IN FLUX, P7). Other Windows
  port names (such as com0com's `CNCA0`) compare without case (`board.py:471-484`; run: test_board.py "port key").
- Windows keeps a board's COM number: "COM numbers follow a board's serial number there" (`board.py:551`). That is a code
  comment about Windows, UNVERIFIED here.
- **Drivers**: none are mentioned anywhere in this repo. Windows 10/11 should use its built-in CDC driver for
  USB-Serial-JTAG. UNVERIFIED; check the sibling project's docs or a clean PC.
- **Opening the port** (`board.py:365-389`):
  - DTR and RTS are set low **before** the port opens, because on Espressif boards those lines drive reset and boot mode.
  - The receive buffer is raised to 1 MiB.
  - The 921600 baud setting is ignored by USB-Serial-JTAG.
  - If `close()` fails because the board was unplugged mid-transfer, the OS handle is closed directly
    (`board.py:415-439`). Otherwise every later open would be refused with "access denied" for as long as the helper runs.
- **Busy port**: Windows answers "Access is denied" (`PermissionError(13, ...)`, WinError 5), which the helper reports as
  "already in use" (`board.py:353-362`).
- **A board that reboots can leave Windows with a silent open handle**, which is why the 6 s no-answer reopen exists
  (`board.py:735-739`).
- **Wedged board**: Windows error 31 (`A device attached to the system is not functioning.`). The port is still listed but
  fails to open or write (`Write timeout`). The source now fails its open with that error and retries every ~5 s. Unplugging
  and replugging the board is the cure seen in the review.
- **Kismet in WSL2**: `--connect localhost:2501` or `127.0.0.1:2501`. The WSL relay listens on 127.0.0.1 only
  (`windows-review.txt`).
- **Kismet in Docker Desktop**: the `kismet` service publishes `${KISMET_PORT:-2501}:2501` on all host interfaces, and the
  `demo` service publishes `127.0.0.1:2501` with login demo/demo (`compose.yaml:55-56,75-81`).
  - The helper fed Kismet in Docker Desktop from Windows as source `docker-win-wifi` (`scratchpad\helper1.log`,
    `helper2.log`, old code).
- **Stopping**: see section 10.
- **Tested on Windows** (Windows 11 Pro, Python 3.13.2): real boards on COM32 and COM30 through a powered hub, feeding
  Kismet in WSL2 (`--connect localhost:2501 --user wintest ...`) and in Docker Desktop. This was **old code**, before P1-P17
  (`scratchpad\logs\`, `helper*.log`, `windows-review.txt`). The current code has only run the offline tests on Windows.

## 12. Linux, macOS, BSD specifics

- **Ports**: `esp32c5-ttyACM0` means `/dev/ttyACM0`. `device=` takes any path, including `/dev/serial/by-id/...`; the lock
  and the MAC lookup follow a link to its device node (IN FLUX, P7). ttyUSB works as a name (`esp32c5-ttyUSB0`), but only
  303a:1001 devices are *found* automatically.
- **Exclusive lock**: pyserial `exclusive=True` takes an `flock` shared with the C helper (IN FLUX, P6). The error when it is
  held: `... Could not exclusively lock port ...`, reported as "already in use" (`board.py:394-400`; run: test_board.py).
- **DTR and RTS** are cleared **after** open on POSIX, RTS first. Clearing them before would pass through "DTR released, RTS
  asserted", which resets the chip (`board.py:401-411`).
- **Pseudo-terminals** (fake board, socat, ser2net) have no modem lines. EINVAL and ENOTTY from clearing DTR and RTS are
  ignored, so the helper works with `tools/fake_board.py` (IN FLUX, P13; `board.py:406-411`). Before today, opening a pty
  failed with `[Errno 25] Inappropriate ioctl for device` (`pi-run-notes.txt` item 18).
  - Example without hardware, POSIX only:
    ```
    python3 tools/fake_board.py /tmp/esp32c5-fake
    python3 -m esp32c5_kismet.remote --connect <kismet>:2501 --apikey KEY --source esp32c5:device=/tmp/esp32c5-fake,mode=wifi
    ```
    The fake board's usage line is `tools/fake_board.py:8-9`. Running the Python helper against it is my composition;
    UNVERIFIED with the current code, though it was done on the Pi with the old code plus a shim.
- **Permissions**: a user outside the group that owns `/dev/ttyACM*` (`dialout` on Debian and Ubuntu) gets
  `[Errno 13] ... Permission denied`, and the open fails with that text. This is a general Linux fact, UNVERIFIED in this
  project.
- **macOS**: `esp32c5-cu.usbmodem1101` means `/dev/cu.usbmodem1101` (run: test_kismet_v3.py). `--list` and MAC lookup come
  from pyserial. Board identity on reopen cannot be checked, since there is no sysfs. UNVERIFIED: never run on macOS.
- **BSD**: `esp32c5-cuaU0` counts as a port name only if `/dev/cuaU0` is a character device. UNVERIFIED: never run.
- **Tested on Linux**:
  - Raspberry Pi 4 (Debian 13 arm64): the Python helper against the fake board over websocket and TCP, and a real board
    via by-id, with **old code**. That run found the pty and by-id bugs now fixed (`pi-run-notes.txt` items 8 and 18).
  - WSL2 Ubuntu 24.04 (Python 3.12): connection-reset reproduction with websocket-client 1.7.0-1.9.1 against a fake server
    (`windows-review.txt` W3).
  - The current code has not run on Linux yet. The offline tests' POSIX-only cases (pty, flock, real symlink) have **not**
    been run on the current code either: they were skipped on Windows.

## 13. Differences from the C helper (so the docs do not claim they are identical)

- **Where it runs**: the C helper is built into Kismet and runs on Linux/POSIX. The Python helper runs anywhere, and is the
  only way from Windows.
- **Board not capturing for 15 s**: the C helper sends an error and **exits**, and Kismet or the Docker loop restarts it. The
  Python helper sends ERROR and SHUTDOWN and **reconnects by itself** after 5 s. The C message differs too:
  `<name>: no capture from the board on <dev> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?`
  (C helper, capture thread).
- **Capture interface in the open report**: the C helper sends `esp32c5-<tty>` (for example `esp32c5-ttyACM0`), and the
  Python helper sends the device (`COM14`, `/dev/ttyACM0`). See the open questions.
- **Multi-board error**: the Python text also lists the ports in parentheses, and suggests a name with the radio word.
- **Unknown mode**: Python says `unknown mode 'x': use wifi, zigbee (802154, 802.15.4, thread) or btle (ble, bluetooth)`,
  and C says `<iface>: mode must be wifi, zigbee or btle`. The C helper's alias list names 802154 and thread;
  whether it also accepts `802.15.4` is UNVERIFIED.
- **`--list`**: the C helper needs Linux sysfs, and the Python helper uses pyserial, which is cross-platform.
- **Credentials**: both read `KISMET_CAP_APIKEY`, or `KISMET_CAP_USER` + `KISMET_CAP_PASSWORD`, when none are given on the
  command line.
- **The same in both**: UUIDs, the hardware label, the names `esp32c5[zigbee|btle]-<port>`, the `channel=` rules, the port
  lock, the stream parser rule, the BTLE fix-up and the 0.8 s MODE settle.

## 14. Tests

- `tests/test_board.py`: stream framing (with the C helper's cases), channel specs, port keys, port lock and ptys (POSIX),
  the handshake against a fake board (the MODE settle, an in-place reboot, a vanishing port, resync without MODE), and
  finding a board by MAC. No port and no Kismet needed. Run: **213 PASS, 2 SKIP** (the symlink and pty/lock cases are
  POSIX-only), `ALL OK`, exit 0, on Windows with Python 3.13.2.
- `tests/test_kismet_v3.py`: exact protocol bytes, UUIDs against the C helper's, definitions, one board one source, the TAP
  rewrap, the BTLE fix-up, hopping, opening, status throttling, surviving connection errors, the CLI (env login, localhost,
  missing websocket-client, exit codes, signals), and whole sessions against a fake Kismet over TCP and websocket. Run:
  **253 PASS, 1 SKIP** (a real symlink), `ALL OK`, exit 0.
  - This file was rewritten at 17:15. The 12:40 version failed four checks against the new code and could not start its
    sessions.
- How to run: `python tests/test_board.py`, then `python tests/test_kismet_v3.py`, from the repo root. `TEST_DEBUG=1` shows
  the helper's own log (test_kismet_v3.py:35).
- Not automated: the Python helper against a **real** Kismet. `tests/kismet_e2e.sh` and `tests/docker_smoke.sh` exercise the
  C helper only (grep: no `esp32c5_kismet` in either).

## 15. IN FLUX register: intended behaviour after the current changes

"In snapshot" means the behaviour is in the snapshot code with the cited lines and passes the offline tests. For every item
the remaining step is a re-run on hardware and against a real Kismet, which has not happened yet.

| # | Intended behaviour | State at the snapshot | Origin |
|---|---|---|---|
| P1 | Stream parser rule identical to the C helper: restart markers are only recognised at record boundaries; a damaged header searches back into the last record for a signature; frames carrying the signature cannot fake a restart. | In snapshot (`board.py:168-342`); test_board.py has the C cases | python-mirror-notes C fix 1 |
| P2 | Names `esp32c5-`, `esp32c5zigbee-` and `esp32c5btle-<port>`; radio from the word before the first `-`; `mode=` wins; `--list` prints the three names | In snapshot (`remote.py:61-66,152-208,1120-1131`) | notes fix 2 |
| P3 | `channel=` strict (digits, ≤177, valid for the radio); BTLE accepts 37-39 and stays on 37; checked before the port; used for the start and the open report; `channel_hop=false` reported | In snapshot (`remote.py:280-295`, `758-777`; `kismet_v3.py:242-243`) | notes fix 3; Windows problem list |
| P4 | Kismet's rewritten definition (sorted, unquoted) is read the way Kismet reads it and recognised as the same source | In snapshot (`remote.py:99-149`, `742-747`) | Pi/Windows findings |
| P5 | Reconnect survives anything in one connection; best-effort websocket close; `websocket-client>=1.9.1`; exit 1 when every source died | In snapshot (`remote.py:586-594`, `985-1010`, `1219-1222`; requirements.txt) | windows-review W3 |
| P6 | Exclusive port, same flock as the C helper; the "already in use ..." message; Windows access denied reads as in use | In snapshot (`board.py:69-70,349-412`) | notes fix 4 |
| P7 | Canonical port names (`COM14`, `\\.\COM14` and `com14` are one port; by-id links resolve to their tty); a named port that is absent is **waited for**, not offered under another UUID; `uuid=` bypasses the wait | In snapshot (`remote.py:176-186,298-302`; `board.py:471-502`) | W1, W2, W4, W6; Pi item 8 |
| P8 | One board, one source: startup refusal, including two portless definitions; a claim held for the process lifetime | In snapshot (`remote.py:327-362`, `924-983`); the check order changed at 17:15 | W2, W6 |
| P9 | A reopened port is checked by MAC and a moved board followed by MAC; portless definitions stay pinned to their board's MAC; a new board on a named port is a new source, with a warning | In snapshot (`board.py:583-784`; `remote.py:961-983`) | notes fix 4; W4 |
| P10 | A port that cannot be opened fails the open report with the OS error (2 s wait); status messages to Kismet throttled; the sync-timeout reason includes the last status | In snapshot (`remote.py:749-777`, `893-918`, `709-713`) | W5; Windows problem list |
| P11 | BTLE fix-up for older firmware: CRC recomputed, flags 0x0C00, said once; short records dropped and counted | In snapshot (`remote.py:418-463`, `859-876`) | notes fix 8 |
| P12 | 0.8 s between MODE and START while still reading; resync skips MODE when already on the radio | In snapshot (`board.py:67`, `663-739`) | notes fix 13 |
| P13 | Works with ptys (fake board, socat, ser2net): EINVAL/ENOTTY on DTR/RTS ignored | In snapshot (`board.py:401-411`); the pty test is POSIX-only and **not run** on the current code | Pi item 18 |
| P14 | Hardware label `Espressif USB-Serial-JTAG (<MAC>)` (else `ESP32-C5`); messages say "Espressif USB-Serial-JTAG device (USB ID 303a:1001)"; UUIDs equal to the C helper's | In snapshot (`remote.py:211-228,314-320`); test compares against compiled C values | notes fix 10 |
| P15 | Ctrl+C, Ctrl+Break and SIGTERM stop cleanly with exit 0; an inherited ignore-Ctrl+C flag is cleared on Windows | In snapshot (`remote.py:1088-1117`, `1195-1223`) | Windows problem list |
| P16 | `localhost` tries 127.0.0.1 before ::1; falls through only on refused or unreachable | In snapshot (`remote.py:1030-1052`) | Windows problem list |
| P17 | Credentials from `KISMET_CAP_APIKEY` or `KISMET_CAP_USER` + `KISMET_CAP_PASSWORD` when none are on the command line | In snapshot (`remote.py:1070-1085`, `1172-1174`) | notes fix 12 (C side) |

The C helper is still in final review too (`capture_esp32c5.c` changed while I read it, and its line numbers moved), so the
parity statements in section 13 may shift.

## 16. Open questions (for the implementer or the user, before these pages are published)

1. **SIGTERM on Windows.** The docstring (`remote.py:29-30`) and P15 say SIGTERM stops the helper "on Windows too". Nothing
   outside the process can send it SIGTERM there: `taskkill` without `/F` sends WM_CLOSE, which a console program has no
   window to receive, and a kill ends up in TerminateProcess. The tests raise SIGTERM from inside the process. Proposed
   wording: "Windows: Ctrl+C or Ctrl+Break; Linux/macOS: Ctrl+C or SIGTERM". Confirm.
2. **Awkward texts the docs would otherwise quote.** Will these be reworded?
   - The startup warning ends `... (waiting for it) (will keep looking)` (`remote.py:302` + `350`).
   - The "connection ended" reason after a failed open is `could not open could not open port 'COM14': ...` or
     `could not open COM14 is already in use ...` (`remote.py:773` puts "could not open " before an error that usually
     says so already).
3. **ERROR every 5 s in the helper's log** while a board is absent or its port is taken (`remote.py:993`). The Kismet
   messages are throttled but the helper log is not. Is that intended? The troubleshooting page should say what to expect.
4. **Capture interface parity.** The Python helper reports `COM14` / `/dev/ttyACM0`, and the C helper reports
   `esp32c5-ttyACM0`. Kismet's interface column will differ between the two. Intended?
5. **`dwell=`** is accepted and checked (20-60000) but has no effect under Kismet. Document it as "not used with Kismet",
   or leave it out?
6. **Minimum Python.** websocket-client>=1.9.1 means Python 3.10+. Should the pages say 3.10+? Ubuntu 20.04 (3.8) could not
   install the requirements. Debian 12 (3.11), Ubuntu 22.04 (3.10) and 24.04 (3.12) can.
7. **Login characters.** Does the `&` / space / `%XX` limit in `docker/entrypoint.sh:214-221` apply to the Python
   helper's `user=&password=` query too? Recommend API keys in any case.
8. **Install form.** Will there be a `pyproject.toml` or entry point (a `pip install .` command), or is "run from the repo
   root with `python -m esp32c5_kismet.remote`" the documented way?
9. **A stock Kismet** without the esp32c5 datasource: what does the user see when the helper connects? This is for the
   troubleshooting page.
10. **A named port that comes back under another name.** After a 15 s sync timeout, a Linux ttyACM that renumbers is not
    followed across reconnects; it is followed only within one connection. Is that intended? The docs would then advise
    naming boards by `/dev/serial/by-id/...` or leaving the port out.
11. **BTLE single-channel requests** are answered with the channel asked for (for example "38") although the board scans
    all three. Should the docs say that, or will the helper report 37?
12. **Re-test plan.** Which environments will re-run the current code on hardware and against a real Kismet (Windows to
    WSL2, Windows to Docker Desktop, the Pi)? Until then every P item stays "intended, offline-tested".
13. **Kismet message display**: the code comment says Kismet shows helper messages as `<source name> - <text>`
    (`remote.py:891`). Check once in the UI before quoting it.

## 17. Sources consulted

- Repo, read-only: `esp32c5_kismet/{remote,board,kismet_v3,__init__}.py`, `requirements.txt`,
  `tests/test_board.py`, `tests/test_kismet_v3.py`, `kismet/datasource_esp32c5.h`,
  `kismet/capture_esp32c5/capture_esp32c5.c` (header, `resolve_device`, `make_uuid`, `make_hardware`, capif, capture thread),
  `docker/entrypoint.sh`, `docker/kismet_site.conf`, `compose.yaml`, `.dockerignore`, `tools/fake_board.py` (header),
  `tests/*.sh` (grep).
- Scratchpad: `python-mirror-notes.txt`, `windows-review.txt`, `pi-run-notes.txt` (items 6, 8, 18), `helper-review.txt`
  (grep), `helper1.log`, `helper2.log`, `helper99.log`, `logs\t3btle.log`, `t4lock.log`, `t5d.log`, `sig*.out`,
  `launch.py`, `runhelper.sh`, `py-before\` (the pre-change code), the wheel METADATA in `linwheels\` and `wsv\`, and
  `pywork\uuidref.c`.
- Runs, all in `docs-facts\`: `probe.py`, `probe2.py`, the test copies in `snap\` and `snap2\`, `python -m
  esp32c5_kismet.remote --help` and the argument errors, and a real `--list` (enumeration only).
