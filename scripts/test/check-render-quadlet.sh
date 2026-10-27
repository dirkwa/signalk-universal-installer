#!/usr/bin/env bash
# Verifies render-server-quadlet.sh builds the hardware block without jq
# errors and emits exactly the enabled devices.
#
# Regression guard: the jq array constructor listed four clauses separated
# by commas, each ending in a `| "AddDevice=..."` string pipeline. jq's `|`
# binds across the whole comma-list, so the serial stream got piped into the
# next clause's `select(.enabled ...)` — which tried to index the already
# built "AddDevice=..." STRING with .enabled and died with:
#     Cannot index string with string "enabled"
# Parenthesizing each clause keeps its pipeline local to the array element.
#
# This test renders against a fixture with one enabled serial device plus a
# disabled CAN/BLE/GPIO mix, and asserts: (1) jq emits nothing on stderr,
# (2) the enabled serial device is listed in the SERIAL DEVICES block, (3)
# disabled devices do not appear. Cases 6-8 cover serial devices that are
# absent at render or at start, and the template's start-time device script
# (issue #309). Requires jq. Run from the repo root.

set -euo pipefail

RENDER=${RENDER:-installer/linux/render-server-quadlet.sh}
TEMPLATE=${TEMPLATE:-quadlets/signalk-server.container.template}

if [[ ! -f "$RENDER" ]]; then
    echo "[ERR] $RENDER not found (run from repo root)" >&2
    exit 2
fi
if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] $TEMPLATE not found (run from repo root)" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not installed — render uses the sed fallback, nothing to test here"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The renderer does not stat serial devices -- the template's ExecStartPre
# does, at each start (case 7 runs it) -- so the fixture's by-id path does not
# have to exist.
serialdir="$tmp/serial-by-id"
mkdir -p "$serialdir"
serial_byid="$serialdir/usb-FTDI_TEST-if00-port0"

# Fixture mirroring the real detect-hardware.sh shape: an enabled serial
# device, plus disabled CAN/BLE/GPIO. The comma-list bug fired regardless of
# enabled state — having a present serial entry is enough to reproduce it.
cat >"$tmp/hardware.json" <<JSON
{
  "detectedAt": "2026-01-01T00:00:00Z",
  "serial": [
    {"byId":"$serial_byid","vendor":"FTDI","product":"UART","enabled":true}
  ],
  "can": [
    {"interface":"can0","enabled":false}
  ],
  "bluetooth": { "dbusAvailable": true, "enabled": false },
  "audio": { "present": true, "enabled": false },
  "input": { "present": true, "enabled": false },
  "gpio": { "platform": "rpi5", "enabled": false }
}
JSON

fail=0
err="$tmp/stderr.log"
out=$(bash "$RENDER" "$tmp/hardware.json" "$TEMPLATE" 2>"$err") || {
    echo "  [MISS] render exited non-zero"
    fail=1
}

# 1. No jq error on stderr (the regression printed to stderr but exited 0,
#    so an exit-code check alone would miss it).
if [[ -s "$err" ]]; then
    echo "  [MISS] render wrote to stderr:"
    sed 's/^/         /' "$err"
    fail=1
else
    echo "  [OK]   render produced no stderr output"
fi

# 2. The enabled serial device is listed in the [Service] SERIAL DEVICES
#    block as SIGNALK_SERIAL_DEVICES, and NOT as an AddDevice= line: Quadlet
#    bakes AddDevice= into ExecStart, and podman fails the start (exit 125)
#    when that path is missing at that start (issue #309). The rendered unit
#    must also carry the PodmanArgs= line that hands the ExecStartPre's
#    arguments to podman.
serial_block() { sed -n '/^# === BEGIN SERIAL DEVICES/,/^# === END SERIAL DEVICES/p'; }
if serial_block <<<"$out" | grep -qxF "Environment=\"SIGNALK_SERIAL_DEVICES=$serial_byid\""; then
    echo "  [OK]   enabled serial device listed in SIGNALK_SERIAL_DEVICES"
else
    echo "  [MISS] enabled serial device missing from the SERIAL DEVICES block"
    serial_block <<<"$out" | sed 's/^/         /'
    fail=1
fi
if grep -qF "AddDevice=$serial_byid" <<<"$out"; then
    echo "  [MISS] serial device rendered as AddDevice= (a node missing at start fails it, exit 125)"
    fail=1
else
    echo "  [OK]   no AddDevice= line for the serial device"
fi
# shellcheck disable=SC2016 # the literal unit-file line, $ included
if grep -qxF 'PodmanArgs=$SIGNALK_DEVICE_ARGS' <<<"$out"; then
    echo "  [OK]   PodmanArgs= passes the start-time device arguments"
