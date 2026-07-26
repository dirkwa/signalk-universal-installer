#!/usr/bin/env bash
# Emits ~/.signalk-updater/hardware.json describing detected USB serial,
# SocketCAN, Bluetooth-DBus availability, Raspberry Pi GPIO, and ALSA
# audio. Serial defaults to enabled (most boats want them); CAN/BLE/GPIO
# default to disabled (require explicit opt-in via the Updater UI); audio
# defaults to enabled when present — the rendered mount is a read-only
# metadata view for signalk-container's device probe, not direct audio
# access (see docs/hardware.md, "Audio passthrough").

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"

detect_os

emit_json() {
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local first=1
    local serial_items=()
    local can_items=()

    # USB serial via /dev/serial/by-id/* — stable across renumbering
    if [[ -d /dev/serial/by-id ]]; then
        local link
        for link in /dev/serial/by-id/*; do
            [[ -e "$link" ]] || continue
            local name
            name=$(basename "$link")
            # Heuristic vendor/product from the by-id symlink name
            local vendor=""
            local product=""
            if [[ "$name" =~ usb-([A-Za-z0-9_]+)_([A-Za-z0-9_-]+)_ ]]; then
                vendor="${BASH_REMATCH[1]}"
                product="${BASH_REMATCH[2]}"
            fi
            serial_items+=("{\"byId\":\"$link\",\"vendor\":\"$vendor\",\"product\":\"$product\",\"enabled\":true}")
        done
    fi

    # SocketCAN
    if command -v ip >/dev/null 2>&1; then
        local can_ifs
        can_ifs=$(ip -o link show type can 2>/dev/null | awk -F': ' '{print $2}' | sort -u)
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            can_items+=("{\"interface\":\"$iface\",\"type\":\"socketcan\",\"enabled\":false}")
        done <<<"$can_ifs"
    fi

    local bluetooth_avail=false
    [[ -S /run/dbus/system_bus_socket ]] && bluetooth_avail=true

    # ALSA sound devices (any card — HDMI counts; capture-capable cards
    # can hot-plug later, and the render-time mount tracks the directory,
    # not its contents)
    local audio_present=false
    [[ -d /dev/snd ]] && audio_present=true

    local pi_platform="none"
    if is_pi; then
        local model
        model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "")
        if [[ "$model" =~ Pi[[:space:]]*5 ]]; then pi_platform="rpi5"
        elif [[ "$model" =~ Pi[[:space:]]*4 ]]; then pi_platform="rpi4"
        elif [[ "$model" =~ Pi[[:space:]]*3 ]]; then pi_platform="rpi3"
        else pi_platform="rpi-other"; fi
    fi

    {
        echo "{"
        echo "  \"detectedAt\": \"$now\","
        echo -n "  \"serial\": ["
        first=1
        for item in "${serial_items[@]:-}"; do
            [[ -z "$item" ]] && continue
            if (( first )); then echo ""; first=0; else echo ","; fi
            printf "    %s" "$item"
        done
        echo ""
        echo "  ],"
        echo -n "  \"can\": ["
        first=1
        for item in "${can_items[@]:-}"; do
            [[ -z "$item" ]] && continue
            if (( first )); then echo ""; first=0; else echo ","; fi
            printf "    %s" "$item"
        done
        echo ""
        echo "  ],"
        echo "  \"bluetooth\": {"
        echo "    \"dbusAvailable\": $bluetooth_avail,"
        echo "    \"enabled\": false"
        echo "  },"
        echo "  \"audio\": {"
        echo "    \"present\": $audio_present,"
        echo "    \"enabled\": $audio_present"
        echo "  },"
        echo "  \"gpio\": {"
        echo "    \"platform\": \"$pi_platform\","
        echo "    \"enabled\": false"
        echo "  }"
        echo "}"
    }
}

emit_json
