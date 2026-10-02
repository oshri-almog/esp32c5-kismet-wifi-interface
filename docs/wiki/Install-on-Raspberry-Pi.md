This page turns a Raspberry Pi into a Kismet capture station with ESP32-C5 boards plugged into it. It is for anyone starting from a 64-bit OS on the Pi, and it covers both routes: building Kismet on the Pi, and the Docker image. Both were tested on a Pi with real boards.

If you have not flashed your boards yet, do that first: [Flashing the Firmware](Flashing-the-Firmware). To try the software without any board, see [Try It Without Hardware](Try-It-Without-Hardware).

## What was tested

| | |
|---|---|
| Pi | Raspberry Pi 4, 8 GB |
| OS | Raspberry Pi OS (64-bit), based on Debian 13 "trixie", arm64 |
| Boards | Four ESP32-C5 boards on a powered USB hub, seen as `/dev/ttyACM0` to `/dev/ttyACM3` |
| Native build | Kismet built on the Pi from source at commit `cfe427074`, installed into the home directory without sudo |
| Seen in Kismet | Wi-Fi on 2.4 and 5 GHz, Zigbee/Thread (802.15.4) and Bluetooth LE advertising, from real boards |
| Last native run | 2026-10-02, with the boards on firmware image `01a50bd6` (the start of the merged image's SHA-256): the helper rebuilt and installed without sudo, the project's C, Python and end-to-end tests, four sources at once, four Wi-Fi boards splitting the channels, and 30 minutes of Kismet logging from a Wi-Fi and a BLE board |
| Docker | The image built on the Pi (about 80 minutes), then run there with the four boards: all 8 checks passed, with Wi-Fi, 802.15.4 and BLE sources and the helper role. That image was built before both rounds of fixes to the helper and to Kismet's capture framework |

The 2026-10-02 run used the helpers and their changes to Kismet as they were just before the latest changes to remote capture: a redirect refused without connecting to it, the port in the `Host` header, `--ssl-certificate` turning on TLS by itself in the C helper, and the Python remote helper's proxy rules, one-line error messages and stop signal. Those are covered by the end-to-end tests with the fake board and a real Kismet, not yet by a run on the Pi. The firmware on the boards differs from a build of the current source only in details its UART0 log shows, such as its version and build time; what it sends over USB is the same.

Not tested: the Raspberry Pi 5, Pis with less than 8 GB, a 32-bit OS, and other operating systems on a Pi, plain Debian included. Four boards did run at once, two on Wi-Fi, one on Zigbee and one on BTLE: for a minute as local sources of Kismet and through the remote helpers, for 10 minutes in one Python remote helper, and in the container. On 2026-10-02 the minute as local sources and a minute in one Python remote helper were run again (in the first local run one board hung on its switch to BLE, see [If something goes wrong](#if-something-goes-wrong); the repeat ran clean), and four Wi-Fi boards ran a 2-minute survey together.

## Which Pi, and how much memory

Compiling Kismet is what needs memory; running it needs far less. On the test Pi, at `make -j4`, the three largest files compiled at the same time (`phy_80211.cc` at 2.4 GB, `phy_80211_dissectors.cc` at 1.8 GB and `phy_80211_components.cc` at 1.7 GB) and left about 1.1 GB of the 8 GB available, with about 40 MB of swap in use.

| Pi | Native build | Docker image |
|---|---|---|
| Pi 4, 8 GB, 64-bit OS | Tested: `make -j4`, about 78 minutes | Tested: built in about 80 minutes, `-j4` chosen automatically |
| Pi 4 or Pi 5, 4 GB | Use `make -j2` | The image build picks the job count from free memory |
| Pi with 2 GB | Use `make -j1`, with at least 2 GB of swap: one file alone needed 2.4 GB on the test Pi | The image build picks `-j1` and needs the same swap |
| Pi with 1 GB | One compiler alone needed up to 2.4 GB on the test Pi, so the build would lean hard on swap | Once images are published, pull one rather than build it |
| Any Pi on a 32-bit OS | Not tested | No image: the images are arm64 and amd64 only |

Only the 8 GB row was measured. The other rows are worked out from its peaks and the Docker build's rule of about 1.5 GB per compiler, and have not been tried.

To check that the OS is 64-bit, ask for the architecture of its packages:

```bash
dpkg --print-architecture
```

`arm64` is a 64-bit OS; the test Pi prints it. `armhf` is a 32-bit OS, even when `uname -m` prints `aarch64`: on a Pi 4 or 5, the 32-bit Raspberry Pi OS can run a 64-bit kernel, so `uname -m` does not tell you which OS you have.

> **Note:** The test Pi runs Raspberry Pi OS (64-bit), the release based on Debian 13 "trixie", although its `/etc/os-release` names Debian. Plain Debian on a Pi, and Raspberry Pi OS releases based on older Debian versions, have not been tried.

## Power and USB

- **Use a powered USB hub for more than one board.** An unpowered hub browns out under several boards, and the failures look like firmware bugs. The four test boards ran through a powered hub. See [Hardware](Hardware) for cables and hubs.
- **Plug each board in by its native USB port** (USB ID `303a:1001`). It shows up as `/dev/ttyACM0`, `/dev/ttyACM1` and so on, and udev also gives it a stable name that holds its MAC:

  ```text
  /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00
  ```

  The `ttyACM` numbers follow the order in which the boards appear and can change after a replug. The `/dev/serial/by-id/` name stays with the board, so use it for sources you keep in a config file.
- **If a board goes missing,** look for `USB disconnect` in the kernel log, then replug the board or power-cycle the hub. The helper can only list boards that are on the USB bus. Debian's kernel lets only root read the kernel log by default, hence `sudo`:

  ```bash
  sudo dmesg | grep -i 'usb disconnect'
  ```

## Choose a route

| | Native build | Docker |
|---|---|---|
| Tested with real boards | Yes, all three radios | Yes, on this Pi, with an image built before both rounds of fixes to the helper and to Kismet's capture framework |
| First setup | About 78 minutes of compiling at `-j4`, plus package installs | About 80 minutes of image build, until a published image can be pulled |
| Needs sudo | Only for `apt-get` (and `usermod` if you are not in `dialout`) | For every `docker` command, unless your user is in the `docker` group |
| A new version of the C helper | A partial rebuild, not all of Kismet: the helper is compiled again, and one Kismet file plus a relink of `kismet` only when the server-side header changed ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)) | Rebuild the image: about a minute when only the helper changed, because Kismet stays cached |
| Starting at boot | A systemd service you set up | Docker's restart policy |

The rest of this page follows the native build first. The Docker route comes after it.

## Route 1: native build

The layout used below, the same as on the test Pi:

| Path | What it is |
|---|---|
| `~/esp32c5-kismet-wifi-interface` | This project |
| `~/src/kismet` | Kismet's source tree, with the ESP32-C5 source added |
| `~/kismet-install` | Where Kismet is installed. Nothing goes outside your home directory, so no sudo is needed, and uninstalling means deleting this folder |

### 1. Install the build packages

```bash
sudo apt-get update
sudo apt-get install -y build-essential git pkg-config autoconf automake python3 \
    libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev \
    libnm-dev libdw-dev libsqlite3-dev libsensors-dev libusb-1.0-0-dev libmosquitto-dev \
    libpcre2-dev libssl-dev
```

`autoconf`, `automake` and `python3` are there for `add-to-kismet.sh` (step 4), which edits Kismet's build files and regenerates its `configure` script. What each library is for, and which ones you can leave out, is on [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support). The list has not been tried on a freshly installed image, where more may be missing; `configure` names any library it cannot find.

### 2. Get this project

```bash
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface.git ~/esp32c5-kismet-wifi-interface
```

### 3. Get Kismet at the tested commit

No Kismet release contains the ESP32-C5 source yet, so Kismet is built from source, at the commit the source was developed and tested against:

```bash
git clone https://github.com/kismetwireless/kismet.git ~/src/kismet
git -C ~/src/kismet checkout cfe427074
```

Git says the tree is in "detached HEAD" state. That is expected: you are on a fixed commit, not a branch.

### 4. Add the ESP32-C5 source to Kismet

```bash
sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
```

It copies the source into the tree, wires it into Kismet's build, fixes seven upstream bugs in Kismet's capture framework, and regenerates `configure`. A first run on a fresh tree prints one line per change:

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

Ignore the plain `./configure` it suggests; use the options in the next step. Running it again is safe: edits already made are skipped, a file is copied only when this project's version differs from the tree's, and `configure` is regenerated only when `configure.ac` is newer than it, so a second run changes nothing. Running it after updating this project is how a new version of the helper gets in. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) lists every change it makes.

