This guide surveys Bluetooth LE advertisers with an ESP32-C5 board in Kismet: start a BTLE source, read what Kismet lists for each device, get at names and manufacturer data, understand the limits, and run the BLE board alongside Wi-Fi boards. It assumes a working setup from [Guide: First Capture](Guide-First-Capture).

> **Warning:** Only capture on networks and devices you own or are authorised to test. The board scans passively and never transmits, but advertisements identify people's phones, watches and trackers, and recording them can still be against the law where you are.

## What you need

| | |
|---|---|
| Board | One ESP32-C5 board with this project's firmware ([Flashing the Firmware](Flashing-the-Firmware)) |
| Kismet | Built with the ESP32-C5 source, or the Docker image |
| Tested | A Raspberry Pi 4 with a local BTLE source and with both remote helpers; a Windows 11 PC with the Python remote helper |

The examples use Kismet in `~/kismet-install`, the login `admin` / `choose-a-long-password`, and the board on `/dev/ttyACM0`. Change them to yours.

## What the board hears

- **Advertising only.** The ESP32-C5 runs a passive Bluetooth LE scan: it hears what devices broadcast before anyone connects to them (`ADV_IND`, `ADV_DIRECT_IND`, `ADV_NONCONN_IND`, `ADV_SCAN_IND`), not connections, and it has no Bluetooth Classic.
- **All three advertising channels at once.** The controller scans channels 37, 38 and 39 together and cannot be limited to one, so there is no channel to choose and nothing to hop.
- **Every repeat.** The board passes on every advertisement it hears, not one per device.
- **No BLE 5 extended advertising.** The firmware is built without extended scanning, and it drops any report with more than 31 bytes of advertising data. In 12,695 packets from six captures on the test Pi, every one was `ADV_IND` or `ADV_NONCONN_IND` with at most 31 bytes of data, though no known extended advertiser was nearby to prove the point.

[Bluetooth LE Capture](Bluetooth-LE-Capture) explains each of these.

## Step 1: Start a BTLE source

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5btle-ttyACM0:name=c5-btle'
```

`btle` between `esp32c5` and the `-` picks the Bluetooth LE radio; `ble` and `bluetooth` mean the same. Look for:

```text
INFO: c5-btle capturing (btle)
```

If the board last used another radio, it reboots into BLE first, which adds about a second. The source's channel list holds only `37`. The **Lock** and **Hop** buttons in **Data Sources** and the channel REST calls are accepted and change nothing: a set to 38 or 39 shows as 37. A set to any other channel is refused with a line such as `c5-btle cannot tune to channel 40 in btle mode` in Kismet's log, and the source goes on capturing.

A board can stall on a radio switch. In the tests, switches made after a capture went through every time from Wi-Fi to BLE (80 of 80, on four boards with both helpers) and all but once back to Wi-Fi (79 of 80). At a fresh Kismet start with mixed radios, where several boards switch at once, one board (the same one each time, on one hub port) dropped off USB in 25 of 25 tries, and in 3 of them it came back silent: all 3 under the C helper, against none of 9 under the Python remote helper, too few to tell the helpers apart. The other three boards never dropped off in those tests. A silent board makes the helper give up after 15 s with `c5-btle: no capture from the board on /dev/ttyACM0 for 15 seconds; ...` in Kismet's log, and Kismet's retries do not bring it back. Unplug the board and plug it in again; an esptool reset cures it too. The cause is not known: it may be the firmware, or the power on that hub port while several boards restart at once.

Boards flashed with the sibling project's firmware 1.2.0 leave the CRC of each BLE packet empty. The helper then fills it in and says so once each time the source opens (for a remote helper, once per connection), in a Kismet message: `c5-btle: the board's firmware does not mark BTLE packets as CRC checked, ...`. Capture works, but flash the current firmware when you can.

## Step 2: What Kismet lists

BTLE devices appear in the device list under the phy `BTLE`, and Kismet logs each new one, with its name when it has one:

```text
INFO: Detected new BTLE device C6:00:00:C5:E5:5A ESP32C5-FAKE
```

