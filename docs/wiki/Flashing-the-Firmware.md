This page gets this project's firmware onto an ESP32-C5 board: building it with ESP-IDF 5.5, backing up what is on the board, flashing it, and checking that it works. It is for anyone setting up a board, on Windows, Linux or macOS.

## Before you start

You need:

- the board, plugged in by its **native USB** port with a data cable ([Hardware](Hardware) explains which connector that is);
- **ESP-IDF 5.5** to build the firmware. It was built with v5.5.5; other versions have not been tried.
- **esptool** to back up the board and to flash a merged image. ESP-IDF 5.5 includes esptool v4; `pip install esptool` gives v5. This page writes every esptool command in a form that works with both (see [Get esptool](#get-esptool)).

There is no prebuilt firmware image to download yet, so you build it once and can then flash the result to as many boards as you like. The Docker image contains no firmware and no flashing tools: flash from a normal Windows, Linux or macOS host.

If you would rather not install ESP-IDF, the sibling project's browser flasher installs its own firmware, which works with Kismet too, with a few differences. See [Without ESP-IDF: the sibling project's web flasher](#without-esp-idf-the-sibling-projects-web-flasher).

The steps below go in order: build, get esptool, back up the board, then flash it in one of two ways, with `idf.py flash` or with the merged image and esptool ([Two ways to flash](#two-ways-to-flash) compares them).

> **Warning:** stop everything that has the board's port open before you flash: Kismet, both helpers, a Docker container that uses the board, and serial terminals. esptool needs the port to itself. On Windows a second program cannot open a COM port at all. On Linux the helpers lock the port and put it in exclusive mode, so esptool stops with `Could not open ..., the port is busy or doesn't exist.` while a helper holds the board, also when that helper runs in a Docker container. esptool run with `sudo` is not kept out that way, so stop the capture first all the same.

## Build the firmware

1. Install ESP-IDF 5.5 by following Espressif's [Get Started guide for the ESP32-C5, release 5.5](https://docs.espressif.com/projects/esp-idf/en/release-v5.5/esp32c5/get-started/index.html). Espressif's "stable" guide describes a newer ESP-IDF, which this project has not been built with.
2. Open an ESP-IDF 5.5 shell. On Linux and macOS, source the export script; change the path to where you installed ESP-IDF:

   ```bash
   . $HOME/esp/esp-idf/export.sh   # a dot, a space, then the path
   ```

   Source it as shown. Run as a program instead, it sets up only its own environment, which ends with it, and `idf.py` stays off your shell's PATH. On Windows, use the "ESP-IDF 5.5 PowerShell" shortcut the installer makes, or run `.\export.ps1` in PowerShell from the ESP-IDF directory.

3. Build, from the repository's root directory:

   ```bash
   cd firmware
   idf.py set-target esp32c5   # once per checkout
   idf.py build
   ```

Stay in `firmware/`, in this shell: the `idf.py` and esptool commands further down this page run there. The one exception is the Python remote helper's `--list`, which needs an ordinary terminal (see [Back up the board first](#back-up-the-board-first)).

The build prints three warnings that are harmless:

| Warning | Why |
|---|---|
| `warning: ignoring malformed line '# Target: ESP32-C5 ...'` | `sdkconfig.defaults` starts with a byte-order mark, and its first line is a comment. Nothing is lost. |
| `git describe returned 'fatal: bad revision 'HEAD''` | Only in a checkout with no commits; the firmware version then reads `1`. |
| `Component directory .../esp_blockdev does not contain a CMakeLists.txt file` | From the ESP-IDF install on the build machine, not from this project. |

### Build options

`idf.py menuconfig` has the project's options under **Packet Sniffer Configuration**. Under Kismet you can leave them alone; the helpers set the radio and channel themselves. Three are worth knowing:

| Option | This project's value | When to change it |
|---|---|---|
| Capture control frames (ACK, RTS, CTS, Block Ack, ...) | On | Turn it off if a busy channel drops frames: control frames add roughly one ACK per data frame. |
| PCAP link type | 802.11 + radiotap header (127) | Leave it. Both helpers expect radiotap and refuse the plain 802.11 link type (105). |
| Bands to sniff | 2.4 GHz + 5 GHz | Leave it for Kismet, which hops both bands. |

The channel hopping, start channel and hopping interval options only matter when nothing tells the board what to do; the helpers always do. [Firmware Protocol](Firmware-Protocol) describes them.

## Get esptool

Every esptool command on this page is written as `python -m esptool ... write_flash`, with underscores in the command name. That form works with esptool v4 and v5: v5 prints a "deprecated" warning for the underscore names and carries on. The name of the `esptool` program itself differs between versions (v4 installs it as `esptool.py` on Linux, v5 as `esptool`), which is why the page runs it through `python -m`.

Where esptool comes from decides which `python` runs it:

- **Inside an ESP-IDF 5.5 shell** there is nothing to install. `python` there is ESP-IDF's own Python, which has esptool v4 (4.12.0). This is the shell the rest of the page uses.
- **Without ESP-IDF, on Windows**, install esptool v5 with pip:

  ```powershell
  python -m pip install esptool
  ```

- **Without ESP-IDF, on Debian and Raspberry Pi OS**, install esptool v5 into a virtual environment (this is what the Raspberry Pi test used, with esptool 5.4.0). The first line installs `python3-venv`, which Debian packages apart from Python itself; without it, `python3 -m venv` stops with a message that `ensurepip` is not available. Installing it when it is already there does no harm:

  ```bash
  sudo apt-get install -y python3-venv
  python3 -m venv ~/esp32c5-venv
  ~/esp32c5-venv/bin/pip install esptool
  . ~/esp32c5-venv/bin/activate   # from now on, in this terminal, python is the venv's Python
  ```

  Debian and Raspberry Pi OS have no `python` command of their own, only `python3`; after `activate`, `python` is the one in the virtual environment. Activate it in a terminal of its own, never in the ESP-IDF shell: `activate` puts the virtual environment first on the `PATH`, so `python` there would become one that has esptool and none of ESP-IDF's packages.

esptool v5 renamed its commands. The v4 names still work in v5, with the warning, so the v4 names are the ones that work everywhere:

| Task | esptool v4 (ESP-IDF 5.5) | esptool v5 |
|---|---|---|
| Run it as | `python -m esptool` (on Linux also `esptool.py`) | `python -m esptool` or `esptool` |
| Write | `write_flash` | `write-flash` (or `write_flash`, with a warning) |
| Read | `read_flash` | `read-flash` (or `read_flash`) |
| Compare with a file | `verify_flash` | `verify-flash` (or `verify_flash`) |
| Erase | `erase_flash` | `erase-flash` (or `erase_flash`) |
| Merge | `merge_bin` | `merge-bin` (or `merge_bin`) |

The hyphenated v5 names do not work in v4. The Raspberry Pi test ran esptool 5.4.0 with them (`esptool --chip esp32c5 ... read-flash`); the examples below do the same with the names that work in both.

## Back up the board first

Before you write anything to the board (with `idf.py flash` or with esptool), read the whole flash into a file with esptool. Then you can put the board back exactly as it was: the maker's demo firmware, or the [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) firmware.

Name each file after the board's MAC, not its port: port numbers change, MACs do not. Write the MAC without colons, as in `F0F5BD010203`, since Windows does not allow colons in file names. To find each board's MAC:

- **On Linux**, the MAC is part of the board's `/dev/serial/by-id/` link, and this needs nothing installed:

  ```bash
  ls -l /dev/serial/by-id/
  ```

- **On Windows** (or any OS), the Python remote helper's `--list` shows each port with its board's MAC ([Hardware](Hardware) shows the output). It needs the helper's packages, and the ESP-IDF shell's Python does not have them all (it lacks `msgpack`), so open a second, ordinary terminal. From the repository's root directory, install the packages once, then list the boards:

  ```powershell
  python -m pip install -r requirements.txt   # once
  python -m esp32c5_kismet.remote --list
  ```

  Without the packages, `--list` stops with `ModuleNotFoundError`. [Install on Windows](Install-on-Windows) has the details. On Linux (where Debian and Raspberry Pi OS have `python3` but no `python`), install the packages into a virtual environment and run the helper with its Python (`.venv/bin/python -m esp32c5_kismet.remote --list`), as on [Try It Without Hardware](Try-It-Without-Hardware). The `by-id` link above is quicker there.

1. Read the flash into a folder of its own in your home directory, which keeps the 8 MB files out of the repository. `ALL` means "to the end of the flash", whatever its size. Replace the port and the MAC with your board's:

   ```bash
   mkdir -p ~/esp32c5-flash-backup
   python -m esptool --chip esp32c5 -p /dev/ttyACM0 read_flash 0 ALL ~/esp32c5-flash-backup/F0F5BD010203.bin
   ```

   ```powershell
   New-Item -ItemType Directory -Force $HOME\esp32c5-flash-backup
   python -m esptool --chip esp32c5 -p COM14 read_flash 0 ALL $HOME\esp32c5-flash-backup\F0F5BD010203.bin
   ```

   On an 8 MB board this takes a minute or so (61 to 86 s per board on the Raspberry Pi), and the file is 8,388,608 bytes.

2. Check the file against the board:

   ```bash
   python -m esptool --chip esp32c5 -p /dev/ttyACM0 verify_flash 0x0 ~/esp32c5-flash-backup/F0F5BD010203.bin
   ```

   ```powershell
   python -m esptool --chip esp32c5 -p COM14 verify_flash 0x0 $HOME\esp32c5-flash-backup\F0F5BD010203.bin
   ```

   It ends with `Verification successful (digest matched).`.

> **Note:** reading a board again into the same file replaces the old backup with what is on the board now. Keep the first backup of each board somewhere safe before you flash and read it again.

[Erase or restore a board](#erase-or-restore-a-board) shows how to put a backup back.

## Two ways to flash

There are two ways to put the firmware on a board. Use one of them, not both:

| | [Flash with idf.py](#flash-with-idfpy) | [The merged image](#make-the-merged-image), [flashed with esptool](#flash-the-merged-image) |
|---|---|---|
| Runs | in the ESP-IDF shell, in the `firmware/` you built in | wherever esptool runs, from one copied file |
| Writes | the bootloader, the partition table and the application | one image at `0x0` that holds all three, with the gaps between them erased |
| The board's stored radio | kept | cleared: the board boots Wi-Fi |
| Suits | the board on your desk, while you work on the firmware | other machines, and many boards |

Under Kismet the difference costs half a second or so: a source whose radio differs from the stored one waits while the board reboots into it. [The radio is kept in flash](#the-radio-is-kept-in-flash) explains. Clearing the stored radio has one catch: a board that was on 802.15.4 when it was flashed that way can come up deaf to Wi-Fi, so put it on Wi-Fi first (see [Flash the merged image](#flash-the-merged-image)).

## Flash with idf.py

This is the first of the two ways. With the board plugged in and backed up, flash the build straight from the ESP-IDF shell, in `firmware/`. Replace `COM14` with your board's port, `/dev/ttyACM0` on Linux:

```bash
idf.py -p COM14 flash
```

`idf.py flash` writes the bootloader, the partition table and the application, and leaves the rest of the flash alone, so **the board keeps the radio it last used** (see [The radio is kept in flash](#the-radio-is-kept-in-flash)).

> **Note:** `idf.py monitor` on the native USB port shows the binary capture stream, not the firmware's log. The log goes to UART0 (115200 baud, TX on GPIO11, RX on GPIO12), which on many development boards is the second USB connector marked "UART".

## Make the merged image

This is the second way, instead of `idf.py flash`. The merged image is one file that holds everything the board needs, to be flashed at offset `0x0`. It is what you copy to another machine, or flash to many boards. Make it in `firmware/`, where you built the firmware:

```bash
idf.py merge-bin -o esp32c5-kismet-merged.bin
```

`idf.py merge-bin` builds first if the build is out of date, and writes the image into the build directory: **`firmware/build/esp32c5-kismet-merged.bin`**, about 1.1 MiB. From `firmware/`, that is `build/esp32c5-kismet-merged.bin`. Inside it:

| Offset | Contents |
|---|---|
| `0x2000` | bootloader |
| `0x8000` | partition table |
| `0x10000` | the application |
| everything else up to the end | `0xFF` (erased), including the NVS partition at `0x9000` |

The last row matters: flashing the merged image erases the board's stored radio, so the board comes up in Wi-Fi.

If you prefer esptool directly, run it inside `firmware/build/` (`cd build` first, and `cd ..` afterwards to get back to `firmware/`):

```bash
python -m esptool --chip esp32c5 merge_bin -o esp32c5-kismet-merged.bin @flash_args   # esptool v5 warns about the old names and carries on
```

## Flash the merged image

The commands below run in `firmware/`, where the image is `build/esp32c5-kismet-merged.bin`. If you copied the image to another machine, give its path there instead.

1. Back up the board, as in [Back up the board first](#back-up-the-board-first), if you have not already.
2. If the board was last used for 802.15.4 (Zigbee or Thread), put it on Wi-Fi first: run a Wi-Fi source on it until it says `capturing`, or send it `MODE WIFI`. A board flashed while it is on 802.15.4 can come up deaf to Wi-Fi ([The radio is kept in flash](#the-radio-is-kept-in-flash) has the details).
3. Stop Kismet, the helpers and anything else that has the port open.
4. Flash the image at `0x0`. Replace the port with your board's; on Linux the `/dev/serial/by-id/` link makes sure you get the board you mean:

   ```bash
   python -m esptool --chip esp32c5 -p /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00 -b 460800 write_flash 0x0 build/esp32c5-kismet-merged.bin
   ```

   ```powershell
   python -m esptool --chip esp32c5 -p COM14 -b 460800 write_flash 0x0 build\esp32c5-kismet-merged.bin
   ```

5. esptool writes the image, prints `Hash of data verified`, and resets the board. No BOOT button is needed: esptool resets the board into and out of its download mode over the native USB port by itself.

`-b 460800` is the speed `idf.py` uses. The native USB port ignores the speed setting, so it is safe; whether it makes flashing any faster there has not been measured.

> **Note:** some boards come up latched in download mode after flashing and never start the new firmware. Unplug the board and plug it back in, or press its BOOT button once. The sibling project's web flasher page reports this on two of the three boards it was developed against; it is a quirk of those boards, not the firmware.

## Flash several boards

Run the same three commands for each board: back up, check the backup, write the merged image. Put any board that was last used for 802.15.4 on Wi-Fi first, as in [Flash the merged image](#flash-the-merged-image). On Linux, loop over the `/dev/serial/by-id/` links, in `firmware/`. The loop names each backup after the board's MAC, and stops at the first command that fails, so a board whose backup did not finish or did not match is never written over:

```bash
mkdir -p ~/esp32c5-flash-backup
for port in /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_*-if00; do
    mac=${port#*_unit_}
    mac=${mac%-if00}
    mac=${mac//:/}
    backup="$HOME/esp32c5-flash-backup/$mac.bin"
    python -m esptool --chip esp32c5 -p "$port" read_flash 0 ALL "$backup" || break
    python -m esptool --chip esp32c5 -p "$port" verify_flash 0x0 "$backup" || break
    python -m esptool --chip esp32c5 -p "$port" write_flash 0x0 build/esp32c5-kismet-merged.bin || break
done
```

> **Warning:** the pattern matches every Espressif chip on its native USB port, not only ESP32-C5 boards: the ESP32-C3, C6, H2, S3 and P4 have the same USB ID. Unplug other ESP32 boards first.

On Windows, list each COM port with its board's MAC yourself; `python -m esp32c5_kismet.remote --list` shows them, in the ordinary terminal where you installed the helper's packages (see [Back up the board first](#back-up-the-board-first)). Change the ports and MACs in the first line to yours, then run this in `firmware/`. It stops at the first esptool command that fails, like the Linux loop:

```powershell
$boards = [ordered]@{ 'COM14' = 'F0F5BD010203'; 'COM15' = 'F0F5BD010204'; 'COM16' = 'F0F5BD010205' }
New-Item -ItemType Directory -Force $HOME\esp32c5-flash-backup
foreach ($port in $boards.Keys) {
    $backup = "$HOME\esp32c5-flash-backup\$($boards[$port]).bin"
    python -m esptool --chip esp32c5 -p $port read_flash 0 ALL $backup
    if ($LASTEXITCODE) { break }
    python -m esptool --chip esp32c5 -p $port verify_flash 0x0 $backup
    if ($LASTEXITCODE) { break }
    python -m esptool --chip esp32c5 -p $port -b 460800 write_flash 0x0 build\esp32c5-kismet-merged.bin
    if ($LASTEXITCODE) { break }
}
```

The four test boards were flashed on the Raspberry Pi with these three commands, in esptool v5's spelling, one board after another, and all four ended up streaming Wi-Fi. One of them, flashed while it was on 802.15.4, came up deaf to Wi-Fi until it was switched to BLE and back; see [The radio is kept in flash](#the-radio-is-kept-in-flash). They now run an image built from this repository during development (its SHA-256 starts `01a50bd6`). It already has the last change to the firmware's messages, and a build of the current source differs from it only in what the UART0 log shows, such as the version and build time; the USB stream is the same, so the boards were not flashed again. On 2026-10-02 the two-part `verify_flash` in [Check the result](#check-the-result) matched that image on all four boards.

## Check the result

A board that esptool can talk to is not yet a board that captures. This is how to check each step.

1. **esptool finished** with `Hash of data verified` and reset the board. That line is esptool's check of what it wrote; see the note below before you compare the whole image with `verify_flash` later.
2. **The board is on USB again.** On Linux, `ls -l /dev/serial/by-id/` lists it; on any OS, `python -m esp32c5_kismet.remote --list` does, once the helper's packages are installed (see [Back up the board first](#back-up-the-board-first)). This shows only that the port is there.
3. **The firmware answers.** When a helper opens a board, it sends the radio, a channel and `START <time in microseconds> <nonce>`. The firmware answers with a line `<<START>> <nonce>` and a PCAP header, and then streams packets; the answer came back in about 0.11 s in the tests. The helpers report the source as capturing only after that answer, so a short capture is the real test. On Linux with Kismet built ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)) and its `bin` directory on your PATH, replace the port and run:

   ```bash
   kismet --no-ncurses --no-logging -c 'esp32c5:device=/dev/ttyACM0,mode=wifi,name=check'
   ```

   Within a few seconds Kismet prints:

   ```text
   INFO: check capturing (wifi)
   ```

   Then watch the packet count, in the web UI or in `/datasource/all_sources.json`: a board flashed while it was on 802.15.4 can say `capturing` and still receive nothing ([The radio is kept in flash](#the-radio-is-kept-in-flash)). Stop Kismet with Ctrl+C. [Guide: First Capture](Guide-First-Capture) walks through a full first capture, with the web UI, on a Raspberry Pi or Linux machine, with a short section for boards on Windows.

If the firmware does not answer, the source never reaches "capturing". After 15 s the C helper gives up, and Kismet prints:

```text
ERROR: check: no capture from the board on /dev/ttyACM0 for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?
```

The source's own error, `kismet.datasource.error_reason` in `/datasource/all_sources.json`, reads only `IPC connection closed`: Kismet ignores the reason a local helper sends along with its error, so the line above in Kismet's output is where to look.

The Python remote helper says the same, with its own last status for that port in brackets, for example for `--source esp32c5-COM14`:

```text
esp32c5-COM14: no capture from the board on COM14 for 15 seconds (last: esp32c5-COM14: COM14 opened); is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?
```

The part in brackets is what the helper last reported, such as `esp32c5-COM14: COM14 opened`, `esp32c5-COM14: lost sync (...)` or the error from opening the port; it is not data from the board. Both then try again: Kismet re-opens the C helper's local source 5 s later, and the Python remote helper reconnects after 5 s.

You can also read the firmware's log on UART0 (115200 baud): at boot it prints the ESP-IDF lines `Project name: esp32c5_sniffer` and `App version: ...`, then `capturing with the Wi-Fi radio`, and every 10 s a status line such as:

```text
I (60012) sniffer: Wi-Fi ch   6 of 1 (250 ms) | captured 1234 | dropped: buffer 0, usb 0, oversize 0
```

That status line is the only place the firmware reports its drop counters.

> **Note:** once the board has started, `verify_flash 0x0 build/esp32c5-kismet-merged.bin` fails with `Verification failed (digest mismatch).`, even though the flash is fine. At its first boot about 2.2 KB of the NVS partition (0x9000 to 0x991b), which the image holds as erased, is written; what writes it was not identified. It failed this way on all four test boards, and a read-back differed from the image in that area only. To compare the rest, leave NVS out: cut the image into the part before it and the part from the application on, and verify both:
>
> ```bash
> python -c "d = open('build/esp32c5-kismet-merged.bin', 'rb').read(); open('part-0x0.bin', 'wb').write(d[:0x9000]); open('part-0x10000.bin', 'wb').write(d[0x10000:])"
> python -m esptool --chip esp32c5 -p /dev/ttyACM0 verify_flash 0x0 part-0x0.bin 0x10000 part-0x10000.bin
> ```
>
> Both parts end with `Verification successful (digest matched).`. On Windows, run the same two lines with your COM port.

## Without ESP-IDF: the sibling project's web flasher

The sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) flashes a board from the browser, with no toolchain. It installs **that project's firmware, version 1.2.0**, not this one. That firmware works with both helpers on all three radios: on the test Pi, a board flashed with the published 1.2.0 image, the one the flasher installs, captured Wi-Fi, 802.15.4 and BLE through the C helper, local and remote, and through the Python remote helper. The image was written with esptool there; the browser flasher itself was not used in the tests. The next section lists the differences.

1. If you want to keep what is on the board now, back it up first with esptool, as in [Back up the board first](#back-up-the-board-first). esptool on its own needs no ESP-IDF (`python -m pip install esptool`). The flasher offers to erase the whole flash.
2. Stop Kismet, the helpers and anything else that has the board's port open. A board last used for 802.15.4 should go back to Wi-Fi first, as before any flash that clears the stored radio (see [Flash the merged image](#flash-the-merged-image)).
3. Open https://oshri-almog.github.io/esp32c5-wireshark-sniffer/ in Chrome or Edge 89 or newer, Firefox 151 or newer, or Chrome for Android. Safari does not work.
4. Plug in the board and follow the page's steps.

The board then boots Wi-Fi, since the flasher's image also clears the stored radio. Check it as in [Check the result](#check-the-result).

> **Note:** before the tests, two of the four test boards, which reported app version `5cdab32-dirty`, the same as the sibling's 1.2.0 build, did not answer `START` within 3 s when probed, so a helper could not have synchronised with them (see **Flash this project's firmware anyway** in [the next section](#boards-flashed-with-the-esp32c5-wireshark-sniffer-firmware)). If a board on the sibling's firmware streams but never reaches "capturing", flash this project's image with esptool. This project has no prebuilt image yet, so that means building it with ESP-IDF as described above.

## Boards flashed with the esp32c5-wireshark-sniffer firmware

The sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) feeds the same boards to Wireshark. This project's firmware started as its firmware, and both speak the same line protocol, so a board flashed for that project works with this one. On the test Pi, a board on the published 1.2.0 image captured Wi-Fi, 802.15.4 and BLE through the C helper, local and remote, and through the Python remote helper. Its browser flasher installs version 1.2.0. Compared with this project's firmware:

| | Sibling 1.2.0 | This project | What it means under Kismet |
|---|---|---|---|
| Wi-Fi and 802.15.4 streams | Identical | Identical | Nothing |
| BLE CRC | Three zero bytes, and the "CRC checked" and "CRC valid" flags clear | Computed by the firmware, both flags set | Kismet would drop every BLE packet from 1.2.0. Both helpers fill in the CRC and the flags for it |
| Longest command line | 63 characters | 255 characters | Nothing: the helpers send one channel per command |
| Channels in one list | 39; a longer list loses 169, 173 and 177 | 42 | Nothing, for the same reason |
| Stored radio | In flash, same place | In flash, same place | Switching firmware with `idf.py flash` keeps the radio |

When a helper meets a board on 1.2.0 capturing BLE, it says so once per connection:

```text
<name>: the board's firmware does not mark BTLE packets as CRC checked, so Kismet would drop them; the helper fills in the CRC and the flags (the board only reports packets whose CRC passed). Flashing current firmware makes this unnecessary
```

On the test board every BLE record from 1.2.0 arrived with the flags clear and a zero CRC, and every one reached Kismet with a valid CRC and both flags set, through all three helper setups, with nothing dropped.

**Flash this project's firmware anyway.** Before they were flashed, all four test boards reported app version `5cdab32-dirty`, the same as the sibling's 1.2.0 build (the compile time matched too). Two of them answered `START`; the other two streamed Wi-Fi but did not answer `START` within 3 s when probed, so a helper could not have synchronised with them. No helper was run against the boards before they were flashed. After flashing this project's image, all four worked. Later, one board flashed with the published 1.2.0 image answered `START` at once in every test, so the published image was not the cause; what was is not known.

**Older sibling firmware** (1.0.0 and 1.1.0, no longer offered by its flasher):

- 1.1.0 captures Wi-Fi and 802.15.4, and has no BLE; its Wi-Fi and Zigbee sources worked on the test board. 1.0.0 is meant to capture Wi-Fi only, but on the test board it answered `START` and then sent no Wi-Fi at all (0 packets in 40 s under Kismet), before and after a reset; that board had been in 802.15.4 mode when it was flashed, the known deaf-Wi-Fi case, so the cause was not isolated. Flash this project's image over 1.0.0.
- A BLE source on either, or a Zigbee source on 1.0.0, never starts: the board ignores the `MODE` it cannot do and keeps sending its Wi-Fi link type, the helper reports `<name>: lost sync (the board sends link type 127, not 256)` (`not 283` for Zigbee), never "capturing", and after 15 s gives up with the message above.
- These versions used a different partition table. Upgrade them with the merged image at `0x0` or with `idf.py flash`, both of which write the partition table, not with an application-only write.

**The other direction:** a board with this project's firmware is expected to work with the sibling's Wireshark plugin, since the two firmwares speak the same protocol, but nobody has run it that way yet. Its BLE packets then carry a computed CRC with both CRC flags set, where the sibling's own firmware leaves them clear. The CRC code the helpers use for older firmware matches a test vector that Wireshark's BTLE dissector accepts, but the firmware's own CRC has not been checked in Wireshark. On hardware, the only check is that Kismet accepted this firmware's BLE records as valid.

**Which firmware is on a board?** No command over USB reports it. Read the `App version:` line of the UART0 boot log: the sibling's 1.2.0 says `5cdab32-dirty`; a build of this project says what `git describe` gave for your checkout, which ESP-IDF uses because the project sets no version of its own: for example a commit hash, with `-dirty` when the checkout had changes. Under Kismet, the BLE message above appears only with older firmware.

## The radio is kept in flash

A board remembers its radio in flash (NVS namespace `sniffer`, key `mode`) and boots into it. A board that has never been told boots Wi-Fi.

| Survives | Is cleared by (the board then boots Wi-Fi) |
|---|---|
| Resets and power cycles | Flashing the merged image at `0x0` |
| `idf.py flash` | esptool's `erase_flash`, or `idf.py erase-flash` |
| | The sibling's browser flasher (its merged image covers the stored radio, whether or not you let it erase the flash) |

Under Kismet this costs only time. The helpers always tell the board which radio to use, then wait 0.8 s before they start the stream:

- If the board is already on that radio, nothing happens; on the test Pi a local source was capturing 1.0 to 1.5 s after Kismet launched it.
- If not, the board reboots into the other radio, which takes about 0.53 s, inside that wait; the source was capturing about 1.5 s after launch, or 2.5 to 3 s when the board dropped off USB during the reboot and came back.

Now and then a switch goes wrong: the board drops off USB, comes back and never answers again. On the test Pi this was always the same one of the four boards. In ordinary switches made after a capture, it happened once in 160 (0 of 80 from Wi-Fi to BLE; 1 of 80 back to Wi-Fi, that one under the Python remote helper). At a fresh Kismet start with several boards switching radio at once, that board dropped off USB every time (25 of 25), and stayed silent in 3 of them, all under the C helper. Whether the firmware or the power on that board's hub port is to blame is not known. Both helpers give up after 15 s and try again, which does not help. Stop the capture, then reset the board with esptool, for example `python -m esptool --chip esp32c5 -p /dev/ttyACM0 read_mac`, which resets it when it finishes, or unplug it and plug it back in. It comes back on the radio it was switching to.

Without a helper, for example with a serial terminal, a board left on Zigbee or BLE seems to hang: it sends its `<<START>>` marker and a header at boot, then nothing on the Wi-Fi channels. Send `MODE WIFI` to bring it back; see [Firmware Protocol](Firmware-Protocol).

**A board flashed while it was on 802.15.4 can come up deaf to Wi-Fi.** It answers the helpers in Wi-Fi, so the source says `capturing (wifi)`, but no packet ever arrives and no error follows: once a source is capturing, the helpers take silence for a quiet channel. This happened both times a test board was flashed with the merged image while it was on 802.15.4; flashed from Wi-Fi, the same board worked. By the firmware's own notes, its `MODE` shuts the old radio down before its reboot, but the reset after flashing skips that, and the cleared stored radio then boots Wi-Fi straight away.

- To avoid it, put the board on Wi-Fi before you flash it with the merged image, erase it or use the browser flasher: run a Wi-Fi source on it until it says `capturing`, or send `MODE WIFI`.
- To cure it, switch the board to BLE and back: run a `btle` source on it until it says `capturing`, then the Wi-Fi source again, or send `MODE BLE` and then `MODE WIFI`. By the firmware's own notes, unplugging the board and plugging it back in also brings it back; that was not tried in the tests. An esptool reset did not cure it.

## Erase or restore a board

To wipe the flash, stored radio included (put a board last used for 802.15.4 on Wi-Fi first, as above):

```bash
python -m esptool --chip esp32c5 -p /dev/ttyACM0 erase_flash
```

```powershell
python -m esptool --chip esp32c5 -p COM14 erase_flash
```

In the ESP-IDF shell, `idf.py -p /dev/ttyACM0 erase-flash` does the same.

To put a backup back, write it at `0x0` like the merged image:

```bash
python -m esptool --chip esp32c5 -p /dev/ttyACM0 write_flash 0x0 ~/esp32c5-flash-backup/F0F5BD010203.bin
```

```powershell
python -m esptool --chip esp32c5 -p COM14 write_flash 0x0 $HOME\esp32c5-flash-backup\F0F5BD010203.bin
```

## If flashing fails

| What you see | What to do |
|---|---|
| `Could not open COM14, the port is busy or doesn't exist.` | Another program has the port: stop Kismet, the helper or the serial terminal. If nothing has it and the message ends with `A device attached to the system is not functioning.` (Windows error 31), unplug the board and plug it back in. |
| `Permission denied` on `/dev/ttyACM0` | Your user is not in the group that owns the port, `dialout` on Debian, Ubuntu and Raspberry Pi OS: `sudo usermod -aG dialout $USER`, then log out and in. On the test Pi the user was already in `dialout`, so this fix was not needed or tried there. |
| The board is back on USB but never captures | It may be latched in download mode: unplug it, or press BOOT once. Otherwise see [Check the result](#check-the-result). |
| A Wi-Fi source says `capturing (wifi)`, but its packet count stays at 0 | The board was probably on 802.15.4 when it was flashed: switch it to BLE and back, as in [The radio is kept in flash](#the-radio-is-kept-in-flash). Or it runs the sibling project's 1.0.0 firmware, which on the one test board answered `START` but sent no Wi-Fi: flash this project's image. |
| `verify_flash` of the whole image fails with `Verification failed (digest mismatch).` | Normal once the board has booted: something has been written to its NVS partition at boot. Verify without it, as in the note under [Check the result](#check-the-result). |
| Random failures, ports renumbering | Almost always the USB link: use a powered hub or a direct port, and a known-good data cable. |

More in [Troubleshooting](Troubleshooting). To update boards later, see [Guide: Updating](Guide-Updating).
