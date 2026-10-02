This page explains the Kismet build that the install pages run: why Kismet is built from source, what `add-to-kismet.sh` changes in Kismet's source tree, which packages and `configure` options it needs, how many parallel jobs a machine can take, and how installing, rebuilding and uninstalling work. It is for readers who want to understand or adapt those steps. For a working install, follow [Install on Raspberry Pi](Install-on-Raspberry-Pi) or [Install on Linux](Install-on-Linux), which link back here where it matters.

The examples use the same layout as the install pages: this project in `~/esp32c5-kismet-wifi-interface`, Kismet's source in `~/src/kismet`, and the installation in `~/kismet-install`.

## Why Kismet is built from source

A Kismet capture source has two halves, and the Kismet you run needs both:

| Part | File in this project | Where it ends up |
|---|---|---|
| The server side, which registers the source type `esp32c5` | [`kismet/datasource_esp32c5.h`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/kismet/datasource_esp32c5.h) | Compiled into the `kismet` program |
| The C helper, `kismet_cap_esp32c5`, which talks to the board | [`kismet/capture_esp32c5/capture_esp32c5.c`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/kismet/capture_esp32c5/capture_esp32c5.c) | A program of its own, installed next to `kismet` |

The server side is compiled into Kismet itself, so it cannot be added to a Kismet that is already installed. No Kismet release contains it yet, and neither do Kismet's distribution packages. A Kismet without it cannot open these boards, and it also turns away remote sources of this type: when a remote helper connects, it logs `Kismet could not find a datasource driver for incoming remote source 'esp32c5' ...`.

The `kismet/` folder is licensed GPL-2.0-or-later, like Kismet, so that it can become part of Kismet. Until a Kismet release has it, you build Kismet from source with this project's files added. The [Docker image](Install-with-Docker) is the same build, done for you.

## The Kismet commit

The source was developed and tested against one Kismet commit:

| | |
|---|---|
| Commit | `cfe427074` (`cfe427074b7ffcfcbc055a123c1df3b3cde60d59`) |
| Title | "Merge branch 'shrout1-ble-uuid-manufacturer-data'" |
| Date | 16 September 2026 |

```bash
git clone https://github.com/kismetwireless/kismet.git ~/src/kismet
git -C ~/src/kismet checkout cfe427074
```

Git reports a "detached HEAD": the tree is on a fixed commit, not on a branch. That is what you want.

A Kismet built from git names its version after the build date and the commit. The test Pi's build printed `Kismet 2026.09.0-cfe427074`: year, month, `0`, then the start of the commit hash. A build made in another month shows another date, and git may abbreviate the hash to a different length (the Docker build printed `cfe42707`). The commit part is what tells you which source you built.

Kismet's own documentation is at [kismetwireless.net](https://www.kismetwireless.net/docs/readme/intro/kismet/). The source tree has no `docs/` folder, and its `README.OLD` describes an older Kismet; do not follow it.

### Trying a newer Kismet

Newer commits have not been tested. To try one, first return the tree to Kismet's own files. `add-to-kismet.sh` has edited files that git tracks (`kismet_server.cc`, `configure` and others), and git refuses to check out a commit that changes a file with local edits ("Your local changes to the following files would be overwritten by checkout").

1. Undo the script and delete everything the build produced. `clean -xfd` also removes the compiled files, which a new commit has to rebuild anyway:

   ```bash
   git -C ~/src/kismet checkout -- .
   git -C ~/src/kismet clean -xfd
   ```

2. Fetch and check out the commit you want. Replace `<commit>` with it:

   ```bash
   git -C ~/src/kismet fetch
   git -C ~/src/kismet checkout <commit>
   ```

3. Run `add-to-kismet.sh`, `configure`, `make` and `make install` as for `cfe427074`, in the sections below.

Cloning Kismet again into another folder works too, and keeps the tested tree as it is.

What can go wrong:

- `add-to-kismet.sh` finds where to add its lines by looking for the lines of Kismet's CatSniffer Zigbee source. If Kismet has moved or renamed them, the script stops with `anchor not found, Kismet has changed: <the line it looked for>`, before it regenerates `configure`. Edits made before that point stay in the tree, so run the two commands of step 1 again before you try another commit.
- Each of the capture framework fixes (below) is skipped without a word when Kismet already has it, and skipped with a note when the code it replaces has changed, such as `capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed`. The login and Host header fixes are recognised only as this script applies them, so a Kismet that fixed the login its own way gets the note `capture_framework.c: the websocket login has changed, it still goes in the URI`. The script carries on either way.
- The C helper is built on Kismet's capture framework. If a newer Kismet changes that framework, the helper may no longer compile.

For the Docker image, the same choice is the build argument `KISMET_REF`, for example `--build-arg KISMET_REF=<commit>`. Changing it rebuilds Kismet from the start. See [Docker Reference](Docker-Reference).

## What add-to-kismet.sh changes

```bash
sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
```

