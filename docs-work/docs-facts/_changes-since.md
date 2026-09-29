# Changes since the fact sheets were written (read this LAST; it wins over the other sheets)

## C helper (kismet_cap_esp32c5): final, reviewed, all tests pass
Settled (no longer in flux), as in the current kismet/capture_esp32c5/capture_esp32c5.c:
- A definition named the helper's way whose board cannot be found right now (bare `esp32c5` with
  no board or several, `esp32c5-ttyACM9` not plugged in, no sysfs) is claimed by the probe for
  LOCAL sources: Kismet shows the helper's real reason (e.g. "no Espressif USB-Serial-JTAG device
  (USB ID 303a:1001) found; ...", "2 Espressif USB-Serial-JTAG devices ... found; say which one ...")
  as the source error and retries every 5 s, so a board plugged in later is picked up. `type=esp32c5`
  is no longer needed for that. It IS still needed to see the reason for a definition that is wrong
  in itself (bad mode= or channel=, or a name outside the helper's namespace), which otherwise gives
  Kismet's generic "Unable to find driver". In remote mode (--connect) an unresolvable definition
  stops the helper before connecting ("Could not probe local source ..."); the Docker helper role
  restarts it every 5 s.
- --list leaves out a board whose port is in use (found via /proc/locks, the port is never opened);
  all three of its names disappear together.
- Only these are taken as a port in a source name: tty*, cu.*, cua*, dty*, pts/N; a name with ".." is
  refused. Anything else after "esp32c5-" (e.g. esp32c5-kitchen) is a free-form name and the board is
  found automatically.
- Remote login from the environment (KISMET_CAP_APIKEY, or KISMET_CAP_USER + KISMET_CAP_PASSWORD):
  used with --connect or --autodetect, not with --tcp; fills in only the missing half (--user alone
  takes KISMET_CAP_PASSWORD, --password alone takes KISMET_CAP_USER); a command-line value wins.
- Tests: C harness 237/237, tests/kismet_e2e.sh 46/46 (twice), 11 mutations caught.

## Python remote helper: implemented (review still running), offline and e2e tests pass
All of P1-P17 are implemented as intended (see python-helper.md's IN FLUX list) with these specifics:
- Names esp32c5-/esp32c5zigbee-/esp32c5btle-<port>; on Windows the port is COMn in any case
  (esp32c5btle-COM14); --list prints these names.
- channel= strict; BTLE 37-39 stays on 37; with channel_hop=false the helper tells Kismet hopping is
  off (the source shows hopping 0).
- Exclusive port: a second opener gets "<port> is already in use by another capture (an esp32c5 source
  or another program holds it); a board captures with one radio at a time". The C and Python helpers
  exclude each other on the same host.
- COM14, com14 and \\.\COM14 are the same port; /dev/serial/by-id links map to the board's MAC and UUID
  like the C helper. A named port that is absent is waited for (not offered to Kismet under another
  UUID). Two definitions that name no port are refused at startup; two definitions for one port too.
- A port that cannot be opened fails the open with the OS error in Kismet's error_reason.
- requirements.txt: websocket-client>=1.9.1 (older versions had a bug that killed a source for good on
  a connection reset; the helper now survives it anyway).
- Exit status: 0 after a stop request (Ctrl+C, Ctrl+Break, SIGTERM), 1 when every source ended on its
  own, 2 for command-line errors.
- --connect localhost tries 127.0.0.1 first.
- Credentials from KISMET_CAP_APIKEY or KISMET_CAP_USER + KISMET_CAP_PASSWORD when none is given.
- New test: tests/remote_e2e.sh (WSL/Linux as root; Kismet on port 2511 + legacy 3511, the fake board,
  78 checks: websocket, --tcp, zigbee reboot, btle, --inject, --restart-every, channel lock, second
  source refused, older-firmware BTLE, Kismet restart -> same UUID, SIGINT/SIGTERM exit 0, env
  credentials). Offline: tests/test_board.py 218, tests/test_kismet_v3.py 254 checks.

## Coming next (write the CURRENT behaviour, and mark these with VERIFY)
- The helpers will also set TIOCEXCL on the tty, so the port lock holds between a container and the
  host and between containers (today flock alone does not cross the container boundary).
- The C helper will drop all capabilities itself; the Docker image will then NOT need NET_ADMIN, and
  compose.yaml / docker run examples lose --cap-add NET_ADMIN. Until then the docs say NET_ADMIN is
  needed; mark every such place <!-- VERIFY: NET_ADMIN removed? -->.
- The Docker entrypoint is being fixed: it will probe whether the device cgroup allows ttyACM (166) /
  ttyUSB (188) instead of trusting that a node exists, and print a hint naming the missing
  --device-cgroup-rule; the demo will not pick up host boards; the exec role (any other command) will
  also make the device nodes; /dev/serial/by-id links will exist inside the container with the same
  names as on the host; ESP32C5_WAIT waits until the board list stops changing; setting only one of
  KISMET_USER / KISMET_PASSWORD always logs a warning. Plain docker run with boards needs
  --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw'.

## Raspberry Pi Docker build: done
- sudo docker build on the Pi 4 (8 GB), started 16:50, both targets (demo, then kismet) finished at
  18:12 with exit 0: about 80 minutes, almost all of it the Kismet compile at -j4 (JOBS picked
  automatically from free memory). The image layers keep Kismet cached, so a helper-only change
  rebuilds in about a minute. Run as a transient systemd unit so it survives an SSH disconnect.
- Real-board tests of the Docker image on the Pi have not run yet (next step).

## Firmware
- Rebuilt with all 42 Wi-Fi channels in the scan list (169/173/177 were dropped before); merged
  image firmware/build/esp32c5-kismet-merged.bin (1,148,576 bytes, flash at 0x0). Not flashed yet.
- No release asset or web flasher exists for this project's firmware yet; the docs should give the
  build + esptool route, and may mention the sibling project's web flasher (firmware 1.2.0) as an
  alternative that works because the helpers fix up its BLE records, with the differences stated.
