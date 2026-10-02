This guide updates each part of a setup to a newer version of this project: the boards' firmware, Kismet with the C helper, the Python remote helper, and the Docker images. It says what each update keeps, what it resets, and how long it takes. It is for anyone with a working setup who has pulled a newer version, or wants to.

## What to update, and in what order

| Part | How | What it keeps | Time |
|---|---|---|---|
| [Firmware](#the-firmware) | Reflash each board: with the web flasher, with a release's image and esptool, or from your own build | With `idf.py flash`, the radio the board remembers; the web flasher and the merged image reset it to Wi-Fi | A few minutes per board |
| [Kismet and the C helper](#kismet-and-the-c-helper-native-build) | Re-run `add-to-kismet.sh`, `make`, `make install` | Your `kismet_site.conf`, login, API keys and logs | Seconds to minutes for a helper change; about 78 minutes on a Pi 4 when Kismet itself must be recompiled |
| [Python remote helper](#the-python-remote-helper) | `git pull`, then `pip install -r requirements.txt` | Everything: it has no settings of its own | A minute |
| [Docker images](#docker-images) | Pull, or rebuild, then recreate the containers | The login, API keys and logs, in the volumes | A pull: about 48 MB to download. A rebuild on a Pi: about a minute for a helper change, about 80 minutes when Kismet is recompiled |

A sensible order: stop everything that uses the boards, update the software on the computers, reflash the boards, then start again.

The parts do not all have to move together, but the firmware has limits:

- A board flashed by the sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) with its firmware 1.2.0 speaks the same line protocol and is meant to work on all three radios; the helpers fill in the BLE checksums that firmware leaves empty.
- In testing, two of the four boards reported the same app version as that 1.2.0 image, streamed Wi-Fi, and never answered the helpers' `START`. They worked only after they were reflashed with this project's image; see step 1 of [Guide: First Capture](Guide-First-Capture).
- The sibling's older firmware does less. 1.1.0 captures Wi-Fi and 802.15.4 but not BLE: it ignores `MODE BLE`. 1.0.0 has no `MODE` command. On the one test board flashed with it, it answered `START` but streamed no Wi-Fi at all, so a `wifi` source said `capturing` and got no packets. That board had just been in 802.15.4 mode, so this may be the known deaf Wi-Fi issue below rather than 1.0.0 itself; the cause was not isolated. A source for a radio the firmware lacks never reaches `capturing`: it logs `<name>: lost sync (the board sends link type 127, not 256)` (`not 283` for `zigbee`), gives up after 15 seconds with `<name>: no capture from the board on <port> for 15 seconds; is it flashed with the esp32c5 sniffer firmware, and is nothing else holding the port?`, and is tried again. The Python remote helper adds the last status to that message, as `(last: ...)`.

So reflash when the firmware has changed: the helpers' fix-ups are for compatibility, not a replacement.

The examples use the project in `~/esp32c5-kismet-wifi-interface`, Kismet's source in `~/src/kismet` and its install in `~/kismet-install`, as in [Install on Raspberry Pi](Install-on-Raspberry-Pi). Change the paths to yours.

## Before you start: free the boards

A board's port can be open in one program at a time. Stop everything that has it before you flash it:

- Kismet with local sources: Ctrl+C in its terminal, or `sudo systemctl stop kismet` for a service;
- the Python remote helper: Ctrl+C or Ctrl+Break in its window, or `sudo systemctl stop esp32c5-remote-helper` for a Linux service;
- the C helper as a service: `sudo systemctl stop esp32c5-helper-wifi` (or whatever you named it);
- a Docker container that uses the boards: `sudo docker compose stop`.

> **Warning:** On Linux a helper that holds a board puts its port in exclusive mode, so esptool is refused with "the port is busy", also on the host while the helper runs in a container. A program run with `sudo` is the exception: that mode does not keep it out, so `sudo esptool` would write to a board that a helper is capturing from. Always stop what uses a board, containers included, before flashing it.

## The firmware

### With the web flasher

The [web flasher](https://oshri-almog.github.io/esp32c5-kismet-wifi-interface/) always offers the firmware built from the latest `main`; its page shows the version and the commit. To update a board with it:

1. Free the board, as above.
2. If the board was last used for 802.15.4, put it on Wi-Fi first: run a `wifi` source on it until it says `capturing` (see the note under step 2 below).
3. Install as on [Flashing the Firmware](Flashing-the-Firmware#flash-from-the-browser). The board comes back on Wi-Fi, whether or not you let the flasher erase it.

On a machine without a desktop browser, write a ready-made image with esptool: download the flasher's or a release's as under [Download the merged image](Flashing-the-Firmware#download-the-merged-image), and check it against its own SHA-256 (the two are separate builds of the same firmware, so their hashes differ). Then write it as in step 2 below, with the path of the downloaded file.

To update from the source instead, or after changing the firmware yourself, follow the steps below.

### 1. Get the new source and build it

In an ESP-IDF 5.5 shell (`export.sh`, or the "ESP-IDF 5.5 PowerShell" shortcut on Windows):

```bash
cd ~/esp32c5-kismet-wifi-interface
git pull
cd firmware
idf.py build
```

If the update changed `firmware/sdkconfig.defaults`, those changes do not reach a `firmware/sdkconfig` that an earlier build created: settings already in it keep their old values. Delete `firmware/sdkconfig` before building to start again from the project's defaults. That also drops anything you changed in `idf.py menuconfig`.

### 2. Flash it: keep the stored radio, or reset it

A board stores the radio it last used (Wi-Fi, 802.15.4 or BLE) in a small area of its flash, and boots into it. The two ways to flash treat that area differently.

For the merged image, make it first. In `firmware/`, where step 1 left you:

```bash
idf.py merge-bin -o esp32c5-kismet-merged.bin
```

It builds if needed and writes the image into the build directory, `firmware/build/esp32c5-kismet-merged.bin`. The commands below run in `firmware/`:

| Way | Command | The board's stored radio |
|---|---|---|
| ESP-IDF, from the source | `idf.py -p /dev/ttyACM0 flash` | **Kept.** It writes the bootloader, partition table and app, and leaves the settings area alone |
| The merged image, at 0x0 | `esptool --chip esp32c5 -p /dev/ttyACM0 write-flash 0x0 build/esp32c5-kismet-merged.bin` | **Reset to Wi-Fi.** The image covers the settings area with blank flash |

Change `/dev/ttyACM0` to the board's port (`COM14` style on Windows, where the path is `build\esp32c5-kismet-merged.bin`). With the esptool that comes with ESP-IDF 5.5 (version 4), write `python -m esptool` and `write_flash` instead of `esptool` and `write-flash`. [Flashing the Firmware](Flashing-the-Firmware) has both spellings, backups and a loop over several boards.

Under Kismet it makes no difference which you choose: the helpers always tell the board which radio to use. A reset only costs one reboot, about a second, the first time a source asks the board for another radio.

`idf.py erase-flash` wipes everything, the stored radio included.

> **Note:** A board that was last used for 802.15.4 (still in 802.15.4 mode) when it was flashed can come up with its Wi-Fi radio deaf: a `wifi` source on it says `capturing (wifi)` but gets no packets, nothing reports an error, and a reset does not help. This is a known firmware issue, seen twice on one test board after flashing the merged image. Before flashing, switch the board to Wi-Fi by running a `wifi` source on it. To cure a deaf board, switch it to BLE and back: run a `btle` source on it until it captures, then the `wifi` source again.

### 3. Boards on the sibling's oldest firmware

A board still on the sibling project's firmware 1.0.0 or 1.1.0 has a smaller app partition than this firmware needs. Flash the merged image at 0x0, with the web flasher or esptool, or use `idf.py flash`: all of them write the new partition table. An update that writes only the app would not fit.

### 4. Which firmware is on a board?

There is no command to ask a board over USB. Two ways to tell:

- The board's UART0 log port (115200 baud, TX on GPIO11) prints the version at every boot, in a line `App version:`. A build from a clone of this repository shows the `git describe` of the tree it was built from, with `-dirty` when the tree had changes. Since `v0.1.0`, that is the tag itself on the tagged commit (`v0.1.0`), and on a later commit the tag, the number of commits since it and the hash, as in `v0.1.0-<n>-g<hash>`. A commit from before `v0.1.0`, or a tree without the tags, gives the commit's short hash, such as `f8e6792`. A board installed from the web flasher shows the version the flasher page showed, and one written from a release's image the release's version; both `v0.1.0` images carry `v0.1.0`. [Hardware](Hardware) shows how to read that port.
- Under Kismet, a BTLE source on older firmware produces the one-time message `<name>: the board's firmware does not mark BTLE packets as CRC checked, ...`. Current firmware never triggers it.

<!-- VERIFY: the App version: line as a board's UART0 port prints it (f8e6792 was read from a clean clone's build with esptool image_info, and v0.1.0 from the app description in both v0.1.0 images, on 2026-10-02; not from a booting board); a clone's build on a commit after v0.1.0 has not been seen -->

## Kismet and the C helper (native build)

The C helper is built as part of Kismet's source tree. An update of this project usually changes only the helper, which rebuilds in seconds or minutes on top of the Kismet you already compiled.

### Same Kismet, newer helper

1. Get the new version of the project:

   ```bash
   cd ~/esp32c5-kismet-wifi-interface
   git pull
   ```

2. Copy it into Kismet's tree. The script copies the helper and its server-side header only where they changed, and skips every edit that is already there:

   ```bash
   sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
   ```

3. Rebuild:

   ```bash
   cd ~/src/kismet
   make
   ```

   `make` rebuilds only what the update changed. A new helper alone takes seconds. A new server-side header, `datasource_esp32c5.h`, also recompiles `kismet_server.cc`, which includes it, and relinks the `kismet` program: minutes, not a full rebuild of Kismet (about 3 on a Pi 4, in a test rebuild that also relinked every capture helper). If the update brings a fix for Kismet's capture framework that this tree does not have yet, every capture helper is rebuilt once as well. That alone does not touch `kismet`, and took 8.5 s on the test Pi 4 with `make -j4`.

   If the script changed Kismet's `Makefile.in` or regenerated `configure`, which a helper update rarely does, `make` prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` It is only a notice: `make` carries on and builds. When you see it, or when the update changed `kismet/capture_esp32c5/Makefile.in`, from which `configure` writes the helper's Makefile, re-run `./configure` with the options you used the first time. Running `configure` again with the same options does not make Kismet compile again.

4. Install, with the same variables as the first time. For the home-directory install:

   ```bash
   make install INSTUSR=$(id -un) INSTGRP=$(id -gn) SUIDGROUP=$(id -gn)
   ```

   `make install` never replaces a config file that is already there; it prints `... already exists; it will not be automatically replaced.` for each one. Your `kismet_site.conf` is not one of Kismet's files at all, so it is never touched. Your login and API keys are in `~/.kismet` and stay as they are.

5. Start Kismet again, or `sudo systemctl restart kismet` for a service, and check that each source reaches `capturing`.

   If this machine runs the C helper as a remote-capture service, `make install` has replaced the helper that service runs. Start it again, one service per board:

   ```bash
   sudo systemctl start esp32c5-helper-wifi
   ```

   Then check on the Kismet server that the source is capturing again. A machine with only the helper has no Kismet of its own to start. See [Guide: Running as a Service](Guide-Running-as-a-Service).

### A newer Kismet

This project was developed and tested against Kismet commit `cfe427074`. A newer commit may work, but has not been tried. To try one, return the tree to Kismet's own files, move to the new commit, and add the source again:

```bash
git -C ~/src/kismet checkout -- .
git -C ~/src/kismet clean -xfd
git -C ~/src/kismet fetch
git -C ~/src/kismet checkout <commit>
sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
```

Change `<commit>` to the one you want. `git checkout -- .` undoes the script's edits, and `git clean -xfd` removes the files it added and everything the build produced, which a new commit has to rebuild anyway. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support#trying-a-newer-kismet) has the same steps.

Then `./configure` with your options, `make` and `make install` as for the first build. Kismet itself is recompiled: about 78 minutes on a Raspberry Pi 4 (8 GB).

What the script may say on a newer Kismet:

| Message | Meaning |
|---|---|
| `anchor not found, Kismet has changed: ...` | The script stops. Kismet moved the lines it edits (those of the CatSniffer Zigbee helper, which it uses as anchors). Go back to `cfe427074`, and report the commit |
| `capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed` | The script carries on. Kismet changed the function that leaks; check whether the new Kismet fixed the leak itself |
| `capture_framework.c: cf_commit_packet not found, its metadata leak not fixed` | The script carries on. Kismet renamed or removed the function; the same check applies |
| Another `capture_framework.c: ... has changed, ...` line, such as `capture_framework.c: the websocket login has changed, it still goes in the URI` or `capture_framework.c: the websocket's Host header has changed, its port not added` | The script carries on without that one of its seven fixes to Kismet's capture framework. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support) lists them all, with each note |
| `edited capture_framework.c` | A framework fix was applied, new to this tree |
| no line about `capture_framework.c` | The fixes are already there, from an earlier run or because Kismet has them itself. The login fix and the Host header fix are recognised only as this script applies them: a Kismet that fixed either its own way gets the `the websocket login has changed` or `the websocket's Host header has changed` line |

## The Python remote helper

1. Stop the helper: Ctrl+C or Ctrl+Break in its window.
2. Update the project and its packages. From the project folder:

   ```powershell
   git pull
   python -m pip install -r requirements.txt
   ```

   `pip install -r` upgrades a package only when the installed version no longer meets the file's minimum, as happened when the minimum for websocket-client rose to 1.9.1. On Linux use the same Python you run the helper with, for example `.venv/bin/pip install -r requirements.txt` in a virtual environment, rather than your distribution's packages: Ubuntu 24.04 and Debian 13 ship older websocket-client versions.

   Without Git, download the repository as a ZIP again and unpack it in place of the old folder.

3. Check it, then start it as before, or with `sudo systemctl start esp32c5-remote-helper` for a Linux service:

   ```powershell
   python -m esp32c5_kismet.remote --help
   ```

Each source keeps its ID, which comes from the board's MAC and the radio, so Kismet recognises the sources when the new helper connects and reuses them. An option you set in the new definition takes effect when the helper reconnects, but an option you removed from it keeps its old value until Kismet restarts. A source that had `channel_hop=false`, for example, stays locked under a plain definition; write `channel_hop=true` or restart Kismet.

## Docker images

Your login, API keys and logs are in the named volumes `kismet-home` and `kismet-data`, so recreating the containers keeps them.

### Published images

The images are published as `ghcr.io/oshri-almog/esp32c5-kismet`, with the tags `latest`, a version number such as `0.1.0`, and `demo` ([Docker Reference](Docker-Reference#tags)). On Docker Desktop (amd64), these steps ran with `v0.1.0`: the pull worked, and as the image had not changed, the container kept running as it was. Only one version has been published so far, so an update to a newer image has not been tried. A pull also replaces an image you built under the same name. From the project folder:

```bash
sudo docker compose pull
sudo docker compose up -d
```

For the helper service on a machine that feeds another Kismet:

```bash
sudo docker compose --profile helper pull helper
sudo docker compose --profile helper up -d helper
```

### Images you build

```bash
cd ~/esp32c5-kismet-wifi-interface
git pull
sudo docker compose build
sudo docker compose up -d
```

The image compiles Kismet in one layer and the helper in a later one, so what a rebuild costs depends on what changed:

| What changed | What is rebuilt | On a Raspberry Pi 4 (8 GB) |
|---|---|---|
| Only `kismet/capture_esp32c5/capture_esp32c5.c`, the C helper | The helper and the layers after it; Kismet stays cached | About a minute |
| `docker/entrypoint.sh` or `docker/kismet_site.conf` | Only the last layers | Seconds to a minute (not timed) |
| `kismet/datasource_esp32c5.h`, `kismet/add-to-kismet.sh` or `kismet/capture_esp32c5/Makefile.in` | Kismet, from the start | About 80 minutes |
| A build argument (`JOBS`, `KISMET_REF`, `KISMET_REPO`, `DEBIAN`) | Everything | About 80 minutes |

Keep build arguments the same from one build to the next. In particular, leave `JOBS` unset, or give it the same value every time: a different value misses Docker's cache and compiles Kismet again. On a Pi, run a long build so that it survives the SSH session ending; [Install with Docker](Install-with-Docker) shows how.

### Without Compose

Pull or build the new image, remove the old container, and run the same `docker run` command as before. `docker rm` keeps the named volumes:

```bash
sudo docker pull ghcr.io/oshri-almog/esp32c5-kismet:latest
sudo docker rm -f esp32c5-kismet
```

> **Warning:** Do not clean up with `docker volume prune` or `docker system prune --volumes`. They delete every unused unnamed volume on the machine, not only this project's (with `-a`, `docker volume prune` deletes unused named volumes too, such as `kismet-data`), and with them logins, API keys and logs. Remove this project's containers and volumes by name.

### Remote helpers during the update

A helper feeding a Kismet that is being recreated reconnects on its own once Kismet is back. The Python remote helper was capturing again about 7 s after a container restart; the C helper retries every 5 s. Kismet recognises each source by its ID and reuses it.

## See also

- [Flashing the Firmware](Flashing-the-Firmware): every way to flash, and backups
- [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support): the native build in detail
- [Install with Docker](Install-with-Docker) and [Docker Reference](Docker-Reference): images, tags, build arguments
- [Development and Testing](Development-and-Testing): the tests to run after changing the code yourself