The script ([`kismet/add-to-kismet.sh`](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/kismet/add-to-kismet.sh)) needs `python3`, which makes its edits, and `autoconf`, `automake` and `pkg-config`, because it regenerates Kismet's `configure` after editing `configure.ac`. It checks the path first: if `kismet_server.cc` or `capture_framework.c` is missing there, it prints `<path> does not look like a Kismet source tree` and exits with status 1.

Every change it makes, in the Kismet tree:

| File | Change |
|---|---|
| `datasource_esp32c5.h` | Copied in; on later runs, only when this project's copy differs |
| `capture_esp32c5/capture_esp32c5.c`, `capture_esp32c5/Makefile.in` | Copied into a new folder; on later runs, likewise only when they differ |
| `kismet_server.cc` | Includes `datasource_esp32c5.h` and registers the `esp32c5` source type, right after Kismet's CatSniffer Zigbee source |
| `configure.ac` | Always builds the helper, which needs only a serial port, so there is no platform test and no new dependency. Adds `capture_esp32c5/Makefile` to the generated files and a `ESP32-C5: yes` line to the summary |
| `Makefile.in` | A build rule for `capture_esp32c5/kismet_cap_esp32c5`, a line in `make clean`, and install lines copied from both of the CatSniffer helper's install blocks, the plain one and the setuid one (see "Installing" below) |
| `.gitignore` | Ignores the built helper |
| `capture_framework.c` | Seven upstream bug fixes (next section) |
| `capture_framework.h` | Three fields that the login fix needs, and one that the Host header fix needs |
| `configure` | Regenerated with `aclocal -I m4 && autoconf` when `configure.ac` is newer than it (`autoconf` alone fails with "possibly undefined macro: AC_DEFINE") |

It prints a line for each file it copies and each edit it makes, so a file changed several times is listed several times. A first run on a clean `cfe427074` tree:

```text
  copied datasource_esp32c5.h
  copied capture_esp32c5/capture_esp32c5.c
  copied capture_esp32c5/Makefile.in
  edited kismet_server.cc
  edited kismet_server.cc
  edited Makefile.in
  edited Makefile.in
  edited Makefile.in
  edited Makefile.in
  edited configure.ac
  edited configure.ac
  edited configure.ac
  edited configure.ac
  edited configure.ac
  edited .gitignore
  edited capture_framework.c
  edited capture_framework.c
  edited capture_framework.c
  edited capture_framework.c
  edited capture_framework.h
  edited capture_framework.c
  edited capture_framework.c
  edited capture_framework.c
  edited capture_framework.c
  edited capture_framework.h
  regenerating configure (needs autoconf and automake)
Done. Now: cd /home/pi/src/kismet && ./configure && make
```

Use the `configure` options in "Configure" below rather than the bare `./configure` it suggests. Afterwards, git shows what changed:

```bash
git -C ~/src/kismet status --short
```

```text
 M .gitignore
 M Makefile.in
 M capture_framework.c
 M capture_framework.h
 M configure
 M configure.ac
 M kismet_server.cc
?? capture_esp32c5/
?? datasource_esp32c5.h
```

Running the script again is safe: every edit is skipped when it is already there, a file is copied only when its content differs from the tree's copy, and `configure` is regenerated only when `configure.ac` is newer than it. A second run changes no file and prints only its `Done.` line. That is how an updated helper gets into the tree without rebuilding more than it has to ("Rebuilding after a helper change" below). On the test Pi (2026-10-02), a run after updating this project printed only the two helper files it copied and the framework edits that were new, `datasource_esp32c5.h` kept its time, and a second run changed nothing.

