This page covers capturing IEEE 802.15.4 with an ESP32-C5 board: the radio under Zigbee and Thread. It explains what Kismet decodes, how channel and signal reach it, when to hop and when to lock a channel, and how to prove the receive path with a second board. It is for anyone running a Zigbee/Thread source.

> **Warning:** Only capture on networks and devices you own or are authorised to test. The board only listens, except when you send it the `TXTEST` command described below, which makes it transmit.

## At a glance

| | |
|---|---|
| Channels | 11–26 (16 channels, 2.4 GHz band, channel page 0) |
| Frequency | 2405 + 5 × (channel − 11) MHz: channel 11 is 2405 MHz, channel 26 is 2480 MHz |
| What is captured | every IEEE 802.15.4 frame the radio receives: Zigbee, Thread, and anything else on 802.15.4 |
| Metadata Kismet gets | channel, frequency and signal strength (dBm) |
| From the board | link type 283 (IEEE 802.15.4 TAP) |
| To Kismet | link type 230 (IEEE 802.15.4 without FCS), with channel and signal alongside |
| Kismet phy | `802.15.4` |
| Start channel | 15 |
| Transmits | only on `TXTEST` |

## Start a Zigbee/Thread source

The radio is chosen by the word between `esp32c5` and the `-`, or by `mode=`. `zigbee`, `802154`, `802.15.4` and `thread` all mean the same radio. There is no separate Thread mode, because Zigbee and Thread both run on 802.15.4.

| Where the board is | Source definition |
|---|---|
| Linux, `/dev/ttyACM0` | `esp32c5zigbee-ttyACM0` |
| The same, with `mode=` | `esp32c5-ttyACM0:mode=zigbee` |
| Windows `COM14`, through the Python remote helper | `esp32c5zigbee-COM14` |

To start Kismet with one Zigbee/Thread source, run this and change `ttyACM0` to your board's port:

```bash
kismet -c esp32c5zigbee-ttyACM0
```

The first time, the board reboots from Wi-Fi into 802.15.4; the reboot itself takes about 0.5 s. In the test runs a source was capturing about 1.5 s after Kismet launched it when the board had to switch, and 1 to 1.5 s when it was already on 802.15.4: the helper always sends the board its radio first and waits 0.8 s before it starts the capture. The board then remembers 802.15.4 until a source asks for another radio. See [Source Definitions](Source-Definitions) for every form of the name.

## What Kismet decodes

Kismet's 802.15.4 support reads the MAC header of each frame:

- the frame type: beacon, data, acknowledgement or MAC command;
- the source and destination addresses, short (16-bit, shown like `00:01`) or extended (64-bit);
- whether MAC-layer security is on. Kismet shows such frames as encrypted.

It creates one 802.15.4 device per address and records the channel, frequency and signal it was seen on. In the `TXTEST` run described further down, Kismet logged `Detected new 802.15.4 device 00:01` and `Detected new 802.15.4 device FF:FF`. It showed device `00:01` with 200 packets sent on channel 20 at 2450 MHz, and `FF:FF`, the broadcast address, with 200 received.

Kismet does **not** decode above the MAC layer: no Zigbee network or application layer, no Thread, 6LoWPAN or IPv6, and no PAN ID (its 802.15.4 device record has no PAN field). To read those, export the capture and open it in Wireshark; see [Exporting to Wireshark](Guide-Exporting-to-Wireshark).

## Why the helper rewraps the TAP header

The board wraps each frame in an IEEE 802.15.4 TAP header of 48 bytes, with five fields:

| TAP field | Content |
|---|---|
| FCS type | none: see below |
| RSS | the received signal strength in dBm |
| Channel assignment | the channel (11–26) and channel page 0 |
| LQI | the radio's link quality indicator |
| Start-of-frame timestamp | the radio's own clock, in nanoseconds |

Kismet can read TAP, but it assumes a fixed 28-byte header with three fields in fixed places. It would misread the board's longer header. The channel would come out right, but the signal would not: the board sends it as a floating-point number, and Kismet reads those bytes as an integer. And Kismet would take the LQI and timestamp fields that follow as the start of the frame. So the helper (both the C helper and the Python remote helper):

