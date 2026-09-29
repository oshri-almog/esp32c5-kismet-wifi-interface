#!/bin/sh
# The helper role's login rule in docker/entrypoint.sh (this repository's, mounted over the image's)
# with a stand-in kismet_cap_esp32c5 that prints the login it was handed and stops the container.
# The existing esp32c5-kismet:latest image is only run, never changed; each container is this
# script's own (--rm).
# Run from Git Bash on Windows, whose Docker has the image: Windows paths, no MSYS path rewriting
export MSYS_NO_PATHCONV=1
REPO='C:/Users/oshria/OneDrive/Documents/GitHub/esp32c5-kismet-wifi-interface'
IMAGE=${IMAGE:-esp32c5-kismet:latest}
STUB='C:/Users/oshria/AppData/Local/Temp/claude/c--Users-oshria-OneDrive-Documents-GitHub-esp32c5-wireshark-sniffer/75fe8a4e-1aa2-48f3-9e8d-8f12a0275438/scratchpad/fix7/c/scripts/stub-cap.sh'
cat > "$STUB" <<'EOF'
#!/bin/sh
echo "stand-in kismet_cap_esp32c5: user=[${KISMET_CAP_USER:-}] password=[${KISMET_CAP_PASSWORD:-}] apikey=[${KISMET_CAP_APIKEY:-}] args: $*"
kill -TERM 1
EOF
chmod 755 "$STUB"

try() {  # try LABEL ENV...
    label=$1; shift
    echo "== $label"
    out=$(docker run --rm --name "esp32c5-fix7-entry-$$" \
        -v "$REPO/docker/entrypoint.sh:/usr/local/bin/esp32c5-kismet:ro" \
        -v "$STUB:/usr/bin/kismet_cap_esp32c5:ro" \
        -e KISMET_SERVER=kismet.example:2501 -e KISMET_SOURCES=esp32c5:device=/dev/null,name=x \
        "$@" "$IMAGE" helper 2>&1)
    status=$?
    echo "$out" | sed 's/^/   /'
    echo "   exit status $status"
}
try "a login with '&', a space and %41, no ':' in the user name: taken" \
    -e KISMET_USER=user -e 'KISMET_PASSWORD=p&w %41x'
try "a user name with ':' and no '&': taken" \
    -e KISMET_USER=us:er -e 'KISMET_PASSWORD=p w%41'
try "a user name with ':' and an '&' in the password: refused" \
    -e KISMET_USER=us:er -e 'KISMET_PASSWORD=p&w'
try "a user name with ':' and an '&' in it: refused" \
    -e 'KISMET_USER=u&s:er' -e KISMET_PASSWORD=pw
try "an API key: taken" \
    -e KISMET_APIKEY=0123456789ABCDEF -e KISMET_USER=us:er -e 'KISMET_PASSWORD=p&w'
rm -f "$STUB"
