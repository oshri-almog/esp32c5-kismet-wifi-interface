This page covers capturing Bluetooth LE advertising with an ESP32-C5 board: what it can and cannot capture and why, why every packet shows as channel 37, how the CRC reaches Kismet, and why Kismet's per-device counts stay low. It is for anyone running a BTLE source.

> **Warning:** Only capture on networks and devices you own or are authorised to test. The board scans passively and never transmits, but advertisements identify people's phones, watches and trackers, and recording them can still be against the law where you are. To keep other people's devices out of the log, see [Kismet Configuration](Kismet-Configuration#logging-only-your-own-devices).

## At a glance

| | |
|---|---|
| Captured | Bluetooth LE advertising: `ADV_IND`, `ADV_DIRECT_IND`, `ADV_NONCONN_IND` and `ADV_SCAN_IND` |
| Not captured | connections, BLE 5 extended advertising, Bluetooth Classic |
| Channels | advertising channels 37, 38 and 39, all scanned at once; every packet is labelled 37 |
| From the board | link type 256 (Bluetooth LE link layer with the radio pseudo-header) |
| To Kismet | the same, unchanged (the CRC is filled in for boards on older firmware) |
| Kismet phy | `BTLE` |
| Transmits | never: a passive scan sends nothing, not even scan requests |

## Start a BTLE source

`btle`, `ble` and `bluetooth` all name this radio, either between `esp32c5` and the `-` or in `mode=`.

| Where the board is | Source definition |
|---|---|
| Linux, `/dev/ttyACM0` | `esp32c5btle-ttyACM0` |
| The same, with `mode=` | `esp32c5-ttyACM0:mode=btle` |
| Windows `COM14`, through the Python remote helper | `esp32c5btle-COM14` |

To start Kismet with one BTLE source, run this and change `ttyACM0` to your board's port:

```bash
kismet -c esp32c5btle-ttyACM0
```

There is no channel to choose. `channel=` accepts 37, 38 or 39, and the source stays on 37 whatever you give it. See [Source Definitions](Source-Definitions) for every form of the name.

**A radio switch can hang a board.** Now and then a board drops off USB as it switches radio, comes back and answers nothing until it is reset with esptool or unplugged and plugged back in; on the test Pi this happened mostly at a Kismet start with sources for mixed radios ([Troubleshooting](Troubleshooting#a-board-stops-answering-after-a-radio-switch)).

## Advertising only, and why

The ESP32-C5 has no promiscuous mode for Bluetooth, only a passive scan through its Bluetooth controller. The controller reports each advertisement it hears. The firmware rebuilds each report as a link-layer packet and sends it on. Everything below follows from that.

- **No connections.** Once two devices connect and move to the data channels, their traffic is gone from the capture. The controller does not follow connections, and there is no Bluetooth promiscuous mode to match the Wi-Fi one, on this chip or on other Espressif parts. To follow connections you need hardware that hops with them, such as an nRF52840 running Nordic's nRF Sniffer.
- **No Bluetooth Classic.** The ESP32-C5 has no BR/EDR radio at all.
- **No BLE 5 extended advertising.** The firmware is built without extended scanning, and drops any report with more than 31 bytes of advertising data, so `ADV_EXT_IND` and the `AUX_` packets, including Coded PHY, are not captured. The test captures held no extended advertising, but no device known to use it was nearby.
- **No scan responses, in practice.** A passive scan never sends a scan request, so devices do not answer it with `SCAN_RSP`: the test captures held none in 12,695 advertisements. A device that puts its name only in its scan response therefore shows up without a name. That follows from the above; it was not checked with such a device.
- **Every repeat is reported.** The controller's duplicate filter is off, so the board sends every advertisement it hears, not one per device.

## Every packet on channel 37

The controller scans advertising channels 37, 38 and 39 together and cannot be limited to one. NimBLE does have a call for that, `ble_gap_set_scan_chan()`, but its own header says it is supported only on the ESP32-C2, and the C5's controller rejects it as an unknown command.

The controller's report does not say which of the three channels an advertisement came in on. The radio pseudo-header needs a channel, so the firmware writes channel 37 in every packet. As a result:

- **Kismet shows every BTLE device on channel 37 (2402 MHz).** That is a label, not a measurement.
- **The source's channel list is only `37`.** Kismet's *Lock* and *Hop* buttons and the `set_channel.cmd` REST call are accepted and change nothing: a set to 38 or 39 shows as 37. A set to any other channel, such as 40, is refused: Kismet's log shows `<name> cannot tune to channel 40 in btle mode`, the call still answers HTTP 200, and the source goes on capturing on 37.
- **Nothing is missed by channel choice.** All three advertising channels are scanned all the time, so there is no hopping to do. In a 120 s test the board heard 97.6% of the advertising events of a strong advertiser that sent one every 100 ms; weaker advertisers were heard less often.

## CRC and the flags Kismet relies on

The radio pseudo-header has flags that say whether a packet's CRC was checked and whether it was valid. **Kismet relies on them.** When "CRC checked" is set, Kismet takes the "CRC valid" flag as the answer: valid packets are decoded, invalid ones counted as errors. When "CRC checked" is not set, Kismet checks the CRC itself and drops every packet that fails.

The controller reports only advertisements whose CRC passed, but it does not hand over the CRC. So the current firmware:

1. rebuilds the packet from the controller's report;
2. computes the 24-bit advertising CRC over it;
3. writes that CRC, and sets both "CRC checked" and "CRC valid" (flags `0x0C13`).

In the test runs, all 757 BLE records from the four test boards had a correct CRC and both flags, and Kismet counted 0 error packets.

**One caveat.** The controller's report does not include the header's ChSel bit, so the firmware always records it as clear. BLE 5 devices that set ChSel in `ADV_IND` or `ADV_DIRECT_IND` therefore appear with a header byte, and a CRC, that differ from what they transmitted. The CRC matches the packet as recorded, which is what Kismet and Wireshark check, but it is not the on-air CRC. `ADV_NONCONN_IND`, `ADV_SCAN_IND` and `SCAN_RSP` are not affected.

### Boards on older firmware

The sibling project's published firmware (esp32c5-wireshark-sniffer 1.2.0, the one its web flasher installs) leaves both flags clear and writes a zero CRC. Kismet would drop every one of those packets **without an error**: the source counts packets, but no BTLE devices appear.

Both helpers detect this, compute the CRC, set the two flags, and say so in Kismet's messages, once each time the source opens (for a remote helper, once per connection):

```text
<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary
```

If you see that message, capture still works, but flash the current firmware when you can: [Flashing the Firmware](Flashing-the-Firmware). In the tests, a board on 1.2.0 captured BLE this way through the C helper, local and remote, and through the Python remote helper, with every record put right and none dropped.

The sibling's firmware 1.0.0 and 1.1.0 have no BLE radio at all: 1.1.0 ignores `MODE BLE` and goes on sending what it was capturing, and 1.0.0 has no `MODE` command. Kismet's messages then show `<name>: lost sync (the board sends link type 127, not 256)` (or `283, not 256` for a board left on 802.15.4), never `capturing`, and after 15 s `<name>: no capture from the board on <device> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` (the Python remote helper adds what the board last said, as `(last: ...)` after `15 seconds`). For a local source, the source's error in Kismet reads only `IPC connection closed`, and Kismet re-opens it 5 s later, so the cycle repeats. Flash the current firmware.

A record too short to be a BTLE packet, or one from older firmware too long to be one, is dropped and counted by either helper: `<name>: <n> BTLE records of impossible length dropped`, at the first drop and every 1000th.

## Why per-device counts stay low

Kismet drops repeated packets as duplicates, and BLE advertisements repeat a lot.

- Kismet computes a CRC32 over each packet (for BTLE, the access address, the PDU and the CRC, without the 10-byte pseudo-header). A packet whose CRC32 matches one of the **last 1024 unique packets**, from any source, is marked as a duplicate.
- An advertiser sends the same bytes on channels 37, 38 and 39, and again at every advertising interval. Nearly all of its packets are duplicates.
- **A BTLE duplicate never updates the device.** Its packet count, last-seen time and signal stay as its first packets left them, and change again only when the advertisement's content changes, or once 1024 other unique packets have gone by. With only BTLE sources that can take hours: in a 180 s test, 15 of 16 devices showed a single packet, and none a last-seen time later than its first.

What the test Pi saw over 150 seconds: the BTLE source counted 2969 packets, about 20 per second, while each of the 17–18 BTLE devices showed only 1–3 packets. In the Windows-to-WSL2 run, Kismet's packet statistics showed 1094 of 1099 packets in one minute as duplicates, and 0 errors.

Nothing in Kismet's configuration turns this off. (`packet_dedup_size` in `kismet_memory.conf` is not read by this Kismet.) To see every packet:

- the *Data Sources* panel counts every packet the board delivered, duplicates included;
- `GET /packetchain/packet_stats.json` gives the duplicate rate;
- the kismetdb log and the pcapng log keep duplicates by default, so an exported capture has every advertisement ([Exporting to Wireshark](Guide-Exporting-to-Wireshark)).

### Random addresses

Many devices advertise from random addresses and change them from time to time, so one device can appear as several over a session. The test runs saw mostly random addresses alongside a few public ones. To hide every random-address device from Kismet's device list, add this to `kismet_site.conf`:

```ini
btle_ignore_random=true
```

Their packets are still logged. See [Kismet Configuration](Kismet-Configuration).

## What Kismet shows

BTLE devices appear under the phy `BTLE`, each with its address, its advertised name when it sends a complete one (Kismet ignores a shortened name), a manufacturer when Kismet can tell it from the address, its signal in dBm, and channel 37.

| Setup | Time | Source packets | BTLE devices | With a name |
|---|---|---|---|---|
| Raspberry Pi 4, local source | 150 s | 2969 | 17–18 | 2 |
| Raspberry Pi 4, Python remote helper | 75 s | 1274 | 15 | 1 |
| Windows 11, Python remote helper, Kismet in WSL2 | about 3 min | 3443 | 16 | 1 |
| Raspberry Pi 4, local source, three other boards running | 60 s | 998 | 14 | not counted |
| Raspberry Pi 4, Python remote helper, three other boards running | 60 s | 986 | 13 | not counted |
| Windows 11, Python remote helper, Kismet on the Pi across the LAN | 60 s | 791 | 6 | not counted |

The first three rows were measured on 2026-09-28 with builds of the helpers from before their final review, the last three on 2026-10-02 (Raspberry Pi 4 with Debian 13, firmware image 01a50bd6). What you see depends on the devices around you. The demo's fake board shows one advertiser, named `ESP32C5-FAKE` ([Try It Without Hardware](Try-It-Without-Hardware)).

Two limits of Kismet's BTLE support show up here:

- **An advertiser whose advertising data ends in zero padding never becomes a device.** Kismet cannot parse such data and drops the packet from its device list without counting an error. The packets are still in the kismetdb and pcapng logs. The tests met three such advertisers.
- **The kismetdb log records the frequency of every BTLE packet as 0.** The device records show 2402 MHz.

For reference, the radio pseudo-header on each packet:

| Field | Value |
|---|---|
| RF channel | 0, the RF index of advertising channel 37 |
| Signal | the RSSI from the controller's report, in dBm |
| Noise | 0, marked as not valid |
| Access-address offenses | 0 |
| Reference access address | `0x8E89BED6`, the advertising access address |
| Flags | `0x0C13`: de-whitened, signal valid, reference access address valid, CRC checked, CRC valid |

## Limits

- **Advertising only**: no connections, no Bluetooth Classic, and no BLE 5 extended advertising.
- **No per-packet channel**: everything is labelled 37.
- **Low per-device counts in Kismet**, because repeated advertisements are duplicates.
- **Some advertisers never appear as devices**: Kismet cannot parse advertising data that ends in zero padding.
- **The CRC matches the rebuilt packet**, which differs from the on-air one for BLE 5 devices that set ChSel.
- **One radio at a time**: a board capturing BLE hears no Wi-Fi or 802.15.4.

## See also

- [BLE advertising survey guide](Guide-BLE-Advertising-Survey)
- [Multiple Boards](Multiple-Boards): a BTLE board alongside Wi-Fi and Zigbee boards
- [Exporting to Wireshark](Guide-Exporting-to-Wireshark)
- [Troubleshooting](Troubleshooting)
