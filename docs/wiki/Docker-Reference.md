This page lists everything about the project's Docker image in reference form: images and tags, Dockerfile targets and build arguments, the entrypoint's roles, every environment variable, the Compose services, volumes, ports, capabilities, the CI workflow that publishes the images, and the smoke test. For step-by-step installation, read [Install with Docker](Install-with-Docker) first.

The files described here are [`docker/Dockerfile`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/Dockerfile), [`docker/entrypoint.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/entrypoint.sh), [`docker/kismet_site.conf`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/kismet_site.conf), [`compose.yaml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/compose.yaml), [`.github/workflows/docker.yml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.github/workflows/docker.yml) and [`tests/docker_smoke.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tests/docker_smoke.sh).

## Images and tags

| Image | Dockerfile target | Contents |
|---|---|---|
| `ghcr.io/oshri-almog/esp32c5-kismet:latest` | `kismet` | Kismet with the `esp32c5` source type, the C helper `kismet_cap_esp32c5`, Kismet's stock capture helpers and its log tools. |
| `ghcr.io/oshri-almog/esp32c5-kismet:demo` | `demo` | The same, plus `python3` and the fake board, which starts by itself (`ESP32C5_DEMO=wifi`). |

- **Architectures:** `linux/amd64` and `linux/arm64`, in one multi-arch tag, so a Raspberry Pi 4 or 5 with a 64-bit OS pulls the arm64 image. No 32-bit ARM image is built.
- **Nothing is published yet.** Until the first version tag is pushed, pulls are refused (`error from registry: denied`) and Compose builds the image locally instead.
  <!-- VERIFY: once the first version tag is pushed, check the tags below on ghcr.io and a pull on amd64 and arm64, and update or remove this point -->
- **Local names** when you build by hand, as in the Dockerfile's header: `esp32c5-kismet` (that is, `esp32c5-kismet:latest`) and `esp32c5-kismet:demo`. `docker compose build` tags its build with the `ghcr.io` names above instead. Until the images are published, use the local names in place of the `ghcr.io` ones in the `docker run` commands on this page, or give your build both names (`-t esp32c5-kismet -t ghcr.io/oshri-almog/esp32c5-kismet:latest`) so that Compose uses it too.
- **Licence:** the image is Kismet, so it is GPL-2.0-or-later (label `org.opencontainers.image.licenses=GPL-2.0-or-later`), although the rest of the repository is MIT. `kismet/` is GPL-2.0-or-later as well.
- **Labels:** `org.opencontainers.image.title=esp32c5-kismet`, and the description "Kismet with the ESP32-C5 capture source: Wi-Fi 2.4/5 GHz, Zigbee/Thread and BLE advertising from ESP32-C5 boards".

### Tags