### 5. Configure

```bash
cd ~/src/kismet
./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr \
    --disable-ubertooth --disable-bladerf --disable-btgeiger
```

These are the options used on the test Pi. `--prefix` puts the installation in your home directory. The `--disable` options leave out things these boards do not use: software-defined radios, Ubertooth, bladeRF, a Bluetooth Geiger counter and Kismet's legacy Python tools.

At the end, `configure` prints a summary. Check these three lines:

```text
       Installing into: /home/pi/kismet-install
 Websocket datasources: yes
              ESP32-C5: yes
```

`ESP32-C5: yes` means the source was added. `Websocket datasources: yes` means the capture helpers can do remote capture over Kismet's web port. The summary also runs `Setuid group: kismet` and `Prelude  SIEM : no` together on one line; that is an upstream cosmetic bug.

### 6. Compile

Compiling takes over an hour, so run it in the background, where it keeps going if your SSH session drops:

```bash
cd ~/src/kismet
nohup nice make -j4 > ~/kismet-build.log 2>&1 &
tail -f ~/kismet-build.log
```

Press Ctrl+C to stop watching; that stops `tail`, not the build. On the test Pi 4 (8 GB) this took about **78 minutes** and finished without running out of memory. The log had 76 warning lines, all from Kismet's own files. On a Pi with less memory, use `-j2` or `-j1`, as in the table under "Which Pi, and how much memory".

