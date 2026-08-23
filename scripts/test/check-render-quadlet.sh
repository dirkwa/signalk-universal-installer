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
# (2) the enabled device appears, (3) disabled devices do not. Requires jq.
# Run from the repo root.

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

# Serial devices are existence-guarded at render time (a missing device node
# would fail container creation with exit 125), so the fixture's by-id path
# must actually exist for the "emitted" assertions to hold. Point SERIAL_DIR
# at a temp dir and create the node there; the fixture byId lives under it.
# All render invocations below inherit this export.
serialdir="$tmp/serial-by-id"
mkdir -p "$serialdir"
serial_byid="$serialdir/usb-FTDI_TEST-if00-port0"
: >"$serial_byid"
export SERIAL_DIR="$serialdir"

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

# 2. The enabled serial device is present (its node exists under SERIAL_DIR).
# Each serial device must be emitted in BOTH forms, and the pair is the point.
#
#   mapped (<by-id>:<by-id>)  the stable name, so two USB serial devices cannot
#                             swap on reboot and have SignalK read the wrong one
#   bare   (<by-id>)          podman resolves it to /dev/ttyUSB0, which is what
#                             the SignalK UI offers and what every existing
#                             config already says
#
# Publishing only the mapped form replaces "permission denied" with "No such
# file or directory" for anyone with an existing config -- a different error,
# not a fixed install. That regression was shipped once and caught on a live
# boat; both assertions exist so it cannot be shipped again.
if grep -qF "AddDevice=${serial_byid}:${serial_byid}" <<<"$out"; then
    echo "  [OK]   serial device is mapped host:container (stable name inside)"
else
    echo "  [MISS] serial AddDevice= is not mapped to a stable in-container path"
    grep -F 'AddDevice=' <<<"$out" | sed 's/^/         /'
    fail=1
fi

if grep -qxF "AddDevice=${serial_byid}" <<<"$out"; then
    echo "  [OK]   serial device is also emitted bare (resolves to /dev/ttyUSB0)"
else
    echo "  [MISS] no bare AddDevice= — existing /dev/ttyUSB0 configs would break"
    grep -F 'AddDevice=' <<<"$out" | sed 's/^/         /'
    fail=1
fi

if grep -qF "AddDevice=$serial_byid" <<<"$out"; then
    echo "  [OK]   enabled serial device emitted"
else
    echo "  [MISS] enabled serial device missing from output"
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
    | grep -qE 'can0|/run/dbus|signalk-dbus-socket|/dev/gpiomem|/dev/snd|/dev/input'; then
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
if grep -qE '^Volume=[^:]+:/dev/input(:|$)' <<<"$out_input" \
    && ! grep -qxF "Volume=$tmp:/dev/input:ro" <<<"$out_input"; then
    echo "  [MISS] /dev/input rendered without the :ro flag"
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
if grep -qE '^for g in .*\binput\b.*; do' installer/linux/install.sh; then
    echo "  [MISS] install.sh adds the operator to the input group"
    fail=1
else
    echo "  [OK]   install.sh does not grant the input group"
fi