else
    echo "  [MISS] PodmanArgs=\$SIGNALK_DEVICE_ARGS missing from the rendered unit"
    fail=1
fi

# 3. Disabled hardware is excluded. BLE renders as the proxy's named
#    socket volume (signalk-dbus-socket), never a direct /run/dbus bind
#    mount — both patterns must stay absent while disabled.
# Comments are stripped first: a leak is a DIRECTIVE, and the template is
# heavily commented -- a comment that merely mentions /dev/snd while explaining
# something else is not hardware leaking into the render. Grepping the raw
# output made this assertion fire on documentation.
if grep -vE '^[[:space:]]*#' <<<"$out" \
    | grep -qE 'can0|/run/dbus|signalk-dbus-socket|Volume=/dev/gpio|SIGNALK_GPIO=|/dev/snd|/dev/input'; then
    echo "  [MISS] disabled hardware leaked into output"
    fail=1
else
    echo "  [OK]   disabled CAN/BLE/GPIO/audio/input correctly excluded"
fi

# 4. Enabled bluetooth must render the auth-proxy's named socket volume.
#    A direct /run/dbus bind mount would regress the userns fix: D-Bus
#    EXTERNAL auth can never complete from the rootless container on
#    hosts whose user isn't uid 1000, so the legacy line coming back
#    means BLE silently breaks for exactly the installs that need the
#    proxy. stderr is captured like check #1 — the original regression
#    printed jq errors on stderr while exiting 0.
if command -v jq >/dev/null 2>&1; then
    jq '.bluetooth.enabled = true' "$tmp/hardware.json" >"$tmp/hardware-ble.json"
    err_ble="$tmp/stderr-ble.log"
    out_ble=$(bash "$RENDER" "$tmp/hardware-ble.json" "$TEMPLATE" 2>"$err_ble") || {
        echo "  [MISS] render (bluetooth enabled) exited non-zero"
        fail=1
    }
    if [[ -s "$err_ble" ]]; then
        echo "  [MISS] render (bluetooth enabled) wrote to stderr:"
        sed 's/^/         /' "$err_ble"
        fail=1
    fi
    if grep -qxF 'Volume=signalk-dbus-socket:/run/dbus:rw' <<<"$out_ble"; then
        echo "  [OK]   enabled bluetooth emits the proxy socket volume"
    else
        echo "  [MISS] enabled bluetooth did not emit the proxy socket volume"
        fail=1
    fi
    if grep -qE '^Volume=/run/dbus:/run/dbus' <<<"$out_ble"; then
        echo "  [MISS] legacy direct /run/dbus bind mount re-appeared"
        fail=1
    else
        echo "  [OK]   no legacy direct /run/dbus bind mount"
    fi
else
    echo "  [SKIP] jq not available — enabled-bluetooth render not checked"
fi

# 4b. An enabled CAN interface renders NO line. SocketCAN interfaces are
#     network devices with no /dev node, reachable through Network=host; the
#     AddDevice=/dev/can0 this used to emit made podman fail every start of
#     the server (`stat /dev/can0: no such file or directory`, exit 125).
jq '.can = [{"interface":"can0","type":"socketcan","enabled":true}]' \
    "$tmp/hardware.json" >"$tmp/hardware-can.json"
out_can=$(bash "$RENDER" "$tmp/hardware-can.json" "$TEMPLATE" 2>/dev/null) || {
    echo "  [MISS] render (CAN enabled) exited non-zero"
    fail=1
}
if grep -vE '^[[:space:]]*#' <<<"$out_can" | grep -q 'can0'; then
    echo "  [MISS] enabled CAN interface rendered a line (podman would fail on /dev/can0):"
    grep -n 'can0' <<<"$out_can" | sed 's/^/         /'
    fail=1
else
    echo "  [OK]   enabled CAN interface renders no AddDevice= line"
fi

# 4c. Enabled GPIO renders one flag into the SERIAL DEVICES block and no
#     Volume= line: the nodes differ between a Pi 4 and a Pi 5 and change
#     with a kernel update, so the start script picks them (case 7). Only
#     the boolean true enables it, and a .gpio that is not an object is
#     ignored without a jq error.
jq '.gpio = {platform:"rpi5", enabled:true}' "$tmp/hardware.json" >"$tmp/hardware-gpio.json"
err_gpio="$tmp/stderr-gpio.log"
out_gpio=$(bash "$RENDER" "$tmp/hardware-gpio.json" "$TEMPLATE" 2>"$err_gpio") || {
    echo "  [MISS] render (gpio enabled) exited non-zero"
    fail=1
}
if [[ -s "$err_gpio" ]]; then
    echo "  [MISS] render (gpio enabled) wrote to stderr:"
    sed 's/^/         /' "$err_gpio"
    fail=1
