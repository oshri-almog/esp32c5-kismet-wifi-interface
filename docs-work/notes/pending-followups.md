# Follow-ups after the C and Python fix workflows finish

From the Docker review (docker-review2.json), need helper changes:

1. TIOCEXCL on the tty after the flock, in both helpers (C serial_open; Python board.open_serial on
   POSIX). EBUSY on open -> the same "already in use by another capture" message. Reason: flock locks
   the node's inode, and a container's mknod'd /dev/ttyACMn is a different inode from the host's, so
   host and container helpers (or two containers) do not exclude each other. TIOCEXCL lives on the
   tty_struct. Caveat to document: an opener with CAP_SYS_ADMIN (sudo esptool) is not stopped.
2. Drop ALL capabilities in the C helper (cap_set_proc(empty) + PR_SET_NO_NEW_PRIVS) right after
   cf_handler_parse_opts, instead of cf_drop_most_caps (which keeps NET_ADMIN/NET_RAW and segfaults
   via cf_send_warning before IPC when they are missing). Then remove NET_ADMIN everywhere:
   compose.yaml cap_add, entrypoint check_caps/has_net_admin, Dockerfile header examples,
   docker_smoke.sh --cap-add, CI, and the docs (Install-with-Docker, Docker-Reference,
   Troubleshooting mention NET_ADMIN).

Also from the Pi run: bare `esp32c5` probe claim -> in the C fix stage (EXTRA).

Python helper final (wu0ezqjes): stale docs to fix --
- P17 half login is now completed from the environment like the C helper (--user alone takes
  KISMET_CAP_PASSWORD, --password alone takes KISMET_CAP_USER). Wrong in: Remote-Capture.md ~171,
  Install-on-Windows.md ~170, Command-Line-Reference.md ~219.
- Port names follow serial_name() exactly (tty*, cu.*, cua*, dty*, pts/, no '..'), no stat.
- Windows: virtual COM ports outside the Ports/Modem classes (com0com, serial-over-network) are
  recognised by their DOS device name; uuid= skips the existence check. Suggested lines in
  Source-Definitions.md (~91) and a Troubleshooting entry for "... is not there".
- --connect localhost dials 127.0.0.1 then ::1 but keeps "localhost" for TLS (server_hostname),
  Host and Origin.
- Tests now: Windows test_board 220 / test_kismet_v3 299; WSL 225 / 299 (ws-client 1.9.2 and
  1.7.0); remote_e2e.sh 78/78 twice; 13 mutations caught.

Repo: .env is now in .gitignore (the docker pages carry a caution + VERIFY about it).
Python --list does not leave out boards in use (the C --list does): doc says so; parity optional.

After the in-code docs pass (weljzw3ps): 49 wiki corrections in wiki-corrections-from-code.json.
Hand edits after it:
- The Python helper's 401 message is now: "Kismet refused the websocket: <details> (check the login
  -- --user/--password or KISMET_CAP_USER/KISMET_CAP_PASSWORD -- or the API key -- --apikey or
  KISMET_CAP_APIKEY; the key needs the datasource role)". Old text quoted in
  Guide-Windows-Boards-to-a-Pi.md:238, Install-on-Windows.md:378, Remote-Capture.md:262,
  Troubleshooting.md:364.
- compose.yaml now passes ESP32C5_WAIT (default 30) to the kismet and helper services (it passed it
  to none before); pages that say to set it in a compose.override.yaml are wrong.
- Firmware: two UART log messages corrected (BLE no longer logged as Wi-Fi; the MODE hint lists
  BLE), Kconfig help and sdkconfig.defaults comments corrected. The flashed boards run the build
  from before these log-string changes (USB stream identical); rebuild the firmware for a release.
- Still to do at the very end (they invalidate the Pi's cached Docker layer): add-to-kismet.sh
  header should mention python3; Makefile.in could get the proposed header comment.

After the hardware retest (hw2) and fix rounds 1 (fix6-result.json, hw3) and 2 (fix7, hw4) -- for the wiki:
- Firmware known issue A: a board flashed while it is in 802.15.4 mode comes up answering START with link type 127 but
  captures no Wi-Fi (esptool reset does not help; a MODE BLE then MODE WIFI cycle does). Cause, per the firmware's own
  comment at s_mode: the 802.15.4 blocks are left powered/configured when the chip is reset without esp_ieee802154_disable
  (MODE does that before its restart; esptool does not). Workaround: send MODE WIFI (or run a Wi-Fi source) before
  flashing; after flashing a deaf board, cycle MODE BLE -> MODE WIFI. Reproduced twice on 38:44:BE:BF:D8:0C (hw3 h11).
- Firmware known issue B: intermittently (about 1 in 5 Wi-Fi->BLE switches on 10:BD:A3:C8:7D:54, hw2 n1 and hw3 H9) the
  board re-enumerates on USB during the switch and then never answers START until a reset (esptool reset / replug).
  Both helpers give up after 15 s and Kismet re-opens, which does not cure it. Other boards: USB re-enumeration during a
  MODE switch happens but recovers in ~0.5-2.5 s.
- Whole-image esptool verify-flash always fails once the board has booted: the firmware writes ~2.2 KB of NVS
  (0x9000-0x991b), which the merged image carries as 0xFF. Verify 0x0-0x9000 and 0x10000-end, or before first boot.
- kismetdb packets.frequency is 0 for 802.15.4 and BTLE whatever the helper sends (Kismet server: kis_databaselogfile.cc
  logs common_info.freq_khz, which phy_802154/phy_btle do not set); device records show the right frequency.
- Firmware 1.0.0 (sibling project) answers START but streams no Wi-Fi on these boards; 1.1.0: Wi-Fi + Zigbee work, BTLE
  not (MODE BLE silently ignored); 1.2.0: all three radios work, BTLE flags 0x0013 + zero CRC fixed up by both helpers.

Docs verification pass must re-check: NET_ADMIN removal, TIOCEXCL, entrypoint changes from the
docker-fixes workflow (probe per major, exec role sync, by-id links in the container, hub wait,
login warning), Python helper final behaviour (P1-P17), C fix-stage results.