Run the script before `configure`. A tree that was configured before the script ran has to be configured again. Until it is, every `make` prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` That is only a notice, and `make` carries on, but the Makefile that `configure` wrote before has no rule for the helper, so Kismet is built without it.

### The capture framework fixes

Kismet's capture helpers share one piece of code, `capture_framework.c`, built into `libkismetdatasource.a`. At this commit it has bugs that every capture helper has, not only this one. The script fixes seven of them. They are upstream bug fixes, not part of the ESP32-C5 source, and each goes to Kismet as a change of its own:

| Fix | What was wrong |
|---|---|
| A memory leak | `cf_commit_packet()` never frees the small holder (`cf_frame_metadata`) that `cf_prepare_packet()` allocates for each packet, so a helper loses about 32 bytes per packet for as long as it runs |
| Remote capture in bursts | Over a websocket, a helper's packets went out in bursts every 5 seconds, when Kismet's next PING woke the helper's loop. With the fix, the first packet over `--connect` reached Kismet in about 1.2 s on the test Pi, instead of 5 to 6 s |
| A missed wake-up | A websocket that closed just as the helper's loop went to sleep left the loop asleep: the helper kept its port and never reconnected |
| The remote login | The login went into the websocket's URL, where a proxy's log keeps it, and a user, password or API key with a space, `%` or `&` in it could not log in. Now a user and password go in an `Authorization: Basic` header and an API key in Kismet's session cookie. Only a user name containing `:`, which that header cannot carry, still goes in the URL, and such a login cannot also hold an `&`. A websocket answered with a redirect is refused, so that the login does not go along to another server. With libwebsockets 4.0 and later (Debian 13 and Ubuntu 24.04 have 4.3) the helper does not even connect to where the redirect points, and its message says where that was, without the query, which may hold the login. Older libwebsockets connects there first, then stops before it sends anything |
| libwebsockets queue warnings | Every websocket connection printed `rejecting message on queue depth 40` on a machine with more than about 40 network routes |
| An empty log line | A remote helper printed an empty `INFO: ` line on its terminal for every channel set it accepted |
| The Host header | The websocket request's `Host` and `Origin` headers named the server without its port (`Host: 127.0.0.1` for `--connect 127.0.0.1:2501`), which a reverse proxy that goes by host and port can take for another site. Now they carry the port, unless it is the scheme's own (80, or 443 with `--ssl`); TLS still checks the certificate against the bare name. With libwebsockets before 4.2, a host and port longer than 110 bytes keep the bare host, because those versions cannot write a longer `Origin` header |

The leak, measured:

| | |
|---|---|
| Measured over 200,000 packets | 6,400,000 bytes lost before the fix (32.0 bytes per packet), 0 after |
| Estimated at 1,000 frames a second | about 115 MB an hour (an estimate from a review, not a measurement) |

The script frees only that holder. Freeing the whole record instead would commit the frame's ring-buffer space a second time.

Each fix is skipped when the tree has it already, from an earlier run or from Kismet itself. The login and Host header fixes are the exceptions: the script recognises only its own versions of them, so a Kismet that fixed either its own way gets that fix's note below. When the code a fix replaces has changed, the script prints one of these lines and carries on without that fix:

```text
  capture_framework.c: cf_commit_packet not found, its metadata leak not fixed
  capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed
  capture_framework.c: the websocket send path has changed, its 5 second bursts not fixed
  capture_framework.c: LWS_CALLBACK_CLIENT_CLOSED has changed, its missed wake-up not fixed
  capture_framework.c: the websocket login has changed, it still goes in the URI
  capture_framework.c: the websocket's connection has changed, where a redirect points still connected to
  capture_framework.c: lws_create_context has changed, its queue warnings not fixed
  capture_framework.c: cf_send_configresp has changed, its empty INFO line not fixed
  capture_framework.c: the websocket's Host header has changed, its port not added
```

The redirect line is the one partial case: telling libwebsockets not to follow a redirect is an edit of its own, so when only that edit cannot be made, the rest of the login fix still goes in. libwebsockets then still connects to where a redirect points, as the note says.

A tree that an earlier version of this script patched is brought up to date in place: the script copies the helper files that changed and adds the fixes, or the parts of a fix, that are new. The result is the same as a fresh tree patched by the current script, and a second run changes nothing. This was checked with every earlier version of the script in this repository.

One more note is for a tree that holds an earlier, unreleased version of the login fix, which followed redirects with the login. The script does not upgrade that version in place, and says how to replace it:

```text
  capture_framework.c: an earlier version of the websocket login fix is there, which follows redirects; git checkout capture_framework.c capture_framework.h and run this again
```

A run that applies a fix changes `capture_framework.c`, and the login and Host header fixes also `capture_framework.h`, so the next `make` rebuilds `libkismetdatasource.a` and every capture helper, once. It does not rebuild `kismet`, which uses neither.

## Dependencies

What Kismet's `configure` at `cfe427074` does when a package is missing, with the Debian and Ubuntu package names:

| Package | What it is for | If it is missing |
|---|---|---|
| `build-essential` | C and C++ compilers, `make` | Nothing builds |
| `git` | Cloning Kismet; the commit in Kismet's version string | Required |
| `pkg-config` | How `configure` finds the libraries, and `add-to-kismet.sh`, whose `aclocal` needs pkg-config's macros | Required; the script fails without it |
| `autoconf`, `automake` | `add-to-kismet.sh` regenerates `configure` | The script fails |
| `python3` | `add-to-kismet.sh` makes its edits in Python | The script fails |
| `zlib1g-dev` | Compression | `configure` stops |
| `libsqlite3-dev` | Kismet's log database (`.kismet` files) | `configure` stops |
| `libssl-dev` | OpenSSL | `configure` stops |
| `libpcap-dev` | libpcap | `configure` stops |
| `libwebsockets-dev` | The capture helpers' websocket client, for [remote capture](Remote-Capture). Version 3.1.0 or later, with client support | `configure` stops, unless `--disable-libwebsockets` |
| `libusb-1.0-0-dev` | Kismet's USB capture helpers (not this one) | `configure` stops, unless `--disable-libusb` |
| `libsensors-dev` | Temperature readings through lm-sensors | `configure` stops, unless `--disable-lmsensors` |
| `libmosquitto-dev` | MQTT | `configure` stops, unless `--disable-mosquitto` |
| `libnm-dev` | NetworkManager, for Kismet's own Wi-Fi capture | A warning |
| `libnl-3-dev`, `libnl-genl-3-dev` | Netlink, for Kismet's own Linux Wi-Fi capture | A warning |
| `libcap-dev` | Lets capture helpers drop capabilities; the C helper drops all of them at start, whoever runs it | Built without it; the C helper then drops nothing |
| `libpcre2-dev` | Regular expressions in filters | A warning |
| `libdw-dev` | Full stack traces if Kismet crashes | Partial stack traces |

The ESP32-C5 source itself adds no library: the C helper needs only a serial port. The only packages this project adds to Kismet's own list are `autoconf`, `automake` and `python3`, for the script. The script also needs `pkg-config`, which Kismet's build needs anyway: Kismet's `configure.ac` uses pkg-config's macros, and its own `m4` folder has no copy of them.

Built without libwebsockets (`--disable-libwebsockets`), the capture helpers can do remote capture only over Kismet's legacy TCP port, with `--tcp`; the Kismet server keeps its own websockets either way. When libwebsockets is missing, the error `configure` prints is pkg-config's `Package requirements (libwebsockets >= 3.1.0) were not met`; the option that turns it off is `--disable-libwebsockets`.

Two package sets that work:

**The full set**, as on the test Raspberry Pi (Raspberry Pi OS (64-bit), based on Debian 13):

```bash
sudo apt-get install -y build-essential git pkg-config autoconf automake python3 \
    libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev \
    libnm-dev libdw-dev libsqlite3-dev libsensors-dev libusb-1.0-0-dev libmosquitto-dev \
    libpcre2-dev libssl-dev