1. walks the TAP fields and takes the channel and the RSS;
2. sends Kismet the bare MAC frame as link type 230, "802.15.4 without FCS";
3. puts the channel, the frequency (2405 + 5 × (channel − 11) MHz) and the signal, rounded to a whole dBm, beside it.

LQI and the start-of-frame timestamp are not passed on. A header that does not parse, or names a channel outside 11–26, is dropped and counted. Kismet's messages then show a line like `c5-zigbee: 1 802.15.4 frames with a malformed TAP header dropped`, at the first drop and every 1000th.

**There is no FCS in the capture.** The radio checks each frame's FCS in hardware and then overwrites those two bytes with the RSSI and LQI, so the firmware never has the FCS to pass on. That is why the TAP header says "FCS type: none", and why Kismet gets link type 230 rather than a type that claims an FCS. Kismet's own pcapng output holds these frames as link type 230, as the test run confirmed.

## Signal and channel

- **Channel**: the channel the board was tuned to when the frame arrived, from the TAP header.
- **Frequency**: worked out from the channel, e.g. 2450 MHz for channel 20.
- **Signal**: the radio's RSSI in dBm, rounded. Between the four test boards, all on one USB hub, it read between −7 and +9 dBm. No noise figure is reported.
- **Kismet's kismetdb log** records the frequency of every 802.15.4 packet as 0, although the helpers send it. The device records have the right frequency. This is a limit of Kismet's 802.15.4 support.

| Channel | MHz | Channel | MHz |
|---|---|---|---|
| 11 | 2405 | 19 | 2445 |
| 12 | 2410 | 20 | 2450 |
| 13 | 2415 | 21 | 2455 |
| 14 | 2420 | 22 | 2460 |
| 15 | 2425 | 23 | 2465 |
| 16 | 2430 | 24 | 2470 |
| 17 | 2435 | 25 | 2475 |
| 18 | 2440 | 26 | 2480 |

## Hopping or locking a channel

By default Kismet hops the source over 11–26 at 5 channels per second: 200 ms on each channel, and 3.2 s for a full pass. The test runs saw exactly that: start on 15, then hop 11–26 at 5 per second.

A Zigbee or Thread network stays on one channel. Hopping is good for finding which channels are in use, but it misses most of a network's traffic, because the board spends only 200 ms of every 3.2 s pass, one sixteenth of the time, on that channel. The usual approach:

1. **Hop** for a few minutes and note the channel of the 802.15.4 devices that appear.
2. **Lock** the board on that channel.

Three ways to lock a channel:

- **In the source definition**, with `channel=` and `channel_hop=false` together:

  ```bash
  kismet -c 'esp32c5zigbee-ttyACM0:channel=20,channel_hop=false'
  ```

  `channel=` on its own does **not** lock the source: Kismet adds the channel to the hop list and keeps hopping. The helper refuses a channel the radio does not have, with `esp32c5zigbee-ttyACM0: channel=27 is not a channel the board can tune to in zigbee mode`. For a local source, Kismet shows only `Unable to find driver for '...'` unless the definition also has `type=esp32c5`; add it to see the reason. The Python remote helper stops at start-up with the message.
- **In the web UI**: *Data Sources* → the source → *Channel Options* → **Lock**, then click the channel under *Channels*.
- **Over the REST API**: `set_channel.cmd` with `{"channel":"20"}`. The test run locked a source this way and then received 200 of 200 test frames.

Details and the REST calls are on [Channel Control](Channel-Control). With two or more Zigbee boards, Kismet spreads them over the 11–26 list by itself, or you can lock each on its own channel. Mixing a locked board with hopping ones needs care; [Channel Control](Channel-Control) explains why. See also [Multiple Boards](Multiple-Boards) and the [Zigbee and Thread networks guide](Guide-Zigbee-and-Thread-Networks).

## Seeing nothing

