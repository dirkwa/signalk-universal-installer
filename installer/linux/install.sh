#!/usr/bin/env bash
# SignalK Universal Installer (v2) — Linux bootstrap.
#
# One-shot installer. After it finishes, systemd-user owns the runtime
# and the updater container takes over signalk-server's lifecycle. The
# installer never runs continuously.
#
# Steps (idempotent; safe to re-run after partial failures):
#   1. Detect distro + arch + sanity-check the host
#   2. Pre-flight checks (RAM, disk, ports, cgroups v2, podman, linger, legacy)
#   3. Install podman if absent
#   4. Enable linger
#   5. Ensure group memberships (dialout, gpio, netdev)
#   6. Generate auth tokens for updater and doctor
#   7. Initialize ~/.signalk-doctor/{snapshots,last-good.json}
#   8. Detect hardware → ~/.signalk-updater/hardware.json
#   9. Pull all three images
#  10. Render and atomic-write three Quadlets
#  11. systemctl --user daemon-reload
#  12. Start doctor + updater services
#  13. Wait for doctor + updater health
#  14. Ask the updater to start signalk-server (with systemctl fallback)
#  15. Wait for signalk-server health
#  16. Install ~/.local/bin/signalk-recovery
#  17. Journald drop-in (sudo)
#  18. Mark bootstrap-complete in last-good.json
#  19. Print success URLs

INSTALLER_VERSION="${INSTALLER_VERSION:-v0.1.0-9-g583b4ed}"
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-https://dirkwa.github.io/signalk-universal-installer}"

# Where the engine container HTTP servers bind. Default localhost-only;
# set SIGNALK_LAN_EXPOSE=true (or 1/yes) to bind 0.0.0.0 so the Updater
# Console (:3003) and Doctor Console (:3004) are reachable from the LAN.
# Bearer-token auth (CC-2) still gates mutating endpoints. Re-running
# the installer without the flag reverts to localhost.
case "${SIGNALK_LAN_EXPOSE:-}" in
    true | TRUE | True | 1 | yes | YES | Yes) PUBLISH_HOST="0.0.0.0" ;;
    *) PUBLISH_HOST="127.0.0.1" ;;
esac
export PUBLISH_HOST

set -euo pipefail

# Resolve own location. When invoked as `curl ... | bash`, BASH_SOURCE[0]
# is empty and we're running from stdin — none of the adjacent lib/
# scripts or sibling Quadlet templates are on disk. In that case, fetch
# them into a tempdir from INSTALLER_BASE_URL and re-exec ourselves.
if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]:-/dev/null}" ]]; then
    TMP=$(mktemp -d -t signalk-installer.XXXXXX)
    trap 'rm -rf "$TMP"' EXIT
    echo "[i] Fetching installer tree from ${INSTALLER_BASE_URL}"
    for f in \
        installer/linux/install.sh \
        installer/linux/preflight.sh \
        installer/linux/detect-hardware.sh \
        installer/linux/render-server-quadlet.sh \
        installer/linux/install-recovery-script.sh \
        installer/linux/legacy-cleanup.sh \
        installer/linux/lib/colors.sh \
        installer/linux/lib/distro.sh \
        installer/linux/lib/http.sh \
        quadlets/signalk-server.container.template \
        quadlets/signalk-updater-server.container.template \
        quadlets/signalk-doctor-server.container.template; do
        mkdir -p "$TMP/$(dirname "$f")"
        if ! curl -fsSL "${INSTALLER_BASE_URL}/${f}" -o "$TMP/$f"; then
            echo "[ERR] Failed to fetch ${INSTALLER_BASE_URL}/${f}" >&2
            exit 1
        fi
    done
    chmod +x "$TMP/installer/linux/"*.sh
    chmod +x "$TMP/installer/linux/lib/"*.sh 2>/dev/null || true
    exec env \
        INSTALLER_VERSION="$INSTALLER_VERSION" \
        INSTALLER_BASE_URL="$INSTALLER_BASE_URL" \
        SIGNALK_LAN_EXPOSE="${SIGNALK_LAN_EXPOSE:-}" \
        bash "$TMP/installer/linux/install.sh" "$@"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"