```

This set has not been tried on a freshly installed system, where more may be missing; `configure` names any library it cannot find. The smaller set below is what the Docker image installs on a fresh Debian 13, and that does build.

**The smaller set**, as in the Docker image. It needs `--disable-lmsensors --disable-mosquitto` on the `configure` line (below). The Docker image also passes `--disable-libnm`, which is optional: without libnm, `configure` only warns, and it prints the NetworkManager warning at the end with or without that option.

```bash
sudo apt-get install -y --no-install-recommends ca-certificates git build-essential pkg-config \
    autoconf automake python3 libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev \
    libcap-dev libpcap-dev libsqlite3-dev libpcre2-dev libssl-dev libusb-1.0-0-dev libdw-dev
```

Fedora and Arch have not been tested; likely package names are on [Install on Linux](Install-on-Linux). macOS and the BSDs are on [Install on macOS and BSD](Install-on-macOS-and-BSD).

## Configure

The two `configure` lines this project uses:

| Where | Command |
|---|---|
| Raspberry Pi, installed into the home directory | `./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger` |
| Docker image | `./configure --prefix=/usr --sysconfdir=/etc/kismet --localstatedir=/var --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger --disable-libnm --disable-lmsensors --disable-mosquitto` |

For the Pi layout:

```bash
cd ~/src/kismet
./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr \
    --disable-ubertooth --disable-bladerf --disable-btgeiger
```

Leave out `--prefix` to install into `/usr/local`, Kismet's default. Add `--disable-lmsensors --disable-mosquitto` if you installed the smaller package set (the Docker image adds `--disable-libnm` too).

What each option means. None of them affects the ESP32-C5 boards:

| Option | What it leaves out | Without the option |
|---|---|---|
| `--prefix=<dir>` | Nothing; it sets where `make install` puts everything | `/usr/local` |
| `--disable-python-tools` | Kismet's legacy Python modules and Python-only sources | Already off by default at this commit |
| `--disable-librtlsdr` | Sources for RTL-SDR software-defined radio dongles | `configure` stops unless librtlsdr's development files are installed |
| `--disable-ubertooth` | Ubertooth One support | `configure` warns and builds without it when the Ubertooth libraries are missing |
| `--disable-bladerf` | bladeRF 2 Wi-Fi support | Already off by default |
| `--disable-btgeiger` | A Bluetooth LE Geiger counter source, which also needs the Python tools | Already off by default |
| `--disable-libnm` | NetworkManager support | A warning |
| `--disable-lmsensors` | Temperature readings | `configure` stops unless `libsensors-dev` is installed |
| `--disable-mosquitto` | MQTT | `configure` stops unless `libmosquitto-dev` is installed |

The Docker image leaves these out because they are hardware the image is not for (SDRs, Ubertooth, bladeRF) or host services a container does not have (NetworkManager, lm-sensors, MQTT).

One more option you may want: `--with-suidgroup=<group>` changes the group of setuid helpers from `kismet` (see "Installing" below).

At the end, `configure` prints a summary. Check these lines:

```text
       Installing into: /home/pi/kismet-install
 Websocket datasources: yes
              ESP32-C5: yes
