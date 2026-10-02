This page installs Kismet with ESP32-C5 support on a Linux PC or server, with the boards plugged into it. It is written for Debian and Ubuntu, with notes for other distributions at the end.

Other pages cover the variations: [Install on Raspberry Pi](Install-on-Raspberry-Pi) for a Pi (same build, with Pi memory and power advice), [Install on WSL2](Install-on-WSL2) for Kismet inside Windows, and [Install with Docker](Install-with-Docker) for the container image. What each build step does, and why, is on [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).

## What was tested

| System | What ran |
|---|---|
| Raspberry Pi OS (64-bit), based on Debian 13 "trixie", arm64 (Raspberry Pi 4) | This page's build, installed into the home directory, with four real boards; Kismet captured all three radios. Last runs on 2026-10-02, with the boards on firmware image `01a50bd6` (the start of the merged image's SHA-256): the helper rebuilt without sudo, four sources at once, and four boards splitting the Wi-Fi channels; later that day the current code, updated in place by `add-to-kismet.sh` and rebuilt without sudo, with the boards, four sources at once among the runs |
| Ubuntu 24.04, x86_64 (in WSL2) | A similar build as root: `configure` with the same options as on this page, then `make install INSTGRP=root SUIDGROUP=root`, installed into `/root/kismet-install`, with the fake board ([Try It Without Hardware](Try-It-Without-Hardware)) |
| Ubuntu 24.04, x86_64 (a container) | A build as root with the Docker image's `configure` options, installed system-wide into `/usr/local` with `make install INSTGRP=root SUIDGROUP=root`. The `make install` errors on this page, the `groupadd kismet` alternative, and the uninstall commands on [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) were checked there too, without boards |
| Fedora, Arch and other distributions | Not tested |

The first 2026-10-02 run used the C helper and its changes to Kismet as they were just before the latest changes to remote capture. The later run put those changes on the Pi's boards: a redirect refused without connecting to it, the port in the `Host` header, and `--ssl-certificate` turning on TLS by itself. A local source, as on this page, does not use that code. The firmware on the boards differs from a build of the current source only in details its UART0 log shows, such as its version and build time; what it sends over USB is the same.

A Debian or Ubuntu PC with boards plugged straight into it is the same build and the same helper as on the Pi, but that exact combination has not been run.

## Before you start

- **Boards:** flashed with this project's firmware, each on its native USB port. The [web flasher](https://oshri-almog.github.io/esp32c5-kismet-wifi-interface/) installs it from Chrome or Edge, on this machine or any other; [Flashing the Firmware](Flashing-the-Firmware) also has esptool and the ESP-IDF build. For several boards, use a powered USB hub ([Hardware](Hardware)).
- **Kismet has to be built from source.** No Kismet release contains the ESP32-C5 source yet, so a Kismet from your distribution, or from Kismet's own packages, cannot use these boards. You can keep one installed; the steps below put this build in its own folder, and you start it by its full path. Do not run both at once: they both want port 2501.
- **Time and memory:** allow about 1.5 GB of memory per parallel compiler. `make -j4` took about 78 minutes on a Raspberry Pi 4; a fast PC is much quicker (the complete Docker image, Kismet included, built in 18.5 minutes on a 20-core PC with 16 GB at `-j4`).

The layout used below:

| Path | What it is |
|---|---|
| `~/esp32c5-kismet-wifi-interface` | This project |
| `~/src/kismet` | Kismet's source tree, with the ESP32-C5 source added |
| `~/kismet-install` | Where Kismet is installed (or `/usr/local`, see step 4) |

## 1. Install the build packages

On Debian 13 or Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y build-essential git pkg-config autoconf automake python3 \
    libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev \
    libnm-dev libdw-dev libsqlite3-dev libsensors-dev libusb-1.0-0-dev libmosquitto-dev \
    libpcre2-dev libssl-dev
```

`autoconf`, `automake` and `python3` are there for `add-to-kismet.sh` (step 3). What each library is for, and which ones you can leave out, is on [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support). The list has not been tried on a freshly installed system, where more may be missing; `configure` names any library it cannot find.

## 2. Get this project and Kismet

```bash
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface.git ~/esp32c5-kismet-wifi-interface
git clone https://github.com/kismetwireless/kismet.git ~/src/kismet
git -C ~/src/kismet checkout cfe427074
```

`cfe427074` is the Kismet commit the ESP32-C5 source was developed and tested against. Git reports a "detached HEAD"; that is expected.

## 3. Add the ESP32-C5 source to Kismet

```bash
sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
```

It copies the source into the tree, wires it into Kismet's build next to Kismet's CatSniffer source, fixes seven upstream bugs in Kismet's capture framework (among them a memory leak, and a remote-capture login that went into the URL), and regenerates `configure`. It prints a `copied <file>` or `edited <file>` line for each change and ends with:

```text
  regenerating configure (needs autoconf and automake)
