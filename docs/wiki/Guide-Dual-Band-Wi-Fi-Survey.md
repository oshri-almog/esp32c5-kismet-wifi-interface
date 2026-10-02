This guide surveys Wi-Fi on both bands with two or more ESP32-C5 boards on one Kismet: how to name the boards, whether to let Kismet share the channels between them or give each board its own list, how to log the survey, and how to read what it found. It assumes you have done [Guide: First Capture](Guide-First-Capture) with one board.

> **Note:** Only capture on networks and devices you own or are authorised to test. In Wi-Fi mode the boards only listen, but recording other people's traffic can still be against the law where you are.

## What you need

| | |
|---|---|
| Boards | Two or more ESP32-C5 boards with this project's firmware ([Flashing the Firmware](Flashing-the-Firmware)) |
| Hub | A **powered** USB hub. An unpowered hub browns out under several boards, and the failures look like firmware bugs ([Hardware](Hardware)) |
| Kismet | Built with the ESP32-C5 source ([Install on Raspberry Pi](Install-on-Raspberry-Pi), [Install on Linux](Install-on-Linux)), or the Docker image ([Install with Docker](Install-with-Docker)) |
| Tested | Two boards on a Raspberry Pi 4 (8 GB), Debian 13 arm64, native Kismet build. Four Wi-Fi boards at once ran only in a short check of the Docker image on the same Pi, where all four captured; they have not been run as a survey |

<!-- VERIFY: a survey with three or four Wi-Fi boards split by Kismet, on the Pi with the current helpers, and then update the "Tested" row -->

The examples use Kismet installed in `~/kismet-install` and the login `admin` / `choose-a-long-password` from [Guide: First Capture](Guide-First-Capture). Change them to yours.

## Why more boards help

A board has one radio and one tuner: while it listens on channel 36, it hears nothing on channel 1. Kismet hops a Wi-Fi board over all 42 channels the firmware can tune to (1–14, 36–64, 100–144 and 149–177), five channels a second by default, so each channel gets 200 ms of every 8.4-second pass. A second board halves the time any one channel goes unheard, or lets each board stay on one band.

There are two ways to share the work. Pick one:

| | Kismet splits the channels | Each board gets its own list |
|---|---|---|
| How | Give every board the same, default channel list | Give each board a `channels=` list, for example one for 2.4 GHz and one for 5 GHz |
| What each board does | Hops all 42 channels, each from a different starting point | Hops only its own list |
| One pass | 8.4 s per board at 5 hops/s | 2.6 s for 13 channels at 2.4 GHz, 5 s for 25 channels at 5 GHz |
| Good for | A general picture of both bands with no set-up | Watching each band more often; keeping to your country's channel plan |
| Tested | Yes, two boards on the Pi | With two simulated boards and a real Kismet; not yet with real boards |

A third pattern works with either: lock one board on the channel of the network you care most about, and let the others hop. See [Channel Control](Channel-Control).

## Step 1: Find the boards' stable names

Plug the boards into the powered hub, then list them:

```bash
ls -l /dev/serial/by-id/
```

```text
usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00 -> ../../ttyACM0
usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00 -> ../../ttyACM1
```

The part after `unit_` is each board's MAC. Use these names in the source definitions: the `ttyACM` numbers follow the order in which the boards come up and can change, the `/dev/serial/by-id/` names stay with the boards. Colons inside the name are fine in a definition, because Kismet splits only at the first `:`.

## Step 2a: Let Kismet split the channels

Start Kismet with one Wi-Fi source per board. Change the two MACs to yours:

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -t survey \
    -c 'esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a' \
    -c 'esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=wifi,name=wifi-b'
```

`-t survey` names the log file `survey-...` instead of `Kismet-...`.

Kismet splits the hop list between sources that have the same source type (`esp32c5`) and the same channel list. Both boards here have the default 42-channel list, so Kismet logs:

```text
INFO: Splitting channels for interfaces using 'esp32c5' among 2 interfaces
```

Splitting does not give each board half the channels. Every board hops the whole list, each starting at a different point: with two boards, one at position 0 and one at position 21. Check it over the REST API in a second terminal:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/datasource/all_sources.json \
  | python3 -c 'import json,sys; [print(s["kismet.datasource.name"], s["kismet.datasource.hop_offset"], len(s["kismet.datasource.hop_channels"]), s["kismet.datasource.hop_rate"]) for s in json.load(sys.stdin)]'
```

Each line shows a source's name, its starting position, the number of channels it hops and its hop rate. With the two sources above it prints lines like `wifi-a 21 42 5` and `wifi-b 0 42 5`; on the test Pi, too, the two offsets were 21 and 0, with 42 channels each at 5 hops per second.

