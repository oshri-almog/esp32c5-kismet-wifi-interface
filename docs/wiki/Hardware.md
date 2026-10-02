This page covers the hardware: which boards work, antennas, cables and hubs, how many boards one machine can take, how to tell boards apart, and what a board can and cannot capture with each radio. Read it before you buy boards or plug several into one machine.

## Boards

Any ESP32-C5 board works if its **native USB port** is wired to a USB connector. That port is the chip's own USB-Serial-JTAG interface, USB ID `303a:1001`. The firmware sends the capture stream over it and nothing else.

- **ESP32-C5 only.** The firmware is built for the `esp32c5` target and does not run on other ESP32 chips.
- **Flash: 2 MB or more.** The firmware's partition table lays out exactly 2 MB (the application partition ends at 2 MB), so any ESP32-C5 module with 2 MB or more works. The firmware image itself is about 1.1 MB. On a bigger flash the firmware uses the first 2 MB.
- **Boards with two USB connectors.** Many development boards have one connector for the native USB port and one marked "UART", which goes through a USB-to-serial chip to the chip's UART0. Plug into the **native USB** one. The UART connector carries only the firmware's log (115200 baud), which is useful for troubleshooting but carries no capture.
- **Boards with one USB-C connector**, such as the Seeed Studio XIAO ESP32C5, use it for the native USB port. To read the firmware's log on such a board you need a USB-to-serial adapter on UART0: TX is GPIO11, RX is GPIO12. <!-- VERIFY: which header pins GPIO11 and GPIO12 are on the XIAO ESP32C5 -->

### Boards that have been used

| Where | Boards | Flash | Connected through |
|---|---|---|---|
| This project's tests (Raspberry Pi 4, Windows 11) | Four ESP32-C5 boards; esptool reported them as ESP32-C5 revision v1.0 with 8 MB flash | 8 MB | A powered USB hub |
| The sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) | Four Seeed Studio XIAO ESP32C5, each with an external antenna on its u.FL connector | not recorded | A powered USB 3.0 hub |

<!-- VERIFY: whether this project's four test boards are the XIAO ESP32C5 boards from the sibling project's photo; the test logs record only the chip and flash size -->

The sibling project's web flasher page reports that two of the three boards it was developed against came up latched in download mode after flashing and did not run the new firmware until they were unplugged and plugged back in, or their BOOT button was pressed once. That is a quirk of those boards, not the firmware. [Flashing the Firmware](Flashing-the-Firmware) covers it.

## Antennas

A board has one antenna, and all three radios share it: Wi-Fi (both bands), 802.15.4 and Bluetooth LE. If your board has an antenna connector (u.FL, also called IPEX), fit an antenna rated for both 2.4 GHz and 5 GHz, or 5 GHz reception suffers; that is general radio practice.

