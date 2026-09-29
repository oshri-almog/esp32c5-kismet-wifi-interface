This page lists the problems met with the boards, the helpers and Kismet, each as symptom, cause and fix. Most entries come from the test runs on a Raspberry Pi 4, on Windows 11 and in WSL2; problems that the code has fixed since then say so. Find your symptom in the table below, or work through the first checks. The last section shows how to get the logs that say more.

## First checks

The Linux commands on this page are written for the home-directory install used on the tested Raspberry Pi (`--prefix=$HOME/kismet-install`). There `kismet` and `kismet_cap_esp32c5` are in `~/kismet-install/bin`, which is not on your `PATH`, so give the full path as below, or add that directory to `PATH`. After a system-wide install, or inside the Docker image, the bare names work.

1. **Is the board on the bus?** On Linux:

   ```bash
   ls -l /dev/serial/by-id/
   ~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1
   ```

   On Windows, from the repository folder:

   ```powershell
   python -m esp32c5_kismet.remote --list
   ```

   Each board shows up with its MAC. `kismet_cap_esp32c5 --list` leaves out a board that a source is using. It writes to stderr, so add `2>&1` when you pipe it (for example into `grep`) or send it to a file.

2. **What does Kismet say about the source?** A working local source logs `<name> capturing (wifi)` (or `zigbee`, `btle`). Kismet puts a remote source's name in front of its messages. A source fed by the remote C helper shows `<source name> - <name> capturing (wifi)`. One fed by the Python remote helper shows the port instead of the radio, for example `<source name> - COM14 capturing`, and the helper's own log shows `COM14 capturing`. A failing one shows its reason in the **Data Sources** panel and in Kismet's log. For a local source the reason is followed by `Kismet will attempt to re-open the source in 5 seconds`. For a remote source Kismet instead waits for the helper to reconnect: `Remote sources are not locally reconnected; waiting for the remote source to reconnect to resume capture.`

3. **Find the stage where it stops:**

