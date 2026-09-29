This page is for contributors: how the repository is laid out, which tests exist, what each one needs and checks, and how to test on real boards. How to report a problem or send a change is on [Contributing](Contributing).

## Repository layout

```text
firmware/                      ESP-IDF 5.5 project: the board's firmware
  main/esp32c5_sniffer.c       the whole firmware, in one file
  main/Kconfig.projbuild       the menuconfig options ("Packet Sniffer Configuration")
  sdkconfig.defaults           the build settings a fresh clone starts from
  partitions.csv               the partition table (needs 2 MB of flash or more)
kismet/                        the Kismet side, GPL-2.0-or-later (COPYING.md says why)
  datasource_esp32c5.h         the server-side source type "esp32c5"
  capture_esp32c5/             the C helper kismet_cap_esp32c5: capture_esp32c5.c, Makefile.in
  add-to-kismet.sh             copies both into a Kismet source tree and wires them into its build
esp32c5_kismet/                the Python remote helper (python -m esp32c5_kismet.remote)
  board.py                     the serial link to a board: port lock, handshake, stream parser
  kismet_v3.py                 Kismet's external capture protocol, version 3
  remote.py                    the command line, source definitions and connections to Kismet
docker/                        Dockerfile, entrypoint.sh, kismet_site.conf
compose.yaml                   the kismet, demo and helper services
tools/fake_board.py            a pseudo-terminal that behaves like a board
tests/
  test_board.py                offline: the Python remote helper's link to a board
  test_kismet_v3.py            offline: the Python remote helper's Kismet side
  c/run.sh, c/test_parser.c    the C parser harness for the C helper
  kismet_e2e.sh                fake board -> C helper -> a real Kismet
  remote_e2e.sh                fake board -> Python remote helper -> a real Kismet
  docker_smoke.sh              the demo image, no hardware
docs/wiki/                     the pages of this wiki
.github/workflows/docker.yml   CI: builds, smoke-tests and publishes the Docker image
.github/dependabot.yml         monthly updates of the pinned GitHub Actions
requirements.txt               the Python remote helper's packages
README.md, CREDITS.md, LICENSE the overview, credits and prior art, the MIT licence
```

- There is no Python package to install: no `setup.py`, no `pyproject.toml`. The Python remote helper and its tests run from the repository root.
- `firmware/build/`, `firmware/sdkconfig`, `.venv/`, capture files (`*.pcap`, `*.pcapng`, `*.kismet`) and a compose `.env` file, which can hold a Kismet login, are git-ignored.
- `.gitattributes` keeps every text file LF on checkout, whatever `core.autocrlf` says. The scripts run on Linux and inside the Docker image, and a script with CRLF line endings does not start there.

## The tests at a glance

