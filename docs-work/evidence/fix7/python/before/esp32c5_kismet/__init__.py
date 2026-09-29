"""The Python remote helper for ESP32-C5 sniffer boards: Wi-Fi, 802.15.4 (Zigbee/Thread) and Bluetooth LE
advertising, fed to a Kismet server elsewhere over Kismet's remote capture.

    python -m esp32c5_kismet.remote --help

remote is the command line, the source definitions and the connections to Kismet; board the serial link to
a board; kismet_v3 Kismet's external capture protocol. Nothing is installed: it runs from the repository
root with the packages in requirements.txt. The C helper, kismet_cap_esp32c5, does the same job on Linux,
started by Kismet or with --connect, and both follow the same rules.
"""

# Sent to Kismet in every open report as the helper's version, esp32c5_kismet-<version> (remote.HELPER_VERSION)
__version__ = "0.1.0"