(That one is the demo's fake advertiser; see [Try It Without Hardware](Try-It-Without-Hardware).) A device without a name gets the line without one, such as `INFO: Detected new BTLE device 45:B5:16:79:64:24`.

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

These fields were checked in Kismet's REST API on the test Pi; how the web UI's device details lay them out was not looked at in a browser.

What the test runs saw, with pre-release builds of the helpers:

| Setup | Time | Source packets | BTLE devices | With a name |
|---|---|---|---|---|
| Raspberry Pi 4, local source | 150 s | 2969 | 17–18 | 2 |
| Raspberry Pi 4, Python remote helper | 75 s | 1274 | 15 | 1 |
| Windows 11, Python remote helper, Kismet in WSL2 | about 3 min | 3443 | 16 | 1 |

Most were random addresses; the public ones included Samsung and LG Innotek devices. Kismet counted 0 error packets. Few devices had a name. A device that names itself only in a scan response shows up without one, because a passive scan never asks for a scan response.

## Step 3: Names and manufacturer data

Kismet reads the data inside each advertisement:

- **Name:** the *complete local name* field. A device that sends only a shortened name, or names itself only in a scan response, shows up without one: Kismet keeps only the complete name (AD type `0x09`) and ignores the shortened one (`0x08`).
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

On the test Pi a row read like `45:B5:16:79:64:24 '' Randomized 0075 021861b1... ` (company `0075` is Samsung), with any service UUIDs, such as `fd5a`, at the end.

Kismet keeps the latest name and manufacturer data per device, and collects the service UUIDs. For every advertisement in full, open the capture in Wireshark ([Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark)): the log keeps every packet, and Wireshark decodes each advertisement's data structure by structure: the flags, the name, service UUIDs, and manufacturer data as the company's name and the rest in hex. Wireshark 4.2 does not take an iBeacon apart any further. (Checked with Wireshark 4.2 on packets in this firmware's format made by the project's simulated board, not on a capture from a real board.)

## Step 4: Know the limits

**Device counts stay low, by design.** Kismet marks a packet as a duplicate when its bytes match one of the last 1024 unique packets it saw, and an advertiser repeats the same advertisement on all three channels and at every interval. A duplicate never updates a BTLE device, so its packet count, last-seen time and signal stay at the first packet and move again only when the advertisement's bytes change. Kismet's list of 1024 packets moves on only as new, different packets arrive, which with Bluetooth LE alone can take hours. On the test Pi, in 180 s, the source delivered 3882 packets, but 15 of the 16 devices stayed at 1 packet (the other reached 2), and every device's last-seen time was still its first-seen time. In an earlier run, Kismet counted 87 duplicates in one second. In the Windows test (the Python remote helper, Kismet in WSL2), 1094 of 1099 packets over one minute were duplicates. Nothing in Kismet's configuration turns this off.

To see the real rate:

- the **Data Sources** panel counts every packet the board delivered;
- `GET /packetchain/packet_stats.json` gives Kismet's duplicate rate;
- the kismetdb and pcapng logs keep duplicates by default.

**Every packet is on channel 37.** That is a label, not a measurement. You cannot tell from the capture which advertising channel a packet came on. In the kismetdb log, the packets table has frequency 0 for every BTLE packet, whatever the helper sends (a limit of Kismet's); the devices carry the right frequency, 2402000 kHz.

**Some advertisers never become devices.** Kismet cannot read advertising data that ends in zero bytes of padding: it drops the advertisement without a message, so the advertiser never appears in the device list, although its packets are in the kismetdb and pcapng logs. On the test Pi, 3 of 19 advertisers were missing for this reason.

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
- Tested on the Pi: two Wi-Fi boards, a Zigbee board and a BTLE board at once. On 2026-10-02 (firmware image 01a50bd6) this ran for 60 s as local sources and through one Python remote helper process: the BTLE board delivered about 1000 packets, and Kismet listed 13 to 14 BTLE devices. Earlier builds of the helpers also ran it through four C remote helpers, and for 10 minutes through the Python helper. No source had an error, apart from three runs in which the BTLE board stalled on its switch from Wi-Fi, as described in step 1: the first local run on 2026-10-02 (its repeat was clean), and with the earlier helpers one local run and one through the C remote helpers.

With boards on a Windows PC, the same mix goes through the Python remote helper with one `--source` per board, for example `--source esp32c5-COM14 --source esp32c5btle-COM15`. See [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi).

## See also

- [Bluetooth LE Capture](Bluetooth-LE-Capture): the BLE radio in detail
- [Multiple Boards](Multiple-Boards): mixing radios on one Kismet
- [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey): the Wi-Fi side of a combined survey
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf`, logging and filters