The build has finished when `pgrep -x make` prints nothing. Check that the end of the log shows no `Error` line and that both programs exist:

```bash
tail -n 5 ~/kismet-build.log
ls -l ~/src/kismet/kismet ~/src/kismet/capture_esp32c5/kismet_cap_esp32c5
```

### 7. Install

```bash
cd ~/src/kismet
make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
```

The three variables make every installed file yours, so nothing needs root. Without them, `make install` tries to make `root` the owner of every file, which a normal user cannot do. It stops at the first file:

```text
/usr/bin/install: cannot change ownership of '/home/pi/kismet-install/bin/kismet': Operation not permitted
```

Run as root instead, it also needs a `kismet` group, and on a system without one it stops with `/usr/bin/install: invalid group 'kismet'`. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) explains both.

The install puts Kismet, its capture helpers (among them the C helper, `kismet_cap_esp32c5`), the `kismetdb_*` log tools and `kismet_discovery` in `~/kismet-install/bin`, the config files in `~/kismet-install/etc`, and the web UI in `~/kismet-install/share/kismet`. The installed `kismet` is about 490 MB because it carries debug information.

At the end it prints `Kismet has NOT been installed suid-root.  This means you will need to start it as root...`. That is Kismet's advice for its Wi-Fi and Bluetooth helpers, which reconfigure network interfaces. The C helper needs only the serial port, so you run Kismet as your normal user.

### 8. Serial port permissions

The boards' ports belong to the `dialout` group:

```bash
ls -l /dev/ttyACM0
id
```

The first line should start with `crw-rw----` and name `root dialout`. If `id` does not list `dialout`, add yourself, then log out and in again:

```bash
sudo usermod -aG dialout $USER
```

The test Pi's user was in `dialout` already, so this step was not needed there.

Without it, the source fails with `cannot open /dev/ttyACM0: Permission denied`. No udev rule is needed: the boards come up with group `dialout` and their `/dev/serial/by-id/` links on their own.

### 9. Check the build

```bash
~/kismet-install/bin/kismet --version
~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1
```

The first prints the version and exits with status 1, which is normal for Kismet:

```text
Kismet 2026.09.0-cfe427074
```

The numbers before the dash are the year and month you built it in, so yours may differ; the part after the dash is Kismet's commit.

The second lists the boards the C helper can see, each three times, once per radio. It writes to stderr (hence `2>&1`) and exits with status 2; both are normal. With one idle board on `ttyACM0`:

```text
esp32c5 supported data sources:
    esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
```