After the first pass the two boards drift closer: on the test Pi they ended up only 5 positions apart instead of 21. They were still never on the same channel at the same time. This is how Kismet's capture framework restarts its hop loop, not something this project controls.

## Step 2b: Or give each board its own band

Give each source a `channels=` list. A value with commas must be in double quotes inside the definition, and the whole definition in single quotes for the shell:

```bash
~/kismet-install/bin/kismet --no-ncurses -t survey \
    -c 'esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-24,channels="1,2,3,4,5,6,7,8,9,10,11,12,13"' \
    -c 'esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=wifi,name=wifi-5,channels="36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144,149,153,157,161,165"'
```

Change the lists to the channels used where you are. The board can also tune to 14, 144 and 169, 173 and 177, which are not allowed everywhere. <!-- VERIFY: that the board's radio really receives on 144, 169, 173 and 177: Kismet's hop list sends them to the board (seen on the Pi), but no traffic on them was ever seen, and whether the radio tunes there was not checked (channel 14 rests only on the channel tracker's range in field test T1c; see Hardware) --> It only receives, but a list that matches your country's channel plan saves time on channels nobody uses.

What changes when the lists differ:

- Kismet still splits the two sources. It compares the channels each source can tune to (the helper's 42), not the `channels=` lists, so the log still shows `Splitting channels for interfaces using 'esp32c5' among 2 interfaces`. Each board hops only its own list, from a starting point worked out from that list's length: 0 for the board that opened last, and half its own list (6 or 12) for the other.
- Because they are split, `channel_hoprate=` on each source is honoured, for example `channel_hoprate=2/sec` on the 2.4 GHz board. Without it, both hop at Kismet's global rate, `channel_hop_speed` (5 per second by default).
- With two simulated boards and the lists above, the one-liner from step 2a printed `wifi-24 6 13 2` and `wifi-5 0 25 5` (the first with `channel_hoprate=2/sec`), and each board was sent only the channels of its own list.
- Write the channels as plain numbers. The helper reads Kismet's `6HT40`-style names as the number they start with, so `6HT40` tunes the board to 6, but Kismet adds such a name to the source's channel list, which then no longer matches the other boards' lists, and the split stops.

To drop a few channels from the full list instead of writing out a new one, use `block_channels=`, for example `block_channels="12,13,14"`. It works with the split in step 2a as long as every board blocks the same channels, so that the lists stay equal. [Source Definitions](Source-Definitions) lists the channel options.

## Step 3: Make it permanent and log it

For a survey you run more than once, put the sources and the logging in `kismet_site.conf` instead of typing them. Kismet reads this file last, and its settings win. For the home-directory install it is `~/kismet-install/etc/kismet_site.conf`:

```ini
# Two Wi-Fi boards, split by Kismet (step 2a). Change the MACs to your boards'.
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=wifi,name=wifi-b

# Logs go here, wherever Kismet is started. The folder must exist.
log_prefix=/home/pi/kismet-logs/
log_title=survey

# A pcapng file next to the kismetdb, for Wireshark
log_types+=pcapng
```

Change `/home/pi` to your home directory. Then start Kismet without `-c`, because any `-c` on the command line makes Kismet ignore every `source=` line:

```bash
~/kismet-install/bin/kismet --no-ncurses
```

Each run writes `survey-<date>-<time>-1.kismet`, and with `log_types+=pcapng` also `survey-<date>-<time>-1.pcapng`, in `log_prefix`. The date and time in the names are UTC. The `.kismet` file is an SQLite database with the devices and every packet; the `.pcapng` file holds the packets for Wireshark. [Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark) explains both. Write `log_types+=`, not `log_types=`: in `kismet_site.conf`, a plain `=` replaces Kismet's default `kismet` log type instead of adding to it.

With Docker, give the same definitions to the `kismet` service in `KISMET_SOURCES`, separated by spaces ([Install with Docker](Install-with-Docker)). The container makes the same `/dev/serial/by-id/` links as the host; on the test Pi, four boards named this way in `KISMET_SOURCES` (two Wi-Fi, one Zigbee, one BTLE) all ran, and the Wi-Fi and BTLE ones received packets. Port names such as `esp32c5-ttyACM0:mode=wifi,name=wifi-a` work there too, but follow the order in which the boards come up. Its logs go to the `kismet-data` volume.

## Step 4: Run the survey

1. Open `http://192.168.1.50:2501`, with your Kismet machine's address in place of `192.168.1.50`, and log in.
2. Under **Data Sources**, check that both sources are running and that both packet counts climb.
3. Leave the boards running for several minutes: each full pass visits a channel for 200 ms, so a busy access point shows up in the first pass and a quiet client may take many.
4. Stop Kismet with Ctrl+C. The logs stay in `log_prefix`.

## Step 5: Read the results

**In the web UI**, the device list shows every device with its type (**Wi-Fi AP**, **Wi-Fi Client**, **Wi-Fi Device** and others), its channel and its signal. Sort by channel to see the 5 GHz access points together. A device's details show which sources saw it.

Two counts that look inconsistent are both right:

- **Data Sources** counts every packet each board delivered.
- The **device** counts leave out duplicates. When both boards hear the same frame, Kismet counts it once. The duplicate still updates the device's signal and "seen by", but not its packet count.

**Over the REST API**, this counts the Wi-Fi devices on each band while Kismet runs:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/devices/views/all/devices.json \
  | python3 -c '
import json, sys
wifi = [d for d in json.load(sys.stdin) if d.get("kismet.device.base.phyname") == "IEEE802.11"]
khz = [d.get("kismet.device.base.frequency", 0) for d in wifi]
print(len(wifi), "Wi-Fi devices:", sum(1 for f in khz if 0 < f < 3000000), "on 2.4 GHz,", sum(1 for f in khz if f >= 5000000), "on 5 GHz")
'
```

It prints one line: the number of Wi-Fi devices, then how many of them are on each band. Kismet gives a device's frequency in kHz (2437000 for channel 6, 5240000 for channel 48, as the test Pi showed). Devices that Kismet has not tied to a frequency (it gives them 0) are counted in the total but on neither band.

**After the survey**, the `.kismet` log holds the same data. [Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark) shows how to turn it into a pcapng file and what Kismet's log tools can do with it.

## What the test survey found

Two boards on the test Raspberry Pi 4, with an earlier build of the C helper, each a local Wi-Fi source named by its `/dev/serial/by-id/` path, with Kismet splitting the 42 channels between them (step 2a):

| | |
|---|---|
| Duration | 242.7 s (about 4 minutes) |
| Health | 243 REST polls, one a second; no sample showed a source in error or not running |
| Packets | 8801 from one board, 10242 from the other |
| Wi-Fi devices | **244** in total; one board saw 170 of them, the other 183 |
| By band | Kismet placed 109 devices on 2.4 GHz channels (1–11 and 13) and 16 on 5 GHz channels (36, 40, 48 and 100) |
| Frequencies with traffic (Kismet's channel tracker) | 2412–2484 MHz (the tracker's range; no 2484 MHz packet is in the kept logs), and 5180, 5200, 5220, 5240, 5280, 5300, 5500 and 5745–5825 MHz |
| Hopping | 42 channels each, 5 hops per second, shuffled, start offsets 21 and 0 |

<!-- VERIFY: re-run this survey on the Pi with the current helper and firmware (these figures come from an earlier build); also check what channel Kismet shows for the devices placed on neither band -->

What you see depends entirely on the networks around you. In that building most devices were on 2.4 GHz.

For comparison, one board hopping alone for 60 s on the same Pi (fed in through the C helper's remote mode, the same earlier build) found 100 Wi-Fi devices, 15 of them on 5 GHz. In the two-board run, the first packets reached Kismet 1.7 s and 2.7 s after it started the boards. Later 60 s runs on the same Pi, with a newer helper, measured 2.2 to 3.7 s, and two boards found 47 to 53 Wi-Fi devices.

## If something goes wrong

| What you see | What to do |
|---|---|
| No `Splitting channels` line with two Wi-Fi boards | The boards' channel lists differ, for example different `block_channels=` lists, a `channels=` entry that is not a plain number (such as `6HT40`), or one source is not running yet. Different `channels=` lists of plain numbers do not stop the split. Give both the same `block_channels=` (or none) |
| `... is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time` | Two definitions point at the same board, or another esp32c5 source, the Python remote helper, esptool or a serial terminal such as picocom, pyserial's miniterm or screen holds it. One source per board. minicom takes no lock, so it does not cause this message, but a capture then opens the board anyway and breaks: close any terminal on the board |
| `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= ...`, retried every 5 s | A bare `esp32c5` means "the only board plugged in". Name each board with `device=` as above |
| A board disappears from `/dev/serial/by-id/` during the survey | Check `dmesg` for `USB disconnect`. Replug the board or power-cycle the hub; Kismet reopens the source every 5 s until the board is back |
| The source's channel stays at `6` while hopping | Nothing is wrong: Kismet keeps the start channel in that field while the helper hops the board, with either helper; the channel of each packet and device is the real one |

More in [Troubleshooting](Troubleshooting).

## See also

- [Multiple Boards](Multiple-Boards): mixing radios, and how boards share a Kismet
- [Channel Control](Channel-Control): hop rates, locking a channel, changing channels while Kismet runs
- [Wi-Fi Capture](Wi-Fi-Capture): what a Wi-Fi board captures and what it leaves out
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf` and logging options