A Zigbee/Thread source that shows **0 packets** usually means there is no 802.15.4 network in range. That is the expected result, not a fault. With nothing nearby, the test boards received 0 frames in 8 s on channel 15, and a hopping Kismet source counted 0 packets.

Check, in this order:

1. **Is there a network nearby?** A Zigbee hub, smart bulbs or sensors, or a Thread border router. A network that is idle may send little, so leave a locked source running for a while.
2. **Is the source capturing?** The source should be running in the *Data Sources* panel, and Kismet's messages should say it is capturing: `c5-zigbee capturing (zigbee)` for a source named `c5-zigbee`. For a remote source, from either remote helper, Kismet puts the source's name in front: `c5-zigbee - c5-zigbee capturing (zigbee)`.
3. **Is the firmware current?** A board flashed with the sibling project's oldest firmware (1.0.0) has no 802.15.4 radio and goes on answering in Wi-Fi's link type (127). Kismet's messages then show `<name>: lost sync (the board sends link type 127, not 283)`, never `capturing`, and after 15 s `<name>: no capture from the board on <device> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` (the Python remote helper adds what the board last said, as `(last: ...)` after `15 seconds`). For a local source, the source's error in Kismet reads only `IPC connection closed`, and Kismet re-opens it 5 s later, so the cycle repeats. Flash the current firmware: [Flashing the Firmware](Flashing-the-Firmware).
4. **Does the receive path work?** Prove it with a second board, below.

## Prove the receive path with TXTEST

`TXTEST` makes a board **transmit** 802.15.4 test frames, so a second board can show that it receives even when there is no Zigbee or Thread equipment around. It is the only command that makes the board transmit, and it works only in 802.15.4 mode.

Each test frame is:

| Field | Value |
|---|---|
| Frame type | data, PAN ID compression, short addresses (frame control `41 88`) |
| Sequence number | 0, 1, 2 … (the frame's index) |
| Destination | PAN `0x1234`, address `0xFFFF` (broadcast) |
| Source | address `0x0001` |
| Payload | `esp32c5-wireshark-sniffer self test` and a terminating zero byte. The text names the sibling project, where the firmware comes from. |
| Spacing | 20 ms apart, on the channel the board is on at that moment |

`TXTEST <n>` sends n frames, 1 to 1000. Anything else, or no number, sends 10.

You need two boards: **board A** as the Kismet source and **board B** as the transmitter. Board B must not be a Kismet source at the same time.

Step 2 runs the project's own Python code, which needs `pyserial`, on Linux as on Windows. On Windows, install the project's requirements once, from the repo root, with `python -m pip install -r requirements.txt`. On Debian, Raspberry Pi OS and Ubuntu, either install the distribution's pyserial with `sudo apt-get install -y python3-serial`, or use a virtual environment with the project's requirements, as [Remote Capture](Remote-Capture) shows, and write its Python, such as `.venv/bin/python`, in place of `python3` in step 2.

1. Start Kismet with board A locked on channel 20:

   ```bash
   kismet -c 'esp32c5zigbee-ttyACM0:channel=20,channel_hop=false'
   ```

2. In a second terminal, since Kismet keeps the first one, send board B three lines: `MODE 802154`, `CHANNELS 20`, `TXTEST 200`. Opening an ESP32-C5 port with a serial terminal's default settings can reset the board or leave it in download mode. So use the project's own port code, which holds the reset lines low. From the repo root, with board B on `/dev/ttyACM1`:

   ```bash
   python3 - /dev/ttyACM1 <<'EOF'
   import sys
   import time
   from esp32c5_kismet import board

   ser = board.open_serial(sys.argv[1])  # DTR and RTS stay low; refused if a source holds the board
   ser.write(b"MODE 802154\n")           # reboots the board if it is on another radio
   time.sleep(1.5)                       # the reboot takes about 0.5 s; anything sent meanwhile is lost
   ser.write(b"CHANNELS 20\n")           # one channel is a lock; the default 802.15.4 list hops 11-26
   time.sleep(0.5)                       # let the board retune before it transmits
   ser.write(b"TXTEST 200\n")            # 200 frames, 20 ms apart: about 4 s
   time.sleep(5)
   board.close_serial(ser)
   EOF
   ```

   The pause after `CHANNELS` matters: without it `TXTEST` can start before the board has left the channel it was on, and the first frames go out there.

   On Windows, save the lines between `<<'EOF'` and `EOF` as `txtest.py` in the repo root and run `python txtest.py COM15`, with board B's COM port. The script has been run as written on Linux; on Windows it has not been tried.

3. In Kismet, the source's packet count goes up by 200, and devices `00:01` and `FF:FF` appear on channel 20.

Send `TXTEST 200` again in the same Kismet session and the source's count goes up by another 200, but the devices' counts do not: the frames are the same as the first time, so Kismet takes them for duplicates.

In the test runs, board A locked with `channel=20,channel_hop=false` received **200 of 200** frames with each helper: the C helper started by Kismet, the C helper over `--connect`, and the Python remote helper. In the Python run the script above drove board B. Outside Kismet, all 12 pairings of the four test boards received 50 of 50.

The board sends no reply over USB to `TXTEST` or any other command except `START`. The result, `sent 200 test frames on channel 20` (or `transmit failed: ...`), appears only on the board's UART0 log port. That line shows the number requested even if sending stopped early.

If `open_serial` fails with `already in use`, board B is still a source in Kismet or open in another program. Close that first.

## Keys and encryption

Kismet records 802.15.4 frames as they are and decrypts nothing. When a frame's header says MAC-layer security is on, Kismet marks the devices involved as encrypted. It has no setting for Zigbee or Thread keys.

To read encrypted traffic, export the capture ([Exporting to Wireshark](Guide-Exporting-to-Wireshark)) and open it in Wireshark with the network's key:

- **Zigbee** traffic above the network layer is encrypted. Put the network key into Wireshark under *Preferences → Protocols → ZigBee → Pre-configured Keys*. "ZigBee" is Wireshark's name for the Zigbee network layer (display filter `zbee_nwk`), not "ZigBee APS" or "ZigBee Green Power".
  <!-- VERIFY: this preference path in the Wireshark GUI. Checked only with tshark 4.6.8 (the network layer's short name is "ZigBee", filter zbee_nwk, and its key table is registered as zigbee_pc_keys); the label "Pre-configured Keys" is recalled from Wireshark's source, not seen in the dialog -->
- **Thread** traffic is dissected by Wireshark as 6LoWPAN and IPv6. Frames protected with MAC-layer security, which Kismet marks as encrypted, need the Thread network key in Wireshark as well.
  <!-- VERIFY: where Wireshark takes a Thread network key, and how much Thread traffic it dissects without one (the sibling README says "Thread is dissected as 6LoWPAN and IPv6 without a key") -->

Decrypt only networks you are allowed to. Treat network keys, and captures that can be decrypted with them, as secrets.

## Limits

- **One channel at a time per board.** A network on another channel is invisible until the hop reaches it.
- **2.4 GHz only.** Channels 11–26, page 0. The sub-GHz 802.15.4 channels are not supported.
- **No FCS, no LQI and no PAN ID** in Kismet. The FCS is checked in hardware and never passed on.
- **Kismet decodes the MAC layer only.** Use Wireshark for Zigbee and Thread.
- **`TXTEST` is the only transmitter**, and it runs only when you send it.
- **Before you flash a board you used for Zigbee or Thread, put it back on Wi-Fi** (run a Wi-Fi source on it until it says `capturing`, or send `MODE WIFI`): a board flashed while in 802.15.4 mode can come up deaf to Wi-Fi, a known firmware issue. `MODE BLE` then `MODE WIFI` cures it ([Troubleshooting](Troubleshooting#a-board-that-ran-zigbee-captures-no-wi-fi)).

## See also

- [Zigbee and Thread networks guide](Guide-Zigbee-and-Thread-Networks)
- [Channel Control](Channel-Control)
- [Multiple Boards](Multiple-Boards)
- [Firmware Protocol](Firmware-Protocol): `MODE`, `CHANNELS` and `TXTEST` in full
- [Troubleshooting](Troubleshooting)