- The three lines are alternatives: a board captures with one radio at a time.
- A board that a running source is already using is left out, all three lines of it.
- Every Espressif chip on its native USB port has the same USB ID, so another ESP32 board plugged into the Pi shows up here too.
- With no free board: `esp32c5 - No supported data sources found...`

### 10. Set the web login

Kismet's web UI listens on port 2501 on every network interface of the Pi. Until a login is set, the first person to open it chooses the admin user and password. Set it before the first start:

```bash
mkdir -p ~/.kismet
printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > ~/.kismet/kismet_httpd.conf
chmod 600 ~/.kismet/kismet_httpd.conf
```

Change `admin` and the password. Kismet reads this file from the home directory of the user it runs as. Do not start Kismet with `sudo`: it would look in `/root/.kismet` instead, and it does not need root for these boards.

If you plan to use the same login for [remote capture](Remote-Capture), any password works; the one login that cannot is a user name containing `:` together with an `&` anywhere in the user name or password. An API key is the better choice there anyway.

### 11. First run

Kismet writes its log into the directory it starts in, so start it in one of its own:

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi'
```

Change `ttyACM0` to your board's port. `--no-ncurses` prints plain log lines. `-c` adds one source; the definition says which board, which radio and what to call it (see [Source Definitions](Source-Definitions)).

Among the startup messages you should see:

```text
INFO: Found type 'esp32c5' for 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi'
INFO: Data source 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi' launched successfully
INFO: c5-wifi capturing (wifi)
```

On the test Pi, a board already on Wi-Fi was capturing about 1 to 1.5 s after launch, and one that had to switch radios about 1.5 s, because a radio switch reboots the board. When the board also dropped off USB and came back during the switch, it took 2.5 to 3 s.

Kismet also logs `ERROR: Tried to re-register duplicate alert FLIPPERZERO` at every start. It is an upstream quirk and harmless.

Now open the web UI from another computer: `http://192.168.1.50:2501`, with your Pi's address in place of `192.168.1.50` (`hostname -I` on the Pi prints it). Log in with the user and password from step 10. Devices appear as the board hops across the 42 Wi-Fi channels on 2.4 and 5 GHz.

Press Ctrl+C in the terminal to stop Kismet. The log file stays in `~/kismet-logs`, named like `Kismet-20260928-14-03-22-1.kismet` (the time in the name is UTC).

> **Note:** Only capture on networks and devices you own or are authorised to test.

For a guided tour of the web UI, follow [Guide: First Capture](Guide-First-Capture).

### 12. More boards, and sources that stay

Give Kismet one `-c` per board, each naming its port:

```bash
~/kismet-install/bin/kismet --no-ncurses \
    -c 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi' \
    -c 'esp32c5-ttyACM1:mode=zigbee,name=c5-zigbee' \
    -c 'esp32c5-ttyACM2:mode=btle,name=c5-btle'
```

With several boards plugged in, always name the port. A bare `esp32c5` cannot choose between them: its source fails with `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, ...; say which one with device= or a source name like esp32c5-ttyACM0`, and Kismet keeps retrying it every 5 seconds.

To keep sources without typing them, put them in `~/kismet-install/etc/kismet_site.conf`, by their `/dev/serial/by-id/` names so that renumbered ports do not matter. [Install on Linux](Install-on-Linux) shows the file, and [Multiple Boards](Multiple-Boards) covers splitting channels between boards. Any `-c` on the command line makes Kismet ignore the `source=` lines in its config files.

## Route 2: Docker

The image holds the C helper and a Kismet built from the same Kismet commit with `add-to-kismet.sh` applied. Its `configure` options differ slightly, its programs are stripped of debug information, and it runs Kismet as root inside the container; [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) lists both `configure` lines. Everything about running it (environment variables, volumes, the web login, Compose) is on [Install with Docker](Install-with-Docker) and [Docker Reference](Docker-Reference). This section covers what is different on a Pi.

> **Note:** The container was tested on this Pi with its four real boards (Wi-Fi, 802.15.4 and BLE sources, boards named by their `/dev/serial/by-id` links, and the helper role feeding a Kismet on the Pi), but with an image built before both rounds of fixes to the helper and to Kismet's capture framework. The current image has not yet been rebuilt and run on the Pi.

