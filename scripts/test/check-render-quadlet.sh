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

# Fixture mirroring the real detect-hardware.sh shape: an enabled serial
# device, plus disabled CAN/BLE/GPIO. The comma-list bug fired regardless of
# enabled state — having a present serial entry is enough to reproduce it.
cat >"$tmp/hardware.json" <<'JSON'
{
  "detectedAt": "2026-01-01T00:00:00Z",
  "serial": [
    {"byId":"/dev/serial/by-id/usb-FTDI_TEST-if00-port0","vendor":"FTDI","product":"UART","enabled":true}
  ],
  "can": [
    {"interface":"can0","enabled":false}
  ],
  "bluetooth": { "dbusAvailable": true, "enabled": false },
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

# 2. The enabled serial device is present.
if grep -qF 'AddDevice=/dev/serial/by-id/usb-FTDI_TEST-if00-port0' <<<"$out"; then
    echo "  [OK]   enabled serial device emitted"
else
    echo "  [MISS] enabled serial device missing from output"
    fail=1
fi

# 3. Disabled hardware is excluded. BLE renders as the proxy's named
#    socket volume (signalk-dbus-socket), never a direct /run/dbus bind
#    mount — both patterns must stay absent while disabled.
if grep -qE 'can0|/run/dbus|signalk-dbus-socket|/dev/gpiomem' <<<"$out"; then
    echo "  [MISS] disabled hardware leaked into output"
    fail=1
else
    echo "  [OK]   disabled CAN/BLE/GPIO correctly excluded"
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

if (( fail )); then
    echo
    echo "[ERR] render-server-quadlet hardware block is broken — see entries above." >&2
    exit 1
fi
echo
echo "[OK] render-server-quadlet hardware block renders cleanly."
