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
#   3b. Switch rootless storage driver to fuse-overlayfs when on ZFS
#   4. Enable linger
#   4b. Enable user podman.socket (engine containers bind-mount it)
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
#  16b. Install ~/.local/bin/signalk (CLI dispatcher: health/recover/bug-report/uninstall)
#  17. Journald drop-in (sudo)
#  18. Mark bootstrap-complete in last-good.json
#  18b. (re-runs only) Verification pass: report healthy/broken checkpoints
#  19. Print success URLs

INSTALLER_VERSION="${INSTALLER_VERSION:-0.0.0-scaffold}"
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-https://dirkwa.github.io/signalk-universal-installer}"

# Where the engine container HTTP servers bind. Default is LAN-reachable
# (0.0.0.0) because most users install headless and reach the consoles
# from another machine. Set SIGNALK_LOCALHOST_ONLY=true (or 1/yes) to
# bind 127.0.0.1 only. Bearer-token auth (CC-2) still gates the updater's
# mutating endpoints and the doctor's recovery endpoints; the doctor's
# read-only probes are unauthenticated by design (recovery surface that
# always answers).
#
# SIGNALK_LAN_EXPOSE is the previous opt-IN variable (default was
# 127.0.0.1). Honoured for one release as a deprecation alias so existing
# automation keeps working: SIGNALK_LAN_EXPOSE=false now means "bind
# localhost only" — same effect as SIGNALK_LOCALHOST_ONLY=true.
PUBLISH_HOST="0.0.0.0"
case "${SIGNALK_LOCALHOST_ONLY:-}" in
    true | TRUE | True | 1 | yes | YES | Yes) PUBLISH_HOST="127.0.0.1" ;;
esac
case "${SIGNALK_LAN_EXPOSE:-}" in
    "") ;; # unset — no deprecation to flag
    false | FALSE | False | 0 | no | NO | No)
        PUBLISH_HOST="127.0.0.1"
        DEPRECATED_LAN_EXPOSE_SEEN=1
        ;;
    *)
        # truthy or any other set value — same effect as the new default,
        # but still flag the deprecation so operators update their automation.
        DEPRECATED_LAN_EXPOSE_SEEN=1
        ;;
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
        installer/linux/install-signalk-command.sh \
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
        SIGNALK_LOCALHOST_ONLY="${SIGNALK_LOCALHOST_ONLY:-}" \
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
if [[ "${DEPRECATED_LAN_EXPOSE_SEEN:-0}" = "1" ]]; then
    warn "SIGNALK_LAN_EXPOSE is deprecated — use SIGNALK_LOCALHOST_ONLY=true instead."
fi
if [[ "$PUBLISH_HOST" = "0.0.0.0" ]]; then
    info "Port bind: 0.0.0.0 (LAN-reachable). Doctor read-only probes are unauthenticated by design."
    info "Set SIGNALK_LOCALHOST_ONLY=true to restrict to localhost."
else
    info "Port bind: localhost only (SIGNALK_LOCALHOST_ONLY=true)"
fi

# Detect a previous successful install. install.sh's last step (#18)
# writes `bootstrappedAt` into ~/.signalk-doctor/last-good.json after
# every successful pass; presence of that key means at least one full
# bootstrap completed. We don't change the run sequence in that case —
# every step is already idempotent — but we DO add a verification pass
# at the end (step 18b) that reports what's healthy vs. still broken
# after the idempotent re-run, so the operator can tell whether issues
# were resolved.
VERIFY_MODE=0
if [[ -f "${DOCTOR_DATA}/last-good.json" ]] \
    && grep -q '"bootstrappedAt"' "${DOCTOR_DATA}/last-good.json" 2>/dev/null; then
    VERIFY_MODE=1
    info "Existing install detected — running in verify mode."
    info "Steps will be re-run idempotently; a summary at the end will tell you"
    info "what was already healthy, what got fixed, and what still needs attention."
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

# 3b. ZFS rootless-storage autofix.
#
# When rootless Podman's graphroot lives on ZFS the default `overlay`
# storage driver triggers Podman's per-file `storage-chown-by-maps`
# sweep on first `--userns=keep-id` use. CoW metadata makes that crawl
# for tens of minutes on real boats, and on some kernel/ZFS combos the
# gid_map write fails outright with `crun: writing file
# /proc/<pid>/gid_map: Invalid argument`. signalk-container's doctor
# documents the same situation post-install — we pre-empt it here by
# installing fuse-overlayfs and pointing podman's storage driver at it
# (virtual ownership stored in xattrs, no chown sweep).
section "Rootless storage driver"
STORAGE_FS=$(stat -f -c '%T' "${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage" 2>/dev/null \
    || stat -f -c '%T' "${XDG_DATA_HOME:-$HOME/.local/share}" 2>/dev/null \
    || stat -f -c '%T' "$HOME" 2>/dev/null \
    || echo "unknown")
