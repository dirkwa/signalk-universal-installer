#!/usr/bin/env bash
# Verifies the recipe `signalk socketcan` prints for a Pi CAN HAT.
#
# The helper writes nothing itself — it prints a recipe the operator
# pastes — so there is no file to inspect afterwards, as there is for
# `signalk halpi2 apply`. The recipe text IS the deliverable, and this
# checks the parts that are wrong-by-omission rather than wrong-by-typo:
#
#   1. RestartSec= is present, so a BUS-OFF controller rejoins the bus.
#      Without it the kernel leaves restart-ms at 0 and a bus-error burst
#      takes CAN down until someone resets the link by hand.
#   2. The bitrate is NMEA 2000's 250000.
#
# Run from the repo root.

set -euo pipefail

TMPL="installer/linux/signalk-socketcan.tmpl"
[ -f "$TMPL" ] || { echo "run from the repo root ($TMPL not found)"; exit 1; }

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
miss() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cli="$work/signalk-socketcan"
sed 's|@@DOC_URL@@|https://example.invalid/socketcan|g' "$TMPL" > "$cli"
chmod +x "$cli"

# Answer the adapter prompt with "5" (USB CAN, SocketCAN-native). The
# Pi-HAT options are offered only on a Pi, but USB-CAN applies on any
# host, so this runs the same on a CI runner as on the target hardware —
# and it emits the same networkd recipe. HOME is redirected so the
# hardware.json write lands in the temp dir, not the real one.
recipe=$(printf '5\n' | HOME="$work" "$cli" 2>&1 || true)

if printf '%s' "$recipe" | grep -q "80-signalk-can0.network"; then
    ok "recipe emits the networkd file"
else
    miss "recipe does not emit 80-signalk-can0.network — did the CLI interface change?"
    printf '%s\n' "$recipe" | sed -n '1,15p'
    exit 1
fi

# The exact value, not just the key: a regression to a multi-second
# delay would still "set RestartSec" while leaving CAN down long enough
# to drop data, and the HALPI2 path this mirrors writes 100ms.
if printf '%s' "$recipe" | grep -qE '^ *RestartSec=100ms *$'; then
    ok "recipe sets RestartSec=100ms (BUS-OFF recovery)"
else
    miss "recipe does not set RestartSec=100ms: a BUS-OFF controller would not rejoin promptly"
fi

if printf '%s' "$recipe" | grep -qE '^ *BitRate=250000'; then
    ok "recipe sets the NMEA 2000 bitrate"
else
    miss "recipe does not set BitRate=250000"
fi

if [ "$fails" -eq 0 ]; then
    echo "check-socketcan-recipe: all checks passed"
else
    echo "check-socketcan-recipe: $fails check(s) failed"
    exit 1
fi
