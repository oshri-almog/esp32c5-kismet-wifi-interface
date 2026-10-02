This page lists everything about the project's Docker image in reference form: images and tags, Dockerfile targets and build arguments, the entrypoint's roles, every environment variable, the Compose services, volumes, ports, capabilities, the CI workflow that publishes the images, and the smoke test. For step-by-step installation, read [Install with Docker](Install-with-Docker) first.

The files described here are [`docker/Dockerfile`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/Dockerfile), [`docker/entrypoint.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/entrypoint.sh), [`docker/kismet_site.conf`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/kismet_site.conf), [`compose.yaml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/compose.yaml), [`.github/workflows/docker.yml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.github/workflows/docker.yml) and [`tests/docker_smoke.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/tests/docker_smoke.sh).

## Images and tags

| Image | Dockerfile target | Contents |
|---|---|---|
| `ghcr.io/oshri-almog/esp32c5-kismet:latest` | `kismet` | Kismet with the `esp32c5` source type, the C helper `kismet_cap_esp32c5`, Kismet's stock capture helpers and its log tools. |
| `ghcr.io/oshri-almog/esp32c5-kismet:demo` | `demo` | The same, plus `python3` and the fake board, which starts by itself (`ESP32C5_DEMO=wifi`). |

- **Architectures:** `linux/amd64` and `linux/arm64`, in one multi-arch tag, so a Raspberry Pi 4 or 5 with a 64-bit OS pulls the arm64 image. No 32-bit ARM image is built.
- **Published** since `v0.1.0`, and pulled without a login. A pull downloads about 48 MB for the Kismet image and about 60 MB for the demo. On Docker Desktop (amd64), `docker pull` of both worked, and Compose pulled the demo instead of building it. The arm64 images were read from the registry on the Raspberry Pi, but not yet pulled there with Docker.
  <!-- VERIFY: a docker pull of latest and demo on the Pi (arm64) -->
- **Local names** when you build by hand, as in the Dockerfile's header: `esp32c5-kismet` (that is, `esp32c5-kismet:latest`) and `esp32c5-kismet:demo`. `docker compose build` tags its build with the `ghcr.io` names above instead. To run your own build, use the local names in place of the `ghcr.io` ones in the `docker run` commands on this page, or give your build both names (`-t esp32c5-kismet -t ghcr.io/oshri-almog/esp32c5-kismet:latest`) so that Compose uses it too. Compose uses an image of the `ghcr.io` name that is already on the machine without pulling, until `docker compose pull` replaces it with the published one.
- **Licence:** the image is Kismet, so it is GPL-2.0-or-later (label `org.opencontainers.image.licenses=GPL-2.0-or-later`), although the rest of the repository is MIT. `kismet/` is GPL-2.0-or-later as well.
- **Labels:** `org.opencontainers.image.title=esp32c5-kismet`, and the description "Kismet with the ESP32-C5 capture source: Wi-Fi 2.4/5 GHz, Zigbee/Thread and BLE advertising from ESP32-C5 boards".

### Tags

