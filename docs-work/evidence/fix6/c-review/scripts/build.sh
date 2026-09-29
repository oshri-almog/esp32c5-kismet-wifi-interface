#!/bin/sh
# build.sh SRC OUT : a kismet_cap_esp32c5 from SRC, against the patched framework in /root/src/kismet
gcc -Wall -Wno-format-truncation -Wno-unused-function -g -pthread -I/root/src/kismet/capture_esp32c5 -I/root/src/kismet -o "$2" "$1" /root/src/kismet/libkismetdatasource.a -lcap -lwebsockets -lpthread -lm