```

- `ESP32-C5: yes` means `add-to-kismet.sh` ran on this tree. If the line is missing, run the script and then `configure` again.
- `Websocket datasources: yes` means the helpers can do remote capture over Kismet's web port.
- `Setuid group: kismet` and `Prelude  SIEM : no` run together on one line. That is an upstream cosmetic bug (a missing newline), not a problem.

## Compiling: parallel jobs and memory

Kismet is a large C++ program. Each parallel compiler can use well over a gigabyte, so memory, not the number of cores, decides how many jobs to run. The Dockerfile's rule of thumb is about 1.5 GB per compiler.

What has been measured:

| Machine | Jobs | Result |
|---|---|---|
| Raspberry Pi 4, 8 GB, Raspberry Pi OS (64-bit) based on Debian 13, arm64 | `make -j4` | About 78 minutes, no out-of-memory kill. At the peak, `phy_80211.cc` (2.4 GB), `phy_80211_dissectors.cc` (1.8 GB) and `phy_80211_components.cc` (1.7 GB) compiled at once, leaving about 1.1 GB available and about 40 MB of swap in use |
| Raspberry Pi 4, 8 GB, Docker image | `-j4`, chosen automatically | About 80 minutes for the whole image, almost all of it compiling Kismet |
| Windows PC, 20 cores, 16 GB, Docker Desktop | `-j4` | 18.5 minutes for the whole image; the configure, compile and install step took 1,051.6 s |
| WSL2, 15 GB | `make -j20` | Exhausted memory; the Windows host was left with 1.2 GB free and the WSL distribution had to be terminated |
| WSL2, 15 GB | `make -j4` under `nice` | Completed (time not recorded) |

From these, for machines that were not measured (worked out from the peaks above and the 1.5 GB rule; none of these has been tried):

| Memory | Jobs |
|---|---|
| 8 GB or more | `-j4` |
| 4 GB | `-j2` |
| 2 GB | `-j1`, with at least 2 GB of swap: one file alone needed 2.4 GB on the test Pi |

The Docker image build on a 2 GB machine picks `-j1` and needs the same swap.

> **Warning:** Do not use `make -j` with the number of cores on a machine with many cores. At `-j20`, WSL2 used up the memory of a 15 GB machine.

The Docker build works the number out from free memory: `MemAvailable` divided by 1.5 GB, capped at the number of cores and at 4, and at least 1. The same calculation for a native build:

```bash
jobs=$(awk -v cores="$(nproc)" '/^MemAvailable:/ { j = int($2 / 1500000); if (j > cores) j = cores; if (j > 4) j = 4; if (j < 1) j = 1; print j }' /proc/meminfo)
echo "building with -j$jobs"
```

On a Pi, or over SSH, run the build in the background so that it survives the session ending. `$jobs` is the number worked out above; in a new shell, run the `jobs=` line again first, or write the number in its place:

```bash
cd ~/src/kismet
nohup nice make -j"$jobs" > ~/kismet-build.log 2>&1 &
tail -f ~/kismet-build.log
```

Ctrl+C stops `tail`, not the build. `nice` keeps the machine responsive while it compiles.

Warnings are expected: the Pi build logged 76 warning lines, all from Kismet's own files. The C helper compiles without warnings of its own under `-Wall`, and under `-Wextra` apart from unused-parameter and sign-compare; the three it shows come from Kismet's `capture_framework.h` and appear for every helper.

When the build has finished, both programs exist:

```bash
ls -l ~/src/kismet/kismet ~/src/kismet/capture_esp32c5/kismet_cap_esp32c5
```

Once the whole tree has been built, `make -C capture_esp32c5` in it builds only the C helper. To install a new version of the helper, run `make` in the whole tree instead ("Rebuilding after a helper change" below explains why).

## Installing

`make install` puts everything under the prefix given to `configure`:

| Folder | What goes there |
|---|---|
| `bin/` | `kismet`, `kismet_server` (an old name that now only starts `kismet`), every capture helper `kismet_cap_*` (19 on the test Pi, `kismet_cap_esp32c5` among them), the `kismetdb_*` log tools and `kismet_discovery` |
| `etc/` | Kismet's config files: `kismet.conf`, `kismet_httpd.conf`, `kismet_alerts.conf`, `kismet_memory.conf`, `kismet_logging.conf`, `kismet_filter.conf`, `kismet_uav.conf`, `kismet_80211.conf`, `kismet_wardrive.conf` |
| `share/kismet/` | The web UI (`httpd/`) and the manufacturer and aircraft lists |
| `lib/pkgconfig/` | `kismet.pc` |

- **Config files are never replaced.** An existing file stays, with the message `<file> already exists; it will not be automatically replaced.` `make forceconfigs` overwrites them all with Kismet's stock versions. Keep your own settings in `kismet_site.conf`, which `make install` never creates or touches ([Kismet Configuration](Kismet-Configuration)).
- **The helper must sit next to `kismet`.** Kismet starts capture helpers only from its own `bin` folder (`helper_binary_path=%B`). A missing helper shows as `Unable to find driver for '<definition>'` for a source without `type=`. With `type=esp32c5`, Kismet at this commit does not say so: it stops at start with `Uncaught exception "kis_external tried to write with no io handler"` and a stack trace.
- **`DESTDIR`** is honoured, for staging an install elsewhere. The Docker build uses `make install DESTDIR=/out INSTUSR=root INSTGRP=root SUIDGROUP=root`.

### Owners, groups and the kismet group

Kismet's install rules take their owners and groups from these make variables. A value given on the `make` command line overrides the default, including in the rules `make` runs from other rules:

| Variable | Default | Used for |
|---|---|---|
| `INSTUSR` | `root` | Owner of every installed file |
| `INSTGRP` | `root` (`wheel` on a system without a `root` group) | Group of the programs and config files |
| `SUIDGROUP` | `kismet` (`staff` on macOS), or what `--with-suidgroup=` set | Group of the setuid helpers, and of `kismet_cap_rz_killerbee` even in a plain `make install` (and of the CoreWLAN helper on macOS) |
| `MANGRP` | Not set by `configure` | No install rule uses it at this commit |

Two of these defaults stop a plain `make install`:

- **The owner.** Every file is installed with owner `INSTUSR`, which is `root`. A normal user cannot give a file to root, so without the variables `make install` stops at its first file, `kismet`:

  ```text
  /usr/bin/install: cannot change ownership of '/home/pi/kismet-install/bin/kismet': Operation not permitted
  ```

- **The `kismet` group.** Even a plain `make install` installs Kismet's `kismet_cap_rz_killerbee` helper with group `SUIDGROUP` and mode 4550, and that helper is built whenever libusb is found. Run as root on a system with no `kismet` group, `make install` gets past `kismet` and the log tools and stops at that helper:

  ```text
  /usr/bin/install: invalid group 'kismet'
  ```

Three ways out; all three have been run:

| Situation | Command |
|---|---|
| Installing into a prefix you own, without root (the Pi) | `make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)` |
| Installing as root, without a `kismet` group (WSL2) | `make install INSTGRP=root SUIDGROUP=root` |
| Creating the group Kismet expects | `sudo groupadd kismet`, then `sudo make install` |

With the `kismet` group in place, a plain `make install` as root installs `kismet_cap_rz_killerbee` with group `kismet` and the rest as root's. The WSL2 run also passed `MANGRP=root`. It does no harm, but at this commit it has no effect.

### make install or make suidinstall?

Kismet offers two install targets:

| Target | What it does | Needs root |
|---|---|---|
| `make install` | Installs everything as ordinary programs, then the config files that do not exist yet. No `groupadd`, and no setuid bits except on `kismet_cap_rz_killerbee` (mode 4550) | Yes, unless you pass `INSTUSR`, `INSTGRP` and `SUIDGROUP` for a prefix you own |
| `make suidinstall` | Runs `groupadd -r -f kismet`, installs as `make install` does, then reinstalls the helpers that need privileges as setuid root, group `kismet`, mode 4550, so that members of `kismet` can run them | Yes |

Kismet recommends `make suidinstall` for its Wi-Fi and Bluetooth helpers, which have to reconfigure network interfaces. After a plain `make install` it prints `Kismet has NOT been installed suid-root.  This means you will need to start it as root...`. That advice is about those helpers.

The C helper needs neither root nor any capability, only read and write access to the board's serial port. With `make install` it is an ordinary program (on the Pi, `-rwxr-xr-x`, owned by the user) that runs as whoever runs Kismet. That user needs the serial port's group, `dialout` on Debian, Ubuntu and Raspberry Pi OS:

```bash
sudo usermod -aG dialout $USER
```

Log out and in again afterwards.

The Raspberry Pi tests ran this way: `make install` with the three variables above, Kismet run as a normal user who was already in `dialout`, and all three radios captured. The WSL2 tests ran Kismet as root, and the Docker image runs it as root too.

`make suidinstall` would also install `kismet_cap_esp32c5` setuid root, mode 4550, group `kismet`, because `add-to-kismet.sh` copies the CatSniffer helper's install lines. The C helper does not need that. Installed that way, it still drops every capability first thing, as it does whoever starts it, and keeps only root's user ID: it can open device nodes that root owns, the boards' among them, and, with the permissions of the user who runs it, a port that user may open, such as their own pseudo-terminal; nothing else. Built without `libcap-dev`, though, it drops nothing, and a setuid install would run it with full root rights. Setuid installs have been checked only by the C test harness, which simulates them, never with a real board. If you want `make suidinstall` for Kismet's other helpers, users have to be in `kismet` (`sudo usermod -aG kismet $USER`, then log in again), or opening a source fails with `IPC cannot run binary '<path>', Kismet was installed setgid and you are not in that group...`.

Running all of Kismet as root also works, but Kismet raises its `ROOTUSER` alert, and its web login and API keys then live in `/root/.kismet`.

### Size

Kismet compiles with debug information and `make install` copies the programs as they are. On the test Pi the installed `kismet` is 489,329,152 bytes, and `kismet_cap_esp32c5` 424,288 bytes (built from commit `f8e6792`). The Docker build runs `strip --strip-debug` on every program, which keeps the symbol table for stack traces and took `kismet` from 469 MB to 14.7 MB on amd64. Stripping a native install has not been tried, and the disk space the source tree and build need has not been measured.

## Checking the build

```bash
~/kismet-install/bin/kismet --version
~/kismet-install/bin/kismet_cap_esp32c5 --version
~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1
```

| Command | Prints | Exit status |
|---|---|---|
| `kismet --version` | `Kismet 2026.09.0-cfe427074` (test Pi) | 1 (Kismet always exits 1 here) |
| `kismet_cap_esp32c5 --version` | The same version without the word `Kismet`, for example `2026.09.0-cfe427074` | 0 |
| `kismet_cap_esp32c5 --list` | The boards it can see, on stderr, hence `2>&1` | 2 |
| `kismet_cap_esp32c5 --help` | The usage of Kismet's capture framework, with the remote capture options | 255 |

The exit statuses are upstream behaviour, not failures; a script should check the text. `--list` reads only Linux sysfs and `/proc/locks` and never opens a port, since opening one can reset the board. With one idle board on `ttyACM0` it prints each board three times, once per radio:

```text
esp32c5 supported data sources:
    esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
