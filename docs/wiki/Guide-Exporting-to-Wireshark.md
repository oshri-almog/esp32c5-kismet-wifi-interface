This guide gets the packets your ESP32-C5 boards captured out of Kismet and into Wireshark: what Kismet logs, how to add a pcapng log, how to convert a Kismet log afterwards, how to pull packets from a running Kismet, and what each radio looks like in Wireshark. It ends with the sibling project for live capture straight into Wireshark. It is for anyone who wants to look inside the frames that Kismet only summarises.

> **Note:** Only capture on networks and devices you own or are authorised to test. An exported capture holds other people's frames and device addresses; treat the file accordingly.

## Choose a way

| Way | When | Tested |
|---|---|---|
| [Add a pcapng log](#1-add-a-pcapng-log) | You know before capturing that you want Wireshark files | No <!-- VERIFY: a pcapng log with Wi-Fi, 802.15.4 and BTLE sources, opened in Wireshark --> |
| [Convert the Kismet log afterwards](#2-convert-a-kismet-log-with-kismetdb_to_pcap) | You have a `.kismet` file from an earlier run | No <!-- VERIFY: kismetdb_to_pcap on a log with the three radios --> |
| [Pull packets from a running Kismet](#3-pull-packets-from-a-running-kismet) | Kismet is running and you want some or all of its packets now | The live stream, yes: its 802.15.4 frames were checked |
| [Capture live in Wireshark instead](#live-in-wireshark-without-kismet) | You want Wireshark, not Kismet | In the sibling project |

The examples use Kismet in `~/kismet-install`, logs in `~/kismet-logs`, and the login `admin` / `choose-a-long-password`. Change them to yours.

## What Kismet writes by default

Kismet's default is one log per run, in its own format, called kismetdb:

- **Name:** `Kismet-20260928-14-03-22-1.kismet`: the log title, the date and time the run started, in **UTC**, and a number. `log_title=` or `-t` changes the first part.
- **Place:** the directory in `log_prefix`. Kismet's default is the directory it was started in. The Docker image sets `/data/`, which is the `kismet-data` volume.
- **Content:** an SQLite database with every packet, the devices, the sources, Kismet's messages and alerts. Duplicate packets are kept.
- While it is open, Kismet commits to it every 10 s, and a `-journal` file sits next to it. A clean stop removes the journal. After a crash or a power cut, the last few seconds may be lost and the journal stays; `kismetdb_clean -i <file>` cleans it up.

Kismet writes no pcap or pcapng file unless you ask for one.

## 1. Add a pcapng log

Add this line to `kismet_site.conf` (for the home-directory install, `~/kismet-install/etc/kismet_site.conf`):

```ini
log_types+=pcapng
```

Write `+=`: in `kismet_site.conf` a plain `log_types=pcapng` replaces Kismet's default instead of adding to it, and the `.kismet` log would stop. For one run only, give the list on the command line instead:

```bash
~/kismet-install/bin/kismet --no-ncurses -T kismet,pcapng -c 'esp32c5-ttyACM0:name=wifi-a'
```

Kismet logs `Opened pcapng log file '...'` and writes `Kismet-<date>-<time>-1.pcapng` next to the `.kismet` file. In the pcapng file each source is its own interface, with its own link type, so one file holds Wi-Fi, 802.15.4 and Bluetooth LE together, and Wireshark opens it directly.

Options for this log, also in `kismet_site.conf`:

| Option | Default | Meaning |
|---|---|---|
| `pcapng_log_max_mb` | `0` (no limit) | Start a new file when this one reaches the size; Kismet logs `Rotating to new pcapng log ...` |
| `pcapng_log_duplicate_packets` | `true` | Keep packets Kismet marks as duplicates. Leave it on for BLE, where most packets are repeats |
| `pcapng_log_data_packets` | `true` | Keep data frames |

With Docker, put the line in your own `kismet_site.conf`, mounted over the image's, and keep the image's `log_prefix=/data/` in it. [Docker Reference](Docker-Reference) shows how. <!-- VERIFY: mounting a kismet_site.conf into the container, not tried -->

## 2. Convert a Kismet log with kismetdb_to_pcap

Kismet installs `kismetdb_to_pcap` next to `kismet` (`~/kismet-install/bin/`), and the Docker image has it too. It writes pcapng by default.

> **Warning:** `kismetdb_to_pcap` and Kismet's other log tools first clean up (SQLite `VACUUM`) the database you give them, which writes to it. Do not run them on the log of a Kismet that is still running. Stop Kismet first, or work on a copy.

1. See which sources the log holds:

   ```bash
   cd ~/kismet-logs
   ~/kismet-install/bin/kismetdb_to_pcap -i Kismet-20260928-14-03-22-1.kismet --list-datasources
   ```

2. Convert everything into one pcapng file:

   ```bash
   ~/kismet-install/bin/kismetdb_to_pcap -i Kismet-20260928-14-03-22-1.kismet -o capture.pcapng
   ```

   Change the file name to your log's. Add `-f` to overwrite an existing output file.

<!-- VERIFY: both commands against a real log of this project's sources (read from the tool's help text, not run) -->

Useful options:

| Option | Does |
|---|---|
| `--datasource <uuid>` | Only this source's packets. Repeat it for several. A board's UUID starts `E5C50001` (Wi-Fi), `E5C50002` (802.15.4) or `E5C50003` (BLE) and ends with its MAC |
| `--split-datasource` | One file per source, named `<out>-<uuid>` |
| `--split-packets <n>`, `--split-size <kb>` | Several smaller files, named `<out>-0001`, `<out>-0002` … |
| `--old-pcap` | A classic `.pcap` file instead of pcapng. A pcap file has one link type, so pick sources of one radio with `--datasource`, or one link type with `--dlt <n>` |
| `-s` | Skip the clean-up step (see the warning above) |

For example, only the Wi-Fi board, as classic pcap:

```bash
~/kismet-install/bin/kismetdb_to_pcap -i Kismet-20260928-14-03-22-1.kismet -o wifi.pcap --old-pcap --datasource E5C50001-0000-0000-0000-F0F5BD010203
```

**In Docker,** run the tool inside the `kismet` container on a log from an earlier run, then copy the result out. The logs are in `/data`:

```bash
sudo docker compose exec kismet ls /data
sudo docker compose exec kismet kismetdb_to_pcap -i /data/Kismet-20260928-14-03-22-1.kismet -o /data/capture.pcapng
sudo docker compose cp kismet:/data/capture.pcapng .
```

<!-- VERIFY: these three docker compose commands -->

Kismet's other log tools, in the same place:

| Tool | Does |
|---|---|
| `kismetdb_statistics -i <log>` | A summary of the log |
| `kismetdb_dump_devices -i <log> -o devices.json` | Every device record as JSON |
| `kismetdb_to_wiglecsv -i <log> -o <file>.csv` | A WiGLE CSV file |
| `kismetdb_strip_packets -i <log> -o <new log>` | A copy of the log without the packet contents, for sharing device lists |
| `kismetdb_clean -i <log>` | Cleans up a log left with a journal after a crash |

[Command-Line Reference](Command-Line-Reference) lists their options.

## 3. Pull packets from a running Kismet

Kismet's REST API can hand you pcapng without stopping it. These calls need the admin login or a key with the `readonly` role; a `datasource` key is refused.

**Everything from now on, as a stream.** This writes every packet from every source until you press Ctrl+C:

```bash
curl -s -u admin:choose-a-long-password -o live.pcapng http://localhost:2501/pcap/all_packets.pcapng
```

In the test run this stream held the 802.15.4 frames as link type 230, with the expected addresses and payload. For one source only, use its UUID (listed in `/datasource/all_sources.json`):

```bash
curl -s -u admin:choose-a-long-password -o wifi-a.pcapng http://localhost:2501/datasource/pcap/by-uuid/E5C50001-0000-0000-0000-F0F5BD010203/packets.pcapng
```

To watch the stream in Wireshark as it arrives, pipe it in:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/pcap/all_packets.pcapng | wireshark -k -i -
```

<!-- VERIFY: piping /pcap/all_packets.pcapng into Wireshark -->

**Packets already in the open log.** This exports from the kismetdb that Kismet is writing, safely, through Kismet itself:

```bash
curl -s -u admin:choose-a-long-password -o survey.pcapng http://localhost:2501/logging/kismetdb/pcap/survey.pcapng
```

It takes optional filters as query parameters, such as `timestamp_start`, `timestamp_end`, `datasource` and `dlt`. <!-- VERIFY: the /logging/kismetdb/pcap export without and with filters, and the meaning of each filter (read from Kismet's code, not run) -->

Change `localhost` to the Kismet machine's address when you run these from another computer.

## Open it in Wireshark

Open the file with **File → Open**. Each radio arrives with its own link type:

| Radio | Link type in the file | What Wireshark shows |
|---|---|---|
| Wi-Fi | 127, IEEE 802.11 with radiotap | Every 802.11 frame with its radiotap header: channel frequency, band, signal and noise in dBm. No data rate, MCS or channel width. The FCS has been removed |
| Zigbee and Thread (802.15.4) | 230, IEEE 802.15.4 without FCS | The 802.15.4 MAC frame and whatever Wireshark decodes above it. No FCS (the radio checks it in hardware), and no per-frame channel or signal: those went to Kismet beside the frame, not in it |
| Bluetooth LE | 256, Bluetooth LE link layer with the radio pseudo-header | Each advertisement with its signal, channel 37 as a label for all three advertising channels, the "CRC checked" and "CRC valid" flags, and the advertising data decoded: names, manufacturer data, service UUIDs |

<!-- VERIFY: the link types of Wi-Fi (127) and BTLE (256) in Kismet's pcapng output and in kismetdb_to_pcap output (only 230 for 802.15.4 was checked); whether per-frame channel/signal of 802.15.4 frames appears anywhere in Kismet's pcapng -->

Notes per radio:

- **Wi-Fi.** Wireshark may mark some frames as malformed. The Wi-Fi driver reports some MIMO frames with metadata that does not match the payload; it is not a broken capture, and how often it happens with this firmware has not been measured. [Wi-Fi Capture](Wi-Fi-Capture) has the details.
- **Zigbee.** Traffic above the network layer is encrypted. Give Wireshark the network key under *Preferences → Protocols → ZigBee → Pre-configured Keys*. <!-- VERIFY: Wireshark preference path for the ZigBee network key -->
- **Thread.** Its frames are protected with keys derived from the Thread network key, which Wireshark needs as well. <!-- VERIFY: the Wireshark preference that takes a Thread network key --> [Guide: Zigbee and Thread Networks](Guide-Zigbee-and-Thread-Networks) has more.
- **Bluetooth LE.** The files keep every repeat of every advertisement, including the ones Kismet counted as duplicates. For BLE 5 devices that set the ChSel bit, the header byte and CRC in the file differ from what was sent; see [Bluetooth LE Capture](Bluetooth-LE-Capture).
- **Timestamps.** For a board plugged into the Kismet machine, the time is the board's own clock, set to the computer's clock when the capture starts. For a remote source, Kismet replaces it with the time the packet arrived, unless the source has `timestamp=false`.

## Live in Wireshark, without Kismet

If you want Wireshark rather than Kismet, the sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) makes each board an ordinary Wireshark capture interface. It runs the same firmware family and speaks the same line protocol, so a board flashed for one project is expected to work with the other; neither direction has been tried on a real board yet. <!-- VERIFY: a board on the Wireshark project's 1.2.0 firmware syncs and captures all three radios under the final helpers, and a board on this project's firmware captures in the Wireshark project's extcap -->

| | This project (Kismet) | esp32c5-wireshark-sniffer (Wireshark) |
|---|---|---|
| What you get | Kismet's device list, logs, REST API, remote capture | Frames live in Wireshark, several boards merged into one capture |
| Channels | Kismet hops the boards and splits the channels between them | You pick channels from a list, and change them mid-capture from a toolbar |
| 802.15.4 | Link type 230; channel and signal go to Kismet beside the frame | The full 802.15.4 TAP header: channel, RSSI, LQI and a timestamp on every frame |
| BLE CRC | Computed by this project's firmware, flags "CRC checked" and "CRC valid" | The sibling's firmware 1.2.0 leaves the CRC empty and the flags clear |

- A board serves one program at a time. Stop Kismet's source, or the helper, before Wireshark opens the board, and the other way round.
- The sibling's firmware 1.2.0 works under Kismet too: the helpers fill in the BLE CRC it leaves empty. This project's firmware in Wireshark should show BLE packets with the CRC flags set, which the sibling's own README does not describe. <!-- VERIFY: a board with this project's firmware captured through the sibling's Wireshark extcap, BLE included -->

## See also

- [Kismet Configuration](Kismet-Configuration): logging options and `kismet_site.conf`
- [Command-Line Reference](Command-Line-Reference): Kismet's `-T`, `-t`, `-p` and the log tools
- [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey) and [Guide: BLE Advertising Survey](Guide-BLE-Advertising-Survey): surveys to export
- [Docker Reference](Docker-Reference): where the container keeps its logs