Done. Now: cd /home/you/src/kismet && ./configure && make
```

Use the `configure` options in the next step rather than the plain command it suggests. Running it again is safe: edits already made are skipped, a file is copied only when this project's version differs from the tree's, and `configure` is regenerated only when `configure.ac` is newer than it, so a second run changes nothing. Running it after updating this project is how a new version of the helper gets in.

## 4. Choose where to install, and configure

| | In your home directory (`~/kismet-install`) | System-wide (`/usr/local`) |
|---|---|---|
| Tested | Yes, with real boards | The install commands only, as root in a container without boards |
| sudo for the install | No | Yes |
| Kismet on your `PATH` | No: start it as `~/kismet-install/bin/kismet` | Yes |
| Config files | `~/kismet-install/etc/` | `/usr/local/etc/` |
| Uninstall | Delete the folder | Remove the files by hand ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) lists them) |

For the home directory (the tested route):

```bash
cd ~/src/kismet
./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr \
    --disable-ubertooth --disable-bladerf --disable-btgeiger
```

For a system-wide install, leave out `--prefix`; Kismet's default is `/usr/local`:

```bash
cd ~/src/kismet
./configure --disable-python-tools --disable-librtlsdr \
    --disable-ubertooth --disable-bladerf --disable-btgeiger
```

The `--disable` options leave out hardware these boards do not need and Kismet's legacy Python tools. At the end, check the summary for these lines:

```text
       Installing into: /home/you/kismet-install
 Websocket datasources: yes
              ESP32-C5: yes
```

`ESP32-C5: yes` means the source is in the build. `Websocket datasources: yes` means the capture helpers can connect to a Kismet elsewhere ([Remote Capture](Remote-Capture)). Without the NetworkManager development package, `configure` prints a NetworkManager warning; it does not affect these boards.

## 5. Compile

```bash
cd ~/src/kismet
nice make -j4
```

Use no more parallel jobs than you have memory for, at about 1.5 GB each: `-j4` needs about 6 GB free. `make -j` with the number of cores can exhaust memory on a machine with many cores; at `-j20`, WSL2 on a 15 GB machine used up the memory and the WSL distribution had to be terminated. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) has the measurements and a one-line way to pick the number. Warnings are expected: the test build printed 76 warning lines, all from Kismet's own files. When it finishes, both programs exist:

```bash
ls -l ~/src/kismet/kismet ~/src/kismet/capture_esp32c5/kismet_cap_esp32c5
```

## 6. Install

Into your home directory:

```bash
cd ~/src/kismet
make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
```

The three variables make every installed file yours, so nothing needs root. Without them, `make install` tries to make `root` the owner of every file, which a normal user cannot do. It stops at the first file:

```text
/usr/bin/install: cannot change ownership of '/home/you/kismet-install/bin/kismet': Operation not permitted
```

Run as root, `make install` also needs a `kismet` group, and on a system without one it stops with `/usr/bin/install: invalid group 'kismet'`. That is what the system-wide variables below avoid.

System-wide:

```bash
cd ~/src/kismet
sudo make install INSTGRP=root SUIDGROUP=root
```

`SUIDGROUP=root` avoids the `kismet` group error. The alternative is to create the group Kismet expects (`sudo groupadd kismet`) and run `sudo make install` without variables.

Run `sudo make install` only after `make` (step 5) has finished as your normal user, so that it only copies files. Anything it still has to compile, it compiles as root, and that leaves root-owned files in your source tree.

Either way, the install ends with `Kismet has NOT been installed suid-root. This means you will need to start it as root...`. That advice is for Kismet's Wi-Fi and Bluetooth helpers, which reconfigure network interfaces. The C helper (`kismet_cap_esp32c5`) needs only its serial port, so Kismet can run as your normal user. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) explains `make suidinstall` and when you would want it.

The rest of this page uses `~/kismet-install/bin/kismet`; after a system-wide install, the command is `kismet`.

## 7. Serial port permissions

On Debian and Ubuntu the boards' ports belong to the `dialout` group:

```bash
ls -l /dev/ttyACM0
id
```

The first line should start with `crw-rw----` and name `root dialout`. If `id` does not list `dialout`, add yourself, then log out and in again:

```bash
sudo usermod -aG dialout $USER
```

The test Pi's user was in `dialout` already, so this step was not needed there.

Without it, Kismet reports `cannot open /dev/ttyACM0: Permission denied` for the source.

You do not need a udev rule. The boards come up with group `dialout`, and udev gives each one a stable name that holds its MAC:

```bash
ls -l /dev/serial/by-id/
```

```text
usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00 -> ../../ttyACM0
```

Use these names for sources you keep in a config file: `ttyACM` numbers follow the order in which boards appear and can change, the `/dev/serial/by-id/` name stays with the board.

## 8. Check the build

```bash
~/kismet-install/bin/kismet --version
~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1
```

`kismet --version` prints something like `Kismet 2026.09.0-cfe427074` (the numbers before the dash are the year and month of your build) and exits with status 1, which is normal for Kismet.

`--list` shows each board the helper can see three times, once per radio, and exits with status 2, also normal. It writes to stderr, hence `2>&1`. With one board on `ttyACM0`:

```text
esp32c5 supported data sources:
    esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
