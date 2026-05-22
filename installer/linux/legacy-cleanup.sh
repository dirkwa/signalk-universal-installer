#!/usr/bin/env bash
# Removes systemd user units left over from the v1 (Keeper-based) installer.
# Preserves user data (~/.signalk, ~/.signalk-backup/kopia-repo).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

LEGACY_UNITS=(
    signalk-keeper
    signalk-keeper.network
    signalk-caddy
    signalk-kopia
    signalk-grafana
    signalk-influxdb
)

LEGACY_FILES=(
    "${HOME}/.config/containers/systemd/signalk-keeper.container"
    "${HOME}/.config/containers/systemd/signalk-keeper.network"
    "${HOME}/.config/containers/systemd/signalk-caddy.container"
    "${HOME}/.config/containers/systemd/signalk-kopia.container"
)

section "Stopping legacy units"
for u in "${LEGACY_UNITS[@]}"; do
    if systemctl --user list-units --all "${u}.service" 2>/dev/null | grep -q "${u}.service"; then
        systemctl --user stop "${u}.service" 2>/dev/null || true
        ok "stopped ${u}.service"
    fi
done

section "Removing legacy Quadlet files"
for f in "${LEGACY_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        ok "removed $f"
    fi
done

section "Removing legacy podman containers (if any)"
for u in "${LEGACY_UNITS[@]}"; do
    if podman container exists "$u" 2>/dev/null; then
        podman rm -f "$u" 2>/dev/null || true
        ok "removed container $u"
    fi
done

section "Reloading systemd-user"
systemctl --user daemon-reload || true

cat <<EOF

Preserved (intentional):
  - ${HOME}/.signalk/                  (SignalK config + plugins)
  - ${HOME}/.signalk-backup/           (backup state, if present)

If you want to start fully clean, remove those directories manually.
EOF
ok "Legacy cleanup complete. You can now run install.sh."
