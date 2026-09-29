# syntax=docker/dockerfile:1
#
# Kismet with the ESP32-C5 capture source (the esp32c5 source type and its C helper,
# kismet_cap_esp32c5), for amd64 and arm64 (a Raspberry Pi 4 or 5 with a 64-bit OS).
#
#     docker compose up -d                                  see compose.yaml
#     docker build -f docker/Dockerfile -t esp32c5-kismet .
#     docker build -f docker/Dockerfile --target demo -t esp32c5-kismet:demo .
#
# Build from the repository root: .dockerignore lets only kismet/, docker/ and tools/fake_board.py
# into the context.
#
# Kismet has no release with this source in it yet, so it is built from source here, at the
# commit the source was developed against, with kismet/add-to-kismet.sh applied. Change
# KISMET_REF to try another commit (--build-arg KISMET_REF=<commit>).
#
# Targets:
#   kismet (the default)  Kismet and kismet_cap_esp32c5
#   demo                  the same, plus a fake board, for trying it out without hardware
#
# What the container does when it starts (the roles kismet and helper, or any other command) and
# the environment variables it reads are described at the top of docker/entrypoint.sh.
#
# Without compose, the demo needs nothing but a port:
#     docker run --rm -p 127.0.0.1:2501:2501 \
#         -e KISMET_USER=demo -e KISMET_PASSWORD=demo esp32c5-kismet:demo
# Real boards need the device cgroup to allow the USB serial classes, 166 (ttyACM, the boards'
# native USB) and 188 (ttyUSB); without the rules, the log names the one that is missing:
#     docker run -d \
#         --device-cgroup-rule 'c 166:* rmw' --device-cgroup-rule 'c 188:* rmw' \
#         -p 2501:2501 -v kismet-data:/data -v kismet-home:/root/.kismet esp32c5-kismet
# No capability has to be added (no --cap-add): kismet_cap_esp32c5 drops every capability it
# has and needs none, and kismet_site.conf masks Kismet's other capture helpers, which crash
# without NET_ADMIN.
#
# Every target, build argument, variable, volume and port:
# https://github.com/oshri-almog/esp32c5-kismet-wifi-interface/wiki/Docker-Reference

ARG DEBIAN=debian:trixie-slim

# ------------------------------------------------------------------------------------------------
FROM ${DEBIAN} AS build

ARG KISMET_REPO=https://github.com/kismetwireless/kismet.git
ARG KISMET_REF=cfe427074
# Parallel compilers. Kismet's C++ needs about 1.5 GB per compiler, so by default this is as many as
# the free memory allows, and no more than the cores or 4: a 2 GB Raspberry Pi gets 1, not an OOM.
ARG JOBS=

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git build-essential pkg-config autoconf automake python3 \
        libwebsockets-dev zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev \
        libsqlite3-dev libpcre2-dev libssl-dev libusb-1.0-0-dev libdw-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --filter=blob:none "$KISMET_REPO" kismet \
    && git -C kismet checkout --quiet "$KISMET_REF"

# Kismet takes an hour and more to build on a Raspberry Pi, the capture helper seconds. So Kismet
# is built first with a stand-in for the helper's source, and that layer stays cached while only
# the helper changes; the real helper is built on top of it below.
COPY kismet/add-to-kismet.sh kismet/datasource_esp32c5.h /src/esp32c5/kismet/
COPY kismet/capture_esp32c5/Makefile.in /src/esp32c5/kismet/capture_esp32c5/
# A Windows checkout with core.autocrlf can hand these over with CRLF line ends (.gitattributes
# asks git not to), and sh and make both choke on the CR
RUN sed -i 's/\r$//' /src/esp32c5/kismet/add-to-kismet.sh /src/esp32c5/kismet/capture_esp32c5/Makefile.in \
    && echo 'int main(void) { return 0; }' > /src/esp32c5/kismet/capture_esp32c5/capture_esp32c5.c \
    && sh /src/esp32c5/kismet/add-to-kismet.sh /src/kismet

