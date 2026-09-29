This guide updates each part of a setup to a newer version of this project: the boards' firmware, Kismet with the C helper, the Python remote helper, and the Docker images. It says what each update keeps, what it resets, and how long it takes. It is for anyone with a working setup who has pulled a newer version, or wants to.

## What to update, and in what order

| Part | How | What it keeps | Time |
|---|---|---|---|
| [Firmware](#the-firmware) | Rebuild and reflash each board | With `idf.py flash`, the radio the board remembers; the merged image resets it to Wi-Fi | A few minutes per board |
| [Kismet and the C helper](#kismet-and-the-c-helper-native-build) | Re-run `add-to-kismet.sh`, `make`, `make install` | Your `kismet_site.conf`, login, API keys and logs | Minutes for a helper change; about 78 minutes on a Pi 4 when Kismet itself must be recompiled |
| [Python remote helper](#the-python-remote-helper) | `git pull`, then `pip install -r requirements.txt` | Everything: it has no settings of its own | A minute |
| [Docker images](#docker-images) | Pull, or rebuild, then recreate the containers | The login, API keys and logs, in the volumes | A pull: minutes. A rebuild on a Pi: about a minute for a helper change, about 80 minutes when Kismet is recompiled |

A sensible order: stop everything that uses the boards, update the software on the computers, reflash the boards, then start again.

The parts do not all have to move together, but the firmware has limits:

- A board flashed by the sibling project [esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer) with its firmware 1.2.0 speaks the same line protocol and is meant to work on all three radios; the helpers fill in the BLE checksums that firmware leaves empty.
- In testing, two of the four boards reported the same app version as that 1.2.0 image, streamed Wi-Fi, and never answered the helpers' `START`. They worked only after they were reflashed with this project's image; see step 1 of [Guide: First Capture](Guide-First-Capture).
- The sibling's older firmware does less: 1.0.0 has no `MODE` command and captures Wi-Fi only, and 1.1.0 has no BLE. A `btle` source fails on both, and a `zigbee` source on 1.0.0. <!-- VERIFY: btle on 1.0.0/1.1.0 and zigbee on 1.0.0 fail with "lost sync (the board sends link type ...)" and then the 15 s message (derived from the helpers' code, not run) -->

So reflash when the firmware has changed: the helpers' fix-ups are for compatibility, not a replacement.

The examples use the project in `~/esp32c5-kismet-wifi-interface`, Kismet's source in `~/src/kismet` and its install in `~/kismet-install`, as in [Install on Raspberry Pi](Install-on-Raspberry-Pi). Change the paths to yours.

## Before you start: free the boards

A board's port can be open in one program at a time. Stop everything that has it before you flash it:

- Kismet with local sources: Ctrl+C in its terminal, or `sudo systemctl stop kismet` for a service;
- the Python remote helper: Ctrl+C or Ctrl+Break in its window, or `sudo systemctl stop esp32c5-remote-helper` for a Linux service;
- the C helper as a service: `sudo systemctl stop esp32c5-helper-wifi` (or whatever you named it);
- a Docker container that uses the boards: `sudo docker compose stop`.

> **Warning:** On Linux the helpers lock the port, and esptool respects that lock, so it refuses a board that a helper holds. That lock does not reach from a container to the host: esptool on the host is not stopped from opening a board that Kismet in a container is using. Always stop the container before flashing its boards. <!-- VERIFY: still true once the helpers set TIOCEXCL on the port (planned) -->

## The firmware

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

### 3. Boards on the sibling's oldest firmware

A board still on the sibling project's firmware 1.0.0 or 1.1.0 has a smaller app partition than this firmware needs. Flash the merged image at 0x0, or use `idf.py flash`: both write the new partition table. An update that writes only the app would not fit.

### 4. Which firmware is on a board?

There is no command to ask a board over USB. Two ways to tell:

- The board's UART0 log port (115200 baud, TX on GPIO11) prints the version at every boot, in a line `App version:`. A build from a clone of this repository shows the `git describe` of the tree it was built from, with `-dirty` when the tree had changes. [Hardware](Hardware) shows how to read that port.
- Under Kismet, a BTLE source on older firmware produces the one-time message `<name>: the board's firmware does not mark BTLE packets as CRC checked, ...`. Current firmware never triggers it.

<!-- VERIFY: the App version string of a build from the published repository (builds from a tree without commits said "1") -->

## Kismet and the C helper (native build)

The C helper is built as part of Kismet's source tree. An update of this project usually changes only the helper, which rebuilds in minutes on top of the Kismet you already compiled.

### Same Kismet, newer helper

1. Get the new version of the project:

   ```bash
   cd ~/esp32c5-kismet-wifi-interface
   git pull
   ```

2. Copy it into Kismet's tree. The script copies the helper and its server-side header again, skips every edit that is already there, and regenerates `configure`:

   ```bash
   sh ~/esp32c5-kismet-wifi-interface/kismet/add-to-kismet.sh ~/src/kismet
   ```

3. Rebuild:

   ```bash
   cd ~/src/kismet
   make
   ```

   `make` rebuilds the helper, and every time also recompiles `kismet_server.cc` and relinks the `kismet` program: the script copies `datasource_esp32c5.h` on each run, which gives it a new time stamp, and `kismet_server.cc` includes it. That is minutes, not a full rebuild of Kismet. <!-- VERIFY: time of the helper rebuild plus the kismet_server.cc recompile and relink on a Pi 4 --> If this is the first time the script fixed Kismet's memory leak in `capture_framework.c`, every capture helper is relinked once.

   `make` also prints `'Makefile.in' or 'configure' are more current than this Makefile.  You should re-run 'configure'.` after every run of the script, because the script regenerates `configure`. It is only a notice: `make` carries on and builds (checked with GNU Make 4.3 on Kismet's rule, which only echoes the message). Re-run `./configure`, with the options you used the first time, when the update changed `kismet/capture_esp32c5/Makefile.in`, from which `configure` writes the helper's Makefile. <!-- VERIFY: whether re-running ./configure then forces a full rebuild of Kismet -->

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

Change `<commit>` to the one you want. `git checkout -- .` undoes the script's edits, and `git clean -xfd` removes the files it added and everything the build produced, which a new commit has to rebuild anyway. [Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support#trying-a-newer-kismet) has the same steps. <!-- VERIFY: this sequence as a way to undo add-to-kismet.sh and move to a newer Kismet (not run) -->

Then `./configure` with your options, `make` and `make install` as for the first build. Kismet itself is recompiled: about 78 minutes on a Raspberry Pi 4 (8 GB).

What the script may say on a newer Kismet:

| Message | Meaning |
|---|---|
| `anchor not found, Kismet has changed: ...` | The script stops. Kismet moved the lines it edits (those of the CatSniffer Zigbee helper, which it uses as anchors). Go back to `cfe427074`, and report the commit |
| `capture_framework.c: cf_commit_packet has changed, its metadata leak not fixed` | The script carries on. Kismet changed the function that leaks; check whether the new Kismet fixed the leak itself |
| `capture_framework.c: cf_commit_packet not found, its metadata leak not fixed` | The script carries on. Kismet renamed or removed the function; the same check applies |
| `edited capture_framework.c` | The leak fix was applied: the first run on this tree |
| no line about `capture_framework.c` | The fix is already there, from an earlier run or because Kismet frees that memory itself |

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

Each source keeps its ID, which comes from the board's MAC and the radio, so Kismet recognises the sources when the new helper connects and reuses them.

## Docker images

Your login, API keys and logs are in the named volumes `kismet-home` and `kismet-data`, so recreating the containers keeps them.

### Published images

The images are published as `ghcr.io/oshri-almog/esp32c5-kismet`, with the tags `latest`, a version number and `demo`. From the project folder:

```bash
sudo docker compose pull
sudo docker compose up -d
```

<!-- VERIFY: nothing is published yet; test pull-and-recreate once the first release exists -->

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
| `docker/entrypoint.sh` or `docker/kismet_site.conf` | Only the last layers | Seconds to a minute |
| `kismet/datasource_esp32c5.h`, `kismet/add-to-kismet.sh` or `kismet/capture_esp32c5/Makefile.in` | Kismet, from the start | About 80 minutes |
| A build argument (`JOBS`, `KISMET_REF`, `KISMET_REPO`, `DEBIAN`) | Everything | About 80 minutes |

<!-- VERIFY: the "seconds to a minute" row for entrypoint or site-conf changes (derived from the layer order, not timed) -->

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