```

- The three lines are alternatives: a board captures with one radio at a time.
- A board that a running source is using is left out, all three lines of it.
- Every Espressif chip on its native USB port has the same USB ID, `303a:1001`, so other ESP32 boards are listed too. The hardware label names the USB device, not the chip, for that reason.
- With no free board: `esp32c5 - No supported data sources found...`

Finally, Kismet itself has to know the source type. Start it with a board as on [Install on Linux](Install-on-Linux) and look for `Found type 'esp32c5'` in its output. A Kismet built without `add-to-kismet.sh` answers a definition with `type=esp32c5` with `Unable to find datasource for 'esp32c5'.`

The project's C test harness also runs against a built tree: `sh tests/c/run.sh ~/src/kismet`, run in this project's folder, compiles the repo's helper against the tree's `libkismetdatasource.a` and prints `ALL OK`. See [Development and Testing](Development-and-Testing).

## Rebuilding after a helper change

A new version of the C helper does not need a new Kismet build:

1. Update this project:

   ```bash
   git -C ~/esp32c5-kismet-wifi-interface pull
   ```

2. Copy the new files into the Kismet tree. The script copies only the files that changed and skips edits already made:

   ```bash
   sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
   ```

3. Rebuild, as your normal user, with `make` in the tree:

   ```bash
   cd ~/src/kismet
   nice make -j4
   ```

   This rebuilds only what the new files change, not all of Kismet. A file the script did not copy keeps its time, so `make` leaves alone what depends on it:

   - A new `capture_esp32c5.c`: only the C helper is compiled again, in seconds.
   - A new `datasource_esp32c5.h`: `kismet_server.cc`, which includes it, is compiled again, and the `kismet` program (about 490 MB) is linked again. That took 87 seconds on a 4-core x86_64 machine, and about 3 minutes on the test Pi 4 in a rebuild that also relinked every capture helper.
   - A capture framework fix new to this tree: every capture helper is rebuilt once, but not `kismet`. On the test Pi, `libkismetdatasource.a` and all 19 capture helpers took 8.5 s at `-j4`.

   Run `make` in the whole tree rather than `make -C capture_esp32c5`: the helper's own Makefile does not rebuild `libkismetdatasource.a`, and `make install` in step 4 builds whatever is still out of date anyway, as root when you install with `sudo`. Run `make` first, so that `make install` only copies files.

   If the script edited Kismet's `Makefile.in` or regenerated `configure`, which a helper update rarely does, `make` prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` It is only a notice, and `make` carries on. When you see it, or when the update changed `kismet/capture_esp32c5/Makefile.in`, from which `configure` writes the helper's Makefile, run the same `./configure` line you used before, then `make` again. Running `configure` again with the same options does not make Kismet compile again: `config.h` keeps its time, and `make` then finds nothing to do.

