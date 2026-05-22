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

# Build the AddDevice/Volume block from hardware.json. We use jq if present
# (best); otherwise fall back to a sed-based extractor that handles the
# narrow shape detect-hardware.sh emits.
hardware_block() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '
          [
            (.serial // [])[] | select(.enabled == true) | "AddDevice=" + .byId,
            (.can // [])[] | select(.enabled == true) | "AddDevice=/dev/" + .interface,
            (.bluetooth // {}) | select(.enabled == true and .dbusAvailable == true) | "Volume=/run/dbus:/run/dbus:ro",
            (.gpio // {}) | select(.enabled == true) | "Volume=/dev/gpiomem:/dev/gpiomem"
          ] | .[]
        ' "$HW_FILE"
    else
        # No jq — minimal grep/sed parser. Handles serial-by-id only;
        # CAN/BLE/GPIO require jq.
        grep -oE '"byId":"[^"]+"' "$HW_FILE" | sed 's/.*"byId":"\(.*\)"$/AddDevice=\1/'
    fi
}

# Stream the template, replacing the HARDWARE block.
awk -v hw_block="$(hardware_block)" '
    BEGIN { in_hw = 0 }
    /^# === BEGIN HARDWARE/ { print; print hw_block; in_hw = 1; next }
    /^# === END HARDWARE/   { in_hw = 0; print; next }
    !in_hw                  { print }
' "$TEMPLATE"
