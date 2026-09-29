This page covers running several ESP32-C5 boards on one machine. It explains how to name them so each source always gets the same board, why a board can serve only one source at a time, how to mix radios, how to share out the Wi-Fi channels, and what to do about USB power. It is for anyone with more than one board.

> **Note:** Only capture on networks and devices you own or are authorised to test.

## What was tested

- **Raspberry Pi 4** (8 GB, Debian 13 trixie, arm64) with **four boards on a powered USB hub**, seen as `/dev/ttyACM0` to `/dev/ttyACM3`, each with its `/dev/serial/by-id` link. Kismet was built on the Pi and ran as a normal user.
  - All four boards were flashed and checked. Each board sent 802.15.4 test frames to each of the other three: all 12 pairs received 50 of 50.
  - As Kismet sources, the boards ran two at a time in several combinations of the three radios. Two Wi-Fi boards shared out the channels for 243 s. A Zigbee source received 200 of 200 test frames from another board.
  - **All four boards ran as Kismet sources at once**, two Wi-Fi, one Zigbee and one BTLE: for 60 s each through the C helper started by Kismet, through one Python remote helper process with four sources, and through four C remote helpers, and for 10 minutes through one Python remote helper process. All sources kept running without errors, except in two runs, one as local sources and one through the C remote helpers, where the BTLE board hung on its switch from Wi-Fi to BLE (see "Mixing radios" below).
  - In Docker on the Pi, the image's `kismet` service ran all four boards, first found by themselves and then named in `KISMET_SOURCES` by their `/dev/serial/by-id` links, with the three radios mixed.
- **Windows 11** with two boards on a powered hub (COM30 and COM32), both given to one Python remote helper. COM32 captured throughout; COM30 was stuck in Windows error 31 for most of the run (see [Troubleshooting](Troubleshooting)).
- These runs used builds of the helpers from before their latest changes, which have been tested only without hardware so far.

<!-- VERIFY: round-2 Pi check: the four-source regression (two Wi-Fi, one Zigbee, one BTLE) through the C helper started by Kismet and through one Python remote helper process, with the current helpers -->

## Naming the boards

A source definition names the radio and the port. The word between `esp32c5` and the dash picks the radio, and the part after the dash is the port:

| Linux, Kismet on the same machine | Windows, the Python remote helper | Radio |
|---|---|---|
| `esp32c5-ttyACM0` | `esp32c5-COM14` | Wi-Fi |
| `esp32c5zigbee-ttyACM1` | `esp32c5zigbee-COM15` | 802.15.4 (Zigbee, Thread) |
| `esp32c5btle-ttyACM2` | `esp32c5btle-COM16` | Bluetooth LE |

Add `name=` to give a source a readable name in Kismet, such as `esp32c5-ttyACM0:name=wifi-a`. [Source Definitions](Source-Definitions) has every form.

### Listing the boards

On Linux, the C helper lists every board it can see, three times, once per radio:

```bash
kismet_cap_esp32c5 --list 2>&1
```

```text
esp32c5 supported data sources:
    esp32c5-ttyACM0:mode=wifi (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5zigbee-ttyACM0:mode=zigbee (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
    esp32c5btle-ttyACM0:mode=btle (Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03))
```

- The list goes to standard error and the helper exits with status 2. Both are normal for Kismet's capture helpers, hence the `2>&1`.
- The three lines are alternatives, not three sources to run together.
- A board that a source is using right now is left out, all three lines. The helper checks the port's lock without opening it.
- `kismet_cap_esp32c5` is installed next to `kismet`, for example in `~/kismet-install/bin`. If that folder is not on your `PATH`, run it as `~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1`.

The Python remote helper lists each port with its MAC and the three `--source` names. It uses pyserial's port list rather than Linux sysfs, so it works on Windows too. Run it from the project folder, with its requirements installed ([Remote Capture](Remote-Capture)). On Windows:

```powershell
python -m esp32c5_kismet.remote --list
```

On Linux, run it with the Python of the virtual environment that holds its requirements; [Remote Capture](Remote-Capture) shows how to create it:

```bash
.venv/bin/python -m esp32c5_kismet.remote --list
```

On Windows each board shows as a line such as `COM14  F0:F5:BD:01:02:03`, followed by `--source esp32c5-COM14` and the other two names; on Linux as `/dev/ttyACM0  F0:F5:BD:01:02:03`, followed by `--source esp32c5-ttyACM0` and the other two. The MACs on this page are examples. On Linux it also leaves out a board that another capture is using, and says so after the list, for example `Left out, in use by another capture: /dev/ttyACM0`; on Windows it lists every board. It has been run on Windows and Linux; macOS and the BSDs are untested.