4. Install with the same command as the first time. Config files you already have are left alone:

   ```bash
   cd ~/src/kismet
   make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
   ```

   For a system-wide install, this is `sudo make install INSTGRP=root SUIDGROUP=root`. Run it only after `make` in step 3 has finished: `sudo make install` on a tree that still needs compiling compiles as root and leaves root-owned files in your source tree, which can make the next `make` as your user fail.

5. Restart Kismet. A source that is already running keeps using the helper program it started with.

This was checked on the test Pi on 2026-10-02: the script, as of commit `f8e6792`, copied the new helper files, brought the login fix up to date and added two more framework fixes; `make` rebuilt the capture helpers in 8.5 s and left `kismet` as it was; and `make install` without sudo put the new helper next to it. Later that day the current script updated the same tree in place: it copied `capture_esp32c5.c`, made the redirect and `Host` header edits to `capture_framework.c` and `capture_framework.h`, and on a second run printed only its `Done.` line; the tree then matched a fresh `cfe427074` tree patched by the same script, `make` took 9.2 s, and `make install` again needed no sudo. The Pi's earlier rebuilds ran with a first version of the script, which copied the files on every run, so that `kismet` was relinked every time.

For the Docker image, a change to `capture_esp32c5.c` alone rebuilds in about a minute on the Pi, because the Kismet layer stays cached. A change to `datasource_esp32c5.h`, `add-to-kismet.sh` or the helper's `Makefile.in` rebuilds Kismet from the start (about 80 minutes on a Pi 4). [Guide: Updating](Guide-Updating) covers updating the helper, the firmware and the image together.

