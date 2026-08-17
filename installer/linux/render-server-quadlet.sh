#!/usr/bin/env bash
# Usage: render-server-quadlet.sh <hardware.json> [<template_path>]
# Emits the final signalk-server.container Quadlet on stdout, with
# AddDevice= / Volume= lines populated from the hardware.json file.
#
# Pure stdout — caller is responsible for atomic-writing to the
# ~/.config/containers/systemd/ directory.

set -euo pipefail

HW_FILE="${1:-${HOME}/.signalk-updater/hardware.json}"
TEMPLATE="${2:-}"
# Host path probed/mounted for the audio class; overridable so the render
# test can exercise both the present and missing cases deterministically.
AUDIO_DIR="${AUDIO_DIR:-/dev/snd}"
# Each serial device is emitted TWICE, deliberately.
#
#   AddDevice=<by-id>:<by-id>   the stable name, present inside the container
#   AddDevice=<by-id>           podman resolves the symlink -> /dev/ttyUSB0
#
# The mapped form alone is not enough. It is the better path to configure --
# a boat with two USB serial devices (an NGT-1 and a GPS) can have them swap
# on reboot, and SignalK would read the wrong one from a config that still
# looks correct -- but /dev/ttyUSB0 is what the SignalK UI offers and what
# every existing config and forum post already says. Publishing only the
# by-id name replaces "permission denied" with "No such file or directory"
# for those users: a different error, not a fixed install. Emitting both
# leaves existing configs working while making the stable name available.
#
# The existence guard below copes with both forms: it strips from the FIRST
# colon to get the host path.
#
# Directory the serial AddDevice= existence guard stats against. Real serial
# by-id symlinks live under /dev/serial/by-id; overridable (like AUDIO_DIR)
# so the render test can seed present/absent device nodes deterministically
# without touching the host's /dev.
SERIAL_DIR="${SERIAL_DIR:-/dev/serial/by-id}"
# Host directory of the halpid socket (HALPI2 power/watchdog daemon,
# docs/halpi2.md). Mounted for the `signalk-halpi` plugin only when the
# board is a HALPI2 and the socket exists at render time; overridable for
# the render tests, same as AUDIO_DIR.
HALPID_RUN_DIR="${HALPID_RUN_DIR:-/run/halpid}"
# Prefix that marks an `onboardSerial` AddDevice= line for the existence
# guard (fixed UARTs are /dev/ttyAMA*, /dev/ttyS*); overridable for tests.
TTY_PREFIX="${TTY_PREFIX:-/dev/tty}"

if [[ -z "$TEMPLATE" ]]; then
    # Default: look next to this script (../../quadlets/...)
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TEMPLATE="$HERE/../../quadlets/signalk-server.container.template"
fi

if [[ ! -f "$TEMPLATE" ]]; then
    echo "render-server-quadlet: template not found: $TEMPLATE" >&2
    exit 1
fi
if [[ ! -f "$HW_FILE" ]]; then
    echo "render-server-quadlet: hardware.json not found: $HW_FILE" >&2
    exit 1
fi

# Drop serial AddDevice= lines whose device node is absent at render time.
# hardware.json records what detect-hardware.sh saw at DETECT time, but a
# USB-serial adapter can disappear between detect and render — physically
# unplugged, or a flaky device that re-enumerates (a CH340/ACM adapter drops
# its /dev/serial/by-id symlink while it re-enumerates). An AddDevice= pointing
# at a path podman can't stat fails container creation hard (exit 125) BEFORE
# the app starts, so one absent optional serial device crashloops the whole
# server. This mirrors the render-time existence guard the audio (/dev/snd)
# and avahi-socket lines below already have: emit the line only when the
# device node exists, otherwise silently drop it (the server still starts;
# that one input source is just absent) rather than bricking.
#
# Scope is deliberately SERIAL ONLY — matched by the /dev/serial/by-id/
# prefix, plus the fixed on-SoC UARTs the `onboardSerial` class emits as
# AddDevice=/dev/tty* (HALPI2 RS-485 on /dev/ttyAMA4). CAN's
# AddDevice=/dev/<iface> is left untouched: socketcan is a
# network device, not a /dev node, so an existence test on /dev/<iface>
# would strip every legitimate CAN line. (signalk-server runs Network=host,
# so the CAN interface is reachable regardless; guarding it correctly is a
# separate concern and out of scope here.) Volume= and every other line
# pass through untouched. Reads stdin, writes stdout.
guard_adddevice() {
    local line dev
    while IFS= read -r line; do
        case "$line" in
            "AddDevice=${SERIAL_DIR}/"*|"AddDevice=${TTY_PREFIX}"*)
                # Strip the "AddDevice=" prefix, then any ":perms" suffix
                # (e.g. AddDevice=/dev/foo:rwm) to get the host path to stat.
                dev=${line#AddDevice=}
                dev=${dev%%:*}
                # Explicit if, not `[ -e ] && printf`: the guard runs in a
                # `... | guard_adddevice` pipe under set -euo pipefail, and a
                # short-circuited && leaves the loop (and the function) with
                # status 1 on a skipped device — the very case this exists to
                # handle — which would abort rendering. An if makes the skip a
                # success.
                if [ -e "$dev" ]; then
                    printf '%s\n' "$line"
                fi
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done
}

