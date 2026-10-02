This guide takes one ESP32-C5 board from flashing to Wi-Fi devices in Kismet's web UI, on a Raspberry Pi or another Debian-style Linux machine, with a shorter section for a board on a Windows PC. It is for a first session: one board, the Wi-Fi radio, Kismet started by hand in a terminal.

The hands-on part takes about 15 minutes. Building Kismet adds about 78 minutes on a Raspberry Pi 4 (8 GB), but it runs unattended, and you do it once. If you would rather use the Docker image, see [The Docker variant](#the-docker-variant) at the end; for a board on Windows, see [Boards on a Windows PC](#boards-on-a-windows-pc).

> **Note:** Only capture on networks and devices you own or are authorised to test.

## What you need

| | |
|---|---|
| Board | One ESP32-C5 board, connected by its native USB port (USB ID `303a:1001`), and a USB cable that carries data |
| Computer | A Raspberry Pi 4 or 5 with a 64-bit OS, or a Linux PC. Tested: Raspberry Pi 4 (8 GB) on Debian 13 "trixie" arm64 |
| Network | Internet access for the downloads, and a second computer or phone on the same network for the web UI (or a desktop on the Pi itself) |
| Disk | Not measured. The installed `kismet` binary alone is about 490 MB, because it carries debug information |

More boards come later: [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey). No board at all: [Try It Without Hardware](Try-It-Without-Hardware).

## Step 1: Flash the board

Skip this step if the board already runs this project's firmware.

A board flashed from the [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) browser flasher (its firmware 1.2.0) speaks the same protocol, and a test board flashed with it captured on all three radios under both helpers; for Bluetooth LE the helper fills in a checksum field that firmware leaves empty, and says so once in Kismet's log. But two of the four test boards, which reported the same app version as that firmware, streamed Wi-Fi without answering the start request the helpers depend on; after reflashing with this project's image they worked. If your source never reaches `capturing` in step 5, come back here and flash.

The quickest way is the [web flasher](https://oshri-almog.github.io/esp32c5-kismet-wifi-interface/). It runs in Chrome or Edge 89 or newer on a desktop computer, which can be a PC rather than the Pi, and needs nothing installed:

1. Plug the board into that computer by its native USB port.
2. Open the flasher page and press **Install**.
3. Choose the board's port and press **Connect**.
4. Choose **Install ESP32-C5 Kismet firmware**. At **Erase device**, erase the whole flash or not, as you like: the board starts on Wi-Fi either way. Press **Next**, then **Install**.
5. Wait for **Installation complete!**, press **Next**, close the window, and move the board to the Pi.

[Flashing the Firmware](Flashing-the-Firmware#flash-from-the-browser) explains each step, and has every other method, backups included.

To flash with ESP-IDF instead, on the Pi or on a PC, from a shell where ESP-IDF 5.5 is set up (`export.sh`), with the board on `/dev/ttyACM0`:

```bash
git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface.git ~/esp32c5-kismet-wifi-interface
cd ~/esp32c5-kismet-wifi-interface/firmware
idf.py set-target esp32c5
idf.py -p /dev/ttyACM0 flash
```

Change `/dev/ttyACM0` to your board's port (`COM14` style on Windows, if you flash from a PC and move the board to the Pi afterwards).

No ESP-IDF on the Pi? Download the image the web flasher installs (`curl -fLO https://oshri-almog.github.io/esp32c5-kismet-wifi-interface/firmware/esp32c5-kismet-merged.bin`) or a release's image, a separate build of the same firmware with its own SHA-256 ([Download the merged image](Flashing-the-Firmware#download-the-merged-image)), or build the merged image on a computer that has ESP-IDF (`idf.py merge-bin -o esp32c5-kismet-merged.bin` in `firmware/`, which writes `firmware/build/esp32c5-kismet-merged.bin`) and copy that file to the Pi. Then write it with esptool from a Python virtual environment, as the test Pi did:

```bash
sudo apt-get install -y python3-venv
python3 -m venv ~/esp32c5-venv
~/esp32c5-venv/bin/pip install esptool
~/esp32c5-venv/bin/esptool --chip esp32c5 -p /dev/ttyACM0 write-flash 0x0 esp32c5-kismet-merged.bin
```

esptool ends with `Hash of data verified` and resets the board. Writing the merged image also resets the radio the board remembers, so it starts on Wi-Fi.

> **Note:** A board that was in 802.15.4 (Zigbee) mode when it was flashed can come up deaf on Wi-Fi: Kismet then shows `capturing (wifi)` and a packet count that stays at 0, with no error. A reset does not cure it; switching the board to Bluetooth LE and back does, for example by running a BTLE source on it once (`esp32c5btle-ttyACM0`, see [Guide: BLE Advertising Survey](Guide-BLE-Advertising-Survey)) and then the Wi-Fi source again. To avoid it, run a Wi-Fi source on a board that last used 802.15.4 until it says `capturing`, before you flash it. [Flashing the Firmware](Flashing-the-Firmware) has the details.

On the Pi, `idf.py` and esptool open the board's port like any other program. If either stops with `Permission denied` on `/dev/ttyACM0`, your user is not in the `dialout` group yet: do item 3 of step 2 first, then flash again.

> **Note:** Some boards stay in download mode after flashing and never start the new firmware. Unplug the board and plug it back in, or press its BOOT button once.

## Step 2: Plug the board in and find it

1. Plug the board into the Pi. For more than one board, use a powered USB hub (see [Hardware](Hardware)).
2. List the stable names udev gives the boards:

   ```bash
   ls -l /dev/serial/by-id/
   ```

   A board looks like this; the part after `unit_` is its MAC, which it reports as its USB serial number:

   ```text
   usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00 -> ../../ttyACM0
   ```

3. Check that you can open the port:

   ```bash
   ls -l /dev/ttyACM0
   id
   ```

   The port should belong to group `dialout`, and `id` should list `dialout`. If it does not, add yourself and log out and in again:

   ```bash
   sudo usermod -aG dialout $USER
   ```

   <!-- VERIFY: usermod plus a new login on a fresh image; the test Pi's user was already in dialout -->

Every Espressif chip on its native USB port has the USB ID `303a:1001`, so another ESP32 board plugged into the same machine looks the same. Name the port in step 5, as shown, and it does not matter.

## Step 3: Build Kismet with the ESP32-C5 source

No Kismet release contains this source yet, so Kismet is built from source at the commit it was tested against, with the project's `add-to-kismet.sh` applied. [Install on Raspberry Pi](Install-on-Raspberry-Pi) explains each command; this is the sequence the test Pi ran.

1. Install the build packages:

   ```bash
   sudo apt-get update
   sudo apt-get install -y build-essential git pkg-config autoconf automake python3 \
       libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev \
       libnm-dev libdw-dev libsqlite3-dev libsensors-dev libusb-1.0-0-dev libmosquitto-dev \
       libpcre2-dev libssl-dev
   ```

   <!-- VERIFY: this list on a freshly installed Debian 13 / Raspberry Pi OS image; the test Pi may have had some packages already -->

2. Get Kismet at the tested commit:

   ```bash
   git clone https://github.com/kismetwireless/kismet.git ~/src/kismet
   git -C ~/src/kismet checkout cfe427074
   ```

   Only if this machine has no copy of the project yet, because step 1 ran on another machine or you skipped it, get the project too:

   ```bash
   git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface.git ~/esp32c5-kismet-wifi-interface
   ```

3. Add the ESP32-C5 source and configure:

   ```bash
   sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
   cd ~/src/kismet
   ./configure --prefix=$HOME/kismet-install --disable-python-tools --disable-librtlsdr \
       --disable-ubertooth --disable-bladerf --disable-btgeiger
   ```

   The summary at the end must show `ESP32-C5: yes` and `Websocket datasources: yes`.

4. Compile in the background, so it keeps going if your SSH session drops:

   ```bash
   nohup nice make -j4 > ~/kismet-build.log 2>&1 &
   tail -f ~/kismet-build.log
   ```

   Ctrl+C stops `tail`, not the build. This took about 78 minutes on the test Pi 4 (8 GB). On a Pi with 4 GB use `-j2`, with 2 GB `-j1`. <!-- VERIFY: -j2 / -j1 guidance is derived from the measured memory peaks, not tested --> When `pgrep -x make` prints nothing, the build has ended; run `cd ~/src/kismet` and then `make` once more in the foreground: it returns at once if everything was built, and shows the error otherwise. The `cd` matters if your SSH session dropped, because a new session starts in your home directory.

5. Install into your home directory (no sudo needed):

   ```bash
   cd ~/src/kismet
   make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
   ~/kismet-install/bin/kismet --version
   ```

   The version line reads like `Kismet 2026.09.0-cfe427074`, and the command exits with status 1. That is normal for Kismet.

## Step 4: Set the web login

Kismet's web UI listens on port 2501 on every network interface. Until a login exists, the first person who opens it chooses the admin user and password. Set one before the first start:

```bash
mkdir -p ~/.kismet
printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > ~/.kismet/kismet_httpd.conf
chmod 600 ~/.kismet/kismet_httpd.conf
```

Change `admin` and the password. Kismet reads this file from the home directory of the user it runs as, so start Kismet as yourself, not with `sudo`. The board needs no root.

If you skip this step, Kismet logs "This is the first time Kismet has been run as this user", and the web UI asks the first visitor to choose the admin user and password, in a **Set Login** dialog. Open it yourself straight away, before anyone else on the network does.

## Step 5: Start Kismet with the board

Kismet writes its log file into the directory it starts in, so give it one:

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi'
```

Change `ttyACM0` to your board's port. The `-c` option adds one source; its definition names the board's port, the radio (`mode=wifi`) and the name Kismet shows (`name=c5-wifi`). [Source Definitions](Source-Definitions) has every form, including the `/dev/serial/by-id/` one that survives renumbered ports.

Among the startup lines, look for these three:

```text
INFO: Found type 'esp32c5' for 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi'
INFO: Data source 'esp32c5-ttyACM0:mode=wifi,name=c5-wifi' launched successfully
INFO: c5-wifi capturing (wifi)
```

`capturing` means the board is streaming to Kismet. On the test Pi that came 1 to 1.5 s after launch for a board already on Wi-Fi, and about 1.5 s for a board that had last used another radio. The helper always sends the radio first and waits 0.8 s before it starts the stream, so even a board already on Wi-Fi takes about a second.

Two lines look alarming and are not:

- `ERROR: Tried to re-register duplicate alert FLIPPERZERO` appears at every start of this Kismet version.
- `ALERT: ROOTUSER` appears only if you started Kismet as root, which you do not need to.

## Step 6: Open the web UI

1. On the Pi, print its address with `hostname -I`.
2. On another computer, open `http://192.168.1.50:2501`, with the Pi's address in place of `192.168.1.50`. On the Pi's own desktop, `http://localhost:2501` works too.
3. Log in with the user and password from step 4.
4. Open **Data Sources** in the sidebar. The source `c5-wifi` is listed as running, and its packet count climbs.

## Step 7: See Wi-Fi devices

The device list fills within seconds. Kismet hops the board across all 42 Wi-Fi channels the firmware can tune to, 14 at 2.4 GHz and 28 at 5 GHz, five channels a second by default, so one full pass takes about 8.4 s. <!-- VERIFY: that the board's radio really receives on 169, 173 and 177: Kismet's hop list sends them to the board (seen on the Pi), but no traffic on them was ever seen, and whether the radio tunes there was not checked --> Access points on both bands appear as the board passes their channels.

What to expect, from the Pi tests:

| Measurement | Result |
|---|---|
| Kismet start to first packets | 2.2 to 3.7 s across runs, for two boards on Wi-Fi |
| One board hopping for 60 s (an earlier build of the C helper in remote mode, same Pi) | 100 Wi-Fi devices, 15 of them on 5 GHz channels 36, 40, 48 and 100 |

Device counts depend on the networks around you: in later 60 s runs on the same Pi, two Wi-Fi boards together found 47 to 53 Wi-Fi devices.

Two things that look wrong but are not:

- The source's channel shows `6` the whole time. The helper hops the board itself, and Kismet keeps the start channel in that field while the board moves; the channel of each packet and device is the real one.
- One board sees one channel at a time. It catches a busy access point quickly, and a quiet client on a channel it visits for 200 ms every 8.4 s much later. More boards help: [Multiple Boards](Multiple-Boards).

To check from the terminal instead, ask Kismet's REST API for its sources (in a second terminal on the Pi):

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/datasource/all_sources.json \
  | python3 -c 'import json,sys; [print(s["kismet.datasource.name"], s["kismet.datasource.running"], s["kismet.datasource.num_packets"]) for s in json.load(sys.stdin)]'
```

It prints each source's name, `1` when it is running, and its packet count, for example `c5-wifi 1 298`.

## Step 8: Stop

Press Ctrl+C in the terminal where Kismet runs. Kismet closes the source, which releases the board's port, and ends with `Kismet exiting.`

The capture stays in `~/kismet-logs`, in a file named like `Kismet-20260928-14-03-22-1.kismet`. The date and time in the name are UTC. The file is an SQLite database that holds the packets and the devices; [Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark) turns it into a pcapng file.

## If something goes wrong

| What you see | What to do |
|---|---|
| `cannot open /dev/ttyACM0: Permission denied` | Add yourself to `dialout` (step 2), then log out and in |
| `/dev/ttyACM0 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time` | Another program holds the port: another Kismet or esp32c5 source, the Python remote helper, the C helper in remote mode, esptool, or a serial terminal such as picocom, pyserial's miniterm or screen. Close it. screen can leave a detached session holding the port after its window is gone: `screen -ls` lists it. minicom takes no lock, so it does not cause this message: the capture opens the board anyway, and the capture breaks. Close any terminal on the board |
| `cannot open /dev/ttyACM0: No such file or directory`, retried every 5 s | The board is not on that port. Check `ls /dev/serial/by-id/` and use the right name |
| `Unable to find driver for '...'` | Either the definition is wrong in itself (a typo in the name, a bad `mode=` or `channel=`), or this Kismet cannot run the ESP32-C5 source. Add `type=esp32c5` to the definition: Kismet then shows the helper's real reason. If Kismet then stops at start with the `kis_external` exception below, the helper is missing (the definition is fine); if it says `Unable to find datasource for 'esp32c5'`, this Kismet has no ESP32-C5 source |
| `Unable to find datasource for 'esp32c5'` | This Kismet has no ESP32-C5 source type: it was built without `add-to-kismet.sh`, or you started another Kismet, such as a distribution package's. Start `~/kismet-install/bin/kismet`, and check that the configure summary in step 3 showed `ESP32-C5: yes` |
| Kismet stops at start with `Uncaught exception "kis_external tried to write with no io handler"` and a stack trace | A source with `type=esp32c5` while the C helper is missing: this Kismet version crashes instead of saying so. Check for `kismet_cap_esp32c5` in `~/kismet-install/bin`, and run `make install` from step 3 again |
| `c5-wifi: no capture from the board on /dev/ttyACM0 for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` in Kismet's log, and Kismet tries again 5 s later. Kismet records only `IPC connection closed` as the source's error, so look for the reason in the log | Replug the board (it may be stuck in download mode), or flash it again (step 1) |
| `Unable to open KismetDB log at ...` and Kismet exits | Start Kismet in a directory you can write to, as in step 5 |

[Troubleshooting](Troubleshooting) has the rest.

## Boards on a Windows PC

Kismet does not run on Windows. The tested way is Kismet in Docker Desktop on the same PC, fed by the Python remote helper, which opens the board on its COM port. [Install with Docker](Install-with-Docker#kismet-in-docker-desktop-boards-through-the-python-remote-helper) has each step in full, and [Install on WSL2](Install-on-WSL2) does the same with Kismet in WSL2. You need Docker Desktop, Git, Chrome or Edge for flashing (or ESP-IDF 5.5), and Python 3.10 or newer.

1. In PowerShell, get the project, install the helper's packages and list the boards. The list shows each board's COM port and MAC:

   ```powershell
   git clone https://github.com/oshri-almog/esp32c5-kismet-wifi-interface
   cd esp32c5-kismet-wifi-interface
   python -m pip install -r requirements.txt
   python -m esp32c5_kismet.remote --list
   ```

2. Flash the board with the [web flasher](https://oshri-almog.github.io/esp32c5-kismet-wifi-interface/) in Chrome or Edge, as in step 1, choosing the board's COM port from the list above. Or flash it from an "ESP-IDF 5.5 PowerShell" window, in the project's `firmware` folder, with its COM port. Change `COM14` to yours:

   ```powershell
   idf.py set-target esp32c5
   idf.py -p COM14 flash
   ```

3. Back in the project folder, start Kismet from the published image, with its web port on this PC only. Change the password. The first run downloads the image, about 48 MB:

   ```powershell
   docker run -d --name esp32c5-kismet -p 127.0.0.1:2501:2501 -e KISMET_USER=admin -e KISMET_PASSWORD=choose-a-long-password -e ESP32C5_WAIT=0 -v kismet-data:/data -v kismet-home:/root/.kismet ghcr.io/oshri-almog/esp32c5-kismet:latest
   ```

   On the test PC, with the image already pulled, this command (with another password) had Kismet answering in 1.4 s, with the no-board message. To run an image you build yourself instead, build it with `docker build -f docker/Dockerfile -t esp32c5-kismet .` (18.5 minutes on the test PC) and write `esp32c5-kismet` in place of `ghcr.io/oshri-almog/esp32c5-kismet:latest`.

4. Open `http://127.0.0.1:2501`, log in, and create an API key under **Settings**, then **API Keys**, then **Create API Key**, with the role **datasource**. <!-- VERIFY: creating a datasource key in the web UI (read from the UI code, not tried) --> Or create it from PowerShell; it prints the key, 32 hex characters:

   ```powershell
   curl.exe -u admin:choose-a-long-password --data-urlencode 'json={\"name\": \"windows-helper\", \"role\": \"datasource\", \"duration\": 0}' http://127.0.0.1:2501/auth/apikey/generate.cmd
   ```

5. In the project folder, start the helper with the key. Change the key and `COM14` to yours:

   ```powershell
   $env:KISMET_CAP_APIKEY = "3F9A6C1E07B24D58A1C9E2F4608B7D35"
   python -m esp32c5_kismet.remote --connect 127.0.0.1:2501 --source esp32c5-COM14:name=c5-wifi
   ```

6. **Data Sources** lists `c5-wifi` as a remote source, and devices appear as in step 7. Stop the helper with Ctrl+C, and Kismet with `docker stop esp32c5-kismet`.

What the Windows test saw, with an earlier image and helper and a Kismet login instead of a key: 6249 packets in about 2.5 minutes and 128 Wi-Fi devices, 11 of them on 5 GHz, with 0 error packets. On 2026-10-02, steps 4 and 5 ran again with a real board, against Kismet on a Raspberry Pi 4 instead of Docker Desktop: the `curl.exe` line printed a key, and the helper captured 18,488 packets and 41 Wi-Fi devices in 90 s. <!-- VERIFY: steps 5 and 6 with a real board against the published image in Docker Desktop; step 3 and the curl.exe line of step 4 ran with the published image on 2026-10-02, without a board (the first figures above are from an earlier image and helper) -->

With Kismet on a Raspberry Pi instead, and the boards on the PC, follow [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi).

## The Docker variant

The Docker image holds Kismet with the ESP32-C5 source already built, so the build step becomes a pull or an image build. [Install with Docker](Install-with-Docker) has the details; in short, from the project folder:

```bash
cd ~/esp32c5-kismet-wifi-interface
sudo docker compose up -d
sudo docker compose logs kismet | grep "web login"
```

The `kismet` service starts one Wi-Fi source per board it finds, and if you set no `KISMET_USER` and `KISMET_PASSWORD`, it makes up a login and prints it once, which the last command finds: `[esp32c5-kismet] no web login was set, so Kismet's is now: user admin, password <24 hex digits>`. Then open `http://192.168.1.50:2501` as in step 6. The logs go to the `kismet-data` volume. `sudo docker compose down` stops it and keeps the volumes.

Differences from the native route:

- `docker compose up` downloads the published arm64 image, about 48 MB, instead of compiling Kismet on the Pi; building the image there took about 80 minutes on the test Pi 4 (8 GB). <!-- VERIFY: the published image pulls on a Pi 4 (its arm64 image is on ghcr.io, but has not been pulled there with Docker yet) -->
- Debian's `docker.io` package does not include Compose; [Install with Docker](Install-with-Docker) says what to install, or use the plain `docker run` command on [Install on Raspberry Pi](Install-on-Raspberry-Pi).
- On the test Pi, four real boards captured in the container with the current image, found by themselves and named by their `/dev/serial/by-id/` links.

## Next steps

- [Wi-Fi Capture](Wi-Fi-Capture): what the board captures and what it leaves out.
- [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey): several boards covering both bands.
- [Guide: Zigbee and Thread Networks](Guide-Zigbee-and-Thread-Networks) and [Guide: BLE Advertising Survey](Guide-BLE-Advertising-Survey): the other two radios.
- [Guide: Running as a Service](Guide-Running-as-a-Service): start Kismet with the boards at boot.
