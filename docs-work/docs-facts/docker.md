# Docker fact sheet (esp32c5-kismet-wifi-interface)

Gathered 2026-09-28, read-only. Repo paths are relative to
`C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface` (the repo has no commits
yet). `file:N` means a line in the current file. "run:" cites a test run from today's session
(scratchpad logs or workflow results). Markers used below:

- **VERIFIED**: seen working in a run today, on the image or file version stated.
- **IN FLUX**: may still change (a review or fix workflow is open on it). Document the intended
  behaviour and mark it for verification.
- **UNVERIFIED**: follows from the code or from general Docker/Kismet behaviour, but nobody ran it.

## 0. Status first: what was tested against what

This matters for every "VERIFIED" below.

- **The Windows Docker Desktop tests (builds, smoke test, compose runs, the Windows Python helper
  feeding Kismet in a container) ran on an image built 11:13 to 11:24 UTC today.** The Docker files
  changed after that:
  - `docker/kismet_site.conf` (14:38 local): legacy port 3501 back on loopback. The tested image
    listened on `0.0.0.0 3501`.
  - `compose.yaml` (14:41 local): the `/dev:/dev` bind was replaced by `device_cgroup_rules` plus
    nodes made by the entrypoint.
  - `docker/Dockerfile` (16:43 local): the Kismet/helper layer split.
  - `docker/entrypoint.sh` (16:45 local): mknod from sysfs, and the NET_ADMIN warning that now
    depends on whether there are local sources.
  - Evidence: file mtimes; image `created 11:24:49Z` in the windows-hw run; message to the user at
    transcript line 1765: "Docker Desktop image: it predates the latest entrypoint and compose
    changes".
- **The current files have not been built and run as a whole anywhere yet.** The first build of
  the current Dockerfile is the Raspberry Pi build, which started 13:49 UTC (16:49 local).
  - It runs as `sudo systemd-run --unit=esp32c5-docker-build ...`, logging to
    `/home/osh/docker-build.log`.
  - At 13:53 UTC it was compiling Kismet (`#16 [build 9/13] RUN ./configure ...`,
    `building with -j4`).
  - Not finished when this was written. Its time, success and arm64 size are UNVERIFIED.
- **A read-only Docker review (workflow `esp32c5-kismet-docker-review`) is running now.** All 13
  of its findings were confirmed by its verifiers (list in section 17). No fixes have been applied
  yet, so the entrypoint, compose file, CI tags and the NET_ADMIN requirement are IN FLUX.
- **The C helper is still being edited**: `capture_esp32c5.c` mtime 17:16 local, after this
  sheet was started.
- Checksums of the files this sheet describes (md5), so a writer can tell whether they have
  changed since:

  ```
  ae5f7cf3e689ba6a49c25c48095ae567  docker/Dockerfile
  8aa1e8c0e5725ddd80e9794c7f16c1fa  docker/entrypoint.sh
  57ef3e55421bc5c804b750500353ec30  docker/kismet_site.conf
  1f6ea525599b1383bcca55e68264cc6c  compose.yaml
  44251e64ac2633e69fe225219ec8e47d  .dockerignore
  5eacf9b755e4802d73250419663afde5  tests/docker_smoke.sh
  931c3c9ad0f83f568b17535d02d87b56  .github/workflows/docker.yml
  87c23be538ceec2bea0be717bf4d1fca  .github/dependabot.yml
  a89b107427fee7a6ae4839e2e57b4df0  .gitattributes
  ```

## 1. Files

| File | What it is |
|---|---|
| `docker/Dockerfile` | Multi-stage build. Stages: `build` (compiles Kismet plus the helper), `kismet` (runtime), `demo` (adds the fake board). A final unnamed `FROM kismet` makes a plain `docker build` produce the Kismet image (`Dockerfile:131-133`). |
| `docker/entrypoint.sh` | POSIX sh, run by dash. Installed as `/usr/local/bin/esp32c5-kismet` (`Dockerfile:99`). It has three roles: `kismet`, `helper`, and anything else (exec). |
| `docker/kismet_site.conf` | Installed as `/etc/kismet/kismet_site.conf` (`Dockerfile:98`). Its one setting is `log_prefix=/data/`. |
| `compose.yaml` | Project `esp32c5-kismet`. Services `kismet` (default), `demo` (profile `demo`) and `helper` (profile `helper`). |
| `.dockerignore` | Only `kismet/`, `docker/` and `tools/fake_board.py` go into the build context (`.dockerignore:1-5`). The Python helper (`esp32c5_kismet/`), `tests/` and `firmware/` are not in the image. |
| `tests/docker_smoke.sh` | Hardware-free smoke test of an image (section 14). |
| `.github/workflows/docker.yml` | CI: build, smoke-test and publish multi-arch images to ghcr.io (section 15). |
| `.github/dependabot.yml` | Monthly updates of the SHA-pinned GitHub Actions (`dependabot.yml:1-7`). |
| `.gitattributes` | `* text=auto eol=lf` (`.gitattributes:3`): LF on every checkout, so a Windows clone with `core.autocrlf=true` still builds. |

## 2. Images, tags and targets

- **Registry name:** `ghcr.io/oshri-almog/esp32c5-kismet`.
  - In CI it is `ghcr.io/${{ github.repository_owner }}/esp32c5-kismet`, lower-cased
    (`docker.yml:41,64-67,155-156`).
  - compose.yaml hard-codes `ghcr.io/oshri-almog/esp32c5-kismet:latest` for `kismet` and `helper`,
    and `:demo` for `demo` (`compose.yaml:48,68,86`).
- **Nothing is published yet.** The repo is not on GitHub.
  - A compose run on Docker Desktop printed `Image ghcr.io/oshri-almog/esp32c5-kismet:demo error
    from registry: denied`, then built the image locally and started it (run: docker-windows
    workflow, "compose" checks). VERIFIED (older files).
- **Local names used in the file headers:** `esp32c5-kismet` (which is `:latest`) and
  `esp32c5-kismet:demo` (`Dockerfile:6-7`; `docker_smoke.sh:5`).
- **Targets:**
  - `kismet` (the default): Kismet plus `kismet_cap_esp32c5`.
  - `demo`: the same, plus `python3` and `tools/fake_board.py` at `/opt/esp32c5/fake_board.py`,
    and `ENV ESP32C5_DEMO=wifi` (`Dockerfile:123-129`).
- **Architectures:** linux/amd64 and linux/arm64 (`docker.yml:50-53`).
  - A Raspberry Pi 4 or 5 needs a 64-bit OS. No arm/v7 image is built (inferred from the matrix).
