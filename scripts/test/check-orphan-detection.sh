#!/usr/bin/env bash
# Verifies preflight's orphan-container filter identifies unmanaged
# signalk-server containers without flagging the managed ones.
#
# Background: a misfired `podman run` (a 443-bind capability probe whose
# entrypoint booted a full signalk-server) left random-named containers
# running an OLD image on Network=host. They squatted signalk-server's port
# and served stale code, which looked like "my image changes aren't
# arriving." Nothing detected them: every installer `podman ps` filters
# `name=signalk-`, and these had random names. preflight now flags any
# running container on a signalk-server image whose name isn't one of the
# three Quadlet-managed containers.
#
# This sources preflight.sh (which defines _orphan_names_from_ps without
# running main) and feeds it fixture `Name|Image` lines. Run from repo root.

set -euo pipefail

PREFLIGHT=${PREFLIGHT:-installer/linux/preflight.sh}

if [[ ! -f "$PREFLIGHT" ]]; then
    echo "[ERR] $PREFLIGHT not found (run from repo root)" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$PREFLIGHT"

if ! declare -F _orphan_names_from_ps >/dev/null; then
    echo "[ERR] _orphan_names_from_ps not defined after sourcing $PREFLIGHT" >&2
    exit 2
fi

fail=0

assert_orphans() {
    local label=$1 input=$2 expected=$3 got
    got=$(printf '%s' "$input" | _orphan_names_from_ps | paste -sd' ' -)
    if [[ "$got" == "$expected" ]]; then
        echo "  [OK]   $label"
    else
        echo "  [MISS] $label"
        echo "         expected: [$expected]"
        echo "         got:      [$got]"
        fail=1
    fi
}

# 1. The real incident: two random-named orphans on the dirkwa image
#    alongside the managed signalk-server. Only the orphans are reported.
assert_orphans "random-named orphans flagged, managed signalk-server ignored" \
"signalk-server|ghcr.io/dirkwa/signalk-server:dirkwa
quirky_proskuriakova|ghcr.io/dirkwa/signalk-server:dirkwa
wizardly_aryabhata|ghcr.io/dirkwa/signalk-server:dirkwa" \
"quirky_proskuriakova wizardly_aryabhata"

# 2. All three managed containers present, no orphans → nothing reported.
assert_orphans "all managed containers ignored" \
"signalk-server|ghcr.io/dirkwa/signalk-server:dirkwa
signalk-updater-server|ghcr.io/dirkwa/signalk-updater-server:latest
signalk-doctor-server|ghcr.io/dirkwa/signalk-doctor-server:latest" \
""

# 3. A non-signalk container must never be flagged, even if random-named.
assert_orphans "unrelated container ignored" \
"signalk-server|ghcr.io/dirkwa/signalk-server:dirkwa
some_random_redis|docker.io/library/redis:7" \
""

# 4. Tag/owner-agnostic: an orphan on a different tag or registry is still
#    caught (the strays ran an older image; future ones may differ again).
assert_orphans "orphan on a different tag/owner flagged" \
"signalk-server|ghcr.io/dirkwa/signalk-server:dirkwa
stale_test|ghcr.io/someone/signalk-server:v2.24.0" \
"stale_test"

# 5. Empty input (no containers) → nothing reported.
assert_orphans "empty podman ps → no orphans" "" ""

if (( fail )); then
    echo
    echo "[ERR] orphan-container detection is wrong — see entries above." >&2
    exit 1
fi
echo
echo "[OK] orphan-container detection identifies unmanaged signalk-server containers."
