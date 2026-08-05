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
# Against the wrong store every unmount is a silent no-op. These pin the rules
# verified against real `podman info` with a pinned CONTAINERS_STORAGE_CONF:
#
#   * `rootless_storage_path` is the ONLY key that moves a rootless store.
#     `graphroot` is ignored outright, wherever it appears.
#   * Exactly one config file is consulted -- the first that exists -- never a
#     merge across files.
#   * Both TOML string forms are valid, and $HOME / $UID expand.
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
USER_CONF="$CONF_DIR/containers/storage.conf"
PINNED="$WORK/pinned.conf"
SYS_HI="$WORK/sys-etc.conf"
SYS_LO="$WORK/sys-usrshare.conf"
BASE_ENV=("HOME=$WORK/home" "XDG_DATA_HOME=$WORK/data" "CONTAINERS_STORAGE_CONF=")
DEFAULT_ROOT="$WORK/data/containers/storage"

# THE STOCK-INSTALL TRAP, and the reason graphroot is never read: Debian and Pi
# OS ship /usr/share/containers/storage.conf with
# graphroot = "/var/lib/containers/storage" -- the ROOTFUL store. Honouring it
# would aim this tool at the wrong place on a DEFAULT install.
printf 'graphroot = "/var/lib/containers/storage"\n' > "$SYS_LO"
: > "$SYS_HI"; rm -f "$SYS_HI"
assert_root "system graphroot ignored (stock install)" "$DEFAULT_ROOT" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$WORK/empty" "SYS_STORAGE_CONFS=$SYS_LO"

# ...but graphroot in the USER's own config IS honoured. Measured, not assumed:
# rootless podman substitutes its own default only for a graphroot that came
# from a "default" config location, and the user's own file is not one.
printf 'graphroot = "/mnt/ssd/store"\n' > "$USER_CONF"
assert_root "user graphroot IS honoured" "/mnt/ssd/store" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$CONF_DIR" "SYS_STORAGE_CONFS="

# Pinning the very same file via CONTAINERS_STORAGE_CONF makes it the "default"
# config, and podman then drops its graphroot. Same bytes, different answer.
printf 'graphroot = "/mnt/ssd/store"\n' > "$PINNED"
assert_root "pinned-file graphroot is ignored" "$DEFAULT_ROOT" \
    "HOME=$WORK/home" "XDG_DATA_HOME=$WORK/data" "XDG_CONFIG_HOME=$WORK/empty" \
    "CONTAINERS_STORAGE_CONF=$PINNED" "SYS_STORAGE_CONFS="

# rootless_storage_path does NOT outrank graphroot -- it fills in where
# graphroot did not already set the store. In the user's own file graphroot
# survives, so it wins. Measured against podman info; the reverse looks more
# natural and is wrong.
printf 'graphroot = "/mnt/ssd/store"\nrootless_storage_path = "/mnt/ssd/rootless"\n' \
    > "$USER_CONF"
assert_root "user file: graphroot beats rootless path" "/mnt/ssd/store" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$CONF_DIR" "SYS_STORAGE_CONFS="

# Same two lines in a PINNED file invert the answer: graphroot is discarded
# first, so rootless_storage_path is what remains.
printf 'graphroot = "/mnt/ssd/store"\nrootless_storage_path = "/mnt/ssd/rootless"\n' \
    > "$PINNED"
assert_root "pinned file: rootless path is what is left" "/mnt/ssd/rootless" \
    "HOME=$WORK/home" "XDG_DATA_HOME=$WORK/data" "XDG_CONFIG_HOME=$WORK/empty" \
    "CONTAINERS_STORAGE_CONF=$PINNED" "SYS_STORAGE_CONFS="

printf 'rootless_storage_path = "/mnt/ssd/rootless"\n' > "$USER_CONF"
assert_root "rootless_storage_path from XDG_CONFIG_HOME" "/mnt/ssd/rootless" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$CONF_DIR" "SYS_STORAGE_CONFS="

# TOML literal strings are valid and podman accepts them.
printf "rootless_storage_path = '/mnt/ssd/literal'\n" > "$USER_CONF"
assert_root "TOML literal (single-quoted) value" "/mnt/ssd/literal" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$CONF_DIR" "SYS_STORAGE_CONFS="