- **Labels** (`Dockerfile:118-120`; re-applied in CI at `docker.yml:94-104` so metadata-action
  does not overwrite them with the repo's MIT):
  - `org.opencontainers.image.title=esp32c5-kismet`
  - description "Kismet with the ESP32-C5 capture source: Wi-Fi 2.4/5 GHz, Zigbee/Thread and BLE
    advertising from ESP32-C5 boards"
  - `org.opencontainers.image.licenses=GPL-2.0-or-later`
  - The image is Kismet, so it is GPL even though the repo is MIT. `kismet/` is GPL-2.0-or-later
    (`kismet/COPYING.md`).
- **Kismet version inside:** `Kismet 2026.09.0-cfe42707`; `kismet_cap_esp32c5 --version` prints
  `2026.09.0-cfe42707` (run: docker-windows, "all installed binaries find their libraries").
  - `KISMET_REF` `cfe427074` is `cfe427074b7ffcfcbc055a123c1df3b3cde60d59`, dated 2026-09-16
    (reference tree in scratchpad).
- **What else is in the image:**
  - Kismet's own tools: `kismetdb_to_pcap`, `kismetdb_to_wiglecsv`, `kismetdb_to_kml`,
    `kismetdb_to_gpx`, `kismetdb_statistics`, `kismetdb_dump_devices`, `kismetdb_clean`,
    `kismetdb_strip_packets`, `kismet_discovery`, `kismet_server` (a shell script).
  - Kismet's stock capture helpers.
  - Source: `make install` lines in `scratchpad/build-demo.log`. VERIFIED (older build; the
    install list does not depend on today's changes).

### Build arguments (`Dockerfile:21-30`)

| ARG | Default | Meaning |
|---|---|---|
| `DEBIAN` | `debian:trixie-slim` | Base image of both the build and runtime stages. |
| `KISMET_REPO` | `https://github.com/kismetwireless/kismet.git` | Where Kismet is cloned from (`git clone --filter=blob:none`, `Dockerfile:40-41`). |
| `KISMET_REF` | `cfe427074` | The Kismet commit. "Change KISMET_REF to try another commit" (`Dockerfile:9-11`). |
| `JOBS` | empty | Parallel compilers. See the formula below. |

- **JOBS formula when empty** (`Dockerfile:28-30,60-63`):
  `j = int(MemAvailable_kB / 1500000)`, capped at the number of cores and at 4, with a minimum
  of 1.
  - The file's reasoning: "Kismet's C++ needs about 1.5 GB per compiler … a 2 GB Raspberry Pi gets
    1, not an OOM".
  - The build prints `building with -j<N>`.
  - The Pi 4 8 GB got `-j4` (run: Pi build log, 13:53 UTC).
  - Override: `--build-arg JOBS=2`.
- **Cache side effect (UNVERIFIED, general Docker rule):** changing any ARG value (`JOBS`,
  `KISMET_REF`, `KISMET_REPO`) is a cache miss for every `RUN` after the ARG in that stage, so the
  whole Kismet compile runs again. Use the same `JOBS` value each time, or leave it empty.

## 3. Building

### Commands

Given in the files:

```sh
docker compose up -d                                          # builds if it cannot pull (compose.yaml:3)
docker build -f docker/Dockerfile -t esp32c5-kismet .                      # Dockerfile:6
docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .   # Dockerfile:7
```

On the Pi today (transcript line 1910; password handling omitted):

```sh
sudo docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
sudo docker build -f docker/Dockerfile --target kismet -t esp32c5-kismet:latest .
```

- These were run inside `sudo systemd-run --unit=esp32c5-docker-build
  --working-directory=/home/osh/esp32c5-kismet-wifi-interface sh -c "exec > /home/osh/docker-build.log 2>&1; ..."`,
  so the long build survives the SSH session ending.
  - This is a useful tip for the docs, but the exact command form is UNVERIFIED as a user
    instruction.
- The build needs internet access: apt, GitHub for the Kismet clone, and Docker Hub for the
  `# syntax=docker/dockerfile:1` frontend (`Dockerfile:1`).

### Build stage steps (`Dockerfile:24-86`)

1. Install the build dependencies with apt (`Dockerfile:32-37`): `ca-certificates git
   build-essential pkg-config autoconf automake python3 libwebsockets-dev zlib1g-dev libnl-3-dev
   libnl-genl-3-dev libcap-dev libpcap-dev libsqlite3-dev libpcre2-dev libssl-dev
   libusb-1.0-0-dev libdw-dev`.
2. Clone Kismet at `KISMET_REF`.
3. **Layer split** (`Dockerfile:43-52`):
   - Copy only `kismet/add-to-kismet.sh`, `kismet/datasource_esp32c5.h` and
     `kismet/capture_esp32c5/Makefile.in`.
   - Strip CRs from the script and Makefile.in.
   - Write a stand-in `capture_esp32c5.c` (`int main(void) { return 0; }`).
   - Run `add-to-kismet.sh /src/kismet`.
4. Configure and compile (`Dockerfile:56-64`):
   - `./configure --prefix=/usr --sysconfdir=/etc/kismet --localstatedir=/var
     --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf
     --disable-btgeiger --disable-libnm --disable-lmsensors --disable-mosquitto`, then
     `make -j$jobs`.
   - This is the long step. It is left out: "hardware this image is not for (SDRs, Ubertooth,
     bladeRF) or host services a container does not have (NetworkManager, lm-sensors, MQTT)".
5. Build the real helper and install (`Dockerfile:66-71`):
   - Copy the real `capture_esp32c5.c`.
   - `make -C capture_esp32c5 clean && make -C capture_esp32c5 && make install DESTDIR=/out
     INSTUSR=root INSTGRP=root SUIDGROUP=root`.
   - `clean` comes first because the copied source can be older than the stand-in's object file.
6. `strip --strip-debug` every ELF executable under `/out`, skipping shell scripts. This keeps the
   symbol table for backtraces (`Dockerfile:73-79`).
7. Work out the runtime Debian packages with `ldd` and `dpkg -S`, into `/runtime-packages.txt`
   (`Dockerfile:81-86`).

What a change rebuilds (from the COPY order; the claim "a C-helper change rebuilds in seconds" is
UNVERIFIED, since the split has not finished a build yet):

| Changed file | What rebuilds |
|---|---|
| `kismet/capture_esp32c5/capture_esp32c5.c` | Step 5 onward: helper, `make install`, strip, ldd, runtime stage. Kismet stays cached. |
| `kismet/datasource_esp32c5.h`, `kismet/add-to-kismet.sh`, `kismet/capture_esp32c5/Makefile.in` | Everything from step 3: the full Kismet compile (these are part of the server build). |
| `docker/entrypoint.sh`, `docker/kismet_site.conf` | Only the runtime stage's COPY and self-check. |
| `tools/fake_board.py` | Only the demo stage. |
| `JOBS`, `KISMET_REF`, `KISMET_REPO`, `DEBIAN` | Everything (see the ARG note above). |

### Runtime stage `kismet` (`Dockerfile:89-120`)

- Installs exactly the packages in `/runtime-packages.txt`, plus `ca-certificates`.
  - On amd64 that list was: `libbz2-1.0 libc6 libcap2 libdbus-1-3 libdw1t64 libelf1t64 libgcc-s1
    liblzma5 libnl-3-200 libnl-genl-3-200 libpcap0.8t64 libpcre2-8-0 libsqlite3-0 libssl3t64
    libstdc++6 libsystemd0 libudev1 libusb-1.0-0 libwebsockets19t64 libzstd1 zlib1g`. The demo
    adds `python3`.
  - Run: docker-windows `runtime_packages`. VERIFIED (older build).
- Copies `/out`, the site conf and the entrypoint. Strips CRs from the entrypoint and site conf.
- Self-check (`Dockerfile:100-106`): `kismet --version | grep '^Kismet '` and
  `kismet_cap_esp32c5 --version`.
  - `kismet --version` exits 1 by design (`kismet_server.cc:566-569`), so its output is grepped
    instead.
  - The helper's `--help` exits 255; `--version` exits 0.
  - A missing shared library fails the build (exit 127).
- Also sets up `VOLUME ["/data", "/root/.kismet"]`, `WORKDIR /data`, `EXPOSE 2501`,
  `ENTRYPOINT ["/usr/local/bin/esp32c5-kismet"]` and `CMD ["kismet"]`.
- There is no `USER`: everything runs as root. Kismet logs `ALERT: ROOTUSER Kismet is running as
  root` (run: windows-hw container log).

### Build times

- **Windows 11, Docker Desktop 29.8** (fast PC: `docker info` gave cpus=20 mem=16624807936; run:
  transcript line 1003):
  - The first build of the demo target from scratch took **1109 s wall (18.5 min)**. The
    configure+make+install step (then a single RUN) took 1051.6 s at `-j4`, and the git clone
    31.8 s.
  - Timestamps: `build-demo.start` 1790592301, `build-demo.end` 1790593410; step `#16 DONE
    1051.6s` in `scratchpad/build-demo.log`.
  - Later rebuilds from cache took 2-39 s (run: docker-windows `image_sizes`).
  - That build had JOBS=4 as a fixed default. With today's formula the cap is still 4, so it
    should be the same. UNVERIFIED.
- **Raspberry Pi 4, 8 GB, Debian 13 arm64, Docker 26.1.5:** the Kismet layer is estimated at
  **about 80-90 min** at `-j4`.
  - Source: the orchestrator's estimate to the user, transcript line 1955.
  - The build is in progress, so the real figure is UNVERIFIED.
  - `Dockerfile:43` says "Kismet takes an hour and more to build on a Raspberry Pi".
- **Raspberry Pi with 2 GB:** `-j1` by the formula, so much longer. UNVERIFIED, no figure.
- **GitHub Actions arm64/amd64 runners:** no figure; CI has never run. The job timeout is 120 min
  (`docker.yml:55`).

### Image sizes

Measured with `docker image ls` on Docker Desktop, amd64, after the strip step (run:
docker-windows `image_sizes`). VERIFIED (older build; the split should not change the size).

| Image | Size | Before the strip step |
|---|---|---|
| `esp32c5-kismet:latest` | **177 MB** | 895 MB |
| `esp32c5-kismet:demo` | **227 MB** | 946 MB |

- Unpacked layers of `latest`: debian trixie-slim 87.6 MB + runtime libraries 7.42 MB + Kismet
  `/out` 33.7 MB.
  - `/out` was 549 MB unstripped, and `/usr/bin/kismet` went from 469 MB to 14.7 MB.
- arm64 sizes: UNVERIFIED (the Pi build is in progress).

## 4. Roles (entrypoint dispatch, `entrypoint.sh:255-266`)

The first argument picks the role, and the default is `kismet`, from `CMD`. All `[esp32c5-kismet]`
messages go to stderr (`entrypoint.sh:27-29`).

### Role `kismet` (default): `kismet [ARGS]` (`entrypoint.sh:156-201`)

`ARGS` go to Kismet unchanged. To pass Kismet options, keep the word `kismet` first, e.g.
`docker run ... esp32c5-kismet kismet --no-logging`. A first argument that is not `kismet` or
`helper` is exec'd as a command, so `docker run IMAGE --no-logging` would fail (inferred from
`entrypoint.sh:255-265`).