fi
if serial_block <<<"$out_gpio" | grep -qxF 'Environment="SIGNALK_GPIO=1"'; then
    echo "  [OK]   enabled GPIO sets SIGNALK_GPIO=1 in the SERIAL DEVICES block"
else
    echo "  [MISS] enabled GPIO did not set SIGNALK_GPIO=1:"
    serial_block <<<"$out_gpio" | sed 's/^/         /'
    fail=1
fi
if grep -q '^Volume=[^:]*gpio' <<<"$out_gpio"; then
    echo "  [MISS] enabled GPIO rendered a Volume= line (fails the unit when the node is missing)"
    fail=1
else
    echo "  [OK]   enabled GPIO renders no Volume= line"
fi
for odd in '{platform:"rpi5", enabled:"true"}' '"on"'; do
    jq ".gpio = $odd" "$tmp/hardware.json" >"$tmp/hardware-gpio-odd.json"
    out_odd=$(bash "$RENDER" "$tmp/hardware-gpio-odd.json" "$TEMPLATE" 2>"$tmp/stderr-gpio-odd.log") || true
    if grep -qxF 'Environment="SIGNALK_GPIO=1"' <<<"$out_odd" || [[ -s "$tmp/stderr-gpio-odd.log" ]]; then
        echo "  [MISS] .gpio = $odd enabled GPIO or wrote to stderr"
        fail=1
    else
        echo "  [OK]   .gpio = $odd leaves GPIO off, quietly"
    fi
done

# 5. Enabled audio renders the read-only /dev/snd view — but only while the
#    host path exists: a Volume= with a missing source fails the whole unit
#    at start, so a stale enabled=true must render nothing rather than brick
#    the server. AUDIO_DIR points the probe at controlled paths so the test
#    is deterministic on hosts and CI runners with or without sound cards.
jq '.audio.enabled = true' "$tmp/hardware.json" >"$tmp/hardware-audio.json"
err_audio="$tmp/stderr-audio.log"
out_audio=$(AUDIO_DIR="$tmp" bash "$RENDER" "$tmp/hardware-audio.json" "$TEMPLATE" 2>"$err_audio") || {
    echo "  [MISS] render (audio enabled) exited non-zero"
    fail=1
}
if [[ -s "$err_audio" ]]; then
    echo "  [MISS] render (audio enabled) wrote to stderr:"
    sed 's/^/         /' "$err_audio"
    fail=1
fi
if grep -qxF "Volume=$tmp:/dev/snd:ro" <<<"$out_audio"; then
    echo "  [OK]   enabled audio emits the read-only /dev/snd view"
else
    echo "  [MISS] enabled audio did not emit the /dev/snd volume"
    fail=1
fi
err_audio_missing="$tmp/stderr-audio-missing.log"
out_audio_missing=$(AUDIO_DIR="$tmp/no-such-dir" bash "$RENDER" "$tmp/hardware-audio.json" "$TEMPLATE" 2>"$err_audio_missing") || {
    echo "  [MISS] render (audio enabled, path missing) exited non-zero"
    fail=1
}
if [[ -s "$err_audio_missing" ]]; then
    echo "  [MISS] render (audio enabled, path missing) wrote to stderr:"
    sed 's/^/         /' "$err_audio_missing"
    fail=1
fi
if grep -q ':/dev/snd:ro' <<<"$out_audio_missing"; then
    echo "  [MISS] audio volume rendered although the host path is missing"
    fail=1
else
    echo "  [OK]   missing host path suppresses the audio volume"
fi

# 5b. Enabled input renders the read-only /dev/input view, under the same
#     existence guard as audio: a Volume= whose source is missing fails the
#     unit at start, so a stale enabled=true on a host that lost its input
#     devices must render nothing rather than brick the server.
jq '.input.enabled = true' "$tmp/hardware.json" >"$tmp/hardware-input.json"
err_input="$tmp/stderr-input.log"
out_input=$(INPUT_DIR="$tmp" bash "$RENDER" "$tmp/hardware-input.json" "$TEMPLATE" 2>"$err_input") || {
    echo "  [MISS] render (input enabled) exited non-zero"
    fail=1
}
if [[ -s "$err_input" ]]; then
    echo "  [MISS] render (input enabled) wrote to stderr:"
    sed 's/^/         /' "$err_input"
    fail=1
fi
if grep -qxF "Volume=$tmp:/dev/input:ro" <<<"$out_input"; then
    echo "  [OK]   enabled input emits the read-only /dev/input view"
else
    echo "  [MISS] enabled input did not emit the /dev/input volume"
    fail=1
