#!/usr/bin/env bash
# Verifies signalk-recovery's incomplete-layer detector, the safety property
# `unwedge-podman` depends on.
#
# Background: a SIGKILL landing on `podman run` mid-container-create leaves a
# layer flagged incomplete in c/storage with its overlayfs merged dir still
# mounted. podman's cleanup then spins forever on that live mount holding the
# global c/storage lock, and every podman command blocks. `unwedge-podman`
# drops the stale mount -- but it must ONLY ever unmount layers podman itself
# declared incomplete. Unmounting a live container's merged dir breaks that
# container, so a detector that over-matches is actively dangerous.
#
# The fixture is verbatim journal output. podman logs in logfmt, so the layer
# ID arrives with BACKSLASH-ESCAPED quotes inside msg="...". A detector written
# against a literal quote matches nothing and reports a healthy host while
# podman is wedged -- silent, and exactly the failure this test pins.
#
# Sources signalk-recovery.tmpl (main-guarded, so nothing dispatches) and feeds
# incomplete_layer_ids fixture journal text. Run from repo root.

set -euo pipefail

RECOVERY=${RECOVERY:-installer/linux/signalk-recovery.tmpl}

if [[ ! -f "$RECOVERY" ]]; then
    echo "[ERR] $RECOVERY not found (run from repo root)" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$RECOVERY"

if ! declare -F incomplete_layer_ids >/dev/null; then
    echo "[ERR] incomplete_layer_ids not defined after sourcing $RECOVERY" >&2
    exit 2
fi

fail=0

# Drive the detector off fixture text instead of the host journal: override
# journalctl for the duration, and point STORAGE_ROOT at an empty dir so the
# optional jq source contributes nothing.
FIXTURE=""
journalctl() { printf '%s\n' "$FIXTURE"; }
STORAGE_ROOT=$(mktemp -d)
trap 'rm -rf "$STORAGE_ROOT"' EXIT

assert_ids() {
    local label=$1 expected=$2 got
    got=$(incomplete_layer_ids | paste -sd' ' -)
    if [[ "$got" == "$expected" ]]; then
        echo "  [OK]   $label"
    else
        echo "  [MISS] $label"
        echo "         expected: [$expected]"
        echo "         got:      [$got]"
        fail=1
    fi
}

ID1=49ceb5b27babe271eead64801e17234d6dcbed003fa38c2874958e56f3a4f060
ID2=0432fcd0907f06b00f08e14d560ab10530a7e06fc9919ef67ec4b0cae160d95b

# 1. The real incident line, copied verbatim from a wedged Pi 4. Escaped
#    quotes around the ID are the whole point of this case.
FIXTURE='time="2026-08-04T17:14:58+12:00" level=warning msg="Found incomplete layer \"'"$ID1"'\", deleting it"'
assert_ids "logfmt line with escaped quotes" "$ID1"

# 2. Unescaped quotes -- the same message as podman prints it to a terminal.
#    Both spellings must resolve to the same ID.
FIXTURE='Found incomplete layer "'"$ID1"'", deleting it'
assert_ids "plain quoted form" "$ID1"

# 3. Two distinct incomplete layers, deduplicated and sorted.
FIXTURE='msg="Found incomplete layer \"'"$ID1"'\", deleting it"
msg="Found incomplete layer \"'"$ID2"'\", deleting it"
msg="Found incomplete layer \"'"$ID1"'\", deleting it"'
assert_ids "two layers, deduplicated" "$ID2 $ID1"

# 4. A quiet journal yields nothing. unwedge-podman refuses to act on an empty
#    set rather than guessing at which mounts look stale.
FIXTURE='level=info msg="Received shutdown.Stop(), terminating!" PID=3290234'
assert_ids "unrelated journal lines" ""

# 5. The timestamp in a logfmt line contains digits, and neighbouring words
#    contain hex letters. Neither may be mistaken for a layer ID.
FIXTURE='time="2026-08-04T17:15:45+12:00" level=warning msg="deadbeefcafe accede facade"'
assert_ids "no false positive without the phrase" ""

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] incomplete-layer detector"
    exit 1
fi
echo "[PASS] incomplete-layer detector"
