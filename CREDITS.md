# Credits and prior art

Everything in this repository was written for it, except where a file says otherwise. Nothing here
should be read as an endorsement by the authors named below, who had no part in it.

## Where this comes from

**[esp32c5-wireshark-sniffer](https://github.com/oshri-almog/esp32c5-wireshark-sniffer).** The
firmware in [`firmware/`](firmware/) started as that project's firmware, and the serial stream code
in [`esp32c5_kismet/board.py`](esp32c5_kismet/board.py) as its `host/sniffer.py`. The board speaks
the same line protocol in both projects, so a board on that project's firmware 1.2.0 works here,
and one flashed here is expected to work there (not yet tried). The changes made here are listed
in the README.

That project in turn owes its approach to Abir Mojumder's ESP32 packet sniffer sketch and to
[@xdavidhu](https://github.com/xdavidhu)'s SerialShark; see its own CREDITS.md.

## Standing on

- **[Kismet](https://www.kismetwireless.net/)**, by Mike Kershaw (dragorn) and contributors. The C
  helper in [`kismet/`](kismet/) is built on Kismet's capture framework
  (`capture_framework.c`) and is meant to become part of Kismet; it follows the layout of the
  serial capture sources already there, in particular `capture_freaklabs_zigbee_v2` and
  `capture_catsniffer_zigbee`. The Python remote helper implements Kismet's external capture
  protocol (v3) from `kis_external_packet.h` and `capture_framework.c`.
- **Espressif's ESP-IDF**: the `esp_wifi` promiscuous mode, the IEEE 802.15.4 driver, and NimBLE.
- **radiotap**, the **IEEE 802.15.4 TAP** link type, and the **Bluetooth LE link layer
  pseudo-header** (LINKTYPE 256), which carry the per-frame radio metadata.
- **[Wireshark](https://www.wireshark.org/)**, whose BTLE dissector accepts the advertising CRC
  of the test packet the helpers' CRC code is checked against.
- **msgpack**, **websocket-client** and **pyserial** for the Python helper.
- **[ESP Web Tools](https://github.com/esphome/esp-web-tools)** by ESPHome (Apache-2.0), with
  Espressif's esptool-js inside it, which the web flasher in [`web/`](web/) runs on.