fi
# The view must never be writable. Note :ro governs the MOUNT (no node
# creation/removal), not open() on a node -- readability is decided by the
# `input` group, which install.sh deliberately does not grant. Verified:
# with keep-groups and the owning group, a :ro bind still opens for read.
# Check EVERY /dev/input line, not just that a good one exists: a writable
# mount emitted ALONGSIDE the read-only one would satisfy a presence test
# while still handing the container an openable node.
input_vol_bad=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "Volume=$tmp:/dev/input:ro" ]] && continue
    echo "  [MISS] unexpected /dev/input volume line: $line"
    input_vol_bad=1
done < <(grep -E '^Volume=[^:]*:/dev/input(:|$)' <<<"$out_input" || true)
if (( input_vol_bad )); then
    fail=1
fi
err_input_missing="$tmp/stderr-input-missing.log"
out_input_missing=$(INPUT_DIR="$tmp/no-such-dir" bash "$RENDER" "$tmp/hardware-input.json" "$TEMPLATE" 2>"$err_input_missing") || {
    echo "  [MISS] render (input enabled, path missing) exited non-zero"
    fail=1
}
if [[ -s "$err_input_missing" ]]; then
    echo "  [MISS] render (input enabled, path missing) wrote to stderr:"
    sed 's/^/         /' "$err_input_missing"
    fail=1
fi
if grep -q ':/dev/input:ro' <<<"$out_input_missing"; then
    echo "  [MISS] input volume rendered although the host path is missing"
    fail=1
else
    echo "  [OK]   missing host path suppresses the input volume"
fi