The CI workflow (see [CI workflow](#ci-workflow)) publishes these tags:

| Git ref pushed | Kismet image tags | Demo image tags |
|---|---|---|
| Release tag `v1.2.3` | `1.2.3`, `1.2`, `latest`, `sha-<7 hex>` | `1.2.3-demo`, `demo`, `sha-<7 hex>-demo` |
| Pre-release tag `v1.1.0-rc.1` | `1.1.0-rc.1`, `sha-<7 hex>` (no `latest`, no `1.1`) | `1.1.0-rc.1-demo`, `sha-<7 hex>-demo` (no `demo`) |
| Manual run of the workflow on `main` | `main`, `sha-<7 hex>` | `main-demo`, `sha-<7 hex>-demo` |
| Push to `main`, pull request | nothing published (build and smoke test only) | nothing published |

`demo` moves only where `latest` moves. Use full version tags (`v1.2.3`, `v1.2.3-rc.1`): a tag that is not a full version, such as `v1.3`, does not start the workflow.

The tag `v0.1.0` made exactly the release-tag row: `0.1.0`, `0.1`, `latest` and `sha-b5fa22a`, and `0.1.0-demo`, `demo` and `sha-b5fa22a-demo`. Each holds the `linux/amd64` and `linux/arm64` images.

<!-- VERIFY: the pre-release and manual-run rows are read from docker.yml and metadata-action's rules; only a release tag (v0.1.0) has run -->

### Kismet version inside

`kismet --version` prints `Kismet <year>.<month>.0-<commit>`: Kismet builds its version from the **build date** and the short commit hash. An image built on 2 October 2026 prints `Kismet 2026.10.0-cfe42707`, and its `kismet_cap_esp32c5 --version` prints `2026.10.0-cfe42707`; one built in September printed `2026.09.0-cfe42707`. So two images of the same Kismet commit can show different versions. The Kismet commit is `cfe427074` (`cfe427074b7ffcfcbc055a123c1df3b3cde60d59`, 16 September 2026), because no Kismet release includes this source yet.

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

**Build arguments and the cache.** Changing `JOBS`, `KISMET_REF`, `KISMET_REPO` or `DEBIAN` from one build to the next misses Docker's cache from that point, so Kismet compiles again (Docker's build cache works this way; not tried with this Dockerfile). Keep `JOBS` at one value, or unset.

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
| Raspberry Pi 4, 8 GB, Debian 13 (arm64) | about 80 minutes (both targets, with `docker build`, Docker 26.1.5) | Almost all of it the Kismet compile at `-j4`, which the build chose from the free memory. A later build of both with `docker compose --profile demo build kismet demo`, with the Debian packages and the Kismet clone from the cache, compiled Kismet again: 78.5 minutes, of which configuring and compiling Kismet took about 76.5 minutes. A native Kismet compile on the same Pi took about 78 minutes. |
| Raspberry Pi, 2 GB | not measured | `-j1`, so much longer, and probably only with swap: one Kismet file needed about 2.4 GB for its own compiler on the 8 GB Pi. Untested. |
| GitHub Actions runners (this project's CI, first run) | about 28 minutes (amd64) and 25 minutes (arm64), demo target, about 2.5 minutes of it spent saving the build cache | Kismet compiled at `-j2`, as the build chose: about 25 minutes (amd64) and 22 minutes (arm64). The Kismet target then came from the cache in seconds. The jobs time out after 120 minutes (amd64) and 180 minutes (arm64). |

<!-- VERIFY: a Docker build on a 2 GB Pi, with and without swap (the 2 GB row) -->

| Image | amd64 | amd64, before the strip step | arm64 (built on the Raspberry Pi 4) |
|---|---|---|---|
| Kismet image (`:latest`) | 177 MB | 895 MB | 140 MB |
| Demo image (`:demo`) | 227 MB | 946 MB | 177 MB |

The build needs internet access: Debian's package servers, GitHub for the Kismet clone, and Docker Hub for the base image and the `docker/dockerfile:1` syntax image.

A Windows checkout is safe to build: [`.gitattributes`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.gitattributes) (`* text=auto eol=lf`) keeps LF line ends even with `core.autocrlf=true`, and the Dockerfile strips carriage returns from the scripts it copies as well.

## Entrypoint roles

The entrypoint is `/usr/local/bin/esp32c5-kismet`, a POSIX `sh` script. The first argument after the image name picks its role; the default, from `CMD`, is `kismet`. Its own messages start with `[esp32c5-kismet]` and go to standard error.

| First argument | Role |
|---|---|
| `kismet` (default) | Kismet, with one source per board found, or the sources in `KISMET_SOURCES`. Arguments after `kismet` go to Kismet unchanged. |
| `helper` | No Kismet: one `kismet_cap_esp32c5` per source, feeding the Kismet at `KISMET_SERVER` over remote capture. Each retries by itself, and is started again if it exits. |
| anything else | Run as a command, with the boards' device nodes kept up to date for it. |

To pass options to Kismet, keep the word `kismet` first: `docker run ... IMAGE kismet --no-logging`. `docker run ... IMAGE --no-logging` would try to run `--no-logging` as a command.

### Role `kismet`, step by step

1. If any argument is `-v`, `--version`, `-h` or `--help`, run `kismet` with the arguments straight away: no login, boards or demo.
2. Set the web login (see [Web login](#web-login)).
3. Keep the device nodes in sync (see [Device access](#device-access)): once now, then every second in the background.
4. **Demo image only**, when `ESP32C5_DEMO` is not empty: start the fake board on `/tmp/esp32c5-demo` in that radio, wait 1 s, log `demo: a fake board on /tmp/esp32c5-demo`, and add the source `esp32c5:device=/tmp/esp32c5-demo,mode=<ESP32C5_DEMO>,name=demo`. With the fake board running, the entrypoint does not look for boards; sources in `KISMET_SOURCES` are still added.
5. Work out the sources: `KISMET_SOURCES` as given, or else one `esp32c5-<tty>:mode=<ESP32C5_MODE>` for each board found.
6. If there is no demo board, no source and no Espressif board in sysfs at all (one the container may not use does not become usable by waiting), and `ESP32C5_WAIT` is above 0: log `waiting up to <n> s for an ESP32-C5 board`, and look again every 2 s for up to `ESP32C5_WAIT` seconds.
7. If the boards were found by themselves (no `KISMET_SOURCES`) and `ESP32C5_WAIT` is above 0, whether they were there at start or turned up in step 6: keep looking every 2 s until two looks in a row agree, so that boards on a hub that come up one after another are all taken, for at most 10 s. After a wait, that ends by `ESP32C5_WAIT` + 10 s from its start (40 s with the default).
8. Log `source: <definition>` for each source and add `-c <definition>` after your own arguments.
9. With no source at all, log the no-board message and start Kismet anyway, so that remote helpers can still connect. Otherwise log `Kismet starts with <n> source(s)`.
10. Run `kismet --no-ncurses <your arguments> -c <definition> ...`.

The sources are worked out once. A board plugged in later gets its device node but is not added as a source.

### Role `helper`, step by step

1. Require `KISMET_SERVER`, the `HOST:PORT` of the Kismet to feed, on its web port.
2. Hand the credentials to the helper through its environment, not its command line, where every account on the host could read them in the process list: `KISMET_APIKEY` becomes `KISMET_CAP_APIKEY`; otherwise `KISMET_USER` and `KISMET_PASSWORD` become `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`, unless the user name holds `:` and the user name or password holds `&`, a login the role refuses (see [Exit status of the `helper` role](#exit-status-of-the-helper-role)). Then unset `KISMET_APIKEY` and `KISMET_PASSWORD`.
3. Keep the device nodes in sync, as in the `kismet` role.
4. Work out the sources as in the `kismet` role. There is no wait for a first board, but when boards were found by themselves (no `KISMET_SOURCES`) and `ESP32C5_WAIT` is not `0`, the list is checked again every 2 s until two checks agree, at most 10 s.
5. For each source, loop forever: log `helper: <definition> -> <KISMET_SERVER>`, run `kismet_cap_esp32c5 --connect "$KISMET_SERVER" --source "<definition>"`, and when it exits, wait 5 s and start it again. It seldom exits: it tries again by itself 5 s after a capture ends (`INFO: Sleeping 5 seconds before attempting to reconnect to remote server`), whether the board stayed away for 15 s, the server could not be reached, or a definition that names no port found no board, or more than one, before it connected (`Could not probe local source prior to connecting to the remote host: <reason>`). It exits after a command-line error (status 255, for example a `KISMET_SERVER` without `:PORT`) or when it is killed. A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) connects even while that port is missing; the open fails, Kismet logs `Error connecting new remote source <name> (<uuid>) - cannot open /dev/ttyACM9: No such file or directory` and does not list the source, and the helper tries again every 5 s until the board is there.
6. On SIGINT or SIGTERM (`docker stop`), stop every loop and helper and exit 0. In a test, `docker stop` took about 1 s.

### Other commands

The entrypoint keeps the device nodes in sync, then runs the command. Examples:

```bash
docker run --rm ghcr.io/oshri-almog/esp32c5-kismet:latest kismet_cap_esp32c5 --list
docker run --rm -it ghcr.io/oshri-almog/esp32c5-kismet:latest sh
```

`kismet_cap_esp32c5 --list` reads sysfs and `/proc/locks` and never opens a port, so it lists the boards even without the device rules. It prints its list on standard error and exits 2 whether or not it found a board, by Kismet's design; with no board the list reads `esp32c5 - No supported data sources found...`. It leaves out a board whose port is held by a capture it can see, but a new container sees none of another container's captures and lists their boards as free; a capture of one of them is still refused, with `... is already in use by another capture ...` (see [Device access](#device-access)). To see which boards are free inside the running `kismet` service, run it there:

```bash
docker compose exec kismet kismet_cap_esp32c5 --list
```

<!-- VERIFY: --list inside the kismet service leaving out the boards its sources hold (/proc/locks in the same container) is read from the code (capture_esp32c5.c:737-773); not run -->

A capture started with a command of your own needs the device rules, as the services have; the entrypoint makes the device nodes for it as it does for them.

### Entrypoint messages

| Message | Meaning |
|---|---|
| `no web login was set, so Kismet's is now: user admin, password <24 hex>` and `(kept in the /root/.kismet volume; set KISMET_USER and KISMET_PASSWORD to choose one)` | A login was made up. Printed once. |
| `KISMET_USER and KISMET_PASSWORD go together; ignoring the one that is set` | Only one of the two is set. Logged at every start, whichever login is then used. |
| `found <tty> in sysfs but the container may not use it: allow it with` / `compose.yaml's device_cgroup_rules, or docker run --device-cgroup-rule 'c <major>:* rmw'` | A board is there but the device rules do not allow its class. |
| `demo: a fake board on /tmp/esp32c5-demo` | Demo image: the fake board started. |
| `waiting up to <n> s for an ESP32-C5 board` | No board at start; see `ESP32C5_WAIT`. |
| `source: <definition>` | A source Kismet starts with. |
| `Kismet starts with <n> source(s)` | Sources counted, Kismet starting. |
| `no ESP32-C5 board found. Plug one in and restart the container, or add sources from` / `the web UI (Data Sources); boards plugged in now appear in the container on their own.` | Kismet starts without sources. |
| `Kismet starts with no source: no board here that the container may use (see above)` | Kismet starts without sources, because the only boards found are in a class the device rules do not allow. |
| `helper: <definition> -> <server>` | Helper role: a helper starts for this source. |

The texts are those of the current entrypoint. The `source:`, `Kismet starts with`, `demo:`, `found <tty> in sysfs ...`, `Kismet starts with no source` and `helper:` lines appeared as above with the current image on the Raspberry Pi with real boards.

### Exit status of the `helper` role

| Status | Message (standard error) | Cause |
|---|---|---|
| 2 | `.../esp32c5-kismet: <line>: KISMET_SERVER: KISMET_SERVER must be HOST:PORT of the Kismet to feed` | `KISMET_SERVER` unset or empty. |
| 2 | `helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD` | No credentials, or only one of user and password. |
| 2 | `helper: a KISMET_USER with ':' in it cannot log in over remote capture when KISMET_USER or KISMET_PASSWORD holds '&'; use KISMET_APIKEY` | Without an API key, a user name with `:` together with an `&` in the user name or password. `kismet_cap_esp32c5` sends a login in an `Authorization` header, which ends the user name at its first `:`, so it puts such a login in the remote-capture URL instead, and Kismet decodes that URL's query before it splits it at `&`. Any other login gets through, `&`, spaces and `%XX` included. |
| 1 | `helper: no ESP32-C5 board found and KISMET_SOURCES is empty` | Nothing to feed. Compose's `restart: unless-stopped` starts the container again. |
| 0 | none | Stopped by `docker stop`. |

On the Raspberry Pi with real boards, the `helper` role refused a user name with `:` and a password with `&` with status 2 and the message above. With a user name with `:` and no `&`, with a password holding `&`, a space and `%41`, and with an API key, it logged in and captured.

## Environment variables

Compose takes each value from the shell's environment or from a `.env` file next to `compose.yaml`; the shell's value wins. Each service passes on only the variables listed for it, so a variable not listed for a service has no effect there under Compose.

| Variable | Used by | Default in the image | Compose default | Meaning |
|---|---|---|---|---|
| `KISMET_SOURCES` | `kismet`, `helper` roles | empty | empty (`kismet`, `helper`); not passed (`demo`) | Source definitions separated by spaces, such as `"esp32c5-ttyACM0:mode=wifi esp32c5-ttyACM1:mode=zigbee esp32c5-ttyACM2:mode=btle"`, or with a board's by-id link, `"esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee"`. A definition cannot contain a space. Empty: every board found, each in `ESP32C5_MODE`. See [Source Definitions](Source-Definitions). |
| `ESP32C5_MODE` | `kismet`, `helper` roles | `wifi` | `wifi` (`kismet`, `helper`) | `wifi`, `zigbee` or `btle`: the radio for boards found by the container. Passed on as `mode=` without checking; the C helper also accepts its other radio words. |
| `ESP32C5_WAIT` | `kismet`, `helper` roles | `30` | `30` (`kismet`, `helper`); not passed (`demo`) | `kismet` role: seconds to wait at start for a first board when none is there. Boards found by themselves, at start or during the wait, are then looked at again every 2 s until the list stops changing, for at most 10 s (`ESP32C5_WAIT` + 10 s in all after a wait). `helper` role: no wait for a first board, only the look again every 2 s, at most 10 s. `0` turns off both. |
| `KISMET_USER`, `KISMET_PASSWORD` | `kismet`, `helper` roles | empty | empty (`kismet`, `helper`); `demo` / `demo` (`demo`) | `kismet` role: the web login, written at every start when both are set. `helper` role: the remote-capture login when there is no API key; any character goes, except that a user name with `:` cannot be used when the user name or password holds `&` (see [Exit status of the `helper` role](#exit-status-of-the-helper-role)). They work only as a pair. |
| `KISMET_SERVER` | `helper` role | none (required) | empty (`helper`) | `HOST:PORT` of the Kismet to feed, on its web port, usually 2501. |
| `KISMET_APIKEY` | `helper` role | empty | empty (`helper`) | A Kismet API key with the `datasource` role. It wins over `KISMET_USER` and `KISMET_PASSWORD`. |
| `ESP32C5_DEMO` | `kismet` role, demo image | `wifi` in the demo image; unset in the Kismet image | `wifi` (`demo`) | The fake board's radio: `wifi`, `zigbee` (or `802154`) or `btle` (or `ble`). Empty turns the fake board off, and the demo image then behaves like the Kismet image. No effect in the Kismet image. |
| `KISMET_PORT` | Compose only | not applicable | `2501` | The host port for Kismet's web port: all interfaces for `kismet` (`"${KISMET_PORT:-2501}:2501"`), loopback only for `demo` (`"127.0.0.1:${KISMET_PORT:-2501}:2501"`). A port number only: with an address in front, Compose refuses the whole file (see [Ports and network](#ports-and-network)). |
| `KISMET_CAP_APIKEY`, `KISMET_CAP_USER`, `KISMET_CAP_PASSWORD` | `kismet_cap_esp32c5`, and the Python remote helper outside the image | set by the `helper` role | not passed | The remote-capture login. **Both helpers**, with `--connect` (never with `--tcp`): with none of `--user`, `--password` and `--apikey`, they take `KISMET_CAP_APIKEY`, or else `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD` (the API key wins when both kinds are set); with half a login they fill in the other half: `--user` alone takes `KISMET_CAP_PASSWORD`, `--password` alone takes `KISMET_CAP_USER`. A value on the command line wins; empty counts as unset. The Python remote helper stops with `give both --user and --password (the one left out may also be in KISMET_CAP_USER or KISMET_CAP_PASSWORD)` when the missing half is not in the environment either. With `--apikey` on the command line it takes nothing from the environment, so half a login stops it with `give both --user and --password`. **Only the C helper** also reads them with `--autodetect` or `--host`. |

Use each value of `KISMET_USER` and `KISMET_PASSWORD` in `.env` with care: every service that passes them on uses them. The demo's `demo` / `demo` applies only while they are unset.

## Compose file

The project name is `esp32c5-kismet`. Every service has both `image:` and `build:` (context `.`, `docker/Dockerfile`), so Compose builds the image when it cannot pull it.

### Services and profiles

| Service | Profile | Image | Target | Command | Ports | Volumes | Device rules | `restart` | `init` |
|---|---|---|---|---|---|---|---|---|---|
| `kismet` | none (default) | `ghcr.io/oshri-almog/esp32c5-kismet:latest` | `kismet` | `kismet` (default) | `${KISMET_PORT:-2501}:2501` | `kismet-data:/data`, `kismet-home:/root/.kismet` | yes | `unless-stopped` | `true` |
| `demo` | `demo` | `ghcr.io/oshri-almog/esp32c5-kismet:demo` | `demo` | `kismet --no-logging` | `127.0.0.1:${KISMET_PORT:-2501}:2501` | anonymous | no | none | `true` |
| `helper` | `helper` | `ghcr.io/oshri-almog/esp32c5-kismet:latest` | `kismet` | `helper` | none | anonymous | yes | `unless-stopped` | `true` |

The `kismet` and `helper` services get the device rules from a shared block (`x-serial`). No service adds a capability (see [Capabilities](#capabilities)). The `demo` service has no device rules, runs Kismet without logging (Kismet then raises `ALERT: LOGDISABLED`), and does not look for boards: on the Raspberry Pi with four boards plugged in, it started with the demo source only, and its list of interfaces answered.

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

Derived from `compose.yaml`. The demo command is the Dockerfile's own example; the other two have not been run as written. The second command is the `helper` service's: change its server address and API key to yours.

```bash
docker run -d --name esp32c5-kismet --restart unless-stopped --init \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet \
    ghcr.io/oshri-almog/esp32c5-kismet:latest
docker run -d --name esp32c5-helper --restart unless-stopped --init \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -e KISMET_SERVER=192.168.1.50:2501 -e KISMET_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35 \
    ghcr.io/oshri-almog/esp32c5-kismet:latest helper
docker run --rm -p 127.0.0.1:2501:2501 \
    -e KISMET_USER=demo -e KISMET_PASSWORD=demo ghcr.io/oshri-almog/esp32c5-kismet:demo
```

<!-- VERIFY: run the kismet and helper docker run commands as written -->

For the demo in the other radios, add `-e ESP32C5_DEMO=zigbee` or `-e ESP32C5_DEMO=btle`.

To run your own build ([Dockerfile](#dockerfile)), write `esp32c5-kismet` and `esp32c5-kismet:demo` in place of `ghcr.io/oshri-almog/esp32c5-kismet:latest` and `ghcr.io/oshri-almog/esp32c5-kismet:demo`, here and in [Other commands](#other-commands).

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
- Ports that Docker publishes are opened by Docker's own firewall rules, which bypass front ends such as ufw (Docker documents this; not tried here). Publish on loopback, or on a trusted network only, if that matters.
- The Compose services are on Compose's default bridge network, `esp32c5-kismet_default`, not the host's network.

## Capabilities

No service adds a capability, and `docker run` needs no `--cap-add`: every container runs with Docker's default set.

- `kismet_cap_esp32c5` drops every capability it has, and sets no_new_privs, as soon as it starts. It needs none to read a serial port.
- Kismet's other capture helpers, which the image also holds, keep NET_ADMIN and NET_RAW when they start as root. Docker's default set lacks NET_ADMIN, and without it they crash (signal 11) as soon as they start. The image's `kismet_site.conf` masks their source types, so Kismet does not start them (see [Kismet configuration in the image](#kismet-configuration-in-the-image)).
- The smoke test runs every container with Docker's default capabilities, so CI checks both points on every build. On the Raspberry Pi, with the current image, the `kismet` service captured from four real boards with no capability added and without `--privileged`. There, every `kismet_cap_esp32c5` in the `kismet` and `helper` containers showed `CapEff` 0 and `NoNewPrivs` 1 in its `/proc/<pid>/status`.

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

On the Raspberry Pi with four real boards and the current image, the container made the nodes and the by-id links, captured from the boards it found by itself and from boards named by those links, and, run without the device rules, left the boards out with the `found <tty> in sysfs ...` message.

<!-- VERIFY: nodes given with docker run --device (used as they are, and left alone) have not been tried; the device-class probe and the by-id links were checked on the Pi (results/pi-docker-test.log D1, D2, D6, and again with the current image on 2026-10-02) -->

> **Warning:** Stop the service before you flash its boards or use them elsewhere. The helpers lock a board's port in two ways. The `flock` on the device node does not reach past the container, since each container makes its own node. The tty's exclusive mode (TIOCEXCL) does: the kernel keeps it with the device, whichever node opens it. So while the `kismet` service captures from a board, a capture from the host or from another container is refused with `... is already in use by another capture ...`, and esptool cannot open the port; on the Pi, an open from the host failed with `Device or resource busy` while the container's sources kept running. A process with the CAP_SYS_ADMIN capability, such as esptool run with `sudo`, is let in all the same. `--list`, of either helper, on the host or in another container cannot see the container's lock and still lists such a board: on the Pi, the Python remote helper's `--list` on the host listed the boards the `kismet` service was capturing from. A board in that list is not proof that it is free.

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
- A password with a space and `#` worked for the web login and the REST API in a test, and the smoke test's password, which holds `&`, a space and `%41`, works for the REST API and for remote capture from the `helper` role; such a password also worked from the `helper` role with real boards on the Pi. The one login the `helper` role refuses is in [Exit status of the `helper` role](#exit-status-of-the-helper-role).

<!-- VERIFY: the grep and exec commands were not run against the current entrypoint (the message text and the file path are the entrypoint's) -->

## Kismet configuration in the image

[`docker/kismet_site.conf`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/docker/kismet_site.conf) is installed as `/etc/kismet/kismet_site.conf`. Kismet loads it after every other configuration file, so its settings win. It sets two things:

- `log_prefix=/data/`, so that the logs go to the `/data` volume.
- 15 `mask_datasource_type=` lines, one per source type of Kismet's other capture helpers: `linuxwifi`, `linuxbluetooth`, `nrfmousejack`, `radiacode-usb`, `rzkillerbee`, `ticc2531`, `ticc2540`, `wch-ble-pro`, `antsdr-droneid`, `catsniffer_zigbee`, `freaklabszigbee`, `nrf51822`, `nrf52840`, `nxp_kw41z` and `radview`. These helpers crash without NET_ADMIN, which the container does not have (see [Capabilities](#capabilities)), so Kismet must not start them, whether to list interfaces or to probe a source given without `type=`, as the entrypoint's sources are. Kismet's list of interfaces (`/datasource/list_interfaces.json`, which the web UI's **Data Sources** window shows) waits for every helper's answer, so a single crashed helper keeps it from ever answering; the smoke test checks that it answers. Not masked: `pcapfile`, `kismetdb` and `sniffle_ble`, which start without NET_ADMIN, and the helpers the image does not build (SDRs, Ubertooth, bladeRF), which Kismet skips at once.

The file's comments also explain why port 3501 stays on loopback, and say that a masked type still works with `type=` in its source (for example `wlan0:type=linuxwifi`) in a container given NET_ADMIN (`cap_add: [NET_ADMIN]` on the service in a `compose.override.yaml`, or `docker run --cap-add NET_ADMIN`) and the hardware it is for. That has not been tried.

To change more, mount your own file over it, and keep both parts in it: `log_prefix=/data/`, so that the logs stay in the volume, and the `mask_datasource_type=` lines, or the **Data Sources** list never loads. With Compose, in a `compose.override.yaml` next to `compose.yaml`:

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

[`.github/workflows/docker.yml`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/.github/workflows/docker.yml), named "Docker image". It has run for the first push to `main`, for pull requests and for the tag `v0.1.0`: each time, both architectures built the images and passed the smoke test (22 of 22 checks on the first push; times in [Build times and sizes](#build-times-and-sizes)). The `v0.1.0` run, started by the tag push, published the images under the tags in [Tags](#tags), each with `linux/amd64` and `linux/arm64`, labelled with version `v0.1.0` and revision `b5fa22a`. It took 3 minutes 20 seconds, with both builds taken from the cache. No manual run has been made.

<!-- VERIFY: the manual-run path (workflow_dispatch; tags main, main-demo) has not run; the tag-push path ran for v0.1.0 (run 37030607390) -->

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

It needs `docker`, `curl` and Python on the host. It removes its containers, their volumes and its network when it ends, and switches off Git Bash's path rewriting for its own `docker` commands. It logs in to Kismet as `smoke` with the password `smoke &pass%41word`, which holds `&`, a space and `%41`: the `helper` role has to carry it to Kismet for remote capture. Every container runs with Docker's default capabilities.

The 22 checks:

| Part | Checks |
|---|---|
| Image | `kismet_cap_esp32c5` is in the image (`--version`). |
| Wi-Fi demo, 35 s | Kismet answers; the interface list answers; the esp32c5 source is running; packets received; decoded as 802.11; the 2.4 GHz access point `ESP32C5-FAKE-24`; the 5 GHz access points `ESP32C5-FAKE-5LOW` and `ESP32C5-FAKE-5HIGH`. |
| 802.15.4 demo, 25 s | Kismet answers; the interface list answers; source running; packets received; decoded as 802.15.4. |
| BTLE demo, 20 s | Kismet answers; the interface list answers; source running; packets received; decoded as BTLE; the advertiser name `ESP32C5-FAKE`. |
| Helper role | A server container (with `ESP32C5_WAIT=0`) answers; a helper container with a fake board makes the remote source run; the access point is seen through remote capture. |

"The interface list answers" means `/datasource/list_interfaces.json` answers with a JSON list. It never answers when one of Kismet's own capture helpers crashes on start, so this check fails if a new Kismet commit (`KISMET_REF`) brings a helper that `kismet_site.conf` does not mask.

It prints a `PASS` or `FAIL` line per check, the container logs when something failed, and `ALL OK` at the end. The exit status is 0 when every check passed, 1 otherwise.

Result: 22 of 22 passed, `ALL OK`, in about 2 minutes on each of GitHub's amd64 and arm64 runners, on images built from the current files (CI's first push to `main`). It passed again in the run that published `v0.1.0`. It has not been run on the Raspberry Pi.

## Kismet messages you will see in container logs

These come from Kismet at commit `cfe427074`, not from this project:

- `ERROR: Tried to re-register duplicate alert FLIPPERZERO` at every start. Harmless; do not treat "ERROR" lines alone as a failure.
- `ALERT: ROOTUSER Kismet is running as root`: the container runs as root.
- `INFO: (HTTPD) Could not read session data file, skipping loading saved sessions.` on a new `kismet-home` volume.
- `Launching remote capture server on 127.0.0.1 3501`: the legacy port, on loopback.
- `Loading optional sub-config file: /etc/kismet/kismet_site.conf`: the image's settings are in use.

In the `helper` role's log, the libwebsockets library can add `W: lws_create_context: unreasonable ulimit -n workaround` after a time stamp, once for each helper as it starts (on the Pi, every helper did): it finds the container's limit on open files unreasonably high and works around it. Harmless.

More in [Troubleshooting](Troubleshooting).
