#!/usr/bin/env bash
# Drops ~/.local/bin/signalk — the user-facing command dispatcher.
# Wraps health, uninstall, bug-report, and recovery so operators don't
# have to remember the four script paths. ~/.local/bin/signalk-recovery
# is still installed as the SSH-only safety net (CC-3) and is the
# delegation target for `signalk recover`.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk"
mkdir -p "$BIN_DIR"

# Embed the installer-version string so `signalk version` reports
# something useful. Caller (install.sh) exports INSTALLER_VERSION.
SK_VERSION="${INSTALLER_VERSION:-unknown}"

cat >"$TARGET" <<SIGNALK_DISPATCHER_EOF
#!/usr/bin/env bash
# signalk — user-facing dispatcher for the SignalK container stack.
# Installed by signalk-universal-installer.
#
# Usage:
#   signalk health         show stack health (containers, services, URLs)
#   signalk recover [...]  delegate to ~/.local/bin/signalk-recovery
#   signalk bug-report     bundle logs + state into /tmp/signalk-bug-report-*.tar.gz
#   signalk uninstall      stop services + remove Quadlets (preserves data)
#   signalk version        print installer version
#   signalk help           show this help

set -euo pipefail

SK_VERSION="${SK_VERSION}"

UPDATER_URL=\${UPDATER_URL:-http://127.0.0.1:3003}
DOCTOR_URL=\${DOCTOR_URL:-http://127.0.0.1:3004}
SIGNALK_URL=\${SIGNALK_URL:-http://127.0.0.1:3000/signalk}
QUADLET_DIR="\${HOME}/.config/containers/systemd"
UNITS=(signalk-server signalk-updater-server signalk-doctor-server)

usage() {
    sed -n '2,11p' "\$0" | sed 's/^# \\{0,1\\}//'
}

cmd_version() {
    echo "signalk \$SK_VERSION"
}

cmd_health() {
    echo "=== SignalK Stack Health ==="
    for entry in \\
        "signalk-server  \$SIGNALK_URL" \\
        "updater (:3003) \$UPDATER_URL/api/health" \\
        "doctor (:3004)  \$DOCTOR_URL/api/health"; do
        name=\${entry% *}
        url=\${entry##* }
        if curl -fsS -o /dev/null -m 5 "\$url"; then
            printf '  [OK]   %-20s %s\\n' "\$name" "\$url"
        else
            printf '  [FAIL] %-20s %s\\n' "\$name" "\$url"
        fi
    done

    echo
    echo "=== systemd-user units ==="
    systemctl --user --no-pager list-units --all 'signalk-*' 2>/dev/null || true

    echo
    echo "=== Container snapshot ==="
    podman ps -a --filter 'name=signalk-' \\
        --format '{{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true

    echo
    echo "For deeper diagnostics:"
    echo "  curl -fsS \$DOCTOR_URL/api/probes | jq ."
    echo "  signalk recover doctor"
}

cmd_recover() {
    if [[ ! -x "\$HOME/.local/bin/signalk-recovery" ]]; then
        echo "[ERR] ~/.local/bin/signalk-recovery is missing; reinstall the stack" >&2
        exit 1
    fi
    exec "\$HOME/.local/bin/signalk-recovery" "\$@"
}

cmd_uninstall() {
    echo "Stopping signalk-* units..."
    for u in "\${UNITS[@]}"; do
        systemctl --user stop "\${u}.service" 2>/dev/null || true
    done

    echo "Removing Quadlet files..."
    for u in "\${UNITS[@]}"; do
        rm -f "\$QUADLET_DIR/\${u}.container"
    done

    echo "Removing podman containers..."
    for u in "\${UNITS[@]}"; do
        if podman container exists "\$u" 2>/dev/null; then
            podman rm -f "\$u" 2>/dev/null || true
        fi
    done

    systemctl --user daemon-reload || true

    echo
    echo "Preserved (intentional):"
    echo "  ~/.signalk/                — SignalK configs + plugins"
    echo "  ~/.signalk-updater/        — Tokens, hardware.json"
    echo "  ~/.signalk-doctor/         — Snapshots, last-good.json"
    echo "  ~/.signalk-backup/         — Backup repo (if present)"
    echo "  ~/.local/bin/signalk-recovery — Host recovery script"
    echo "  ~/.local/bin/signalk       — This command"
    echo
    echo "To purge ALL data, run:"
    echo "  rm -rf ~/.signalk ~/.signalk-updater ~/.signalk-doctor ~/.signalk-backup"
    echo "  rm -f  ~/.local/bin/signalk ~/.local/bin/signalk-recovery"
    echo "Done."
}

cmd_bug_report() {
    local stamp
    stamp=\$(date -u +%Y%m%dT%H%M%SZ)
    local outdir
    outdir=\$(mktemp -d -t signalk-bug-report.XXXXXX)
    local bundle="\$outdir/signalk-bug-report-\$stamp"
    mkdir -p "\$bundle"

    echo "[i] Collecting diagnostics into \$bundle"

    # Host context.
    {
        echo "=== signalk version ==="
        echo "installer: \$SK_VERSION"
        echo
        echo "=== uname -a ==="
        uname -a 2>&1 || true
        echo
        echo "=== /etc/os-release ==="
        cat /etc/os-release 2>&1 || true
        echo
        echo "=== date ==="
        date -u 2>&1 || true
        echo
        echo "=== uptime ==="
        uptime 2>&1 || true
    } >"\$bundle/host.txt" 2>&1

    # Container runtime.
    {
        echo "=== podman --version ==="
        podman --version 2>&1 || true
        echo
        echo "=== podman info ==="
        podman info 2>&1 || true
        echo
        echo "=== podman ps -a (signalk-) ==="
        podman ps -a --filter 'name=signalk-' \\
            --format '{{.Names}}\\t{{.Status}}\\t{{.Image}}' 2>&1 || true
        echo
        echo "=== podman images (signalk + dirkwa) ==="
        podman images --format '{{.Repository}}:{{.Tag}}\\t{{.ID}}\\t{{.Created}}' \\
            2>&1 | grep -E 'signalk|dirkwa' || true
        echo
        echo "=== docker --version (if shim) ==="
        docker --version 2>&1 || true
    } >"\$bundle/runtime.txt" 2>&1

    # systemd-user state.
    {
        echo "=== systemctl --user list-unit-files signalk-* ==="
        systemctl --user list-unit-files 'signalk-*' 2>&1 || true
        echo
        echo "=== systemctl --user list-units signalk-* (incl. inactive) ==="
        systemctl --user list-units --all 'signalk-*' 2>&1 || true
        echo
        echo "=== loginctl show-user (Linger) ==="
        loginctl show-user "\$USER" -p Linger 2>&1 || true
    } >"\$bundle/systemd.txt" 2>&1

    # Journal — last 24h per unit. Truncate aggressively; logs are noisy.
    for u in "\${UNITS[@]}"; do
        journalctl --user -u "\${u}.service" --since '24 hours ago' --no-pager \\
            >"\$bundle/journal-\${u}.log" 2>&1 || true
    done

    # Quadlet sources (config, not secrets).
    mkdir -p "\$bundle/quadlets"
    for u in "\${UNITS[@]}"; do
        if [[ -f "\$QUADLET_DIR/\${u}.container" ]]; then
            cp "\$QUADLET_DIR/\${u}.container" "\$bundle/quadlets/\${u}.container"
        fi
    done

    # Doctor snapshots index (file listing only — snapshot contents
    # could be large and contain the same Quadlets we already copied).
    {
        echo "=== last-good.json ==="
        cat "\$HOME/.signalk-doctor/last-good.json" 2>&1 || true
        echo
        echo "=== snapshot file listing ==="
        ls -la "\$HOME/.signalk-doctor/snapshots/" 2>&1 || true
    } >"\$bundle/doctor-state.txt" 2>&1

    # Token presence — NEVER the value.
    {
        for f in "\$HOME/.signalk-updater/token" "\$HOME/.signalk-doctor/token"; do
            if [[ -f "\$f" ]]; then
                local mode
                mode=\$(stat -c '%a' "\$f" 2>/dev/null || echo "?")
                printf '%s — present, mode %s\\n' "\$f" "\$mode"
            else
                printf '%s — MISSING\\n' "\$f"
            fi
        done
    } >"\$bundle/tokens.txt" 2>&1

    # Console health.
    {
        for entry in \\
            "signalk-server  \$SIGNALK_URL" \\
            "updater (:3003) \$UPDATER_URL/api/health" \\
            "doctor (:3004)  \$DOCTOR_URL/api/health"; do
            name=\${entry% *}
            url=\${entry##* }
            echo "--- \$name (\$url) ---"
            curl -fsS -m 5 "\$url" 2>&1 || echo "(unreachable)"
            echo
        done
    } >"\$bundle/console-health.txt" 2>&1

    # Hardware detection (non-secret).
    if [[ -f "\$HOME/.signalk-updater/hardware.json" ]]; then
        cp "\$HOME/.signalk-updater/hardware.json" "\$bundle/hardware.json"
    fi

    # Container storage state — surfaces ZFS/idmap hazards.
    {
        echo "=== rootless storage path ==="
        echo "\${XDG_DATA_HOME:-\$HOME/.local/share}/containers/storage"
        echo
        echo "=== stat -f -c %T ==="
        stat -f -c '%T' "\${XDG_DATA_HOME:-\$HOME/.local/share}/containers/storage" 2>&1 || true
        echo
        echo "=== ~/.config/containers/storage.conf ==="
        cat "\${XDG_CONFIG_HOME:-\$HOME/.config}/containers/storage.conf" 2>&1 || echo "(absent — using podman defaults)"
        echo
        echo "=== /proc/cmdline ==="
        cat /proc/cmdline 2>&1 || true
        echo
        echo "=== /sys/fs/cgroup/cgroup.controllers ==="
        cat /sys/fs/cgroup/cgroup.controllers 2>&1 || true
    } >"\$bundle/storage-and-cgroup.txt" 2>&1

    # Tar it up.
    local tarball="/tmp/signalk-bug-report-\$stamp.tar.gz"
    tar -C "\$outdir" -czf "\$tarball" "signalk-bug-report-\$stamp"
    rm -rf "\$outdir"

    echo
    echo "[OK] Bundle ready:"
    echo "  \$tarball"
    echo
    echo "Attach this file to a GitHub issue at:"
    echo "  https://github.com/dirkwa/signalk-universal-installer/issues"
    echo
    echo "Contents are limited to host metadata, container state, and recent journals."
    echo "Tokens are reported as presence-only (mode + 'present'); their values are NEVER included."
}

case "\${1:-help}" in
    health)     cmd_health ;;
    recover)    shift; cmd_recover "\$@" ;;
    bug-report) cmd_bug_report ;;
    uninstall)  cmd_uninstall ;;
    version|--version|-v) cmd_version ;;
    help|--help|-h) usage ;;
    *)
        echo "[ERR] Unknown command: \$1" >&2
        usage
        exit 1
        ;;
esac
SIGNALK_DISPATCHER_EOF

chmod 0755 "$TARGET"
ok "Installed $TARGET"
