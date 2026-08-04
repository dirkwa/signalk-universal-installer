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
#
# The stub records its argv to a FILE, not a variable: incomplete_layer_ids runs
# it inside a `{ ... } | sort -u` pipeline, so the stub executes in a subshell
# and any variable it sets is lost on return.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STORAGE_ROOT="$WORK/store"
mkdir -p "$STORAGE_ROOT"
JOURNAL_ARGV="$WORK/journal-argv"
FIXTURE=""
journalctl() { printf '%s\n' "$*" >"$JOURNAL_ARGV"; printf '%s\n' "$FIXTURE"; }

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

# 6. The journal scan must stay bounded. Without this the 7-day window is
#    untested: every case above passes just as happily against an unbounded
#    read, which on a busy journal costs minutes on an SD card — in the one
#    tool an operator runs when the box is already broken.
FIXTURE=''
incomplete_layer_ids >/dev/null
if grep -q -- '--since' "$JOURNAL_ARGV" 2>/dev/null; then
    echo "  [OK]   journal scan passes --since"
else
    echo "  [MISS] journal scan is unbounded (no --since in: $(cat "$JOURNAL_ARGV" 2>/dev/null))"
    fail=1
fi

# --- effective storage root ------------------------------------------------
# Against the wrong graphroot every unmount is a silent no-op. These pin the
# containers-storage.conf(5) precedence the resolver implements.
assert_root() {
    local label=$1 expected=$2 got
    shift 2
    got=$(env "$@" bash -c "source '$RECOVERY'; default_storage_root")
    if [[ "$got" == "$expected" ]]; then
        echo "  [OK]   $label"
    else
        echo "  [MISS] $label"
        echo "         expected: [$expected]"
        echo "         got:      [$got]"
        fail=1
    fi
}

CONF_DIR="$WORK/xdgconf"; mkdir -p "$CONF_DIR/containers"
ETC_STYLE="$WORK/pinned.conf"

printf 'graphroot = "/mnt/ssd/store"
' > "$CONF_DIR/containers/storage.conf"
assert_root "graphroot from XDG_CONFIG_HOME" "/mnt/ssd/store" \
    "HOME=$WORK/home" "XDG_CONFIG_HOME=$CONF_DIR" "CONTAINERS_STORAGE_CONF="

# rootless_storage_path wins over graphroot in the same file — we are always
# resolving a rootless store here.
printf 'graphroot = "/mnt/ssd/store"
rootless_storage_path = "/mnt/ssd/rootless"
' \
    > "$CONF_DIR/containers/storage.conf"
assert_root "rootless_storage_path beats graphroot" "/mnt/ssd/rootless" \
    "HOME=$WORK/home" "XDG_CONFIG_HOME=$CONF_DIR" "CONTAINERS_STORAGE_CONF="

# CONTAINERS_STORAGE_CONF pins one file outright, ignoring the search path.
printf 'graphroot = "/mnt/pinned"
' > "$ETC_STYLE"
assert_root "CONTAINERS_STORAGE_CONF pins the file" "/mnt/pinned" \
    "HOME=$WORK/home" "XDG_CONFIG_HOME=$CONF_DIR" "CONTAINERS_STORAGE_CONF=$ETC_STYLE"

# THE STOCK-INSTALL TRAP. Debian and Pi OS ship
# /usr/share/containers/storage.conf with graphroot = "/var/lib/containers/storage"
# — the ROOTFUL store, which a rootless podman ignores. An earlier revision of
# the resolver honoured it and would have pointed this tool at the wrong store
# on a DEFAULT install. Only rootless_storage_path may carry from a system file.
SYS_DIR="$WORK/sys"; mkdir -p "$SYS_DIR"
printf 'graphroot = "/var/lib/containers/storage"\n' > "$SYS_DIR/storage.conf"
assert_root "system graphroot is ignored for a rootless store" \
    "$WORK/data/containers/storage" \
    "HOME=$WORK/home" "XDG_CONFIG_HOME=$WORK/empty" "XDG_DATA_HOME=$WORK/data" \
    "CONTAINERS_STORAGE_CONF="

# $HOME inside a value is expanded by podman; mirror that.
# shellcheck disable=SC2016  # the literal $HOME is the fixture's whole point
printf 'graphroot = "$HOME/relocated"
' > "$ETC_STYLE"
assert_root "expands \$HOME in a config value" "$WORK/home/relocated" \
    "HOME=$WORK/home" "XDG_CONFIG_HOME=$CONF_DIR" "CONTAINERS_STORAGE_CONF=$ETC_STYLE"

# No config anywhere: fall back through XDG_DATA_HOME, not a hardcoded path.
assert_root "XDG_DATA_HOME fallback" "$WORK/data/containers/storage" \
    "HOME=$WORK/home" "XDG_CONFIG_HOME=$WORK/empty" "XDG_DATA_HOME=$WORK/data" \
    "CONTAINERS_STORAGE_CONF="

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] incomplete-layer detector"
    exit 1
fi
echo "[PASS] incomplete-layer detector"