# 6. Serial existence guard: an enabled serial device whose node has vanished
#    between detect and render (unplugged / re-enumerating flaky ACM adapter)
#    must be DROPPED, not emitted. An AddDevice= pointing at a missing node
#    fails container creation with exit 125 and crashloops the whole server,
#    so one absent optional serial device must never brick it. Fixture: a
#    second by-id path under SERIAL_DIR that we never create.
missing_byid="$serialdir/usb-GONE_ADAPTER-if00-port0"
# The absent device is listed LAST so the guard's final loop iteration is a
# skip — the shape that trips the exit-status trap checked directly in case 7.
cat >"$tmp/hardware-serial-missing.json" <<JSON
{
  "detectedAt": "2026-01-01T00:00:00Z",
  "serial": [
    {"byId":"$serial_byid","vendor":"FTDI","product":"UART","enabled":true},
    {"byId":"$missing_byid","vendor":"GONE","product":"UART","enabled":true}
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
if grep -qF "AddDevice=$missing_byid" <<<"$out_missing"; then
    echo "  [MISS] absent serial device leaked into output (would crashloop the server, exit 125)"
    fail=1
else
    echo "  [OK]   absent serial device dropped (server not bricked)"
fi
# The present device must still survive the same render — the guard drops only
# the missing one, never the whole serial class.
if grep -qF "AddDevice=$serial_byid" <<<"$out_missing"; then
    echo "  [OK]   present serial device kept alongside the dropped one"
else
    echo "  [MISS] guard dropped the present serial device too"
    fail=1
fi

# 7. guard_adddevice must EXIT 0 when its last action is skipping an absent
#    device. It runs as `... | guard_adddevice` under set -euo pipefail; a
#    short-circuited `[ -e ] && printf` leaves the function at status 1 on a
#    trailing skip, failing the pipeline. (The renderer's own call site happens
#    to mask this — hardware_block runs inside a command substitution where
#    set -e doesn't propagate — so this asserts the function contract directly,
#    the level where the trap actually bites and a refactor would expose it.)
guard_fn="$tmp/guard.sh"
# Extract the guard_adddevice function definition from the renderer verbatim.
sed -n '/^guard_adddevice() {/,/^}/p' "$RENDER" >"$guard_fn"
if ! grep -q '^guard_adddevice() {' "$guard_fn"; then
    echo "  [MISS] could not extract guard_adddevice from $RENDER (renamed?)"
    fail=1
else
    guard_rc=0
    SERIAL_DIR="$serialdir" bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        . "'"$guard_fn"'"
        # Present line, then an absent one LAST — the failing shape.
        printf "AddDevice=%s\nAddDevice=%s\n" "'"$serial_byid"'" "'"$missing_byid"'" \
            | guard_adddevice >/dev/null
    ' || guard_rc=$?
    if [[ "$guard_rc" -eq 0 ]]; then
        echo "  [OK]   guard_adddevice exits 0 after a trailing skip (no set -e abort)"
    else
        echo "  [MISS] guard_adddevice exited $guard_rc on a trailing skip — would abort rendering under set -e"
        fail=1
    fi
fi

# 7. HALPI2 classes (docs/halpi2.md). `onboardSerial` renders a single
#    AddDevice=<device> line, existence-guarded like USB serial (TTY_PREFIX
#    points the guard at the fixture tree); the halpid socket directory is
#    mounted only when board.model is halpi2 AND the socket exists at render
#    time (HALPID_RUN_DIR points the probe at the fixture). A fixture without
#    `board` must render exactly as before.
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
out_halpi2=$(TTY_PREFIX="$tmp/tty/" HALPID_RUN_DIR="$tmp/halpid" bash "$RENDER" "$tmp/hardware-halpi2.json" "$TEMPLATE" 2>"$err_halpi2") || {
    echo "  [MISS] render (halpi2) exited non-zero"
    fail=1
}
if [[ -s "$err_halpi2" ]]; then
    echo "  [MISS] render (halpi2) wrote to stderr:"
    sed 's/^/         /' "$err_halpi2"
    fail=1
fi
if [[ "$(grep -cxF "AddDevice=$tmp/tty/ttyAMA4" <<<"$out_halpi2")" == 1 ]]; then
    echo "  [OK]   enabled onboardSerial emits one AddDevice line"
else
    echo "  [MISS] enabled onboardSerial AddDevice missing or duplicated"
    fail=1
fi
if grep -q "ttyAMA9" <<<"$out_halpi2"; then
    echo "  [MISS] absent onboardSerial node was not guarded out"
    fail=1
else
    echo "  [OK]   absent onboardSerial node is dropped by the existence guard"
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
out_halpi2_nosock=$(TTY_PREFIX="$tmp/tty/" HALPID_RUN_DIR="$tmp/no-such-dir" bash "$RENDER" "$tmp/hardware-halpi2.json" "$TEMPLATE" 2>/dev/null) || {
    echo "  [MISS] render (halpi2, socket missing) exited non-zero"
    fail=1
}
if grep -q ':/run/halpid:' <<<"$out_halpi2_nosock"; then
    echo "  [MISS] halpid volume rendered although the socket is missing"
    fail=1
else
    echo "  [OK]   missing halpid socket suppresses the volume"
fi
out_noboard=$(TTY_PREFIX="$tmp/tty/" HALPID_RUN_DIR="$tmp/halpid" bash "$RENDER" "$tmp/hardware.json" "$TEMPLATE" 2>/dev/null) || {
    echo "  [MISS] render (no board) exited non-zero"
    fail=1
}
if grep -vE '^[[:space:]]*#' <<<"$out_noboard" | grep -q 'halpid\|ttyAMA'; then
    echo "  [MISS] fixture without board rendered HALPI2 lines"
    fail=1
else
    echo "  [OK]   fixture without board renders no HALPI2 lines"
fi

if (( fail )); then
    echo
    echo "[ERR] render-server-quadlet hardware block is broken — see entries above." >&2
    exit 1
fi
echo
echo "[OK] render-server-quadlet hardware block renders cleanly."
