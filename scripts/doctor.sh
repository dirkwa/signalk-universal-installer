#!/usr/bin/env bash
# Post-install standalone health check. Probes the running stack without
# touching it. Safe to run any time. Mirrors the doctor container's probes
# at a coarser granularity — the container's /api/probes endpoint is the
# real diagnostic surface.

set -euo pipefail

UPDATER_URL=${UPDATER_URL:-http://127.0.0.1:3003}
DOCTOR_URL=${DOCTOR_URL:-http://127.0.0.1:3004}
SIGNALK_URL=${SIGNALK_URL:-http://127.0.0.1:3000/signalk}

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

echo
echo "For deeper diagnostics:"
echo "  curl -fsS $DOCTOR_URL/api/probes | jq ."
echo "  ~/.local/bin/signalk-recovery doctor"
