#!/usr/bin/env bash
# Uninstall: stop services, remove Quadlets and containers.
# PRESERVES user data (~/.signalk, ~/.signalk-backup/kopia-repo, hardware
# config). To purge those, remove the directories manually.

set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
UNITS=(signalk-server signalk-updater-server signalk-doctor-server)

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
    podman container exists "$u" 2>/dev/null && podman rm -f "$u" 2>/dev/null || true
done

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
