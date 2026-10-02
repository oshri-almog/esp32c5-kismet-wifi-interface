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

   Each board shows up with its MAC. On Linux, `--list` in both helpers leaves out a board that a source is using; the Python remote helper names it in a line `Left out, in use by another capture: <port>`. On Windows every board is listed. `kismet_cap_esp32c5 --list` writes to stderr, so add `2>&1` when you pipe it (for example into `grep`) or send it to a file.

2. **What does Kismet say about the source?** A working local source logs `<name> capturing (wifi)` (or `zigbee`, `btle`). Kismet puts a remote source's name in front of its messages, so a remote source, from either helper, shows `<source name> - <name> capturing (wifi)`, and the Python remote helper's own log shows `<name> capturing (wifi)`. A failing one shows its reason in the **Data Sources** panel and in Kismet's log. For a local source the reason is followed by `Kismet will attempt to re-open the source in 5 seconds`. For a remote source Kismet instead waits for the helper to reconnect: `Remote sources are not locally reconnected; waiting for the remote source to reconnect to resume capture.` When a local source's helper gives up by itself, as after [15 seconds without a capture](#no-capture-from-the-board-on-devttyacm0-for-15-seconds), the source's error reads only `IPC connection closed`, and the reason is the `ERROR:` line just before it in Kismet's log. The tests read the sources' state through Kismet's REST API; the web UI was not checked in a browser.

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
- Kismet was built with the esp32c5 source, but `kismet_cap_esp32c5` is not in Kismet's `bin` directory (`helper_binary_path`): `make install` was not run, or `helper_binary_path=` in a config file replaced Kismet's directory. With `type=esp32c5`, Kismet instead stops at start: see ["kis_external tried to write with no io handler"](#kismet-stops-with-kis_external-tried-to-write-with-no-io-handler).

**Fix.**

1. Check that the helper is installed: `ls ~/kismet-install/bin/kismet_cap_esp32c5`. Then add `type=esp32c5` to the definition. Kismet then opens the source with the C helper directly, shows the helper's reason, and retries every 5 s:

   ```bash
   ~/kismet-install/bin/kismet --no-ncurses -c 'esp32c5:mode=zigbee,channel=27,type=esp32c5'
   ```

   Here the reason reads `esp32c5: channel=27 is not a channel the board can tune to in zigbee mode`.
2. If Kismet answers `Unable to find datasource for 'esp32c5'` instead, this Kismet has no esp32c5 source. Build one with it: [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support).
3. Correct the definition. [Source Definitions](Source-Definitions) has every form and the channels of each radio.

A definition named the helper's way whose board is missing (`esp32c5`, `esp32c5-kitchen`, `esp32c5zigbee-ttyACM9`) does not get this message from the current helper: the source is created, its open fails with the real reason, and Kismet retries until the board is there. On the test Raspberry Pi with four boards plugged in, a bare `esp32c5`, `esp32c5zigbee` and `esp32c5btle` each failed with `4 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, ...` and were retried every 5 to 6 s. Kismet also logged `Conflict of new datasource <name>/00000000-0000-0000-0000-000000000000 and existing datasource <name> with the same UUID.` for each such source after the first: a source whose open failed has no UUID yet, and each was retried all the same. Helpers built before this change said "Unable to find driver" for a bare `esp32c5` with no board or with several. If yours does, update it ([Guide: Updating](Guide-Updating)).

### "no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found" or "2 Espressif USB-Serial-JTAG devices ... found"

```text
no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition
2 Espressif USB-Serial-JTAG devices (USB ID 303a:1001) found, and every ESP32 on native USB has that ID; say which one with device= or a source name like esp32c5-ttyACM0
```

**Cause.** The definition names no port (`esp32c5`, `esp32c5zigbee`, `esp32c5-kitchen`), so the helper looks for the only board plugged in, and finds none or several. Every ESP32 on its native USB port counts, not only sniffers. The Python remote helper's text also lists the ports it found, in parentheses after `found`.

**Fix.** Plug the board in; Kismet retries every 5 s and picks it up. With several boards, name one: `esp32c5-ttyACM0`, or better its by-id link, `esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00`. On macOS and the BSDs the C helper cannot look for boards at all (`finding a board by itself needs Linux sysfs ...`): always name the port there. Neither helper has been run on macOS or the BSDs.

### "cannot open /dev/ttyACM0: Permission denied"

**Cause.** The user Kismet runs as may not read and write the port. On Debian, Ubuntu and Raspberry Pi OS the boards' ports belong to the group `dialout` (`crw-rw---- root dialout`).

**Fix.** Add the user to the group, then log out and back in:

```bash
sudo usermod -aG dialout $USER
```

The helper needs nothing more: no root, no setuid. On the tested Raspberry Pi the user was already in `dialout`, so this fix was not needed there, and it has not been tried on a system where the user was not.

### "cannot open /dev/ttyACM9: No such file or directory"

**Cause.** The port named in the definition does not exist: the board is not plugged in, or it came back under another number. The helper waits for a named port rather than taking another board, so Kismet retries every 5 s.

**Fix.** Plug the board in, or check its number with `ls -l /dev/serial/by-id/`. Name boards by their by-id link, which stays with the board whatever ttyACM number it gets.

### "... is already in use by another capture ..."

```text
/dev/ttyACM0 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time
```

**Cause.** A board captures with one radio at a time, and each helper holds its port exclusively: it takes a lock on the port (`flock`), and puts the port in exclusive mode, so that any other open of it fails, whether or not that program takes the lock, unless it runs with `sudo`. Something else has it:

- another source on the same board, often the same board's other radio picked in the Data Sources panel (`esp32c5zigbee-ttyACM0` while `esp32c5-ttyACM0` runs);
- the other helper: the C helper and the Python remote helper take the same lock and keep each other out;
- esptool, which takes the same lock;
- a serial monitor. Of those tried on Linux, `picocom` and pyserial's `miniterm` take the same lock and `screen` puts the port in exclusive mode, so each of them keeps the helpers out while it has the port. `screen` goes on holding the port after its terminal is closed or killed: `screen -ls` shows the detached session, and `screen -X -S <session> quit` ends it. `idf.py monitor` was not tried;
- on Windows, any program that has the COM port open, a serial monitor included: a COM port has only one user at a time. A wedged board shows the same way on Windows: see [error 31](#windows-error-31-a-device-attached-to-the-system-is-not-functioning).

A program that takes neither lock, such as `minicom`, is refused when it opens the port after a helper. One that opened the port first does not keep the helpers out, though: they open the board alongside it, and the capture fails ([no capture for 15 seconds](#no-capture-from-the-board-on-devttyacm0-for-15-seconds)). The Python remote helper then logs `<name>: device reports readiness to read but returned no data (device disconnected or multiple access on port?), reconnecting`. Close `minicom` before you start a source.

When a helper opens the port again during a capture, after the board rebooted or dropped off USB, it shows the same condition as `<name>: <that message>; waiting for it`, and keeps trying. When the Python remote helper cannot open the port at the start of a connection, it says `<name>: <that message>` without `; waiting for it`, ends the connection with `<definition>: connection ended: <that message>`, and tries again 5 s later.

On Linux, a remote helper also looks before it connects, and does not offer a board that another program holds to Kismet, since the source could only fail. That check sees only the lock (`flock`), so it sees the helpers, esptool, `picocom` and `miniterm`, but not `screen` or `minicom`: a board one of them holds is listed by `kismet_cap_esp32c5 --list` and offered all the same, and its source then fails as above ("already in use" with `screen`, a capture that fails with `minicom`). It says `<name>: /dev/ttyACM0 is already in use by another capture; not offering it to Kismet until it is free (looked at again every 5 seconds)`: the C helper as `FATAL: Could not probe local source prior to connecting to the remote host: <that text>` every 5 s on its terminal, the Python remote helper once, as a warning in its log. It connects once the port is free.

**Fix.** Close the other source, or the other program. To change a board's radio, close its source and open one for the other radio; the board reboots, and in the hardware runs of 2026-10-02 the new source was capturing about 1.5 to 2 s after it opened.

The Python remote helper also refuses at startup, with exit code 2, two definitions for one board (`esp32c5-COM14 and esp32c5:device=com14,mode=zigbee both want COM14`) and two that name no port.

In Docker the exclusive mode also holds between a container and the host, although each container makes its own device node, which the `flock` does not cover. On the test Raspberry Pi, opening a board from the host while the `kismet` container captured from it failed with `Device or resource busy`, and the container kept capturing. Between two containers it should hold the same way, since the exclusive mode belongs to the port and not to a device node, but that has not been tried. Three gaps remain: a program run with `sudo`, such as `sudo esptool`, is let through; `screen` and `minicom` are invisible to the check before connecting, as above; and so is the lock of a program in another container, or on the host when the helper runs in a container. Such a board is then listed by `--list` and offered, and its open fails with "already in use". On the test Pi, the Python remote helper's `--list` on the host listed the boards the `kismet` container was capturing from, so on a machine with a container, a board in that list is not proof that it is free.

<a id="capture-tool-not-installed"></a>

### Kismet stops with "kis_external tried to write with no io handler"

```text
Uncaught exception "kis_external tried to write with no io handler"
```

A source defined with `type=esp32c5` at start (with `-c`) makes Kismet stop with this line and a stack trace (exit status 134). One added later through the REST API (`add_source.cmd`) is refused with `ERROR: kis_external tried to write with no io handler` (HTTP 500), and Kismet keeps running. Kismet at this commit (`cfe427074`) never says that the helper is missing: its code has the reason `Capture tool not installed` for this case, but it fails while it reports that reason, so the text is never shown. Without `type=`, the same problem shows only as ["Unable to find driver"](#unable-to-find-driver-for-esp32c5), because Kismet keeps the probe's reason to itself.

**Cause.** Kismet runs capture helpers only from its own `bin` directory (`helper_binary_path`), and `kismet_cap_esp32c5` is not there.

**Fix.** Run `make install` in the Kismet tree after building it, so the helper lands next to `kismet`: for example `ls ~/kismet-install/bin/kismet_cap_esp32c5`. If you set `helper_binary_path=` in `kismet_site.conf`, change it to `helper_binary_path+=`, which adds a directory instead of replacing Kismet's. See [Kismet Configuration](Kismet-Configuration).

### Docker: a capture helper crashes with signal 11

The image needs no added capability: `kismet_cap_esp32c5` drops every capability it has as soon as it starts, and needs none. On the test Raspberry Pi the `kismet` service captured from four boards with Docker's default capabilities. The crash below concerns Kismet's other capture helpers, or an image built before this change.

**Symptom.** In a container, Kismet's list of interfaces, which the web UI's **Data Sources** list asks for, never answers. With an image built before this change, no esp32c5 source starts either: Kismet logs only `cancelling source probe due to timeout` or `Unable to find driver`, and the `helper` role's log shows `capture process exited 0 signal 11`.

**Cause.** Kismet's other capture helpers, run as root, keep the `NET_ADMIN` and `NET_RAW` capabilities and drop the rest. Docker's default set lacks `NET_ADMIN`, and without it they crash as soon as they start. The image's `kismet_site.conf` masks their source types (`mask_datasource_type=`), so Kismet does not start them. They come back if you mount a `kismet_site.conf` of your own that leaves out those lines, or define a source of such a type with `type=`. In images built before `kismet_cap_esp32c5` dropped all its capabilities, it crashed the same way.

**Fix.** Keep the `mask_datasource_type=` lines in a `kismet_site.conf` of your own ([Docker Reference](Docker-Reference)). For a source of one of Kismet's other types, the container needs `--cap-add NET_ADMIN` (or `cap_add: [NET_ADMIN]` in a `compose.override.yaml`); that has not been tried. For an older image, rebuild or pull the current one ([Guide: Updating](Guide-Updating)).

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

On the test Raspberry Pi, with four real boards and the current image, the `kismet` service found and captured from all four, and a plain `docker run` without the device rules printed the hint above, one pair of lines per board.

## The source opens but never captures

### "no capture from the board on /dev/ttyACM0 for 15 seconds"

```text
c5-wifi: no capture from the board on /dev/ttyACM0 for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?
```

The Python remote helper adds the board's last status, for example `esp32c5-COM14: no capture from the board on COM14 for 15 seconds (last: esp32c5-COM14: COM14 opened); is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?`.

**Cause.** The port opened, but the board has not been capturing for 15 s: no valid stream in the radio's link type came back. Where the text shows, and what happens next:

- **A local source** (Kismet runs the C helper): Kismet's log has `ERROR: <that text>`. The helper ends, and Kismet re-opens the source 5 s later. The source's error then reads only `IPC connection closed`: Kismet ignores the error report the helper sends with it, so look in the log.
- **The remote C helper:** Kismet's log has `ERROR: <source name> - <that text>`, and the source's error reads `websocket connection closed`. The helper's own terminal does not show it. The helper connects again 5 s later.
- **The Python remote helper:** its log has it as an ERROR, and Kismet shows it as the source's error, `remote connection triggered shutdown: <that text>`. The helper connects again 5 s later.

Likely reasons, most likely first:

1. The board does not run the sniffer firmware, or it is another ESP32 with the same USB ID.
2. The board is latched in its ROM download mode after flashing. The sibling project's web flasher page reports this on two of the three boards it was developed against; it is a quirk of the board, not of the firmware.
3. Another program talks to the port without taking the helpers' lock, such as a serial terminal.
4. On Windows, the board is wedged ([error 31](#windows-error-31-a-device-attached-to-the-system-is-not-functioning)).
5. The firmware is an older sibling build that lacks the radio asked for; the log then also shows `lost sync (the board sends link type 127, not 256)` or similar.
6. In the first hardware run, all four boards came with the sibling project's 1.2.0 build (app version `5cdab32-dirty`). Two of them streamed Wi-Fi but did not answer `START` within 3 s in the flashing script's check. The cause was not found. After this project's firmware was flashed (an earlier build than the current one), all four worked.
7. The board hung in a radio switch: it dropped off USB for a moment, came back, and then never answered. Kismet's re-opens do not cure it; resetting the board does ([A board stops answering after a radio switch](#a-board-stops-answering-after-a-radio-switch)).

**Fix.** Unplug the board and plug it back in, or press its reset button (RST or EN on many boards), which restarts the chip much as a replug does. Close any serial terminal. For a board that hung in a radio switch, see [the next section](#a-board-stops-answering-after-a-radio-switch). If none of this helps, flash the current firmware: [Flashing the Firmware](Flashing-the-Firmware).

### A board stops answering after a radio switch

**Symptom.** A source on a board that has just changed radio never starts capturing. The board's USB device went away during the switch and came back, so the helper first says `<name>: port closed, reconnecting` (the C helper) or `<name>: device reports readiness to read but returned no data (device disconnected or multiple access on port?), reconnecting` (the Python remote helper). That alone is harmless: most times the source then captures about 2.5 to 3 s after it was launched. A board that hangs sends nothing after it. The helper says `<name>: no answer, reconnecting`, gives up after 15 s with `<name>: no capture from the board on /dev/ttyACM0 for 15 seconds; ...` ([see above](#no-capture-from-the-board-on-devttyacm0-for-15-seconds)), and tries again 5 s later, with the same result each time.

**Cause.** Not established: the board's firmware, or the power on its hub port. On the test Raspberry Pi (2026-10-02, four boards on a powered hub, firmware image 01a50bd6), only one board did this, always on the same hub port; the other three never dropped off USB in the tests below.

- **At a fresh Kismet start with sources for mixed radios**, that board switched from Wi-Fi to BLE while two other boards changed radio at the same moment, one to Wi-Fi and one to 802.15.4. It dropped off USB every time, 28 times in 28. Most times it came back and captured; once it sent nothing for several seconds, then captured without help, about 7.7 s after it was launched; and 4 times it then answered nothing until it was reset. All 4 were under the C helper (4 of 18 tries, against 0 of 10 under the Python remote helper: too few to blame one helper).
- **Switching alone, or with one other board switching,** it never dropped off USB (28 tries).
- **In ordinary switches made right after a capture,** each of the four boards switched between Wi-Fi and BLE ten times under each helper. None of the 80 switches to BLE hung or dropped off USB, and 1 of the 80 switches back to Wi-Fi hung (the same board, under the Python remote helper): 1 in 160 in all.
- After the reset the board came up in the radio it had been switching to, so it had stored its new radio before it went silent.

**Fix.** esptool needs the port, so free it first: stop the remote helper, or close the local source in Kismet or stop Kismet. Then reset the board with esptool, set up as on [Flashing the Firmware](Flashing-the-Firmware#get-esptool). Give the board's port; on Windows that is a COM port, such as `COM14`:

```bash
python -m esptool --chip esp32c5 -p /dev/ttyACM0 read_mac
```

`read_mac` resets the board when it finishes, which cured every such hang in the tests. Unplugging the board and plugging it back in also brings it back. Either way the board comes back on the radio it was switching to. Kismet's re-opens and the helpers' retries do not cure it, so a machine that runs unattended cannot recover by itself. To avoid it, keep each board on the same radio from one Kismet start to the next: a board remembers its radio, so then no board has to switch at the start.

### A board sends `<<START>>` and then goes quiet

**Symptom.** With a serial terminal or your own program, not the Kismet helpers: after a reset the board sends `<<START>>` and a PCAP header, then nothing on the Wi-Fi channels you asked for. It looks like a hang.

**Cause.** The board remembers its radio and boots into it. A board last used for Zigbee or Bluetooth LE comes up on that radio, and ignores Wi-Fi.

**Fix.** Send `MODE WIFI` (or the radio you want) before `START`. It costs nothing when the board is already on that radio. The Kismet helpers always do this, so the problem does not arise under Kismet. Flashing the merged image or erasing the flash also resets the board to Wi-Fi; `idf.py flash` keeps the stored radio. See [Firmware Protocol](Firmware-Protocol). A board that was on 802.15.4 when it was flashed can come up with a deaf Wi-Fi radio: see the next section.

### A board that ran Zigbee captures no Wi-Fi

**Symptom.** A Wi-Fi source on a board that was used for 802.15.4 says `<name> capturing (wifi)` and shows no error, but its packet count stays at 0 while other boards see traffic on the same channels.

**Cause.** A known firmware problem. By the firmware's own notes, the board's 802.15.4 radio was left powered and configured when the chip was reset without shutting it down first, and Wi-Fi then receives nothing. esptool's reset after flashing does that: in the tests, a board that was in 802.15.4 mode when it was flashed came up deaf 2 times out of 2, while a flash from Wi-Fi mode worked. The firmware's own radio switch (`MODE`) shuts the old radio down before it reboots, which keeps the problem rare there: in the sibling project's measurements, nine of nine switches on two boards left Wi-Fi working. The helpers cannot tell: once a source is capturing, silence is just a quiet channel.

**Fix.** Switch the board to Bluetooth LE and back. Open a Bluetooth LE source on it (`esp32c5btle-ttyACM0`) until it logs "capturing", close it, and open the Wi-Fi source again; or send `MODE BLE`, then `MODE WIFI`, from a serial terminal. That cured the deaf board in the tests; an esptool reset did not. The firmware's notes say that removing power also clears it, which these tests did not try. To avoid it, put the board on Wi-Fi before you flash it: run a Wi-Fi source on it, or send `MODE WIFI`. See [Flashing the Firmware](Flashing-the-Firmware).

### Windows: error 31, "A device attached to the system is not functioning"

**Symptom.** esptool fails with:

```text
A fatal error occurred: Could not open COM30, the port is busy or doesn't exist.
(Cannot configure port, something went wrong. Original message: PermissionError(13, 'A device attached to the system is not functioning.', None, 31))
```

The port is still listed, with its MAC, by `--list`. An older Python remote helper logged `COM30: Write timeout`, then the same `Cannot configure port ...` text about once a second. The current one reads that error as a port another program holds. At the start of a connection it says `<name>: COM30 is already in use by another capture (an esp32c5 source or another program holds it); a board captures with one radio at a time`, ends the connection with `<definition>: connection ended: COM30 is already in use ...`, and tries again 5 s later; during a capture it says the same with `; waiting for it` at the end, and keeps trying. That is read from its code: no board has wedged this way under the current helper yet. If the helper says a port is in use and no other program has it, try esptool on it: error 31 means this.

**Cause.** Windows' USB device for that board is in a bad state. The same board had passed every test on the Pi an hour earlier, so the board and firmware were fine. A likely trigger is a program that opened the port with default DTR and RTS, which resets the chip; right after such an open, two boards briefly vanished.

**Fix.** Unplug the board and plug it back in, or power-cycle the hub. Other boards on the same helper keep capturing, and the helper keeps trying the port, so it picks the board up once it works.

<!-- VERIFY: error 31 with the current Python remote helper on Windows (its code, board.port_busy_error, takes it for a busy port: "already in use ..." at a connection's first open, "...; waiting for it" on a reopen during a capture); the exact trigger of the wedge; and that a replug clears error 31 (reported, not logged) -->

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

The board only ever sends whole records, so frequent "bad header" or "damaged record" messages mean bytes are lost or mangled between the board and the helper. Check the cable and the hub, and make sure no other program has the port open. This follows from how the firmware sends its records; the tests never saw it happen with a real board, only with the fake board's deliberately damaged records.

### A listed board is not an ESP32-C5 sniffer

**Symptom.** `--list` shows a board you did not expect, a bare `esp32c5` reports two devices when you have one sniffer, or the Docker image adds a source that never captures.

**Cause.** Every Espressif chip with a native USB-Serial-JTAG port (the ESP32-C3, C5, C6, H2, S3, P4 and others) has the USB ID `303a:1001`. The helpers cannot tell a sniffer from any other ESP32 by its ID.

**Fix.** Name the sniffers' ports, preferably by their `/dev/serial/by-id/` links. In Docker, list them in `KISMET_SOURCES` instead of letting the image find boards.

To stop Kismet offering such a board in its list of interfaces, which the Data Sources panel shows, hide each of its names in `kismet_site.conf`. For a board that is not a sniffer on `/dev/ttyACM3`:

```ini
mask_datasource_interface=esp32c5-ttyACM3
mask_datasource_interface=esp32c5zigbee-ttyACM3
mask_datasource_interface=esp32c5btle-ttyACM3
```

The names follow the `ttyACM` number, which can change after a replug. On the test Raspberry Pi these three lines removed that board's three entries from Kismet's interface list, read through the REST API; the panel itself was not looked at in a browser.

### Boards drop off the bus, or fail in ways that look like firmware bugs

**Symptom.** Boards disappear from `--list` and `/dev/serial/by-id/`, sources reconnect again and again, or errors come and go with no pattern.

**Cause.** Usually power or cabling. The sibling project found that an unpowered hub browns out under four sniffers and produces failures that look like firmware bugs. The tested setups used a powered hub. In one test run two boards "disappeared" because they had been unplugged by hand, so check that first.

**Fix.** Use a powered USB hub and known-good data cables. Look for disconnects in the kernel log:

```bash
sudo dmesg | grep -i 'usb disconnect'
lsusb -d 303a:1001
```

Then replug the boards, or power-cycle the hub. A board missing from `--list` is not on the bus; that is not a helper fault. See [Hardware](Hardware).

A disconnect and reconnect of one board when a source on it switches radio can happen: the board reboots, and its USB device sometimes goes away with it for about 0.3 to 2.5 s. Both helpers wait for it and find it again by its MAC, even under another `ttyACM` number. The C helper then says `<name>: port closed, reconnecting`, and the Python remote helper `<name>: device reports readiness to read but returned no data (device disconnected or multiple access on port?), reconnecting`. One test board dropped off USB at every Kismet start that switched it together with two other boards, and a few times then stopped answering ([A board stops answering after a radio switch](#a-board-stops-answering-after-a-radio-switch)); giving each board the same radio from one Kismet run to the next avoids switches at the start.

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
- **The firmware lacks 802.15.4** (the sibling's 1.0.0): the source never says "capturing", logs `lost sync (the board sends link type 127, not 283)`, and gives up after [15 seconds](#no-capture-from-the-board-on-devttyacm0-for-15-seconds). Flash the current firmware.

Kismet's 802.15.4 device records have no PAN field; that is Kismet, not a fault. Nor is the frequency 0 that the kismetdb log stores for every 802.15.4 and Bluetooth LE packet: Kismet does not copy the frequency there for these two radios, whatever the helper sends. The device records show the right frequency.

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

**Some advertisers never appear.** Kismet drops, without a word, every advertisement whose advertising data ends in zero padding, so such an advertiser never becomes a device. In the tests, three advertisers of one maker (GREE, MAC prefix `50:2C:C6`) ended theirs in nine zero bytes. Their packets are still in the pcapng and kismetdb logs. That is Kismet, not a fault.

### The source stays on channel 6 or 15, although the definition says otherwise

**Causes and fixes.**

- `channel=` on its own only adds the channel to the hop list. Add `channel_hop=false` to stay on it: `esp32c5zigbee-ttyACM0:channel=20,channel_hop=false`. On the test boards that held 802.15.4 on 20 and Wi-Fi on 36 with both helpers.
- Helpers built before the `channel=` fix, including those used in the first hardware run, ignored `channel=` entirely. Update them, or set the channel from the web UI or with the REST call `set_channel.cmd` and `{"channel":"20"}`, which worked in the tests.
- The channel set was one the radio does not have, such as 40 in Bluetooth LE mode. The source keeps capturing on the channel it was on (a hopping source stops hopping there, as after any channel set), the REST call still answers HTTP 200, and Kismet logs why: `ERROR: <name> cannot tune to channel 40 in btle mode` for a local source, `ERROR: <source name> - <name> cannot tune to channel 40 in btle mode` for a remote one. Both helpers answer this way, as a BTLE board on the test Raspberry Pi showed with the C helper, local and remote, and with the Python remote helper.
- A remote source that reconnects under a UUID Kismet already knows keeps every option of its earlier definition that the new one leaves out, until Kismet restarts; options the new definition gives replace the old ones. After a session with `channel_hop=false`, a plain `esp32c5-ttyACM0` from either remote helper stays locked. Write `channel_hop=true` in the definition, or restart Kismet.
- While a source hops, Kismet keeps showing its start channel in the source's channel field: 6 for Wi-Fi, 15 for 802.15.4, 37 for Bluetooth LE, with every helper. Each packet's channel is the real one. Look at the frequencies of the packets instead.

## Remote capture

### Windows: every connection to Kismet on localhost takes 2 s longer

**Symptom.** From Windows, `--connect localhost:2501` to Kismet in WSL2 is about 2 s slower than `--connect 127.0.0.1:2501`. Older Python remote helpers, and other tools, take about 2 s to connect. The current helper connects at once while Kismet is up, but while Kismet is down each of its attempts fails about 2 s later, so its ERROR lines come about 9 s apart instead of about 7.

**Cause.** Windows resolves `localhost` to the IPv6 address `::1` first, and takes about 2 s to give up on it. WSL2's port forwarder listens on `127.0.0.1` only, so `::1` is refused. Measured: 2.067 s through `localhost`, 0.001 s through `127.0.0.1`. Docker Desktop was not measured separately.

<!-- VERIFY: Docker Desktop and localhost. A port it publishes without an address (compose's kismet service, "2501:2501") answered on ::1 in 0.03 s in a quick check with another container, so it may not have the delay; one published on 127.0.0.1 (the demo service) may refuse ::1 as WSL2 does -->

**Fix.** Use `127.0.0.1` rather than `localhost`. The current Python remote helper, given `localhost`, dials `127.0.0.1` first by itself and `::1` only if that fails, but other tools do not. On Windows 11 against Kismet in WSL2 it connected 0.36 s after it started; only its refused attempts, which try both addresses, stay slower.

### The C helper over the websocket takes about 5 s to start, then sends in bursts

This is fixed by the current `add-to-kismet.sh`. A Kismet tree patched by an older copy of the script still shows it.

**Symptom.** With `kismet_cap_esp32c5 --connect`, the first packet reaches Kismet about 5 s after the helper starts, and later packets arrive in bursts about 5 s apart.

**Cause.** Kismet's own capture framework, which the C helper is built with, asked for each websocket write from the wrong thread, so every write waited for Kismet's next PING, which comes every 5 s. `add-to-kismet.sh` patches the framework. With the patch as it was in an earlier hardware run, on the test Raspberry Pi, the first packet arrived after 1.2 s (the median of five runs), with no bursts, as quickly as with the Python remote helper or over `--tcp`. The script has changed the patched framework since (the login now goes in a header, and redirects are refused); with those changes the first packet arrived after about 0.9 s, with no bursts, in the end-to-end test with the fake board, in WSL2 and on the Pi. They have not been timed with a real board.

**Fix.** Run the current `add-to-kismet.sh` on your Kismet tree, then `make` and `make install` again ([Guide: Updating](Guide-Updating)).

### The login is refused

**Symptom.** The Python remote helper logs, every 5 s:

```text
Kismet refused the websocket: 401 Unauthorized (check the login -- --user/--password or KISMET_CAP_USER/KISMET_CAP_PASSWORD -- or the API key -- --apikey or KISMET_CAP_APIKEY; the key needs the datasource role)
```

An older helper prints `Handshake status 401 Unauthorized` there, followed by Kismet's whole answer, its HTML page included, over several lines. The C helper prints a libwebsockets line that ends `got bad HTTP response '401'`, then `FATAL: Datasource could not connect websocket client`, and tries again 5 s later. With no login at all, the C helper stops with `FATAL: User and password or API key required for remote capture`, and the Python remote helper with `a user and password, or an API key, are required for the websocket protocol (...)`.

**Causes and fixes.**

- No login was given at all: pass `--apikey`, or `--user` and `--password`, or set `KISMET_CAP_APIKEY` (or `KISMET_CAP_USER` and `KISMET_CAP_PASSWORD`) in the environment.
- The key has the wrong role. Remote capture needs the `datasource` role (or `admin`); a `readonly` key is refused.
- The user name contains `:` and the login (user name or password) contains `&`. Such a login cannot log in, and both helpers warn at start: `WARNING: the Kismet user name holds ':' and the login '&': Kismet reads a user name in an Authorization header only up to its first ':', and cuts a login in the websocket's address at every '&' (after decoding it), so this one cannot log in either way; use an API key (--apikey or KISMET_CAP_APIKEY) instead of the login`. Use an API key, or a user name without `:`.

Any other login goes through, a password with `&`, a space or `%41` in it included: both helpers send a login in an HTTP `Authorization` header and an API key in Kismet's session cookie, not in the websocket's address. A user name with `:`, which that header cannot carry, goes in the address instead, and logs in as long as the login has no `&`. On the test Raspberry Pi both helpers captured with a login and with an API key, given on the command line and in the environment, and a logging proxy in front of Kismet found the login only in the `Authorization` header and the key only in the cookie. A user name with `:` logged in through the address with both helpers.

Helpers from before this change put every login in the address, where `&`, a space or `%` followed by two hex digits broke it. Update them ([Guide: Updating](Guide-Updating)). For the C helper, the login is sent by Kismet's capture framework as `add-to-kismet.sh` patches it, so run the current script on your Kismet tree and build again.

The C helper also refuses a login too long for the websocket request, with `FATAL: The login does not fit in the websocket request's headers, which have <n> bytes left for it; use a shorter one, or an API key` (with libwebsockets 4.3.3, a user name and password of up to about 2800 bytes together fit), and an API key too long for it with `FATAL: The API key does not fit in the websocket request's headers, which have <n> bytes left for it; the keys Kismet makes have 32 characters`.

Create a key as shown in [Kismet Configuration](Kismet-Configuration).

### "The websocket was answered with a redirect"

```text
FATAL: The websocket was answered with a redirect (HTTP <status> to <where>), which is not followed: Kismet never redirects it, and the login would go along to wherever it points; check --connect, --endpoint and --ssl
```

The Python remote helper says `the websocket was answered with a redirect (HTTP <status> to <where>), which the helper does not follow: ...`, with the same ending. `<where>` is the address the redirect points to, cut at its first `?` or `#` (shown as `?...` or `#...`) so that a login in it is not printed; ` to <where>` is left out when the answer names no address. A C helper built with libwebsockets older than 4.0 prints the line without `(HTTP ...)`.

**Cause.** Something between the helper and Kismet, usually a reverse proxy, answered the websocket request with a redirect: to `https://`, to another path, or to a sign-in page. Kismet itself never does. Neither helper follows it, because the login or API key would go along to wherever it points. Each attempt fails, and the helper tries again 5 s later. This was tested against stand-in servers, in the tests and on the test Pi with real boards, not against a real proxy.

**Fix.** Point the helper where the proxy expects it: `--ssl` for a proxy that serves `https://`, `--endpoint` for one that adds a path prefix, or `--connect` straight to Kismet. See [Remote Capture](Remote-Capture).

### "FATAL: Could not probe local source prior to connecting to the remote host"

**Cause.** A remote C helper checks its definition before it connects, and the reason follows the colon:

- the definition names no port (a bare `esp32c5`, or a free-form name such as `esp32c5-kitchen`), and the helper found no board or more than one; the reason reads like the local ones above, for example `no Espressif USB-Serial-JTAG device (USB ID 303a:1001) found; plug the board in, or give device= in the source definition`;
- the definition is wrong in itself: a `mode=` that is not a radio, or a `channel=` the radio does not have;
- another program holds the board (see ["... is already in use ..."](#-is-already-in-use-by-another-capture-)).

A definition that names a port (`esp32c5-ttyACM0`, `device=`, a by-id link) does not stop here when the port is missing: the helper connects, prints `ERROR: cannot open /dev/ttyACM9: No such file or directory`, and Kismet logs `Data source 'esp32c5-ttyACM9 / esp32c5-ttyACM9' ('esp32c5-ttyACM9') encountered an error: cannot open /dev/ttyACM9: No such file or directory` and `Error connecting new remote source esp32c5-ttyACM9 (<uuid>) - cannot open /dev/ttyACM9: No such file or directory`, and lists no source for it. That `<uuid>` is made from the path, as there is no board to read a MAC from; once the board is there, the source comes up under its usual one.

Either way, unless it was started with `--disable-retry`, the helper tries again every 5 s by itself, printing the reason each time, then `INFO: Sleeping 5 seconds before attempting to reconnect to remote server`. Kismet sees nothing of a failed check.

**Fix.** Plug the board in, name its port, or correct the definition. A board plugged in later is picked up at the next try.

### "Connection refused", or "Datasource could not connect websocket"

```text
ERROR: esp32c5-COM14: [WinError 10061] No connection could be made because the target machine actively refused it
ERROR: esp32c5-ttyACM0: [Errno 111] Connection refused
FATAL: Datasource could not connect websocket
```

**Cause.** Nothing listens at the address and port given: Kismet is not running yet, or the address or port is wrong. Both helpers wait 5 s after each failed attempt and try again, so a helper started before Kismet connects once Kismet is up. On Windows a refused connection itself takes about 2 s to fail, so the Python remote helper's ERROR lines come about 7 s apart there.

**Fix.** Check that the server logs `HTTP server listening on 0.0.0.0:2501`, and that the helper connects to that port. From another machine, the Kismet machine's firewall must let the port through. A Kismet in WSL2 and one in Docker Desktop both want `localhost:2501`; give one of them another host port.

### Kismet says "Kismet could not find a datasource driver for incoming remote source 'esp32c5'"

**Cause.** The Kismet server was built without this project's source. A stock Kismet cannot take these boards.

**Fix.** Build Kismet with it ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)), or use the Docker image ([Install with Docker](Install-with-Docker)).

### Two entries for one board, or a source that comes back as a new one

**Cause.** Kismet recognises a remote source only by its UUID, and keeps a source in error in its list. The helpers make the UUID from the board's MAC and the radio (`E5C50001-0000-0000-0000-<MAC>` for Wi-Fi, `...0002...` for Zigbee, `...0003...` for BLE), so it stays the same across reconnects and ttyACM renumbering. Without the MAC (with the fake board, with a board that cannot be identified at that moment, or with the C helper on macOS and the BSDs, which have no Linux sysfs) the UUID comes from the port path as written, and another spelling of the path makes another source. The Python remote helper reads the MAC through pyserial, which should work on macOS too; that is untested.

Older versions of the Python remote helper also changed the UUID when a board was away for more than about 20 s, or when the helper started before the board was plugged in. The current version waits for the board instead. On the test Raspberry Pi it kept the UUID when it gave a silent board up and connected again; a board unplugged for more than 20 s has not been tried with it.

**Fix.** Keep a definition's port spelling the same, or name boards by their by-id links. If you need a fixed identity whatever happens, set `uuid=` in the definition. The stale entry stays listed in error and does no harm.

Two connections that present the same UUID at the same time replace each other: Kismet logs `Incoming remote connection for source '<uuid>' matches existing source '<name>', which is still running.  The running instance will be closed; ...`, and the running source stops. On Linux both helpers check before they connect whether another program holds the board, and wait while it does ([see above](#-is-already-in-use-by-another-capture-)), so this happens only where they cannot see the holder: with the Python remote helper on Windows, which has no such check (on the test PC two helpers for one board took the source from each other about every 15 to 20 s), or when the holder is in another container, or on the host while the helper runs in a container. Do not feed one board to Kismet from two helpers, for example from a service and from a copy started by hand.

Adding a local source for a board and radio that Kismet still lists as a remote source, even a closed one, is refused with `Conflict of new datasource <name>/<uuid> and existing datasource <name> with the same UUID.`, yet Kismet lists a second, dead entry for it all the same (5 tries of 5 on the test Raspberry Pi), and in one of the five Kismet crashed when the remote helper then came back. A new local source for a board and radio whose earlier local source was closed gets the same `Conflict` refusal. Within one Kismet run, keep to one kind of source for each board and radio, or restart Kismet in between.

### The remote source shows "websocket connection closed" after the helper stops

This is expected. Kismet never re-opens a remote source itself; the source returns when the helper connects again. After it does, Kismet may keep showing the old error text while the source runs. That is a display quirk of Kismet's.

The other way round, closing a remote source in Kismet (with the REST call `close_source.cmd`, for example) lasts only until its helper connects again, about 5 s later: the Python remote helper logs `connection ended: Connection to remote host was lost.`, the C helper `FATAL: Datasource websocket closed`, and both offer the source again. To keep a remote source closed, stop its helper.

### Python remote helper: "COM14 is not there; is the board plugged in? (waiting for it)"

**Cause.** The port named in the definition does not exist right now. The helper waits for it, logs this ERROR every 5 s, and does not offer the source to Kismet until the port appears, so that the board keeps its identity when it comes back. A definition without a port waits the same way for the board it found first: `the board <MAC> is not plugged in (waiting for it)`. On Windows a port counts as there when pyserial lists it, or when Windows knows a device by that name, which covers virtual COM ports from drivers such as com0com. A definition with `uuid=` skips the check.

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

Run the helper with `.venv/bin/python -m esp32c5_kismet.remote ...` from the repository folder. The current helper also survives the old versions and reconnects. If an internal error ends every source anyway, it exits with status 1, so a service manager can restart it.

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
| `<definition>: connection ended: no PING from Kismet for 15 seconds` | Kismet pings every 5 s. The network or the server stalled, and the helper reconnects 5 s later. |
| `<definition>: connection ended: Connection to remote host was lost.` | Kismet closed the connection: the source was closed in Kismet, or Kismet stopped. The helper reconnects 5 s later. |
| `<name>: no answer, reconnecting` | Before the board was capturing, its port sent nothing at all for 6 s, so the helper opens it again. The board may be in download mode, not running the sniffer firmware, or hung after it dropped off USB during a radio switch ([see above](#a-board-stops-answering-after-a-radio-switch)); in the hardware tests of 2026-10-02, every one of these lines came after such a drop. The C helper says the same. |
| `<name>: device reports readiness to read but returned no data (device disconnected or multiple access on port?), reconnecting` | The port went away under the helper, which opens it again: the board dropped off USB, usually during a radio switch, or another program such as `minicom` reads the port ([see above](#-is-already-in-use-by-another-capture-)). The C helper says `<name>: port closed, reconnecting`. |
| `<name>: COM14 now holds another board, looking for <MAC>`, then `<name>: board <MAC> is on COM15 now` | The board came back on another port. The helper follows it by its MAC for this connection. The C helper says the same on Linux. |
| `Removed 2 channels from the channel list because the source could not tune to them: 15, 38` | In Kismet's log, not the helper's: a hop list held channels the radio does not have, here in Wi-Fi mode. The rest are hopped. |

`<definition>` is the source's definition as given with `--source`; `<name>` is the source's name, its `name=` or else the part of the definition before the first `:`.

## Windows

### Ctrl+C does not stop the Python remote helper started from Git Bash with &

This is fixed in the current helper. An older copy still shows it.

**Symptom.** A helper started as a Git Bash background job ignored `kill -INT` and Ctrl+C.

**Cause.** Windows passes an "ignore Ctrl+C" setting from a process to its children, and Git Bash starts background jobs with it set. The current helper clears that setting when it starts: from Git Bash, `kill -INT $!` stopped a background helper in about 0.5 s, and Ctrl+C or Ctrl+Break in the same window stopped it too.

**Fix.** Update the helper ([Guide: Updating](Guide-Updating)). With an older one, run it in its own console window (Windows Terminal, PowerShell or cmd) and stop it with Ctrl+C or Ctrl+Break. For a background job, `taskkill /F /PID <pid>` is safe: the COM port is released at once, and Kismet shows the source in error with `websocket connection closed`.

`taskkill /PID <pid>` without `/F` never stops the helper, old or current: Windows answers `This process can only be terminated forcefully (with /F option).` It sends a window message, and a console program has no window to receive it.

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

**Cause.** `add-to-kismet.sh` changed `Makefile.in` or regenerated `configure` in a tree that had been configured before. It does that on its first run on a tree, and later only when a newer version of the script has new edits for them. It is a notice, not an error: Kismet's Makefile only prints it, and `make` carries on and builds. But on a tree configured before the script's first run, the old Makefile does not know the helper, so `kismet_cap_esp32c5` is not built: in a test on a freshly configured `cfe427074` tree, `make` after the script had no step for the helper.

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
| `W: lws_create_context: unreasonable ulimit -n workaround`, after a time stamp, in the log of the Docker `helper` service | The libwebsockets library finds the container's limit on open files unreasonably high, and works around it; one line per helper as it starts |
| A running source still shows an old error text | Kismet keeps the last error after a re-open or a reconnect |
| `Conflict of new datasource <name>/00000000-0000-0000-0000-000000000000 and existing datasource <name> with the same UUID.` | Several local sources whose first open failed, for example because their board could not be found: none has a UUID yet. Each is retried all the same |
| `esptool verify-flash` of the whole merged image fails with `Verification failed (digest mismatch).` once the board has booted | At its first boot about 2.2 KB of the NVS partition (0x9000 to 0x991b) is written, where the image holds blank bytes; what writes it was not identified. Verify `0x0` to `0x9000` and `0x10000` to the end instead, or verify before the first boot. See [Flashing the Firmware](Flashing-the-Firmware) |

Scripts should check the printed text, not these exit codes.

## How to get debug logs

As in the first checks, the Linux commands use the home-directory install's `~/kismet-install/bin`. After a system-wide install, or in the Docker image, use the bare names.

### Kismet

Run Kismet in a terminal with `--no-ncurses`, so its log goes to the terminal:

```bash
~/kismet-install/bin/kismet --no-ncurses -c esp32c5-ttyACM0
```

- The C helper's messages appear in this log: `INFO: <text>` for a local source, `INFO: <source name> - <text>` for a remote one, and `ERROR:` instead of `INFO:` for its errors. They do not appear on a remote C helper's own terminal, which shows its connection and its connection events, and why a board could not be probed or opened.
- Kismet also keeps its messages in the kismetdb log.
- Kismet's last 50 messages, including those the helpers send, are also in its REST API, which helps with a Kismet run as a service or in Docker: `curl -s -u admin:PASSWORD http://127.0.0.1:2501/messagebus/last-time/0/messages.json`.
- In Docker: `docker compose logs kismet` (with `sudo` on the Pi), or `docker logs <container name>`. The entrypoint's own lines start with `[esp32c5-kismet]`, among them one `source: <definition>` per source and `Kismet starts with <n> source(s)`. The demo's fake board logs to `/tmp/fake-board.log` inside the container.

The state of every source, over Kismet's REST API (replace the login and address):

```bash
curl -s -u admin:PASSWORD http://127.0.0.1:2501/datasource/all_sources.json
```

The fields that matter: `kismet.datasource.running`, `kismet.datasource.error`, `kismet.datasource.error_reason`, `kismet.datasource.num_packets`, `kismet.datasource.channel`, `kismet.datasource.hopping`, and `kismet.datasource.ipc_pid`, the process of a local source's helper. A local helper's command line holds only `--in-fd` and `--out-fd`, not the board, so `ipc_pid` is the way to find it.

### The C helper on its own

- `~/kismet-install/bin/kismet_cap_esp32c5 --list 2>&1` shows the boards it can use, without opening any port.
- Run as a remote helper against your own Kismet, it prints on the terminal why it cannot probe or open the board, which Kismet does not show for a local source defined without `type=`:

  ```bash
  export KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
  ~/kismet-install/bin/kismet_cap_esp32c5 --connect 127.0.0.1:2501 --source esp32c5-ttyACM0
  ```

  Replace `3F9A6C1E07B24D58A1C9E2F4608B7D35` with your API key, one with the `datasource` role. A reason shows as `FATAL: Could not probe local source prior to connecting to the remote host: <reason>` or `ERROR: cannot open /dev/ttyACM0: <reason>`. Once the source runs, the terminal shows `INFO: 127.0.0.1:2501 starting capture...`, and then only connection events: `FATAL: Datasource websocket closed` and `INFO: Sleeping 5 seconds before attempting to reconnect to remote server` when a connection ends, and `ERROR: <source name>: no PING from Kismet for 15 seconds; closing the connection` when Kismet has sent no PING for 15 s. The helper's status messages, such as `capturing (wifi)` and `lost sync`, go to Kismet's log as `<source name> - <text>`.

### The Python remote helper

Add `--debug`. It logs every protocol message except packets, the stop signal, and where the login came from. The log goes to stderr; on Linux, with the virtual environment in the repository folder, keep it in a file with:

```bash
.venv/bin/python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-ttyACM0 --debug 2> helper.log
```

In cmd on Windows, `2> helper.log` works the same way. In Windows PowerShell 5.1, `2>` wraps the first line in error-record text (`NativeCommandError`, `CategoryInfo`). Run the command through cmd to get a clean file:

```powershell
cmd /c "python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --apikey 3F9A6C1E07B24D58A1C9E2F4608B7D35 --source esp32c5-COM14 --debug 2> helper.log"
```

Change the address, the API key and the board's port to yours.

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