| Test | What it checks | Needs | Runs on | Last recorded result |
|---|---|---|---|---|
| `tests/test_board.py` | The Python remote helper's link to a board: stream framing, channel specs, port names, the port lock (and on Linux the tty's exclusive mode and `/proc/locks`), the handshake against a fake board inside the test, finding a board by its MAC | Python and pyserial | Windows, Linux | 254 checks on Linux as root, `ALL OK`; 238 plus 2 `SKIP` on Windows |
| `tests/test_kismet_v3.py` | The Python remote helper's Kismet side: protocol bytes, UUIDs compared with the C helper's, source definitions, one board per source, the 802.15.4 rewrap, the BTLE CRC fix-up, hopping and refused channel sets, the command line, where the login and the API key go, a redirect that must not be followed, whole sessions against a fake Kismet over TCP and over a websocket, and over TLS when `openssl` is available | Python and `requirements.txt`; `openssl` on the `PATH` for the TLS session | Windows, Linux | 363 checks, `ALL OK` (on Windows plus 1 `SKIP`) |
| `tests/c/run.sh` | The C helper: stream parser, "capturing", 802.15.4 and BTLE handling, source names, `channel=` and refused channels, the probe, `--list`, finding a board by MAC, the port lock and exclusive mode, the reason told to Kismet, the PING watchdog, the signals that end a remote helper, the capability drop, the remote login | gcc, and a Kismet tree patched with `add-to-kismet.sh` and built | Linux | 323 checks as root, `ALL OK`; 299 plus 3 `SKIP` as another user; 318 plus 1 `SKIP` as root on a machine without a `/dev/ttyS*` |
| `tests/kismet_e2e.sh` | The fake board, through the C helper, into a real Kismet, as a local source and over remote capture | Kismet built with the esp32c5 source, python3, curl, port 2501 free | Linux | 80 checks, `ALL OK` |
| `tests/remote_e2e.sh` | The fake board, through the Python remote helper, into a real Kismet, over the websocket and over legacy TCP | The same, plus a Python with `requirements.txt` and `ss`; ports 2511 and 3511 free | Linux | 101 checks, `ALL OK` |
| `tests/docker_smoke.sh` | The demo image: each radio, then the `helper` role feeding Kismet in a second container | Docker, curl, Python | Linux, Windows (Git Bash) | 22 checks, `ALL OK`, in CI on amd64 and arm64 |
| Real boards | What no fake can show: the radios, the USB port, `TXTEST` between boards | Two or more flashed boards | See [Testing on real hardware](#testing-on-real-hardware) | See that section |

Only the last row needs a board. CI runs only the Docker smoke test ([CI](#ci)); run the others yourself. The Python, C and end-to-end results are the last recorded runs, on WSL2 (Ubuntu, libwebsockets 4.3.3) and Windows with the current code. The counts grow as tests are added.

### Which tests to run for a change

| You changed | Run |
|---|---|
| `esp32c5_kismet/` | `test_board.py` and `test_kismet_v3.py`; on Linux also `remote_e2e.sh` |
| `kismet/capture_esp32c5/capture_esp32c5.c` | `tests/c/run.sh`, `kismet_e2e.sh`, `remote_e2e.sh` (it checks that the C helper is refused a board the Python remote helper holds), the Docker smoke test |
| `kismet/datasource_esp32c5.h`, `kismet/add-to-kismet.sh`, `kismet/capture_esp32c5/Makefile.in` | Rebuild Kismet with the script, then everything in the row above |
| `tools/fake_board.py` | `kismet_e2e.sh`, `remote_e2e.sh`, the Docker smoke test |
| `docker/`, `compose.yaml`, `.dockerignore` | The Docker smoke test, and a check of each compose profile: `docker compose config -q`, `docker compose --profile demo config -q` and `docker compose --profile helper config -q` |
| `firmware/` | Build it, then the hardware checks. Nothing automated runs the firmware: every other test uses a fake board. |
| The line protocol or the stream format | All of the above, with the change made in both helpers and in the fake board |

## Setting up

### Python

On Linux, use a virtual environment in the repository root (`.venv` is git-ignored):

```bash
cd esp32c5-kismet-wifi-interface
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

On Windows, in PowerShell:

```powershell
cd esp32c5-kismet-wifi-interface
python -m pip install -r requirements.txt
```

- `requirements.txt` asks for pyserial, msgpack and websocket-client 1.9.1 or newer. websocket-client 1.9.1 needs Python 3.10 or newer, so `requirements.txt` needs 3.10. On the Pi the tests and a capture ran on 3.10, 3.11, 3.12 and 3.13. Python 3.9 could not install `requirements.txt`, but with websocket-client 1.8.0 the tests passed and a capture ran there too.
- On Debian and Ubuntu, install with pip into a virtual environment (`sudo apt install python3-venv` if `venv` is missing), not from apt. The packaged `python3-websocket` is 1.7.0 on Ubuntu 24.04 and 1.8.0 on Debian 13. Versions before 1.9.1 raise an error on Linux when Kismet resets the connection. The helper recovers from that error (on the Pi it reconnected after Kismet was killed, with 1.7.0, 1.8.0 and 1.9.2 alike), but install with pip so that you get 1.9.1 or newer.

### Linux tools for the C harness and the end-to-end tests

- A Kismet source tree at commit cfe427074, patched with `kismet/add-to-kismet.sh`, configured, built and installed. Follow [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support). The examples on this page use the layout of the Raspberry Pi that was tested: the tree in `~/src/kismet`, Kismet installed to `~/kismet-install`.
- gcc (Debian's `build-essential`), python3 and curl.
- WSL2 works for all of it: the C harness and both end-to-end tests have run on WSL2. See [Install on WSL2](Install-on-WSL2).

> **Warning:** Build Kismet in WSL2 with `make -j4` at most. A `make -j20` there used up the host's memory, and the WSL distribution had to be terminated. On a Raspberry Pi 4 with 8 GB, `make -j4` took about 78 minutes.

## The offline Python tests

From the repository root, on Linux:

```bash
.venv/bin/python tests/test_board.py
.venv/bin/python tests/test_kismet_v3.py
```

On Windows:

```powershell
python tests/test_board.py
python tests/test_kismet_v3.py
```

- Neither file opens a serial port or needs Kismet. `test_board.py` has a fake board of its own inside the test. `test_kismet_v3.py` also plays Kismet, over TCP and over a websocket, and over a websocket with TLS when `openssl` is on the `PATH` to make a test certificate.
- `test_board.py` feeds the Python remote helper the same streams that `tests/c/test_parser.c` feeds the C helper, so both helpers are held to one parser rule.
- `test_kismet_v3.py` compares the Python remote helper's UUIDs with values compiled from the C helper's code.
- Each check prints a `PASS` line. The first `FAIL` stops the file with exit status 1. A clean run ends with `ALL OK` and exit status 0.

These `SKIP` lines are expected:

| Line | File | Why |
|---|---|---|
| `SKIP pseudo-terminal and lock tests (POSIX only)` | `test_board.py`, on Windows | Pseudo-terminals and `flock` exist only on POSIX |
| `SKIP port key through a symbolic link (no permission to make one here)` | `test_board.py` | Windows without the right to make symbolic links |
| `SKIP a real symbolic link (no permission to make one here)` | `test_kismet_v3.py` | The same |
| `SKIP an open refused with EBUSY (needs root and capsh, to try it without CAP_SYS_ADMIN)` | `test_board.py`, on Linux | Not run as root, or no `capsh`. The check opens a port held in exclusive mode from a process without `CAP_SYS_ADMIN`, since the exclusive mode lets a process with it through |
| `SKIP wss to localhost with a certificate for localhost (no openssl to make one)` | `test_kismet_v3.py` | No `openssl` on the `PATH` to make a test certificate |

Before you send a change to `board.py`, also run both files on Linux: the pseudo-terminal and lock cases run only on POSIX, and the exclusive-mode and `/proc/locks` cases only on Linux (on other POSIX systems they are left out without a word). The recorded runs: `test_board.py` 254 checks on Linux as root, 238 plus 2 `SKIP` lines on Windows; `test_kismet_v3.py` 363 checks on both, with 1 `SKIP` line on Windows, and 363 again on Linux with websocket-client 1.7.0, 1.8.0 and 1.9.1.

Several cases in `test_kismet_v3.py` make the helper log errors on purpose, so its log is hidden. `TEST_DEBUG=1` shows it:

```bash
TEST_DEBUG=1 .venv/bin/python tests/test_kismet_v3.py
```

## The C parser harness

`tests/c/run.sh` compiles `tests/c/test_parser.c`, which includes this repository's `kismet/capture_esp32c5/capture_esp32c5.c` as it is. It builds against a Kismet tree's `config.h`, `capture_framework.h` and `libkismetdatasource.a`. The calls that would reach a Kismet server are replaced by stubs that record what they are given; the rest of the capture framework is Kismet's own. Linux only.

1. Build Kismet with the source once: the tree must have been through `add-to-kismet.sh`, `./configure` and `make`.
2. Run the harness against that tree:

   ```bash
   sh tests/c/run.sh ~/src/kismet
   ```

   Without an argument it uses `$KISMET_SRC`, then `~/src/kismet`. Set `CC` to use a compiler other than gcc.

It compiles the repository's copy of the helper, not the tree's, so you can re-run it after every edit without copying anything into the tree or rebuilding Kismet.

| Part | What it checks |
|---|---|
| `test_framing` | The stream parser: start markers with and without the helper's nonce, the PCAP header, records, damaged records; fed in chunks of 1, 3, 7, 11, 64 and 4096 bytes and all at once |
| `test_capturing` | "capturing" is said only once the PCAP header has the radio's link type |
| `test_injection` | Frames whose payload holds the whole restart signature (`<<START>>` and a PCAP header) are passed on as data |
| `test_154`, `test_wifi_freq` | The 802.15.4 TAP header rewrapped as link type 230, with channel and signal; the frequency in every radio's signal block |
| `test_btle` | The CRC fix-up for older firmware (flags `0x0013` against `0x0C13`), with a CRC vector that Wireshark's BTLE dissector accepts |
| `test_definitions` | Source names, `mode=`, `channel=` |
| `test_sysfs` | `--list` and finding a board by its MAC |
| `test_probe`, `test_remote_busy` | Which definitions the helper claims when Kismet probes; a remote helper that does not offer a port another process holds |
| `test_open`, `test_exclusive` | Opening a port, the port lock, and the tty's exclusive mode; channel sets, BTLE 38 and 39 reported as 37, and a refused channel |
| `test_say_why`, `test_ping_watchdog` | The reason told to Kismet, as a message and as an error; the websocket PING watchdog |
| `test_end_on_signal`, `test_end_with_parent` | The signals that end a remote helper (not one it was started ignoring, as under `nohup`), and its capture process ending with its parent |
| `test_capabilities` | The helper dropping every capability, as root, with Docker's default set and installed setuid root; setuid root still opening a user's own pseudo-terminal |
| `test_login` | The remote login from `KISMET_CAP_APIKEY`, `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`, read as the framework reads it; the Basic `Authorization` header and the `KISMET` cookie; a user name with ':' in the URI; a login too long refused; none of it over `--tcp`; the warning for a login that cannot log in |

- The boards it lists and finds sit on a sysfs tree the test makes up under `/tmp`, and their ports are pseudo-terminals. Boards plugged into the machine make no difference.
- Run it as root to include the checks that need root: the exclusive mode (on a `/dev/ttyS*` with no hardware behind it, when the machine has one; a port with hardware is not touched), the capabilities, and setuid root. The login checks test the framework as `add-to-kismet.sh` patches it, so the tree must have been patched by this repository's script.
- Each check prints `PASS` or `FAIL`. The harness runs every check, then prints `ALL OK` (exit status 0) or `<n> FAILED` (exit status 1). A build that fails also gives exit status 1.
- A tree without the files it needs gives `<tree>/<file> is missing: give a Kismet tree patched with kismet/add-to-kismet.sh and built` and exit status 2.
- The last recorded runs, on WSL2 with the current code: 323 checks as root, `ALL OK`; 299 checks and 3 `SKIP` lines as another user, `ALL OK`. On Ubuntu 24.04 (libwebsockets 4.3.3) as root, in a container without a `/dev/ttyS*`: 318 checks and 1 `SKIP` line (the exclusive-mode check across device nodes), `ALL OK`. In the helper's reviews, deliberate bugs (mutations) were put into it one at a time to check that these tests catch them.

These `SKIP` lines are expected:

| Line | Why |
|---|---|
| `SKIP exclusive mode: needs root, to make device nodes and to open as a process without CAP_SYS_ADMIN` | Not run as root |
| `SKIP exclusive mode across device nodes: no /dev/ttyS* without hardware to try it on` | Run as root on a machine with no spare `/dev/ttyS*` |
| `SKIP setuid root: the capture process ends with its parent after opening a port of the user's: needs root` | Not run as root |
| `SKIP capabilities as root, in Docker and setuid root: needs root` | Not run as root |
| `SKIP exclusive mode: built without libcap, or no TIOCGEXCL`, `SKIP capabilities: built without libcap, the helper keeps what it is given` | A Kismet configured without libcap: the helper then drops no capability |

## The fake board

`tools/fake_board.py` makes a pseudo-terminal that speaks the firmware's line protocol and streams made-up traffic that depends on the channel it is tuned to. The end-to-end tests, the Docker demo image and [Try It Without Hardware](Try-It-Without-Hardware) all use it instead of a board. It needs only Python's standard library, and it runs on POSIX systems only: Linux, WSL2.

```bash
python3 tools/fake_board.py /tmp/esp32c5-fake
```

It puts a link to a new `/dev/pts/N` at the path you give, starts in Wi-Fi mode and prints what it does on its standard output:

```text
[fake] booted in wifi mode on /tmp/esp32c5-fake -> /dev/pts/3
```

In a second terminal, give it to Kismet as a source. `/tmp/esp32c5-fake` is the path from the first command:

```bash
kismet -c esp32c5:device=/tmp/esp32c5-fake
```

The C helper also accepts the pseudo-terminal by name, for example `esp32c5-pts/3`.

Run the fake board as the same user as Kismet, or as the helper that opens it: the pseudo-terminal belongs to whoever starts the fake board (mode 0620), and `kismet_cap_esp32c5` drops every capability, root's power to open other users' files included. For a Kismet started with `sudo`, start the fake board with `sudo` too.

### Options

```text
python3 tools/fake_board.py PATH [MODE] [--garble N] [--inject N] [--restart-every N] [--vanish] [--old-firmware] [--lacks RADIO] [--silent]
```

| Option | What it does |
|---|---|
| `PATH` | Where the port appears. It is a symbolic link to the pseudo-terminal. |
| `MODE` | The radio it boots with: `WIFI` (the default), `802154` (also `ZIGBEE`, `THREAD`) or `BLE` (also `BT`, `BLUETOOTH`) |
| `--garble N` | Every Nth record gets a header no stream can contain, so the helper has to resynchronise |
| `--inject N` | Every Nth record is a frame whose payload holds the whole restart signature, `<<START>>` and a PCAP header, as anyone on the air could send |
| `--restart-every N` | Every Nth record the board restarts its stream in place, as after a reset that keeps the port: alternately right after a record and after a record cut short |
| `--vanish` | On a radio change the port goes away for 2 s and comes back as a new pseudo-terminal behind the same path. Without it the port stays open through the reboot, as it did on the real boards. |
| `--old-firmware` | BTLE records the way older firmware sends them: no CRC flags, CRC zeroed |
| `--lacks RADIO` | Firmware without that radio, `BLE` or `802154`, as the sibling project's 1.0.0 and 1.1.0 are: `MODE` for it is ignored, and `START` is answered in the link type of the radio the board is on |
| `--silent` | Says nothing at all and ignores what it is sent, as a board with other firmware, or stuck in its ROM download mode, does |

The Nth record is counted from the last `START` the fake answered, so each of these lands in a stream a helper asked for and is reading.

### What it sends

| Radio | Traffic | What Kismet shows |
|---|---|---|
| Wi-Fi | Beacons from three access points: `ESP32C5-FAKE-24` on channel 6, `ESP32C5-FAKE-5LOW` on 36, `ESP32C5-FAKE-5HIGH` on 149 | The three access points, once hopping reaches their channels |
| 802.15.4 | Data frames to broadcast from node `0x1001` on channel 15 and node `0x2501` on channel 25 | Devices `10:01`, `25:01` and `FF:FF` |
| BTLE | Advertisements from `C6:00:00:C5:E5:5A`, named `ESP32C5-FAKE` | The advertiser `ESP32C5-FAKE` |

It sends about 100 records a second while tuned to a channel with traffic, and nothing on other channels.

### How it differs from a real board

- **A radio change reboots it in 0.53 s**, the time measured on the real board from `MODE` to the boot marker. Anything sent during the reboot is lost, and the fake logs it as `[fake] rebooting, lost: <line>`. The end-to-end tests use that line to check that no `START` is lost.
- **It remembers its radio only while it runs.** Each start boots in the `MODE` on its command line.
- **It reads command words in any case.** The firmware's are case-sensitive: it refuses `start`.
- **It ignores `TXTEST`** and any command it does not know, and it has no UART log and no drop counters.
- **It refuses `CHANNELS 0` and `CHANNELS AUTO`**, which make the firmware go back to its built-in list, and in 802.15.4 it starts locked on channel 15, where the firmware hops 11 to 26. Under Kismet neither matters: the helpers always send a channel.
- **Its timestamps are wall-clock time** whatever `START` says.
- **It prints `ESP-ROM:esp32c5-fake` before its first boot marker**, so the helpers' handling of boot text gets exercised.

## The Kismet end-to-end tests

Both scripts start their own Kismet with a login in a temporary `--homedir` and logging off, feed it from the fake board, and check what Kismet reports through its REST API.

```mermaid
flowchart LR
    F["tools/fake_board.py<br/>pseudo-terminal"] -->|"line protocol,<br/>PCAP stream"| C["kismet_cap_esp32c5<br/>(kismet_e2e.sh)"]
    F -->|"line protocol,<br/>PCAP stream"| P["python -m esp32c5_kismet.remote<br/>(remote_e2e.sh)"]
    C -->|"IPC: packets"| K["Kismet<br/>temporary --homedir, --no-logging"]
    K -.->|"starts"| C
    P -->|"websocket or --tcp"| K
    T["the test script"] -->|"REST: sources, devices"| K
```

- Both need a Kismet built with the esp32c5 source and installed, with `kismet_cap_esp32c5` next to `kismet`. Kismet starts helpers only from the bin directory it was configured with (`--prefix` or `--bindir`), not from the directory the `kismet` binary runs from. Point `KISMET` at an installed `kismet`: one left in the source tree runs whatever `kismet_cap_esp32c5` is installed under its prefix.
- Both print a `== <case>` heading, a few lines of what Kismet reported, `PASS` or `FAIL` for each check, and `ALL OK` at the end.
- On a failure they exit with status 1, keep their logs in a temporary directory and print where it is (`--- logs kept in <dir>`).
- Each case runs for 15 to 40 seconds, so a full run takes several minutes.

### `tests/kismet_e2e.sh`: the C helper

```bash
KISMET=~/kismet-install/bin/kismet sh tests/kismet_e2e.sh
```

Without `KISMET` it runs the `kismet` on the `PATH`. It starts Kismet on port 2501, so stop any other Kismet first. It needs python3 and curl, but no Python packages. The remote cases run the `kismet_cap_esp32c5` next to `KISMET`, or the one `HELPER` names, and reach Kismet through a relay of the script's own that logs the head of every request. Every Kismet it starts has the login `e2e`, with a password that holds '&', a space and `%41`. The cases:

1. Wi-Fi on 2.4 and 5 GHz with Kismet hopping, and a damaged record every 50.
2. Frames whose payload holds the whole restart signature.
3. A board that restarts its stream in place every 40 records.
4. 802.15.4 as `esp32c5zigbee-<port>`, with the board booting in Wi-Fi and rebooting, its port staying open.
5. 802.15.4 with `--vanish`: the port goes away in the reboot and comes back as another.
6. Wi-Fi locked with `channel=36,channel_hop=false`, and a second source on the same board, which must be refused as in use.
7. BTLE, set to channel 38 and shown as 37, then set to 40, which the helper refuses while the source goes on capturing.
8. BTLE from older firmware, which the helper fixes up.
9. BTLE on firmware without it (`--lacks BLE`): one `lost sync` per attempt, never "capturing", and the helper's 15 s reason in Kismet's log.
10. Remote capture over the websocket (`--connect`, with retry, started as `nohup` starts it): the login in an `Authorization` header and nowhere in the request line, the first packet within 3 s and more every second after, no empty `INFO: ` line after a channel set, no libwebsockets notices, a second remote helper for the same board refused, `close_source.cmd` followed by a reconnect, and `kill -TERM` ending the capture process with the helper.
11. An API key, which must go in Kismet's session cookie and not in the request line.
12. A login, and then an API key, too long for the request's headers: each refused with a reason, nothing sent.
13. A websocket answered with a redirect to another host, which must not be followed: that host must receive nothing.
14. No libwebsockets `rejecting message on queue depth` warnings from a helper in a network namespace of its own with 200 routes. This needs `unshare` and `ip`, and root or user namespaces; the case prints `SKIP` without them.
15. A bare `esp32c5` with no board plugged in. Kismet has to hand it to the helper and keep retrying, instead of giving up with `Unable to find driver`. This case is skipped when an Espressif USB-Serial-JTAG device (USB ID 303a:1001) is plugged in.

The last recorded runs, on WSL2 and on Ubuntu 24.04 as root, with the current code, passed all 80 checks; in the WSL2 run, in case 10 the first packet reached Kismet 946 ms after the helper started.

### `tests/remote_e2e.sh`: the Python remote helper

```bash
KISMET=~/kismet-install/bin/kismet PYTHON="$PWD/.venv/bin/python" sh tests/remote_e2e.sh
```

- `PYTHON` must have pyserial, msgpack and websocket-client. Otherwise the script stops with `the helper needs pyserial, msgpack and websocket-client for <python> (PYTHONPATH=<path>)`. Give it as an absolute path: the script starts the helper from a temporary directory.
- It also needs `python3` on the `PATH` for its own checks, curl and `ss`.
- Its Kismet listens on port 2511 for the web and on 3511 for legacy TCP remote capture, so a Kismet on 2501 and 3501 is left alone. Set `HTTP_PORT` and `TCP_PORT` to use other ports.
- It stops only the processes it started.

The cases:

1. Wi-Fi over the websocket, the helper stopped with SIGTERM. Every websocket case logs in with a password that holds '&', which the helper sends in an `Authorization` header.
2. Wi-Fi over legacy TCP as `esp32c5-<port>`, stopped with SIGINT.
3. 802.15.4 as `esp32c5zigbee-<port>`, with the board rebooting in place.
4. BTLE, with the login from `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`; the password must not appear on the helper's command line. A channel set to 38 must show as 37, and one to 40 must be refused as the C helper refuses it: HTTP 200, the source going on on 37, and the refusal in Kismet's log.
5. BTLE from older firmware, with an API key (role `datasource`) from `KISMET_CAP_APIKEY`, through a proxy that logs each request: the key must go in the `KISMET` cookie, and no request line may hold it.
6. Frames whose payload holds the restart signature.
7. A board that restarts its stream in place.
8. `channel=36,channel_hop=false` on a source Kismet already knows as hopping. Then a second source on the same board: from a second Python remote helper, on another radio or as the very same source, which must not be offered to Kismet at all; from `kismet_cap_esp32c5`; and twice in one helper, which must refuse to start.
9. A board another process holds: not offered until it is free, while the helper's other source captures, and taken within about 5 s of its release.
10. Kismet killed and started again: the helper must reconnect with the same UUID.

Every time the helper is stopped it must exit with status 0, within 10 s, and nothing may be left running at the end. The last recorded runs, on WSL2 and on Ubuntu 24.04 as root, with the current code, passed all 101 checks.

## The Docker smoke test

`tests/docker_smoke.sh` runs the demo image with its fake board in each radio. Then it runs the `helper` role in one container, feeding Kismet in a second one over remote capture. No hardware is needed.

1. Build the demo image from the repository root:

   ```bash
   docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
   ```

2. Run the test on Linux:

   ```bash
   sh tests/docker_smoke.sh esp32c5-kismet:demo
   ```

   On Windows, in Git Bash, where Python is `python`:

   ```bash
   PYTHON=python sh tests/docker_smoke.sh esp32c5-kismet:demo
   ```

   Where your user is not in the `docker` group, as on the tested Pi, both commands fail with a permission error on `/var/run/docker.sock`. Run both with sudo there:

   ```bash
   sudo docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
   sudo sh tests/docker_smoke.sh esp32c5-kismet:demo
   ```

   The Pi built its images this way; the smoke test itself has not been run on the Pi. Its recorded runs are on Docker Desktop and in CI.

- It needs Docker, curl and Python on the host (`PYTHON`, default `python3`).
- It uses host port 2599 and containers and a network named `esp32c5-smoke*`, and removes them afterwards with their volumes. Set `SMOKE_PORT` and `SMOKE_NAME` to run it beside another copy.
- Every container runs with Docker's default capabilities and no more, so the test also shows that nothing in the image needs `NET_ADMIN`. It also checks that Kismet's list of interfaces (the web UI's Data Sources window) answers, which it never does when one of Kismet's own capture helpers crashes on start.
- The `helper` role logs in with a password that holds '&', a space and `%41`. An image built before the login moved into HTTP headers fails that part: its entrypoint refuses such a password.
- It prints `PASS` or `FAIL` for each check and `ALL OK` at the end; the exit status is 0 or 1.
- The first build of the demo image took about 18.5 minutes on a fast Windows PC, and rebuilds from cache took seconds. On GitHub's runners it takes about 25 to 30 minutes. On a Raspberry Pi 4 (8 GB), building both images took about 80 minutes, almost all of it the Kismet compile.
- CI ran it on the current code, on amd64 and on arm64: all 22 checks passed, in about 2 minutes each.

## CI

The only workflow is `.github/workflows/docker.yml`, named "Docker image".

| | |
|---|---|
| **When** | Pushes to `main` and pull requests that change `kismet/**`, `docker/**`, `.dockerignore`, `tools/fake_board.py`, `tests/docker_smoke.sh` or the workflow itself; version tags such as `v1.2.3` and `v1.2.3-rc.1`, whatever they change; manual runs |
| **Where** | Each architecture on its own native runner: linux/amd64 on `ubuntu-24.04` (120-minute limit), linux/arm64 on `ubuntu-24.04-arm` (180-minute limit). Under emulation the Kismet build would take hours. |
| **What** | Build the demo image with the GitHub Actions cache, run `tests/docker_smoke.sh` on it, then build the Kismet image |
| **Publishing** | Only for version tags and manual runs: both architectures are pushed by digest, then joined under the image tags listed on [Docker Reference](Docker-Reference) |
| **Actions** | Pinned to commit SHAs; `.github/dependabot.yml` updates them monthly |

CI does **not** run the Python offline tests, the C harness, the end-to-end tests or a firmware build. A pull request that only touches `esp32c5_kismet/`, `firmware/`, `compose.yaml`, `requirements.txt`, or files in `tests/` other than `docker_smoke.sh` runs no CI at all. Run the tests for your change yourself, and say in the pull request which ones you ran.

CI has run on GitHub for pushes to `main` and for pull requests: both architectures built the demo image and passed the smoke test. Nothing has been published yet, as no version tag has been pushed and no manual run made, so the publishing steps have not run.

## Working on the C helper

1. Build Kismet with the source once ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)).
2. Edit `kismet/capture_esp32c5/capture_esp32c5.c`, and run the harness after each change:

   ```bash
   sh tests/c/run.sh ~/src/kismet
   ```

3. Get the changed files into the tree and build it. From the repository root, run the script again, then `make`:

   ```bash
   sh kismet/add-to-kismet.sh ~/src/kismet
   make -C ~/src/kismet
   ```

   The script copies a file into the tree only when it differs from the tree's copy (it prints `copied <file>` for each one), and an unchanged file keeps its time. So after a change to `capture_esp32c5.c` alone, `make` rebuilds only the helper. After a change to `datasource_esp32c5.h`, which `kismet_server.cc` includes, it also recompiles `kismet_server.cc` and relinks `kismet` (about 490 MB with its debug information): on the Raspberry Pi 4 a build that did so took about 3 minutes. The first run that adds the script's login fix to `capture_framework.h` recompiles every capture helper once, but not `kismet`.

   After a change to `capture_esp32c5/Makefile.in`, run `./configure` in the tree again, with the flags you used the first time, before `make`: the helper's Makefile is made from it by `configure`.

4. Install it next to `kismet`, the way you installed Kismet. The example is for a Kismet installed under your home directory without sudo, as on the tested Pi:

   ```bash
   make -C ~/src/kismet install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
   ```

   `make install` never replaces configuration files that are already installed.

5. Run the end-to-end tests:

   ```bash
   KISMET=~/kismet-install/bin/kismet sh tests/kismet_e2e.sh
   ```

> **Note:** After a run of the script that edits Kismet's `Makefile.in` or regenerates `configure`, as the first run on a tree does, `make` prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` on every run until `./configure` runs again. It is only a notice, and `make` carries on. A later run that finds everything in place changes neither file, and the notice does not come back. Run `./configure` again, with the flags you used the first time, after a change to `capture_esp32c5/Makefile.in` (step 3) and on a tree configured before the script's first run: its Makefile was made from Kismet's own `Makefile.in`, which has no esp32c5 helper, so it builds without it.

For the Docker image, rebuild the demo target and run the smoke test. The image builds Kismet with a stand-in for the helper's source and copies the real `capture_esp32c5.c` in only afterwards, so a change to that file alone leaves the Kismet build cached and rebuilds only the helper and the layers after it. How long that takes on a Raspberry Pi has not been measured. A change to `datasource_esp32c5.h`, `add-to-kismet.sh` or `Makefile.in` rebuilds Kismet.

## Moving to a newer Kismet commit

No Kismet release has the esp32c5 source yet, so the project pins Kismet commit cfe427074. On the Pi, `kismet --version` printed `Kismet 2026.09.0-cfe427074`. To try another commit (change `<commit>` to the one you want):

1. Clone Kismet into a fresh directory, check out the commit and add the source. Run the last command from the repository root:

   ```bash
   git clone https://github.com/kismetwireless/kismet.git ~/src/kismet-next
   git -C ~/src/kismet-next checkout <commit>
   sh kismet/add-to-kismet.sh ~/src/kismet-next
   ```

2. If the script stops with `anchor not found, Kismet has changed: <anchor>`, Kismet has moved the CatSniffer helper's lines that the script anchors its edits on. Update the anchors in `add-to-kismet.sh`.
3. The script's six fixes to `capture_framework.c` (the metadata leak, the websocket's 5 s bursts, a closed websocket's missed wake-up, the login in HTTP headers with redirects refused, libwebsockets' queue warnings, the empty `INFO: ` line) are each skipped once Kismet has the fix itself. If the code a fix replaces has changed shape, the script prints a note naming it and carries on, for example `capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed` or `capture_framework.c: the websocket login has changed, it still goes in the URI`. Check each note: the helper still builds without the fix, but keeps the bug it fixed.
4. Configure the tree with a prefix of its own, build it and install it there. Kismet starts helpers from the bin directory it was configured with, so the new `kismet` has to be installed before it runs its own `kismet_cap_esp32c5`. With the same prefix as your working Kismet, `make install` would overwrite that install. The `configure` flags are the ones from [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) with another `--prefix`. The example installs into `~/kismet-next-install` without sudo:

   ```bash
   cd ~/src/kismet-next
   ./configure --prefix=$HOME/kismet-next-install --disable-python-tools --disable-librtlsdr \
       --disable-ubertooth --disable-bladerf --disable-btgeiger
   make -j4
   make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
   ```

5. From the repository root, run the C harness and both end-to-end tests against the new tree and its install:

   ```bash
   sh tests/c/run.sh ~/src/kismet-next
   KISMET=~/kismet-next-install/bin/kismet sh tests/kismet_e2e.sh
   KISMET=~/kismet-next-install/bin/kismet PYTHON="$PWD/.venv/bin/python" sh tests/remote_e2e.sh
   ```

   Each test runs the helper installed next to the `kismet` that `KISMET` names, so these use the new install, not your working one. This layout, a second install beside the first, has not been tried yet.

6. For the image, pass the commit as a build argument and run the smoke test. The default is `KISMET_REF` in `docker/Dockerfile`.

   ```bash
   docker build -f docker/Dockerfile --target demo --build-arg KISMET_REF=<commit> -t esp32c5-kismet:demo .
   ```

## Building the firmware

From an ESP-IDF 5.5 shell:

```bash
cd firmware
idf.py set-target esp32c5
idf.py build
idf.py merge-bin -o esp32c5-kismet-merged.bin
```

- `set-target` is needed once. `merge-bin` builds first and writes `firmware/build/esp32c5-kismet-merged.bin`, which flashes at offset 0x0. Flashing, backups and board quirks are on [Flashing the Firmware](Flashing-the-Firmware).
- `warning: ignoring malformed line` is harmless: `sdkconfig.defaults` starts with a UTF-8 byte order mark, and the line it names is a comment.
- The app version is what `git describe` prints. In a tree with no commits it is `1`, with a `Could not use 'git describe' to determine PROJECT_VER` warning. In a tree with uncommitted changes it ends in `-dirty`. Build any firmware you publish from a clean, committed tree.
- The build options are under `idf.py menuconfig` → *Packet Sniffer Configuration*.

## Testing on real hardware

Only capture on networks and devices you own or are authorised to test.

### What has been tested

| Setup | What ran |
|---|---|
| Raspberry Pi 4, 8 GB, Debian 13 (trixie) arm64; four ESP32-C5 boards on a powered USB hub, as `/dev/ttyACM0` to `/dev/ttyACM3` | The native Kismet build; backups and flashing of all four boards; each radio into Kismet through the C helper; `TXTEST` between every pair of boards; the C helper and the Python remote helper as remote sources; four boards as sources at once; the sibling project's firmware 1.0.0, 1.1.0 and 1.2.0 on one board; the Docker build of both images (about 80 minutes) and the Kismet image with the four boards |
| Windows 11; two of the same boards, as COM30 and COM32 | The Python remote helper feeding Kismet in WSL2 and in Docker Desktop, with an early version of the helper |
| GitHub Actions, Ubuntu 24.04 runners, amd64 and arm64 | The Docker image build and the smoke test ([CI](#ci)) |
| Not run | macOS, the BSDs, Fedora and Arch; a setuid-root install on real boards; Kismet's web UI in a browser (the tests read Kismet's REST API) |

The hardware results on this wiki come from three runs on the Pi: two before the last two rounds of changes (the first field test and a retest), and one after the first round. The last round (the login in HTTP headers, redirects refused, a refused channel set answered alike by both helpers, message texts that name the source) has run end to end in WSL2 with fake boards and a real Kismet, not yet on hardware. [Still to check on hardware](#still-to-check-on-hardware) lists what needs a new run.

### Seeing what the firmware does

The board's native USB port carries only the capture stream and your command lines. The firmware answers nothing on USB except `START`: whether a command was accepted or refused shows only in its log on UART0.

- UART0 runs at 115200 baud, 8N1, TX on GPIO11 and RX on GPIO12. On a devkit it is the USB connector marked UART. A board with only the native USB-C port, such as the Seeed Studio XIAO ESP32C5, needs a USB-UART adapter on those two pins. <!-- VERIFY: which header pins of the XIAO ESP32C5 carry GPIO11 and GPIO12, and a serial terminal that reads UART0 without resetting a devkit -->
- A status line comes every 10 s, with the drop counters that are reported nowhere else:

  ```text
  I (123456) sniffer: Wi-Fi ch   6 of 1 (250 ms) | captured 1234 | dropped: buffer 0, usb 0, oversize 0
  ```

- The boot log has an `App version:` line. It is the only way to read the firmware version.

The commands and every log message are listed on [Firmware Protocol](Firmware-Protocol).

### Talking to a board by hand

Do not open a board's native USB port with a serial terminal. On this port DTR and RTS drive reset and boot mode, and a program that raises them can reboot the board or leave it in its ROM download mode.

Use `open_serial()` from the Python remote helper's `board.py` instead. It clears DTR and RTS in the order that does not reset the chip: on Windows before the port opens, elsewhere RTS and then DTR right after it opens (opening the port raises both lines there). It also takes the same port lock as the helpers. When a source holds the board, it is refused with `... is already in use by another capture ...`. The next section uses it.

### `TXTEST` between two boards

`TXTEST [n]` makes a board send n IEEE 802.15.4 test frames, 20 ms apart. It works only in 802.15.4 mode, on the channel the board is on at that moment. A second board then proves the receive path without any Zigbee or Thread equipment nearby.

> **Warning:** `TXTEST` is the only command that makes a board transmit. Use it only where you are allowed to transmit on 2.4 GHz, and on an 802.15.4 channel that none of your own Zigbee or Thread networks uses.

The example uses board A on `/dev/ttyACM0` as the receiver (a Kismet source) and board B on `/dev/ttyACM1` as the sender (not a source). Change the ports to yours.

1. Start Kismet with board A on 802.15.4, locked to channel 20:

   ```bash
   ~/kismet-install/bin/kismet --no-ncurses --no-logging -c 'esp32c5:device=/dev/ttyACM0,mode=zigbee,channel=20,channel_hop=false,name=c5-rx'
   ```

   On the Pi this kept the source on channel 20, not hopping, with the C helper and with the Python remote helper. A source that is already running can be locked through Kismet's REST API instead. Take the source's UUID from `/datasource/all_sources.json`: it starts with `E5C50002` for 802.15.4 and ends with the board's MAC. In the command, replace the UUID with yours and `admin:PASSWORD` with your Kismet login:

   ```bash
   curl -s -u admin:PASSWORD --data-urlencode 'json={"channel":"20"}' http://localhost:2501/datasource/by-uuid/E5C50002-0000-0000-0000-F0F5BD010203/set_channel.cmd
   ```

2. From the repository root, send board B its commands:

   ```bash
   .venv/bin/python - /dev/ttyACM1 <<'EOF'
   import sys
   import time
   from esp32c5_kismet import board

   ser = board.open_serial(sys.argv[1])  # clears DTR and RTS without a reset; refused if a source holds the board
   ser.write(b"MODE 802154\n")           # reboots the board if it is on another radio
   time.sleep(1.5)                       # the reboot takes about 0.5 s; anything sent meanwhile is lost
   ser.write(b"CHANNELS 20\n")           # one channel is a lock; the default 802.15.4 list hops 11-26
   time.sleep(0.5)                       # let the board retune before it transmits
   ser.write(b"TXTEST 200\n")            # 200 frames, 20 ms apart: about 4 s
   time.sleep(5)
   board.close_serial(ser)
   EOF
   ```

   On the Pi this script ran as written, with the virtual environment's Python and with Debian's `python3` and its `python3-serial` package, and 200 of 200 frames reached Kismet. The pause after `CHANNELS` matters: the firmware handles commands in a task with a higher priority than the one that changes channel, so without it `TXTEST` starts before the board has left the channel it was hopping on, and the first frame goes out there.

   The USB port usually stays open through the reboot, but on the test boards some radio switches made a board drop off USB and come back. Then the write after `MODE` fails. Run the script again: the board is now in 802.15.4 mode and does not reboot.

3. Check what board A received:

   ```bash
   curl -s -u admin:PASSWORD http://localhost:2501/datasource/all_sources.json | python3 -m json.tool | grep -E '"kismet.datasource.(name|channel|hopping|num_packets)"'
   ```

   `c5-rx` should show channel `"20"`, hopping `0` and `num_packets` 200, plus anything else that transmits on channel 20. Kismet's device list then has the 802.15.4 devices `00:01` (the sender) and `FF:FF` (the broadcast address).

4. Board B now remembers 802.15.4. The next time a helper opens it for another radio, it reboots once. Put it back on Wi-Fi before you flash it with the merged image: a board flashed while it is on 802.15.4 can come up deaf to Wi-Fi ([Flashing the Firmware](Flashing-the-Firmware#the-radio-is-kept-in-flash)).

Results on the Pi: `TXTEST 200` into Kismet gave 200 of 200 packets, with device `00:01` at 200 packets on channel 20 and +9 dBm at close range. Board to board, all 12 ordered pairs of the four boards received 50 of 50 frames on channel 20. On channel 15, with no Zigbee or Thread equipment nearby, every board received nothing, as expected.

### Other checks worth repeating

| Check | How | Result on the Pi (earlier code) |
|---|---|---|
| Time to capture | Kismet's log: `Data source '...' launched successfully`, then `<name> capturing (<radio>)` | With the 0.8 s wait after `MODE`: 1.0 to 1.5 s when the board was already on the radio; about 1.5 s when it had to switch, 2.5 s when it dropped off USB and came back |
| Recovery from a killed local helper | Take the source's `kismet.datasource.ipc_pid` from `/datasource/all_sources.json` and `kill -9` it. A helper's command line holds no port name, so `pkill -f /dev/ttyACM0` finds nothing. | Error at once, `Attempting to re-open source` after 5.8 s, capturing after 6.4 s |
| Two Wi-Fi boards | Two Wi-Fi sources in one Kismet | `Splitting channels for interfaces using 'esp32c5' among 2 interfaces`; the two boards were never on the same channel at once |
| BLE records | Records read from the boards directly | 757 of 757 with a valid CRC and the "CRC checked" and "CRC valid" flags |
| Remote capture start | Poll `/datasource/all_sources.json` from starting the helper to the first packet | C helper over the websocket: 1.2 to 1.4 s (5 to 6 s before the framework fix in `add-to-kismet.sh`); over `--tcp`: 1.2 to 1.6 s; the Python remote helper: 1.4 to 1.8 s |

### Still to check on hardware

These are fixed or changed in the code but have not run on a board since:

- The last round of changes, which has run only in WSL2 with fake boards: logins with '&', a space and `%41`, and API keys, through a proxy that logs each request, with no secret in any request line; a login whose user name holds ':'; a refused BTLE channel 40 with the Python remote helper (the C helper's refusal already passed on the Pi); what the helpers print on stderr; and four sources at once through the C helper as local sources and through one Python remote helper.
- The Docker image rebuilt with the latest code, with real boards on the Pi. Its 8 checks there (boards found by themselves, by-id names, the host refused a board the container holds, the `helper` role, the demo leaving host boards alone, the hint for missing cgroup rules) passed with an image from before the last two rounds of changes.
- Python's `--list` on Linux leaving out a board another capture holds (the C helper's `--list` does, on the Pi).
- Finding a board again by its MAC when two boards swap tty names, and a board unplugged for more than 20 s.
- The current Python remote helper on Windows with a real board, including stopping it with Ctrl+Break, and with `kill -INT` from Git Bash.
- The firmware built from the current source. The test boards run a build from during development, which may lack the last change: two messages in the UART log.
- That a board a helper on the host holds is refused inside a container. The other direction passed on the Pi: the host could not open a board the container was capturing from.

## Results that look like failures but are not

Scripts should check the text of these, not the exit status.

| What you see | Why |
|---|---|
| `kismet --version` exits with status 1 | Kismet does that by design |
| `kismet_cap_esp32c5 --help` exits with status 255 | The capture framework does that |
| `kismet_cap_esp32c5 --list` prints to stderr and exits with status 2 | The capture framework does that; use `kismet_cap_esp32c5 --list 2>&1` |
| `python -m esp32c5_kismet.remote --list` exits with status 1 | No board was found, or on Linux every board is in use by another capture |
| `ERROR: Tried to re-register duplicate alert FLIPPERZERO` at every Kismet start | An upstream quirk of Kismet cfe427074; harmless. Do not treat `ERROR` lines in Kismet's log as failures by themselves. |
| A source shows an old error text while it runs | Kismet keeps the last `error_reason` after a reconnect or re-open |
| A local source's `error_reason` says only `IPC connection closed` after the C helper gave up | Kismet ignores the error frame a local helper sends; the helper's reason is in Kismet's log, as an `ERROR:` line just before. Kismet also sometimes starts two re-opens of a failed local source at once, and the second ends with `IPC connection closed` too. |
| `packets.frequency` in the kismetdb log is 0 for every 802.15.4 and BTLE packet | A Kismet limit: its 802.15.4 and BTLE code never sets a packet's frequency, whatever the helper sends. The device records have the right frequency. |
| A remote source closed with `close_source.cmd` runs again 5 s later | The helper reconnects, and Kismet runs the source again. To stop a remote source, stop its helper. |
| A remote source keeps an option its new definition no longer has | Kismet keeps, until it restarts, every option of a UUID it knows that the new definition leaves out: write the option out (`channel_hop=true`, say) or restart Kismet |
