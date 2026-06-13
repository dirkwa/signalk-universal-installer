#!/usr/bin/env bash
# Post-install standalone health check. Probes the running stack without
# touching it. Safe to run any time. Mirrors the doctor container's probes
# at a coarser granularity — the container's /api/probes endpoint is the
# real diagnostic surface.

set -euo pipefail

# signalk-server's HTTP port is install-time-configurable (80 or 3000).
# Read it from the rendered Quadlet's `Environment=PORT=` line so this
# standalone probe hits the right port without the operator exporting
# SIGNALK_URL; fall back to 80 (the default) when the line is absent.
sk_http_port() {
    local q="${HOME}/.config/containers/systemd/signalk-server.container"
    local p
    p=$(sed -n 's/^Environment=PORT=\([0-9][0-9]*\).*/\1/p' "$q" 2>/dev/null | head -1)
    printf '%s' "${p:-80}"
}

UPDATER_URL=${UPDATER_URL:-http://127.0.0.1:3003}
DOCTOR_URL=${DOCTOR_URL:-http://127.0.0.1:3004}
SIGNALK_URL=${SIGNALK_URL:-http://127.0.0.1:$(sk_http_port)/signalk}

check() {
    local name=$1; local url=$2
    if curl -fsS -o /dev/null -m 5 "$url"; then
        printf '  [OK]   %-20s %s\n' "$name" "$url"
    else
        printf '  [FAIL] %-20s %s\n' "$name" "$url"
    fi
}

echo "=== SignalK Stack Doctor ==="
check "signalk-server"  "$SIGNALK_URL"
check "updater (:3003)" "$UPDATER_URL/api/health"
check "doctor (:3004)"  "$DOCTOR_URL/api/health"

echo
echo "=== systemd-user units ==="
systemctl --user --no-pager list-units --all 'signalk-*' 2>/dev/null || true

echo
echo "=== Container snapshot ==="
podman ps -a --filter 'name=signalk-' --format '{{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true

# Root storage type. Twin of the doctor container's storage-type probe (CC-3),
# but reads the host's real /proc + /sys directly so it works with zero
# containers running. microSD I/O stalls are the usual cause of slow health
# responses; flag it and point at the SSD fix.
echo
echo "=== Host root storage ==="
root_storage() {
    local dev base rot
    dev=$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null)
    if [[ -z "$dev" || "$dev" != /dev/* ]]; then
        echo "  could not determine root device"
        return
    fi
    base=${dev#/dev/}
    case "$base" in
        # Partitioned mmcblk/nvme: strip the pN suffix, keep the device index
        # (mmcblk0p2 -> mmcblk0, nvme0n1p2 -> nvme0n1). A bare mmcblk0/nvme0n1
        # (root on the whole device) matches neither arm and is left intact.
        mmcblk*p[0-9]* | nvme*n[0-9]*p[0-9]*) base=${base%p[0-9]*} ;;
        # Traditional disks only — strip trailing partition digits. Scoped so
        # it can't over-strip a bare nvme/mmc device number.
        sd*[0-9] | hd*[0-9] | vd*[0-9] | xvd*[0-9]) base=${base%%[0-9]*} ;;
    esac
    rot=$(cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo "?")
    case "$base" in
        mmcblk*)
            echo "  [WARN] root on SD card ($base) — microSD I/O stalls cause slow"
            echo "         health/probe responses; a USB3/NVMe SSD removes them"
            ;;
        nvme*)
            echo "  [OK]   root on $base (NVMe SSD)" ;;
        *)
            if [[ "$rot" == "0" ]]; then
                echo "  [OK]   root on $base (SSD/flash)"
            elif [[ "$rot" == "1" ]]; then
                echo "  [OK]   root on $base (spinning disk)"
            else
                echo "  [OK]   root on $base"
            fi
            ;;
    esac
}
root_storage

echo
echo "For deeper diagnostics:"
echo "  curl -fsS $DOCTOR_URL/api/probes | jq ."
echo "  ~/.local/bin/signalk-recovery doctor"