### Install Docker

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-buildx
```

This is what the test Pi runs (Docker 26.1.5 and buildx 0.13.1 from Debian 13). The commands below use `sudo`. Adding your user to the `docker` group would let you drop it, but membership of that group is equivalent to root on the Pi, which is why the test Pi kept using `sudo`.

These packages do not include Docker Compose, so the commands below use plain `docker`. To use Compose, see [Install with Docker](Install-with-Docker#debian-and-raspberry-pi) (Install Docker, Debian and Raspberry Pi), which replaces these packages with Docker's own. The test Pi's container checks did run through `compose.yaml` with Compose, but how Compose was installed on it was not recorded, and replacing `docker.io` with Docker's own packages has not been tried there.

### Get the image

Until the first release is published, build the image on the Pi, from this project's folder. If you skipped Route 1, install git and get the project first (a minimal OS may not have git):

```bash
sudo apt-get install -y git
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface.git ~/esp32c5-kismet-wifi-interface
```

Then build the image:

```bash
cd ~/esp32c5-kismet-wifi-interface
sudo docker build -f docker/Dockerfile --target kismet -t esp32c5-kismet:latest .
```

- **Time:** about 80 minutes on the test Pi 4 (8 GB), almost all of it compiling Kismet. Later builds reuse the compiled Kismet: when only the C helper has changed, a rebuild takes about a minute. The build needs internet access (Debian packages, GitHub for Kismet, Docker Hub).
- **Memory:** the build picks its parallel jobs from free memory, about 1.5 GB per compiler, at most 4 and at least 1, and prints `building with -j<N>`. The 8 GB Pi got `-j4`. To choose, add `--build-arg JOBS=2`; use the same value on later builds, or Docker compiles Kismet again from the start.
- **Size:** on amd64 the finished image is 177 MB, after stripping debug information. The arm64 image's size on the Pi was not recorded.
- **A long build over SSH:** the test Pi ran the build as a transient systemd unit, so that it survived the SSH session ending:

  ```bash
  sudo systemd-run --unit=esp32c5-docker-build --working-directory=$HOME/esp32c5-kismet-wifi-interface \
      sh -c "exec > $HOME/docker-build.log 2>&1; docker build -f docker/Dockerfile --target kismet -t esp32c5-kismet:latest ."
  tail -f ~/docker-build.log
  ```

Once images are published, pull the arm64 image instead of building. None has been published yet, so this has not been tried:

```bash
sudo docker pull ghcr.io/oshri-almog/esp32c5-kismet:latest
```

A pulled image is named `ghcr.io/oshri-almog/esp32c5-kismet:latest`; use that name in place of `esp32c5-kismet` below.

### Run it

The container publishes Kismet's web port, 2501. If you also built Kismet natively (Route 1), stop that Kismet first: both want port 2501. Or publish the container on another host port, with `-p 2502:2501` in place of `-p 2501:2501` below, and open port 2502 instead.

```bash
sudo docker run -d --name esp32c5-kismet --restart unless-stopped --init \
    --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
    -e KISMET_USER=admin -e KISMET_PASSWORD=choose-a-long-password \
    -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet esp32c5-kismet
```

<!-- VERIFY: this docker run command with real boards on the Pi; the Pi's container checks ran the same settings through compose.yaml -->

Change the user and password. Given this way, the password also stays in your shell history. To keep it off the command line, leave out both `-e` options: the container then makes up a login, keeps it in the `kismet-home` volume and prints it once in its log, which `sudo docker logs esp32c5-kismet 2>&1 | grep "web login"` finds. [Install with Docker](Install-with-Docker) covers the login in full, including a `.env` file for Compose.

The container starts Kismet with one Wi-Fi source per board it finds. To choose radios and ports, add `-e KISMET_SOURCES="..."`, as described on [Install with Docker](Install-with-Docker). A source can name a board by its `ttyACM` number, or by its `/dev/serial/by-id` link, the same as on the Pi itself: the container makes the same links as the host. Then open `http://192.168.1.50:2501` with your Pi's address.

- `--device-cgroup-rule` lets the container open USB serial ports: `166` is `ttyACM`, the boards' native USB, and `188` is `ttyUSB`. The container makes the device nodes itself and keeps up when a board reboots or comes back under another number. It needs no added capability: the C helper drops all of its own, and the image masks Kismet's other capture types, whose helpers crash without `NET_ADMIN`.
- `--restart unless-stopped` starts the container again whenever Docker starts, so at boot when the Docker service is enabled (`systemctl is-enabled docker` prints `enabled`).