if [[ "$STORAGE_FS" == "zfs" ]]; then
    info "Rootless storage on ZFS — switching to fuse-overlayfs"
    if ! command -v fuse-overlayfs >/dev/null 2>&1; then
        info "Installing fuse-overlayfs (requires sudo)"
        sudo apt-get install -y fuse-overlayfs
    fi
    STORAGE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/containers/storage.conf"
    mkdir -p "$(dirname "$STORAGE_CONF")"
    # Refuse to overwrite an existing storage.conf — operator may have
    # tuned it. Detect by content: if it already names fuse-overlayfs
    # as the mount_program we're done; otherwise leave it alone and
    # warn so the user knows the autofix didn't take effect.
    if [[ -f "$STORAGE_CONF" ]]; then
        if grep -q 'mount_program.*fuse-overlayfs' "$STORAGE_CONF"; then
            ok "storage.conf already points at fuse-overlayfs"
        else
            warn "Existing $STORAGE_CONF does not use fuse-overlayfs — leaving as-is."
            warn "If you hit slow image pulls or 'gid_map: Invalid argument' on first start,"
            warn "edit it to set [storage].driver=\"overlay\" and"
            warn "[storage.options.overlay].mount_program=\"/usr/bin/fuse-overlayfs\","
            warn "then run: podman system reset --force && podman system migrate"
        fi
    else
        # `podman system reset` is destructive if images/containers
        # already exist. The safe path is "only reset when storage is
        # empty"; on a clean install that's always the case.
        if [[ -n "$(podman images -q 2>/dev/null)" ]] || [[ -n "$(podman ps -aq 2>/dev/null)" ]]; then
            warn "Found existing podman images/containers — skipping driver switch to avoid data loss."
            warn "If first start is slow or fails on ZFS, manually run:"
            warn "  podman system reset --force && podman system migrate"
            warn "after writing $STORAGE_CONF (see docs/recovery.md)."
        else
            cat >"$STORAGE_CONF" <<'EOF'
# Written by signalk-universal-installer on ZFS hosts.
# Default `overlay` triggers chown-by-maps on --userns=keep-id; very
# slow on ZFS and on some kernels fails outright. fuse-overlayfs keeps
# virtual ownership in xattrs, no chown sweep.
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
            chmod 0644 "$STORAGE_CONF"
            # storage layout is empty: a reset is a no-op but migrate
            # picks up the new mount_program for any future pulls.
            podman system migrate >/dev/null 2>&1 || true
            ok "fuse-overlayfs configured in $STORAGE_CONF"
        fi
    fi
else
    ok "rootless storage on $STORAGE_FS (no driver switch needed)"
fi

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

# The rootless podman socket at $XDG_RUNTIME_DIR/podman/podman.sock is
# bind-mounted into all three engine containers (updater, doctor, and
# signalk-server itself — the signalk-container plugin reaches the host
# daemon via that mount). Without an enabled socket unit, the file
# doesn't exist when those containers start and `podman run -v ...`
# exits 125 with `statfs: no such file or directory`. Enabling
# activates it on user-bus startup; --now creates the socket
# immediately for the very first install.
if ! systemctl --user is-enabled --quiet podman.socket 2>/dev/null; then
    info "Enabling user podman.socket"
    systemctl --user enable --now podman.socket
fi
ok "podman.socket active"

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
    for _ in 1 2 3 4 5 6; do
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

# 16b. `signalk` command dispatcher
section "signalk command"
INSTALLER_VERSION="$INSTALLER_VERSION" bash "$HERE/install-signalk-command.sh"

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

