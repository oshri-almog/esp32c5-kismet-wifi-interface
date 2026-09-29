This guide finds the IEEE 802.15.4 networks around you, the radio under Zigbee and Thread, with an ESP32-C5 board in Kismet: hop the 16 channels, spot where the traffic is, lock the board onto that channel, and prove the whole path with a second board. It is for anyone with a working Kismet setup ([Guide: First Capture](Guide-First-Capture)) who wants to look at Zigbee or Thread.

> **Warning:** Only capture on networks and devices you own or are authorised to test. The board only listens, except in step 4, where you tell a second board to transmit test frames.

## What you need

| | |
|---|---|
| One board | With this project's firmware ([Flashing the Firmware](Flashing-the-Firmware)), as the Kismet source |
| A second board | Only for step 4, the transmit test. It must not be a Kismet source at the same time |
| Kismet | Built with the ESP32-C5 source, or the Docker image |
| For step 4 | This project's files and pyserial on the machine the second board is plugged into |

The examples use Kismet in `~/kismet-install`, the login `admin` / `choose-a-long-password`, board A (the source) on `/dev/ttyACM0` and board B (the transmitter) on `/dev/ttyACM1`. Change them to yours.

## How the search works

Zigbee and Thread both run on IEEE 802.15.4, channels 11 to 26 in the 2.4 GHz band, and a network stays on one channel. The board listens on one channel at a time. So the search has two phases:

1. **Hop** over all 16 channels to find the ones in use. At Kismet's default 5 channels a second, one pass takes 3.2 s and each channel gets 200 ms of it, one sixteenth of the time.
2. **Lock** the board on the busy channel, so it hears all of that network's traffic instead of a sixteenth.

## Step 1: Start a hopping 802.15.4 source

```bash
mkdir -p ~/kismet-logs
cd ~/kismet-logs
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5zigbee-ttyACM0:name=c5-zigbee'
```

`zigbee` between `esp32c5` and the `-` picks the 802.15.4 radio; `802154`, `802.15.4` and `thread` mean the same. There is no separate Thread mode. <!-- VERIFY: the short form esp32c5zigbee-ttyACM0 on real hardware; the hardware runs used device= forms -->

Look for:

```text
INFO: c5-zigbee capturing (zigbee)
```

If the board last used another radio, it reboots into 802.15.4 first. On the test Pi, a source that had to switch was capturing about 1.5 s after launch, against 0.5 s for a board already on the radio. <!-- VERIFY: re-measure with the current helper, which waits 0.8 s after the radio switch --> The board then remembers 802.15.4 until a source asks for another radio.

The source starts on channel 15 and hops 11 to 26 at 5 channels a second, as the test runs showed.

## Step 2: Spot the activity

Give it a few minutes. A network that is idle sends little, and while hopping the board hears a given channel only 200 ms in every 3.2 s.