# Build the AddDevice/Volume block from hardware.json. We use jq if present
# (best); otherwise fall back to a sed-based extractor that handles the
# narrow shape detect-hardware.sh emits.
# Bluetooth note: the volume is the signalk-dbus-proxy sidecar's named
# socket volume, NOT a bind mount of the host's /run/dbus. A direct bind
# mount cannot work under rootless podman on hosts where the SignalK user
# isn't uid 1000: D-Bus EXTERNAL auth compares the uid the in-container
# client sends (its container uid) against the kernel's SO_PEERCRED (the
# host-side uid), the mismatch never authenticates, and the client dies
# 30s later with "Tried to write a message to a closed stream". The proxy
# rewrites the AUTH uid in transit — see
# quadlets/signalk-dbus-proxy.container.template for the full mechanism.
hardware_block() {
    {
    if command -v jq >/dev/null 2>&1; then
        # Each clause is parenthesized so its `|` pipeline stays local to
        # the array element. Without the parens, jq's `|` binds across the
        # whole comma-list: the serial stream gets piped into the next
        # clause's `select(.enabled ...)`, which indexes the already-built
        # "AddDevice=..." string and errors with "Cannot index string".
        jq -r '
          [
            ((.serial // [])[] | select(.enabled == true)
                | ("AddDevice=" + .byId + ":" + .byId), ("AddDevice=" + .byId)),
            ((.onboardSerial // [])[] | select(.enabled == true) | "AddDevice=" + .device),
            ((.can // [])[] | select(.enabled == true) | "AddDevice=/dev/" + .interface),
            ((.bluetooth // {}) | select(.enabled == true and .dbusAvailable == true) | "Volume=signalk-dbus-socket:/run/dbus:rw"),
            ((.gpio // {}) | select(.enabled == true) | "Volume=/dev/gpiomem:/dev/gpiomem")
          ] | .[]
        ' "$HW_FILE"
    else
        # No jq — minimal grep/sed parser. Handles serial-by-id only;
        # CAN/BLE/GPIO require jq.
        grep -oE '"byId":"[^"]+"' "$HW_FILE" \
            | sed 's/.*"byId":"\(.*\)"$/AddDevice=\1:\1\nAddDevice=\1/'
    fi
    } | guard_adddevice

    # ALSA /dev/snd view (the `audio` class in hardware.json). This is NOT
    # audio access for signalk-server itself: signalk-container runs INSIDE
    # this container and stats a consumer plugin's requested device paths on
    # its OWN filesystem before emitting the /dev/snd bind for the managed
    # container that actually uses the sound card (e.g. signalk-wyoming's
    # wyoming-satellite). Without this view the probe reports the device
    # missing. Read-only — the manager only stats/readdirs; the consumer
    # container gets its own bind from signalk-container. Existence-guarded
    # like the avahi socket below (a Volume= with a missing source fails the
    # unit to start), so a stale enabled=true in hardware.json can never
    # brick the server on a host that lost its sound devices.
    local audio_enabled=false
    if command -v jq >/dev/null 2>&1; then
        [ "$(jq -r '.audio.enabled // false' "$HW_FILE")" = "true" ] \
            && audio_enabled=true
    elif grep -A2 '"audio"' "$HW_FILE" 2>/dev/null | grep -q '"enabled": *true'; then
        # No jq — same minimal-parser spirit as the serial fallback above;
        # relies on detect-hardware.sh's flat two-key `audio` object.
        audio_enabled=true
    fi
    if [ "$audio_enabled" = "true" ] && [ -d "$AUDIO_DIR" ]; then
        echo "Volume=${AUDIO_DIR}:/dev/snd:ro"
    fi

    # Host avahi socket (mDNS .local resolution). The signalk-server image ships
    # libnss-mdns (the NSS module) but NOT avahi-daemon, so getaddrinfo('x.local')
    # inside the container resolves via the HOST's avahi over this socket. This
    # works because the Quadlet runs the container with UserNS=keep-id:uid=1000,
    # so the socket's peer credentials match the host user. Mounted ONLY when the
    # host actually runs avahi (the socket exists) — a Volume= with a missing
    # source makes the unit fail to start (statfs ENOENT, exit 125). Probed at
    # render time, so it tracks the host: re-running the installer or a later
    # updater re-render adds/drops it as avahi appears/disappears. ro: the
    # container only queries; it never writes the host's avahi socket.
    if [ -S /run/avahi-daemon/socket ]; then
        echo "Volume=/run/avahi-daemon/socket:/run/avahi-daemon/socket:ro"
    fi

    # halpid socket (HALPI2 only). Lets the `signalk-halpi` plugin poll
    # /run/halpid/halpid.sock from inside the container; the socket is
    # root:halpid 0660 and the container reaches it through the host user's
    # `halpid` membership (GroupAdd=keep-groups), so this is a plain
    # directory bind. ro: connect() on a socket does not need a writable
    # mount (same as the usual docker.sock:ro pattern), and the container
    # must not be able to create files in /run/halpid. Existence-guarded on
    # the socket like avahi above.
    if command -v jq >/dev/null 2>&1 \
        && [ "$(jq -r '.board.model // empty' "$HW_FILE")" = "halpi2" ] \
        && [ -S "${HALPID_RUN_DIR}/halpid.sock" ]; then
        echo "Volume=${HALPID_RUN_DIR}:/run/halpid:ro"
    fi
}

# Stream the template, replacing the HARDWARE block.
awk -v hw_block="$(hardware_block)" '
    BEGIN { in_hw = 0 }
    /^# === BEGIN HARDWARE/ { print; print hw_block; in_hw = 1; next }
    /^# === END HARDWARE/   { in_hw = 0; print; next }
    !in_hw                  { print }
' "$TEMPLATE"
