#!/usr/bin/env bash
# Uninstall: stop services, remove Quadlets and containers.
# PRESERVES user data (~/.signalk, ~/.signalk-backup/kopia-repo, hardware
# config). To purge those, remove the directories manually.

set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
# signalk-dbus-proxy is conditional (only on hosts with a system D-Bus);
# all loops below tolerate a missing unit/quadlet/container.
UNITS=(signalk-server signalk-updater-server signalk-doctor-server signalk-dbus-proxy)

echo "Stopping signalk-* units..."
for u in "${UNITS[@]}"; do
    systemctl --user stop "${u}.service" 2>/dev/null || true
done

echo "Removing Quadlet files..."
for u in "${UNITS[@]}"; do
    rm -f "$QUADLET_DIR/${u}.container"
done

echo "Removing podman containers..."
for u in "${UNITS[@]}"; do
    if podman container exists "$u" 2>/dev/null; then
        podman rm -f "$u" 2>/dev/null || true
    fi
done

# The dbus proxy's socket volume holds no data worth preserving —
# it only ever contains the proxy's unix socket.
podman volume rm signalk-dbus-socket 2>/dev/null || true

systemctl --user daemon-reload || true

echo
echo "Preserved (intentional):"
echo "  ~/.signalk/                — SignalK configs + plugins"
echo "  ~/.signalk-updater/        — Tokens, hardware.json"
echo "  ~/.signalk-doctor/         — Snapshots, last-good.json"
echo "  ~/.signalk-backup/         — Backup repo (if present)"
echo "  ~/.local/bin/signalk-recovery — Host recovery script"
echo
echo "To purge ALL data, run:  rm -rf ~/.signalk ~/.signalk-updater ~/.signalk-doctor ~/.signalk-backup"
echo "Done."
