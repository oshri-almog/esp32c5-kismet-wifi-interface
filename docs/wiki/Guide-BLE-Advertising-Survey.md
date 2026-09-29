This guide surveys Bluetooth LE advertisers with an ESP32-C5 board in Kismet: start a BTLE source, read what Kismet lists for each device, get at names and manufacturer data, understand the limits, and run the BLE board alongside Wi-Fi boards. It assumes a working setup from [Guide: First Capture](Guide-First-Capture).

> **Warning:** Only capture on networks and devices you own or are authorised to test. The board scans passively and never transmits, but advertisements identify people's phones, watches and trackers, and recording them can still be against the law where you are.

## What you need

| | |
|---|---|
| Board | One ESP32-C5 board with this project's firmware ([Flashing the Firmware](Flashing-the-Firmware)) |
| Kismet | Built with the ESP32-C5 source, or the Docker image |
| Tested | A Raspberry Pi 4 with a local BTLE source; the Pi and a Windows 11 PC with the Python remote helper |

The examples use Kismet in `~/kismet-install`, the login `admin` / `choose-a-long-password`, and the board on `/dev/ttyACM0`. Change them to yours.

## What the board hears

- **Advertising only.** The ESP32-C5 runs a passive Bluetooth LE scan: it hears what devices broadcast before anyone connects to them (`ADV_IND`, `ADV_DIRECT_IND`, `ADV_NONCONN_IND`, `ADV_SCAN_IND`), not connections, and it has no Bluetooth Classic.
- **All three advertising channels at once.** The controller scans channels 37, 38 and 39 together and cannot be limited to one, so there is no channel to choose and nothing to hop.
- **Every repeat.** The board passes on every advertisement it hears, not one per device.
- **No BLE 5 extended advertising.** The firmware is built without extended scanning. <!-- VERIFY: derived from CONFIG_BT_NIMBLE_EXT_SCAN being off; not tested on air -->

[Bluetooth LE Capture](Bluetooth-LE-Capture) explains each of these.

## Step 1: Start a BTLE source

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5btle-ttyACM0:name=c5-btle'
```

`btle` between `esp32c5` and the `-` picks the Bluetooth LE radio; `ble` and `bluetooth` mean the same. <!-- VERIFY: the short form esp32c5btle-ttyACM0 on real hardware; the hardware runs used device= forms --> Look for:

```text
INFO: c5-btle capturing (btle)
```

If the board last used another radio, it reboots into BLE first, which adds about a second. The source's channel list holds only `37`. The **Lock** and **Hop** buttons in **Data Sources** and the channel REST calls are accepted and change nothing.

Boards flashed with the sibling project's firmware 1.2.0 leave the CRC of each BLE packet empty. The helper then fills it in and says so once, in a Kismet message that begins `c5-btle: the board's firmware does not mark BTLE packets as CRC checked`. Capture works, but flash the current firmware when you can.

## Step 2: What Kismet lists

BTLE devices appear in the device list under the phy `BTLE`, and Kismet logs each new one, with its name when it has one:

```text
INFO: Detected new BTLE device C6:00:00:C5:E5:5A ESP32C5-FAKE
```

(That one is the demo's fake advertiser; see [Try It Without Hardware](Try-It-Without-Hardware).) <!-- VERIFY: the "Detected new BTLE device <address> <name>" line format, read from Kismet's phy_btle.cc -->

For each device, Kismet keeps:

| What | Where it comes from |
|---|---|
| Address | The advertiser's address. Many devices use random addresses and change them from time to time, so one device can show up as several over a session |
| Manufacturer | For a public address, the vendor of its first three bytes, from Kismet's manufacturer list. For a random address, `Randomized` |
| Name | The advertised complete local name, when the device sends one |
| Signal | In dBm, from the scan report |
| Channel | Always 37 (2402 MHz). It is a label: the scan report does not say which of the three channels an advertisement came on |
| PDU type | Connectable (`ADV_IND`), directed, non-connectable or scannable |
| Discovery and BR/EDR flags | From the advertisement's flags: limited or general discoverable, and whether the device also does Bluetooth Classic |
| Manufacturer data and service UUIDs | Decoded from the advertisement; see step 3 |

<!-- VERIFY: the manufacturer, "Randomized", PDU type and flags fields in Kismet's device list and device details (read from Kismet's phy_btle.cc and kismet.ui.btle.js at cfe427074, not seen in a run) -->

What the test runs saw, with pre-release builds of the helpers:

| Setup | Time | Source packets | BTLE devices | With a name |
|---|---|---|---|---|
| Raspberry Pi 4, local source | 150 s | 2969 | 17–18 | 2 |
| Raspberry Pi 4, Python remote helper | 75 s | 1274 | 15 | 1 |
| Windows 11, Python remote helper, Kismet in WSL2 | about 3 min | 3443 | 16 | 1 |

Most were random addresses; the public ones included Samsung and LG Innotek devices. Kismet counted 0 error packets. Few devices had a name. A device that names itself only in a scan response shows up without one, because a passive scan never asks for a scan response.

## Step 3: Names and manufacturer data

