#!/usr/bin/env bash
# Emits ~/.signalk-updater/hardware.json describing detected USB serial,
# SocketCAN, Bluetooth-DBus availability, Raspberry Pi GPIO, ALSA audio,
# and — on a Hat Labs HALPI2 carrier — the `board` / `onboardSerial`
# classes. Serial defaults to enabled (most boats want them); CAN/BLE/GPIO
# default to disabled (require explicit opt-in via the Updater UI); audio
# defaults to enabled when present — the rendered mount is a read-only
# metadata view for signalk-container's device probe, not direct audio
# access (see docs/hardware.md, "Audio passthrough").
#
# Board detection is passive (no sudo, no writes): the CM5 model string
# makes the box a candidate; an active halpid unit or an answer from the
# HALPI2 controller at I2C 0x6d confirms it. `signalk halpi2 apply` owns
# the sudo side (docs/halpi2.md). Paths are env-overridable so
# scripts/test/check-halpi2-detect.sh can drive the ladder on any host.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"

detect_os

DT_MODEL_FILE="${DT_MODEL_FILE:-/proc/device-tree/model}"
HALPI2_I2C_DEV="${HALPI2_I2C_DEV:-/dev/i2c-1}"
HALPI2_RS485_DEV="${HALPI2_RS485_DEV:-/dev/ttyAMA4}"

# HALPI2 controller version register: write the register byte, read 4
# bytes (major, minor, patch, alpha|0xff) — the same transaction halpid's
# read_bytes() performs. Prints "M.m.p" or nothing.
halpi2_i2c_version() {
    local reg=$1 bus out
    bus=${HALPI2_I2C_DEV##*i2c-}
    command -v i2ctransfer >/dev/null 2>&1 || return 1
    out=$(i2ctransfer -y "$bus" w1@0x6d "$reg" r4 2>/dev/null) || return 1
    # shellcheck disable=SC2086
    set -- $out
    [[ $# -eq 4 ]] || return 1
    printf '%d.%d.%d' "$1" "$2" "$3"
}

# Sets BOARD_JSON to the `board` object (empty when not a CM5) and
# ONBOARD_SERIAL_ITEMS to the onboardSerial entries (empty unless the
# board is confirmed and the RS-485 node exists).
detect_board() {
    BOARD_JSON=""
    ONBOARD_SERIAL_ITEMS=()
    local model=""
    [[ -r "$DT_MODEL_FILE" ]] && model=$(tr -d '\0' <"$DT_MODEL_FILE" 2>/dev/null || true)
    [[ "$model" == *"Compute Module 5"* ]] || return 0
    local via="model-string" candidate=true hw="null" fw="null"
    if systemctl is-active --quiet halpid 2>/dev/null; then
        via="halpid"; candidate=false
    elif [[ -r "$HALPI2_I2C_DEV" && -w "$HALPI2_I2C_DEV" ]]; then
        local v
        if v=$(halpi2_i2c_version 0x04) && [[ -n "$v" ]]; then
            via="i2c"; candidate=false; fw="\"$v\""
            v=$(halpi2_i2c_version 0x03) && [[ -n "$v" ]] && hw="\"$v\""
        fi
    fi
    BOARD_JSON="{\"model\":\"halpi2\",\"candidate\":$candidate,\"detectedVia\":\"$via\",\"hardwareVersion\":$hw,\"firmwareVersion\":$fw}"
    if [[ "$candidate" == false && -e "$HALPI2_RS485_DEV" ]]; then
        ONBOARD_SERIAL_ITEMS+=("{\"device\":\"$HALPI2_RS485_DEV\",\"label\":\"HALPI2 RS-485\",\"enabled\":true}")
    fi
}

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

    detect_board

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
        if [[ -n "$BOARD_JSON" ]]; then
            echo "  },"
            echo "  \"board\": $BOARD_JSON,"
            echo -n "  \"onboardSerial\": ["
            first=1
            for item in "${ONBOARD_SERIAL_ITEMS[@]:-}"; do
                [[ -z "$item" ]] && continue
                if (( first )); then echo ""; first=0; else echo ","; fi
                printf "    %s" "$item"
            done
            echo ""
            echo "  ]"
        else
            echo "  }"
        fi
        echo "}"
    }
}

emit_json
