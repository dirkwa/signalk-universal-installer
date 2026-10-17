#!/usr/bin/env bash
# Usage: render-server-quadlet.sh <hardware.json> [<template_path>]
# Emits the final signalk-server.container Quadlet on stdout, with the
# HARDWARE Volume= lines and the SERIAL DEVICES list populated from the
# hardware.json file.
#
# Pure stdout — caller is responsible for atomic-writing to the
# ~/.config/containers/systemd/ directory.

set -euo pipefail

HW_FILE="${1:-${HOME}/.signalk-updater/hardware.json}"
TEMPLATE="${2:-}"
# Host path probed/mounted for the audio class; overridable so the render
# test can exercise both the present and missing cases deterministically.
AUDIO_DIR="${AUDIO_DIR:-/dev/snd}"
# Host path probed/mounted for the input class; overridable for the same
# reason as AUDIO_DIR.
INPUT_DIR="${INPUT_DIR:-/dev/input}"
# Host directory of the halpid socket (HALPI2 power/watchdog daemon,
# docs/halpi2.md). Mounted for the `signalk-halpi` plugin only when the
# board is a HALPI2 and the socket exists at render time; overridable for
# the render tests, same as AUDIO_DIR.
HALPID_RUN_DIR="${HALPID_RUN_DIR:-/run/halpid}"

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