**Other ESP32 boards show up too.** Boards are found by their USB ID, 303a:1001, and every Espressif chip on its native USB port has that ID: ESP32-C3, C6, H2, S3, P4 and others. A listed board need not be an ESP32-C5 sniffer. With other ESP32 boards plugged in, always name the port.

### A source without a port

A bare `esp32c5` (or `esp32c5zigbee`, `esp32c5btle`, or a free name such as `esp32c5-kitchen`) takes the only board plugged in. With several boards it cannot choose:

- The C helper fails the source with `2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-ttyACM0`, and Kismet retries it every 5 s.
- The Python remote helper refuses two definitions that name no port at start-up, because both would take the same board.
- With one definition that names no port, the Python remote helper does not stop. For `--source esp32c5` with boards on COM14 and COM15 it logs `esp32c5: 2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found (COM14, COM15), and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-COM14` and tries again every 5 s. It does not connect to Kismet while more than one board is plugged in, so the source does not appear there at all.

With more than one board, give every source a port or a `device=`.

## Names that stay the same

### On Linux: /dev/serial/by-id

`ttyACM` numbers are handed out in the order boards appear, so they can change: after a replug, after the machine reboots, or when a board comes back while its old number is still held. On the test Pi they stayed the same through radio switches and resets, but do not rely on that.

udev also gives each board a link that never changes, named after its MAC, such as `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00`. List them, with the `ttyACM` each one points to:

```bash
ls -l /dev/serial/by-id/
```

Use the link with `device=` and set the radio with `mode=`:

```ini
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a
```

The colons in the path are fine: Kismet splits a definition at its first colon only. The test Pi ran its sources this way.

The project's Docker container makes the same `/dev/serial/by-id` links as the host, so use them in `KISMET_SOURCES` there too, for example `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=zigbee` ([Docker Reference](Docker-Reference)). The test Pi ran four sources in the container this way.

### On Windows: COM numbers

Windows gives each board its own COM number and should keep giving it the same one. `--list` shows which MAC is on which port.
<!-- VERIFY: that Windows keeps a board's COM number across replugs and USB ports (a code comment, not tested) -->

### When a board comes back under another name

Both helpers know a board by its MAC, which it reports as its USB serial number. When a port has to be reopened, after the board rebooted or USB dropped out, the helper checks that the port still holds the same board. If it does not, the helper looks for its board by MAC:

```text
<name>: /dev/ttyACM0 now holds another board, looking for <MAC>
<name>: board <MAC> is on /dev/ttyACM2 now
```

This matters when two boards reboot at the same moment and come back with their `ttyACM` names swapped. The configured path stays the first one tried. This has not been tested on hardware, because it needs two boards whose names swap. Finding a board by its MAC needs Linux sysfs on the C helper's side, and works on Linux and Windows for the Python remote helper.

A board that stays away for good:

- **C helper:** after 15 s without capture it reports `<name>: no capture from the board on <device> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?` and ends. Kismet re-opens the source 5 s later and keeps trying until the board is back at the configured path. With a by-id link, that is wherever the board is plugged in; with a `ttyACM` name, only that name.
- **Python remote helper:** after 15 s it gives the source up, then waits for the board. A named port is waited for (`COM14 is not there; is the board plugged in? (waiting for it)`), and a definition with no port waits for its board's MAC. If a different board turns up on a named port, the helper uses it and warns: `<definition>: COM14 holds board <new MAC> now, not <old MAC>; Kismet will see it as another source (<uuid>)`.

<!-- VERIFY: the reopen-by-MAC and waiting behaviour of the current helpers on real boards -->

## Identity in Kismet

Kismet knows a source by its UUID. The helpers build it from the board's MAC and the radio:

```text
E5C5000M-0000-0000-0000-<MAC without colons>        M = 1 Wi-Fi, 2 Zigbee, 3 BTLE
```

A board with the MAC F0:F5:BD:01:02:03 is `E5C50001-0000-0000-0000-F0F5BD010203` on Wi-Fi and `E5C50003-0000-0000-0000-F0F5BD010203` on BTLE. So:

- **One board has three UUIDs**, one per radio.
- **The UUID does not depend on the port name.** The same board on the same radio is the same source in Kismet, on `ttyACM0` or `ttyACM3`, and through a by-id link.
- **Both helpers give the same UUID** for the same board and radio.
- Kismet matches remote sources **by UUID only**, and never removes a source it has seen. A stable UUID is what keeps a reconnecting board from turning into a second source.