Kismet reads the data inside each advertisement:

- **Name:** the *complete local name* field. A device that sends only a shortened name, or names itself only in a scan response, shows up without one. <!-- VERIFY: Kismet at cfe427074 stores only AD type 0x09 (complete local name), not 0x08 (shortened) -->
- **Manufacturer data:** the company identifier assigned by the Bluetooth SIG (four hex digits) and the rest of the data as hex.
- **Service UUIDs:** the 16-, 32- and 128-bit service UUIDs the device advertises.

Kismet at the commit this project builds keeps the manufacturer data and the service UUIDs in each device's record; they are in the REST API and in the log's device records. This lists every BTLE device with its name, manufacturer, company identifier, manufacturer data and service UUIDs:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/devices/views/all/devices.json \
  | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d.get("kismet.device.base.phyname") != "BTLE":
        continue
    b = d.get("btle.device", {})
    print(d["kismet.device.base.macaddr"], repr(d.get("kismet.device.base.name", "")), d.get("kismet.device.base.manuf", ""),
          b.get("btle.device.manuf_company_id", ""), b.get("btle.device.manuf_data", ""),
          ",".join(b.get("btle.device.service_uuid_vec") or []))
'
```

<!-- VERIFY: run this against a real BTLE capture; field names read from Kismet's phy_btle.h and devicetracker_component.cc at cfe427074 -->

Kismet keeps the latest name and manufacturer data per device, and collects the service UUIDs. For every advertisement in full, open the capture in Wireshark ([Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark)): the log keeps every packet, and Wireshark shows each one field by field. <!-- VERIFY: what Wireshark decodes inside the advertising data of these captures (AD structures, manufacturer data such as iBeacon); only CRC acceptance by its btle dissector is established -->

## Step 4: Know the limits

**Device counts stay low, by design.** Kismet marks a packet as a duplicate when its bytes match one of the last 1024 unique packets it saw, and an advertiser repeats the same advertisement on all three channels and at every interval. A duplicate never updates a BTLE device, so its packet count, last-seen time and signal stop after the first few packets and move again only when the advertisement changes. On the test Pi, 17–18 devices showed only 1–3 packets each while the source counted about 20 packets a second, and Kismet counted 87 duplicates in the last second. In the Windows test (the Python remote helper, Kismet in WSL2), 1094 of 1099 packets over one minute were duplicates. Nothing in Kismet's configuration turns this off.

To see the real rate:

- the **Data Sources** panel counts every packet the board delivered;
- `GET /packetchain/packet_stats.json` gives Kismet's duplicate rate;
- the kismetdb and pcapng logs keep duplicates by default.

**Every packet is on channel 37.** That is a label, not a measurement. You cannot tell from the capture which advertising channel a packet came on.

**Random addresses rotate.** A phone can appear as several devices over a session. To hide every random-address device from Kismet's device list, add `btle_ignore_random=true` to `kismet_site.conf`; their packets are still logged.

**The recorded CRC is computed, not received.** The firmware rebuilds each packet from the scan report and computes its CRC. For BLE 5 devices that set the ChSel bit in `ADV_IND` or `ADV_DIRECT_IND`, the recorded header byte and CRC differ from what was sent. [Bluetooth LE Capture](Bluetooth-LE-Capture) has the details.

## Step 5: Run it alongside Wi-Fi boards

A BTLE board and Wi-Fi boards can feed the same Kismet, each board on its own radio:

```bash
~/kismet-install/bin/kismet --no-ncurses \
    -c 'esp32c5-ttyACM0:name=wifi-a' \
    -c 'esp32c5-ttyACM1:name=wifi-b' \
    -c 'esp32c5btle-ttyACM2:name=c5-btle'
```

Or, to keep them, in `~/kismet-install/etc/kismet_site.conf`, by the boards' stable names (`ls -l /dev/serial/by-id/`; change the MACs to yours):

```ini
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=wifi,name=wifi-b
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:05-if00,mode=btle,name=c5-btle
```

- Kismet splits channels only between sources with the same channel list. The two Wi-Fi boards share the Wi-Fi channels; the BTLE board keeps its single channel and is left alone.
- A board listens with one radio at a time, so each radio needs its own board. A second source on a board already in use fails with `... is already in use by another capture ...`.
- Use a powered USB hub for three or more boards ([Hardware](Hardware)).
- Tested: a Wi-Fi board and a BTLE board together, both as local sources on the Pi and through the Python remote helper. Two Wi-Fi boards, a Zigbee board and a BTLE board at once have not been run. <!-- VERIFY: run two Wi-Fi, one Zigbee and one BTLE board at once on the rebuilt Pi -->

With boards on a Windows PC, the same mix goes through the Python remote helper with one `--source` per board, for example `--source esp32c5-COM14 --source esp32c5btle-COM15`. See [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi).

## See also

- [Bluetooth LE Capture](Bluetooth-LE-Capture): the BLE radio in detail
- [Multiple Boards](Multiple-Boards): mixing radios on one Kismet
- [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey): the Wi-Fi side of a combined survey
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf`, logging and filters