This project has not compared antennas. Kismet shows the signal strength of every packet in dBm (from radiotap for Wi-Fi; for 802.15.4, from the board's TAP header, which the helper reads and passes on; from the pseudo-header for BLE), so you can compare two antennas on the same device yourself.

The boards only listen. The one exception is the 802.15.4 self-test command `TXTEST`, which transmits test frames when you send it ([Firmware Protocol](Firmware-Protocol)). Wi-Fi runs in receive-only promiscuous mode and never sends a beacon, probe or association; BLE runs a passive scan and never advertises or connects.

## USB cables and powered hubs

- **Use a known-good data cable.** A charge-only cable gives no serial port at all, and a poor one gives intermittent errors. A faulty cable and an unpowered hub cost the sibling project hours of confusing, intermittent failures.
- **Use a powered hub for several boards.** An unpowered hub browns out under four boards and produces failures that look like firmware bugs: random disconnects, ports renumbering, boards that stop answering. The four test boards on the Raspberry Pi 4 ran through a powered hub.
- **One board directly in a port** is fine without a hub.

If boards drop off the bus, check the kernel log before blaming the firmware. On Linux:

```bash
sudo dmesg | grep -i "usb disconnect"   # a board that left the bus
lsusb -d 303a:1001                      # the Espressif USB-Serial-JTAG devices present now
```

A board whose firmware hangs stays enumerated. A board missing from `lsusb` has left the bus: replug it, or power-cycle the hub. [Troubleshooting](Troubleshooting) has more.

> **Warning:** do not open a board's port with a serial terminal that uses default settings. On the native USB port the DTR and RTS lines drive the chip's reset and boot mode, and a terminal that raises them can reset the board or leave it in download mode. On Windows, an open with pyserial's defaults made two boards briefly vanish from the system. Both helpers open the port with DTR and RTS held low.

## How many boards per machine

Each board listens on one radio at a time, and with Wi-Fi or 802.15.4 on one channel at a time (BLE covers all three advertising channels at once). More boards give you more channels or more radios at once: for example two boards on Wi-Fi, one on Zigbee and one on BLE.

What has been run:

- **Raspberry Pi 4:** four boards on one powered hub. All four were backed up and flashed there, and all four were on the hub together, in 802.15.4 mode on one channel, for the cross-board `TXTEST` test. In Kismet all four ran at once, two on Wi-Fi, one on 802.15.4 and one on BLE, through either helper and in the Docker image, without errors apart from one board that sometimes hung when it changed radio at the same moment as others (see [below](#what-a-board-can-and-cannot-do-per-radio) and [Multiple Boards](Multiple-Boards)); the 802.15.4 source received nothing, as no Zigbee or Thread traffic was nearby; one Python remote helper process ran the four for 10 minutes without an error, at 2 to 5 % of the Pi's CPU. All four also ran on Wi-Fi together, sharing out the channels. The latest of these runs were on 2026-10-02, with this project's firmware (image 01a50bd6).
- **Windows 11:** two boards in one Python remote helper process.

No upper limit has been measured. What limits it:

- **USB bandwidth per board.** The native USB link carries a few hundred kB/s, by the firmware's own estimate; this project has not measured it. On a busy Wi-Fi channel a board drops whole frames rather than stall, so the stream stays valid, but some frames are lost. Its drop counters are reported only on the UART0 log.
- **Power.** Every board adds to the hub's load; see above.

Boards on the same radio do not duplicate each other's work: Kismet shares the channel list out among them. Each hops the whole list from a different starting point, so two Wi-Fi boards are never on the same channel at once. [Multiple Boards](Multiple-Boards) explains how, and how to give boards fixed channels instead.

## Telling boards apart

### The USB ID is not enough

`303a:1001` is Espressif's USB-Serial-JTAG ID, and every Espressif chip with a native USB port uses it: ESP32-C3, C5, C6, H2, S3, P4 and others. A host cannot tell an ESP32-C5 running this firmware from any other ESP32 on native USB by its USB ID. So when both helpers, or the Docker image, look for boards by themselves, they count every such device. With other ESP32 boards plugged in, name the port in each source definition.

### The MAC is the board's name

The chip's USB-Serial-JTAG port reports the board's MAC address as its USB serial number, on any ESP32 with native USB and whatever firmware it runs. On a test board it stayed the same with four different firmware images and in the chip's download mode. So the MAC tells boards apart, but, like the USB ID, it does not say what runs on them. Both helpers use it to recognise a board:

- The source UUID Kismet sees is `E5C5000M-0000-0000-0000-<MAC>`, where M is 1 for Wi-Fi, 2 for Zigbee and 3 for BLE, and the MAC is written in capitals without colons. For the board `F0:F5:BD:01:02:03`, the Wi-Fi source is `E5C50001-0000-0000-0000-F0F5BD010203`. A board keeps the same UUID for each radio across port names, reboots and reconnects.
- The hardware label Kismet records for the source is `Espressif USB-Serial-JTAG (<MAC>)`, the same from either helper. It names the USB device, not the chip, because the helper cannot know which chip it is.
- When a board comes back under another port name, the helpers look for it by MAC.

Write the last few digits of each board's MAC on the board itself; it saves guessing when several are plugged in.

### Port names

| OS | Port name | Stable name |
|---|---|---|
| Linux | `/dev/ttyACM0`, `/dev/ttyACM1`, … in the order the boards enumerate | `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<MAC>-if00`, made by udev |
| Windows | `COM14` and so on | Windows keeps giving a board the same COM number <!-- VERIFY: that Windows keeps a board's COM number when it is plugged into another USB port (a code comment; which USB port the one replugged test board used each time is not recorded) --> |
| macOS | `/dev/cu.usbmodem…` | untested |
| FreeBSD, OpenBSD | `/dev/cuaU0` style | untested |

On Linux the `ttyACM` numbers are not tied to a board: they follow the order boards appear, and two boards that reboot together can swap names. Use the `/dev/serial/by-id/` link wherever a board has to be the same one every time:

```bash
ls -l /dev/serial/by-id/
```

```text
usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00 -> ../../ttyACM0
```

The colons in the MAC are fine inside a source definition, such as `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee`. Kismet splits a definition only at the first colon.

Inside the project's Docker container, the entrypoint makes the same `/dev/serial/by-id/` links as the host has, so a definition written for the host works there too. On the test Pi, four sources defined by those links ran in the container.

### Listing boards with the helpers

Both helpers list the boards they can see without opening any port (opening one would move DTR and RTS). Each board is listed once per radio, as the source names to use.

The Python remote helper runs on any OS with Python (tested on Windows and Linux). It needs its packages first: without pyserial and msgpack even `--list` stops with `ModuleNotFoundError`. From the repository's root directory, on Windows:

```powershell
python -m pip install -r requirements.txt   # once
python -m esp32c5_kismet.remote --list
```

[Install on Windows](Install-on-Windows) has the details. On Linux, where Debian and Raspberry Pi OS have `python3` but no `python`, put the packages into a virtual environment, as on [Try It Without Hardware](Try-It-Without-Hardware):

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt   # once
.venv/bin/python -m esp32c5_kismet.remote --list
```

(`sudo apt install python3-venv` first if `venv` is missing.) On Linux, `ls -l /dev/serial/by-id/` ([Port names](#port-names)) shows each board's MAC too, with nothing installed.

With one board on COM14 the output reads:

```text
COM14  F0:F5:BD:01:02:03
    --source esp32c5-COM14
    --source esp32c5zigbee-COM14
    --source esp32c5btle-COM14
One source per board: it captures with one radio at a time. Every ESP32 on its native USB port has this USB ID, so a board listed here need not be an ESP32-C5 sniffer.
```

The C helper, on Linux only. It writes its list to stderr and exits with status 2, which is Kismet's usual behaviour, not an error:

```bash
kismet_cap_esp32c5 --list 2>&1
```

```text
esp32c5 supported data sources:
    esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
```

Both were run on the test Pi with its four boards and printed these lines for each board (the Python remote helper's closing line once); on Linux the Python remote helper names the port as `/dev/ttyACM0`.

On Linux, both helpers leave out a board whose port another capture holds, all three names of it together. They find that out from the system's lock table, without opening the port. A board held from a container, or from the host when the helper runs in one, is still listed; opening it then fails as in use. The Python remote helper then adds a line such as `Left out, in use by another capture: /dev/ttyACM0`. On Windows it lists every board, in use or not.

On the test Pi (Debian 13) the ports were `root:dialout` with mode 0660, so the user that runs Kismet or a helper has to be in the `dialout` group to open them. The install pages show how.

## What a board can and cannot do, per radio

A board runs **one radio at a time**. The source definition chooses it, and switching reboots the board: the new radio is up about 0.53 s after the command. The board remembers its last radio in flash and boots into it. On the Pi some switches also made the board drop off USB and come back within about 0.3 to 2.5 s, which the helpers ride out. One of the four test boards dropped off USB every time a fresh start with sources for mixed radios switched it to BLE while two other boards changed radio too (25 times in 25), and in 3 of those it then answered nothing until it was reset or unplugged and plugged back in; the helpers give up on it after 15 s, and trying again does not help. Of 160 switches between Wi-Fi and BLE made right after a capture, one hung, on the same board. It was always on the same hub port, so whether its firmware or the power on that port is to blame is not known.

| | Wi-Fi | Zigbee and Thread (IEEE 802.15.4) | Bluetooth LE |
|---|---|---|---|
| Channels | 42: 2.4 GHz 1–14; 5 GHz 36–64, 100–144 and 149–177 (every fourth) | 11–26 | Advertising channels 37, 38 and 39, all three together |
| At once | One channel | One channel | All three advertising channels |
| Captures | Management, data and control frames (ACK, RTS, CTS, Block Ack, PS-Poll, CF-End) | Every frame the radio receives | Advertising packets from a passive scan: ADV_IND, ADV_DIRECT_IND, ADV_NONCONN_IND, ADV_SCAN_IND |
| Per-packet metadata | Channel, frequency, signal and noise in dBm | Channel and signal in dBm. The board also records LQI, which does not reach Kismet | Signal in dBm |
| Leaves out | Frames that failed their checksum; the FCS itself; data rate, MCS and bandwidth | The FCS, which the radio checks and does not pass on | Which of the three channels a packet came on; connections; Bluetooth Classic |
| Transmits | Never | Only on `TXTEST` | Never |
| Kismet receives it as | radiotap (link type 127) | 802.15.4 without FCS (230) | LE link layer with pseudo-header (256) |

What follows from that:

- **Wi-Fi:** one channel at a time, so hopping trades coverage for completeness; use several boards to watch several channels. On 2.4 GHz the board tunes 20 MHz channels; on 5 GHz the Wi-Fi driver chooses the secondary channel itself. Whether every board receives on channel 14 and on 144, 169, 173 and 177 has not been checked on hardware: Kismet's hop list sends them to the boards, but no packet on 144 or 169 to 177 has been seen, and the only one labelled channel 14 came from a device heard mostly on channels 8 to 10. <!-- VERIFY: reception on channels 14, 144, 169, 173 and 177 (needs a board locked on each with a transmitter nearby). The 2026-10-02 four-board survey (hw5 s3) sent every board all of them: no packet on 144/169/173/177, and its one 2484 MHz packet came from a device whose other 1360 packets were at 2447-2457 MHz and 5180 MHz, so it does not show reception on 14 --> The 42 channels include some that are not allowed in every country; keeping to your local rules is your job (Kismet's `block_channels=` option, see [Channel Control](Channel-Control)).
- **Zigbee and Thread:** the board hears the frames, not their meaning above the MAC layer; Zigbee traffic above the network layer is encrypted. Kismet's 802.15.4 device records have no PAN field. `TXTEST` makes a board send 802.15.4 test frames, so a second board can prove the receive path when there is no Zigbee or Thread equipment around; in the tests, all 12 board pairs received 50 of 50 frames.
- **Bluetooth LE:** advertising only. The ESP32-C5 has no promiscuous Bluetooth mode, only a passive scan, and no Bluetooth Classic, so it cannot follow a connection. For that you need hardware that hops with the connection, such as an nRF52840 with Nordic's nRF Sniffer. BLE 5 extended advertising is not captured: the firmware is built without extended scanning and drops any report with more than 31 bytes of advertising data. The test captures held none, though no device known to use it was nearby. Every packet is labelled channel 37, and in Kismet a device's packet count stops rising once its advertisements repeat unchanged; see [Bluetooth LE Capture](Bluetooth-LE-Capture).
- **After 802.15.4, sometimes no Wi-Fi.** The firmware shuts each radio down cleanly before it reboots into another, because a board left with 802.15.4 powered can come back deaf to Wi-Fi. Flashing skips that shutdown: a test board flashed while it was on 802.15.4 came up deaf to Wi-Fi both times, and its Wi-Fi source said `capturing (wifi)` but got no packets, with no error. A reset did not cure it; switching the board to BLE and back did, for example by running a BLE source on it once and then the Wi-Fi source again. The firmware's notes say removing power also clears it (not tried in these tests). Before you flash a board, run a Wi-Fi source on it for a moment. See [Flashing the Firmware](Flashing-the-Firmware).

The radio pages have the details: [Wi-Fi Capture](Wi-Fi-Capture), [Zigbee and Thread Capture](Zigbee-and-Thread-Capture) and [Bluetooth LE Capture](Bluetooth-LE-Capture).

> **Note:** only capture on networks and devices you own or are authorised to test.