To see what the container did at start, including a `source: ...` line for each board it found:

```bash
sudo docker logs esp32c5-kismet
```

> **Note:** A board captures for one Kismet at a time. While the container captures from a board, a source for it on the Pi itself fails with `... is already in use by another capture ...`, and esptool is refused too: the helpers put the port in exclusive mode, which holds across the container boundary. The exception is a program run with `sudo`, which that mode does not keep out. `--list` on the Pi still shows a board the container holds, because it cannot see the container's lock.

The container cannot flash boards: the image holds no firmware and no flashing tools. Flash from the Pi itself or another machine ([Flashing the Firmware](Flashing-the-Firmware)), with the container stopped.

## Running at boot

For the native build, Kismet ships a systemd unit template, but `make install` does not install it, and as shipped it runs Kismet as root with its logs going to the service's working directory. [Guide: Running as a Service](Guide-Running-as-a-Service) sets it up to run as your user, with a login and a log directory that work.

For Docker, the `--restart unless-stopped` option above (or `restart: unless-stopped` in Compose) brings Kismet back after a reboot when the Docker service is enabled at boot (`systemctl is-enabled docker` prints `enabled`). This has not been checked on the test Pi. <!-- VERIFY: that the container comes back after a reboot of the Pi with the Docker service enabled -->

## If something goes wrong

| What you see | What to do |
|---|---|
| `configure` stops, naming a missing library | Install the package from step 1, or add the `--disable` option for that feature ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)) |
| The build stops, or the Pi stops responding while compiling | Out of memory: run `make` again with fewer jobs (`-j2` or `-j1`) |
| `/usr/bin/install: cannot change ownership of '...': Operation not permitted` | Run `make install` with the three variables from step 7 |
| `/usr/bin/install: invalid group 'kismet'` | Run `make install` with the three variables from step 7, as your normal user |
| `cannot open /dev/ttyACM0: Permission denied` | Add yourself to `dialout` (step 8), then log out and in |
| A board is missing from `--list` | Check the kernel log with `sudo dmesg \| grep -i 'usb disconnect'`; replug the board or power-cycle the hub. A board in use by a running source is also left out |
| `... is already in use by another capture ...` | Another source or program holds that board. A board captures with one radio at a time |
| `ERROR: c5-wifi: no capture from the board on /dev/ttyACM0 for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` | The board sent nothing the helper could use: flash it with this project's firmware, and close any serial monitor on the port. Right after a radio switch, the board may instead have dropped off USB, come back and stopped answering, a known issue whose cause is not established (the firmware, or the power on that hub port). On the test Pi it was always the same board. In ordinary switches after a capture it happened once in 160; when Kismet started with several boards switching radio at once, that board dropped off USB every time (25 of 25) and stayed silent in 3 of them. Stop Kismet, then reset the board with esptool, set up as on [Flashing the Firmware](Flashing-the-Firmware#get-esptool): `python -m esptool --chip esp32c5 -p /dev/ttyACM0 read_mac` resets it when it finishes. Or replug it. Kismet opens the source again every 5 seconds, which does not cure it; its error then reads only `IPC connection closed`, so the reason is in Kismet's log |
| A `wifi` source says `capturing (wifi)`, but its packet count stays at 0 | A board that was last used for 802.15.4 (still in 802.15.4 mode) when it was flashed can come up with its Wi-Fi radio deaf, and nothing reports it (a known firmware issue). Switch the board to BLE and back: run a `btle` source on it until it captures, then the `wifi` source again |
| `Unable to open KismetDB log at ...` and Kismet exits | Start Kismet in a directory you can write to, as in step 11 |
| `ERROR: Tried to re-register duplicate alert FLIPPERZERO` | Harmless; it appears at every start of this Kismet version |

Everything else is on [Troubleshooting](Troubleshooting).

## Next steps

- [Guide: First Capture](Guide-First-Capture): a first session in the web UI.
- [Multiple Boards](Multiple-Boards) and [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey): several boards on one Pi.
- [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi): feed boards plugged into a Windows PC to this Pi.
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf`, logging and API keys.
- [Guide: Updating](Guide-Updating): new versions of the helper and the firmware.