```

- The three lines are alternatives: a board captures with one radio at a time.
- A board that a running source is already using is left out, all three lines of it.
- Every Espressif chip on its native USB port has the same USB ID (`303a:1001`), so other ESP32 boards appear here too.
- With no free board: `esp32c5 - No supported data sources found...`

## 9. Set the web login

Kismet's web UI listens on port 2501 on every network interface. Until a login exists, the first person to open it chooses the admin user and password. Set one before the first start:

```bash
mkdir -p ~/.kismet
printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > ~/.kismet/kismet_httpd.conf
chmod 600 ~/.kismet/kismet_httpd.conf
```

Change `admin` and the password. Kismet reads this file from the home directory of the user it runs as, taken from the system's user database, not from `$HOME`. Started with `sudo`, it would read `/root/.kismet` instead. For remote capture you can use the same login, whatever its password holds, or an API key ([Remote Capture](Remote-Capture)). The one login that cannot work there is a user name containing `:` together with an `&` anywhere in the user name or password.

If you skip this step, Kismet logs `This is the first time Kismet has been run as this user.  You will need to set an administrator username and password...`, and the browser asks you to choose one on first visit.

## 10. First run

Kismet writes its log to the directory it starts in, so give it one:

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi'
```

Change `ttyACM0` to your board's port. The `-c` definition names the board, the radio (`wifi`, `zigbee` or `btle`) and the source; [Source Definitions](Source-Definitions) has every form. Look for:

```text
INFO: Found type 'esp32c5' for 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi'
INFO: Data source 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi' launched successfully
INFO: c5-wifi capturing (wifi)
```

`ERROR: Tried to re-register duplicate alert FLIPPERZERO` appears at every start of this Kismet version and is harmless.

Open `http://localhost:2501` on the same machine, or `http://192.168.1.50:2501` from another one, with the machine's address in place of `192.168.1.50`. Stop Kismet with Ctrl+C. The log stays in `~/kismet-logs`, named like `Kismet-20260928-14-03-22-1.kismet`, with the time in UTC.

> **Note:** Only capture on networks and devices you own or are authorised to test.

## 11. Sources that stay: kismet_site.conf

Kismet reads `kismet_site.conf` after all its other config files, and what it sets wins. `make install` does not create it; you do. It lives in the install's `etc` folder: `~/kismet-install/etc/kismet_site.conf`, or `/usr/local/etc/kismet_site.conf` after a system-wide install. Put your changes here rather than in the stock `.conf` files: in those the first value of a setting wins, so a line added at the end is ignored, and `make forceconfigs` replaces them.

```ini
# ~/kismet-install/etc/kismet_site.conf

# One source per board, by its stable name. Change the MACs to your boards' (ls /dev/serial/by-id/).
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=c5-wifi,type=esp32c5
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=zigbee,name=c5-zigbee,type=esp32c5

# Logs always go here, wherever Kismet is started; the folder must exist
log_prefix=/home/you/kismet-logs/
```

Change the MACs, the names and `/home/you`. After a system-wide install, the `etc` folder belongs to root, so create and edit the file with `sudo`:

```bash
sudo nano /usr/local/etc/kismet_site.conf
```

Then start Kismet without `-c`:

```bash
~/kismet-install/bin/kismet --no-ncurses
```

It logs `Loading optional sub-config file: /home/you/kismet-install/etc/kismet_site.conf` and opens both sources. If it logs `Optional sub-config file not present: ...` instead, the file is in the wrong folder. The `Loading config override file ...` line logged before it appears either way, so it does not show that the file was read.

- **`type=esp32c5`** hands the definition straight to the C helper, instead of first asking every helper whether it is theirs. It is optional, but it helps when a definition has a mistake in it, such as a wrong `mode=` or `channel=`: with it, Kismet shows the helper's reason; without it, only `Unable to find driver for '<definition>'`. A board that is not plugged in yet is waited for either way: Kismet shows the helper's reason as the source's error and retries every 5 seconds. One catch: if `kismet_cap_esp32c5` is missing from Kismet's `bin` folder, a `type=esp32c5` source makes this Kismet version stop at start (see "If something goes wrong").
- **Several `source=` lines** in this file all apply, and together they replace any `source=` lines in the other config files (there are none by default).
- **Any `-c`** on the command line makes Kismet ignore every `source=` line in its config.
- **Syntax:** a comment is a whole line starting with `#`; there are no comments at the end of a line. True and false are written `true` and `false`; Kismet does not read `yes` or `1`.

More settings (logging formats, channel hopping, the web server) are on [Kismet Configuration](Kismet-Configuration), and running several boards together on [Multiple Boards](Multiple-Boards).

## 12. The web UI

- **Login:** the browser asks for the user and password from step 9 and remembers them. Change them under Settings, Login & Password.
- **Data Sources** (in the sidebar): each running source, with its packet count and channel, and the boards the helpers report as available. An idle board appears once per radio: `esp32c5-ttyACM0` (Wi-Fi), `esp32c5zigbee-ttyACM0` and `esp32c5btle-ttyACM0`. Enable Source opens one of them. A board that a source is using drops out of the list, all three rows, because a board captures with one radio at a time; a second source on it fails with "already in use". <!-- VERIFY: the Data Sources panel in a browser; only the REST call behind it (list_interfaces) was checked, on the Pi: three rows per idle board, and all three gone for a board a source holds -->
- **API keys:** Settings, API Keys. A key with the `datasource` role lets a helper on another machine feed this Kismet; see [Remote Capture](Remote-Capture).

[Guide: First Capture](Guide-First-Capture) walks through a first session.

## Other distributions

Fedora, Arch and others have not been tested. The build is the same; the package names differ. To need fewer packages, leave out lm-sensors and MQTT, which make `configure` stop when their libraries are missing, and NetworkManager, which only gives a warning, as the Docker image does:

```bash
cd ~/src/kismet
./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr \
    --disable-ubertooth --disable-bladerf --disable-btgeiger \
    --disable-libnm --disable-lmsensors --disable-mosquitto
```

The packages that set then needs, with likely names elsewhere (the Fedora and Arch names have not been tried):

| Debian / Ubuntu | What it is | Fedora | Arch |
|---|---|---|---|
| `build-essential` | C and C++ compilers, make | `gcc gcc-c++ make` | `base-devel` |
| `git` | | `git` | `git` |
| `pkg-config` | | `pkgconf-pkg-config` | `pkgconf` |
| `autoconf automake` | for `add-to-kismet.sh` | `autoconf automake` | `autoconf automake` |
| `python3` | for `add-to-kismet.sh` | `python3` | `python` |
| `libwebsockets-dev` | remote capture from the helpers | `libwebsockets-devel` | `libwebsockets` |
| `zlib1g-dev` | zlib | `zlib-devel` | `zlib` |
| `libnl-3-dev libnl-genl-3-dev` | netlink, for Kismet's Linux Wi-Fi helper | `libnl3-devel` | `libnl` |
| `libcap-dev` | capabilities | `libcap-devel` | `libcap` |
| `libpcap-dev` | libpcap | `libpcap-devel` | `libpcap` |
| `libsqlite3-dev` | SQLite, for Kismet's log database | `sqlite-devel` | `sqlite` |
| `libpcre2-dev` | regular expressions | `pcre2-devel` | `pcre2` |
| `libssl-dev` | OpenSSL | `openssl-devel` | `openssl` |
| `libusb-1.0-0-dev` | libusb, for Kismet's USB capture helpers | `libusb1-devel` | `libusb` |
| `libdw-dev` | full backtraces if Kismet crashes | `elfutils-devel` | `libelf` |