# shellcheck disable=SC1091
. "$HERE/lib/http.sh"

REPO_OWNER=${REPO_OWNER:-dirkwa}
SK_IMAGE=${SK_IMAGE:-ghcr.io/${REPO_OWNER}/signalk-server:latest}
UPDATER_IMAGE=${UPDATER_IMAGE:-ghcr.io/${REPO_OWNER}/signalk-updater-server:latest}
DOCTOR_IMAGE=${DOCTOR_IMAGE:-ghcr.io/${REPO_OWNER}/signalk-doctor-server:latest}

QUADLET_DIR="${HOME}/.config/containers/systemd"
UPDATER_DATA="${HOME}/.signalk-updater"
DOCTOR_DATA="${HOME}/.signalk-doctor"

UPDATER_URL="http://127.0.0.1:3003"
DOCTOR_URL="http://127.0.0.1:3004"
SIGNALK_URL="http://127.0.0.1:3000/signalk"

# 1. Detect host
detect_os
section "SignalK Universal Installer v${INSTALLER_VERSION}"
info "Host: ${DISTRO_PRETTY} (${ARCH_NORM})"
if [[ "$PUBLISH_HOST" = "0.0.0.0" ]]; then
    warn "SIGNALK_LAN_EXPOSE=true: Updater + Doctor consoles will bind 0.0.0.0 (LAN-reachable)"
else
    info "Port bind: localhost only (set SIGNALK_LAN_EXPOSE=true to expose on LAN)"
fi

# 2. Pre-flight
section "Pre-flight"
bash "$HERE/preflight.sh"

# 3. Install podman if absent
section "Podman"
if ! command -v podman >/dev/null 2>&1; then
    info "Installing podman + uidmap + slirp4netns (requires sudo)"
    sudo apt-get update
    sudo apt-get install -y podman uidmap slirp4netns
fi
ok "$(podman --version)"

# 4. Linger
section "systemd-user linger"
if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
    info "Enabling linger for $USER (requires sudo)"
    sudo loginctl enable-linger "$USER"
fi
ok "linger enabled"

# Re-establish XDG_RUNTIME_DIR if linger was just enabled; the user-bus
# socket may not exist until the next login otherwise. Defensive nudge:
systemctl --user daemon-reload || true

# 5. Groups
section "Group memberships"
for g in dialout gpio netdev; do
    if getent group "$g" >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
        info "Adding $USER to $g (requires sudo)"
        sudo usermod -aG "$g" "$USER" || warn "could not add $USER to $g"
    fi
done
ok "groups: dialout, gpio, netdev (ensured if present on host)"

# 6. Tokens
section "Authentication tokens"
mkdir -p "$UPDATER_DATA" "$DOCTOR_DATA"
for path in "$UPDATER_DATA/token" "$DOCTOR_DATA/token"; do
    if [[ ! -f "$path" ]]; then
        umask 077
        openssl rand -base64 32 | tr -d '\n' >"$path"
        chmod 0600 "$path"
        ok "generated $path"
    else
        ok "preserved existing $path"
    fi
done

# 7. Doctor state init
section "Recovery state"
mkdir -p "$DOCTOR_DATA/snapshots"
if [[ ! -f "$DOCTOR_DATA/last-good.json" ]]; then
    echo '{"updatedAt":null,"quadlets":{}}' >"$DOCTOR_DATA/last-good.json"
fi
ok "snapshots dir and last-good.json present"

# 8. Hardware detection
section "Hardware detection"
"$HERE/detect-hardware.sh" >"$UPDATER_DATA/hardware.json"
ok "wrote $UPDATER_DATA/hardware.json"

# 9. Pull images
section "Image pulls"
for img in "$SK_IMAGE" "$UPDATER_IMAGE" "$DOCTOR_IMAGE"; do
    info "pulling $img"
    podman pull "$img"
done
ok "all images pulled"

# 10. Quadlet rendering
section "Quadlet rendering"
mkdir -p "$QUADLET_DIR"

