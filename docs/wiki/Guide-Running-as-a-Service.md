This guide makes a capture setup start by itself: Kismet with its board sources as a systemd service, the C helper or the Python remote helper feeding a remote Kismet as a service, the Docker containers through their restart policy, and the Python remote helper at logon on Windows. It is for a machine that should capture unattended, such as a Raspberry Pi in a cupboard.

> **Note:** Only capture on networks and devices you own or are authorised to test. A setup that starts by itself keeps recording until you stop it, so decide where the logs go and who can read them. To keep other people's devices out of the log, see [Kismet Configuration](Kismet-Configuration#logging-only-your-own-devices).

**Status:** the set-ups on this page have not all run as written. What has run on the test Pi, with builds from before the latest changes: Kismet and the Python remote helper each as a systemd *user* unit (`systemctl --user`, so without `User=`, `Group=` and `sudo`), with the helper's API key in an `EnvironmentFile`. Kismet's messages reached the journal; the helper captured from two boards named by their by-id links, came back after a Kismet restart and after being killed, exited with status 0 when stopped, was not restarted after exit status 2, and waited for a missing board without adding a source to Kismet. The C helper's login from `KISMET_CAP_APIKEY`, its reconnect after a Kismet restart and its wait for a missing board ran by hand, without systemd. Of the Windows section, the batch file ran by hand on Windows 11. Not run yet: the system units below, a reboot, permanent `source=` lines in `kismet_site.conf`, the Docker containers after a reboot, and the Windows logon task. <!-- VERIFY: the system units as written (User=pi, sudo) and a reboot on the Pi; the Docker containers after a reboot; the Windows logon task (Task Scheduler, a logon, sleep/wake); then shorten this paragraph -->

