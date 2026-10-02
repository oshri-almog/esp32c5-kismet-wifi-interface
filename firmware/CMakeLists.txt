# ESP-IDF project: the ESP32-C5 sniffer firmware. One radio at a time -- Wi-Fi (2.4 and 5 GHz), 802.15.4
# or Bluetooth LE advertising -- streamed as a live PCAP over the native USB port to the Kismet helpers.
# No version is set here, so ESP-IDF takes the App version in the boot log from git describe.
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp32c5_sniffer)