## Uninstalling

Kismet has no `make uninstall`.

**A home-directory install** is one folder. Stop Kismet, then:

```bash
rm -rf ~/kismet-install
```

**A system-wide install** into `/usr/local` has to be removed by hand. These are the files `make install` puts there:

```bash
sudo rm -f /usr/local/bin/kismet /usr/local/bin/kismet_server /usr/local/bin/kismet_discovery
sudo rm -f /usr/local/bin/kismet_cap_* /usr/local/bin/kismetdb_*
sudo rm -f /usr/local/lib/pkgconfig/kismet.pc
sudo rm -rf /usr/local/share/kismet
sudo rm -f /usr/local/etc/kismet*.conf
```

Checked against a fresh install into `/usr/local`: these commands remove every file it made and leave only the empty folders.

The last line also removes your own `kismet_site.conf`; copy it somewhere first if you want to keep it.

**Your per-user state** is in `~/.kismet` in the home directory of the user Kismet ran as: the web login (`kismet_httpd.conf`), the API keys (`session.db`) and the server's ID. Delete it if you want those gone too. A systemd unit you set up ([Guide: Running as a Service](Guide-Running-as-a-Service)) has to be disabled and removed separately.

**The Kismet source tree.** Delete `~/src/kismet` if you no longer need it. To keep the clone but undo `add-to-kismet.sh`, run these two commands (or delete the folder and clone Kismet again):

```bash
git -C ~/src/kismet checkout -- .
git -C ~/src/kismet clean -xfd
```

`clean -xfd` also removes everything the build produced, so the next build starts from the beginning. Afterwards `git -C ~/src/kismet status` shows no change, and another commit can be checked out.

## If the build goes wrong

| What you see | Cause | What to do |
|---|---|---|
| `does not look like a Kismet source tree` | The script was given the wrong path | Give it the top folder of the Kismet clone |
| The script fails because `aclocal` or `autoconf` is not found | autoconf or automake is missing | `sudo apt-get install autoconf automake`, then run the script again |
| The script stops after `regenerating configure` with `configure.ac:83: error: possibly undefined macro: AC_DEFINE` (and the same for `AC_MSG_WARN` and `AC_MSG_ERROR`) | pkg-config is missing, so `aclocal` cannot find its macros | `sudo apt-get install pkg-config`, then run the script again |
| `anchor not found, Kismet has changed: ...` | The tree is on a Kismet commit the script does not know | Check out `cfe427074`, or see "Trying a newer Kismet" |
| `configure: error: Package requirements (librtlsdr) were not met` | No librtlsdr, and `--disable-librtlsdr` not given | Add `--disable-librtlsdr` |
| `Package requirements (libmosquitto) were not met` | No `libmosquitto-dev` | Install it, or add `--disable-mosquitto` |
| `Package requirements (libwebsockets >= 3.1.0) were not met` | No `libwebsockets-dev` | Install it |
| `Package requirements (libusb-1.0) were not met` | No `libusb-1.0-0-dev` | Install it |
| `required libsensors lm-sensors missing, configure with --disable-lmsensors ...` | No `libsensors-dev` | Install it, or add `--disable-lmsensors` |
| No `ESP32-C5: yes` line in the `configure` summary | The script did not run on this tree, or failed | Run the script, read its output, then run `configure` again |
| `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` | A notice, not an error: the script changed Kismet's `Makefile.in` or regenerated `configure` after the tree was configured. `make` carries on | Run `configure` again with the options you used before |
| A compiler is killed, or the machine stops responding | Out of memory | Fewer jobs: `-j2` or `-j1` |
| `/usr/bin/install: cannot change ownership of '...': Operation not permitted` | `make install` as a normal user without the variables: it tries to make root the owner | Pass `INSTUSR`, `INSTGRP` and `SUIDGROUP`; see "Owners, groups and the kismet group" |
| `/usr/bin/install: invalid group 'kismet'` | `make install` as root, with no `kismet` group | See "Owners, groups and the kismet group" |
| A source fails with `Unable to find driver for '<definition>'` | `kismet_cap_esp32c5` is not in the same `bin` folder as `kismet`, or the definition is one the helper does not accept ([Install on Linux](Install-on-Linux)) | Install both from the same tree with the same prefix |
| Kismet stops at start with `Uncaught exception "kis_external tried to write with no io handler"` and a stack trace | A source with `type=esp32c5`, while `kismet_cap_esp32c5` is not in the same `bin` folder as `kismet` | Install both from the same tree with the same prefix |
| `IPC cannot run binary ...` | Installed with `make suidinstall`, and the user is not in `kismet` | Add the user to `kismet` and log in again, or use `make install` |
| `ERROR: Tried to re-register duplicate alert FLIPPERZERO` at every start | Upstream Kismet at this commit | Nothing; it is harmless |

More on [Troubleshooting](Troubleshooting).