# 5c. install.sh must NOT put the operator in the `input` group. GroupAdd=
#     keep-groups is server-wide, so that membership would turn the read-only
#     /dev/input view into readable event nodes -- every keystroke on the host.
#     The probe needs only readdir+stat, which work without the group.
#     Matched over the group-management patterns we know -- a `for g in ...`
#     list, usermod, gpasswd, adduser, groupadd, a GROUPS array -- rather than
#     one line format, so reformatting the loop cannot silently retire the
#     guard. Comments are stripped first: this file and install.sh both DISCUSS
#     the input group at length, and the guard is about code, not prose.
#
#     This is a REGRESSION guard over known shapes, not a proof of absence: an
#     obfuscated or indirect grant would evade it. What actually enforces the
#     outcome is the render-time `id -nG` check in 5c-bis below, which holds
#     regardless of how the membership was acquired.
#     Backslash continuations are joined first, so splitting the group list
#     across lines does not hide the grant from the keyword match.
input_grant=$(sed 's/#.*//' installer/linux/install.sh \
    | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' \
    | grep -nE "(^|[^-[:alnum:]_])input([^-[:alnum:]_]|$)" \
    | grep -E 'for g in|usermod|groupadd|GROUPS|gpasswd|adduser' || true)
if [[ -n "$input_grant" ]]; then
    echo "  [MISS] install.sh appears to grant the input group:"
    printf '%s\n' "$input_grant" | sed 's/^/         /'
    fail=1
else
    echo "  [OK]   install.sh does not grant the input group"
fi

# 5c-bis. A user who ALREADY holds the host `input` group must not get the
#     mount. GroupAdd=keep-groups carries every supplementary host group
#     whoever granted it, and :ro restricts the mount rather than open() on a
#     node, so rendering the view for such a user hands signalk-server
#     readable event nodes. install.sh never adds `input`, but a desktop
#     distro or a local admin may have -- and this renderer also runs on hosts
#     the installer did not set up, so the source scan in 5c cannot cover it.
out_input_grp=$(INPUT_GROUP_OVERRIDE=yes INPUT_DIR="$tmp" bash "$RENDER" \
    "$tmp/hardware-input.json" "$TEMPLATE" 2>"$tmp/stderr-input-grp.log") || {
    echo "  [MISS] render (input enabled, user in group) exited non-zero"
    fail=1
}
if [[ -s "$tmp/stderr-input-grp.log" ]]; then
    echo "  [MISS] render (input enabled, user in group) wrote to stderr:"
    sed 's/^/         /' "$tmp/stderr-input-grp.log"
    fail=1
fi
if grep -qE '^Volume=[^:]*:/dev/input(:|$)' <<<"$out_input_grp"; then
    echo "  [MISS] /dev/input mounted for a user already in the input group"
    fail=1
else
    echo "  [OK]   input-group membership suppresses the /dev/input view"
fi
# The skip must be explained in the unit, not silent -- an operator who loses
# the view needs to know why and how to restore it.
if grep -q 'input.*group' <<<"$out_input_grp"; then
    echo "  [OK]   suppressed view is explained in the rendered unit"
else
    echo "  [MISS] view suppressed with no explanation in the unit"
    fail=1
fi

# 6. An enabled serial device whose node is absent at RENDER time is still
#    listed: the ExecStartPre decides at each start, so a device that comes
#    back is passed without a re-render. A disabled device is not listed, and
#    a path with characters the unit file would mangle is named in a comment
#    in the block instead of being listed.
missing_byid="$serialdir/usb-GONE_ADAPTER-if00-port0"
off_byid="$serialdir/usb-OFF_ADAPTER-if00-port0"
odd_byid="$serialdir/usb-ODD ADAPTER-if00"
cat >"$tmp/hardware-serial-missing.json" <<JSON
{
  "detectedAt": "2026-01-01T00:00:00Z",
  "serial": [
    {"byId":"$serial_byid","vendor":"FTDI","product":"UART","enabled":true},
    {"byId":"$missing_byid","vendor":"GONE","product":"UART","enabled":true},
    {"byId":"$off_byid","vendor":"OFF","product":"UART","enabled":false},
    {"byId":"$odd_byid","vendor":"ODD","product":"UART","enabled":true}
  ],
  "can": [],
  "bluetooth": { "dbusAvailable": false, "enabled": false },
  "audio": { "present": false, "enabled": false },
  "gpio": { "platform": "none", "enabled": false }
}
JSON
err_missing="$tmp/stderr-serial-missing.log"
out_missing=$(bash "$RENDER" "$tmp/hardware-serial-missing.json" "$TEMPLATE" 2>"$err_missing") || {
    echo "  [MISS] render (serial node missing) exited non-zero"
    fail=1
}
if [[ -s "$err_missing" ]]; then
    echo "  [MISS] render (serial node missing) wrote to stderr:"
    sed 's/^/         /' "$err_missing"
    fail=1
fi
if serial_block <<<"$out_missing" \
    | grep -qxF "Environment=\"SIGNALK_SERIAL_DEVICES=$serial_byid $missing_byid\""; then
    echo "  [OK]   absent device listed with the present one; disabled and odd paths left out"
else
    echo "  [MISS] SIGNALK_SERIAL_DEVICES does not list exactly the enabled, well-formed devices:"
    serial_block <<<"$out_missing" | sed 's/^/         /'
    fail=1
fi
if serial_block <<<"$out_missing" \
    | grep -qxF "# serial device not passed (unsupported characters): $odd_byid"; then
    echo "  [OK]   a path with a space is named in a comment, not listed"
else
    echo "  [MISS] no comment naming the path that was not passed"
    fail=1
fi

# 7. The template's ExecStartPre, run as systemd hands it to the shell:
#    continuation lines joined, $$ -> $, %t -> a temp dir. It must write
#    --device arguments only for devices that exist now, in BOTH forms for a
#    by-id symlink, and the pair is the point:
#
#      mapped (<by-id>:<by-id>)  the stable name, so two USB serial devices
#                                cannot swap on reboot and have SignalK read
#                                the wrong one
#      bare   (<by-id>)          podman resolves it to /dev/ttyUSB0, which is
#                                what the SignalK UI offers and what every
#                                existing config already says
#
#    Publishing only the mapped form replaces "permission denied" with "No
#    such file or directory" for anyone with an existing config -- a different
#    error, not a fixed install. That regression was shipped once and caught
#    on a live boat. A plain node (an onboard UART) is passed once. An absent
#    device is left out and named on stderr (the unit's journal), a stale file
#    from an earlier start is replaced, and a device that appears during the
#    wait is passed.
pre_line=$(awk '/^ExecStartPre=\/bin\/sh -c .f=%t\/signalk-server-devices\.env/ { grab = 1 }
    grab { if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; exit }' "$TEMPLATE")
pre_script=${pre_line#"ExecStartPre=/bin/sh -c '"}
pre_script=${pre_script%"'"}
pre_script=${pre_script//\$\$/\$}
rt="$tmp/run"
pre_script=${pre_script//%t/$rt}
devs="$tmp/devs"
mkdir -p "$rt" "$devs"
link="$devs/usb-LINK_TEST-if00"
node="$devs/ttyAMA4"
absent="$devs/usb-ABSENT_TEST-if00"
ln -s /dev/null "$link"
: >"$node"
env_file="$rt/signalk-server-devices.env"
if [[ -z "$pre_line" || "$pre_script" == "$pre_line" ]]; then
    echo "  [MISS] could not extract the device ExecStartPre from $TEMPLATE (changed?)"
    fail=1
else
    echo "SIGNALK_DEVICE_ARGS=--device /stale/from/an/earlier/start" >"$env_file"
    pre_rc=0
    SIGNALK_SERIAL_DEVICES="$link $node $absent" SIGNALK_DEVICE_WAIT=0 \
        sh -c "$pre_script" 2>"$tmp/pre.err" || pre_rc=$?
    want="SIGNALK_DEVICE_ARGS= --device $link:$link --device $link --device $node"
    if [[ "$pre_rc" -eq 0 && "$(cat "$env_file")" == "$want" ]]; then
        echo "  [OK]   start script passes the by-id link in both forms and the node once"
    else
        echo "  [MISS] start script (rc=$pre_rc) wrote:"
        sed 's/^/         /' "$env_file"
        echo "         expected: $want"
        fail=1
    fi
    if grep -qF "starting without absent serial device(s): $absent" "$tmp/pre.err"; then
        echo "  [OK]   the absent device is named on stderr"
    else
        echo "  [MISS] the absent device is not named on stderr:"
        sed 's/^/         /' "$tmp/pre.err"
        fail=1
    fi
    (sleep 1; ln -s /dev/null "$absent") &
    SIGNALK_SERIAL_DEVICES="$absent" SIGNALK_DEVICE_WAIT=5 sh -c "$pre_script" 2>/dev/null || true
    wait
    if [[ "$(cat "$env_file")" == "SIGNALK_DEVICE_ARGS= --device $absent:$absent --device $absent" ]]; then
        echo "  [OK]   a device that appears during the wait is passed"
    else
        echo "  [MISS] the device that appeared during the wait was not passed:"
        sed 's/^/         /' "$env_file"
        fail=1
    fi
    SIGNALK_SERIAL_DEVICES="" sh -c "$pre_script" 2>"$tmp/pre-empty.err" || true
    if [[ "$(cat "$env_file")" == "SIGNALK_DEVICE_ARGS=" && ! -s "$tmp/pre-empty.err" ]]; then
        echo "  [OK]   no serial devices: empty arguments, nothing logged"
    else
        echo "  [MISS] empty device list did not give empty arguments"
        fail=1
    fi
fi

# 7b. With SIGNALK_GPIO=1 the same start script passes each GPIO node present
#     at this start, once, and none without the flag. The script's /dev/gpio
#     paths are pointed at a fixture laid out like a Pi 5 (gpiomem0..1 and
#     gpiochip0, no plain gpiomem), then like a Pi 4 (gpiomem, gpiochip0..1).
if [[ -n "${pre_script:-}" ]]; then
    gdev="$tmp/gpiodev"
    gpio_script=${pre_script//\/dev\/gpio/$gdev\/gpio}
    mkdir -p "$gdev"
    : >"$gdev/gpiomem0"; : >"$gdev/gpiomem1"; : >"$gdev/gpiochip0"
    SIGNALK_SERIAL_DEVICES="" SIGNALK_GPIO=1 sh -c "$gpio_script" 2>/dev/null || true
    want="SIGNALK_DEVICE_ARGS= --device $gdev/gpiomem0 --device $gdev/gpiomem1 --device $gdev/gpiochip0"
    if [[ "$(cat "$env_file")" == "$want" ]]; then
        echo "  [OK]   Pi 5 layout: gpiomem0..N and gpiochip* passed, no plain gpiomem"
    else
        echo "  [MISS] Pi 5 layout wrote:"
        sed 's/^/         /' "$env_file"
        echo "         expected: $want"
        fail=1
    fi
    rm -f "$gdev"/*
    : >"$gdev/gpiomem"; : >"$gdev/gpiochip0"; : >"$gdev/gpiochip1"
    SIGNALK_SERIAL_DEVICES="$node" SIGNALK_GPIO=1 sh -c "$gpio_script" 2>/dev/null || true
    want="SIGNALK_DEVICE_ARGS= --device $node --device $gdev/gpiomem --device $gdev/gpiochip0 --device $gdev/gpiochip1"
    if [[ "$(cat "$env_file")" == "$want" ]]; then
        echo "  [OK]   Pi 4 layout: gpiomem and every gpiochip passed after the serial device"
    else
        echo "  [MISS] Pi 4 layout wrote:"
        sed 's/^/         /' "$env_file"
        echo "         expected: $want"
        fail=1
    fi
    SIGNALK_SERIAL_DEVICES="" sh -c "$gpio_script" 2>/dev/null || true
    if [[ "$(cat "$env_file")" == "SIGNALK_DEVICE_ARGS=" ]]; then
        echo "  [OK]   without SIGNALK_GPIO no GPIO node is passed"
    else
        echo "  [MISS] GPIO nodes passed without SIGNALK_GPIO:"
        sed 's/^/         /' "$env_file"
        fail=1
    fi
    rm -f "$gdev"/*
    SIGNALK_SERIAL_DEVICES="" SIGNALK_GPIO=1 sh -c "$gpio_script" 2>"$tmp/pre-gpio.err" || true
    if [[ "$(cat "$env_file")" == "SIGNALK_DEVICE_ARGS=" && ! -s "$tmp/pre-gpio.err" ]]; then
        echo "  [OK]   SIGNALK_GPIO=1 with no GPIO node: empty arguments, nothing logged"
    else
        echo "  [MISS] SIGNALK_GPIO=1 with no node did not give empty arguments"
        fail=1
    fi
fi

# 8a. A template whose device ExecStartPre does not read SIGNALK_GPIO must
#     make the render fail while GPIO is enabled, and still render without.
nogpio_template="$tmp/nogpio.template"
sed '/if \[ "\$\${SIGNALK_GPIO/,/^ *fi; *\\$/d' "$TEMPLATE" >"$nogpio_template"
if grep -q '^[^#]*SIGNALK_GPIO' "$nogpio_template"; then
    echo "  [MISS] could not strip the GPIO handling from the template for this test"
    fail=1
fi
jq '.gpio = {"enabled": true, "platform": "rpi5"}' "$tmp/hardware.json" >"$tmp/hardware-gpio-old.json"
if bash "$RENDER" "$tmp/hardware-gpio-old.json" "$nogpio_template" >/dev/null 2>&1; then
    echo "  [MISS] render against a template without GPIO handling succeeded with GPIO enabled"
    fail=1
else
    echo "  [OK]   render refuses a template without GPIO handling while GPIO is enabled"
fi
jq '.gpio = {"enabled": false}' "$tmp/hardware.json" >"$tmp/hardware-gpio-off.json"
if bash "$RENDER" "$tmp/hardware-gpio-off.json" "$nogpio_template" >/dev/null 2>&1; then
    echo "  [OK]   the same template renders when GPIO is off"
else
    echo "  [MISS] render failed on the template without GPIO handling with GPIO off"
    fail=1
fi

# 8. A template without the SERIAL DEVICES block (from before #309) must make
#    the render fail while serial devices are enabled: its ExecStart would
#    not read the list, so rendering would drop every serial device silently.
#    Without serial devices the old template still renders.
old_template="$tmp/old.template"
sed '/^# === BEGIN SERIAL DEVICES/,/^# === END SERIAL DEVICES/d' "$TEMPLATE" >"$old_template"
if bash "$RENDER" "$tmp/hardware.json" "$old_template" >/dev/null 2>"$tmp/old.err"; then
    echo "  [MISS] render against a template without SERIAL DEVICES succeeded with a serial device enabled"
    fail=1
else
    echo "  [OK]   render refuses a template without SERIAL DEVICES while a serial device is enabled"
fi
jq '.serial = []' "$tmp/hardware.json" >"$tmp/hardware-noserial.json"
if bash "$RENDER" "$tmp/hardware-noserial.json" "$old_template" >/dev/null 2>&1; then
    echo "  [OK]   the same template renders when no serial device is enabled"
else
    echo "  [MISS] render failed on the old template with no serial devices"
    fail=1
fi

# 9. HALPI2 classes (docs/halpi2.md). An enabled `onboardSerial` device is
#    listed in SIGNALK_SERIAL_DEVICES after the USB serial devices, present
#    or not, like USB serial; a disabled one is not. The halpid socket
#    directory is mounted only when board.model is halpi2 AND the socket
#    exists at render time (HALPID_RUN_DIR points the probe at the fixture).
#    A fixture without `board` must render exactly as before.
mkdir -p "$tmp/tty" "$tmp/halpid"
: >"$tmp/tty/ttyAMA4"
# A unix socket node for the existence guard. Bash cannot create one; use
# python3, else perl (both ship on ubuntu-latest and Debian). No socket →
# the volume-present assertion below fails rather than skipping.
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$tmp/halpid/halpid.sock" || true
elif command -v perl >/dev/null 2>&1; then
    perl -MSocket -e 'socket(S, PF_UNIX, SOCK_STREAM, 0) and bind(S, sockaddr_un($ARGV[0])) or die' "$tmp/halpid/halpid.sock" || true
fi
jq --arg dev "$tmp/tty/ttyAMA4" --arg gone "$tmp/tty/ttyAMA9" '
    .board = {model:"halpi2", candidate:false, detectedVia:"i2c"}
    | .onboardSerial = [ {device:$dev, label:"HALPI2 RS-485", enabled:true},
                         {device:$gone, label:"absent", enabled:true},
                         {device:$dev, label:"disabled", enabled:false} ]
' "$tmp/hardware.json" >"$tmp/hardware-halpi2.json"
err_halpi2="$tmp/stderr-halpi2.log"
out_halpi2=$(HALPID_RUN_DIR="$tmp/halpid" bash "$RENDER" "$tmp/hardware-halpi2.json" "$TEMPLATE" 2>"$err_halpi2") || {
    echo "  [MISS] render (halpi2) exited non-zero"
    fail=1
}
if [[ -s "$err_halpi2" ]]; then
    echo "  [MISS] render (halpi2) wrote to stderr:"
    sed 's/^/         /' "$err_halpi2"
    fail=1
fi
if serial_block <<<"$out_halpi2" | grep -qxF \
    "Environment=\"SIGNALK_SERIAL_DEVICES=$serial_byid $tmp/tty/ttyAMA4 $tmp/tty/ttyAMA9\""; then
    echo "  [OK]   enabled onboardSerial devices listed once each, the disabled one not"
else
    echo "  [MISS] onboardSerial devices not listed as expected:"
    serial_block <<<"$out_halpi2" | sed 's/^/         /'
    fail=1
fi
if grep -q "AddDevice=$tmp/tty/" <<<"$out_halpi2"; then
    echo "  [MISS] onboardSerial rendered as AddDevice="
    fail=1
else
    echo "  [OK]   no AddDevice= line for onboardSerial"
fi
if [[ -S "$tmp/halpid/halpid.sock" ]]; then
    if grep -qxF "Volume=$tmp/halpid:/run/halpid:ro" <<<"$out_halpi2"; then
        echo "  [OK]   halpi2 board + live halpid socket mounts /run/halpid"
    else
        echo "  [MISS] halpid volume missing with board=halpi2 and a live socket"
        fail=1
    fi
else
    echo "  [MISS] could not create the halpid socket fixture (python3/perl missing or bind failed)"
    fail=1
fi
out_halpi2_nosock=$(HALPID_RUN_DIR="$tmp/no-such-dir" bash "$RENDER" "$tmp/hardware-halpi2.json" "$TEMPLATE" 2>/dev/null) || {
    echo "  [MISS] render (halpi2, socket missing) exited non-zero"
    fail=1
}
if grep -q ':/run/halpid:' <<<"$out_halpi2_nosock"; then
    echo "  [MISS] halpid volume rendered although the socket is missing"
    fail=1
else
    echo "  [OK]   missing halpid socket suppresses the volume"
fi
out_noboard=$(HALPID_RUN_DIR="$tmp/halpid" bash "$RENDER" "$tmp/hardware.json" "$TEMPLATE" 2>/dev/null) || {
    echo "  [MISS] render (no board) exited non-zero"
    fail=1
}
if grep -vE '^[[:space:]]*#' <<<"$out_noboard" | grep -q 'halpid\|ttyAMA'; then
    echo "  [MISS] fixture without board rendered HALPI2 lines"
    fail=1
else
    echo "  [OK]   fixture without board renders no HALPI2 lines"
fi

# 10. Without jq the renderer reads by-id paths with grep. It lists only an
#     object that holds "enabled":true on its own line: the disabled entry
#     and the entry spread over several lines are left out. PATH for this
#     render is a directory of links to every command on PATH except jq.
nojq_bin="$tmp/nojq-bin"
mkdir -p "$nojq_bin"
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    if [[ -d "$d" ]]; then
        # Names already linked from an earlier PATH entry fail; that is the
        # PATH order the render would see.
        ln -s "$d"/* "$nojq_bin"/ 2>/dev/null || true
    fi
done
rm -f "$nojq_bin/jq"
bash_bin=$(command -v bash)
cat >"$tmp/hardware-nojq.json" <<JSON
{
  "serial": [
    {"byId":"$serialdir/usb-ON-if00","vendor":"A","product":"B","enabled":true},
    {"byId":"$serialdir/usb-OFF-if00","vendor":"A","product":"B","enabled":false},
    {
      "byId": "$serialdir/usb-SPLIT-if00",
      "enabled": true
    }
  ],
  "can": []
}
JSON
if PATH="$nojq_bin" "$bash_bin" -c 'command -v jq' >/dev/null 2>&1; then
    echo "  [MISS] could not hide jq for the no-jq render"
    fail=1
else
    err_nojq="$tmp/stderr-nojq.log"
    out_nojq=$(PATH="$nojq_bin" "$bash_bin" "$RENDER" "$tmp/hardware-nojq.json" "$TEMPLATE" 2>"$err_nojq") || {
        echo "  [MISS] render (no jq) exited non-zero"
        fail=1
    }
    if [[ -s "$err_nojq" ]]; then
        echo "  [MISS] render (no jq) wrote to stderr:"
        sed 's/^/         /' "$err_nojq"
        fail=1
    fi
    if serial_block <<<"$out_nojq" | grep -qxF "Environment=\"SIGNALK_SERIAL_DEVICES=$serialdir/usb-ON-if00\""; then
        echo "  [OK]   without jq only the enabled one-line entry is listed"
    else
        echo "  [MISS] without jq the serial list is not the enabled one-line entry alone:"
        serial_block <<<"$out_nojq" | sed 's/^/         /'
        fail=1
    fi
fi

if (( fail )); then
    echo
    echo "[ERR] render-server-quadlet hardware block is broken — see entries above." >&2
    exit 1
fi
echo
echo "[OK] render-server-quadlet hardware block renders cleanly."