Without a MAC the helpers use a hash of the device path instead. That happens with the fake board, and with the C helper outside Linux. Renaming the path then changes the UUID. `uuid=` in the definition sets it by hand. Two sources must never share one: when a remote source arrives with the UUID of a running one, Kismet closes the running one.

Kismet's **Hardware** row for the source reads `Espressif USB-Serial-JTAG (F0:F5:BD:01:02:03)`, or `ESP32-C5` when there is no MAC. It names the USB device, not the chip, since the USB ID cannot tell an ESP32-C5 from other ESP32 chips.

## One board, one source

A board listens with one radio at a time, and changing radio reboots it. Two sources for different radios on one board would reboot it back and forth, which a review of the earlier helpers found could happen. So only one source may use a board at a time.

- **The port is locked.** While a source runs, its helper holds an exclusive lock on the port. A second source for the same board fails to open, whether it asks for another radio or for the same radio under another name or a by-id link:

  ```text
  /dev/ttyACM0 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time
  ```

  Kismet keeps retrying such a source every 5 s. Adding it over the REST API returns HTTP 500.
- **Both helpers take the same lock**, so the C helper and the Python remote helper keep out of each other's way on one machine. While a source has a board, every other program that tries to open its port is refused with `Device or resource busy`, esptool included (`Could not open ..., the port is busy or doesn't exist.`), so stop the source before you flash the board. The one exception is a program run with `sudo`: root gets past the lock, so do not run `sudo esptool` on a board a source is using. On Windows every COM port is one program at a time anyway. A serial terminal such as minicom that opened the port *before* the source takes no lock, so the helper cannot tell and both read the port; close serial terminals yourself.
- **The Python remote helper checks at start-up.** Two definitions for one port stop it with exit status 2, for example `esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14`. `COM14`, `com14` and `\\.\COM14` are the same port, and so are a by-id link and its `ttyACM`.
- **Lists leave busy boards out**, on one machine (not across a container's boundary, below). `kismet_cap_esp32c5 --list` leaves out a board that a source is using, and so does the Python remote helper's `--list` on Linux. So does Kismet's list of interfaces you can add, which comes from the C helper: that was checked over Kismet's REST API (`/datasource/list_interfaces.json`), which the web UI's **Data Sources** window reads, but not in a browser.
- **A second remote helper for a busy board is not offered to Kismet** (Linux). Both helpers check before every connection, and wait while another capture holds the board: otherwise Kismet, which sees the same board and radio as the same source, would close the running one to make room. On Windows the Python remote helper cannot check first, so do not start a second copy of a source that is already running. See [Remote Capture](Remote-Capture#when-the-connection-drops).
- **To switch a board to another radio,** close its source first (Data Sources, then **Close** on the source), then add the new one. Without the web UI, for example on a headless Pi or in Docker, the REST calls in [Source Definitions](Source-Definitions#closing-reopening-and-pausing-a-source) do the same. For a remote source, stop its helper instead: Kismet's close lasts only until the helper connects again, about 5 s later.

The lock holds between a container and the host: the helpers put the port itself in exclusive mode, not only the device node each container makes. On the test Pi, while the project's `kismet` container captured from the boards, opening one from the host failed with `Device or resource busy`, and the container's sources kept running. By the same means it should hold between two containers; that follows from the code and has not been tried.

What the exclusive mode does not give is a view of the other side's locks; only an actual open is refused. On the test Pi, the host's Python `--list` still listed the boards the `kismet` container was using, and the C helper's `--list` looks for locks the same way. Likewise `--list` in one container lists a board that another container is using, and a remote helper in the `helper` container does not notice that the `kismet` container holds a board, so it offers the board to Kismet anyway. Stop the `kismet` service before you use its boards from the `helper` service, or from the host.

## Mixing radios

Use one board for each radio you want at the same time. For the four-board layout, two Wi-Fi boards, one Zigbee and one BTLE, add this to `kismet_site.conf` and change the MACs to your boards':

```ini
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=wifi,name=wifi-b
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:05-if00,mode=zigbee,name=zigbee
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:06-if00,mode=btle,name=btle
```

- Several `source=` lines in `kismet_site.conf` all count. Together they replace any `source=` lines in Kismet's own config files, which have none.
- Any `-c` on Kismet's command line makes it ignore every `source=` in the config. Kismet logs: `Data sources passed on the command line (via -c source), ignoring source= definitions in the Kismet config file.`
- **Boards remember their last radio.** The first time a board is used for another radio, it reboots into it. On the test Pi a source was capturing about 1.5 s after Kismet launched it when the board had to switch (2.5 s from Wi-Fi to BLE, where the board also drops off USB and comes back), and about 1 s when it was already on that radio: the helpers always set the radio and wait 0.8 s before they start. Keep each board on the same radio from run to run and the reboot happens only once.
- **A switch from Wi-Fi to BLE can hang a board.** One of the four test boards sometimes dropped off USB during that switch, about one time in five, and then never answered again until it was reset with esptool or unplugged and plugged back in. The helper gives up after 15 s and tries again (Kismet re-opens a local source; a remote helper reconnects), which does not help. It was seen only with the C helper; the Python remote helper made the same switch on that board 5 times (25 runs in all, 20 of them radio switches) without a hang, so the cause is not certain. If a BTLE source on a board that was on Wi-Fi stays at 0 packets with the helper giving up every 15 s, replug the board.
- **One board's reboot does not touch the others.** Each source has its own helper and its own port.

With the Python remote helper, repeat `--source` for each board. Each source gets its own connection to Kismet:

```powershell
python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5-COM14:name=wifi-a --source esp32c5-COM15:name=wifi-b --source esp32c5zigbee-COM16 --source esp32c5btle-COM17
```

This assumes the API key is in `KISMET_CAP_APIKEY`; see [Remote Capture](Remote-Capture).

In the Docker image, the `kismet` role adds one source per board it finds, each in the radio `ESP32C5_MODE` names (Wi-Fi unless set). For a mix, list the sources in `KISMET_SOURCES`, separated by spaces, for example `esp32c5-ttyACM0:mode=wifi esp32c5-ttyACM1:mode=zigbee esp32c5-ttyACM2:mode=btle`, or with the by-id links as above. A definition in that list cannot contain a space. See [Docker Reference](Docker-Reference).

## Sharing out the Wi-Fi channels

One board hears one channel at a time. With several Wi-Fi boards there are three ways to share the 42 channels:

| Approach | How | Good for |
|---|---|---|
| Let Kismet split | Nothing to set: every board hops over all 42 channels, each from a different starting point | A general survey. Each channel is visited more often. |
| One band per board | `channels=` on each board: 2.4 GHz on one, 5 GHz on the other | Covering both bands evenly |
| Fixed channels | `channel=<n>,channel_hop=false` on each board, for example 1, 6 and 11 | Watching busy channels without gaps |

The details and the exact lines are on [Channel Control](Channel-Control). What the test Pi saw with two Wi-Fi boards left to split over 243 s: 8801 and 10242 packets, and 244 Wi-Fi devices between them. The two boards saw 170 and 183 devices each, so each found devices the other missed.

> **Note:** Mixing locked and hopping boards on the same radio may undo the lock. When a hopping board opens after a locked one, Kismet's split may send the locked board a hop list too. This was read from Kismet's code, not seen in a test. [Channel Control](Channel-Control) has the details and a workaround.

The same choices apply to several Zigbee boards: let Kismet split channels 11–26, or lock each board on a channel of interest.

Several BTLE boards in one place add little. They all listen on the same advertising channels. Kismet treats the second board's copy of an advertisement as a duplicate of the first board's, and a duplicate BTLE packet does not update the device ([Bluetooth LE Capture](Bluetooth-LE-Capture)). A second BTLE board is worth more somewhere else.

## USB, hubs and power

- **Use a powered hub.** An unpowered hub browns out under four boards, and the failures look like firmware bugs. That is the sibling project's experience with four sniffers; the test Pi ran its four boards through one powered hub.
- **Use data cables you trust.** Some USB cables carry power only, and a board on one never appears.
- **Each board is its own USB device**, with its own port and its own link. By the firmware's design notes a board's link carries a few hundred kB/s; that has not been measured. On a busy channel a board drops whole frames rather than stall ([Wi-Fi Capture](Wi-Fi-Capture)).
- **A board that disappears.** Check the kernel log for "USB disconnect", then replug the board or power-cycle the hub:

  ```bash
  sudo dmesg | grep -i "usb disconnect"
  ```

  In the test run two boards that "disappeared" from the Pi had been unplugged by hand. `--list` shows only what is on the USB bus, so a missing board there is a USB matter, not a helper one.
- **Windows** can leave a board listed but unusable, with error 31. Replug it. [Install on Windows](Install-on-Windows) has the details.
- More on boards, cables and hubs: [Hardware](Hardware).

## See also

- [Channel Control](Channel-Control): hopping, splitting and locking
- [Source Definitions](Source-Definitions): every form of a definition
- [Remote Capture](Remote-Capture): boards on one machine, Kismet on another
- [Guide: Dual-Band Wi-Fi Survey](Guide-Dual-Band-Wi-Fi-Survey)
- [Troubleshooting](Troubleshooting)