The CI workflow (see [CI workflow](#ci-workflow)) publishes these tags:

| Git ref pushed | Kismet image tags | Demo image tags |
|---|---|---|
| Release tag `v1.2.3` | `1.2.3`, `1.2`, `latest`, `sha-<7 hex>` | `1.2.3-demo`, `demo` |
| Pre-release tag `v1.1.0-rc.1` | `1.1.0-rc.1`, `sha-<7 hex>` (no `latest`, no `1.1`) | `1.1.0-rc.1-demo` (no `demo`) |
| Manual run of the workflow on `main` | `main`, `sha-<7 hex>` | `main-demo` |
| Push to `main`, pull request | nothing published (build and smoke test only) | nothing published |

`demo` moves only where `latest` moves. Use full version tags (`v1.2.3`, `v1.2.3-rc.1`): a tag that is not a full version, such as `v1.3`, does not start the workflow.

<!-- VERIFY: the tag list is read from docker.yml and metadata-action's rules; CI has never run -->

### Kismet version inside

`kismet --version` prints `Kismet <year>.<month>.0-<commit>`: Kismet builds its version from the **build date** and the short commit hash. An image built in September 2026 printed `Kismet 2026.09.0-cfe42707`, and `kismet_cap_esp32c5 --version` printed `2026.09.0-cfe42707`. The Kismet commit is `cfe427074` (`cfe427074b7ffcfcbc055a123c1df3b3cde60d59`, 16 September 2026), because no Kismet release includes this source yet.

| Command | Exit status |
|---|---|
| `kismet --version` | 1, by Kismet's design. Check the text, not the status. |
| `kismet_cap_esp32c5 --version` | 0 |
| `kismet_cap_esp32c5 --help` | 255 |
| `kismet_cap_esp32c5 --list` | 2, with the list on standard error |

## What is in the image

| Path | What |
|---|---|
| `/usr/bin/kismet` | The Kismet server. |
| `/usr/bin/kismet_server` | Kismet's shell script that says the server is now called `kismet`, then runs it. |
| `/usr/bin/kismet_cap_esp32c5` | The C helper for these boards. |
| `/usr/bin/kismet_cap_*` | Kismet's stock capture helpers. |
| `/usr/bin/kismetdb_to_pcap`, `kismetdb_to_wiglecsv`, `kismetdb_to_kml`, `kismetdb_to_gpx`, `kismetdb_statistics`, `kismetdb_dump_devices`, `kismetdb_clean`, `kismetdb_strip_packets`, `kismet_discovery` | Kismet's log and discovery tools. |
| `/etc/kismet/` | Kismet's configuration files (`kismet.conf` and the files it includes). |
| `/etc/kismet/kismet_site.conf` | This project's settings; see [Kismet configuration in the image](#kismet-configuration-in-the-image). |
| `/usr/share/kismet/httpd/` | Kismet's web UI. |
| `/usr/local/bin/esp32c5-kismet` | The entrypoint ([`docker/entrypoint.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/entrypoint.sh)). |
| `/opt/esp32c5/fake_board.py` | Demo image only: the fake board ([`tools/fake_board.py`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tools/fake_board.py)). |

**Not in the image:** the Python remote helper (`esp32c5_kismet/`), the firmware, esptool or any other flashing tool, and the tests. The build context holds only `kismet/`, `docker/` and `tools/fake_board.py` ([`.dockerignore`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.dockerignore)). The Kismet image has no Python at all; the demo image adds `python3` for the fake board.

Everything runs as root: the image sets no `USER`. Kismet raises its `ROOTUSER` alert about that at every start.

## Dockerfile

### Stages and targets

| Stage | Built from | What it does |
|---|---|---|
| `build` | `DEBIAN` | Installs the build tools, clones Kismet at `KISMET_REF`, applies `kismet/add-to-kismet.sh` with a stand-in for the helper's source, configures and compiles Kismet, builds the real helper, installs everything into `/out`, strips debug information, and works out which Debian packages the programs need at run time. |
| `kismet` | `DEBIAN` | Installs only those run-time packages, copies `/out`, the site configuration and the entrypoint, and checks that `kismet` and `kismet_cap_esp32c5` both start. Declares the volumes, the port and the entrypoint. |
| `demo` | `kismet` | Adds `python3` and the fake board, and sets `ESP32C5_DEMO=wifi`. |
| last, unnamed | `kismet` | Makes a plain `docker build` produce the Kismet image, not the demo. |

```bash
docker build -f docker/Dockerfile -t esp32c5-kismet .                        # target kismet (default)
docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .     # target demo
```

Run both from the repository root: the build context is the whole repository, filtered by `.dockerignore`.

### Build arguments

| Argument | Default | Meaning |
|---|---|---|
| `DEBIAN` | `debian:trixie-slim` | Base image of the `build` and `kismet` stages. |
| `KISMET_REPO` | `https://github.com/kismetwireless/kismet.git` | Where Kismet is cloned from. |
| `KISMET_REF` | `cfe427074` | The Kismet commit to build. If a commit has moved the lines `add-to-kismet.sh` edits, the build stops with `anchor not found, Kismet has changed: ...`. |
| `JOBS` | empty | Parallel compilers for Kismet. Empty: worked out from memory, as below. |

Pass them with `--build-arg`, for example `--build-arg JOBS=2`.

**`JOBS` when empty.** The build counts on about 1.5 GB of memory per compiler for Kismet's C++, so it uses `MemAvailable` (in kB) divided by 1,500,000, then caps it at the number of cores and at 4, with a minimum of 1. An 8 GB Raspberry Pi 4 got 4; a 2 GB Pi gets 1. The build prints `building with -j<N>`.

Some files need more than 1.5 GB. On the 8 GB Pi, one Kismet file (`phy_80211.cc`) needed about 2.4 GB for its own compiler, more than a 2 GB Pi has in all, so a 2 GB Pi probably needs swap even at `-j1`. This is untested.

<!-- VERIFY: a Docker build on a 2 GB Pi, with and without swap -->

**Build arguments and the cache.** Changing `JOBS`, `KISMET_REF`, `KISMET_REPO` or `DEBIAN` from one build to the next misses Docker's cache from that point, so Kismet compiles again. Keep `JOBS` at one value, or unset.

<!-- VERIFY: the cache miss on a changed build argument is general Docker behaviour, not tried here -->

### Build and run-time packages

- **Build stage** (Debian, `--no-install-recommends`): `ca-certificates git build-essential pkg-config autoconf automake python3 libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev libsqlite3-dev libpcre2-dev libssl-dev libusb-1.0-0-dev libdw-dev`.
- **Kismet's configure options:** `--prefix=/usr --sysconfdir=/etc/kismet --localstatedir=/var --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger --disable-libnm --disable-lmsensors --disable-mosquitto`. The parts left out are hardware the image is not for (SDRs, Ubertooth, bladeRF) or host services a container does not have (NetworkManager, lm-sensors, MQTT).
- **Install:** `make install DESTDIR=/out INSTUSR=root INSTGRP=root SUIDGROUP=root`, then `strip --strip-debug` on every ELF program. That keeps the symbol table, so a crash backtrace still names functions, and shrinks `/usr/bin/kismet` from about 470 MB to under 15 MB.
- **Run-time stage:** the packages that hold the libraries the installed programs link against (found with `ldd` and `dpkg -S`), plus `ca-certificates`. On amd64 that was `libbz2-1.0 libc6 libcap2 libdbus-1-3 libdw1t64 libelf1t64 libgcc-s1 liblzma5 libnl-3-200 libnl-genl-3-200 libpcap0.8t64 libpcre2-8-0 libsqlite3-0 libssl3t64 libstdc++6 libsystemd0 libudev1 libusb-1.0-0 libwebsockets19t64 libzstd1 zlib1g`. The demo adds `python3`.

### What a change rebuilds

Kismet is built first with a stand-in for the helper's source, so that the long Kismet layer stays cached while only the helper changes.

| Changed | What rebuilds |
|---|---|
| `kismet/capture_esp32c5/capture_esp32c5.c` | The helper, its install, the strip and package steps, and the run-time stage; when you build the demo, the whole demo stage too. Kismet stays cached. |
| `kismet/datasource_esp32c5.h`, `kismet/add-to-kismet.sh`, `kismet/capture_esp32c5/Makefile.in` | Everything from applying `add-to-kismet.sh` on: Kismet compiles again. |
| `docker/entrypoint.sh`, `docker/kismet_site.conf` | The run-time stage's copy and check; when you build the demo, the whole demo stage too. |
| `tools/fake_board.py` | Only the demo stage's copy of it. |
| A build argument | Everything after it (see above). |

Other files under `kismet/`, such as `kismet/COPYING.md`, are not copied into the build, so a change to them rebuilds nothing. The demo stage is built on the run-time stage, so it is rebuilt whenever that stage is, and its `apt-get install python3` then needs the network again.

On the Raspberry Pi 4, a helper-only change rebuilt in about a minute, with Kismet taken from the cache.

### Build times and sizes

| Machine | First build | Notes |
|---|---|---|
| Windows 11 PC, Docker Desktop 4.92 (Docker Engine 29.8, amd64); Docker's VM had 20 CPUs and 16 GB, as `docker info` reported | 18.5 minutes (demo target) | Configuring, compiling and installing Kismet took 17.5 minutes at `-j4`, the clone 32 s. Rebuilds from the cache: 2 to 39 s. |
| Raspberry Pi 4, 8 GB, Debian 13, Docker 26.1.5 (arm64) | about 80 minutes (both targets, demo then kismet) | Almost all of it the Kismet compile at `-j4`, which the build chose from the free memory. A native Kismet compile on the same Pi took about 78 minutes. |
| Raspberry Pi, 2 GB | not measured | `-j1`, so much longer, and probably only with swap: one Kismet file needed about 2.4 GB for its own compiler on the 8 GB Pi. Untested. |
| GitHub Actions runners | not measured | The jobs time out after 120 minutes (amd64) and 180 minutes (arm64). |

<!-- VERIFY: a Docker build on a 2 GB Pi, with and without swap (the 2 GB row) -->

| Image (amd64) | Size | Before the strip step |
|---|---|---|
| `esp32c5-kismet:latest` | 177 MB | 895 MB |
| `esp32c5-kismet:demo` | 227 MB | 946 MB |

The arm64 sizes have not been measured.

<!-- VERIFY: add the arm64 image sizes from the Pi build (docker image ls) -->

The build needs internet access: Debian's package servers, GitHub for the Kismet clone, and Docker Hub for the base image and the `docker/dockerfile:1` syntax image.

A Windows checkout is safe to build: [`.gitattributes`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.gitattributes) (`* text=auto eol=lf`) keeps LF line ends even with `core.autocrlf=true`, and the Dockerfile strips carriage returns from the scripts it copies as well.

## Entrypoint roles

The entrypoint is `/usr/local/bin/esp32c5-kismet`, a POSIX `sh` script. The first argument after the image name picks its role; the default, from `CMD`, is `kismet`. Its own messages start with `[esp32c5-kismet]` and go to standard error.

| First argument | Role |
|---|---|
| `kismet` (default) | Kismet, with one source per board found, or the sources in `KISMET_SOURCES`. Arguments after `kismet` go to Kismet unchanged. |
| `helper` | No Kismet: one `kismet_cap_esp32c5` per source, feeding the Kismet at `KISMET_SERVER` over remote capture, each restarted when it exits. |
| anything else | Run as a command, with the boards' device nodes kept up to date for it. |

To pass options to Kismet, keep the word `kismet` first: `docker run ... IMAGE kismet --no-logging`. `docker run ... IMAGE --no-logging` would try to run `--no-logging` as a command.

### Role `kismet`, step by step

1. If any argument is `-v`, `--version`, `-h` or `--help`, run `kismet` with the arguments straight away: no login, boards or demo.
2. Set the web login (see [Web login](#web-login)).
3. Keep the device nodes in sync (see [Device access](#device-access)): once now, then every second in the background.
4. **Demo image only**, when `ESP32C5_DEMO` is not empty: start the fake board on `/tmp/esp32c5-demo` in that radio, wait 1 s, log `demo: a fake board on /tmp/esp32c5-demo`, and add the source `esp32c5:device=/tmp/esp32c5-demo,mode=<ESP32C5_DEMO>,name=demo`. With the fake board running, the entrypoint does not look for boards; sources in `KISMET_SOURCES` are still added.
5. Work out the sources: `KISMET_SOURCES` as given, or else one `esp32c5-<tty>:mode=<ESP32C5_MODE>` for each board found.
6. If there is no demo board, no source and no Espressif board in sysfs at all (one the container may not use does not become usable by waiting), and `ESP32C5_WAIT` is above 0: log `waiting up to <n> s for an ESP32-C5 board`, and look again every 2 s for up to `ESP32C5_WAIT` seconds. Once a board is found, keep looking every 2 s until two looks in a row agree, so that boards on a hub that come up one after another are all taken, but never beyond `ESP32C5_WAIT` + 10 s from the start of the wait (40 s with the default).
7. Log `source: <definition>` for each source and add `-c <definition>` after your own arguments.
8. With no source at all, log the no-board message and start Kismet anyway, so that remote helpers can still connect. Otherwise log `Kismet starts with <n> source(s)`.
9. Check for NET_ADMIN (see [Capabilities](#capabilities)).
10. Run `kismet --no-ncurses <your arguments> -c <definition> ...`.

The sources are worked out once. A board plugged in later gets its device node but is not added as a source.

<!-- VERIFY: steps 4 and 6 (demo no longer looks for boards; waiting until the list settles) are new in the entrypoint and have not been run -->

### Role `helper`, step by step

1. Require `KISMET_SERVER`, the `HOST:PORT` of the Kismet to feed, on its web port.
2. Hand the credentials to the helper through its environment, not its command line, where every account on the host could read them in the process list: `KISMET_APIKEY` becomes `KISMET_CAP_APIKEY`; otherwise `KISMET_USER` and `KISMET_PASSWORD` become `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`. Then unset `KISMET_APIKEY` and `KISMET_PASSWORD`.
3. Keep the device nodes in sync, as in the `kismet` role.
4. Work out the sources as in the `kismet` role. There is no wait for a first board, but when boards were found by themselves (no `KISMET_SOURCES`) and `ESP32C5_WAIT` is not `0`, the list is checked again every 2 s until two checks agree, at most 10 s. <!-- VERIFY: the helper role's settle wait (entrypoint changed after the last Docker test) -->
5. Check for NET_ADMIN, which this role always needs. <!-- VERIFY: NET_ADMIN removed? -->
6. For each source, loop forever: log `helper: <definition> -> <KISMET_SERVER>`, run `kismet_cap_esp32c5 --connect "$KISMET_SERVER" --source "<definition>"`, and when it exits, wait 5 s and start again. The helper gives up on a board that stays away for 15 s, and on a server it cannot reach. A definition that names no port stops it before it connects when there is no board or more than one (`Could not probe local source prior to connecting to the remote host: <reason>`), so such a source is tried again every 5 s until the board is there. A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) connects anyway, and Kismet shows the open error as the source's error. <!-- VERIFY: that a remote C helper whose named port is missing connects and reports the open error (read from capture_esp32c5.c probe_callback and resolve_device) -->
7. On SIGINT or SIGTERM (`docker stop`), stop every loop and helper and exit 0. In a test, `docker stop` took about 1 s.

### Other commands

The entrypoint keeps the device nodes in sync, then runs the command. Examples:

```bash
docker run --rm ghcr.io/oshri-almog/esp32c5-kismet:latest kismet_cap_esp32c5 --list
docker run --rm -it ghcr.io/oshri-almog/esp32c5-kismet:latest sh
```

`kismet_cap_esp32c5 --list` reads sysfs and `/proc/locks` and never opens a port, so it lists the boards even without the device rules. It prints its list on standard error and exits 2 whether or not it found a board, by Kismet's design; with no board the list reads `esp32c5 - No supported data sources found...`. It leaves out a board whose port is held by a capture it can see, but a new container sees none of another container's captures. To see which boards are free inside the running `kismet` service, run it there:

```bash
docker compose exec kismet kismet_cap_esp32c5 --list
```

<!-- VERIFY: --list inside the kismet service leaving out the boards its sources hold (/proc/locks in the same container); not run -->

A capture started with a command of your own needs the device rules and NET_ADMIN, as the services have.

<!-- VERIFY: NET_ADMIN removed? -->
<!-- VERIFY: the exec role making device nodes is new in the entrypoint; not run -->

### Entrypoint messages

| Message | Meaning |
|---|---|
| `no web login was set, so Kismet's is now: user admin, password <24 hex>` and `(kept in the /root/.kismet volume; set KISMET_USER and KISMET_PASSWORD to choose one)` | A login was made up. Printed once. |
| `KISMET_USER and KISMET_PASSWORD go together; ignoring the one that is set` | Only one of the two is set. |
| `found <tty> in sysfs but the container may not use it: allow it with` / `compose.yaml's device_cgroup_rules, or docker run --device-cgroup-rule 'c <major>:* rmw'` | A board is there but the device rules do not allow its class. |
| `demo: a fake board on /tmp/esp32c5-demo` | Demo image: the fake board started. |
| `waiting up to <n> s for an ESP32-C5 board` | No board at start; see `ESP32C5_WAIT`. |
| `source: <definition>` | A source Kismet starts with. |
| `Kismet starts with <n> source(s)` | Sources counted, Kismet starting. |
| `no ESP32-C5 board found. Plug one in and restart the container, or add sources from` / `the web UI (Data Sources); boards plugged in now appear in the container on their own.` | Kismet starts without sources. |
| `Kismet starts with no source: no board here that the container may use (see above)` | Kismet starts without sources, because the only boards found are in a class the device rules do not allow. |
| `the container has no NET_ADMIN capability, and without it Kismet's capture helpers` / `crash on start. Add --cap-add NET_ADMIN to docker run (compose.yaml has it).` | Local sources, no NET_ADMIN. |
| `no NET_ADMIN capability: sources from remote helpers work, boards plugged into this` / `machine would not (add --cap-add NET_ADMIN for those)` | No local sources, no NET_ADMIN. |
| `helper: <definition> -> <server>` | Helper role: a helper starts for this source. |

<!-- VERIFY: message texts are from the current entrypoint; only the login, NET_ADMIN (first form), no-board and helper lines have appeared in a run, with older wording in places -->

### Exit status of the `helper` role

| Status | Message (standard error) | Cause |
|---|---|---|
| 2 | `.../esp32c5-kismet: <line>: KISMET_SERVER: KISMET_SERVER must be HOST:PORT of the Kismet to feed` | `KISMET_SERVER` unset or empty. |
| 2 | `helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD` | No credentials, or only one of user and password. |
| 2 | `helper: KISMET_USER and KISMET_PASSWORD cannot contain '&', a space or %XX for remote capture; use KISMET_APIKEY, or another password` | Kismet decodes the whole query string of the remote-capture URL before splitting it on `&`, so these characters cannot get through. |
| 1 | `helper: no ESP32-C5 board found and KISMET_SOURCES is empty` | Nothing to feed. Compose's `restart: unless-stopped` starts the container again. |
| 0 | none | Stopped by `docker stop`. |

## Environment variables

Compose takes each value from the shell's environment or from a `.env` file next to `compose.yaml`; the shell's value wins. Each service passes on only the variables listed for it, so a variable not listed for a service has no effect there under Compose.

| Variable | Used by | Default in the image | Compose default | Meaning |
|---|---|---|---|---|
| `KISMET_SOURCES` | `kismet`, `helper` roles | empty | empty (`kismet`, `helper`); not passed (`demo`) | Source definitions separated by spaces, such as `"esp32c5-ttyACM0:mode=wifi esp32c5-ttyACM1:mode=zigbee esp32c5-ttyACM2:mode=btle"`, or with a board's by-id link, `"esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee"`. A definition cannot contain a space. Empty: every board found, each in `ESP32C5_MODE`. See [Source Definitions](Source-Definitions). |
| `ESP32C5_MODE` | `kismet`, `helper` roles | `wifi` | `wifi` (`kismet`, `helper`) | `wifi`, `zigbee` or `btle`: the radio for boards found by the container. Passed on as `mode=` without checking; the C helper also accepts its other radio words. |
| `ESP32C5_WAIT` | `kismet`, `helper` roles | `30` | not passed by any service | `kismet` role: seconds to wait at start for a first board when none is there. Once one is found, the entrypoint looks again every 2 s until the list stops changing, for at most `ESP32C5_WAIT` + 10 s in all. `helper` role: no wait for a first board, only the look again every 2 s, at most 10 s. Both only for boards found by themselves. `0` turns it off. Under Compose, set it in a `compose.override.yaml`. |
| `KISMET_USER`, `KISMET_PASSWORD` | `kismet`, `helper` roles | empty | empty (`kismet`, `helper`); `demo` / `demo` (`demo`) | `kismet` role: the web login, written at every start when both are set. `helper` role: the remote-capture login when there is no API key. They work only as a pair. |
| `KISMET_SERVER` | `helper` role | none (required) | empty (`helper`) | `HOST:PORT` of the Kismet to feed, on its web port, usually 2501. |
| `KISMET_APIKEY` | `helper` role | empty | empty (`helper`) | A Kismet API key with the `datasource` role. It wins over `KISMET_USER` and `KISMET_PASSWORD`. |
| `ESP32C5_DEMO` | `kismet` role, demo image | `wifi` in the demo image; unset in the Kismet image | `wifi` (`demo`) | The fake board's radio: `wifi`, `zigbee` (or `802154`) or `btle` (or `ble`). Empty turns the fake board off, and the demo image then behaves like the Kismet image. No effect in the Kismet image. |
| `KISMET_PORT` | Compose only | not applicable | `2501` | The host port for Kismet's web port: all interfaces for `kismet` (`"${KISMET_PORT:-2501}:2501"`), loopback only for `demo` (`"127.0.0.1:${KISMET_PORT:-2501}:2501"`). A port number only: with an address in front, Compose refuses the whole file (see [Ports and network](#ports-and-network)). |
| `KISMET_CAP_APIKEY`, `KISMET_CAP_USER`, `KISMET_CAP_PASSWORD` | `kismet_cap_esp32c5`, and the Python remote helper outside the image | set by the `helper` role | not passed | The remote-capture login. **Both helpers**, with `--connect` (never with `--tcp`): with none of `--user`, `--password` and `--apikey`, they take `KISMET_CAP_APIKEY`, or else `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD` (the API key wins when both kinds are set); with half a login they fill in the other half: `--user` alone takes `KISMET_CAP_PASSWORD`, `--password` alone takes `KISMET_CAP_USER`. A value on the command line wins; empty counts as unset. The Python remote helper stops with `give both --user and --password` only when the missing half is not in the environment either. **Only the C helper** also reads them with `--autodetect` or `--host`. |

<!-- VERIFY: the final Python remote helper against this row: KISMET_CAP_* read with --connect only, never with --tcp; --user alone completed from KISMET_CAP_PASSWORD and --password alone from KISMET_CAP_USER (login_from_env); the "give both --user and --password" error only when the other half is missing from the environment too; its review was still running -->

Use each value of `KISMET_USER` and `KISMET_PASSWORD` in `.env` with care: every service that passes them on uses them. The demo's `demo` / `demo` applies only while they are unset.

## Compose file

The project name is `esp32c5-kismet`. Every service has both `image:` and `build:` (context `.`, `docker/Dockerfile`), so Compose builds the image when it cannot pull it.

### Services and profiles

| Service | Profile | Image | Target | Command | Ports | Volumes | Device rules | NET_ADMIN | `restart` | `init` |
|---|---|---|---|---|---|---|---|---|---|---|
| `kismet` | none (default) | `ghcr.io/oshri-almog/esp32c5-kismet:latest` | `kismet` | `kismet` (default) | `${KISMET_PORT:-2501}:2501` | `kismet-data:/data`, `kismet-home:/root/.kismet` | yes | yes | `unless-stopped` | `true` |
| `demo` | `demo` | `ghcr.io/oshri-almog/esp32c5-kismet:demo` | `demo` | `kismet --no-logging` | `127.0.0.1:${KISMET_PORT:-2501}:2501` | anonymous | no | yes | none | `true` |
| `helper` | `helper` | `ghcr.io/oshri-almog/esp32c5-kismet:latest` | `kismet` | `helper` | none | anonymous | yes | yes | `unless-stopped` | `true` |

The `kismet` and `helper` services get the device rules and NET_ADMIN from a shared block (`x-serial`). The `demo` service has no device rules, runs Kismet without logging (Kismet then raises `ALERT: LOGDISABLED`), and does not look for boards.

<!-- VERIFY: NET_ADMIN removed? -->

### Commands

```bash
docker compose up -d                            # Kismet, one Wi-Fi source per board plugged in
docker compose --profile demo up demo           # no hardware needed: Kismet and a fake board
docker compose --profile helper up -d helper    # no Kismet here: feed the boards to one elsewhere
docker compose logs kismet | grep "web login"   # the made-up login
```

Name the service when you use a profile: `docker compose --profile demo up` on its own also starts the `kismet` service, which then clashes on the port or competes for the boards. What matters is the name, not the profile: Compose acts on a service named on the command line whatever its profile, so `--profile` beside the name does no harm but is not needed, and a command with no service name acts on the `kismet` service as well ([Docker's page on profiles](https://docs.docker.com/compose/how-tos/profiles/)). The same goes for the other commands on a machine that runs only the `helper` service: `docker compose --profile helper pull helper`, `build helper`, `logs -f helper`, `restart helper` and `stop helper`. A plain `docker compose up -d` there would start the `kismet` service beside the helper (a plain `pull` is harmless: it fetches the same image). On Linux without the `docker` group, put `sudo` in front.

<!-- VERIFY: with Compose 5.5.1, `ps -a helper`, `logs helper` and `config helper` worked without --profile; check stop, restart and down without it before dropping the flag -->

### docker run equivalents

Derived from `compose.yaml`. The demo command is the Dockerfile's own example; the other two have not been run as written.

```bash
docker run -d --name esp32c5-kismet --restart unless-stopped --init --cap-add NET_ADMIN \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet \
    ghcr.io/oshri-almog/esp32c5-kismet:latest
docker run -d --name esp32c5-helper --restart unless-stopped --init --cap-add NET_ADMIN \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -e KISMET_SERVER=192.168.1.50:2501 -e KISMET_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35 \
    ghcr.io/oshri-almog/esp32c5-kismet:latest helper
docker run --rm --cap-add NET_ADMIN -p 127.0.0.1:2501:2501 \
    -e KISMET_USER=demo -e KISMET_PASSWORD=demo ghcr.io/oshri-almog/esp32c5-kismet:demo
```

<!-- VERIFY: run the kismet and helper docker run commands as written -->
<!-- VERIFY: NET_ADMIN removed? -->

Change the server address and the API key in the second command to yours. For the demo in the other radios, add `-e ESP32C5_DEMO=zigbee` or `-e ESP32C5_DEMO=btle`.

Until the images are published, build them ([Dockerfile](#dockerfile)) and write `esp32c5-kismet` and `esp32c5-kismet:demo` in place of `ghcr.io/oshri-almog/esp32c5-kismet:latest` and `ghcr.io/oshri-almog/esp32c5-kismet:demo`, here and in [Other commands](#other-commands).

## Volumes and paths

| Path in the container | Volume | Holds |
|---|---|---|
| `/data` | `kismet-data` in Compose, named `esp32c5-kismet_kismet-data` by Docker | Kismet's logs (`log_prefix=/data/`), one `.kismet` database per run by default, such as `/data//Kismet-20260928-11-13-48-1.kismet` (the double slash is Kismet's own; times are UTC). Also the working directory. |
| `/root/.kismet` | `kismet-home` in Compose, named `esp32c5-kismet_kismet-home` by Docker | The web login `kismet_httpd.conf` (mode 0600), `session.db` with the API keys and sessions, and Kismet's other per-user state. |
| `/tmp/esp32c5-demo` | none | Demo image: the fake board's serial port. Its log is `/tmp/fake-board.log`. |
| `/dev/ttyACM*`, `/dev/ttyUSB*` | none | Device nodes made by the entrypoint from sysfs. |
| `/dev/serial/by-id/` | none | Links made by the entrypoint, named as udev names them on the host, unless the directory was already there. |

- Both volume paths are declared in the image (`VOLUME ["/data", "/root/.kismet"]`). The `demo` and `helper` services, and a `docker run` without `-v`, therefore get two unnamed volumes per container; `docker rm -v` removes them with the container.
- `docker compose down -v` deletes the named volumes, and with them the login, the API keys and every log. An API key survived `docker restart` in a test; it survives re-creating the container only because `/root/.kismet` is a named volume.
- Never clean up with `docker volume prune` or `docker system prune --volumes`: they delete every unused unnamed volume on the machine, not only this project's, and `docker volume prune -a` deletes unused named volumes as well. Remove containers and volumes by name (`docker rm -f -v esp32c5-helper`, `docker volume rm esp32c5-kismet_kismet-home`).

## Ports and network

| Port | In the container | Carries | Published |
|---|---|---|---|
| 2501/tcp | Kismet's web server, on all container interfaces (`HTTP server listening on 0.0.0.0:2501`) | The web UI, the REST API, and remote capture over a websocket at `/datasource/remote/remotesource.ws`, which needs a login or an API key. | `EXPOSE 2501`. `kismet` service: all host interfaces. `demo`: host loopback only. `helper`: nothing. |
| 3501/tcp | Kismet's legacy TCP remote capture, on the container's loopback only (Kismet's default `remote_capture_listen=127.0.0.1`) | Helpers started with `--tcp`. It has no authentication at all. | Not exposed, and unreachable from outside the container. |

- To use the legacy port anyway, mount your own site configuration with `remote_capture_listen=0.0.0.0` and publish 3501 only on a network you trust. See [Remote Capture](Remote-Capture).
- **Keeping the `kismet` service on the host's loopback.** Do not put an address in `KISMET_PORT`. The `demo` service puts `127.0.0.1:` in front of the same variable, and Compose reads every service's ports when it loads the file, so `KISMET_PORT=127.0.0.1:2501` makes every Compose command fail with `invalid IP address: 127.0.0.1:127.0.0.1`, even `docker compose up -d` for the `kismet` service alone (checked with `docker compose config`, Compose 5.5.1). Replace the service's port list in a `compose.override.yaml` next to `compose.yaml` instead. The `!override` tag makes the list replace the one in `compose.yaml`; without it, Compose adds the new entry to the old one and publishes both:

  ```yaml
  services:
    kismet:
      ports: !override
        - "127.0.0.1:2501:2501"
  ```

  With `docker run`, use `-p 127.0.0.1:2501:2501`.
  <!-- VERIFY: the override was checked with `docker compose config` only (Compose 5.5.1 on Docker Desktop 4.92, Docker Engine 29.8); start the service with it and check that port 2501 answers on 127.0.0.1 and not on the LAN address, and which Compose version first accepts !override -->
- Ports that Docker publishes are opened by Docker's own firewall rules, which bypass front ends such as ufw. Publish on loopback, or on a trusted network only, if that matters.
  <!-- VERIFY: general Docker behaviour, not tested here -->
- The Compose services are on Compose's default bridge network, `esp32c5-kismet_default`, not the host's network.

## Capabilities

| Setting | `kismet` | `demo` | `helper` | `docker run` |
|---|---|---|---|---|
| NET_ADMIN | yes | yes | yes | `--cap-add NET_ADMIN` |

Kismet's capture helpers, run as root, keep NET_ADMIN and NET_RAW and drop every other capability. Docker's default set lacks NET_ADMIN, so that step fails and the helper crashes with signal 11 before it opens the board; Kismet then reports only `cancelling source probe due to timeout` or `Unable to find driver`, and logs `capture process exited 0 signal 11`. Kismet's stock `kismet_cap_catsniffer_zigbee` crashes the same way.

NET_ADMIN is needed only by helpers started in the container. A container that only receives remote sources works without it (tested twice). The entrypoint checks bit 12 (CAP_NET_ADMIN) of `CapEff` in `/proc/self/status` when it runs as root, and warns if it is missing; the two warnings are in [Entrypoint messages](#entrypoint-messages).

<!-- VERIFY: NET_ADMIN removed? -->

## Device access

| Setting | `kismet` | `demo` | `helper` | `docker run` |
|---|---|---|---|---|
| Device rule `c 166:* rmw` (ttyACM, the boards' native USB) | yes | no | yes | `--device-cgroup-rule 'c 166:* rmw'` |
| Device rule `c 188:* rmw` (ttyUSB) | yes | no | yes | `--device-cgroup-rule 'c 188:* rmw'` |

- **Nodes.** The container does not share the host's `/dev`. The entrypoint reads `/sys/class/tty/ttyACM*/dev` and `ttyUSB*/dev` (a container sees the host's sysfs) and makes each node with `mknod -m 660`. It replaces a node whose device number changed, removes nodes whose device has gone, and repeats every second, so a board plugged in again, or back under another number, gets its node within about a second.
- **by-id links.** It also makes `/dev/serial/by-id/usb-<manufacturer>_<product>_<serial>-if<interface>` links, as udev does on the host; for these boards that is `usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00`. It leaves an existing `/dev/serial/by-id` alone.
- **Which classes may be opened.** Docker lets a container make any device node; only opening it is refused by the device rules. So at start the entrypoint opens one node per class on a device number that no device uses (never a board's own port, since opening a board's port moves DTR and RTS, its reset lines). A board whose class is refused is logged and left out.
- **Nodes given by Docker.** Nodes already in `/dev` before the entrypoint made any, such as those from `docker run --device /dev/ttyACM0`, are used as they are and left alone. A fixed `--device` entry does not follow a board that comes back under another number.
- **Discovery.** A tty is a board when its USB device has vendor `303a` and product `1001`. The port is not opened to check. The ESP32-C3, C6, H2, S3 and P4 share this ID; with any of them plugged in, list the sources in `KISMET_SOURCES`.
- **Why not `/dev:/dev`.** It would hand the container every device node on the host: terminals, `/dev/shm`, disks.

<!-- VERIFY: the device-class probe, by-id links and --device handling are new in the entrypoint; real boards in a container have not been tested at all -->

> **Warning:** The port lock the helpers take (`flock` on the device node) does not cross the container boundary: each container makes its own node. A board used by the `kismet` service can still be opened from the host or from another container, and the two would fight over it. Stop the service before using its boards elsewhere. On one host outside containers, the lock works: the C helper and the Python remote helper refuse a board the other holds.

<!-- VERIFY: the helpers are to set TIOCEXCL on the tty so that the lock also holds between a container and the host, and between containers; if that has landed, restate this warning -->

## Web login

The `kismet` role always sets a login before Kismet starts, because Kismet without one lets the first visitor to port 2501 choose it. The login file is `/root/.kismet/kismet_httpd.conf`, with `httpd_username=` and `httpd_password=` lines, written with mode 0600 (Kismet's logs in `/data` stay 0644).

| Situation | Login used |
|---|---|
| `KISMET_USER` and `KISMET_PASSWORD` both set | Written at every start, replacing a kept login. |
| Otherwise, a kept file with both lines non-empty | Used unchanged (a login from an earlier run, or one set in the web UI). |
| Otherwise | User `admin`, a random password of 24 lowercase hex characters, printed once. |

- Find the printed login: `docker compose logs kismet | grep "web login"`, or `docker logs <container> 2>&1 | grep "web login"`.
- After the container is recreated, read the file: `docker compose exec kismet cat /root/.kismet/kismet_httpd.conf`.
- Reset: set both variables, or, with neither set, delete the `kismet-home` volume, which also deletes the API keys and sessions but keeps the logs. Docker does not delete a volume that a container still uses, even a stopped one, so remove the container first. With Compose: `docker compose down`, then `docker volume rm esp32c5-kismet_kismet-home`, then `docker compose up -d`. With `docker run`: `docker rm -f esp32c5-kismet`, then `docker volume rm kismet-home`, then the `docker run` command again. Not `docker compose down -v`, which deletes the logs too.
  <!-- VERIFY: the reset commands were not run -->
- A password with a space and `#` worked for the web login and the REST API in a test. For remote capture from the `helper` role, see the character limit above.

<!-- VERIFY: the grep and exec commands against the current entrypoint -->

## Kismet configuration in the image

[`docker/kismet_site.conf`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/kismet_site.conf) is installed as `/etc/kismet/kismet_site.conf`. Kismet loads it after every other configuration file, so its settings win. Its one setting is:

```ini
log_prefix=/data/
```

It also explains why port 3501 stays on loopback. To change more, mount your own file over it, and keep `log_prefix=/data/` in it so that the logs stay in the volume. With Compose, in a `compose.override.yaml` next to `compose.yaml`:

```yaml
services:
  kismet:
    volumes:
      - ./kismet_site.conf:/etc/kismet/kismet_site.conf:ro
```

With `docker run`, add `-v "$PWD/kismet_site.conf:/etc/kismet/kismet_site.conf:ro"`. Save the file with LF line ends: a mounted file is not cleaned of carriage returns the way the image's own copy is.

<!-- VERIFY: mounting your own kismet_site.conf was not tried, nor whether Kismet minds CRLF -->

Kismet's defaults, as seen in a container's log: channel hopping at 5 channels per second, channel lists split and shuffled among sources of one type, and sources re-opened after an error. [Kismet Configuration](Kismet-Configuration) lists the options.

## CI workflow

[`.github/workflows/docker.yml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.github/workflows/docker.yml), named "Docker image". It has not run yet.

<!-- VERIFY: every trigger, tag and timing in this section once CI has run (the first push to GitHub and the first version tag), then update or remove "It has not run yet" -->

| Event | Runs | Publishes |
|---|---|---|
| Push to `main` | when `kismet/**`, `docker/**`, `.dockerignore`, `tools/fake_board.py`, `tests/docker_smoke.sh` or the workflow changed | no |
| Pull request | same paths | no |
| Push of a version tag (`v1.2.3`, `v1.2.3-rc.1`) | always (GitHub does not apply path filters to tag pushes) | yes |
| Manual run (`workflow_dispatch`) | always | yes |

**Build job,** once per architecture, each on a native runner, since under QEMU emulation the Kismet build would take hours:

| Platform | Runner | Timeout |
|---|---|---|
| `linux/amd64` | `ubuntu-24.04` | 120 minutes |
| `linux/arm64` | `ubuntu-24.04-arm` | 180 minutes |

Steps: check out (without keeping credentials); lower-case the image name, as ghcr.io requires; set up Buildx; build the demo target into the runner's Docker, with the GitHub Actions cache (`type=gha`, `mode=max`, one scope per platform); run the smoke test on it; when publishing, log in to ghcr.io with `GITHUB_TOKEN`; set the labels (again, so that the repository's MIT licence does not replace the image's GPL); build the Kismet target and push it by digest (the push only when publishing); push the demo by digest and upload the digests as the artifact `digests-<platform>` (kept 1 day), both only when publishing. The two platforms run independently (`fail-fast: false`).

**Publish job,** only for version tags and manual runs: download the digests, join the two architectures into one multi-arch image per tag list with `docker buildx imagetools create`, and inspect the result. The tags are in [Tags](#tags).

**Other details:**

- Image name `ghcr.io/<repository owner>/esp32c5-kismet`, lower-cased: `ghcr.io/oshri-almog/esp32c5-kismet`.
- Permissions: `contents: read` for the workflow, `packages: write` for the two jobs.
- Actions are pinned to commit SHAs: `actions/checkout` v4.4.0, `docker/setup-buildx-action` v3.12.0, `docker/build-push-action` v6.19.2, `docker/login-action` v3.7.0, `docker/metadata-action` v5.10.0, `actions/upload-artifact` v4.6.2, `actions/download-artifact` v4.3.0. [`.github/dependabot.yml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.github/dependabot.yml) updates them monthly.
- The arm64 runner is free in public repositories and, since 29 January 2026, also runs in private ones on the plan's minutes.

## Smoke test

[`tests/docker_smoke.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tests/docker_smoke.sh) checks a demo image without hardware: the fake board feeds Kismet in each radio, then the `helper` role feeds a Kismet in a second container over remote capture. CI runs it on both architectures.

```bash
docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
sh tests/docker_smoke.sh esp32c5-kismet:demo
```

From Git Bash on Windows:

```bash
PYTHON=python sh tests/docker_smoke.sh esp32c5-kismet:demo
```

| Setting | Default | Meaning |
|---|---|---|
| first argument | `esp32c5-kismet:demo` | The image to test. It must be a demo image. |
| `PYTHON` | `python3` | Python on the host, used to read Kismet's JSON. `python` on Windows. |
| `SMOKE_PORT` | `2599` | Host port for the Kismet under test (on loopback). |
| `SMOKE_NAME` | `esp32c5-smoke` | Prefix of the containers (`<name>`, `<name>-version`, `<name>-server`, `<name>-helper`) and the network (`<name>-net`). Change it and `SMOKE_PORT` to run beside another copy. |

It needs `docker`, `curl` and Python on the host. It removes its containers, their volumes and its network when it ends, and switches off Git Bash's path rewriting for its own `docker` commands. It logs in to Kismet as `smoke` / `smoke-password`.

The 19 checks:

| Part | Checks |
|---|---|
| Image | `kismet_cap_esp32c5` is in the image (`--version`). |
| Wi-Fi demo, 35 s | Kismet answers; the esp32c5 source is running; packets received; decoded as 802.11; the 2.4 GHz access point `ESP32C5-FAKE-24`; the 5 GHz access points `ESP32C5-FAKE-5LOW` and `ESP32C5-FAKE-5HIGH`. |
| 802.15.4 demo, 25 s | Kismet answers; source running; packets received; decoded as 802.15.4. |
| BTLE demo, 20 s | Kismet answers; source running; packets received; decoded as BTLE; the advertiser name `ESP32C5-FAKE`. |
| Helper role | A server container (without NET_ADMIN, and with `ESP32C5_WAIT=0`) answers; a helper container with a fake board makes the remote source run; the access point is seen through remote capture. |

It prints a `PASS` or `FAIL` line per check, the container logs when something failed, and `ALL OK` at the end. The exit status is 0 when every check passed, 1 otherwise.

Result so far: 19 of 19 passed, `ALL OK`, in 132 s, on Docker Desktop (Windows, amd64), with an image built from earlier Docker files and an earlier version of the script.

<!-- VERIFY: run the current smoke test against an image built from the current files, on amd64 and on the Pi -->

## Kismet messages you will see in container logs

These come from Kismet at commit `cfe427074`, not from this project:

- `ERROR: Tried to re-register duplicate alert FLIPPERZERO` at every start. Harmless; do not treat "ERROR" lines alone as a failure.
- `ALERT: ROOTUSER Kismet is running as root`: the container runs as root.
- `INFO: (HTTPD) Could not read session data file, skipping loading saved sessions.` on a new `kismet-home` volume.
- `Launching remote capture server on 127.0.0.1 3501`: the legacy port, on loopback.
- `Loading optional sub-config file: /etc/kismet/kismet_site.conf`: the image's settings are in use.

More in [Troubleshooting](Troubleshooting).
