This page covers what an ESP32-C5 board captures with its Wi-Fi radio, how Kismet moves it across both bands, and what you will see in Kismet. It is for anyone running a Wi-Fi source, whichever way Kismet is installed.

> **Warning:** Only capture on networks and devices you own or are authorised to test. In Wi-Fi mode the board only listens and never transmits, but recording other people's traffic can still be against the law where you are. To keep other people's devices out of the log, see [Kismet Configuration](Kismet-Configuration#logging-only-your-own-devices).

## At a glance

| | |
|---|---|
| Bands | 2.4 GHz and 5 GHz on the same board, one channel at a time |
| Channels | 42: 1–14, 36–64, 100–144 and 149–177 |
| Frames | management, data and control (ACK, RTS, CTS, Block Ack, PS-Poll, CF-End) |
| Per-frame metadata | a radiotap header: channel frequency, band, signal and noise in dBm |
| Link type | 127 (IEEE 802.11 with radiotap), passed to Kismet unchanged |
| Kismet phy | `IEEE802.11` |
| Start channel | 6 |
| Transmits | never: no beacons, probes, association or injection |

## Start a Wi-Fi source

Wi-Fi is the default radio. A source name with nothing between `esp32c5` and the `-` is a Wi-Fi source.

| Where the board is | Source definition |
|---|---|
| Linux, `/dev/ttyACM0`, Kismet on the same machine | `esp32c5-ttyACM0` |
| Linux, by the board's stable link | `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi` |
| Linux, the only board plugged in | `esp32c5` |
| Windows `COM14`, through the Python remote helper | `esp32c5-COM14` |

To start Kismet with one Wi-Fi source, run this and change `ttyACM0` to your board's port:

```bash
kismet -c esp32c5-ttyACM0
```
<!-- VERIFY: the short form "-c esp32c5-ttyACM0" on real hardware; the hardware runs used device= forms and esp32c5-ttyACM2:mode=wifi -->

To keep the source across restarts, put it in `kismet_site.conf` instead (see [Kismet Configuration](Kismet-Configuration)):

```ini
source=esp32c5-ttyACM0:name=wifi-a
```

A board remembers the radio it last used. If it was last on Zigbee or BLE, opening a Wi-Fi source reboots it into Wi-Fi first. In the test runs a source was capturing about 1.5 s after Kismet launched it when the board had to switch, and about 0.5 s when it was already on Wi-Fi.
<!-- VERIFY: re-measure the radio-switch time with the current helpers, which wait 0.8 s between MODE and START -->

All the ways to write a definition are on [Source Definitions](Source-Definitions). For boards on another machine, see [Remote Capture](Remote-Capture).

## Channels

| Band | Channels | Count | Centre frequency |
|---|---|---|---|
| 2.4 GHz | 1–14 | 14 | 2412–2472 MHz (2407 + 5 × channel), and 2484 MHz for channel 14 |
| 5 GHz | 36, 40, 44, 48, 52, 56, 60, 64 | 8 | 5180–5320 MHz (5000 + 5 × channel) |
| 5 GHz | 100, 104, … 144 (every 4th) | 12 | 5500–5720 MHz |
| 5 GHz | 149, 153, … 177 (every 4th) | 8 | 5745–5885 MHz |

- Channels are plain numbers. Kismet names such as `6HT40` or `36HT80` are refused.
- On 2.4 GHz the board listens on a 20 MHz channel. On 5 GHz the Wi-Fi driver picks the channel width itself. Whether 40 MHz and 80 MHz transmissions are received in full has not been tested.
- Channels 12–14 and 169–177 are not allowed everywhere. The board only receives, but if you want Kismet to keep to your country's channel plan, give the source a `channels=` or `block_channels=` list (see [Channel Control](Channel-Control)).
- Channel 14 (2484 MHz) showed up in Kismet's channel list on the test Pi. That every board receives on 144 and 169–177 has not been confirmed.
  <!-- VERIFY: frames received on channels 144, 169, 173 and 177 with current firmware -->

## Hopping and dwell

Kismet decides where the board listens. The helper tells the board one channel at a time, and Kismet moves it on at its hop rate.

| Kismet default | Value | What it means here |
|---|---|---|
| `channel_hop` | `true` | Wi-Fi sources hop unless told not to |
| `channel_hop_speed` | `5/sec` | 200 ms on each channel; one pass over all 42 channels takes about 8.4 s |
| `randomized_hopping` | `true` | the order is shuffled; the helper sets a skip of 4, so overlapping 2.4 GHz neighbours are not visited back to back |
| `split_source_hopping` | `true` | two or more Wi-Fi boards start at different points of the list (see [Multiple Boards](Multiple-Boards)) |

In the test runs Kismet reported the Wi-Fi source as `hopping=1`, `hop_rate=5`, `hop_shuffle=1`, `hop_shuffle_skip=4` over the 42 channels above, and the helper sent the board a new channel every 200 ms.

A board has one radio and one tuner. While it listens on channel 36 it hears nothing on channel 1. Hopping gives you a picture of everything around you, but only a fraction of each channel's traffic. So:

- **To survey**, hop. Kismet finds access points and clients on both bands within a few passes.
- **To follow one network**, lock the board on its channel with `channel=<n>,channel_hop=false`, from the web UI, or over the REST API. See [Channel Control](Channel-Control), which also explains why a locked board next to hopping Wi-Fi boards needs care.
- **To cover more**, add boards. Kismet splits the hop list between Wi-Fi boards by itself, or you can give each board its own band. See [Multiple Boards](Multiple-Boards) and [Dual-band Wi-Fi survey](Guide-Dual-Band-Wi-Fi-Survey).

The firmware has its own dwell setting (`DWELL`, 250 ms by default), but it applies only when the board is given several channels at once, and neither helper does that. Under Kismet, the hop rate is the dwell.

While the source hops, the Data Sources panel may keep showing the start channel (6) as the source's channel. The channel recorded for each packet and device is the one the board was really on.
<!-- VERIFY: whether kismet.datasource.channel now follows the hops with the current C helper (it sets the framework's current channel on every hop); older builds left it at 6 -->

## What each frame carries

Every Wi-Fi frame arrives with a 16-byte radiotap header:

| Radiotap field | Value |
|---|---|
| Flags | "frame includes FCS" is clear: the FCS has been removed |
| Channel | the frequency in MHz, and flags for the band (2.4 GHz or 5 GHz) and the modulation (CCK for 802.11b frames, otherwise OFDM) |
| dBm antenna signal | the signal strength the radio measured for this frame |
| dBm antenna noise | the radio's noise floor at the time |

The radiotap header does **not** carry the data rate or MCS, the channel width, HT/VHT/HE details, a TSFT timestamp or an antenna number.

The board stamps each frame in microseconds when it reaches the firmware, which is close to, but not exactly, the time it was on the air. The helper sets the board's clock to wall-clock time when the capture starts. For a remote source, Kismet replaces the time with its own arrival time unless the source has `timestamp=false` (see [Remote Capture](Remote-Capture)).

## Frame types

| Captured | Notes |
|---|---|
| Management | beacons, probes, authentication, association and the rest |
| Data | including aggregated (A-MPDU) data |
| Control | ACK, RTS, CTS, Block Ack, PS-Poll, CF-End |

Not captured:

- frames the radio received with an error, including a failed FCS check, so a capture never holds bad-FCS frames;
- driver packets of the "misc" kind, which carry no usable payload;
- frames longer than 11454 bytes once the FCS is removed. These are dropped and counted as "oversize".

Control frames come roughly one ACK per data frame, so on a busy channel they are a large part of the load. They can be switched off when you build the firmware yourself: `idf.py menuconfig` → *Packet Sniffer Configuration* → the control-frames option (`SNIFFER_CAPTURE_CTRL_FRAMES`). See [Flashing the Firmware](Flashing-the-Firmware).

## What Kismet shows

Kismet builds its device list from the frames. Wi-Fi devices are shown under the phy `IEEE802.11`, sorted into types such as **Wi-Fi AP**, **Wi-Fi Client**, **Wi-Fi Device**, **Wi-Fi Bridged**, **Wi-Fi Ad-Hoc** and **Wi-Fi WDS**. Access points and clients on 5 GHz appear alongside the 2.4 GHz ones once the hop reaches their channels.

What the test runs saw. These were measured on 2026-09-28 with builds of the helpers from before their final review, and the counts depend entirely on what was on the air around the test sites:

| Setup | Time | Packets | Wi-Fi devices | Devices on 5 GHz |
|---|---|---|---|---|
| Raspberry Pi 4, two local Wi-Fi sources splitting the channels | 243 s | 8801 + 10242 | 244 | 16 (channels 36, 40, 48, 100) |
| Raspberry Pi 4, one remote source over the websocket (C helper) | 60 s | 3473 | 100 | 15 |
| Raspberry Pi 4, the Python remote helper | 75 s | 2711 | 127 | 19 |
| Windows 11, Python remote helper, Kismet in WSL2 | about 3 min | about 9900 | 128 | 4 with packets |
| Windows 11, Python remote helper, Kismet in Docker Desktop | about 2.5 min | 6249 | 128 | 11 |

On the Pi, Kismet's channel list showed traffic on 2412–2484 MHz and on 5180, 5200, 5220, 5240, 5280, 5300, 5500 and 5745–5825 MHz.

Two counts can look inconsistent, for good reason:

- The **Data Sources** panel counts every packet the board delivered.
- The **device** counts leave out duplicates. When two boards hear the same frame, Kismet counts it once. The duplicate still updates the device's signal and "seen by", but not its packet count.

By default Kismet logs to a kismetdb file. To also get a pcapng file with the radiotap frames, add `log_types+=pcapng` to `kismet_site.conf`. See [Exporting to Wireshark](Guide-Exporting-to-Wireshark).

## Throughput and dropped frames

The board sends frames to the host over its USB-Serial-JTAG port, which carries a few hundred kB/s.
<!-- VERIFY: no measured throughput figure exists; "a few hundred kB/s" is the firmware's design note -->

The path on the board is: radio → a 64 KiB ring buffer → the USB driver's 32 KiB buffer → the host. When either cannot keep up, the board drops **whole frames**. It never sends half a frame, so the stream stays valid and the helper stays in sync. The firmware keeps three drop counters:

| Counter | Counts a frame dropped because |
|---|---|
| `buffer` | the ring buffer was full (a burst, or the host is not keeping up) |
| `usb` | the USB driver could not take the whole frame within 100 ms, typically when nothing is reading the port |
| `oversize` | the frame was too long for the format |

For scale: on channel 6 near the test Pi, each board delivered 410–778 frames in 8 seconds.

The counters are **not** sent over USB, so Kismet cannot see them. Kismet's packet counts show only what arrived. The board prints them every 10 seconds on its UART0 log port (115200 baud, TX on GPIO11), in a line like this:

```text
I (60012) sniffer: Wi-Fi ch   6 of 1 (250 ms) | captured 1234 | dropped: buffer 0, usb 0, oversize 0
```

Reading that port needs the board's UART connector or a USB-to-serial adapter on GPIO11/GPIO12; see [Hardware](Hardware) and [Firmware Protocol](Firmware-Protocol).

If you drop frames on a busy channel, you can spread the load over several boards, or build the firmware without control frames.

## Malformed frames

The Wi-Fi driver reports some MIMO frames with metadata that does not match the payload. Wireshark marks them as malformed. They are an artefact of the driver, not a sign of a bad board or a broken capture. Kismet's own error-packet count was 0 in the Docker Desktop run above (6249 packets); whether Kismet counts such frames as errors at all has not been checked.

How often it happens with this build has not been measured. The sibling project's notes give both "a few per thousand" and 2.5%.
<!-- VERIFY: measure the malformed-frame rate with this firmware build -->

## Limits

- **One channel at a time per board.** Use more boards to watch more channels at once.
- **Receive only.** No injection, deauthentication or active probing.
- **No rate, MCS or channel-width fields** in the radiotap header.
- **Drop counters are on UART0 only.**
- **One radio at a time.** A board in Wi-Fi mode hears no Zigbee, Thread or BLE.
- **A board that has run 802.15.4 can rarely come back deaf to Wi-Fi.** No reset clears it: unplug the board and plug it in again. The firmware shuts the other radio down cleanly before it reboots into Wi-Fi, which keeps this rare.

## See also

- [Channel Control](Channel-Control): hop rate, channel lists, locking, changing channels live
- [Multiple Boards](Multiple-Boards): splitting the bands across boards
- [Dual-band Wi-Fi survey](Guide-Dual-Band-Wi-Fi-Survey): a worked example
- [Troubleshooting](Troubleshooting)
- The firmware source: [esp32c5_sniffer.c](https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/blob/main/firmware/main/esp32c5_sniffer.c)