The serial port group differs too: check it with `ls -l /dev/ttyACM0` and add yourself to whichever group that shows (probably `dialout` on Fedora and `uucp` on Arch; not checked).

For macOS and the BSDs, see [Install on macOS and BSD](Install-on-macOS-and-BSD).

## Running at boot

`make install` does not set up a service. Kismet's source tree has a systemd unit template (`packaging/systemd/kismet.service`, made by `configure`), which as shipped runs Kismet as root with its logs in the service's working directory. [Guide: Running as a Service](Guide-Running-as-a-Service) sets it up to run as your user, with `log_prefix` pointing at a folder that user can write to.

## Updating and uninstalling

- A new version of the helper needs only a partial rebuild, not all of Kismet: `add-to-kismet.sh` copies only the files that changed, so `make` compiles the helper again, and recompiles one Kismet file and relinks `kismet` only when the server-side header (`datasource_esp32c5.h`) changed. See [Guide: Updating](Guide-Updating), and "Rebuilding after a helper change" on [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).
- To uninstall a home-directory install, stop Kismet and delete `~/kismet-install`. `~/.kismet` holds your web login and API keys; delete it too if you want those gone. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) covers a system-wide install and undoing the changes to the Kismet source tree.

## If something goes wrong

| What you see | What to do |
|---|---|
| `configure` stops, naming a missing library | Install its package, or add the `--disable` option for that feature ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)) |
| `ESP32-C5` missing from the `configure` summary | `add-to-kismet.sh` did not run on this tree, or failed; run it again and read its output, then run the `configure` line from step 4 again |
| `/usr/bin/install: cannot change ownership of '...': Operation not permitted` | `make install` as a normal user without the variables; run it with the variables in step 6 |
| `/usr/bin/install: invalid group 'kismet'` | `make install` as root with no `kismet` group; run it with the variables in step 6 |
| `cannot open /dev/ttyACM0: Permission denied` | Join the port's group (step 7), then log out and in |
| `Unable to open KismetDB log at ...` and Kismet exits | Start Kismet in a folder you can write to, or set `log_prefix` to one that exists |
| The source's error reads `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, ...; say which one ...` | A definition without a port, such as a bare `esp32c5`, with several boards plugged in. Name the port: `esp32c5-ttyACM1`, or `device=/dev/serial/by-id/...` |
| The source's error reads `no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; ...` | No board is plugged in. Kismet retries every 5 seconds and picks the board up when it appears |
| `Unable to find driver for '<definition>'` | The definition itself is wrong: a `mode=` or `channel=` the helper does not accept, or a name the helper does not recognise while no board can be found (between `esp32c5` and the first `-` it accepts nothing or a radio word such as `zigbee` or `btle`, so `esp32c5foo` is not its name). Or the C helper, `kismet_cap_esp32c5`, is not installed in the same `bin` folder as `kismet` (`ls ~/kismet-install/bin/kismet_cap_esp32c5`). Once the helper is there, add `type=esp32c5` to see its reason |
| Kismet stops at start with `Uncaught exception "kis_external tried to write with no io handler"` and a stack trace | A source with `type=esp32c5` while `kismet_cap_esp32c5` is not in the same `bin` folder as `kismet`: this Kismet version crashes instead of saying that the helper is missing. Install both from the same tree (step 6) |
| `... is already in use by another capture ...` | Another source or program holds that board; a board captures with one radio at a time |
| `ERROR: c5-wifi: no capture from the board on /dev/ttyACM0 for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` | The board sent nothing the helper could use. Flash it with this project's firmware ([Flashing the Firmware](Flashing-the-Firmware)), and close any serial monitor that has the port open. Kismet opens the source again 5 seconds later; the source's error then reads only `IPC connection closed`, so the reason is in Kismet's log |
| A `wifi` source says `capturing (wifi)`, but its packet count stays at 0 | A board that was last used for 802.15.4 (still in 802.15.4 mode) when it was flashed can come up with its Wi-Fi radio deaf, and nothing reports it (a known firmware issue). Switch the board to BLE and back: run a `btle` source on it until it captures, then the `wifi` source again |

More on [Troubleshooting](Troubleshooting) and the [FAQ](FAQ).