Order of events:

1. If any argument is `-v`, `--version`, `-h` or `--help`, exec `kismet "$@"` straight away: no
   login, board scan or demo (`entrypoint.sh:157-162`).
2. `set_login` (section 8).
3. `keep_devices_in_sync`: make the device nodes now, then again every 1 s in the background
   (section 6).
4. **Demo board**, only if `ESP32C5_DEMO` is non-empty and `/opt/esp32c5/fake_board.py` exists,
   i.e. the demo image (`entrypoint.sh:166-177`):
   - The board boots in the radio `ESP32C5_DEMO` names: `zigbee` or `802154` boot 802.15.4,
     `btle` or `ble` boot BLE, anything else boots Wi-Fi.
   - It runs `python3 /opt/esp32c5/fake_board.py /tmp/esp32c5-demo <WIFI|802154|BLE>`, logging to
     `/tmp/fake-board.log`, and waits 1 s.
   - It adds the source `-c "esp32c5:device=/tmp/esp32c5-demo,mode=$ESP32C5_DEMO,name=demo"`.
     The mode is passed through as given.
   - Log: `demo: a fake board on /tmp/esp32c5-demo`.
   - `-e ESP32C5_DEMO=` (empty) turns the demo board off; the smoke test does this for its
     server (`docker_smoke.sh:139`).
5. **Sources** (`entrypoint.sh:90-100`):
   - `KISMET_SOURCES` as given, if set.
   - Otherwise one `esp32c5-<tty>:mode=${ESP32C5_MODE:-wifi}` per board found (section 6).
   - Note: auto-discovery runs in the demo image too, after the demo board. IN FLUX (review
     finding 2).
6. **Wait** (`entrypoint.sh:179-189`): if there is no demo board and no source, and
   `ESP32C5_WAIT` (default 30) is > 0:
   - Log `waiting up to 30 s for an ESP32-C5 board`.
   - Re-check every 2 s. **It stops at the first board found.** IN FLUX (review finding 3: it may
     change to wait until the list settles).
7. For each source, log `source: <def>` and append `-c <def>` (`entrypoint.sh:190-194`).
8. **No source at all:** log these two lines (`entrypoint.sh:195-198`) and start Kismet anyway,
   so remote sources can still connect:

   ```
   no ESP32-C5 board found. Plug one in and restart the container, or add sources from
   the web UI (Data Sources); boards plugged in now appear in the container on their own.
   ```

9. `check_caps <number of local sources>` (section 7).
10. `exec kismet --no-ncurses "$@"` (`entrypoint.sh:200`).
    - `--no-ncurses` is Kismet's alias of `--no-ncurses-wrapper` (`kismet_server.cc:268,435`).
    - The `-c` sources come after any user arguments.

Hot-plug:

- Boards plugged in after start get a device node within about 1 s, but they are **not** added as
  sources automatically. Add them from the web UI (Data Sources) or restart the container
  (entrypoint message above; code: the sources are computed once).
- Adding `-c <def>` in `ARGS` for a board that auto-discovery also picked up gives two sources on
  one board. Inside one container the helper's port lock refuses the second ("already in use").
  Use `KISMET_SOURCES` instead. Inferred from the code and the C helper header comment, which is
  IN FLUX.

### Role `helper`: boards here, Kismet elsewhere (`entrypoint.sh:207-253`)

- Needs `KISMET_SERVER`, as `HOST:PORT` of the other Kismet's **web port**, usually 2501.
  - If it is unset or empty, dash prints `<script>: <line>: KISMET_SERVER: KISMET_SERVER must be
    HOST:PORT of the Kismet to feed` and exits 2.
  - Seen in a run as `/usr/local/bin/esp32c5-kismet: 92: KISMET_SERVER: ...`. The line number
    is now 208.
- Credentials (section 8): `KISMET_APIKEY`, or `KISMET_USER` plus `KISMET_PASSWORD`.
- Runs `keep_devices_in_sync`, then works out the sources as in the kismet role.
  - There is **no wait**. With no sources: `helper: no ESP32-C5 board found and KISMET_SOURCES is
    empty`, exit 1 (`entrypoint.sh:231-234`).
  - compose's `restart: unless-stopped` then restarts the container.
- `check_caps 1`: the helper runs capture helpers locally, so it needs NET_ADMIN.
- For each source, a loop runs forever (`entrypoint.sh:243-251`):
  1. Log `helper: <def> -> <KISMET_SERVER>`.
  2. Run `kismet_cap_esp32c5 --connect "$KISMET_SERVER" --source "$def"`.
  3. Sleep 5 s when it exits, and start again.
  - Why: "kismet_cap_esp32c5 gives up on a board that stays away for 15 s, and on a server it
    cannot reach" (`entrypoint.sh:236-237`; `RECOVER_TIMEOUT_S 15.0` in `capture_esp32c5.c`,
    which is IN FLUX).
- Remote capture goes over the websocket on the web port (Kismet route
  `/datasource/remote/remotesource.ws`, role `datasource`; `datasourcetracker.cc:988`).
- **Stop:** `trap 'trap "" INT TERM; kill 0 ...; exit 0' INT TERM` (`entrypoint.sh:242`).
  - `docker stop` ends every loop and helper, and the container exits 0 in about 1 s, with and
    without `--init`.
  - Run: docker-windows "helper: docker stop", `stop took 1s exit=0`. VERIFIED on the older
    entrypoint; this code is unchanged.
- The helper role uses the **C** helper (`kismet_cap_esp32c5`). The Python helper is not in the
  image.
- Run: smoke test "helper role" (fake board inside the helper container, websocket to a second
  container). 3/3 PASS, `running=1 packets=200`. VERIFIED on the older image.