# 18b. Verification pass (verify mode only).
#
# On re-runs, check the final state and build two lists: healthy and
# broken. We don't classify "fixed" because all 18 prior steps are
# idempotent and don't tell us whether they had to do work — we'd have
# to instrument every one to know. Instead, we trust that if a re-run
# leaves a checkpoint healthy, the install is effectively repaired; if
# a checkpoint is still broken after a full pass, that's what the
# operator needs to see.
#
# Suppressed on a first-run (VERIFY_MODE=0) to keep the success message
# clean; the URLs being printed already imply everything's up.
if [[ "$VERIFY_MODE" = "1" ]]; then
    section "Verification"
    VERIFY_HEALTHY=()
    VERIFY_BROKEN=()

    verify_check() {
        local label=$1 verdict=$2
        if [[ "$verdict" = "ok" ]]; then
            VERIFY_HEALTHY+=("$label")
        else
            VERIFY_BROKEN+=("$label — $verdict")
        fi
    }

    # podman present + version usable
    if command -v podman >/dev/null 2>&1; then
        verify_check "podman binary" "ok"
    else
        verify_check "podman binary" "missing"
    fi

    # podman.socket enabled (R8.3 / our PR #17)
    if systemctl --user is-enabled --quiet podman.socket 2>/dev/null; then
        verify_check "user podman.socket enabled" "ok"
    else
        verify_check "user podman.socket enabled" "not enabled; engine containers will fail on next boot"
    fi

    # linger
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        verify_check "systemd-user linger" "ok"
    else
        verify_check "systemd-user linger" "off; user-bus dies at logout"
    fi

    # Three Quadlets on disk
    for u in signalk-server signalk-updater-server signalk-doctor-server; do
        if [[ -f "$QUADLET_DIR/${u}.container" ]]; then
            verify_check "Quadlet ${u}.container" "ok"
        else
            verify_check "Quadlet ${u}.container" "missing from $QUADLET_DIR"
        fi
    done

    # Three services active
    for u in signalk-server signalk-updater-server signalk-doctor-server; do
        active=$(systemctl --user is-active "${u}.service" 2>/dev/null || true)
        if [[ "$active" = "active" ]]; then
            verify_check "${u}.service" "ok"
        else
            verify_check "${u}.service" "state=${active:-unknown}; check 'journalctl --user -u ${u}.service'"
        fi
    done

    # Both tokens present + mode 0600
    for f in "$UPDATER_DATA/token" "$DOCTOR_DATA/token"; do
        token_label="$(basename "$(dirname "$f")")/token"
        if [[ -f "$f" ]]; then
            mode=$(stat -c '%a' "$f" 2>/dev/null || echo "?")
            if [[ "$mode" = "600" ]]; then
                verify_check "$token_label" "ok"
            else
                verify_check "$token_label" "mode $mode (expected 600)"
            fi
        else
            verify_check "$token_label" "missing"
        fi
    done

    # Three URLs answering
    if curl -fsS -o /dev/null -m 5 "$UPDATER_URL/api/health" 2>/dev/null; then
        verify_check "updater health (:3003)" "ok"
    else
        verify_check "updater health (:3003)" "unreachable"
    fi
    if curl -fsS -o /dev/null -m 5 "$DOCTOR_URL/api/health" 2>/dev/null; then
        verify_check "doctor health (:3004)" "ok"
    else
        verify_check "doctor health (:3004)" "unreachable"
    fi
    if curl -fsS -o /dev/null -m 5 "$SIGNALK_URL" 2>/dev/null; then
        verify_check "signalk-server (:3000)" "ok"
    else
        verify_check "signalk-server (:3000)" "unreachable"
    fi

    # Summary.
    if (( ${#VERIFY_HEALTHY[@]} > 0 )); then
        echo
        for item in "${VERIFY_HEALTHY[@]}"; do
            ok "$item"
        done
    fi
    if (( ${#VERIFY_BROKEN[@]} > 0 )); then
        echo
        warn "Verification flagged ${#VERIFY_BROKEN[@]} item(s):"
        for item in "${VERIFY_BROKEN[@]}"; do
            warn "  - $item"
        done
        echo
        warn "Next steps:"
        warn "  signalk health           — quick re-check"
        warn "  signalk recover doctor   — full diagnostics dump"
        warn "  signalk bug-report       — bundle state for an issue"
    fi
fi

# 19. Success
if [[ "$PUBLISH_HOST" = "0.0.0.0" ]]; then
    LAN_NOTE="Updater + Doctor are reachable on the LAN. The doctor's read-only probes are unauthenticated by design (recovery surface); on shared/guest WiFi consider SIGNALK_LOCALHOST_ONLY=true."
else
    LAN_NOTE="Updater + Doctor are bound to localhost only. Unset SIGNALK_LOCALHOST_ONLY to expose on the LAN."
fi
if [[ "$VERIFY_MODE" = "1" ]] && (( ${#VERIFY_BROKEN[@]} > 0 )); then
    SUMMARY_HEADLINE="${C_BOLD}Re-run complete — verification flagged ${#VERIFY_BROKEN[@]} item(s) above.${C_RESET}"
elif [[ "$VERIFY_MODE" = "1" ]]; then
    SUMMARY_HEADLINE="${C_GREEN}${C_BOLD}OK — existing install verified healthy.${C_RESET}"
else
    SUMMARY_HEADLINE="${C_GREEN}${C_BOLD}OK — SignalK is up.${C_RESET}"
fi

cat <<EOF

${SUMMARY_HEADLINE}

  SignalK admin UI : http://localhost:3000
  Updater Console  : ${UPDATER_URL}
  Doctor Console   : ${DOCTOR_URL}

${LAN_NOTE}

Auth tokens are at:
  Updater : ${UPDATER_DATA}/token  (mode 0600)
  Doctor  : ${DOCTOR_DATA}/token   (mode 0600)

The 'signalk' command is now on your PATH:
  signalk health         show stack health
  signalk recover        delegate to the SSH-only recovery script
  signalk bug-report     bundle logs + state for an issue report
  signalk uninstall      stop services + remove Quadlets (preserves data)
  signalk help           full usage

Next: install plugins from the SignalK appstore.
EOF
