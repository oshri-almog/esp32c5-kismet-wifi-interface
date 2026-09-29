Short answers to the questions people ask first, with links to the pages that go into detail. If something is not working, [Troubleshooting](Troubleshooting) is the better place to start.

## Which boards work?

Any ESP32-C5 board that you connect by its native USB port (the chip's USB-Serial-JTAG port, USB ID `303a:1001`) and that has at least 2 MB of flash. The firmware is built for the ESP32-C5 only; other ESP32 chips will not run it.

The project was tested with four ESP32-C5 boards (chip revision v1.0, 8 MB flash) on a powered USB hub. Use a **powered** hub for several boards: an unpowered one browns out and produces failures that look like firmware bugs. [Hardware](Hardware) has the details.

## Why use these boards instead of a Wi-Fi adapter?

They do different things, and a monitor-mode Wi-Fi adapter on Linux remains Kismet's usual Wi-Fi source. What an ESP32-C5 board adds:

- **More than Wi-Fi.** The same board captures 2.4 and 5 GHz Wi-Fi, IEEE 802.15.4 (Zigbee, Thread) or Bluetooth LE advertising, one at a time.
- **No monitor-mode driver.** The board needs only a serial port, which is why boards plugged into a Windows PC can feed Kismet.
- **Several small radios.** Each board is its own source, so a few boards can cover a few channels at once.

What it does not do: it listens on one channel at a time, its USB link carries an estimated few hundred kB/s, its radiotap header has no rate or MCS fields, and it never transmits Wi-Fi frames, so it is no use for anything that needs injection. See the performance question below.

## Can one board capture Wi-Fi, Zigbee and BLE at the same time?

No. A board listens with one radio at a time. Switching radio reboots the board, which takes about 0.5 s; the helpers do it for you when a source asks for a different radio than the board is on. On the Raspberry Pi, a source that had to switch the board's radio was capturing about 1.5 s after Kismet launched it, against 1 to 1.5 s when the board was already on that radio (the helpers always set the radio and wait 0.8 s before they start). One of the four test boards now and then hung in a switch from Wi-Fi to BLE until it was reset or unplugged and plugged back in (twice in the recorded runs, of about a dozen such switches on that board); see [Troubleshooting](Troubleshooting). While a source uses a board, the board's port is locked, and a second source on it fails with "already in use by another capture".

To watch all three at once, use three boards. The radio is fixed per boot because switching radios at runtime left boards deaf to Wi-Fi until they were unplugged. [How It Works](How-It-Works) explains this.

## How many boards can I use?

Each board is a source of its own and needs a USB port; the project sets no limit. Put several boards on a **powered** hub. Boards on the same radio share Kismet's channel list: each hops the whole list from a different starting point, so they are not on the same channel at once. Kismet opens more than 16 sources in groups, 10 s apart.

Tested so far: four boards attached to a Raspberry Pi 4, all four capturing at once (two on Wi-Fi, one on 802.15.4, one on BLE; the 802.15.4 source received nothing, as no Zigbee or Thread traffic was nearby): as local sources of the C helper, through four remote C helpers, through one Python remote helper process, which ran them for 10 minutes without an error, and in the Docker image. These runs used the helpers from before their last round of changes; a repeat with the current ones is still to be done. See [Multiple Boards](Multiple-Boards).

## Which Raspberry Pi do I need?

Tested: a Raspberry Pi 4 with 8 GB, on 64-bit Debian 13. Compiling Kismet is what needs memory, about 1.5 GB per parallel job: `make -j2` on a 4 GB Pi, `make -j1` with swap on a 2 GB one (derived from the measured peaks, not tested). There is no 32-bit image, and the Pi 5 has not been tried. Running Kismet needs far less than building it. See [Install on Raspberry Pi](Install-on-Raspberry-Pi).

## Does it work on Windows?

The boards do; Kismet does not run on Windows. Plug the boards into the Windows PC and run the Python remote helper there. It feeds a Kismet server in WSL2, in Docker Desktop, on a Raspberry Pi or on any Linux machine. This was tested on Windows 11 with boards on COM ports, feeding Kismet in WSL2 and in Docker Desktop, with an earlier version of the helper; the current one has passed its tests on Windows, but has not yet run there with a real board.

Docker Desktop cannot see USB boards by itself, so the boards cannot go into a container directly on Windows. Attaching them to WSL with usbipd might make that possible, but it has not been tried. See [Install on Windows](Install-on-Windows).

## Does it work on macOS or the BSDs?

Not tested. The C helper knows the port names of macOS (`/dev/cu.usbmodem1101`) and the BSDs (`/dev/cuaU0`, `/dev/dtyU0`), but it has never been compiled there, and finding boards by itself needs Linux, so you name the port. The Python remote helper uses pyserial, which should find boards on macOS, but that has not been run either. See [Install on macOS and BSD](Install-on-macOS-and-BSD).

## Do I need root?

No. The helper needs read and write access to the board's serial port, nothing else. On the Raspberry Pi, Kismet was built and installed into the user's home directory without `sudo` (only installing the build packages needed it), and ran as that user, who was in the `dialout` group that owns `/dev/ttyACM*`. On Debian, Ubuntu and Raspberry Pi OS, add yourself to that group if you are not in it; the install pages show how (the test Pi's user was in it already, so that step was not needed there). The Docker image runs as root inside its container. Even run as root, the C helper drops every capability before it does anything else, when it was built with libcap (`libcap-dev`), as the install pages and the Docker image build it.

## Does the board transmit anything?

Not unless you ask it to. On Wi-Fi it runs in promiscuous mode with neither a station nor an access point: no beacons, no probe requests, no association. On Bluetooth it runs a passive scan and never advertises, connects or pairs. On 802.15.4 it receives in promiscuous mode and is not a coordinator. <!-- VERIFY: whether ESP-IDF's 802.15.4 driver sends an automatic ACK for a frame that requests one while the firmware listens in promiscuous mode (firmware sets promiscuous on, coordinator off: esp32c5_sniffer.c sniffer_154_init); no test looked for ACKs on air -->

The one exception is the firmware's `TXTEST` command, which sends 802.15.4 test frames so a second board can prove its receive path works. It only works in 802.15.4 mode, you have to send it to the board yourself over its serial port, and neither helper ever sends it. See [Firmware Protocol](Firmware-Protocol).

## Can it capture Bluetooth LE connections?

No, only advertising: beacons, trackers, and whatever a device broadcasts before anyone connects to it. Once two devices connect and move to the data channels, they disappear from the capture. The ESP32-C5 has no promiscuous mode for Bluetooth, only a passive scan. Only legacy advertising is captured, not BLE 5 extended advertising: the firmware is built without extended scanning and drops any report with more than 31 bytes of advertising data. The test captures held no extended advertising, though no device known to use it was nearby.

To follow connections you need hardware that hops with them, such as an nRF52840 running Nordic's nRF Sniffer. See [Bluetooth LE Capture](Bluetooth-LE-Capture).

## What about Bluetooth Classic?

No. The ESP32-C5 has no Bluetooth Classic (BR/EDR) radio at all, only Bluetooth LE.

## Why does every BLE device show channel 37, with only a few packets?

The ESP32-C5 scans advertising channels 37, 38 and 39 together and does not say which one a packet came on, so every packet is recorded as channel 37. And a device repeats the same advertisement over and over; Kismet treats an identical repeat as a duplicate packet, so a device's packet count and last-seen time stop moving after its first few packets, while the source's own packet count keeps rising. In one minute of a test run, 1094 of 1099 BLE packets were duplicates. This is expected. See [Bluetooth LE Capture](Bluetooth-LE-Capture).

## Are these the same boards as the Wireshark project?

Yes. [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) uses the same boards and the same line protocol, and its firmware is where this project's firmware came from. A board flashed with this project's firmware should work in the Wireshark project too (same protocol; not yet tried). The other way round depends on the firmware version:

| Firmware on the board | Wi-Fi | Zigbee and Thread | Bluetooth LE |
|---|---|---|---|
| This project's | Yes | Yes | Yes |
| Wireshark project 1.2.0 (its browser flasher) | Yes | Yes | Yes: the helpers fill in the BLE CRC and the flags that firmware leaves clear, and say so once |
| Wireshark project 1.1.0 | Yes | Yes | No: it ignores the switch to BLE |
| Wireshark project 1.0.0 | Not shown: the one run was on a board that had been on 802.15.4 when it was flashed (see below) | No | No |

Each row was tried on one of the test boards, flashed with that version's published image. On 1.2.0 it captured all three radios under both helpers, and every BLE packet reached Kismet repaired. On 1.1.0 a BLE source never started capturing: the board stayed on Wi-Fi, and the helpers gave up every 15 s and tried again. On 1.0.0 a Wi-Fi source said it was capturing but got no packets at all, before and after a reset. That board had been on 802.15.4 when 1.0.0 was flashed onto it, the case that leaves a board deaf to Wi-Fi ([Troubleshooting](Troubleshooting#a-board-that-ran-zigbee-captures-no-wi-fi)), and the cure, a switch to Bluetooth LE and back, does not exist on 1.0.0, so the run did not settle whether 1.0.0 captures Wi-Fi. The same board captured Wi-Fi on 1.1.0 and 1.2.0. These runs used earlier versions of the helpers. <!-- VERIFY: 1.0.0 Wi-Fi on a board flashed from Wi-Fi mode (the only run, hw2 o100, flashed it onto a board left in 802.15.4 mode by the 1.1.0 zigbee run) -->

Before they were reflashed, the four test boards all ran a build with the same version and build time as 1.2.0. Two of them answered `START`; the other two streamed Wi-Fi but did not answer it within 3 s, so a helper would never have got in sync with them. The published 1.2.0 image, flashed onto a board, answered `START` at once every time, so the cause lies elsewhere and was not found. A board that behaves like that needs this project's firmware, as the last paragraph of this answer says.

This project has no prebuilt firmware image or browser flasher of its own yet, so the Wireshark project's [browser flasher](https://oshri-almog.github.io/esp32c5-wireshark-sniffer/) is a way to get a board going without ESP-IDF. The other differences of its 1.2.0 firmware do not matter under Kismet: it takes command lines of up to 63 characters instead of 255, and a channel list of up to 39 channels instead of 42, but the helpers send one short `CHANNELS` line per hop. On 1.0.0 or 1.1.0, flash the whole image (the merged image at 0x0, or `idf.py flash`), not only the app, because the partition table changed.

Flash this project's firmware when you can, and always when a board streams but never gets in sync with the helper; [Flashing the Firmware](Flashing-the-Firmware) shows how.

## Is this part of Kismet?

Not yet. No Kismet release includes the `esp32c5` source, so you build Kismet from source at commit `cfe427074` with this project's `add-to-kismet.sh` applied, or use the Docker image, which does that for you. The Kismet side, in the `kismet/` directory, is GPL-2.0-or-later and written to become part of Kismet. See [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).

A stock Kismet refuses these sources, local or remote: the source type has to be compiled into the Kismet server. [How It Works](How-It-Works) explains why.

## How fast is it, and what are the limits?

- **One channel at a time per board.** At Kismet's default of 5 hops a second, a pass over all 42 Wi-Fi channels takes about 8.4 s, and a hopping board spends about one forty-second of its time on any one channel. Lock a channel, or add boards, to see more of one channel. See [Channel Control](Channel-Control).
- **The USB link.** The board's USB-Serial-JTAG link carries a few hundred kB/s (the firmware's own estimate; it has not been measured here). On a busy channel the board drops whole frames rather than block, so the stream stays valid, but the drop counters are only on the board's UART log; Kismet cannot see them.
- **What was measured.** A Wi-Fi board locked on channel 6 delivered 410 to 778 frames in 8 s. Two Wi-Fi boards hopping all 42 channels for four minutes on a Raspberry Pi 4 gave 8,801 and 10,242 packets and 244 Wi-Fi devices between them. Your numbers depend on how busy the air is around you.
- **Wi-Fi detail.** Each frame carries channel, frequency, signal and noise, but no data rate, MCS or bandwidth. Frames with a bad checksum are dropped on the board and never reach Kismet.
- **Remote capture start-up.** On the Pi, the first packet reached Kismet about 1.2 s after the C helper was started with `--connect` over the websocket (1.2 to 1.4 s) and about 1.6 s over the legacy TCP port (1.2 to 1.6 s), and 1.4 to 1.8 s after the Python remote helper was; packets then came every second. A C helper built before `add-to-kismet.sh` fixed Kismet's capture framework took 5 to 6 s over the websocket and then sent in bursts every 5 s. See [Remote Capture](Remote-Capture).

## Can I record where devices were seen?

Location comes from Kismet's own GPS support, which has not been tried with these boards; see [Kismet's documentation](https://www.kismetwireless.net/docs/readme/intro/kismet/). What relates to these boards:

- `metagps=<name>` in a source definition attaches a named GPS to that source ([Source Definitions](Source-Definitions)).
- The C helper, as a remote helper, takes `--fixed-gps <lat>,<lon>[,<alt>]` and `--gps-name <name>` for a board at a fixed place. These are options of Kismet's capture framework ([Command-Line Reference](Command-Line-Reference)), and have not been tried with these boards either. The Python remote helper has no GPS option.
- `kismetdb_to_kml`, `kismetdb_to_gpx` and `kismetdb_to_wiglecsv` turn a log with locations into maps and WiGLE files. `kismet --override wardrive` loads Kismet's wardriving settings, which add a WiGLE CSV log and stop tracking Wi-Fi devices other than access points.