# The optional pieces left out are hardware this image is not for (SDRs, Ubertooth, bladeRF)
# or host services a container does not have (NetworkManager, lm-sensors, MQTT).
WORKDIR /src/kismet
RUN ./configure --prefix=/usr --sysconfdir=/etc/kismet --localstatedir=/var \
        --disable-python-tools --disable-librtlsdr --disable-ubertooth --disable-bladerf \
        --disable-btgeiger --disable-libnm --disable-lmsensors --disable-mosquitto \
    && jobs=${JOBS:-$(awk -v cores="$(nproc)" '/^MemAvailable:/ { \
            j = int($2 / 1500000); if (j > cores) j = cores; if (j > 4) j = 4; if (j < 1) j = 1; \
            print j }' /proc/meminfo)} \
    && echo "building with -j$jobs" \
    && make -j"$jobs"

# The helper itself. "clean" first: the copied source can carry an older time than the stand-in's
# object file, and make would then keep the stand-in.
COPY kismet/capture_esp32c5/capture_esp32c5.c capture_esp32c5/
RUN make -C capture_esp32c5 clean \
    && make -C capture_esp32c5 \
    && make install DESTDIR=/out INSTUSR=root INSTGRP=root SUIDGROUP=root

# Kismet compiles with -g and "make install" copies the programs as they are, which makes
# /usr/bin/kismet about 470 MB, nearly all of it debug information, and the image five times the
# size it needs to be (on a Raspberry Pi's SD card, too). --strip-debug keeps the symbol table, so
# a crash backtrace still names the functions. Only ELF files: kismet_server is a shell script.
RUN find /out -type f -perm -u+x -exec sh -c \
        'for f; do if head -c4 "$f" | grep -q ELF; then strip --strip-debug "$f" || exit 1; fi; done' \
        sh {} +

# The Debian packages that hold the shared libraries the installed programs link against, so the
# runtime stage installs exactly those, whatever this Debian release happens to call them.
RUN find /out -type f -perm -u+x -exec ldd {} + 2>/dev/null \
        | awk '/=> \// { print $3 }' | xargs -r readlink -f | sort -u \
        | xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | sort -u > /runtime-packages.txt \
    && cat /runtime-packages.txt

# ------------------------------------------------------------------------------------------------
FROM ${DEBIAN} AS kismet

COPY --from=build /runtime-packages.txt /tmp/
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        $(cat /tmp/runtime-packages.txt) ca-certificates \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt

COPY --from=build /out/ /
# Logs to /data, and Kismet's other capture helpers masked (the file says why)
COPY docker/kismet_site.conf /etc/kismet/kismet_site.conf
COPY docker/entrypoint.sh /usr/local/bin/esp32c5-kismet
# Both have to start, i.e. find every library they link against. "kismet --version" prints the
# version and then exits with 1, so its output is what is checked; the capture helper's --version
# exits with 0 (its --help exits with 255).
RUN sed -i 's/\r$//' /usr/local/bin/esp32c5-kismet /etc/kismet/kismet_site.conf \
    && chmod 755 /usr/local/bin/esp32c5-kismet \
    && kismet --version | grep '^Kismet ' \
    && kismet_cap_esp32c5 --version

# /data holds the Kismet logs, /root/.kismet the web login, the API keys and session state
VOLUME ["/data", "/root/.kismet"]
WORKDIR /data
# The web UI, the REST API and remote capture (websocket). The legacy TCP remote capture port 3501
# has no authentication and stays on loopback; see kismet_site.conf.
EXPOSE 2501

ENTRYPOINT ["/usr/local/bin/esp32c5-kismet"]
CMD ["kismet"]

LABEL org.opencontainers.image.title="esp32c5-kismet" \
      org.opencontainers.image.description="Kismet with the ESP32-C5 capture source: Wi-Fi 2.4/5 GHz, Zigbee/Thread and BLE advertising from ESP32-C5 boards" \
      org.opencontainers.image.licenses="GPL-2.0-or-later"

# ------------------------------------------------------------------------------------------------
FROM kismet AS demo

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
COPY tools/fake_board.py /opt/esp32c5/fake_board.py
# The radio of the fake board the entrypoint starts on /tmp/esp32c5-demo, as a source named demo
# (wifi, zigbee or btle). With it, no boards are looked for; -e ESP32C5_DEMO= turns it off.
ENV ESP32C5_DEMO=wifi

# ------------------------------------------------------------------------------------------------
# A plain "docker build" makes the Kismet image, not the demo
FROM kismet
