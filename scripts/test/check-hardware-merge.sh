#!/usr/bin/env bash
# Pins the operator-toggle preservation contract of the hardware.json merge.
# detect-hardware.sh always re-emits fresh state — opt-in classes at
# enabled=false, audio at its present-derived default — and the installer
# merges the operator's prior toggles back over the fresh detection so a
# documented re-run (`curl … | bash`) can't silently flip passthrough back
# on/off.
#
# The merge filter under test is the SAME one install.sh runs: both source
# installer/linux/lib/hardware-merge.sh, so this test can't pass against a
# stale copy. Run from the repo root.

set -euo pipefail

MERGE_LIB=${MERGE_LIB:-installer/linux/lib/hardware-merge.sh}
if [[ ! -f "$MERGE_LIB" ]]; then
    echo "[ERR] $MERGE_LIB not found (run from repo root)" >&2
    exit 2
fi
# shellcheck disable=SC1090
. "$MERGE_LIB"

if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not available — hardware merge contract not checked"
    exit 0
fi

fail=0

# Production merge, sourced above. Aliased so the cases below read cleanly.
merge() { hardware_merge "$1" "$2"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check() {
    # $1 = label, $2 = jq filter, $3 = expected, run against $tmp/merged.json
    local got
    got=$(jq -r "$2" "$tmp/merged.json")
    if [[ "$got" == "$3" ]]; then
        echo "  [OK]   $1"
    else
        echo "  [MISS] $1 (got '$got', want '$3')"
        fail=1
    fi
}

# Fresh detection: audio present (enabled-by-default), opt-in classes off.
cat >"$tmp/fresh.json" <<'JSON'
{
  "serial": [],
  "can": [],
  "bluetooth": { "dbusAvailable": true, "enabled": false },
  "audio": { "present": true, "enabled": true },
  "gpio": { "platform": "rpi5", "enabled": false }
}
JSON

# Case 1: operator disabled audio previously → the false must survive.
cat >"$tmp/old.json" <<'JSON'
{
  "bluetooth": { "dbusAvailable": true, "enabled": true },
  "audio": { "present": true, "enabled": false },
  "gpio": { "platform": "rpi5", "enabled": true }
}
JSON
merge "$tmp/old.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "operator-disabled audio survives re-detect" '.audio.enabled' "false"
check "operator-enabled bluetooth survives re-detect" '.bluetooth.enabled' "true"
check "operator-enabled gpio survives re-detect" '.gpio.enabled' "true"

# Case 2: first merge on upgrade — old file has no audio key at all.
# audio must keep its freshly-detected enabled-by-default value, not go false.
cat >"$tmp/old-noaudio.json" <<'JSON'
{
  "bluetooth": { "dbusAvailable": true, "enabled": false },
  "gpio": { "platform": "none", "enabled": false }
}
JSON
merge "$tmp/old-noaudio.json" "$tmp/fresh.json" >"$tmp/merged.json"
check "audio default preserved when old file lacks audio key" '.audio.enabled' "true"

if (( fail )); then
    echo
    echo "[ERR] hardware.json merge contract broken — see entries above." >&2
    exit 1
fi
echo "[OK] hardware.json merge preserves operator toggles."