- Run (docker-windows): a helper started before its server logged `FATAL: Datasource could not
  connect websocket`, then `Sleeping 5 seconds before attempting to reconnect`. After the server
  came up: `running 1 packets 1993`. VERIFIED on the older image.

### Anything else: exec (`entrypoint.sh:263-265`)

- Runs the command as given, e.g. `docker run --rm esp32c5-kismet kismet_cap_esp32c5 --list` or
  `sh` (`entrypoint.sh:8`).
- **This role makes no device nodes.** `--list` still works, because it reads sysfs only, but a
  capture started this way cannot open a board. IN FLUX (review findings 4 and 5: the fix is
  `keep_devices_in_sync` before `exec`).
- Seen in a run: `kismet_cap_esp32c5 --list` with no boards printed `esp32c5 - No supported data
  sources found...` and exited 2 (by design).

## 5. Environment variables

The entrypoint reads them (`entrypoint.sh:10-23`); compose passes only the ones listed per
service (`compose.yaml:60-64,78-81,94-100`). Compose takes values from the shell environment or a
`.env` file next to `compose.yaml` (`compose.yaml:13`).

| Variable | Entrypoint default | Compose default (service) | Meaning |
|---|---|---|---|
| `KISMET_SOURCES` | empty | `""` (kismet, helper) | Source definitions separated by spaces, e.g. `"esp32c5-ttyACM0:mode=wifi esp32c5-ttyACM1:mode=zigbee esp32c5-ttyACM2:mode=btle"`. Empty means every board found, each in `ESP32C5_MODE`. A definition cannot contain a space (the list is split on whitespace, `entrypoint.sh:190`). |
| `ESP32C5_MODE` | `wifi` | `wifi` (kismet, helper) | `wifi`, `zigbee` or `btle`, for boards found by auto-discovery. Not validated by the entrypoint; the C helper also accepts its aliases. |
| `ESP32C5_WAIT` | `30` | **not passed by compose** | Seconds to wait at start for a board (kismet role only). `0` turns the wait off. To set it under compose you need an override file; with `docker run`, use `-e`. |
| `KISMET_USER`, `KISMET_PASSWORD` | empty | `""` (kismet, helper); `demo` / `demo` (demo) | The web login (section 8). In the helper role, the remote-capture login if there is no API key. They work only as a pair. |
| `KISMET_SERVER` | none (required for helper) | `""` (helper) | `HOST:PORT` of the Kismet to feed, on its web port (2501). |
| `KISMET_APIKEY` | empty | `""` (helper) | Helper role: an API key with the `datasource` role, used instead of the login. It wins if both are set. |
| `ESP32C5_DEMO` | `wifi` in the demo image (`Dockerfile:129`); unset in the kismet image | `wifi` (demo) | Demo image only: the fake board's radio (`wifi`, `zigbee`/`802154`, `btle`/`ble`). Empty turns the fake board off. It does nothing in the kismet image (`entrypoint.sh:166`). |
| `KISMET_PORT` | n/a (compose only) | `2501` | The host port for the web UI: `"${KISMET_PORT:-2501}:2501"` (kismet) and `"127.0.0.1:${KISMET_PORT:-2501}:2501"` (demo) (`compose.yaml:56,76`). |
| `KISMET_CAP_APIKEY`, `KISMET_CAP_USER`, `KISMET_CAP_PASSWORD` | set by the entrypoint in the helper role | n/a | Read by `kismet_cap_esp32c5` (and the Python helper) when `--connect` is given without `--user`, `--password` or `--apikey`, and not with `--tcp` (`capture_esp32c5.c` `login_from_env`, IN FLUX). |

- A `.env` value of `KISMET_USER` or `KISMET_PASSWORD` applies to every service that passes it.
  The demo's `demo`/`demo` defaults apply only when they are unset (`compose.yaml:80-81`).

## 6. Device access: how boards reach the container

- **Rules** (`compose.yaml:36-39`): `device_cgroup_rules: ["c 166:* rmw", "c 188:* rmw"]`.
  - 166 is ttyACM, the boards' native USB (USB-Serial-JTAG, 303a:1001). 188 is ttyUSB.
  - The `docker run` equivalent is `--device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule
    'c 188:* rmw'` (the entrypoint hint, `entrypoint.sh:84`, names the first one).
  - The `kismet` and `helper` services get the rules through the `x-serial` anchor. **The `demo`
    service does not** (`compose.yaml:66-81`).
- **Nodes are made by the container** (`entrypoint.sh:42-67`). `sync_devices` reads
  `/sys/class/tty/ttyACM*/dev` and `ttyUSB*/dev`; a container sees the host's sysfs, read-only.
  - It runs `mknod -m 660 /dev/<tty> c <major> <minor>`.
  - It replaces a node whose major:minor changed, and removes nodes whose tty has gone from sysfs.
  - It runs once, then every 1 s in a background loop.
  - "A board that reboots or is plugged in again, possibly as another ttyACM number, gets its
    node within a second" (`entrypoint.sh:36-38`).
- **Discovery** (`entrypoint.sh:69-88`): a tty counts as a board if its parent USB device has
  `idVendor` `303a` and `idProduct` `1001`.
  - Ports are **not opened** to check, because opening moves DTR/RTS, the board's reset lines.
  - Espressif's ESP32-C3, C6, H2, S3 and P4 share this ID. With any of those plugged in, list the
    sources in `KISMET_SOURCES` (`entrypoint.sh:13-15`, `compose.yaml:16-18`).
- **Why not bind the host's `/dev`:** it "would hand the container every device node on the
  host, its terminals included" (`compose.yaml:28-32`); also /dev/shm and disks
  (`entrypoint.sh:38-39`).
  - An earlier version of compose.yaml did bind `/dev:/dev`; an earlier review rated it high
    severity.