In the web UI (`http://192.168.1.50:2501`, with your Kismet machine's address), 802.15.4 devices appear in the device list with the channel they were heard on. Kismet also logs each one:

```text
INFO: Detected new 802.15.4 device 00:01
```

<!-- VERIFY: the exact "Detected new 802.15.4 device" line with a real network (seen in the TXTEST run) -->

What the addresses mean:

- Two bytes, such as `00:01`: a 16-bit short address.
- Eight bytes: a 64-bit extended address.
- `FF:FF`: the broadcast address. Kismet lists it as a device because frames are sent to it.

Kismet's 802.15.4 device record has no PAN ID, so Kismet cannot tell you which network a device belongs to. The channel is the useful clue here.

To list the 802.15.4 devices with their channel and packet count over the REST API:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/devices/views/all/devices.json \
  | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d.get("kismet.device.base.phyname") == "802.15.4":
        print(d["kismet.device.base.macaddr"], "channel", d.get("kismet.device.base.channel"), "packets", d.get("kismet.device.base.packets.total"))
'
```

<!-- VERIFY: run this one-liner against a real 802.15.4 capture -->

The channel with the most devices and packets is the one to lock onto.

**Seeing nothing** usually means there is no 802.15.4 network in range, not a fault. With no Zigbee or Thread equipment nearby, the test boards received 0 frames on channel 15, and a hopping source counted 0 packets. To be sure the board and Kismet work, run the test in step 4.

**Two boards find networks faster.** Two 802.15.4 sources with the same channel list are split by Kismet, each starting at a different point of 11 to 26. See [Multiple Boards](Multiple-Boards).

## Step 3: Lock onto the busy channel

The examples lock onto channel 20. Use the channel you found in step 2. There are three ways.

**In the source definition,** for the next start. `channel=` and `channel_hop=false` must go together: `channel=` on its own only adds the channel to the hop list, and Kismet keeps hopping.

```bash
~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5zigbee-ttyACM0:name=c5-zigbee,channel=20,channel_hop=false'
```

<!-- VERIFY: channel=20 with channel_hop=false keeps an 802.15.4 source on channel 20 on real hardware (fixed in both helpers after the last hardware run, which found it ignored) -->

A channel the radio does not have is refused before the board is touched, for example `channel=27`: `esp32c5zigbee-ttyACM0: channel=27 is not a channel the board can tune to in zigbee mode`. Without `type=esp32c5` in the definition, Kismet shows only `Unable to find driver for ...` for such a mistake; add it to see the reason.

To keep the lock across restarts, put the same definition in `~/kismet-install/etc/kismet_site.conf` as `source=esp32c5zigbee-ttyACM0:name=c5-zigbee,channel=20,channel_hop=false`, and start Kismet without `-c`.

**In the web UI,** while Kismet runs: open **Data Sources**, expand the source, and under **Channel Options** press **Lock**. That locks the source on the first channel of its list; then click the channel you want among the channel buttons. **Hop** goes back to hopping. <!-- VERIFY: the Lock / channel-button sequence in Kismet's Data Sources panel with an esp32c5 source -->

**Over the REST API,** which is how the test run locked its source. Find the source's UUID:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/datasource/all_sources.json \
  | python3 -c 'import json,sys; [print(s["kismet.datasource.name"], s["kismet.datasource.uuid"], s["kismet.datasource.channel"], s["kismet.datasource.hopping"]) for s in json.load(sys.stdin)]'
```

An 802.15.4 source's UUID starts with `E5C50002` and ends with the board's MAC. Lock it:

```bash
curl -s -u admin:choose-a-long-password --data-urlencode 'json={"channel":"20"}' http://localhost:2501/datasource/by-uuid/E5C50002-0000-0000-0000-F0F5BD010203/set_channel.cmd
```

The channel is a string, `"20"`, not a number. Kismet logs `Source 'c5-zigbee' (...) setting channel 20`. To hop again:

```bash
curl -s -u admin:choose-a-long-password http://localhost:2501/datasource/by-uuid/E5C50002-0000-0000-0000-F0F5BD010203/set_hop.cmd
```

Run the UUID one-liner again to check: a locked source shows channel `20` and hopping `0`. [Channel Control](Channel-Control) has the other channel calls.

## Step 4: Prove the setup with a second board

When step 2 shows nothing, you cannot tell "no network nearby" from "something is broken". The firmware's `TXTEST` command settles it: it makes a board **transmit** 802.15.4 test frames, and board A should receive every one.

> **Warning:** `TXTEST` is the only command that makes a board transmit, and it works only in 802.15.4 mode. Use it only where you are allowed to transmit on the 2.4 GHz band, on a channel that none of your own Zigbee or Thread networks uses, and with a small count. The frames are short broadcasts to a made-up network (PAN `0x1234`), 20 ms apart, for a few seconds.

What board B sends, `n` times:

| Field | Value |
|---|---|
| Frame | data frame, PAN ID compression, short addresses (frame control `41 88`) |
| Sequence number | 0, 1, 2 … |
| Destination | PAN `0x1234`, address `0xFFFF` (broadcast) |
| Source | address `0x0001` |
| Payload | `esp32c5-wireshark-sniffer self test` and a zero byte. The text names the sibling project the firmware comes from |

`TXTEST <n>` sends n frames, from 1 to 1000; anything else, or no number, sends 10.

1. **Lock board A on the test channel** as in step 3. The example uses channel 20. A board that hops would catch only about one frame in sixteen.

2. **Get the tools for board B.** The board has to be opened with its reset lines held low: on this USB port, DTR and RTS drive reset and boot mode, and a serial terminal with default settings can reboot the board or leave it in download mode. The project's `board.open_serial()` does it right, and takes the same port lock as the helpers. It needs pyserial. On Debian or Raspberry Pi OS:

   ```bash
   sudo apt-get install -y python3-serial
   ```

   Or use the virtual environment from the project's `requirements.txt`. <!-- VERIFY: python3-serial from apt is enough for "from esp32c5_kismet import board" (board.py imports only pyserial beyond the standard library) -->

3. **Send board B its commands.** The script imports the project's `esp32c5_kismet` package, which Python finds only from the project folder, so start there. With board B on `/dev/ttyACM1`:

   ```bash
   cd ~/esp32c5-kismet-wifi-interface
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

   <!-- VERIFY: this script as written against current firmware, on Linux and on Windows; the field tests used their own scripts -->

   The pause after `CHANNELS` matters: the firmware handles commands in a task with a higher priority than the one that changes channel, so without it `TXTEST` starts before the board has left the channel it was hopping on, and the first frame goes out there.

   Change `/dev/ttyACM1` and the channel to yours. On Windows, save the lines between `<<'EOF'` and `EOF` as `txtest.py` in the project folder and run `python txtest.py COM15`, with board B's COM port; pyserial comes with `python -m pip install -r requirements.txt`. If the script stops with `... is already in use by another capture ...`, board B is still a source in Kismet, or another program holds its port, such as a helper or esptool: close that first.

4. **Check board A.** Its packet count goes up by 200, and two 802.15.4 devices appear on channel 20: `00:01`, the sender, and `FF:FF`, the broadcast address. Two boards close together on a desk read between −7 and +9 dBm.

The test run did the same test, with the source locked over the REST API and board B driven by a script of its own: `TXTEST 200` from one board gave **200 of 200** packets in Kismet, with device `00:01` at 200 packets on channel 20 (2450 MHz). Outside Kismet, all 12 pairings of the four test boards received 50 of 50 frames each.

The board answers nothing over USB to `TXTEST` or any command except `START`. Its result, `sent 200 test frames on channel 20`, appears only on the board's UART0 log port ([Firmware Protocol](Firmware-Protocol)).

Afterwards board B remembers 802.15.4. The next time a helper opens it for another radio, it reboots once. On the tested boards the USB port stayed up through the reboot after `MODE`; if yours drops, the write after `MODE` fails: run the script again, and the board, now already in 802.15.4 mode, does not reboot.

## Decoding what you captured

What Kismet does with 802.15.4:

- It reads the MAC header of each frame: the frame type (beacon, data, acknowledgement, MAC command), the source and destination addresses, and whether MAC-layer security is on. Frames with security on are shown as encrypted.
- It makes one device per address, with the channel, the frequency (2405 + 5 × (channel − 11) MHz) and the signal it was heard at.
- It does **not** decode anything above the MAC layer: no Zigbee network or application layer, no Thread, 6LoWPAN or IPv6, no PAN ID, and it has no place for network keys.

The frames reach Kismet, and its logs, as link type 230, "IEEE 802.15.4 without FCS": the radio checks each frame's FCS in hardware and never hands it over. The link quality (LQI) and the radio's own timestamp are not passed on. [Zigbee and Thread Capture](Zigbee-and-Thread-Capture) explains why.

To read Zigbee or Thread itself, export the capture and open it in Wireshark ([Guide: Exporting to Wireshark](Guide-Exporting-to-Wireshark)):

- **Zigbee** encrypts traffic above its network layer. Give Wireshark the network key under *Preferences → Protocols → ZigBee → Pre-configured Keys*. <!-- VERIFY: Wireshark preference path for the ZigBee network key -->
- **Thread** protects its frames with keys derived from the Thread network key, so Wireshark needs that key too. <!-- VERIFY: the Wireshark preference that takes a Thread network key for 802.15.4 decryption, and what Wireshark shows for Thread frames without it -->

Treat network keys, and captures that can be decrypted with them, as secrets.

To watch 802.15.4 live in Wireshark with the channel, RSSI and LQI of every frame, use the sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer), which runs the same firmware family and hands Wireshark the full 802.15.4 TAP header.

## See also

- [Zigbee and Thread Capture](Zigbee-and-Thread-Capture): the radio in detail, and its limits
- [Channel Control](Channel-Control): locking and hopping, in the definition, the UI and over REST
- [Multiple Boards](Multiple-Boards): an 802.15.4 board next to Wi-Fi and BLE boards
- [Firmware Protocol](Firmware-Protocol): `MODE`, `CHANNELS` and `TXTEST` in full
- [Troubleshooting](Troubleshooting)