| What | Where it runs | Section |
|---|---|---|
| Kismet with boards plugged into the same machine | Raspberry Pi or Linux, native build | [Kismet as a systemd service](#kismet-as-a-systemd-service) |
| Boards on this machine, Kismet on another | Raspberry Pi or Linux, native build | [The C helper as a service](#the-c-helper-as-a-service) |
| Boards on this machine, Kismet on another, without building Kismet here | Raspberry Pi or Linux, Python | [The Python remote helper as a service on Linux](#the-python-remote-helper-as-a-service-on-linux) |
| Either of the two, in Docker | Raspberry Pi or Linux with Docker | [Docker: restart policies](#docker-restart-policies) |
| Boards on a Windows PC, Kismet elsewhere | Windows | [The Python remote helper at logon on Windows](#the-python-remote-helper-at-logon-on-windows) |

The examples use the user `pi` with home `/home/pi`, Kismet built into `/home/pi/kismet-install` as in [Install on Raspberry Pi](Install-on-Raspberry-Pi), a Kismet server at `192.168.1.50`, and board names from `/dev/serial/by-id/`. Change them to yours.

## Kismet as a systemd service

Kismet's source tree has a systemd unit. `configure` writes it, with your install prefix filled in, to `packaging/systemd/kismet.service`, but `make install` does not install it. As shipped it runs Kismet as root. This section installs it and runs Kismet as your user instead, which is all the boards need: the helper needs read and write access to the serial port and nothing else.

### 1. Put the sources and the log folder in kismet_site.conf

A service has no command line to type `-c` on, and it starts in `/`, where your user cannot write a log. Kismet's default `log_prefix=./` would make it fail with `Unable to open KismetDB log at ...` and exit. So make a log folder:

```bash
mkdir -p /home/pi/kismet-logs
```

Then create `/home/pi/kismet-install/etc/kismet_site.conf` (Kismet reads it last, and its settings win):

```ini
# One source per board, by its stable name. Change the MACs to your boards' (ls -l /dev/serial/by-id/).
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=wifi-a
source=esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=btle,name=c5-btle

# Logs go here. The folder must exist and belong to the service's user.
log_prefix=/home/pi/kismet-logs/
```

Kismet started without `-c` picks these sources up; that was checked with simulated boards (the runs with real boards gave their sources with `-c`).

Name the boards by their `/dev/serial/by-id/` links, not by `ttyACM` numbers, which follow the order in which the boards come up. A board that is not there yet when Kismet starts is no problem: Kismet reports the source's error and tries to open it again every 5 s until the board appears.

Keep each board on the same radio from one start to the next. A board changes radio by rebooting, and a switch at a Kismet start with sources for mixed radios can leave a board silent until it is reset or replugged, which an unattended machine cannot do for itself ([Troubleshooting](Troubleshooting#a-board-stops-answering-after-a-radio-switch)).

For a Kismet that only receives remote sources, for example from [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi), leave out the `source=` lines and keep `log_prefix`.

### 2. Set the web login

The service runs Kismet as `pi`, so Kismet reads its login from `pi`'s home directory. If you have not set one yet (see [Guide: First Capture](Guide-First-Capture)):

```bash
mkdir -p /home/pi/.kismet
printf 'httpd_username=%s\nhttpd_password=%s\n' admin 'choose-a-long-password' > /home/pi/.kismet/kismet_httpd.conf
chmod 600 /home/pi/.kismet/kismet_httpd.conf
```

Without a login, the first person to open port 2501 after boot would choose it.

### 3. Install Kismet's unit

Check that the unit points at your install:

```bash
grep -E 'ExecStart|User' ~/src/kismet/packaging/systemd/kismet.service
```

```text
User=root
ExecStart=/home/pi/kismet-install/bin/kismet --no-ncurses-wrapper
```

Install it, then change the user it runs as:

```bash
sudo cp ~/src/kismet/packaging/systemd/kismet.service /lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl edit kismet
```

`systemctl edit` opens an editor for an override. Put in:

```ini
[Service]
User=pi
Group=pi
SupplementaryGroups=dialout
```

and save. `dialout` is the group that owns `/dev/ttyACM*` on Debian and Raspberry Pi OS. <!-- VERIFY: whether SupplementaryGroups=dialout is needed, or systemd already gives User=pi its groups; harmless either way -->

Kismet's unit also has `Restart=always`, so systemd starts Kismet again if it exits.

### 4. Start it, and at every boot

```bash
sudo systemctl enable kismet
sudo systemctl start kismet
```

Check it:

```bash
systemctl status kismet
journalctl -u kismet -f
```

Kismet's own log lines go to the journal. Look for `Loading config override file '/home/pi/kismet-install/etc/kismet_site.conf'`, one `capturing` line per source (for example `INFO: wifi-a capturing (wifi)`), and `Opened kismetdb log file '/home/pi/kismet-logs/...'`. Ctrl+C stops following the journal, not Kismet.

To stop it, for example before flashing a board:

```bash
sudo systemctl stop kismet
```

`sudo systemctl disable kismet` stops it from starting at boot.

Why not keep the shipped `User=root`: Kismet then raises a `ROOTUSER` alert, reads its login from `/root/.kismet`, and runs the helpers as root, which this helper does not need. Kismet's own documentation recommends running it as a normal user.

## The C helper as a service

On a machine with boards but no Kismet server, such as a second Pi, the C helper `kismet_cap_esp32c5` can feed the boards to a Kismet elsewhere over remote capture. It comes with the native build ([Building Kismet with ESP32-C5 Support](Building-Kismet-with-ESP32-C5-Support)); you do not have to run Kismet on this machine. Each helper takes one `--source`, so run one service per board.

### 1. Store the API key

Create an API key with the `datasource` role on the Kismet server ([Remote Capture](Remote-Capture)), and store it where only root can read it. The helper reads it from the environment variable `KISMET_CAP_APIKEY`, which keeps it off the command line and out of the process list:

```bash
echo 'KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35' | sudo tee /etc/esp32c5-helper.env > /dev/null
sudo chmod 600 /etc/esp32c5-helper.env
```

Change the key to yours. The key then also sits in your shell history; clear that line if it matters.

### 2. Write the unit

Create `/etc/systemd/system/esp32c5-helper-wifi.service`, for example with `sudo nano`:

```ini
[Unit]
Description=ESP32-C5 board to a remote Kismet (Wi-Fi)
After=network-online.target
Wants=network-online.target

[Service]
User=pi
Group=pi
SupplementaryGroups=dialout
EnvironmentFile=/etc/esp32c5-helper.env
ExecStart=/home/pi/kismet-install/bin/kismet_cap_esp32c5 --connect 192.168.1.50:2501 --source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=pi-wifi
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Change the server address, the board's link and the name. For a second board, copy the file under another name (`esp32c5-helper-btle.service`) with that board's `--source`.

<!-- VERIFY: this system unit on the Pi (User=pi, EnvironmentFile): the helper connects, reconnects after a Kismet restart, and comes back after a reboot (the reconnect after a Kismet restart ran by hand, without systemd) -->

How it behaves:

- **Kismet goes away:** the helper reconnects by itself every 5 s until Kismet is back, and Kismet recognises the source by its ID.
- **The board is missing when the helper starts:** with the board named by its `/dev/serial/by-id/` link, as in this unit, the helper connects anyway, and the open fails. Kismet logs `Data source 'pi-wifi / esp32c5:device=...' ('esp32c5') encountered an error: cannot open ...` and `Error connecting new remote source pi-wifi (<uuid>) - cannot open /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00: No such file or directory`, and does not list the source. The `<uuid>` there is made from the path, as the board's MAC is not known yet. The helper tries again every 5 s, and the source appears under the board's usual ID once the board is there. On the test Pi, with this unit's `--source` run by hand, a missing board was logged this way every 5 s; in another run, a board's arrival was simulated with a link, not a real plug-in. Only a definition that names no port, such as a bare `esp32c5` or a free-form name like `esp32c5-kitchen`, stops before connecting when there is no board or more than one: `FATAL: Could not probe local source prior to connecting to the remote host: ...`. The helper then tries again 5 s later, and goes on doing so.
- **Another capture holds the board**, for example a Kismet on this machine capturing from it, or the same helper started by hand: the helper does not offer the source to Kismet, which would otherwise close the running capture to make room for it. It logs `FATAL: Could not probe local source prior to connecting to the remote host: pi-wifi: <device> is already in use by another capture; not offering it to Kismet until it is free (looked at again every 5 seconds)` and looks again every 5 s.
- **The board disappears while capturing:** after 15 s without capture the helper gives up on it, and it is started again 5 s later, by the helper's own retry or, if the helper exits, by systemd.
- **The service is stopped:** systemd stops the helper and its capture process together, and the port is free at once.

<!-- VERIFY: a remote C helper whose by-id board is missing, under systemd on the Pi, with the board really plugged in later: the source appears under the board's usual ID, with no second source -->

### 3. Start it, and at every boot

```bash
sudo systemctl daemon-reload
sudo systemctl enable esp32c5-helper-wifi
sudo systemctl start esp32c5-helper-wifi
journalctl -u esp32c5-helper-wifi -f
```

On the Kismet server the source appears under **Data Sources** as a remote source, and Kismet logs `New remote source pi-wifi (...) connected`, then `INFO: pi-wifi - pi-wifi capturing (wifi)`. On the test Pi the C helper's first packet reached Kismet about 1.2 s after the helper started, and packets then kept arriving steadily, in nearly every second (the longest gap was about 2 s). The helper's own journal shows the capture framework's lines, such as `INFO: 192.168.1.50:2501 starting capture...`; its status messages, `capturing` included, are in Kismet's log.

Stop the helper before you use the board for anything else, or before flashing it: `sudo systemctl stop esp32c5-helper-wifi`.

## The Python remote helper as a service on Linux

The Python remote helper also runs on Linux, and needs no Kismet build on this machine: only Python and the project's three packages. One process takes several `--source` options, so one service covers all the boards. It exits with status 0 when systemd stops it (SIGTERM) and with 2 for a mistake on its command line. A source never ends by itself, so status 1 means an internal error ended every source.

### 1. Install it in a virtual environment

In the project folder (clone it there first if this machine has no copy):

```bash
sudo apt-get install -y python3-venv
cd /home/pi/esp32c5-kismet-wifi-interface
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

### 2. Store the API key

Store the key in `/etc/esp32c5-helper.env` exactly as in [step 1 of the C helper section](#1-store-the-api-key). The Python remote helper reads the same `KISMET_CAP_APIKEY` when no `--apikey`, `--user` or `--password` is given.

### 3. Write the unit

Create `/etc/systemd/system/esp32c5-remote-helper.service`:

```ini
[Unit]
Description=ESP32-C5 boards to a remote Kismet (Python remote helper)
After=network-online.target
Wants=network-online.target

[Service]
User=pi
Group=pi
SupplementaryGroups=dialout
EnvironmentFile=/etc/esp32c5-helper.env
WorkingDirectory=/home/pi/esp32c5-kismet-wifi-interface
ExecStart=/home/pi/esp32c5-kismet-wifi-interface/.venv/bin/python -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:03-if00,mode=wifi,name=pi-wifi --source esp32c5:device=/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_F0:F5:BD:01:02:04-if00,mode=btle,name=pi-btle
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=2

[Install]
WantedBy=multi-user.target
```

Change the folder, the server address, the boards' links and the names.

- `WorkingDirectory` matters: the helper runs as `python -m esp32c5_kismet.remote` and is found only from the project folder.
- `Restart=on-failure` starts it again after status 1 or after it was killed; `RestartPreventExitStatus=2` keeps a typo on the command line from restarting it every 5 s.
- A board named by its link that is missing is waited for: the helper logs `<definition>: /dev/serial/by-id/...-if00 is not there; is the board plugged in? (waiting for it)` every 5 s and does not contact Kismet for that source until the board is there.

<!-- VERIFY: this unit as a system unit on the Pi (User=pi, SupplementaryGroups=dialout) with the current helper; a restart after exit status 1 (status 0 on stop, a restart after a kill, no restart after status 2 and a missing board waited for ran as a --user unit with an earlier build) -->

### 4. Start it, and at every boot

```bash
sudo systemctl daemon-reload
sudo systemctl enable esp32c5-remote-helper
sudo systemctl start esp32c5-remote-helper
journalctl -u esp32c5-remote-helper -f
```

Stop it before you use a board for anything else, or before flashing: `sudo systemctl stop esp32c5-remote-helper`.

## Docker: restart policies

The project's `compose.yaml` gives the `kismet` and `helper` services `restart: unless-stopped`. Start them once:

```bash
sudo docker compose up -d
```

or, for the helper service on a machine with boards but no Kismet:

```bash
sudo docker compose --profile helper up -d helper
```

From then on Docker starts them again whenever Docker itself starts, including after a reboot, unless you stopped them yourself. `sudo docker compose stop` counts as stopping them: they stay stopped after a reboot until you run `up -d` again. The `demo` service has no restart policy. With plain `docker run`, the same is `--restart unless-stopped` ([Install with Docker](Install-with-Docker)).

Docker's own service has to start at boot for this to work. Check it, and enable it if it prints `disabled`:

```bash
systemctl is-enabled docker
sudo systemctl enable docker
```

<!-- VERIFY: a reboot of the Pi brings the kismet and helper containers back with their sources (not tested); whether Debian's docker.io enables docker.service by default -->

Boards at boot:

- **`kismet` service:** the sources are worked out once, when the container starts. If no board is there yet, the container waits up to 30 s for one, then until no more appear. A board that turns up later is not added by itself. To be safe after a reboot, list the boards in `KISMET_SOURCES` in `.env`: Kismet then keeps retrying a listed source every 5 s until its board appears. Sources in `KISMET_SOURCES` by their `/dev/serial/by-id/` links ran in the container on the test Pi. <!-- VERIFY: the entrypoint's wait for a board at start (ESP32C5_WAIT) and its wait until the board list settles, with real boards after a reboot -->
- **`helper` service:** it runs the C helper, one per source, and the C helper keeps trying by itself (as in [the C helper as a service](#the-c-helper-as-a-service)), so a board listed in `KISMET_SOURCES` that comes up late is picked up. With no board at all and no `KISMET_SOURCES`, the container exits (`helper: no ESP32-C5 board found and KISMET_SOURCES is empty`) and Docker restarts it until a board is there.

Your login, API keys and logs are in named volumes, so they survive restarts and reboots.

## The Python remote helper at logon on Windows

To start the helper when you log on to a Windows PC, have Task Scheduler run a small batch file. The batch file was tested by hand on Windows 11; the task, a logon, and how the helper behaves when the PC sleeps and wakes have not been tested. <!-- VERIFY: the Windows task: its settings, a logon, and sleep/wake -->

### 1. Write the batch file

Create `start-helper.cmd` in the project folder, for example `C:\Users\you\esp32c5-kismet-wifi-interface\start-helper.cmd`:

```text
@echo off
cd /d C:\Users\you\esp32c5-kismet-wifi-interface
set KISMET_CAP_APIKEY=3F9A6C1E07B24D58A1C9E2F4608B7D35
:again
"C:\Users\you\AppData\Local\Programs\Python\Python313\python.exe" -m esp32c5_kismet.remote --connect 192.168.1.50:2501 --source esp32c5-COM14:name=win-wifi --source esp32c5btle-COM15:name=win-btle
if %errorlevel% equ 1 (
    timeout /t 60 >nul
    goto again
)
```

Change the folder, the key, the server and the sources to yours. The last four lines start the helper again a minute after it exits with status 1, which it does when an internal error has ended every source. Python also exits with status 1 when it cannot find the helper (`Error while finding module specification for 'esp32c5_kismet.remote'`), for example after a typo in the `cd /d` folder, and the file then starts it again every minute without end; run it by hand first (below). After Ctrl+C the helper exits with status 0 and the batch file ends. A mistake in the helper's own options gives status 2 and also ends it, so a typo there does not loop. Use the full path of `python.exe`, because a task does not always get the same `PATH` as your console. PowerShell prints it:

```powershell
(Get-Command python).Source
```

The file holds the API key, so keep it in your own user folder. A `datasource` key can only feed sources, and you can delete it in Kismet's **Settings → API Keys** if the file leaks.

Run the file once by hand and check that the sources appear in Kismet.

### 2. Create the task

1. Open **Task Scheduler** and choose **Create Task…** (not *Create Basic Task*, which hides the settings below).
2. **General:** name it `ESP32-C5 helper`, and keep **Run only when user is logged on**. The helper then runs in a console window on your desktop, where Ctrl+C stops it.
3. **Triggers → New…:** *Begin the task* **At log on**, for your user.
4. **Actions → New…:** **Start a program**, with the path of `start-helper.cmd`.
5. **Conditions:** untick **Start the task only if the computer is on AC power**, or a laptop on battery will not start it.
6. **Settings:** untick **Stop the task if it runs longer than** (3 days by default).
7. Press **OK**, then right-click the task and choose **Run** to try it.

Do not count on **If the task fails, restart every** to restart the helper. That setting is meant for a task that fails to run, and the batch file does not pass the helper's exit status on: run with `cmd /c`, it ended with exit code 0 after the helper had exited with status 2. The loop in the batch file does that job instead. <!-- VERIFY: whether Task Scheduler's "If the task fails, restart every" ever reacts to start-helper.cmd -->

The helper keeps each source trying on its own: it tries to reconnect about every 7 s while Kismet is away, and waits for a board that is unplugged. So the restart in the batch file is only a safety net.

### 3. Stop it

Press **Ctrl+C** or **Ctrl+Break** in the helper's window. It logs `stopping`, releases the COM ports and exits with status 0; pressing it again while it stops changes nothing. cmd may then ask `Terminate batch job (Y/N)?`; with status 0 either answer ends the batch file. Ctrl+C during the minute's wait after an error asks the same; there, answer Y, as N starts the helper again at once. Kismet then shows the sources as stopped with `websocket connection closed`, which is expected. Ending the task in Task Scheduler stops it by force; the COM ports are released at once all the same.

## Logs and disk space

A service writes one kismetdb per start, and it grows with every packet: Kismet keeps the packets it marks as duplicates too. For scale, one Wi-Fi and one BTLE board on the test Pi, with Kismet's default logging, grew the kismetdb by about 47 MB an hour, measured over 30 minutes (about 1.1 GB a day if it goes on like that). In those 30 minutes the Wi-Fi board delivered about 55,500 packets and the BTLE board about 28,000, nearly all of the BTLE ones duplicates.

To keep the logs smaller, add one of these to `kismet_site.conf`:

```ini
# keep devices, messages and alerts, but no packets
kis_log_packets=false
```

```ini
# keep packets, but not the duplicates (most BLE packets)
kis_log_duplicate_packets=false
```

A pcapng log can be split into files of a set size with `pcapng_log_max_mb=1000`. Kismet's `kismet_logging.conf` also has options that remove old records from a running kismetdb: `kis_log_packet_timeout`, `kis_log_device_timeout`, `kis_log_message_timeout`, `kis_log_alert_timeout` and `kis_log_snapshot_timeout`, each in seconds (86400 for a day), all off by default. Read their comments in that file before you use them. Nothing deletes old log files, so check the free space in `log_prefix` now and then. [Kismet Configuration](Kismet-Configuration#logging) lists the logging options.

These options were checked with simulated boards against a Kismet built from this project's commit: with `kis_log_packets=false` the kismetdb kept devices, messages and alerts but no packets; with `kis_log_duplicate_packets=false` it kept no duplicates; and each timeout removed older records while Kismet ran (packets every 15 s, the other records once a minute). None of them changes the pcapng log.

## See also

- [Install on Raspberry Pi](Install-on-Raspberry-Pi) and [Install on Linux](Install-on-Linux): the native build these services run
- [Install with Docker](Install-with-Docker) and [Docker Reference](Docker-Reference): the services, variables and volumes
- [Guide: Windows Boards to a Pi](Guide-Windows-Boards-to-a-Pi): the Windows side, started by hand
- [Kismet Configuration](Kismet-Configuration): `kismet_site.conf` and logging
- [Guide: Updating](Guide-Updating): what to restart after an update