# Serial devices (USB `serial` by-id paths and the fixed `onboardSerial`
# UARTs) are NOT AddDevice= lines. Quadlet bakes an AddDevice= into the unit's
# ExecStart as `--device`, and podman fails container creation (exit 125)
# when that path is missing at start. A render-time existence check cannot
# cover it: a device present at render can be gone at a later start. Issue
# #309 is the case: a touchscreen whose USB hub, and the serial port behind
# it, disconnects whenever the monitor is switched off, so every server start
# with the monitor off failed and the server stayed down for hours.
#
# Instead this renders the [Service] SERIAL DEVICES block: one
# Environment="SIGNALK_SERIAL_DEVICES=<path> <path> ..." line listing the
# enabled devices. The template's ExecStartPre turns the devices that exist
# at THAT start into --device arguments (see the template for the wait, the
# two forms per by-id device, and the log line for absent ones). Absent
# devices are listed anyway, so a device that comes back is passed at the
# next start without a re-render.
#
# A path is listed only if it is made of characters that survive the unit
# file and the ExecStartPre word split unchanged; udev's by-id names
# (usb-<vendor>_<model>_<serial>-if<NN>[-port<N>]) and /dev/ttyAMA* do. A
# rejected path is named in a comment in the block rather than on stderr,
# for the same reason as warn_input_group_skip below.
serial_devices_block() {
    local paths path list=""
    if command -v jq >/dev/null 2>&1; then
        paths=$(jq -r '
            ((.serial // [])[] | select(.enabled == true) | .byId // empty),
            ((.onboardSerial // [])[] | select(.enabled == true) | .device // empty)
        ' "$HW_FILE")
    else
        # No jq — minimal grep/sed parser: by-id paths only. An entry is
        # listed only when the whole object, "enabled":true included, is on
        # one line, the form detect-hardware.sh writes. An object spread over
        # several lines (the Updater writes hardware.json pretty-printed) is
        # not listed, because grep cannot tie its enabled flag to its path.
        paths=$(grep -oE '\{[^{}]*"byId": *"[^"]+"[^{}]*\}' "$HW_FILE" \
            | grep -E '"enabled": *true' \
            | sed -E 's/.*"byId": *"([^"]+)".*/\1/')
    fi
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [[ "$path" =~ ^/[A-Za-z0-9._/:+@,=-]+$ ]]; then
            list="${list:+$list }$path"
        else
            echo "# serial device not passed (unsupported characters): $path"
        fi
    done <<<"$paths"
    if [ -n "$list" ]; then
        echo "Environment=\"SIGNALK_SERIAL_DEVICES=$list\""
    fi
}

# Build the Volume block from hardware.json. The BLE/GPIO lines need jq; the
# audio and input lines below have a grep fallback.
# Bluetooth note: the volume is the signalk-dbus-proxy sidecar's named
# socket volume, NOT a bind mount of the host's /run/dbus. A direct bind
# mount cannot work under rootless podman on hosts where the SignalK user
# isn't uid 1000: D-Bus EXTERNAL auth compares the uid the in-container
# client sends (its container uid) against the kernel's SO_PEERCRED (the
# host-side uid), the mismatch never authenticates, and the client dies
# 30s later with "Tried to write a message to a closed stream". The proxy
# rewrites the AUTH uid in transit — see
# quadlets/signalk-dbus-proxy.container.template for the full mechanism.
# True when the service user holds the host `input` group.
#
# Checked against the RUNNING user's supplementary set (`id -nG`), not against
# what install.sh grants: GroupAdd=keep-groups carries every host group into the
# container regardless of who added it. INPUT_GROUP_OVERRIDE lets the render
# test drive both branches without touching real group membership.
user_in_input_group() {
    if [ -n "${INPUT_GROUP_OVERRIDE:-}" ]; then
        [ "$INPUT_GROUP_OVERRIDE" = "yes" ]
        return
    fi
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx input
}

# Explain the skip in the unit itself. A `warn` on stderr would be wrong here:
# this is a routine, correct outcome, and the render is also consumed by
# scripts that treat any stderr as a failure. A comment reaches the operator
# reading their Quadlet and is inert to systemd.
warn_input_group_skip() {
    echo "# /dev/input view SKIPPED: this user is in the host 'input' group."
    echo "# Mounting it would make event nodes readable inside signalk-server"
    echo "# (:ro restricts the mount, not open() on a node), so the metadata"
    echo "# view is withheld. signalk-container still emits /dev/input for a"
    echo "# consumer container unverified. Remove yourself from 'input' and"
    echo "# re-run 'signalk hardware rescan' to restore the view."
}

# CAN interfaces get no line. A SocketCAN interface is a network device, not
# a /dev node, and signalk-server runs with Network=host, so every CAN
# interface on the host is already reachable. The AddDevice=/dev/<iface> line
# this used to emit for an enabled interface made podman fail every start
# (`stat /dev/can0: no such file or directory`, exit 125), since no such node
# exists.
hardware_block() {
    # Serial devices are not in this block; serial_devices_block above
    # renders them. Without jq, BLE/GPIO are not rendered at all.
    if command -v jq >/dev/null 2>&1; then
        # Each clause is parenthesized so its `|` pipeline stays local to
        # the array element. Without the parens, jq's `|` binds across the
        # whole comma-list: one clause's stream gets piped into the next
        # clause's `select(.enabled ...)`, which indexes the already-built
        # "Volume=..." string and errors with "Cannot index string".
        jq -r '
          [
            ((.bluetooth // {}) | select(.enabled == true and .dbusAvailable == true) | "Volume=signalk-dbus-socket:/run/dbus:rw"),
            ((.gpio // {}) | select(.enabled == true) | "Volume=/dev/gpiomem:/dev/gpiomem")
          ] | .[]
        ' "$HW_FILE"
    fi

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

    # Input event devices (the `input` class). Identical rationale to audio
    # above: a read-only METADATA view so signalk-container can stat the real
    # host nodes, not input access for signalk-server. The manager only ever
    # stats and readdirs; a consumer container that genuinely needs an encoder
    # gets its own bind emitted by signalk-container. Same existence guard, so
    # a stale enabled=true cannot brick the unit.
    #
    # THIRD guard, specific to this class: skip the mount entirely when the
    # service user is in the host `input` group. `:ro` makes the MOUNT
    # read-only, not the nodes -- open() is decided by the node's own
    # permissions (root:input 0660) -- and GroupAdd=keep-groups carries EVERY
    # supplementary host group, whoever granted it. install.sh never adds
    # `input`, but a desktop distro or a local admin may have, and this script
    # also runs on hosts the installer did not set up. Without this check such
    # a host would hand signalk-server readable event nodes: a keylogger
    # surface. Losing the metadata view costs only probe accuracy --
    # signalk-container falls back to emitting /dev/input unverified.
    local input_enabled=false
    if command -v jq >/dev/null 2>&1; then
        [ "$(jq -r '.input.enabled // false' "$HW_FILE")" = "true" ] \
            && input_enabled=true
    elif grep -A2 '"input"' "$HW_FILE" 2>/dev/null | grep -q '"enabled": *true'; then
        # No jq — same minimal-parser spirit as the audio block above.
        input_enabled=true
    fi
    if [ "$input_enabled" = "true" ] && [ -d "$INPUT_DIR" ]; then
        if user_in_input_group; then
            warn_input_group_skip
        else
            echo "Volume=${INPUT_DIR}:/dev/input:ro"
        fi
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

serial_block=$(serial_devices_block)

# A template from before the SERIAL DEVICES block has no place for the list,
# and its ExecStart would not read it: rendering against it would drop every
# serial device without a word. Refuse instead, so `signalk render-server`
# leaves the live Quadlet as it is.
if [ -n "$serial_block" ] && ! grep -q '^# === BEGIN SERIAL DEVICES' "$TEMPLATE"; then
    echo "render-server-quadlet: $TEMPLATE has no SERIAL DEVICES block; refusing to drop the serial devices in $HW_FILE" >&2
    exit 1
fi

# Stream the template, replacing the HARDWARE and SERIAL DEVICES blocks.
awk -v hw_block="$(hardware_block)" -v serial_block="$serial_block" '
    BEGIN { skip = 0 }
    /^# === BEGIN HARDWARE/       { print; print hw_block; skip = 1; next }
    /^# === BEGIN SERIAL DEVICES/ { print; print serial_block; skip = 1; next }
    /^# === END (HARDWARE|SERIAL DEVICES)/ { skip = 0; print; next }
    !skip                         { print }
' "$TEMPLATE"
