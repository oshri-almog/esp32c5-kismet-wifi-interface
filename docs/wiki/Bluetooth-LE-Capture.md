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
<!-- VERIFY: the short form "-c esp32c5btle-ttyACM0" on real hardware; the hardware runs used device= forms -->

There is no channel to choose. `channel=` accepts 37, 38 or 39, and the source stays on 37 whatever you give it. See [Source Definitions](Source-Definitions) for every form of the name.

## Advertising only, and why

The ESP32-C5 has no promiscuous mode for Bluetooth, only a passive scan through its Bluetooth controller. The controller reports each advertisement it hears. The firmware rebuilds each report as a link-layer packet and sends it on. Everything below follows from that.

- **No connections.** Once two devices connect and move to the data channels, their traffic is gone from the capture. The controller does not follow connections, and there is no Bluetooth promiscuous mode to match the Wi-Fi one, on this chip or on other Espressif parts. To follow connections you need hardware that hops with them, such as an nRF52840 running Nordic's nRF Sniffer.
- **No Bluetooth Classic.** The ESP32-C5 has no BR/EDR radio at all.
- **No BLE 5 extended advertising.** The firmware is built without extended scanning, so `ADV_EXT_IND` and the `AUX_` packets, including Coded PHY, are not captured.
  <!-- VERIFY: derived from CONFIG_BT_NIMBLE_EXT_SCAN being off; not tested on air -->
- **Scan responses are rare.** A passive scan never sends a scan request, so devices seldom send `SCAN_RSP`. A device that puts its name only in its scan response therefore shows up without a name.
  <!-- VERIFY: devices that name themselves only in SCAN_RSP appear nameless in Kismet -->
- **Every repeat is reported.** The controller's duplicate filter is off, so the board sends every advertisement it hears, not one per device.

## Every packet on channel 37

The controller scans advertising channels 37, 38 and 39 together and cannot be limited to one. NimBLE does have a call for that, `ble_gap_set_scan_chan()`, but its own header says it is supported only on the ESP32-C2, and the C5's controller rejects it as an unknown command.

The controller's report does not say which of the three channels an advertisement came in on. The radio pseudo-header needs a channel, so the firmware writes channel 37 in every packet. As a result:

- **Kismet shows every BTLE device on channel 37 (2402 MHz).** That is a label, not a measurement.
- **The source's channel list is only `37`.** Kismet's *Lock* and *Hop* buttons and the `set_channel.cmd` REST call are accepted and change nothing.
- **Nothing is missed by channel choice.** All three advertising channels are scanned all the time, so there is no hopping to do.
  <!-- VERIFY: the firmware leaves the scan interval and window to the controller, whose comment says it then listens continuously; confirm the scan duty cycle -->

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

Both helpers detect this, compute the CRC, set the two flags, and say so once in Kismet's messages. The C helper says it once per run, the Python remote helper once per connection:

```text
<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary
```
<!-- VERIFY: the fix-up and its message text in both helpers after their final review -->

If you see that message, capture still works, but flash the current firmware when you can: [Flashing the Firmware](Flashing-the-Firmware).

The sibling's firmware 1.0.0 and 1.1.0 have no BLE radio at all. With those, the C helper reports `<name>: lost sync (the board sends link type 127, not 256)` (or `283, not 256`), and after 15 s `<name>: no capture from the board on <device> for 15 seconds; ...`. The Python remote helper gives up with `the board on <port> has not been capturing for 15 s`. Flash the current firmware.
<!-- VERIFY: behaviour and message texts with sibling firmware 1.0.0 and 1.1.0 in BTLE mode, with both helpers (firmware.md 16.5: derived from code, not run) -->

A record too short to be a BTLE packet, or one from older firmware too long to be one, is dropped and counted by either helper: `<name>: <n> BTLE records of impossible length dropped`, at the first drop and every 1000th.
<!-- VERIFY: the BTLE length checks and the drop message in both helpers after their final review (both drop a record shorter than a BTLE packet, and a longer one only when it needs the older-firmware fix-up) -->

## Why per-device counts stay low

Kismet drops repeated packets as duplicates, and BLE advertisements repeat a lot.

- Kismet computes a CRC32 over each packet (for BTLE, the access address, the PDU and the CRC, without the 10-byte pseudo-header). A packet whose CRC32 matches one of the **last 1024 unique packets**, from any source, is marked as a duplicate.
- An advertiser sends the same bytes on channels 37, 38 and 39, and again at every advertising interval. Nearly all of its packets are duplicates.
- **A BTLE duplicate never updates the device.** Its packet count, last-seen time and signal stop after the first few packets, and change again only when the advertisement's content changes, or once 1024 other unique packets have gone by.

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

BTLE devices appear under the phy `BTLE`, each with its address, its advertised name when it sends one, a manufacturer when Kismet can tell it from the address, its signal in dBm, and channel 37.

| Setup | Time | Source packets | BTLE devices | With a name |
|---|---|---|---|---|
| Raspberry Pi 4, local source | 150 s | 2969 | 17–18 | 2 |
| Raspberry Pi 4, Python remote helper | 75 s | 1274 | 15 | 1 |
| Windows 11, Python remote helper, Kismet in WSL2 | about 3 min | 3443 | 16 | 1 |

These were measured on 2026-09-28 with builds of the helpers from before their final review. What you see depends on the devices around you. The demo's fake board shows one advertiser, named `ESP32C5-FAKE` ([Try It Without Hardware](Try-It-Without-Hardware)).

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
- **The CRC matches the rebuilt packet**, which differs from the on-air one for BLE 5 devices that set ChSel.
- **One radio at a time**: a board capturing BLE hears no Wi-Fi or 802.15.4.

## See also

- [BLE advertising survey guide](Guide-BLE-Advertising-Survey)
- [Multiple Boards](Multiple-Boards): a BTLE board alongside Wi-Fi and Zigbee boards
- [Exporting to Wireshark](Guide-Exporting-to-Wireshark)
- [Troubleshooting](Troubleshooting)