| What you see | Section |
|---|---|
| Kismet refuses the definition, or the source fails to open | [Kismet will not open the source](#kismet-will-not-open-the-source) |
| The source opens but never logs "capturing" | [The source opens but never captures](#the-source-opens-but-never-captures) |
| "capturing", but few or no packets or devices | [Few or no packets](#few-or-no-packets) |
| A remote helper cannot connect, or keeps reconnecting | [Remote capture](#remote-capture) |
| Something only Windows does | [Windows](#windows) |
| Kismet's login, logs or build | [Kismet itself](#kismet-itself) |

## Kismet will not open the source

### "Unable to find driver for 'esp32c5...'"

```text
ERROR: Unable to find driver for 'esp32c5:mode=zigbee,channel=27'.  Make sure that any required plugins are loaded, the interface is available, and any required Kismet helper packages are installed.
```

**Cause.** For a definition without `type=`, Kismet asks every capture helper whether the definition is theirs, keeps their answers to itself, and gives up for good, with no retry, when none says yes. The C helper says no when:

- the definition is wrong in itself: a `mode=` that is not a radio, or a `channel=` the radio does not have;
- the name is not one of the helper's: it must start with `esp32c5` in lower case, and a name such as `esp32c5foo` is not the helper's when no board can be found;
- this Kismet was built without the esp32c5 source, so there is no helper to ask;
- Kismet was built with the esp32c5 source, but `kismet_cap_esp32c5` is not in Kismet's `bin` directory (`helper_binary_path`): `make install` was not run, or `helper_binary_path=` in a config file replaced Kismet's directory. With `type=esp32c5` this shows as [Capture tool not installed](#capture-tool-not-installed);
- in Docker, the helper crashed before it could answer (see [Docker: no source starts](#docker-no-source-starts-and-the-helper-crashes-with-signal-11)).

**Fix.**

1. Add `type=esp32c5` to the definition. Kismet then opens the source with the C helper directly, shows the helper's reason, and retries every 5 s:

   ```bash
   ~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5:mode=zigbee,channel=27,type=esp32c5'
   ```

   Here the reason reads `esp32c5: channel=27 is not a channel the board can tune to in zigbee mode`.
2. If Kismet answers `Unable to find datasource for 'esp32c5'` instead, this Kismet has no esp32c5 source. Build one with it: [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).
3. Correct the definition. [Source Definitions](Source-Definitions) has every form and the channels of each radio.

A definition named the helper's way whose board is missing (`esp32c5`, `esp32c5-kitchen`, `esp32c5zigbee-ttyACM9`) does not get this message from the current helper: the source is created, its open fails with the real reason, and Kismet retries until the board is there. Helpers built before this change said "Unable to find driver" for a bare `esp32c5` with no board or with several. If yours does, update it ([Guide: Updating](Guide-Updating)).

<!-- VERIFY: on real hardware, a bare esp32c5 with two boards plugged in now shows the helper's reason and is retried without type=esp32c5 -->

### "no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found" or "2 Espressif USB-Serial-JTAG devices ... found"

```text
no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition
2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-ttyACM0
```

**Cause.** The definition names no port (`esp32c5`, `esp32c5zigbee`, `esp32c5-kitchen`), so the helper looks for the only board plugged in, and finds none or several. Every ESP32 on its native USB port counts, not only sniffers.

**Fix.** Plug the board in; Kismet retries every 5 s and picks it up. With several boards, name one: `esp32c5-ttyACM0`, or better its by-id link, `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00`. On macOS and the BSDs the helper cannot look for boards at all (`finding a board by itself needs Linux sysfs ...`): always name the port there.

### "cannot open /dev/ttyACM0: Permission denied"

**Cause.** The user Kismet runs as may not read and write the port. On Debian, Ubuntu and Raspberry Pi OS the boards' ports belong to the group `dialout` (`crw-rw---- root dialout`).

**Fix.** Add the user to the group, then log out and back in:

```bash
sudo usermod -aG dialout $USER
```

The helper needs nothing more: no root, no setuid. On the tested Raspberry Pi the user was already in `dialout`.

<!-- VERIFY: the usermod fix on a system where the user is not in dialout (standard Debian practice; not needed on the tested Pi) -->

### "cannot open /dev/ttyACM9: No such file or directory"

**Cause.** The port named in the definition does not exist: the board is not plugged in, or it came back under another number. The helper waits for a named port rather than taking another board, so Kismet retries every 5 s.

**Fix.** Plug the board in, or check its number with `ls -l /dev/serial/by-id/`. Name boards by their by-id link, which stays with the board whatever ttyACM number it gets.

### "... is already in use by another capture ..."

```text
/dev/ttyACM0 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time
```

**Cause.** A board captures with one radio at a time, and each helper holds its port exclusively. Something else has it:

- another source on the same board, often the same board's other radio picked in the Data Sources panel (`esp32c5zigbee-ttyACM0` while `esp32c5-ttyACM0` runs);
- the other helper: the C helper and the Python remote helper take the same lock and keep each other out;
- esptool, which takes the same lock;
- on Windows, any program that has the COM port open, a serial monitor included: a COM port has only one user at a time.

On Linux, a serial monitor that does not take this lock is not refused. It reads from the port alongside the helper, and the source loses sync or stops capturing instead ([no capture for 15 seconds](#no-capture-from-the-board-on-devttyacm0-for-15-seconds)).

<!-- VERIFY: which common serial monitors on Linux (idf.py monitor, screen, minicom, picocom) take the flock, and so get or cause "already in use" -->

During a reconnect the helper shows the same condition as `<name>: <that message>; waiting for it`.

**Fix.** Close the other source, or the other program. To change a board's radio, close its source and open one for the other radio; the board reboots, which took about 1.5 s in the last hardware run.

The Python remote helper also refuses at startup, with exit code 2, two definitions for one board (`esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14`) and two that name no port.

> **Warning:** In Docker the lock does not cross the container boundary: each container makes its own device node. A board used by a container can still be opened from the host or from a second container, and neither is refused; the board then reboots back and forth between radios. Stop the `kismet` service before you use the same boards from the host or from the `helper` service.

<!-- VERIFY: whether TIOCEXCL has landed in the helpers; then the lock holds across containers and this warning can go -->

### "Capture tool not installed"

A source defined with `type=esp32c5` fails with the reason `Capture tool not installed`. Without `type=`, the same problem shows only as ["Unable to find driver"](#unable-to-find-driver-for-esp32c5), because Kismet keeps the probe's reason to itself.

<!-- VERIFY: the exact log line for this case at Kismet cfe427074. Kismet checks for the binary (check_ipc) before it tries to launch it, so "Kismet external interface can not find IPC binary for launch: kismet_cap_esp32c5" is probably not printed -->

**Cause.** Kismet runs capture helpers only from its own `bin` directory (`helper_binary_path`), and `kismet_cap_esp32c5` is not there.

**Fix.** Run `make install` in the Kismet tree after building it, so the helper lands next to `kismet`: for example `ls ~/kismet-install/bin/kismet_cap_esp32c5`. If you set `helper_binary_path=` in `kismet_site.conf`, change it to `helper_binary_path+=`, which adds a directory instead of replacing Kismet's. See [Kismet Configuration](Kismet-Configuration).

### Docker: no source starts, and the helper crashes with signal 11

**Symptom.** In a container without `NET_ADMIN`:

- Kismet logs only `cancelling source probe due to timeout` or `Unable to find driver`;
- in the `helper` role, the log shows `capture process exited 0 signal 11`;
- the entrypoint warns: `the container has no NET_ADMIN capability, and without it Kismet's capture helpers crash on start. Add --cap-add NET_ADMIN to docker run (compose.yaml has it).`

**Cause.** Kismet's capture helpers, run as root, keep the `NET_ADMIN` and `NET_RAW` capabilities and drop the rest. Docker's default set lacks `NET_ADMIN`, so that step fails, and Kismet's error path then crashes the helper before it opens the board. Kismet's own stock helpers crash the same way.

**Fix.** Add `--cap-add NET_ADMIN` to `docker run`. compose.yaml already has it on the `kismet`, `demo` and `helper` services. A container that only receives sources from remote helpers does not need it; the entrypoint says so with `no NET_ADMIN capability: sources from remote helpers work, boards plugged into this machine would not`.

<!-- VERIFY: NET_ADMIN removed? -->

### Docker: the container finds no boards

**Symptom.** The container starts Kismet with no source. When the container sees no Espressif device at all, the log says:

```text
[esp32c5-kismet] no ESP32-C5 board found. Plug one in and restart the container, or add sources from
[esp32c5-kismet] the web UI (Data Sources); boards plugged in now appear in the container on their own.
```

When a board is there but the container may not use it, the log shows the hint under "Linux without the device rules" below, and ends differently.

**Causes and fixes.**

- **Docker Desktop on Windows** does not pass USB boards to containers. Run the Python remote helper on Windows and feed the Kismet in the container ([Install on Windows](Install-on-Windows)). Attaching boards to WSL2 with usbipd might work, but has not been tried with Docker Desktop. Docker Desktop on macOS is untested, and probably has the same limit.
- **Linux without the device rules.** The entrypoint names the missing permission, and the "no ESP32-C5 board found" lines do not appear:

  ```text
  [esp32c5-kismet] found ttyACM0 in sysfs but the container may not use it: allow it with
  [esp32c5-kismet] compose.yaml's device_cgroup_rules, or docker run --device-cgroup-rule 'c 166:* rmw'
  [esp32c5-kismet] Kismet starts with no source: no board here that the container may use (see above)
  ```

  Use compose.yaml, or add `--device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw'` to `docker run`.
- **The boards were plugged in after the container started.** They get their device nodes within a second, but they are not added as sources. Add them from the web UI's Data Sources panel, or restart the container. At start, the `kismet` role waits up to `ESP32C5_WAIT` seconds (30 by default) for a board.
- **The demo image**, with its fake board running, does not look for boards. Use the `kismet` image, or list them in `KISMET_SOURCES` with `docker run -e KISMET_SOURCES=...`; the Compose `demo` service does not pass that variable.

<!-- VERIFY: the entrypoint's device-rule check and hint, and real boards in a container at all (the current entrypoint has only run with the fake board) -->

## The source opens but never captures

### "no capture from the board on /dev/ttyACM0 for 15 seconds"

```text
c5-wifi: no capture from the board on /dev/ttyACM0 for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?
```

The Python remote helper says `the board on COM14 has not been capturing for 15 s (last: <the board's last status>)`.

**Cause.** The port opened, but no valid stream came back for 15 s. The C helper then ends and Kismet re-opens the source 5 s later; the Python remote helper gives the source up and reconnects after 5 s. Likely reasons, most likely first:

1. The board does not run the sniffer firmware, or it is another ESP32 with the same USB ID.
2. The board is latched in its ROM download mode after flashing. The sibling project's web flasher page reports this on two of the three boards it was developed against; it is a quirk of the board, not of the firmware.
3. Another program talks to the port without taking the helpers' lock, such as a serial terminal.
4. On Windows, the board is wedged ([error 31](#windows-error-31-a-device-attached-to-the-system-is-not-functioning)).
5. The firmware is an older sibling build that lacks the radio asked for; the log then also shows `lost sync (the board sends link type 127, not 256)` or similar.
6. In the last hardware run, all four boards came with the sibling project's 1.2.0 build (app version `5cdab32-dirty`). Two of them streamed Wi-Fi but did not answer `START` within 3 s in the flashing script's check. The cause was not found. After this project's firmware was flashed (an earlier build than the current one), all four worked.

**Fix.** Unplug the board and plug it back in, or press its BOOT button once. Close any serial terminal. If that does not help, flash the current firmware: [Flashing the Firmware](Flashing-the-Firmware).

### A board sends `<<START>>` and then goes quiet

**Symptom.** With a serial terminal or your own program, not the Kismet helpers: after a reset the board sends `<<START>>` and a PCAP header, then nothing on the Wi-Fi channels you asked for. It looks like a hang.

**Cause.** The board remembers its radio and boots into it. A board last used for Zigbee or Bluetooth LE comes up on that radio, and ignores Wi-Fi.

**Fix.** Send `MODE WIFI` (or the radio you want) before `START`. It costs nothing when the board is already on that radio. The Kismet helpers always do this, so the problem does not arise under Kismet. Flashing the merged image or erasing the flash also resets the board to Wi-Fi; `idf.py flash` keeps the stored radio. See [Firmware Protocol](Firmware-Protocol).

### A board that ran Zigbee captures no Wi-Fi

**Symptom.** A Wi-Fi source on a board that was used for 802.15.4 says "capturing", but its packet count stays at 0 while other boards see traffic on the same channels.

**Cause.** The board's radio was left in a state that no reset clears. The firmware now switches radio by rebooting, and shuts the old radio down cleanly first, which keeps this rare: in the sibling project's measurements, nine of nine switches on two boards left Wi-Fi working.

**Fix.** Unplug the board and plug it back in. A reset does not clear it; cutting the power does.

### Windows: error 31, "A device attached to the system is not functioning"

**Symptom.** The Python remote helper logs, about once a second:

```text
COM30 opened
COM30: Write timeout
COM30: Cannot configure port, something went wrong. Original message: PermissionError(13, 'A device attached to the system is not functioning.', None, 31)
```

esptool fails with `Could not open COM30, the port is busy or doesn't exist.` and the same error 31. The port is still listed, with its MAC, by `--list`.

**Cause.** Windows' USB device for that board is in a bad state. The same board had passed every test on the Pi an hour earlier, so the board and firmware were fine. A likely trigger is a program that opened the port with default DTR and RTS, which resets the chip; right after such an open, two boards briefly vanished.

**Fix.** Unplug the board and plug it back in, or power-cycle the hub. Other boards on the same helper keep capturing. The current Python remote helper reports the error to Kismet as the source's error and retries every 5 s.

<!-- VERIFY: the current Python remote helper shows error 31 as the source error in Kismet and throttles its messages; the exact trigger of the wedge; and that a replug clears error 31 (reported, not logged) -->

### "lost sync (...)" in the log

The helpers read the board's stream record by record, and resynchronise by themselves when something does not fit:

| Message | Meaning |
|---|---|
| `<name>: lost sync (the board restarted the stream)` | The board rebooted (a radio switch) or answered another `START`. Normal once after a switch or a reconnect. |
| `<name>: lost sync (the board sends link type 127, not 283)` | The board is still on another radio; the helper asks again. If it never ends, the firmware lacks that radio: flash the current firmware. |
| `<name>: lost sync (bad PCAP global header)` | The stream's header did not look right |
| `<name>: lost sync (damaged PCAP record)` | A record's header did not look right |
| `<name>: <n> 802.15.4 frames with a malformed TAP header dropped` | Said at the first and every 1000th |
| `<name>: <n> BTLE records of impossible length dropped` | Said at the first and every 1000th |

The board only ever sends whole records, so frequent "bad header" or "damaged record" messages mean bytes are lost or mangled between the board and the helper. Check the cable and the hub, and make sure no other program has the port open.

<!-- VERIFY: frequent damaged-record messages point at the cable, the hub or another program on the port (inferred from the firmware's whole-record guarantee; not observed) -->

### A listed board is not an ESP32-C5 sniffer

**Symptom.** `--list` shows a board you did not expect, a bare `esp32c5` reports two devices when you have one sniffer, or the Docker image adds a source that never captures.

**Cause.** Every Espressif chip with a native USB-Serial-JTAG port (the ESP32-C3, C5, C6, H2, S3, P4 and others) has the USB ID `303a:1001`. The helpers cannot tell a sniffer from any other ESP32 by its ID.

**Fix.** Name the sniffers' ports, preferably by their `/dev/serial/by-id/` links. In Docker, list them in `KISMET_SOURCES` instead of letting the image find boards.

To stop Kismet's Data Sources panel offering such a board, hide each of its names in `kismet_site.conf`. For a board that is not a sniffer on `/dev/ttyACM3`:

```ini
mask_datasource_interface=esp32c5-ttyACM3
mask_datasource_interface=esp32c5zigbee-ttyACM3
mask_datasource_interface=esp32c5btle-ttyACM3
```

The names follow the `ttyACM` number, which can change after a replug.
<!-- VERIFY: mask_datasource_interface hides these list entries (kismet.md 7.2, Kismet's kismet.conf:116-121; not run) -->

### Boards drop off the bus, or fail in ways that look like firmware bugs

**Symptom.** Boards disappear from `--list` and `/dev/serial/by-id/`, sources reconnect again and again, or errors come and go with no pattern.

**Cause.** Usually power or cabling. The sibling project found that an unpowered hub browns out under four sniffers and produces failures that look like firmware bugs. The tested setups used a powered hub. In one test run two boards "disappeared" because they had been unplugged by hand, so check that first.

**Fix.** Use a powered USB hub and known-good data cables. Look for disconnects in the kernel log:

```bash
sudo dmesg | grep -i 'usb disconnect'
lsusb -d 303a:1001
```

Then replug the boards, or power-cycle the hub. A board missing from `--list` is not on the bus; that is not a helper fault. See [Hardware](Hardware).

## Few or no packets

### No Zigbee or Thread packets

**Causes and fixes.**

- **Nothing is transmitting.** With no Zigbee or Thread devices nearby, every test source counted 0 packets. That is expected.
- **The source is hopping.** Kismet hops the 16 channels 11 to 26 at 5 per second, so each channel gets 0.2 s in every 3.2 s. If you know your network's channel, lock the source on it:

  ```text
  esp32c5zigbee-ttyACM0:channel=20,channel_hop=false
  ```

  or set the channel from the web UI or the REST API ([Channel Control](Channel-Control)).
- **To prove the receive path**, let a second board transmit test frames with `TXTEST` on the same channel: 200 of 200 arrived in Kismet in the test. Transmit only where you are allowed to, and only near networks and devices you own or are authorised to test. See [Guide: Zigbee and Thread Networks](Guide-Zigbee-and-Thread-Networks).
- **The firmware lacks 802.15.4** (the sibling's 1.0.0): the source never says "capturing" and logs `lost sync (the board sends link type 127, not 283)`. Flash the current firmware.

Kismet's 802.15.4 device records have no PAN field; that is Kismet, not a fault.

### Bluetooth LE: every device on channel 37, and device counts stuck at 1 to 3

**Symptom.** Every Bluetooth LE device shows channel 37 (2402 MHz). Its packet count, last-seen time and signal stop changing after the first 1 to 3 packets, while the source counts about 20 packets a second. In one test minute Kismet counted 1099 packets, of which 1094 were duplicates.

**Cause.**

1. The board's controller scans advertising channels 37, 38 and 39 together and does not say which one a packet came on, so every packet is recorded as channel 37.
2. Kismet drops a packet as a duplicate when its contents match one of the last 1024 packets, and an advertiser repeats the same advertisement, byte for byte, on all three channels and at every interval. Duplicates do not update the device.

**Fix.** None needed; this is how the radio and Kismet work. A device's entry updates when its advertisement changes. The source's packet count, the kismetdb and the pcapng log all keep every packet, duplicates included. See [Bluetooth LE Capture](Bluetooth-LE-Capture).

### Bluetooth LE: packets are counted, but no devices appear

**Cause.** Older firmware, such as the sibling project's 1.2.0 from its browser flasher, leaves the "CRC checked" flags clear and the CRC zeroed. Kismet then checks the CRC itself and silently drops every packet.

**Fix.** The current helpers repair such packets and say so once per source:

```text
<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary
```

If you see no devices and no such message, update the helpers ([Guide: Updating](Guide-Updating)). Flashing the current firmware makes the repair unnecessary.

### The source stays on channel 6 or 15, although the definition says otherwise

**Causes and fixes.**

- `channel=` on its own only adds the channel to the hop list. Add `channel_hop=false` to stay on it: `esp32c5zigbee-ttyACM0:channel=20,channel_hop=false`.
- Helpers built before the `channel=` fix, including those used in the last hardware run, ignored `channel=` entirely. Update them, or set the channel from the web UI or with the REST call `set_channel.cmd` and `{"channel":"20"}`, which worked in the tests.
- While a source hops, Kismet may keep showing its start channel (6 for Wi-Fi) in the source's channel field; each packet's channel is the real one. Look at the frequencies of the packets instead. <!-- VERIFY: whether kismet.datasource.channel follows the hops with the current C helper (it now updates the framework's current channel on every hop) and with the Python remote helper; older builds left it at the start channel -->

<!-- VERIFY: channel= with channel_hop=false on real boards with the current helpers (fixed and covered by the fake-board tests; not re-run on hardware) -->

## Remote capture

### Windows: every connection to Kismet on localhost takes 2 s longer

**Symptom.** `--connect localhost:2501` from Windows to Kismet in WSL2 takes about 2 s to connect, a refused attempt about 4 s, and reconnects come 7 to 9 s apart instead of about 5.

**Cause.** Windows resolves `localhost` to the IPv6 address `::1` first, and takes about 2 s to give up on it. WSL2's port forwarder listens on `127.0.0.1` only, so `::1` is refused. Measured: 2.067 s through `localhost`, 0.001 s through `127.0.0.1`. Docker Desktop was not measured separately.

<!-- VERIFY: Docker Desktop and localhost. A port it publishes without an address (compose's kismet service, "2501:2501") answered on ::1 in 0.03 s in a quick check with another container, so it may not have the delay; one published on 127.0.0.1 (the demo service) may refuse ::1 as WSL2 does -->

**Fix.** Use `127.0.0.1` rather than `localhost`. The current Python remote helper tries `127.0.0.1` first by itself, but other tools do not.

<!-- VERIFY: the Python remote helper's localhost handling (127.0.0.1 first) re-measured on Windows -->

### The C helper over the websocket takes 3 to 5.4 s to start, then sends in bursts

**Symptom.** With `kismet_cap_esp32c5 --connect`, Kismet shows the source about 3 to 5.4 s after it connects (2.96, 3.63 and 5.38 s in three sessions), and packets arrive in bursts. Over `--tcp` it took 0.51 s; the Python remote helper over the websocket took 0.35 s.

**Cause.** Most likely in Kismet's own capture framework, which the C helper uses: the helper sent its first command 0.3 s after connecting, so the delay is in the websocket transport. Not confirmed.

**Fix.** It does no harm in normal use. For a faster start on a trusted network, use `--tcp` to port 3501. That port has no authentication and listens on loopback only by default; see [Kismet Configuration](Kismet-Configuration).

<!-- VERIFY: re-measure with the current C helper build (measured once, with an older build) -->

### The login is refused

**Symptom.** One of:

```text
Kismet refused the websocket: <details> (check --user/--password, or --apikey: the key needs the datasource role)
FATAL: User and password or API key required for remote capture
```

**Causes and fixes.**

- No login was given at all: pass `--apikey`, or `--user` and `--password`, or set `KISMET_CAP_APIKEY` (or `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`) in the environment.
- The key has the wrong role. Remote capture needs the `datasource` role (or `admin`); a `readonly` key is refused.
- The password contains `&`, a space or `%` followed by two hex digits. Kismet decodes the whole remote-capture URL before it splits it at `&`, so these cannot get through however they are escaped. Use an API key.

Create a key as shown in [Kismet Configuration](Kismet-Configuration).

### "FATAL: Could not probe local source prior to connecting to the remote host"

**Cause.** A remote C helper checks its definition before it connects. The definition names no port (a bare `esp32c5`, or a free-form name such as `esp32c5-kitchen`), and it found no board or more than one; the reason follows the colon and reads like the local ones above. A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) does not stop here: it connects, and Kismet shows the open error, such as `cannot open /dev/ttyACM0: No such file or directory`, as the source's error.
<!-- VERIFY: that a remote C helper whose named port is missing connects and reports the open error (read from capture_esp32c5.c probe_callback and resolve_device) -->

**Fix.** Plug the board in, or name its port. The Docker image's `helper` role starts the helper again every 5 s, so a board plugged in later is picked up there.

<!-- VERIFY: whether the C helper's own retry loop (without Docker) restarts it after this message, and how often it prints it -->

### "Connection refused", or "Datasource could not connect websocket"

```text
ERROR: esp32c5-COM14: [WinError 10061] No connection could be made because the target machine actively refused it
ERROR: esp32c5-ttyACM0: [Errno 111] Connection refused
FATAL: Datasource could not connect websocket
```

**Cause.** Nothing listens at the address and port given: Kismet is not running yet, or the address or port is wrong. Both helpers retry every 5 s, so a helper started before Kismet connects once Kismet is up.

**Fix.** Check that the server logs `HTTP server listening on 0.0.0.0:2501`, and that the helper connects to that port. From another machine, the Kismet machine's firewall must let the port through. A Kismet in WSL2 and one in Docker Desktop both want `localhost:2501`; give one of them another host port.

### Kismet says "Kismet could not find a datasource driver for incoming remote source 'esp32c5'"

**Cause.** The Kismet server was built without this project's source. A stock Kismet cannot take these boards.

**Fix.** Build Kismet with it ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)), or use the Docker image ([Install with Docker](Install-with-Docker)).

### Two entries for one board, or a source that comes back as a new one

**Cause.** Kismet recognises a remote source only by its UUID, and keeps a source in error in its list. The helpers make the UUID from the board's MAC and the radio (`E5C50001-0000-0000-0000-<MAC>` for Wi-Fi, `...0002...` for Zigbee, `...0003...` for BLE), so it stays the same across reconnects and ttyACM renumbering. Without the MAC (with the fake board, with a board that cannot be identified at that moment, or with the C helper on macOS and the BSDs, which have no Linux sysfs) the UUID comes from the port path as written, and another spelling of the path makes another source. The Python remote helper reads the MAC through pyserial, which should work on macOS too; that is untested. <!-- VERIFY: the Python remote helper gets the MAC (and so a MAC-based UUID) through pyserial on macOS -->

Older versions of the Python remote helper also changed the UUID when a board was away for more than about 20 s, or when the helper started before the board was plugged in. The current version waits for the board instead.

**Fix.** Keep a definition's port spelling the same, or name boards by their by-id links. If you need a fixed identity whatever happens, set `uuid=` in the definition. The stale entry stays listed in error and does no harm.

Two helpers that present the same UUID at the same time replace each other: Kismet logs that the new source `matches existing source '<name>', which is still running.  The running instance will be closed`. Do not feed one board to Kismet from two helpers.

<!-- VERIFY: the Python remote helper keeps its source's UUID across a board unplugged for more than 20 s (fixed; not re-run on hardware) -->

### The remote source shows "websocket connection closed" after the helper stops

This is expected. Kismet never re-opens a remote source itself; the source returns when the helper connects again. After it does, Kismet may keep showing the old error text while the source runs. That is a display quirk of Kismet's.

### Python remote helper: "COM14 is not there; is the board plugged in? (waiting for it)"

**Cause.** The port named in the definition does not exist right now. The helper waits for it, logs this ERROR every 5 s, and does not offer the source to Kismet until the port appears, so that the board keeps its identity when it comes back. A definition without a port waits the same way for the board it found first: `the board <MAC> is not plugged in (waiting for it)`.

**Fix.** Plug the board in. The source then connects within about 5 s.

### Python remote helper on Linux: a source never comes back after Kismet restarts

**Symptom.** After Kismet restarted, the helper printed a traceback ending in `OSError: [Errno 107] Transport endpoint is not connected` and stopped reconnecting.

**Cause.** websocket-client before 1.9.1 raises this on a reset connection. Ubuntu 24.04 packages 1.7.0 and Debian 13 packages 1.8.0.

**Fix.** Install the requirements with pip into a virtual environment, which brings a current version. Debian 12 and later and Ubuntu 23.04 and later refuse a plain `pip install` into the system Python (`error: externally-managed-environment`), so a virtual environment is the way on Linux. From the repository folder:

```bash
sudo apt install python3-venv                          # if python3 -m venv says ensurepip is not available
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m esp32c5_kismet.remote --list       # run the helper with this Python from now on
```

Run the helper with `.venv/bin/python -m esp32c5_kismet.remote ...` from the repository folder. The current helper also survives the old versions and reconnects. If every source stops by itself anyway, it exits with status 1, so a service manager can restart it.

### Python remote helper: "ModuleNotFoundError", or "the websocket protocol needs websocket-client"

**Cause.** The requirements are not installed, or Python is not started in the repository folder, so it cannot find `esp32c5_kismet`.

**Fix.** On Windows, from the repository folder, with Python 3.10 or newer:

```powershell
python -m pip install -r requirements.txt
python -m esp32c5_kismet.remote --list
```

On Linux, install into a virtual environment and run the helper with its Python, as in the previous section.

### Python remote helper: other messages

| Message | Meaning |
|---|---|
| `connection ended: no PING from Kismet for 15 s` | Kismet pings every 5 s. The network or the server stalled, and the helper reconnects 5 s later. |
| `connection ended: Kismet shut the source down: <reason>` | Kismet ended the source, for example because it was closed in the web UI. The helper reconnects 5 s later. |
| `COM14: no answer for 6 s, reopening` | Before the stream was in sync, the port sent nothing at all for 6 s. The board may be in download mode or not running the sniffer firmware. |
| `COM14 now holds another board, looking for <MAC>`, then `board <MAC> is on COM15 now` | The board came back on another port. The helper follows it by its MAC for this connection. |
| `Removed 2 channels from the channel list because the source could not tune to them: 15, 38` | A hop list held channels the radio does not have, here in Wi-Fi mode. The rest are hopped. |

<!-- VERIFY: these texts in the final Python remote helper (python-helper.md 7, 8.1, 8.3, 8.4; seen in remote.py and board.py) -->

## Windows

### Ctrl+C does not stop the Python remote helper started from Git Bash with &

**Symptom.** A helper started as a Git Bash background job ignored `kill -INT` and Ctrl+C, and `taskkill /PID <pid>` answered `This process can only be terminated forcefully (with /F option).`

**Cause.** Windows passes an "ignore Ctrl+C" setting from a process to its children, and Git Bash starts background jobs with it set. `taskkill` without `/F` sends a window message, and a console program has no window to receive it.

**Fix.** Run the helper in its own console window (Windows Terminal, PowerShell or cmd) and stop it with Ctrl+C or Ctrl+Break. For a background job, `taskkill /F /PID <pid>` is safe: the COM port is released at once, and Kismet shows the source in error with `websocket connection closed`. The current helper clears the inherited setting at start.

<!-- VERIFY: whether Ctrl+C, Ctrl+Break and Git Bash kill -INT stop the current Python remote helper when it runs as a Git Bash background job -->

### Git Bash turns /tmp/... into C:/Users/.../Temp/...

**Cause.** Git Bash rewrites arguments that look like POSIX paths before it passes them to Windows programs, `docker` included. `device=/tmp/esp32c5-demo` arrives as `device=C:/Users/.../Temp/esp32c5-demo`.

**Fix.** Turn the rewriting off for that command:

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker compose exec kismet cat /root/.kismet/kismet_httpd.conf
```

### esptool: "Could not open COM30, the port is busy or doesn't exist."

**Cause.** Another program has the port: the Python remote helper, a serial monitor, or another esptool. If the message also shows error 31, the board is wedged.

**Fix.** Stop the helper and close serial monitors, then flash. For error 31, unplug the board and plug it back in first. See [Flashing the Firmware](Flashing-the-Firmware).

## Kismet itself

### Kismet asks for a first login, or ignores the login you created

**Symptom.** Kismet logs `This is the first time Kismet has been run as this user.  You will need to set an administrator username and password ...` and the browser shows **Set Login**, although you created `~/.kismet/kismet_httpd.conf`. Or it logs `ERROR: Error reading config file '/root/.kismet/kismet_httpd.conf': No such file or directory`, and REST calls get no answer.

**Cause.** Kismet reads the login from `.kismet/kismet_httpd.conf` in the home directory that the system's user database gives for the user it runs as, **not** from `$HOME`. Started with `sudo`, that is `/root`.

**Fix.**

- Create the file for the user Kismet actually runs as, or start Kismet as the user whose file you made.
- Or give Kismet the directory: `kismet --homedir /home/you ...` reads `/home/you/.kismet/`.
- Or set the login in the browser, **at once**: until a login exists, the first visitor to port 2501 chooses it.

See [Kismet Configuration](Kismet-Configuration) for the file format and a global login.

### "Unable to open KismetDB log at ..."

```text
Unable to open KismetDB log at '<path>'; check that the directory exists and that you have write permissions to it.
```

**Cause.** Kismet writes its logs to `log_prefix`, by default the directory it was started in, and stops when it cannot. It does not create the directory.

**Fix.** Start Kismet in a directory you can write to, or set `log_prefix` in `kismet_site.conf` to a folder that exists, or pass `-p <dir>`. For a quick test, `--no-logging` writes no logs at all.

### make install fails: "/usr/bin/install: invalid group 'kismet'"

**Cause.** One of Kismet's own helpers (`kismet_cap_rz_killerbee`, built when libusb is found) is installed with the group `kismet` even by a plain `make install`, and the system has no such group. WSL2 had none.

**Fix.** Either create the group (`sudo groupadd kismet`), or name another group when you install:

```bash
make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)    # into a prefix in your home, no sudo (as on the Pi)
make install INSTGRP=root SUIDGROUP=root                                # as root (as in WSL2)
```

See [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).

### make prints: "'Makefile.in' or 'configure' are more current than this Makefile"

**Cause.** `add-to-kismet.sh` regenerated `configure` (and, on its first run, changed `Makefile.in`) in a tree that had been configured before. It is a notice, not an error: `make` carries on and builds. But on a tree configured before the script's first run, the old Makefile does not know the helper, so `kismet_cap_esp32c5` is not built.
<!-- VERIFY: that make on a tree configured before add-to-kismet.sh builds without kismet_cap_esp32c5 (the notice itself was checked: Kismet's Makefile rule only echoes it, and GNU Make 4.3 printed it on every run, carried on and exited 0) -->

**Fix.** After the script's first run on a tree, and after an update that changed `kismet/capture_esp32c5/Makefile.in`, run `./configure` again with the same options as before, then `make`. Otherwise the notice can be ignored; it stops once `configure` has run again.

### Messages and exit codes that look wrong but are not

| What you see | Why it is fine |
|---|---|
| `ERROR: Tried to re-register duplicate alert FLIPPERZERO` | Printed at every start of this Kismet version, with or without these boards |
| `ALERT: ROOTUSER Kismet is running as root` in Docker | Kismet runs as root in the container |
| `INFO: (HTTPD) Could not read session data file, skipping loading saved sessions.` | A fresh install, with no API keys yet |
| `kismet --version` exits with 1 | Kismet does that by design |
| `kismet_cap_esp32c5 --list` prints to stderr and exits with 2 | Kismet's capture framework does that by design |
| `kismet_cap_esp32c5 --help` exits with 255 | The same |
| A running source still shows an old error text | Kismet keeps the last error after a re-open or a reconnect |

Scripts should check the printed text, not these exit codes.

## How to get debug logs

As in the first checks, the Linux commands use the home-directory install's `~/kismet-install/bin`. After a system-wide install, or in the Docker image, use the bare names.

### Kismet

Run Kismet in a terminal with `--no-ncurses`, so its log goes to the terminal:

```bash
~/kismet-install/bin/kismet --no-ncurses -c esp32c5-ttyACM0
```

- The C helper's messages appear in this log: `INFO: <text>` for a local source, `INFO: <source name> - <text>` for a remote one.
- Kismet also keeps its messages in the kismetdb log.
- Kismet's recent messages, including those the helpers send, are also in its REST API, which helps with a Kismet run as a service or in Docker: `curl -s -u admin:PASSWORD http://127.0.0.1:2501/messagebus/last-time/0/messages.json`. <!-- VERIFY: the route with 0 as the time returns all kept messages (kismet.md 10 lists /messagebus/last-time/<ts>/messages.json) -->
- In Docker: `docker compose logs kismet` (with `sudo` on the Pi), or `docker logs <container name>`. The entrypoint's own lines start with `[esp32c5-kismet]`, among them one `source: <definition>` per source and `Kismet starts with <n> source(s)`. The demo's fake board logs to `/tmp/fake-board.log` inside the container.

The state of every source, over Kismet's REST API (replace the login and address):

```bash
curl -s -u admin:PASSWORD http://127.0.0.1:2501/datasource/all_sources.json
```

<!-- VERIFY: this curl command as written (the tests polled this endpoint, but with their own scripts) -->

The fields that matter: `kismet.datasource.running`, `kismet.datasource.error`, `kismet.datasource.error_reason`, `kismet.datasource.num_packets`, `kismet.datasource.channel`, `kismet.datasource.hopping`, and `kismet.datasource.ipc_pid`, the process of a local source's helper. A local helper's command line holds only `--in-fd` and `--out-fd`, not the board, so `ipc_pid` is the way to find it.

### The C helper on its own

- `~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1` shows the boards it can use, without opening any port.
- Run as a remote helper against your own Kismet, it prints its messages to the terminal, which shows what a local source would do:

  ```bash
  export KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
  ~/kismet-install/bin/kismet_cap_esp32c5 --connect 127.0.0.1:2501 --source esp32c5-ttyACM0
  ```

  Replace `3F9A6C1E07B24D58A1C9E2F4608B7D35` with your API key, one with the `datasource` role.

<!-- VERIFY: this command as written with the current C helper -->

### The Python remote helper

Add `--debug`. It logs every protocol message except packets, the stop signal, and where the login came from. The log goes to stderr; on Linux, with the virtual environment in the repository folder, keep it in a file with:

```bash
.venv/bin/python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-ttyACM0 --debug 2> helper.log
```

In cmd on Windows, `2> helper.log` works the same way. In Windows PowerShell 5.1, `2>` wraps the first line in error-record text (`NativeCommandError`, `CategoryInfo`). Run the command through cmd to get a clean file:

```powershell
cmd /c "python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-COM14 --debug 2> helper.log"
```

### USB and the board

- On Linux: `ls -l /dev/serial/by-id/` for the boards and their MACs, `lsusb -d 303a:1001` for what is on the bus, and `sudo dmesg | grep -i usb` for connects and disconnects.
- The board's own log is on its UART0, not on the USB port: 115200 baud, TX on GPIO11. Every 10 s it prints a status line with the channel, the frames captured and its drop counters, which nothing else reports. See [Firmware Protocol](Firmware-Protocol).

### When you report a problem

Include:

- `~/kismet-install/bin/kismet --version` and `~/kismet-install/bin/kismet_cap_esp32c5 --version`;
- the firmware build: the `App version:` line of the board's UART0 boot log, or whether the one-time BTLE repair message appears;
- the Python remote helper's version, which it reports to Kismet as the source's version (`esp32c5_kismet-0.1.0`);
- the source definition, the platform, and the log lines around the problem, with `--debug` for the Python remote helper.

See [Contributing](Contributing).

## Related pages

- [Source Definitions](Source-Definitions): every form of a definition, and what each helper accepts.
- [Kismet Configuration](Kismet-Configuration): config files, login, API keys, logging.
- [Firmware Protocol](Firmware-Protocol): what the board does and says.
- [Hardware](Hardware): boards, hubs and cables.
- [FAQ](FAQ): short answers to common questions.