snapshot_existing() {
    local name=$1
    local src="$QUADLET_DIR/$name"
    [[ -f "$src" ]] || return 0
    local ts
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    cp -p "$src" "$DOCTOR_DATA/snapshots/${ts}-${name}"
}

atomic_write() {
    local target=$1
    local body=$2
    local tmp
    tmp=$(mktemp "${target}.XXXXXX")
    printf '%s\n' "$body" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

snapshot_existing signalk-server.container
snapshot_existing signalk-updater-server.container
snapshot_existing signalk-doctor-server.container

SERVER_QUADLET=$("$HERE/render-server-quadlet.sh" "$UPDATER_DATA/hardware.json" "$HERE/../../quadlets/signalk-server.container.template")
atomic_write "$QUADLET_DIR/signalk-server.container" "$SERVER_QUADLET"

UPDATER_QUADLET=$(sed "s/__PUBLISH_HOST__/${PUBLISH_HOST}/g" "$HERE/../../quadlets/signalk-updater-server.container.template")
atomic_write "$QUADLET_DIR/signalk-updater-server.container" "$UPDATER_QUADLET"

DOCTOR_QUADLET=$(sed "s/__PUBLISH_HOST__/${PUBLISH_HOST}/g" "$HERE/../../quadlets/signalk-doctor-server.container.template")
atomic_write "$QUADLET_DIR/signalk-doctor-server.container" "$DOCTOR_QUADLET"

ok "Quadlets written to $QUADLET_DIR"

# 11. daemon-reload
section "systemd-user daemon-reload"
systemctl --user daemon-reload
ok "daemon-reload OK"

# 12. Start doctor + updater
section "Starting peer containers"
systemctl --user start signalk-doctor-server.service
systemctl --user start signalk-updater-server.service
ok "doctor and updater units started"

# 13. Wait for health (first-boot tolerant per R1.3)
section "Health checks"
if wait_for_http "${DOCTOR_URL}/api/health" 180; then
    ok "doctor responding on ${DOCTOR_URL}"
else
    warn "doctor did not respond within 180s; check 'journalctl --user -u signalk-doctor-server.service'"
fi
if wait_for_http "${UPDATER_URL}/api/health" 180; then
    ok "updater responding on ${UPDATER_URL}"
else
    warn "updater did not respond within 180s; check 'journalctl --user -u signalk-updater-server.service'"
fi

# 13.5 Install (or update) the bundled SignalK plugins into ~/.signalk/.
# These plugins live in the user's data dir, not the signalk-server image —
# same as anything installed via the SignalK appstore. After the first install
# the appstore is the source of truth for updates; we just lay them down on
# day one so the admin UI has the Updater / Doctor consoles immediately.
#
# We use the signalk-server container's own bundled npm so the host doesn't
# need a Node toolchain. --ignore-scripts matches the appstore's install
# posture (some plugins try to compile native bindings that fail silently).
section "Installing SignalK plugins"
SK_PLUGINS=(signalk-container signalk-updater signalk-doctor)
mkdir -p "$HOME/.signalk"

info "running 'npm install' inside the signalk-server image"
if podman run --rm \
    --userns=keep-id \
    -v "$HOME/.signalk:/home/node/.signalk:Z" \
    --entrypoint sh \
    "$SK_IMAGE" \
    -c "cd /home/node/.signalk && npm install --ignore-scripts --no-audit --no-fund --no-progress ${SK_PLUGINS[*]}" >/dev/null 2>&1; then
    for p in "${SK_PLUGINS[@]}"; do
        if [[ -d "$HOME/.signalk/node_modules/$p" ]]; then
            v=$(grep -m1 '"version"' "$HOME/.signalk/node_modules/$p/package.json" 2>/dev/null \
                | sed 's/.*"\([0-9][^"]*\)".*/\1/')
            ok "$p@${v:-?}"
        else
            warn "$p — install reported ok but module dir is missing"
        fi
    done
else
    warn "npm install failed; plugins not installed. Install from the SignalK appstore later."
fi

# Auto-enable each plugin (one-time on first install). If a config file
# already exists we leave the user's settings alone — they may have
# deliberately disabled a plugin and re-running the installer should not
# override that.
mkdir -p "$HOME/.signalk/plugin-config-data"
for p in "${SK_PLUGINS[@]}"; do
    # signalk-container is auto-enabled by its own metadata
    # (signalk-plugin-enabled-by-default: true); skip writing a config for it.
    [[ "$p" == "signalk-container" ]] && continue
    cfg="$HOME/.signalk/plugin-config-data/${p}.json"
    if [[ ! -f "$cfg" ]]; then
        printf '{\n  "enabled": true,\n  "configuration": {}\n}\n' >"$cfg"
        ok "auto-enabled $p"
    fi
done

# 14. Bring up signalk-server (prefer updater REST, fall back to systemctl).
# The updater may have JUST been restarted by the daemon-reload above and
# need a few seconds to settle dockerode against the podman socket — retry
# briefly before declaring REST broken.
section "Starting signalk-server"
UP_TOKEN=$(cat "$UPDATER_DATA/token" 2>/dev/null || echo "")
updater_rest_start() {
    local attempt
    for attempt in 1 2 3 4 5 6; do
        if curl -fsS -X POST \
            -H "Authorization: Bearer $UP_TOKEN" \
            "${UPDATER_URL}/api/signalk/start" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}
if [[ -n "$UP_TOKEN" ]]; then
    if updater_rest_start; then
        ok "updater started signalk-server"
    else
        warn "updater REST start failed; falling back to systemctl"
        systemctl --user start signalk-server.service
    fi
else
    warn "no updater token; using systemctl"
    systemctl --user start signalk-server.service
fi

# 15. Wait for signalk-server health
if wait_for_http "$SIGNALK_URL" 180; then
    ok "signalk-server responding on ${SIGNALK_URL}"
else
    warn "signalk-server did not respond within 180s"
    warn "open ${DOCTOR_URL} or run ~/.local/bin/signalk-recovery doctor"
fi

# 16. Recovery script
section "Host recovery script"
bash "$HERE/install-recovery-script.sh"

# 17. Journald limits (sudo)
section "Journald retention drop-in"
SUDO_OK=1
sudo -n true 2>/dev/null || SUDO_OK=0
if (( SUDO_OK )); then
    sudo install -d -m 0755 /etc/systemd/journald.conf.d
    sudo tee /etc/systemd/journald.conf.d/signalk.conf >/dev/null <<EOF
# Installed by signalk-universal-installer
[Journal]
SystemMaxUse=500M
MaxRetentionSec=14day
EOF
    sudo systemctl restart systemd-journald
    ok "journald limits applied"
else
    warn "sudo not available without prompt; skipping journald limits"
    warn "to apply later: see docs/recovery.md 'Journald retention'"
fi

# 18. Mark bootstrap-complete
section "Recording bootstrap state"
python3 - "$DOCTOR_DATA/last-good.json" <<'PY' 2>/dev/null || true
import json, sys, datetime
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    data = {"quadlets": {}}
data.setdefault("quadlets", {})
data["updatedAt"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
data["bootstrappedAt"] = data["updatedAt"]
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY

# 19. Success
if [[ "$PUBLISH_HOST" = "0.0.0.0" ]]; then
    LAN_NOTE="Updater + Doctor are reachable on the LAN. Use the host's LAN address."
else
    LAN_NOTE="Updater + Doctor are bound to localhost only. Run with SIGNALK_LAN_EXPOSE=true to expose on the LAN."
fi
cat <<EOF

${C_GREEN}${C_BOLD}OK — SignalK is up.${C_RESET}

  SignalK admin UI : http://localhost:3000
  Updater Console  : ${UPDATER_URL}
  Doctor Console   : ${DOCTOR_URL}
  Recovery script  : \$HOME/.local/bin/signalk-recovery

${LAN_NOTE}

Auth tokens are at:
  Updater : ${UPDATER_DATA}/token  (mode 0600)
  Doctor  : ${DOCTOR_DATA}/token   (mode 0600)

Next: install plugins from the SignalK appstore. To check stack health any time:
  ~/.local/bin/signalk-recovery status
EOF
