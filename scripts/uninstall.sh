#!/usr/bin/env bash
# Uninstall: stop services, remove Quadlets and containers.
# PRESERVES user data (~/.signalk, ~/.signalk-backup/kopia-repo, hardware
# config). To purge those, remove the directories manually.

set -euo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
# signalk-dbus-proxy is conditional (only on hosts with a system D-Bus);
# all loops below tolerate a missing unit/quadlet/container.
UNITS=(signalk-server signalk-updater-server signalk-doctor-server signalk-dbus-proxy)

# Checked before anything stops: `signalk kiosk disable` deletes the kiosk's
# Signal K user through the server. KIOSK_ROOT is a test hook.
if [[ -f "${KIOSK_ROOT:-}/etc/systemd/system/signalk-kiosk.service" ]]; then
    echo "[ERR] The kiosk is enabled. Run 'signalk kiosk disable --purge' first, while" >&2
    echo "      the server still runs: it deletes the kiosk's Signal K user through it." >&2
    echo "      Then run this uninstaller again." >&2
    exit 1
fi

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

# The power units the installer wrote (install.sh step 17e), and the polkit
# rule that lets this account power off: removed without a password prompt
# when sudo allows it, otherwise listed under "Preserved" below.
if ! rm -f "${HOME}/.config/systemd/user/signalk-poweroff.service" \
    "${HOME}/.config/systemd/user/signalk-reboot.service"; then
    echo "[WARN] Could not remove the power off / reboot user units." >&2
fi
POWER_RULE=/etc/polkit-1/rules.d/50-signalk-power.rules
# Debian's rules.d is root:polkitd 0750: this account cannot see the rule
# there, so an unreadable directory counts as "the rule may exist".
if [[ -e "$POWER_RULE" ]] || [[ -d "${POWER_RULE%/*}" && ! -x "${POWER_RULE%/*}" ]] \
    || sudo -n test -e "$POWER_RULE" 2>/dev/null; then
    if sudo -n rm -f "$POWER_RULE" 2>/dev/null; then
        echo "Removed the power off / reboot polkit rule."
    else
        echo "[WARN] $POWER_RULE may still let $(id -un) power off and reboot" >&2
        echo "       this computer; remove it with sudo (see below)." >&2
    fi
fi

# The unit that stops the plugin containers at shutdown (install.sh step 17f).
# Stopping it runs its ExecStop, which stops the sk-* containers.
CONTAINER_STOP_UNIT=/etc/systemd/system/signalk-container-stop.service
if [[ -e "$CONTAINER_STOP_UNIT" ]]; then
    if sudo -n systemctl disable --now signalk-container-stop.service 2>/dev/null \
        && sudo -n rm -f "$CONTAINER_STOP_UNIT" 2>/dev/null \
        && sudo -n systemctl daemon-reload 2>/dev/null; then
        echo "Removed signalk-container-stop.service."
    else
        echo "[WARN] Could not remove $CONTAINER_STOP_UNIT; remove it with sudo (see below)." >&2
    fi
fi

# The app.slice CPUWeight drop-in the installer wrote. Deleting the file
# alone leaves the running slice at 300 until re-login (systemd does not
# write the default back), so also reset the live value.
CPU_PRIORITY_CONF="${HOME}/.config/systemd/user/app.slice.d/50-signalk-cpu-priority.conf"
if [[ -f "$CPU_PRIORITY_CONF" ]]; then
    echo "Removing app.slice CPU priority drop-in..."
    rm -f "$CPU_PRIORITY_CONF"
    rmdir "$(dirname "$CPU_PRIORITY_CONF")" 2>/dev/null || true
    systemctl --user set-property --runtime app.slice CPUWeight=100 2>/dev/null || true
fi

systemctl --user daemon-reload || true

echo
echo "Preserved (intentional):"
echo "  ~/.signalk/                — SignalK configs + plugins"
echo "  ~/.signalk-updater/        — Tokens, hardware.json"
echo "  ~/.signalk-doctor/         — Snapshots, last-good.json"
echo "  ~/.signalk-backup/         — Backup repo (if present)"
echo "  ~/.local/bin/signalk-recovery — Host recovery script"
echo "  ~/.local/bin/signalk-{socketcan,bluetooth,kiosk} — hardware helpers"
echo "  signalk-timesync (system timer)   — disable: sudo systemctl disable --now signalk-timesync.timer"
echo "  power off/reboot polkit rule (if the warning above showed) — remove: sudo rm /etc/polkit-1/rules.d/50-signalk-power.rules"
echo "  signalk-container-stop.service (if the warning above showed) — remove: sudo systemctl disable --now signalk-container-stop.service && sudo rm /etc/systemd/system/signalk-container-stop.service"
echo
echo "To purge ALL data, run:  rm -rf ~/.signalk ~/.signalk-updater ~/.signalk-doctor ~/.signalk-backup"
echo "Done."