- **Why not `devices:` / `--device /dev/ttyACM0`:** a board reboots every time it changes radio
  and can come back under another ttyACM number, and a fixed device entry would lose it (the
  orchestrator's reasoning, transcript line 1162; `compose.yaml:31-32` "keeping up when a board is
  plugged in again or comes back as another ttyACM number").
- **IN FLUX, device-access findings of the review in progress (all confirmed):**
  - *mknod always succeeds under Docker.* runc adds `c *:* m` and `b *:* m`, and CAP_MKNOD is a
    default capability; only open() is limited by the cgroup rule.
    - So the check at `entrypoint.sh:77-80` ("the node is made only where the device cgroup
      allows it") is always true. The hint at `entrypoint.sh:83-84` never prints.
    - A container **without** the rules (the compose `demo` service, or a plain `docker run`)
      still lists host boards as sources, and they then fail to open with EPERM.
    - Experiment on Docker Desktop 29.8: without a rule, `mknod` succeeded and open gave
      `Operation not permitted`. With `--device-cgroup-rule 'c 166:* rmw'`, open gave `No such
      device or address`, which means allowed.
    - Proposed fix: probe each major once with a spare minor.
  - *The port lock does not cross container boundaries.* The helpers' `flock` sits on the device
    node's inode, and each container's mknod'ed node is its own inode.
    - A board used by the container can also be opened from the host, or from a second
      container, and neither is refused.
    - Until a fix lands (proposed: `TIOCEXCL` in the C helper), the docs should say to stop the
      `kismet` service before using the same boards from the host or from the `helper` service.
  - *No `/dev/serial/by-id` in the container*, so a board cannot be named stably in
    `KISMET_SOURCES`; use ttyACM names. A fix is proposed (udev-style links).
  - *The exec role makes no nodes* (section 4).

## 7. NET_ADMIN

- **Why it is needed:** Kismet's capture helpers, run as root, call `cf_drop_most_caps()`, which
  keeps NET_ADMIN and NET_RAW and drops every other capability.
  - Docker's default set has NET_RAW but **not** NET_ADMIN, so `cap_set_proc` fails with EPERM.
    Kismet's error path (`cf_send_warning`) then dereferences a NULL ring buffer, and the helper
    crashes with **SIGSEGV** before it opens the board.
  - Sources: `compose.yaml:40-42`; `entrypoint.sh:134-137`; gdb backtrace in the docker-windows
    run: `kis_simple_ringbuf_reserve (ringbuf=0x0)` ← `cf_send_warning` ← `cf_drop_most_caps` ←
    `main`.
  - Kismet reports only `cancelling source probe due to timeout` or `Unable to find driver`. A
    helper logs `capture process exited 0 signal 11`.
  - Kismet's stock `kismet_cap_catsniffer_zigbee` crashes the same way.
  - The first smoke run, without NET_ADMIN, failed 14 checks (`scratchpad/smoke1.log`).
- **Where it is set:**
  - compose: `cap_add: [NET_ADMIN]` on `kismet` and `helper` through `x-serial`
    (`compose.yaml:43`), and on `demo` (`compose.yaml:74`).
  - `docker run`: `--cap-add NET_ADMIN` (`Dockerfile:17-19`).
  - The smoke test gives it to its demo and helper containers (`docker_smoke.sh:24-26`).
- **Only helpers started in this container need it.**
  - A Kismet that only receives remote sources works without it, VERIFIED twice: the smoke test
    server container runs without CAPS, and the Windows remote-helper test container was
    started without `--cap-add`.
  - "It only reaches this container's own network" (`compose.yaml:42`).
- **Entrypoint warning** (`entrypoint.sh:138-154`): it checks bit 12 of `CapEff` in
  `/proc/self/status`, and only when running as root.
  - With local sources:

    ```
    the container has no NET_ADMIN capability, and without it Kismet's capture helpers
    crash on start. Add --cap-add NET_ADMIN to docker run (compose.yaml has it).
    ```

  - With no local sources:

    ```
    no NET_ADMIN capability: sources from remote helpers work, boards plugged into this
    machine would not (add --cap-add NET_ADMIN for those)
    ```

  - The second form was added after the Windows test found the first one misleading for
    remote-only use. It is not run-tested yet.
- **IN FLUX:** the security review's finding 9 proposes that `kismet_cap_esp32c5` drop all
  capabilities itself and never call `cf_drop_most_caps`, since a serial source needs none. If
  that lands, NET_ADMIN is **no longer needed** for this image's own helper; stock Kismet helpers
  would still need it. Write the NET_ADMIN requirement so that it can be removed later.

## 8. Web login, API keys and helper credentials

### Web login in the `kismet` role (`set_login`, `entrypoint.sh:106-132`)

The entrypoint always sets a login before Kismet starts. Without one, Kismet serves an
unauthenticated page that lets the first visitor set one ("with the port published, that is
whoever gets there first"). Kismet's own first-run text is `This is the first time Kismet has been
run as this user. You will need to set an administrator username and password...`. The login
file is `$HOME/.kismet/kismet_httpd.conf`, i.e. `/root/.kismet/kismet_httpd.conf`, with
`httpd_username=` and `httpd_password=` lines.

Precedence:

1. `KISMET_USER` **and** `KISMET_PASSWORD` both set: written to the file at **every** start,
   replacing whatever was kept.
2. Otherwise, a kept file that has both a non-empty `httpd_username=` and `httpd_password=` is
   used unchanged. That covers a login from an earlier run, or one set in the browser then.
3. Otherwise a login is made up: user `admin` and a random password of 24 lowercase hex
   characters (`od -An -N12 -tx1 /dev/urandom`).
   - It is printed once:

     ```
     [esp32c5-kismet] no web login was set, so Kismet's is now: user admin, password <24 hex chars>
     [esp32c5-kismet] (kept in the /root/.kismet volume; set KISMET_USER and KISMET_PASSWORD to choose one)
     ```

   - If only one of the two variables was set, this also prints `KISMET_USER and KISMET_PASSWORD
     go together; ignoring the one that is set`.

- **Only one of the pair set, with a login already kept:** it is silently ignored, with no
  warning. IN FLUX (review finding 6).
- **File modes:** the login file is 0600, via `umask 077` in a subshell. Kismet's logs in `/data`
  stay 0644. VERIFIED on the older entrypoint, same code.
- **A password with a space and `#`** (`s3cret pass#1`) worked for the web login and the REST API
  (run: docker-windows "Kismet with no boards serves REST API").
- **Finding the made-up login:**
  - compose: `docker compose logs kismet | grep "web login"` (`compose.yaml:10-11`). UNVERIFIED
    with the current entrypoint, but the message text contains "web login".
  - `docker run`: the message goes to the container's stderr, so use `docker logs <name> 2>&1 |
    grep "web login"`. UNVERIFIED (general `docker logs` behaviour).
  - The line is only in the logs of the container that made it. After the container is
    recreated, read the file instead, e.g. `docker compose exec kismet cat
    /root/.kismet/kismet_httpd.conf`. UNVERIFIED command, derived from the code.
- **Resetting it:** set both variables, or delete the `kismet-home` volume. That also deletes the
  API keys and sessions.

### API keys (Kismet)

- **Create a key.** Tested from Git Bash against the container (run: windows-hw docker step 2):

  ```sh
  curl -u USER:PASS --data-urlencode 'json={"name": "wintest", "role": "datasource", "duration": 0}' \
       http://localhost:2612/auth/apikey/generate.cmd
  ```

  - It returned `HTTP 200` and the key as plain text, 32 hex characters
    (`28E0833651023247F05A47AABB98B37C` in the test).
  - `duration` is in seconds; `0` means it never expires (`kis_net_beast_httpd.cc:312-332`).
  - The route needs a logged-in user (`LOGON_ROLE`). The test used the admin login.
- **List and revoke:** `GET /auth/apikey/list.json` showed role `datasource`, expiration 0.
  Revoke with `POST /auth/apikey/revoke.cmd` and `json={"name": "..."}` (source only; revoke not
  run).
- **What a `datasource` key can do:** feed sources. On its own it gets 401 on
  `/datasource/all_sources.json` (run). Kismet's remote-capture websocket route requires role
  `datasource` (`datasourcetracker.cc:988`).
- **Where keys live:** `/root/.kismet/session.db` (`httpd_session_db`,
  `kis_net_beast_httpd.cc:937`).
  - A key survived `docker restart` (run: windows-hw "docker restart").
  - It survives container re-creation only if `/root/.kismet` is a named volume, as in compose's
    `kismet-home`.
- Creating keys needs `httpd_allow_auth_creation=true`, which is Kismet's default.
- PowerShell equivalent: UNVERIFIED. Windows PowerShell 5.1 aliases `curl` to Invoke-WebRequest,
  so `curl.exe` and JSON quoting need care. Whether Kismet's web UI can create keys was not
  checked.

### Helper role credentials (`entrypoint.sh:209-228`)

- Credentials reach `kismet_cap_esp32c5` **through its environment, not its command line**, where
  every account on the host could read them in the process list.
  - `KISMET_APIKEY` → `KISMET_CAP_APIKEY`; it has priority.
  - Otherwise `KISMET_USER` + `KISMET_PASSWORD` → `KISMET_CAP_USER` + `KISMET_CAP_PASSWORD`.
  - The entrypoint then unsets `KISMET_APIKEY` and `KISMET_PASSWORD`.
- **Neither given:** `helper: set KISMET_APIKEY, or KISMET_USER and KISMET_PASSWORD`, exit 2.
  This also happens with only `KISMET_USER` set.
- **Character limit for the login path only:** the user and password cannot contain `&`, a space,
  or `%` followed by two hex digits.
  - Message: `helper: KISMET_USER and KISMET_PASSWORD cannot contain '&', a space or %XX for
    remote capture; use KISMET_APIKEY, or another password`, exit 2.
  - Reason: "Kismet decodes the whole query string of the remote capture URL before splitting it
    on '&', so these characters cannot get through, however they are escaped"
    (`entrypoint.sh:214-221`).
  - This applies to the remote-capture login everywhere, e.g. the Python helper on Windows too
    (transcript line 1765). API keys are hex, so they are unaffected.
- VERIFIED on the older entrypoint (same code): no server → exit 2; no credentials → exit 2;
  credentials but no boards → exit 1.

## 9. Volumes, files and ports

- **Volumes** (`Dockerfile:108-109`):
  - `/data` holds the Kismet logs.
  - `/root/.kismet` holds the web login (`kismet_httpd.conf`), `session.db` (sessions and API
    keys) and Kismet's other per-user state.
- **In compose:**
  - Named volumes `kismet-data:/data` and `kismet-home:/root/.kismet` on the `kismet` service
    (`compose.yaml:57-59,102-104`).
  - Docker names them `esp32c5-kismet_kismet-data` and `esp32c5-kismet_kismet-home` (run:
    compose-up log).
  - `demo` and `helper` declare none, so they get anonymous volumes from the image's `VOLUME`.
  - `docker compose down -v` deletes the named volumes, and with them the login, API keys and
    logs (run: "down -v removed volumes esp32c5-kismet_kismet-data and _kismet-home").
- **Without compose:** `docker run` without `-v` creates two anonymous volumes per container.
  `docker rm -v` removes them (`docker_smoke.sh:31-33`).
- **Logs:**
  - `kismet_site.conf` sets `log_prefix=/data/`. `WORKDIR` is also `/data`, and Kismet's default
    is `./`.
  - Kismet's default `log_types=kismet` gives one kismetdb file per run, e.g.
    `/data//Kismet-20260928-11-13-48-1.kismet`. The double slash is Kismet's own `%p` expansion
    (run: docker-windows). pcap logs are not on by default (Kismet default config).
  - The demo service runs `kismet --no-logging` (`compose.yaml:77`), so it writes no logs.
    Kismet then says `ALERT: LOGDISABLED ...`.
  - Export tools are in the image: `kismetdb_to_pcap` and the others (section 2).
- **Ports:** `EXPOSE 2501` only (`Dockerfile:111-113`). 2501 carries the web UI, the REST API and
  websocket remote capture.
  - compose `kismet` publishes `${KISMET_PORT:-2501}:2501` on **all host interfaces**, so remote
    helpers on other machines can reach it.
  - compose `demo` publishes `127.0.0.1:${KISMET_PORT:-2501}:2501`, **loopback only**
    (`compose.yaml:55-56,75-76`).
  - `helper` publishes nothing.
  - UNVERIFIED idea: `KISMET_PORT=127.0.0.1:2501` would give `"127.0.0.1:2501:2501"` and keep the
    kismet service local.
  - General Docker behaviour, not tested here: published ports bypass ufw. An earlier review
    finding said so.
- **Legacy TCP remote capture, port 3501:** it has no authentication, so it stays on Kismet's
  default `remote_capture_listen=127.0.0.1` (`kismet.conf:92-93` in Kismet cfe427074), which is
  unreachable inside a container (`kismet_site.conf:7-11`).
  - Only the helpers' `--tcp` option needs it.
  - To use it anyway: your own site conf with `remote_capture_listen=0.0.0.0`, and publish 3501
    only on a network you trust.
  - The Windows-tested image predates this change and listened on `0.0.0.0 3501`.
- **Networking:** containers are on compose's default bridge network, `esp32c5-kismet_default`,
  not the host network.

## 10. Kismet configuration in the image

- `/etc/kismet/kismet_site.conf` is "Loaded after every other Kismet config file, so anything
  here wins. To change more, mount your own file over `/etc/kismet/kismet_site.conf`"
  (`kismet_site.conf:1-2`).
  - Kismet logged `Loading optional sub-config file: /etc/kismet/kismet_site.conf` (run).
  - If you replace the file, keep `log_prefix=/data/`, or rely on `WORKDIR /data`.
  - A mounted file is not CR-stripped; the `sed` runs at build time only. Whether Kismet minds CRLF
    is UNVERIFIED.
- Mount example (UNVERIFIED as written): `-v ./my_site.conf:/etc/kismet/kismet_site.conf:ro`.
- Defaults seen in the container log (run: windows-hw):
  - hop rate 5/s, channel list splitting and shuffling
  - "Sources will be re-opened if they encounter an error"
  - `HTTP server listening on 0.0.0.0:2501`

## 11. compose.yaml usage

Commands from the header (`compose.yaml:3-11`):

```sh
docker compose up -d                           # Kismet, one Wi-Fi source per board plugged in
docker compose --profile demo up demo          # no hardware needed: Kismet and a fake board
docker compose --profile helper up -d helper   # no Kismet here: feed the boards to one elsewhere
docker compose logs kismet | grep "web login"  # the made-up login
```

- "Name the service with a profile: `--profile demo up` on its own starts the kismet service
  too" (`compose.yaml:7`). Otherwise there is a port clash, or two containers on the same boards.
- "Then open http://<this host>:2501. The demo listens on http://localhost:2501, login demo /
  demo" (`compose.yaml:9`).
- **Service settings:**

  | Service | restart | init | Command | Device rules, NET_ADMIN |
  |---|---|---|---|---|
  | `kismet` | `unless-stopped` | `true` (docker-init/tini) | default `kismet` | yes, via x-serial |
  | `demo` | none | `true` | `["kismet", "--no-logging"]` | NET_ADMIN only, no device rules |
  | `helper` | `unless-stopped` | `true` | `["helper"]` | yes, via x-serial |

- Every service has both `image:` and `build:` (`context: .`, `dockerfile: docker/Dockerfile`,
  `target: kismet` or `demo`).
  - Until the images are published, compose falls back to a local build after the pull is denied
    (VERIFIED).
  - Once they are published, it will pull them, and local changes need `docker compose build` or
    `docker compose up --build`. UNVERIFIED; this is compose's default `pull_policy: missing`.
- Compose runs VERIFIED on Docker Desktop, on the older files:
  - `KISMET_PORT=2598 docker compose --profile demo up -d demo` came up in 5 s from cache. Login
    `demo`/`demo` gave 200; with no login, 401. The source `demo esp32c5:device=/tmp/esp32c5-demo,
    mode=wifi,name=demo` was running, and the devices `ESP32C5-FAKE-24`, `-5HIGH` and `-5LOW`
    appeared.
  - `docker compose --profile demo down -v` removed everything.
  - The default `kismet` service on port 2596 came up and logged the no-board hint.
  - `docker compose config -q` exited 0 for the default, demo and helper profiles.
- **Docker Compose on the Pi: not installed.** `dpkg -l` on the Pi shows only `containerd`,
  `docker-buildx`, `docker-cli`, `docker.io` and `runc` (transcript line 1647). Which package to
  recommend is an open question (section 19).

## 12. Platforms

### Linux / Raspberry Pi (tested host: Pi 4 8 GB, Debian 13 trixie arm64)

- **Docker was installed from Debian** with `sudo apt-get install -y docker.io docker-buildx`
  (transcript line 1018). Versions:
  - `docker.io` / `docker-cli` 26.1.5+dfsg1-9+deb13u1
  - `docker-buildx` 0.13.1+ds1-3
  - `containerd` 1.7.24~ds1-6+deb13u1
  - `runc` 1.1.15+ds1-2+b4
  - The build output shows BuildKit (`#16 [build 9/13]`).
- **sudo, not the docker group:** the user `osh` is in `sudo` and `dialout` but **not** in
  `docker`, and `/var/run/docker.sock` is `srw-rw---- root docker` (transcript line 1647).
  - The user chose to keep using `sudo docker ...`, because docker group membership is
    root-equivalent. That trade-off was put to the user at transcript line 1012; the choice is
    recorded in the project memory.
  - The docs should show `sudo docker` for the Pi, and mention the docker-group alternative with
    its trade-off.
- **Boards:** `/dev/ttyACM*`, with `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00`
  on the host.
  - The by-id links do not exist inside the container (section 6).
- **After the first release:** Pi users can pull the arm64 image instead of spending 80-90 min
  compiling. UNVERIFIED until CI has published.
- **Current state:** the Pi Docker build is in progress. There is no Docker test with real boards
  yet on any platform.
  - Real boards through Docker device access (cgroup rules plus mknod) are **untested**.
  - Only the fake board inside a container, and remote helpers, have been tested.

### Windows 11, Docker Desktop

- **No USB passthrough:** containers do not see Windows COM ports. "The boards have to be visible
  to Docker's Linux: on Linux and a Raspberry Pi they are. On Windows they are not, unless they
  are attached to WSL with usbipd; the demo works everywhere" (`compose.yaml:25-26`).
  - The usbipd route into Docker Desktop is **UNVERIFIED**. Nobody attached a board with usbipd
    today, and no usbipd commands were run.
- **Tested path:** the Python remote helper on Windows feeding Kismet in a Docker Desktop
  container (run: windows-hw workflow, docker phase, 14:34-14:47 local, older image). VERIFIED.
  - Container:

    ```sh
    docker run -d --name esp32c5-wintest -p 127.0.0.1:2612:2501 -e KISMET_USER=wintest \
      -e KISMET_PASSWORD=... -e ESP32C5_DEMO= esp32c5-kismet:latest kismet --no-logging
    ```

    It had no `--cap-add NET_ADMIN` and no device rules; neither is needed for remote-only use.
  - **Login:** `python -m esp32c5_kismet.remote --connect localhost:2612 --user wintest --password
    ... --source esp32c5-COM32:mode=wifi,name=docker-win-wifi --debug` (run through a wrapper
    script).
    - The source was running, remote, driver `esp32c5`, hardware `ESP32-C5 (38:44:BE:BF:C9:10)`,
      hopping 42 channels at 5/s.
    - About 8.9k packets in 3.5 min, with 0 error packets. 128+ Wi-Fi devices, including 5 GHz
      APs on channel 48 (5240 MHz) and channel 52 (5260 MHz).
  - **API key:** created with `/auth/apikey/generate.cmd` (role `datasource`, duration 0), then
    `--apikey <key>` instead of the login.
    - Kismet matched the stable UUID `E5C50001-0000-0000-0000-3844BEBFC910` and logged
      `Remote source docker-win-wifi ... reconnected`. The same source was reused.
  - **Channel control through the published port:** `set_channel.cmd {"channel":"48"}` put all
    287 new packets on 5240 MHz; `set_hop.cmd` resumed hopping.
  - **`docker restart`:**
    - Restart issued at 14:44:40. The helper logged `connection ended: Connection to remote host
      was lost.` at 14:44:41, then `connected` and `COM32 capturing` at **14:44:48**: it
      reconnected by itself in about 7 s.
    - The 7 s is 5 s of reconnect backoff (`RECONNECT_BACKOFF_S = 5.0` in `remote.py`, IN FLUX)
      plus about 2 s.
    - The API key survived, in `/root/.kismet/session.db`.
  - **Stop:** a simulated Ctrl+C exited 0 in about 1 s. Kismet then shows the source `running=0
    error=1`, reason `websocket connection closed`; the C helper behaves the same.
- **`localhost` vs `127.0.0.1` from Windows:** in the WSL test, `--connect localhost:2501` cost
  about 2 s per attempt, because Windows tries `::1` first. The docs should use `127.0.0.1` in
  Windows examples (windows-hw WSL finding).
  - For Docker Desktop's published port the extra 2 s is consistent with the ~7 s reconnect, but
    was not measured separately. UNVERIFIED.
- **Git Bash:** it rewrites arguments that look like POSIX paths, e.g. `device=/tmp/...` became
  `device=C:/Users/.../Temp/...`. Set `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` when a
  `docker` argument holds a container path (`docker_smoke.sh:14-17`). VERIFIED.
- **Port clash:** a Kismet in WSL and one in Docker Desktop both want `localhost:2501`. Use
  another host port (`KISMET_PORT`, or `-p 127.0.0.1:2612:2501`).
- **Demo:** works on Docker Desktop. The Windows smoke test run is in section 14. The command
  given to the user was `docker run --rm --cap-add NET_ADMIN -p 127.0.0.1:2601:2501 -e
  KISMET_USER=demo -e KISMET_PASSWORD=demo esp32c5-kismet:demo`, with `-e ESP32C5_DEMO=btle` or
  `zigbee` for the other radios (transcript line 1765).
- **One accident to keep out of the docs:** a test agent ran `docker volume prune -f` and deleted
  38 unrelated anonymous volumes. Docs and scripts should remove only named containers and
  volumes (`docker rm -f -v <name>`), never prune.

### macOS, BSD, Fedora, Arch

Not tested. Docker Desktop on macOS presumably has the same no-USB limit as on Windows.
UNVERIFIED.

## 13. What the demo shows

From `tools/fake_board.py:1-13` and the smoke-test runs.

- **Wi-Fi:** APs `ESP32C5-FAKE-24` on channel 6, `ESP32C5-FAKE-5LOW` on 36, and
  `ESP32C5-FAKE-5HIGH` on 149. Kismet hops the fake board over both bands.
- **802.15.4:** nodes sending data frames on channels 15 and 25 (device names `10:01`, `25:01`,
  `FF:FF` in the run).
- **BTLE:** an advertiser called `ESP32C5-FAKE`.
- **Demo URL and login:** `http://localhost:2501` (compose) with `demo`/`demo`.

## 14. Smoke test (`tests/docker_smoke.sh`)

- **Usage** (`docker_smoke.sh:5-7`):

  ```sh
  docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
  tests/docker_smoke.sh esp32c5-kismet:demo
  PYTHON=python sh tests/docker_smoke.sh esp32c5-kismet:demo     # Windows, Git Bash
  ```

- **Needs:** `docker`, `curl`, and Python on the host (`PYTHON`, default `python3`). It uses host
  port **2599**, and containers and a network named `esp32c5-smoke*`, all removed afterwards
  with their volumes (`docker_smoke.sh:9-10,30-38`).
- **Checks (19):**
  - The image contains `kismet_cap_esp32c5` (`--version`).
  - Wi-Fi demo, 35 s: answers, source running, packets, 802.11, the 2.4 GHz AP, both 5 GHz APs.
  - 802.15.4 demo, 25 s: answers, running, packets, decoded as 802.15.4.
  - BTLE demo, 20 s: answers, running, packets, decoded as BTLE, advertiser name.
  - Helper role: a fake board in one container feeds Kismet in a second over a user network
    (`esp32c5-smoke-net`): server answers, remote source running, AP seen.
  - It prints `PASS`/`FAIL` lines, then `ALL OK`; the exit status is 0 or 1.
- **Result:** 19/19 PASS and `ALL OK` on Docker Desktop, exit 0 in 132 s (`scratchpad/smoke2.log`;
  run: docker-windows). The run used the older image; the smoke script itself is the current
  version (mtime 14:24, run at 14:27).
- **IN FLUX (review finding 7):** the server container waits a useless 30 s for a board. The fix
  is to add `-e ESP32C5_WAIT=0` (`docker_smoke.sh:138-140`).

## 15. CI: `.github/workflows/docker.yml` ("Docker image")

CI has never run (the repo is not on GitHub). Everything here is from the file, so all of it is
UNVERIFIED in practice.

- **Triggers** (`docker.yml:16-35`):
  - Push to `main`, push of tags `v*`, pull requests, and manual `workflow_dispatch`.
  - For push and PR, only when one of these changed: `kismet/**`, `docker/**`, `.dockerignore`,
    `tools/fake_board.py`, `tests/docker_smoke.sh`, `.github/workflows/docker.yml`.
  - GitHub does not apply path filters to tag pushes, so every `v*` tag runs it (review
    verifier, citing GitHub behaviour).
- **Publishes** (`PUSH`) only for `refs/tags/v*` and manual runs (`docker.yml:42,148`). Pushes to
  `main` and PRs only build and test (`docker.yml:5`).
- **Build job:**
  - Matrix `linux/amd64` on `ubuntu-24.04` and `linux/arm64` on `ubuntu-24.04-arm`, each built
    natively, since "under QEMU emulation it would take hours" (`docker.yml:7-9,45-55`).
  - `fail-fast: false`, `timeout-minutes: 120`.
- **Steps per architecture:**
  1. checkout (`persist-credentials: false`)
  2. lower-case the image name
  3. buildx
  4. build the **demo** target with `load: true` and the GitHub Actions cache (`type=gha`,
     `mode=max`, scope per platform)
  5. **smoke test** `sh tests/docker_smoke.sh esp32c5-kismet:demo`
  6. log in to ghcr.io (publish only)
  7. labels
  8. build the **kismet** target and push it by digest (the push only when publishing)
  9. push the demo by digest (publish only)
  10. upload the digests as artifact `digests-<platform>`, kept 1 day
- **Publish job:** download the digests, then `docker buildx imagetools create` one multi-arch
  manifest per image under the tags below, then `imagetools inspect` (`docker.yml:147-221`).
- **Tags** (`docker.yml:172-196`; metadata-action v5.10.0 logic checked in its source):

  | Git ref | Kismet image | Demo image |
  |---|---|---|
  | release tag `v1.2.3` | `1.2.3`, `1.2`, `latest`, `sha-<7 hex>` | `1.2.3-demo`, `demo` |
  | pre-release `v1.1.0-rc.1` | `1.1.0-rc.1`, `sha-<7 hex>` (no `latest`, no `1.1`) | `1.1.0-rc.1-demo` (no `demo`) |
  | manual run on `main` | `main`, `sha-<7 hex>` | `main-demo` |

  - The header comment summarises this as ":latest, :1.2.3, :1.2 … (latest only for releases, not
    rcs)" and ":demo, :1.2.3-demo" (`docker.yml:3-4`).
  - IN FLUX (review finding 11): a non-semver tag like `v1.3` gives the Kismet image no version
    and no `latest`, while `:demo` still moves. A fix is proposed.
- **arm64 runner cost:** the comment says free for public repositories and that private ones need
  larger runners (`docker.yml:8-9`).
  - IN FLUX (review finding 12): since 2026-01-29 standard arm64 runners also work in private
    repositories.
- **Actions pinned to SHAs** (version in the comment): `actions/checkout` v4.4.0,
  `docker/setup-buildx-action` v3.12.0, `docker/build-push-action` v6.19.2, `docker/login-action`
  v3.7.0, `docker/metadata-action` v5.10.0, `actions/upload-artifact` v4.6.2,
  `actions/download-artifact` v4.3.0.
  - Dependabot updates them monthly (`dependabot.yml`).
- **Permissions:** `contents: read` at workflow level; `packages: write` in both jobs. It logs in
  with `GITHUB_TOKEN`.

## 16. Upstream Kismet quirks seen in container logs (not bugs of this project)

- `ERROR: Tried to re-register duplicate alert FLIPPERZERO` appears at every start and is
  harmless. Do not grep logs for "ERROR" as a failure signal.
- `kismet --version` exits 1.
- The `/data//` double slash in log paths.
- `INFO: (HTTPD) Could not read session data file, skipping loading saved sessions.` on a fresh
  volume.
- `ALERT: ROOTUSER`, because Kismet runs as root in the container.

## 17. IN FLUX: pending changes

1. **Every current Docker file is untested as built.** The Pi build (the first of these files) is
   running; a Windows rebuild and retest are planned (transcript line 1747).
2. **Docker review `esp32c5-kismet-docker-review`:** 13 findings, all confirmed, not yet fixed:
   1. flock does not cross container/host (section 6)
   2. mknod always allowed, so the discovery check is always true and the hint is dead
   3. `ESP32C5_WAIT` stops at the first board
   4. and 5. the exec role makes no device nodes
   6. a lone `KISMET_USER`/`KISMET_PASSWORD` is silently ignored once a login is kept
   7. the smoke server's useless 30 s wait
   8. no `/dev/serial/by-id` in the container
   9. NET_ADMIN on the whole container; the proposed fix removes the need
   10. a duplicate of 2
   11. a `v1.3`-style tag splits `demo` from `latest`
   12. the arm64-runner comment is outdated
   13. a duplicate of 2
3. **NET_ADMIN may stop being required** (finding 9).
4. **C helper** (`capture_esp32c5.c`, in final review, edited at 17:16 local): source names,
   `--list` output, `channel=`, the port lock, `KISMET_CAP_*` handling, `RECOVER_TIMEOUT_S` 15 s,
   the capability drop. The entrypoint relies on `--connect`, `--source`, `--version` and the
   `KISMET_CAP_*` variables.
5. **Python helper** (being fixed): `RECONNECT_BACKOFF_S` 5 s, and the reconnect and stop
   behaviour behind the Windows figures ("about 7 s").
6. **CI** has never run, so the tags, timings and published image names are unconfirmed.

## 18. UNVERIFIED (not run by anyone)

- The Pi build time (the 80-90 min estimate), whether it succeeds, and the arm64 image sizes.
- That a helper-only change rebuilds in seconds, i.e. that the layer split works as intended.
- Real boards inside any container, with the cgroup rules and mknod. Only the fake board and
  remote helpers were tested.
- usbipd into WSL2 into Docker Desktop.
- `docker compose logs kismet | grep "web login"` against the current entrypoint;
  `docker logs <name> 2>&1 | grep "web login"`; `docker compose exec kismet cat
  /root/.kismet/kismet_httpd.conf`.
- The ARG cache-miss behaviour of `--build-arg JOBS=...` (general Docker rule).
- Compose pulling published images once they exist (`pull_policy: missing`).
- The `KISMET_PORT=127.0.0.1:2501` trick; published ports bypassing ufw.
- Mounting your own `kismet_site.conf`, and CRLF in a mounted file.
- A plain `docker run` equivalent of the kismet and helper services, e.g.:

  ```sh
  docker run -d --name esp32c5-kismet --restart unless-stopped --init --cap-add NET_ADMIN \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet esp32c5-kismet
  docker run -d --name esp32c5-helper --restart unless-stopped --init --cap-add NET_ADMIN \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -e KISMET_SERVER=192.168.1.20:2501 -e KISMET_APIKEY=<key> esp32c5-kismet helper
  ```

  These are derived from compose.yaml and not run.
- Creating API keys from PowerShell, or from Kismet's web UI.
- CI: every trigger, tag and timing.
- macOS, BSD, Fedora and Arch hosts.

## 19. Open questions for the writer or the user

1. Which Compose to recommend on the Pi, which does not have it: Debian's `docker-compose`
   package (does it provide the `docker compose` plugin on trixie?) or Docker's own apt repository
   (`docker-ce` plus `docker-compose-plugin`)? Or should the Pi page use plain `sudo docker run`?
2. Should the Pi/Linux page lead with pulling the published multi-arch image, which does not
   exist until the first `v*` tag, with building locally (80-90 min on a Pi 4) as the fallback?
   What is the first version number?
3. NET_ADMIN: document it as required now and flag it, or wait for the C-helper decision
   (finding 9)?
4. The flock gap (finding 1): should the docs carry a "do not use the same boards from the host
   and the container at once" warning even if TIOCEXCL lands?
5. For Windows examples: `--connect 127.0.0.1:PORT` rather than `localhost`?
6. Is usbipd into Docker Desktop meant to be a supported path, or only mentioned as untested? It
   needs a test with a board.
7. Is the `KISMET_PORT=127.0.0.1:2501` trick for keeping the kismet service off the LAN worth
   documenting? It needs a quick test.
8. Should `ESP32C5_WAIT` be passed through compose.yaml? At the moment it cannot be set from
   `.env`.
