# ESP32-C5 Kismet Interface

**ESP32-C5 boards as Kismet capture sources: dual-band Wi-Fi, Zigbee/Thread and Bluetooth LE advertising.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![kismet/: GPL-2.0-or-later](https://img.shields.io/badge/kismet%2F-GPL--2.0--or--later-blue.svg)](kismet/COPYING.md)
![Chip](https://img.shields.io/badge/chip-ESP32--C5-red)
![Kismet](https://img.shields.io/badge/Kismet-cfe427074%2C%20built%20from%20source-orange)
![Kismet host](https://img.shields.io/badge/Kismet%20host-Linux%20%7C%20Raspberry%20Pi%20%7C%20Docker-lightgrey)
![Boards on](https://img.shields.io/badge/boards%20on-Linux%20%7C%20Windows-lightgrey)

Plug an ESP32-C5 board into the machine that runs Kismet, or into a Windows PC on the same network, and Kismet gets a new capture source: 802.11 on 2.4 and 5 GHz, IEEE 802.15.4 for Zigbee and Thread, or Bluetooth LE advertising, whichever the source asks for. A board listens with one radio at a time, so add boards to cover more radios and channels. Kismet hops their channels and logs their packets like those of any other source. It keeps one source per board and radio across reboots and reconnects, because a source's ID comes from the board's MAC. Kismet has no release with this source in it yet: you build it from source with a small patch, or run the Docker image, which does that for you.

**Documentation: [the wiki](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki).**

## What it does

| | |
|---|---|
| **Three radios per board** | Wi-Fi on 2.4 and 5 GHz, IEEE 802.15.4 for Zigbee and Thread, or Bluetooth LE advertising: one at a time, chosen by the source definition (`esp32c5-ttyACM0`, `esp32c5zigbee-ttyACM0`, `esp32c5btle-ttyACM0`). |
| **Both Wi-Fi bands** | 42 channels: 1–14, 36–64, 100–144 and 149–177. Kismet hops them, and boards on the same radio hop the list from different starting points, so they are not on the same channel at once. |
| **A normal Kismet source** | Source type `esp32c5`. Boards appear under *Data Sources* in Kismet's web UI, and their packets go into the device list, the logs and the REST API like any other source's. The tests checked this through the REST API; the web UI has not been looked at in a browser. |
| **Boards on another machine** | Kismet's remote capture feeds boards from wherever they are plugged in: the C helper `kismet_cap_esp32c5` from Linux, the Python remote helper from Windows or anything else with Python. |
| **Stable identity** | A board reports its MAC as its USB serial number. Its source keeps the same UUID when the port name changes, the board reboots or the helper reconnects, so Kismet does not collect duplicates. |
| **Radio metadata** | Channel, frequency and signal with every packet: radiotap for Wi-Fi, a signal block for 802.15.4, the LE pseudo-header for BLE. |
| **Receive only** | The boards never transmit, except an 802.15.4 self-test you have to ask for by hand. <!-- VERIFY: whether the ESP32-C5 802.15.4 driver sends automatic ACKs in promiscuous mode --> |
| **Docker** | One image with Kismet and the C helper for amd64 and arm64, and a demo image with a fake board that needs no hardware. |

## Supported setups

| Setup | Kismet runs on | Boards plug into | Tested | Install guide |
|---|---|---|---|---|
| Raspberry Pi | The Pi | The Pi | Raspberry Pi 4, 8 GB, Debian 13 arm64, four boards on a powered hub, four sources at once | [Install on Raspberry Pi](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-on-Raspberry-Pi) |
| Linux PC | The PC | The PC | WSL2 Ubuntu 24.04 with the fake board. Fedora and Arch not tested | [Install on Linux](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-on-Linux) |
| Docker | A container on Linux or a Pi | The host | On a Raspberry Pi 4 (arm64), with the current image: four boards ran in a container as Wi-Fi, 802.15.4 and BLE sources, and the `helper` role fed a Kismet outside it. The image also passes its smoke test with the fake board on amd64 and arm64 | [Install with Docker](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-with-Docker) |
| Windows | WSL2, Docker Desktop, a Pi or a Linux machine | Windows COM ports, through the Python remote helper | Windows 11 feeding Kismet in WSL2, in Docker Desktop, and on a Raspberry Pi across the LAN | [Install on Windows](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-on-Windows), [Install on WSL2](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-on-WSL2) |
| macOS, BSD | Untested | Untested | Not tested | [Install on macOS and BSD](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-on-macOS-and-BSD) |

The current helpers have passed their tests against a real Kismet with the fake board, and ran with real boards on the Raspberry Pi on 2026-10-02, four sources at once among the runs. The current Docker image ran with the Pi's boards that day too. On Windows the current Python remote helper ran with a board that day, feeding Kismet in WSL2. Its run across the LAN to a Pi used the version just before its latest changes, and the run with Docker Desktop an earlier image and an earlier version of the helper.

Kismet itself runs on Linux: natively, in WSL2 or in a container. Docker Desktop cannot see USB boards by itself, so the tested way on Windows is the Python remote helper (attaching boards to WSL with usbipd has not been tried). [Choosing a setup](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Choosing-a-Setup) compares the options.

## Quick start

### Try it without hardware

Needs Docker with Compose.

```bash
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface
cd esp32c5-kismet-wifi-interface
docker compose --profile demo up demo
```

Open http://localhost:2501 and log in as `demo` / `demo`. A fake board shows three access points, one on 2.4 GHz and two on 5 GHz. For the other radios, put `ESP32C5_DEMO=zigbee` or `ESP32C5_DEMO=btle` in front of the last command:

```bash
ESP32C5_DEMO=btle docker compose --profile demo up demo
```

With `sudo`, as on a Raspberry Pi, the variable goes after it (`sudo ESP32C5_DEMO=btle docker compose ...`); in front of `sudo` it never reaches Compose, and the demo starts on Wi-Fi.

In PowerShell, set the variable first; it stays set until you close the window:

```powershell
$env:ESP32C5_DEMO = "btle"
docker compose --profile demo up demo
```

Or, in any shell, put the line `ESP32C5_DEMO=btle` in a file named `.env` next to `compose.yaml`.

Until the images are published, Compose builds the image first: that took 18.5 minutes on a fast Windows PC and about 80 minutes on a Raspberry Pi 4 with 8 GB. <!-- VERIFY: once ghcr.io/oshri-almog/esp32c5-kismet:demo is published, drop this paragraph and say the demo pulls the image -->

### Raspberry Pi or Linux, boards plugged in

1. Get this repository:

   ```bash
   git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface ~/esp32c5-kismet-wifi-interface
   ```

2. Give your user access to the boards' ports. On Debian and Raspberry Pi OS, `/dev/ttyACM*` belongs to the `dialout` group; without it, flashing in step 3 stops with `Permission denied` and a source fails with `cannot open /dev/ttyACM0: Permission denied`. If `id` does not list `dialout`, add yourself, then log out and back in so the change applies (the test Pi's user was in the group already, so this step was not needed there):

   ```bash
   sudo usermod -aG dialout $USER
   ```

3. Flash each board from an ESP-IDF 5.5 shell. Stop anything that has the board's port open first, and back up the board's flash if you may want its old firmware back; [Flashing the firmware](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Flashing-the-Firmware) shows how. Change `/dev/ttyACM0` to the board's port:

   ```bash
   cd ~/esp32c5-kismet-wifi-interface/firmware
   idf.py set-target esp32c5
   idf.py -p /dev/ttyACM0 flash
   ```

   To flash on another machine with ESP-IDF instead, run the same `idf.py` commands from its copy of `firmware/`, with its port name, for example `COM14` on Windows.

   There is no prebuilt image yet. A board flashed from the [Wireshark project's browser flasher](https://oshri-almog.github.io/esp32c5-wireshark-sniffer/) (its firmware 1.2.0) works too: a test board with the 1.2.0 image the flasher installs, written with esptool, captured Wi-Fi, 802.15.4 and BLE under both helpers, with earlier versions of them; the browser flasher itself was not used in the tests. A board that streams but never gets in sync with the helper needs this project's firmware.

4. Build Kismet with the `esp32c5` source and install it into your home directory. The `make` step took about 78 minutes on a Raspberry Pi 4 with 8 GB:

   ```bash
   sudo apt-get update
   sudo apt-get install -y build-essential git pkg-config autoconf automake python3 libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev libnm-dev libdw-dev libsqlite3-dev libsensors-dev libusb-1.0-0-dev libmosquitto-dev libpcre2-dev libssl-dev
   git clone https://github.com/kismetwireless/kismet.git ~/src/kismet
   git -C ~/src/kismet checkout cfe427074
   sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
   cd ~/src/kismet
   ./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf --disable-btgeiger
   nice make -j4
   make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
   ```

   The package list has not been tried on a freshly installed system, where more may be missing; `configure` names any library it cannot find. Kismet's compiler needs about 1.5 GB of memory per job; with less than 8 GB, use fewer jobs than `-j4`.

5. Set Kismet's web login before the first start. Change `admin` and the password:

   ```bash
   mkdir -p ~/.kismet
   printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > ~/.kismet/kismet_httpd.conf
   chmod 600 ~/.kismet/kismet_httpd.conf
   ```

6. Start Kismet with one board on Wi-Fi, in a folder of its own, because Kismet writes its log into the folder it starts in:

   ```bash
   mkdir -p ~/kismet-logs
   cd ~/kismet-logs
   ~/kismet-install/bin/kismet --no-ncurses -c esp32c5-ttyACM0
   ```

   Use `esp32c5zigbee-ttyACM0` or `esp32c5btle-ttyACM0` for the other radios, and one `-c` per board. Then open `http://<the Pi's address>:2501` and log in.

> **Warning:** until a login is set, the first person to open Kismet's web page chooses it. Step 5 sets it; if you skipped it, open the page yourself straight away.

### Boards on Windows, Kismet elsewhere

You need a Kismet with the `esp32c5` source running somewhere this PC can reach (a Pi, a Linux machine, WSL2 or Docker Desktop), and an API key from it with the `datasource` role. In PowerShell, with Python 3.10 or newer:

```powershell
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface
cd esp32c5-kismet-wifi-interface
python -m pip install -r requirements.txt
python -m esp32c5_kismet.remote --list
$env:KISMET_CAP_APIKEY = "3F9A6C1E07B24D58A1C9E2F4608B7D35"
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5-COM14
```

Change `192.168.1.50` to the Kismet machine's address (`127.0.0.1` for Kismet in WSL2 or Docker Desktop on the same PC; [Guide: Windows boards to a Pi](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Guide-Windows-Boards-to-a-Pi) feeds a Pi across the network), `3F9A6C1E07B24D58A1C9E2F4608B7D35` to your key, and `COM14` to the port `--list` shows. The key goes in an environment variable to keep it off the helper's command line, which Task Manager can show. A Kismet login works too; [Install on Windows](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Install-on-Windows) shows both. Add a `--source` for each board: `esp32c5zigbee-COM15` or `esp32c5btle-COM15` for the other radios. Stop the helper with Ctrl+C. [Remote capture](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Remote-Capture) shows how to make the key.

## Documentation

The [wiki](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki) covers installation on each platform, every feature and step-by-step guides. Good places to start:

- [Choosing a setup](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Choosing-a-Setup) and [Hardware](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Hardware)
- [Flashing the firmware](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Flashing-the-Firmware)
- [Try it without hardware](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Try-It-Without-Hardware) and [First capture](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Guide-First-Capture)
- [Building Kismet with ESP32-C5 support](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Building-Kismet-with-ESP32-C5-Support)
- [Source definitions](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Source-Definitions), [Channel control](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Channel-Control) and [Remote capture](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Remote-Capture)
- [How it works](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/How-It-Works), the [FAQ](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/FAQ) and [Troubleshooting](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Troubleshooting)

The wiki's source lives in [`docs/wiki/`](docs/wiki) in this repository; changes to the documentation go there.

## What is in here

| Path | What it is |
|---|---|
| [`firmware/`](firmware) | ESP-IDF 5.5 project for the board: one radio per boot, a line protocol over the native USB port |
| [`kismet/`](kismet) | The Kismet side, GPL-2.0-or-later: `datasource_esp32c5.h` (the `esp32c5` source type for the server), `capture_esp32c5/` (the C helper `kismet_cap_esp32c5`), and `add-to-kismet.sh`, which adds both to a Kismet source tree and fixes seven upstream bugs in Kismet's capture framework |
| [`esp32c5_kismet/`](esp32c5_kismet) | The Python remote helper, `python -m esp32c5_kismet.remote`, for boards on Windows or any other OS with Python |
| [`docker/`](docker), [`compose.yaml`](compose.yaml) | The Docker image (Kismet with the C helper, and a demo target with the fake board) and its Compose file |
| [`tools/fake_board.py`](tools/fake_board.py) | A fake board on a POSIX pseudo-terminal, for trying things without hardware |
| [`tests/`](tests) | Offline tests of the Python remote helper, a C test harness for the C helper, Kismet end-to-end tests for both helpers with the fake board, and a Docker smoke test |
| [`docs/wiki/`](docs/wiki) | The source of the wiki |
| [`.github/workflows/docker.yml`](.github/workflows/docker.yml) | CI: builds and tests the image for amd64 and arm64, and publishes it to `ghcr.io/oshri-almog/esp32c5-kismet` for version tags and manual runs (none yet) |
| [`requirements.txt`](requirements.txt) | The Python packages the remote helper needs |

## Requirements

- **Boards:** ESP32-C5 boards connected by their native USB port (USB-Serial-JTAG, USB ID `303a:1001`), with at least 2 MB of flash. For several boards, a powered USB hub.
- **Kismet server:** Linux. Either Kismet built from source at commit `cfe427074` with `kismet/add-to-kismet.sh` applied (needs `autoconf`, `automake` and `python3` besides Kismet's own build dependencies, and about 1.5 GB of memory per compile job), or Docker on amd64 or arm64 (a 64-bit OS on a Raspberry Pi).
- **Python remote helper:** Python 3.10 or newer, with `pyserial>=3.5`, `msgpack>=1.0` and `websocket-client>=1.9.1` from [`requirements.txt`](requirements.txt). The helper has run with real boards on Python 3.13 (3.13.2 on Windows 11, 3.13.5 on the Pi), and its tests also on 3.12.3; an earlier version of it also passed its tests and captured on the Pi on 3.10, 3.11 and 3.12. On Debian and Ubuntu, install the packages with pip into a virtual environment: the distributions' websocket-client is older than this.
- **Firmware build:** [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/release-v5.5/esp32c5/get-started/index.html) 5.5 (the firmware was built with 5.5.5). <!-- VERIFY: the Espressif release-v5.5 get-started link resolves for the ESP32-C5 (the same link as on Flashing-the-Firmware) -->

## Known limitations

- **One radio and one channel at a time per board.** Use several boards to watch several radios or channels at once.
- **Not in a Kismet release yet.** Kismet has to be built from source with the patch, or run from the Docker image.
- **Kismet does not run on Windows**, and Docker Desktop cannot see USB boards by itself. On Windows the tested route is the Python remote helper, feeding a Kismet in WSL2, in Docker Desktop or on another machine such as a Raspberry Pi; attaching boards to WSL with usbipd has not been tried.
- **Bluetooth LE is advertising only**, and legacy advertising at that: no connections, no BLE 5 extended advertising, and no Bluetooth Classic. Every BLE packet is reported on channel 37, and Kismet counts repeated advertisements as duplicates, so per-device packet counts stay low.
- **Throughput.** The USB link carries a few hundred kB/s (the firmware's estimate, not measured). On a busy channel the board drops whole frames, and its drop counters are only on its UART log.
- **Wi-Fi metadata** is channel, frequency, signal and noise; no data rate, MCS or bandwidth. Frames with a bad checksum are not captured.
- **Every Espressif chip on native USB has the same USB ID.** With other ESP32 boards plugged in, name the board's port in the source definition.
- **macOS and the BSDs are untested.** The C helper finds boards by itself only on Linux; elsewhere you name the port.
- **A board that was on 802.15.4, mainly one flashed while on it, can come up deaf to Wi-Fi**: its source says it is capturing, but no packet arrives. A reset does not clear it; switching the board to BLE and back does, for example by running a BLE source on it once and then the Wi-Fi source again. To avoid it, run a Wi-Fi source on a board before you flash it.
- **A radio switch can hang a board.** On the test Pi one board sometimes stopped answering after a radio switch, mostly at a Kismet start with sources for mixed radios, until it was reset with esptool or replugged; the cause is not known ([Troubleshooting](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Troubleshooting#a-board-stops-answering-after-a-radio-switch)).
- **Kismet's own limits.** Its kismetdb log stores frequency 0 for every 802.15.4 and BLE packet (the device records are right); a remote source closed in Kismet comes back when its helper reconnects, so stop the helper instead; and a BLE advertiser whose advertising data ends in zero padding never becomes a device. [Troubleshooting](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Troubleshooting) has these and more.

## Changes from the Wireshark project's firmware

The firmware started as that of [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) (its release 1.2.0), and the board speaks the same line protocol in both projects. The changes made here:

- **Bluetooth LE CRC.** The firmware computes each advertising packet's CRC and marks it "CRC checked" and "CRC valid". Kismet drops BLE packets whose CRC it cannot trust; the helpers repair packets from the older firmware, which leaves the CRC zeroed.
- **Longer command lines:** up to 255 characters, from 63.
- **All 42 Wi-Fi channels fit in one list.** The list held 39, so a full range lost channels 169, 173 and 177.
- **A channel list that does not fit is refused**, instead of being cut short without a word.

The serial stream code of the Python remote helper, `esp32c5_kismet/board.py`, started as that project's `host/sniffer.py`.

## Licence and credits

MIT, see [LICENSE](LICENSE), except the [`kismet/`](kismet) directory, which is GPL-2.0-or-later because it is written to become part of Kismet and links against Kismet's capture framework; see [`kismet/COPYING.md`](kismet/COPYING.md). The Docker image contains Kismet and is GPL-2.0-or-later too.

Built on [Kismet](https://www.kismetwireless.net/docs/readme/intro/kismet/) by Mike Kershaw (dragorn) and contributors, and on Espressif's ESP-IDF. Prior art and everything this project stands on are in [CREDITS.md](CREDITS.md).

Only capture on networks and devices you own or are authorised to test.