# Single file, no merge: a user config that exists but is silent on the key
# falls to the DEFAULT rather than deferring to a lower-precedence file.
printf 'driver = "overlay"\n' > "$USER_CONF"
printf 'rootless_storage_path = "/mnt/should-not-be-used"\n' > "$SYS_LO"
assert_root "silent user config does not fall through" "$DEFAULT_ROOT" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$CONF_DIR" "SYS_STORAGE_CONFS=$SYS_LO"

# Same rule inside the system search path: the first readable file decides, so a
# lower-precedence value must not be picked up when the higher one is silent.
rm -f "$USER_CONF"
printf 'driver = "overlay"\n' > "$SYS_HI"
printf 'rootless_storage_path = "/mnt/should-not-be-used"\n' > "$SYS_LO"
assert_root "lower system file ignored when higher exists" "$DEFAULT_ROOT" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$WORK/empty" "SYS_STORAGE_CONFS=$SYS_HI:$SYS_LO"

# ...but it IS used when the higher-precedence file is absent.
rm -f "$SYS_HI"
assert_root "lower system file used when higher absent" "/mnt/should-not-be-used" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$WORK/empty" "SYS_STORAGE_CONFS=$SYS_HI:$SYS_LO"

# CONTAINERS_STORAGE_CONF pins one file outright, ignoring the search path.
printf 'rootless_storage_path = "/mnt/pinned"\n' > "$PINNED"
assert_root "CONTAINERS_STORAGE_CONF pins the file" "/mnt/pinned" \
    "HOME=$WORK/home" "XDG_DATA_HOME=$WORK/data" "XDG_CONFIG_HOME=$CONF_DIR" \
    "CONTAINERS_STORAGE_CONF=$PINNED" "SYS_STORAGE_CONFS=$SYS_LO"

# podman expands these inside a value; mirror it. The literal, unexpanded
# $HOME is the whole point of both the fixture and the label.
# shellcheck disable=SC2016
printf 'rootless_storage_path = "$HOME/relocated"\n' > "$PINNED"
# shellcheck disable=SC2016
assert_root 'expands $HOME in a config value' "$WORK/home/relocated" \
    "HOME=$WORK/home" "XDG_DATA_HOME=$WORK/data" "XDG_CONFIG_HOME=$CONF_DIR" \
    "CONTAINERS_STORAGE_CONF=$PINNED" "SYS_STORAGE_CONFS="

# No config anywhere: fall back through XDG_DATA_HOME, not a hardcoded path.
assert_root "XDG_DATA_HOME fallback" "$DEFAULT_ROOT" \
    "${BASE_ENV[@]}" "XDG_CONFIG_HOME=$WORK/empty" "SYS_STORAGE_CONFS="

# --- namespace entry and escalation ----------------------------------------
# The tool must not depend on podman to repair podman. `podman unshare` was the
# original way into the namespace; on a second real incident it HUNG, because
# unshare still initialises the store -- the thing that is blocked. nsenter into
# a live conmon touches no podman code, which is why it is now preferred.
if declare -F mount_ns_pid >/dev/null; then
    echo "  [OK]   mount_ns_pid helper present"
else
    echo "  [MISS] mount_ns_pid helper missing"; fail=1
fi

# mount_ns_pid must pick a CONMON, never a podman process: conmons are the
# long-lived per-container supervisors, and none of them can be the wedged one.
if grep -q 'comm" 2>/dev/null)" == conmon' "$RECOVERY"; then
    echo "  [OK]   namespace entry targets a conmon, not a podman process"
else
    echo "  [MISS] namespace entry does not pin conmon"; fail=1
fi

# A layer with no mount anywhere must not resolve to some unrelated pid.
if mount_ns_pid deadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1; then
    echo "  [MISS] mount_ns_pid matched a layer that is not mounted"; fail=1
else
    echo "  [OK]   unmounted layer yields no namespace pid"
fi

# Dropping the mount is not always enough -- observed on a Pi 4, where podman
# still spun on the layer afterwards and the directory had to go. Escalation
# must exist, and must be gated on podman still being unresponsive so a healthy
# host never has a layer directory deleted underneath it.
if declare -F remove_layer_dir >/dev/null; then
    echo "  [OK]   remove_layer_dir escalation present"
else
    echo "  [MISS] remove_layer_dir escalation missing"; fail=1
fi
if grep -q '! podman_responds; then' "$RECOVERY"; then
    echo "  [OK]   escalation gated on podman still being wedged"
else
    echo "  [MISS] escalation not gated — could delete on a healthy host"; fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] incomplete-layer detector"
    exit 1
fi
echo "[PASS] incomplete-layer detector"
