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
#   4c. Cgroup delegation: write user@.service.d/delegate.conf if needed
#   4d. Open-files limit: write user@.service.d/nofile.conf if needed
#   5. Ensure group memberships (dialout, gpio, netdev, audio)
#   6. Generate auth tokens for updater and doctor
#   7. Initialize ~/.signalk-doctor/{snapshots,last-good.json}
#   8. Detect hardware → ~/.signalk-updater/hardware.json
#   9. Pull all three images
#  10. Render and atomic-write three Quadlets
#  11. systemctl --user daemon-reload
#  11a. Install ~/.local/bin/{signalk,signalk-recovery} (CLI dispatcher:
#       health / recover / bug-report / uninstall). Installed BEFORE any
#       container restart so the operator always has these tools when
#       something below fails. Also guarantees the source dir for the
#       doctor Quadlet's `~/.local/bin` bind-mount exists.
#  11a-bis. CPU priority: write app.slice.d/50-signalk-cpu-priority.conf
#       (no sudo; after the CLI's watchers reclaimed ~/.config/systemd/user)
#  11b. signalk-server drift apply (restart only if Quadlet drifted)
#  12. Start doctor + updater services (warn-and-continue on failure)
#  13. Wait for doctor + updater health
#  14. Ask the updater to start signalk-server (with systemctl fallback)
#  15. Wait for signalk-server health
#  16. Append a PATH snippet to the user's login-shell rc
#  17. Journald drop-in (sudo)
#  18. Mark bootstrap-complete in last-good.json
#  18b. (re-runs only) Verification pass: report healthy/broken checkpoints
#  19. Print success URLs

INSTALLER_VERSION="${INSTALLER_VERSION:-0.0.0-scaffold}"

# Release channel. The site publishes the latest RELEASE at its root and master
# under /dev, so the default here follows releases rather than whatever landed
# on master minutes ago — a boat should not be a test bed by accident.
#
#   SIGNALK_CHANNEL=master curl … | bash     # track master (dev/testing)
#   INSTALLER_BASE_URL=…    curl … | bash     # point somewhere else entirely
#
# An explicit INSTALLER_BASE_URL still wins: it is the escape hatch for local
# checkouts, mirrors and CI, and the channel must not quietly override it.
SIGNALK_CHANNEL="${SIGNALK_CHANNEL:-release}"
_SK_SITE_ROOT="https://dirkwa.github.io/signalk-universal-installer"
case "$SIGNALK_CHANNEL" in
    release) _SK_DEFAULT_BASE="$_SK_SITE_ROOT" ;;
    master|dev) _SK_DEFAULT_BASE="${_SK_SITE_ROOT}/dev" ;;
    *)
        echo "[ERR] SIGNALK_CHANNEL must be 'release' or 'master' (got '${SIGNALK_CHANNEL}')" >&2
        exit 1
        ;;
esac
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-$_SK_DEFAULT_BASE}"

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

# Login shells set USER, but `podman exec`, cron, and some systemd contexts
# don't — with `set -u` the first $USER dereference then aborts the run.
# id -un answers from the kernel. Exported so preflight.sh (subprocess)
# inherits it; preflight keeps its own guard for standalone invocation.
USER="${USER:-$(id -un)}"
export USER

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
        installer/linux/install-socketcan-script.sh \
        installer/linux/install-bluetooth-script.sh \
        installer/linux/install-halpi2-script.sh \
        installer/linux/signalk.tmpl \
        installer/linux/signalk-recovery.tmpl \
        installer/linux/signalk-socketcan.tmpl \
        installer/linux/signalk-bluetooth.tmpl \
        installer/linux/signalk-halpi2.tmpl \
        installer/linux/signalk-timesync.tmpl \
        installer/linux/legacy-cleanup.sh \
        installer/linux/lib/colors.sh \
        installer/linux/lib/distro.sh \
        installer/linux/lib/http.sh \
        installer/linux/lib/ghcr.sh \
        installer/linux/lib/hardware-merge.sh \
        quadlets/signalk-server.container.template \
        quadlets/signalk-updater-server.container.template \
        quadlets/signalk-doctor-server.container.template \
        quadlets/signalk-dbus-proxy.container.template; do
        mkdir -p "$TMP/$(dirname "$f")"
        if ! curl -fsSL "${INSTALLER_BASE_URL}/${f}" -o "$TMP/$f"; then
            echo "[ERR] Failed to fetch ${INSTALLER_BASE_URL}/${f}" >&2
            exit 1
        fi
    done
    chmod +x "$TMP/installer/linux/"*.sh
    chmod +x "$TMP/installer/linux/lib/"*.sh 2>/dev/null || true
    # Run the local copy as a child, NOT via `exec`. The original
    # `curl … | bash` invocation is still streaming bytes through this
    # bash's stdin; using `exec` here replaced the process before bash
    # had consumed the tail of install.sh, so curl hit SIGPIPE writing
    # to a pipe with no reader and exited 23 with a confusing
    # "Failure writing output to destination" line printed AFTER the
    # successful install summary. Running as a subprocess keeps this
    # bash alive; we then drain curl's leftover bytes to /dev/null so
    # curl sees a clean EOF instead of a broken pipe.
    env \
        INSTALLER_VERSION="$INSTALLER_VERSION" \
        INSTALLER_BASE_URL="$INSTALLER_BASE_URL" \
        SIGNALK_CHANNEL="$SIGNALK_CHANNEL" \
        SIGNALK_LOCALHOST_ONLY="${SIGNALK_LOCALHOST_ONLY:-}" \
        SIGNALK_LAN_EXPOSE="${SIGNALK_LAN_EXPOSE:-}" \
        SIGNALK_VESSEL_NAME="${SIGNALK_VESSEL_NAME:-}" \
        SIGNALK_VESSEL_MMSI="${SIGNALK_VESSEL_MMSI:-}" \
        SIGNALK_VESSEL_CALLSIGN="${SIGNALK_VESSEL_CALLSIGN:-}" \
        SIGNALK_ADMIN_USER="${SIGNALK_ADMIN_USER:-}" \
        bash "$TMP/installer/linux/install.sh" "$@"
    # SIGNALK_ADMIN_PASSWORD is intentionally NOT on the `env` argv line
    # above (that would expose it in `ps` of the env process). It reaches
    # the child by inheritance instead: `env VAR=val bash` adds to the
    # inherited environment rather than replacing it, so an exported
    # password passes straight through, off every command line.
    rc=$?
    cat >/dev/null 2>&1 || true
    exit "$rc"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"
# shellcheck disable=SC1091
. "$HERE/lib/http.sh"
# shellcheck disable=SC1091
. "$HERE/lib/ghcr.sh"
# shellcheck disable=SC1091
. "$HERE/lib/hardware-merge.sh"

# Refuse root BEFORE the install-log tee below: run as root, the tee
# would first create /root/.signalk-updater/install.log — a root-owned
# leftover that `signalk bug-report` (which runs as the regular user)
# can never bundle. The full rationale for refusing root lives at the
# privilege-escalation comment further down.
if (( EUID == 0 )); then
    err "Do not run the installer as root (su / root login / sudo bash)."
    echo >&2
    err "The SignalK stack is rootless and tied to a regular user's"
    err "session: Quadlets, systemd --user units, linger, and ~/.signalk"
    err "all belong to the user who runs this script. As root they would"
    err "land in root's home and session instead."
    echo >&2
    err "Run it as the user who should own SignalK. If that user can't"
    err "sudo yet, bootstrap once as root, then RECONNECT the session:"
    err "  1. apt-get update && apt-get install -y sudo"
    err "  2. /usr/sbin/usermod -aG sudo <youruser>"
    err "     (full path — a plain 'su' root shell lacks /usr/sbin on PATH)"
    err "  3. Log in as <youruser> (fresh SSH session, not su)."
    err "  4. Re-run the installer one-liner — it sudo's where needed."
    exit 1
fi

# Persist this run's console output to ~/.signalk-updater/install.log so
# `signalk bug-report` can bundle it. The documented invocation is
# `curl … | bash` (output goes only to the terminal), so without this a
# failed install left no on-disk trace — the operator had to re-run by
# hand to see what broke, and bug-report had nothing to send. We're past
# the curl|bash self-reexec branch above (which already exited), so this
# tees the real on-disk run, not the stdin bootstrap. fd1+fd2 are merged
# through a single appending `tee` that keeps the terminal output intact;
# the process-substitution sink drains on the script's natural exit.
# Truncate (not append) at the start of each run so a re-install doesn't
# accumulate stale failures; cap by truncating only — the file is one
# install's worth of output, a few KB. SIGNALK_NO_INSTALL_LOG=1 opts out
# (e.g. for read-only-home CI). The dir is created here because the log
# starts before step 8 (hardware detect) would otherwise mkdir it.
INSTALL_LOG="${HOME}/.signalk-updater/install.log"
case "${SIGNALK_NO_INSTALL_LOG:-}" in
    1 | true | TRUE | yes | YES) INSTALL_LOG="" ;;
esac
if [[ -n "$INSTALL_LOG" ]] && mkdir -p "${HOME}/.signalk-updater" 2>/dev/null \
    && : >"$INSTALL_LOG" 2>/dev/null; then
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    info "Logging this run to $INSTALL_LOG"
fi

REPO_OWNER=${REPO_OWNER:-dirkwa}
SK_IMAGE=${SK_IMAGE:-ghcr.io/${REPO_OWNER}/signalk-server:dirkwa}

# Engine Quadlets default to `:latest` (OperatorIntent = "stay on the
# channel"). The engine's self-update / doctor-update flows pull a
# specific semver tag explicitly before `restartUnit`, so podman picks
# up the just-pulled image without rewriting the Quadlet. Full
# rationale (and the reversal of PR #36's install-time pinning) lives
# in AGENTS.md "Engine images run on :latest". UPDATER_IMAGE /
# DOCTOR_IMAGE env overrides still work for CI.
UPDATER_IMAGE=${UPDATER_IMAGE:-ghcr.io/${REPO_OWNER}/signalk-updater-server:latest}
DOCTOR_IMAGE=${DOCTOR_IMAGE:-ghcr.io/${REPO_OWNER}/signalk-doctor-server:latest}
# Third-party sidecar that bridges the host system D-Bus into the rootless
# stack for BLE plugins (AUTH EXTERNAL uid rewriting — see
# quadlets/signalk-dbus-proxy.container.template). Unlike our own engine
# images this is NOT ours, so it does not get the ":latest = channel"
# treatment: the default is pinned to the multi-arch (amd64+arm64) index
# digest that was verified end-to-end, so a fresh install can never pull
# unreviewed third-party code. Env override for CI, mirrors, or a
# deliberate bump (which is a repo change, updating this pin).
# KEEP IN SYNC with DEFAULT_PROXY_IMAGE in signalk-bluetooth.tmpl (the
# helper renders the same template from the doctor's staged payload) —
# scripts/test/check-proxy-image-sync.sh enforces the match.
PROXY_IMAGE=${PROXY_IMAGE:-ghcr.io/yichenshen/dbus-auth-proxy@sha256:b1458d7822f6bcfa8d70ea2ab15d4371ce723932c1728ca8a34624da047cf07e}

QUADLET_DIR="${HOME}/.config/containers/systemd"
UPDATER_DATA="${HOME}/.signalk-updater"
DOCTOR_DATA="${HOME}/.signalk-doctor"

UPDATER_URL="http://127.0.0.1:3003"
DOCTOR_URL="http://127.0.0.1:3004"
# SIGNALK_URL is derived after the privileged-port decision below, once
# SK_HTTP_PORT is final. Declared empty here so `set -u` stays happy if
# an early-exit path references it.
SIGNALK_URL=""

# Privilege escalation. The installer needs root for apt + systemd
# file writes + journald drop-in + cgroup delegation override — but it
# must RUN as the regular user that will own the stack. Everything it
# sets up is per-user state: Quadlets in ~/.config/containers/systemd,
# `systemctl --user` units, linger, rootless podman storage, ~/.signalk.
# Run as root, all of that lands in root's home and user session — a
# broken install that LOOKS successful. So we support three setups:
#   - Running as root (su, root login, `curl … | sudo bash`) →
#     fail-fast with the switch-to-a-user recipe — already handled
#     above, before the install-log tee. Escalation for the few
#     root-needing steps is the installer's job, via sudo.
#   - Non-root + sudo present + caller authorized → SUDO="sudo"
#     (interactive prompt on first use, cached for the rest of the
#     run).
#   - Non-root + sudo present + caller NOT authorized → fail-fast
#     with the recipe + the "log out + back in" reminder. Common
#     case: user just ran `usermod -aG sudo $USER` and didn't
#     relogin, so the session's group set is stale.
#   - Non-root + sudo absent → fail-fast with the bootstrap recipe.
#     We don't try `su -c` because the curl-piped one-liner has no
#     controlling tty for the password prompt and the failure mode
#     is confusing.
if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO="MISSING"
fi

# Install OS packages portably across the distros this stack runs on. Debian/
# Ubuntu (the Pi/desktop targets) use apt; Fedora (what `podman machine`'s VM
# is, used by the macOS and Windows installers) uses dnf. Fedora CoreOS is
# image-based: it has no dnf at runtime and an immutable /usr, so packages can
# only be layered via `rpm-ostree install` + a reboot — hostile to a one-shot
# installer. We therefore never try to install on CoreOS; the only packages
# this installer needs (podman, passt, slirp4netns, uidmap, fuse-overlayfs)
# are all pre-baked on the podman-machine image, and jq is no longer
# host-installed.
#
# Args are Debian package names; we translate the few that differ on Fedora.
# Returns non-zero (without aborting the caller) when it genuinely couldn't
# install, so callers can decide whether the package was optional.
pkg_install() {
    local debs=("$@") pm="" pkgs=() p
    if command -v apt-get >/dev/null 2>&1; then
        pm="apt"
    elif command -v dnf >/dev/null 2>&1; then
        pm="dnf"
    elif command -v rpm-ostree >/dev/null 2>&1; then
        # Fedora CoreOS / Silverblue: can't layer packages without a reboot.
        warn "Cannot install (${debs[*]}) on an rpm-ostree system at runtime."
        warn "These are normally pre-installed on the podman-machine image."
        return 1
    else
        warn "No supported package manager (apt-get/dnf) found; cannot install (${debs[*]})."
        return 1
    fi

    if [[ "$pm" == "apt" ]]; then
        $SUDO apt-get update
        $SUDO apt-get install -y "${debs[@]}"
        return $?
    fi

    # dnf: map the Debian names that differ on Fedora.
    for p in "${debs[@]}"; do
        case "$p" in
            uidmap) pkgs+=("shadow-utils") ;;
            *)      pkgs+=("$p") ;;
        esac
    done
    $SUDO dnf install -y "${pkgs[@]}"
}

# 1. Detect host
detect_os
section "SignalK Universal Installer v${INSTALLER_VERSION#v}"
info "Host: ${DISTRO_PRETTY} (${ARCH_NORM})"
if [[ "$SUDO" = "MISSING" ]]; then
    err "Running as non-root user '$USER' and sudo is not installed."
    echo >&2
    err "Bootstrap sudo as root, then RECONNECT your SSH session:"
    err "  1. Become root (e.g.  su -)"
    err "  2. apt-get update && apt-get install -y sudo"
    err "  3. /usr/sbin/usermod -aG sudo $USER"
    err "  4. exit  # leave the root shell"
    err "  5. CLOSE the SSH session entirely and reconnect."
    err "     (su / newgrp / exec bash do NOT pick up the new group —"
    err "     Linux assigns groups when the session starts, not on"
    err "     subshell entry.)"
    err "  6. After reconnect, verify with:  groups | grep -qw sudo && echo OK"
    err "  7. Re-run the installer one-liner."
    exit 1
elif [[ "$SUDO" = "sudo" ]]; then
    # Probe whether sudo will actually let this user escalate, BEFORE
    # we start running steps that depend on it. `sudo -nv` returns 0
    # when the timestamp is already cached, 1 when sudo would prompt
    # OR when the user is not authorized; we distinguish by looking
    # for the "not in sudoers" / "may not run sudo" / "is not allowed"
    # patterns sudo emits to stderr (English + the localized forms
    # we've seen in the wild). When that's the case, fail-fast with
    # the recipe — the typical cause is `usermod -aG sudo $USER`
    # without a full SSH reconnect (the running session still has the
    # stale group set; only a fresh login refreshes it).
    sudo_probe=$(sudo -nv 2>&1 || true)
    if grep -qiE 'not (in the sudoers|allowed)|may not run sudo|nicht in der sudoers' <<<"$sudo_probe"; then
        err "'$USER' is not authorized to use sudo."
        echo >&2
        err "If you just added the user to the sudo group, CLOSE this SSH"
        err "session entirely and reconnect — su / exec bash / newgrp do"
        err "NOT refresh the kernel's group credentials for the running"
        err "session. Only a fresh login does."
        echo >&2
        err "After reconnect, verify with:  groups | grep -qw sudo && echo OK"
        err "Then re-run the installer one-liner."
        echo >&2
        err "If '$USER' really isn't in the sudo group at all, add it as"
        err "root first:  /usr/sbin/usermod -aG sudo $USER"
        exit 1
    fi
    # The -nv probe above can't catch every non-sudoer: sudo
    # authenticates BEFORE the sudoers lookup, so with -n a non-sudoer
    # often just gets "a password is required" (localized) and sails
    # past the pattern grep. So validate for real, once.
    #
    # First try a NON-INTERACTIVE real command (`sudo -n true`): this is what the
    # installer actually does (run commands as root), and it's exactly what
    # NOPASSWD covers. We deliberately do NOT use `sudo -n -v` here: `-v` only
    # validates/refreshes the credential timestamp, and on many sudoers configs
    # (a catch-all `%wheel ALL=(ALL) ALL` matched before the NOPASSWD line, or
    # Defaults that gate -v) it still demands a password even when NOPASSWD
    # applies to commands — which fails in a no-TTY context like
    # `podman machine ssh` even though `sudo -n true` succeeds. So `sudo -n true`
    # is the reliable "can this user sudo unattended?" check. Only if it fails do
    # we fall back to an interactive `sudo -v`, and only when a TTY exists.
    if ! sudo -n true 2>/dev/null; then
        if [[ -t 0 || -r /dev/tty ]]; then
            sudo_ok=0
            sudo -v && sudo_ok=1
        else
            sudo_ok=0
        fi
        if [[ "$sudo_ok" != "1" ]]; then
            err "sudo validation failed for '$USER' — cannot continue."
            echo >&2
            err "Either the password was wrong, or '$USER' is not authorized"
            err "to use sudo (and there is no TTY to prompt for a password)."
            err "If you just added the user to the sudo group, CLOSE this SSH"
            err "session entirely and reconnect, then verify with:"
            err "  groups | grep -qw sudo && echo OK"
            echo >&2
            err "For an unattended/no-TTY run (e.g. inside a podman machine),"
            err "grant the user passwordless sudo as root:"
            err "  echo '$USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-$USER-nopasswd"
            exit 1
        fi
    fi
fi
if [[ "${DEPRECATED_LAN_EXPOSE_SEEN:-0}" = "1" ]]; then
    warn "SIGNALK_LAN_EXPOSE is deprecated — use SIGNALK_LOCALHOST_ONLY=true instead."
fi
if [[ "$PUBLISH_HOST" = "0.0.0.0" ]]; then
    info "Port bind: 0.0.0.0 (LAN-reachable). Doctor read-only probes are unauthenticated by design."
    info "Set SIGNALK_LOCALHOST_ONLY=true to restrict to localhost."
else
    info "Port bind: localhost only (SIGNALK_LOCALHOST_ONLY=true)"
fi

# Privileged web ports (HTTP 80 / HTTPS 443) — opt-out.
#
# signalk-server runs as a non-root user inside the container, and the
# stack uses Network=host (shares the host's network namespace). On
# Linux a non-root process can't bind ports < 1024, and a network
# sysctl can't be set from inside a host-netns container, so the only
# working lever is the HOST's net.ipv4.ip_unprivileged_port_start. We
# lower it to 80 (a sudo'd /etc/sysctl.d drop-in) so signalk-server can
# bind 80/443 directly.
#
# Default ON. Interactive runs get a [Y/n] prompt; non-interactive runs
# (curl|bash with no TTY) proceed with the default unless the operator
# opted out via SIGNALK_PRIVILEGED_PORTS=0. SIGNALK_PRIVILEGED_PORTS=1
# forces it on without prompting (CI / unattended).
#
# When disabled, ports fall back to the historical 3000/3443 and the
# sysctl is left untouched.
PRIV_PORTS="${SIGNALK_PRIVILEGED_PORTS:-prompt}"
# Normalize common truthy/falsy spellings to 1/0 so SIGNALK_PRIVILEGED_PORTS=yes
# doesn't silently fall through to the legacy ports. Anything unrecognized
# (including the empty default) stays "prompt". Mirrors the SIGNALK_LOCALHOST_ONLY
# handling above.
case "$PRIV_PORTS" in
    1 | y | Y | yes | YES | Yes | true | TRUE | True | on | ON | On) PRIV_PORTS=1 ;;
    0 | n | N | no | NO | No | false | FALSE | False | off | OFF | Off) PRIV_PORTS=0 ;;
    *) PRIV_PORTS=prompt ;;
esac
# If no explicit choice was given (still "prompt") but a prior run already
# lowered the privileged-port floor, the operator answered "yes" before —
# don't ask again. The sysctl drop-in is this installer's own persistent
# artifact, written 0644 (world-readable, no sudo needed to detect) only
# when standard ports were chosen. Its presence is the durable record of
# that decision, so re-runs honour it silently.
PRIV_SYSCTL_FILE="/etc/sysctl.d/80-signalk-unprivileged-ports.conf"
if [[ "$PRIV_PORTS" = "prompt" && -f "$PRIV_SYSCTL_FILE" ]]; then
    PRIV_PORTS=1
    info "Standard web ports already configured (${PRIV_SYSCTL_FILE}); keeping :80/:443."
fi
if [[ "$PRIV_PORTS" = "prompt" ]]; then
    # Actually OPEN /dev/tty to decide if we can prompt. A bare `[[ -r /dev/tty ]]`
    # test passes when the device node merely exists but there's no controlling
    # terminal behind it (e.g. inside `podman machine ssh`, piped stdin) - then
    # the real `>/dev/tty` redirect fails with "No such device or address". So we
    # probe by opening it, in a subshell that can't take the script down.
    if ( exec 3<>/dev/tty ) 2>/dev/null; then
        printf '\n%sUse standard web ports? HTTP on :80, HTTPS on :443 (default 3000/3443).%s\n' \
            "$C_BOLD" "$C_RESET" >/dev/tty
        printf 'This lowers the host net.ipv4.ip_unprivileged_port_start to 80 (sudo). [Y/n] ' >/dev/tty
        read -r _priv_reply </dev/tty || _priv_reply=""
        case "$_priv_reply" in
            n|N|no|NO) PRIV_PORTS=0 ;;
            *) PRIV_PORTS=1 ;;
        esac
    else
        # No usable TTY (curl|bash, or no controlling terminal): default-on intent.
        PRIV_PORTS=1
    fi
fi

if [[ "$PRIV_PORTS" = "1" ]]; then
    SK_HTTP_PORT=80
    SK_HTTPS_PORT=443
else
    SK_HTTP_PORT=3000
    SK_HTTPS_PORT=3443
fi
SIGNALK_URL="http://127.0.0.1:${SK_HTTP_PORT}/signalk"
# Export so the child `bash preflight.sh` checks the actual ports.
export SK_HTTP_PORT SK_HTTPS_PORT
info "signalk-server ports: HTTP :${SK_HTTP_PORT}, HTTPS :${SK_HTTPS_PORT}"

# Vessel identity (boat name / MMSI / VHF call sign). Collected up front
# alongside the ports prompt so the operator isn't called back
# mid-install; applied as a ~/.signalk/baseDeltas.json seed right before
# signalk-server's first start, which pre-fills the admin UI's Server →
# Settings page. Env overrides for unattended runs: SIGNALK_VESSEL_NAME /
# SIGNALK_VESSEL_MMSI / SIGNALK_VESSEL_CALLSIGN. Every field is optional
# (Enter skips). Skipped entirely when the data dir already carries a
# vessel identity — baseDeltas.json, or legacy defaults.json which a
# fresh baseDeltas.json would silently shadow (the server reads
# baseDeltas.json first and never falls through).
VESSEL_NAME="${SIGNALK_VESSEL_NAME:-}"
VESSEL_MMSI="${SIGNALK_VESSEL_MMSI:-}"
VESSEL_CALLSIGN="${SIGNALK_VESSEL_CALLSIGN:-}"
# Env-driven-ness is decided on the RAW values, before MMSI validation
# can clear one: an env-driven run whose only value is an invalid MMSI
# must not fall through to the interactive prompts. A non-empty test
# (not ${var+x} presence) because the curl|bash re-exec above always
# forwards all three vars, set-but-empty, on every run.
VESSEL_ENV_SET=0
[[ -n "${VESSEL_NAME}${VESSEL_MMSI}${VESSEL_CALLSIGN}" ]] && VESSEL_ENV_SET=1
if [[ -n "$VESSEL_MMSI" && ! "$VESSEL_MMSI" =~ ^[0-9]{9}$ ]]; then
    warn "SIGNALK_VESSEL_MMSI '$VESSEL_MMSI' is not 9 digits — ignoring it"
    VESSEL_MMSI=""
fi
VESSEL_SEED=0
# Set to 1 when this run seeds config the server only reads at startup (vessel
# identity, security). On a re-run with the server already up, that means we
# must `restart` (not just `start`) so the new config takes effect.
NEED_SERVER_RESTART=0
if [[ -f "$HOME/.signalk/baseDeltas.json" || -f "$HOME/.signalk/defaults.json" ]]; then
    # Existing vessel identity — never clobber, and keep re-runs prompt-free.
    :
elif [[ "$VESSEL_ENV_SET" = "1" ]]; then
    [[ -n "${VESSEL_NAME}${VESSEL_MMSI}${VESSEL_CALLSIGN}" ]] && VESSEL_SEED=1
elif ( exec 3<>/dev/tty ) 2>/dev/null; then  # only prompt if /dev/tty truly opens
    printf '\n%sVessel identity — pre-fills the admin UI (all optional, Enter to skip).%s\n' \
        "$C_BOLD" "$C_RESET" >/dev/tty
    printf 'Boat name: ' >/dev/tty
    read -r VESSEL_NAME </dev/tty || VESSEL_NAME=""
    while :; do
        printf 'MMSI (9 digits): ' >/dev/tty
        read -r VESSEL_MMSI </dev/tty || VESSEL_MMSI=""
        [[ -z "$VESSEL_MMSI" || "$VESSEL_MMSI" =~ ^[0-9]{9}$ ]] && break
        printf 'An MMSI is exactly 9 digits — try again, or press Enter to skip.\n' >/dev/tty
    done
    printf 'VHF call sign: ' >/dev/tty
    read -r VESSEL_CALLSIGN </dev/tty || VESSEL_CALLSIGN=""
    [[ -n "${VESSEL_NAME}${VESSEL_MMSI}${VESSEL_CALLSIGN}" ]] && VESSEL_SEED=1
fi

# Admin credentials. Collected here, alongside the vessel prompts, and
# seeded into ~/.signalk/security.json (+ settings.json's
# security.strategy) right before signalk-server's first start, so the
# server never boots unsecured on the LAN — closing the window where the
# admin UI would otherwise show its "create an account" screen to anyone
# who reaches it first.
#
# Interactive: prompt for a username (default "admin") and a password
# typed twice; mandatory, re-asks on empty/mismatch. The password is
# read with `read -rs` and never echoed; it travels to the hashing step
# via a pipe (never argv/env), so it can't leak through `ps` or
# install.log.
#
# Unattended (no TTY): SIGNALK_ADMIN_USER / SIGNALK_ADMIN_PASSWORD. The
# password env var is forwarded through the curl|bash re-exec by
# inheritance (exported, NOT placed on the `env` argv line) so it stays
# off every command line. With no TTY and no password env var the
# install proceeds UNSECURED with a loud warning — preserving today's
# behavior for existing automation rather than hard-failing.
#
# Skipped entirely when ~/.signalk/security.json already has a users[]
# array (security already configured): re-runs stay prompt-free and the
# existing credentials are never touched.
ADMIN_USER=""
ADMIN_PASSWORD=""
ADMIN_SEED=0
ADMIN_UNSECURED=0
if command -v jq >/dev/null 2>&1 \
    && [[ -f "$HOME/.signalk/security.json" ]] \
    && [[ "$(jq -r 'has("users")' "$HOME/.signalk/security.json" 2>/dev/null)" = "true" ]]; then
    # Security already configured — leave it alone, ask nothing.
    :
elif [[ -n "${SIGNALK_ADMIN_USER:-}" || -n "${SIGNALK_ADMIN_PASSWORD:-}" ]]; then
    ADMIN_USER="${SIGNALK_ADMIN_USER:-admin}"
    ADMIN_PASSWORD="${SIGNALK_ADMIN_PASSWORD:-}"
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        warn "SIGNALK_ADMIN_USER set without SIGNALK_ADMIN_PASSWORD — cannot create admin; server will start UNSECURED"
        ADMIN_UNSECURED=1
    else
        ADMIN_SEED=1
    fi
elif ( exec 3<>/dev/tty ) 2>/dev/null; then  # only prompt if /dev/tty truly opens
    printf '\n%sAdmin login — secures the server before it goes on the network.%s\n' \
        "$C_BOLD" "$C_RESET" >/dev/tty
    printf 'Admin username [admin]: ' >/dev/tty
    read -r ADMIN_USER </dev/tty || ADMIN_USER=""
    # Trim and default. signalk-server's own register/login don't trim
    # consistently across versions (see the username-whitespace lockout),
    # so we trim here to keep the stored username and the login the
    # operator types byte-identical.
    ADMIN_USER="${ADMIN_USER#"${ADMIN_USER%%[![:space:]]*}"}"
    ADMIN_USER="${ADMIN_USER%"${ADMIN_USER##*[![:space:]]}"}"
    [[ -z "$ADMIN_USER" ]] && ADMIN_USER="admin"
    while :; do
        printf 'Admin password: ' >/dev/tty
        read -rs ADMIN_PASSWORD </dev/tty || ADMIN_PASSWORD=""
        printf '\n' >/dev/tty
        printf 'Confirm password: ' >/dev/tty
        read -rs _admin_pw2 </dev/tty || _admin_pw2=""
        printf '\n' >/dev/tty
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            printf 'Password must not be empty.\n' >/dev/tty
        elif [[ "$ADMIN_PASSWORD" != "$_admin_pw2" ]]; then
            printf 'Passwords do not match — try again.\n' >/dev/tty
        else
            break
        fi
    done
    unset _admin_pw2
    ADMIN_SEED=1
else
    warn "No TTY and no SIGNALK_ADMIN_USER/SIGNALK_ADMIN_PASSWORD — server will start UNSECURED"
    warn "secure it from the admin UI, or re-run with SIGNALK_ADMIN_USER and SIGNALK_ADMIN_PASSWORD set"
    ADMIN_UNSECURED=1
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
# Preflight may apply a kernel-cmdline patch that requires a reboot
# (Pi memory controller). It signals that case with exit code 2 — its
# own [OK]/[!] messages already told the operator what to do; we just
# need to stop cleanly without flagging it as a generic preflight fail.
set +e
bash "$HERE/preflight.sh"
PREFLIGHT_RC=$?
set -e
if (( PREFLIGHT_RC == 2 )); then
    info "Preflight applied a kernel cmdline patch; reboot and re-run this installer."
    exit 0
elif (( PREFLIGHT_RC != 0 )); then
    exit "$PREFLIGHT_RC"
fi

# 2c. Hat Labs HALPI2 carrier board (Raspberry Pi CM5). On a CM5 the helper
# probes the HALPI2 controller at I2C 0x6d, installs the Hat Labs packages
# (halpid, halpi2-firmware, blinkenlights-daemon, i2c-tools, can-utils),
# writes the config.txt device-tree block, the can0 bitrate and i2c-dev at
# boot, then asks for a reboot — same exit-and-re-run contract as the
# preflight cmdline patch above: the re-run finds can0 / ttyAMA4 / halpid
# live and the normal hardware detection picks them up. Runs the template
# directly because ~/.local/bin/signalk-halpi2 is installed later (11a).
# SIGNALK_HALPI2=no skips it; SIGNALK_HALPI2=yes skips its prompts. Details
# and the manual recipe: docs/halpi2.md. Never fails the install: rc 1 =
# declined/incomplete, warned and carried on. Runs only when sudo is usable.
case "${SIGNALK_HALPI2:-auto}" in
    no|NO|0|false|FALSE) ;;
    *)
        if [[ "$SUDO" = "MISSING" ]]; then
            # detect: 0 confirmed, 1 candidate, 2 not a CM5
            set +e
            bash "$HERE/signalk-halpi2.tmpl" detect >/dev/null 2>&1
            HALPI2_DETECT_RC=$?
            set -e
            if (( HALPI2_DETECT_RC == 0 || HALPI2_DETECT_RC == 1 )); then
                warn "Compute Module 5 detected but sudo is unavailable — HALPI2 setup skipped."
                warn "Run 'signalk halpi2 apply' with sudo later (docs/halpi2.md)."
            fi
        else
            set +e
            bash "$HERE/signalk-halpi2.tmpl" apply
            HALPI2_RC=$?
            set -e
            if (( HALPI2_RC == 2 )); then
                info "HALPI2 support applied; reboot and re-run this installer."
                exit 0
            elif (( HALPI2_RC != 0 )); then
                warn "HALPI2 setup incomplete (see above); continuing with the install."
            fi
        fi
        ;;
esac

# 2b. Privileged-port sysctl (only when standard web ports were chosen)
#
# Lower net.ipv4.ip_unprivileged_port_start to 80 via a persistent
# /etc/sysctl.d drop-in so the rootless, host-netns signalk-server
# container can bind 80/443. Idempotent: re-runs skip the write when
# the running value is already <= 80. Host-wide change (affects every
# unprivileged process), documented in docs/installation.md.
if [[ "$PRIV_PORTS" = "1" ]]; then
    section "Privileged web ports"
    PRIV_SYSCTL_KEY="net.ipv4.ip_unprivileged_port_start"
    # PRIV_SYSCTL_FILE is set near the prompt above (used there to detect a
    # prior "yes" and skip re-prompting).
    current_floor=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)
    # Gate on the DROP-IN, not on the running value. A runtime 80 proves only
    # that something lowered it in this boot, not that it will come back after
    # a reboot - and on a podman machine something does exactly that: a fresh
    # WSL VM reports 80 with no file anywhere under /etc/sysctl.d or
    # /usr/lib/sysctl.d to hold it. The old `current_floor <= 80` check read
    # that as "already configured", skipped the write, and the next
    # `wsl --shutdown` reset the floor to 1024. signalk-server then crash-looped
    # on `listen EACCES: permission denied 0.0.0.0:80` while the container
    # itself stayed "Up" - the stack looked healthy and served nothing on :80.
    #
    # Writing the drop-in when the value is already 80 costs one idempotent
    # file write; not writing it costs a dead server after the next restart.
    # Check the drop-in's CONTENT, not merely that a file is there: an empty or
    # hand-edited file satisfies -f while persisting nothing, which reproduces
    # exactly the failure this guard exists to prevent. Match the assignment
    # sysctl itself would honour - optional spaces, no leading comment.
    if grep -qE "^[[:space:]]*${PRIV_SYSCTL_KEY//./\\.}[[:space:]]*=[[:space:]]*(80|[0-9]|[1-7][0-9])[[:space:]]*$" \
        "$PRIV_SYSCTL_FILE" 2>/dev/null && (( current_floor <= 80 )); then
        ok "${PRIV_SYSCTL_KEY} already ${current_floor} (≤ 80, persisted in ${PRIV_SYSCTL_FILE})"
    elif [[ "$SUDO" = "MISSING" ]]; then
        warn "Cannot lower ${PRIV_SYSCTL_KEY} without sudo; 80/443 will fail to bind."
        warn "Set it manually as root:  echo '${PRIV_SYSCTL_KEY}=80' > ${PRIV_SYSCTL_FILE} && echo 80 > /proc/sys/net/ipv4/ip_unprivileged_port_start"
    else
        info "Lowering ${PRIV_SYSCTL_KEY} to 80 (host-wide, persistent)"
        # Runtime apply goes through /proc, not the sysctl binary: a fresh
        # minimal Trixie may not have procps installed, and a root shell
        # entered via plain `su` lacks /usr/sbin on PATH — both surfaced as
        # `sysctl: command not found` here. The /etc/sysctl.d drop-in above
        # covers persistence across reboots; tee'ing /proc is the same
        # operation `sysctl -w` performs.
        if printf '# Managed by signalk-universal-installer — lets the rootless,\n# host-netns signalk-server container bind HTTP :80 / HTTPS :443.\n%s=80\n' \
            "$PRIV_SYSCTL_KEY" | $SUDO tee "$PRIV_SYSCTL_FILE" >/dev/null \
            && printf '80\n' | $SUDO tee /proc/sys/net/ipv4/ip_unprivileged_port_start >/dev/null; then
            ok "${PRIV_SYSCTL_KEY}=80 (drop-in ${PRIV_SYSCTL_FILE})"
        else
            warn "Failed to apply ${PRIV_SYSCTL_KEY}=80; 80/443 may not bind until fixed."
        fi
    fi
fi

# 3. Install podman if absent
section "Podman"
if ! command -v podman >/dev/null 2>&1; then
    # passt, aardvark-dns and nftables are explicit, not left to podman's
    # dependency pull: on Debian all three are only a Recommends (of podman
    # and netavark), and Armbian ships with APT::Install-Recommends off —
    # podman installs fine but the pasta binary is missing and every
    # pasta-networked container (updater, doctor) fails to start, without
    # aardvark-dns every container on a user-defined network (grafana,
    # questdb) has a dead nameserver, and without nftables netavark cannot
    # exec nft, so bridge-networked containers fail to start at all.
    info "Installing podman + passt + uidmap + slirp4netns + aardvark-dns + nftables (requires sudo)"
    if ! pkg_install podman passt uidmap slirp4netns aardvark-dns nftables; then
        err "Could not install podman. Install it manually and re-run."
        exit 1
    fi
fi
ok "$(podman --version)"

# Hosts that arrived WITH podman preinstalled (Armbian images, prior manual
# installs) skip the block above, so ensure pasta separately. podman >= 5
# defaults rootless networking to pasta; without the binary the updater and
# doctor containers fail to start even though podman itself looks healthy.
# Deliberately warn-not-fatal: a host configured to use slirp4netns via
# containers.conf works without pasta, and aborting the whole install
# over the default-backend package would block it.
if ! command -v pasta >/dev/null 2>&1; then
    info "Installing passt (pasta rootless networking backend, requires sudo)"
    pkg_install passt || true
    if ! command -v pasta >/dev/null 2>&1; then
        warn "pasta still not found — updater/doctor containers may fail"
        warn "to start. Install it manually (e.g. apt-get install passt)"
        warn "if they do."
    fi
fi

# Same Recommends gap for aardvark-dns: netavark only Recommends it, so
# Armbian-style hosts end up with user-defined networks whose containers
# get the bridge gateway as nameserver and nothing listening on :53 —
# every DNS lookup inside grafana/questdb-style containers fails with
# "connection refused". Ask podman where it resolved the helper (covers
# custom helper_binaries_dir); the binary is not on PATH, so fall back to
# the packaged locations rather than command -v.
# Warn-not-fatal: the core stack (host/pasta networking) works without it.
have_aardvark_dns() {
    local p
    p="$(podman info --format '{{.Host.NetworkBackendInfo.DNS.Path}}' 2>/dev/null || true)"
    if [[ -n "$p" && -x "$p" ]]; then
        return 0
    fi
    [[ -x /usr/lib/podman/aardvark-dns || -x /usr/libexec/podman/aardvark-dns ]] \
        || command -v aardvark-dns >/dev/null 2>&1
}
if ! have_aardvark_dns; then
    info "Installing aardvark-dns (DNS for user-defined container networks, requires sudo)"
    pkg_install aardvark-dns || true
    if ! have_aardvark_dns; then
        warn "aardvark-dns still not found — containers on user-defined"
        warn "networks (e.g. grafana/questdb) cannot resolve DNS. Install"
        warn "it manually (e.g. apt-get install aardvark-dns) if they fail."
    fi
fi

# And the same Recommends gap once more for nftables: netavark's firewall
# driver execs the nft binary when it wires a container network, but
# nftables is only a Recommends of netavark — on recommends-off hosts
# (Armbian) every bridge-networked container (grafana, questdb, backup)
# fails to start with "netavark: unable to execute nft: No such file or
# directory" (issue #171 field report). nft lives in /usr/sbin, which
# user shells often drop from PATH, so probe the packaged locations too.
# Warn-not-fatal: the core stack (host/pasta networking) works without it.
have_nft() {
    command -v nft >/dev/null 2>&1 || [[ -x /usr/sbin/nft || -x /sbin/nft ]]
}
if ! have_nft; then
    info "Installing nftables (netavark firewall backend, requires sudo)"
    pkg_install nftables || true
    if ! have_nft; then
        warn "nft still not found — containers on bridge networks (e.g."
        warn "grafana/questdb) cannot start. Install it manually (e.g."
        warn "apt-get install nftables) if they fail."
    fi
fi

# Re-gate the podman version AFTER the install. Preflight runs before this
# block, so on a host that arrived without podman its check_podman only said
# "will install it" — it never saw the version apt would lay down. Some
# supported distros ship a too-old podman in their own archive (e.g. Ubuntu
# 24.04 = 4.9.3), and the [Quadlet] DefaultDependencies=false key the engine
# Quadlets rely on is silently ignored below 5.3, re-arming the network-wait
# shim that stalls startup. Fail loudly here rather than proceed to a setup
# that hangs on every boot with no obvious cause.
PODMAN_MIN_VERSION="5.3"
pv=$(podman --version 2>/dev/null | awk '{print $3}')
pv_major=${pv%%.*}
pv_minor=$(cut -d. -f2 <<<"$pv")
req_major=${PODMAN_MIN_VERSION%%.*}
req_minor=${PODMAN_MIN_VERSION#*.}
if (( pv_major < req_major )) || { (( pv_major == req_major )) && (( pv_minor < req_minor )); }; then
    err "Podman $pv is below the required $PODMAN_MIN_VERSION."
    err "This release's archive podman is too old for rootless Quadlet"
    err "network-dependency control; the stack will stall on startup."
    err "Install podman >= $PODMAN_MIN_VERSION (e.g. a newer OS release whose"
    err "archive ships it) and re-run this installer."
    exit 1
fi

# Ensure subuid/subgid ranges exist for rootless podman. Debian/Ubuntu/Pi OS
# auto-populate /etc/subuid + /etc/subgid for human users via adduser, so this
# is a no-op there. But minimally-provisioned images (e.g. the Fedora
# podman-machine VM, where the user is created from a Containerfile) can lack a
# range — and then the very first `podman pull` below fails with
# "lookup user ...: no subuid ranges found". preflight only warns about this; we
# actually fix it here. Idempotent: only added when missing.
if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null; then
    info "Adding subuid range for $USER (rootless podman; requires sudo)"
    $SUDO usermod --add-subuids 100000-165535 "$USER" || warn "could not add subuid range for $USER"
fi
if ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    info "Adding subgid range for $USER (rootless podman; requires sudo)"
    $SUDO usermod --add-subgids 100000-165535 "$USER" || warn "could not add subgid range for $USER"
fi
# Re-read the (possibly new) ranges so the first pull doesn't trip over a stale
# user-namespace mapping.
podman system migrate >/dev/null 2>&1 || true

# NOTE: the rootless podman API service is realigned with the containers' pause
# namespace LATE — after the final container start (search "Realigning podman
# API service" below), NOT here. Doing it here is too early: starting the
# keep-id containers further down recreates the pause process AFTER this point,
# so an early realign is immediately undone and the socket service is left in a
# sibling namespace it cannot enter. See that block's comment for the mechanism.

# jq smooths a few optional steps (sslport / vessel-identity / security seeding,
# admin-user lookup, the last-good snapshot) and `signalk bug-report`'s JSON
# handling — every consumer guards on `command -v jq` and degrades without it,
# so jq is a nice-to-have, not a hard dependency. Best-effort install it where a
# package manager can (apt/dnf); on rpm-ostree images (Fedora CoreOS / the
# podman-machine VM) jq isn't pre-baked and can't be layered at runtime, so we
# continue without it rather than abort.
if ! command -v jq >/dev/null 2>&1; then
    info "Installing jq (optional; requires sudo)"
    pkg_install jq || warn "jq unavailable — optional JSON steps will be skipped."
fi
if command -v jq >/dev/null 2>&1; then
    ok "$(jq --version)"
else
    info "jq not present; continuing (optional steps degrade gracefully)."
fi

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
        pkg_install fuse-overlayfs || warn "Could not install fuse-overlayfs; ZFS storage may be slow."
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
    $SUDO loginctl enable-linger "$USER"
fi
ok "linger enabled"

# Re-establish XDG_RUNTIME_DIR if linger was just enabled; the user-bus
# socket may not exist until the next login otherwise. Defensive nudge:
systemctl --user daemon-reload || true

# Reclaim ~/.config/systemd/user if something else created it as root.
#
# Podman machine's WSL provisioning does exactly that: it writes
# podman-mnt-bindings.service and default.target.wants there while
# provisioning the VM, leaving the directory root:root 0755 inside an
# unprivileged home. Everything this installer later writes underneath it
# then fails - the podman TasksMax drop-in a few lines below, and the
# resolv-watch / netgate-watch units near the end - each with a different
# and misleading message about the file it happened to be writing.
#
# Do it here, once, before the first write: this is the earliest point where
# sudo is known to work (the linger step above just used it) and it is
# ahead of every consumer.
# Usable means writable AND searchable: a directory can be -w but not -x, and
# the write still fails. Same test the CLI's _signalk_ensure_unit_dir applies,
# so the two agree about what "already fine" means.
SK_USER_UNIT_DIR="$HOME/.config/systemd/user"
if [[ -d "$SK_USER_UNIT_DIR" ]] && { [[ ! -w "$SK_USER_UNIT_DIR" ]] || [[ ! -x "$SK_USER_UNIT_DIR" ]]; }; then
    sk_owner=$(stat -c '%U:%G' "$SK_USER_UNIT_DIR" 2>/dev/null || echo 'unknown')
    if $SUDO chown -R "$(id -un):$(id -gn)" "$SK_USER_UNIT_DIR" 2>/dev/null \
        && [[ -w "$SK_USER_UNIT_DIR" && -x "$SK_USER_UNIT_DIR" ]]; then
        ok "reclaimed $SK_USER_UNIT_DIR from ${sk_owner} (created by the VM provisioner)"
    else
        # chown fixes ownership, never the mode: a dir we already own with the
        # execute bit cleared lands here too, and needs chmod rather than chown.
        warn "$SK_USER_UNIT_DIR (owner ${sk_owner}, mode $(stat -c '%a' "$SK_USER_UNIT_DIR" 2>/dev/null || echo '?')) is not usable by $(id -un); unit installs below will fail."
        warn "Fix with: sudo chown -R $(id -un):$(id -gn) $SK_USER_UNIT_DIR && chmod u+rwx $SK_USER_UNIT_DIR"
    fi
fi

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

# 4b-ter. Circuit breaker: cap concurrent tasks under podman.service.
#
# podman's /info & /version (which dockerode clients poll) shell out
# `dpkg-query --search` on each helper binary to report provenance. The
# engines now cache runtime detection so steady-state is a non-event, but
# a COLD boot — all three engines starting concurrently with empty caches —
# can still fan out a burst before the caches fill. TasksMax is a hard
# ceiling on how many children the podman daemon cgroup can fork at once,
# so even a worst-case cold burst can't melt a slow box. 256 is ~8x the
# observed idle task count (32) — invisible to legitimate pull/run/recreate
# but a firm stop on a runaway dpkg fork-storm. TasksMax ONLY: a CPUQuota
# or MemoryMax here would throttle/OOM real image pulls (the daemon peaks
# ~2G RSS during unpack), so we deliberately don't set those.
PODMAN_LIMITS_DIR="$HOME/.config/systemd/user/podman.service.d"
PODMAN_LIMITS_CONF="$PODMAN_LIMITS_DIR/resource-limits.conf"
if [[ ! -f "$PODMAN_LIMITS_CONF" ]] || ! grep -q '^TasksMax=' "$PODMAN_LIMITS_CONF"; then
    if mkdir -p "$PODMAN_LIMITS_DIR" 2>/dev/null \
        && printf '[Service]\nTasksMax=256\n' > "$PODMAN_LIMITS_CONF"; then
        systemctl --user daemon-reload || true
        ok "podman.service TasksMax cap applied (fork-storm circuit breaker)"
    else
        warn "Could not write $PODMAN_LIMITS_CONF; podman fork-storm cap not applied"
    fi
fi

# 4c. Cgroup delegation for the user slice.
#
# The kernel may have memory + pids enabled at the root cgroup, but
# systemd's default user@.service Delegate= value varies by distro and
# systemd version. On hosts where memory/pids don't propagate down to
# user-<uid>.slice, container resource limits silently no-op:
# `podman run --memory=512m` accepts the flag but enforces nothing.
# signalk-container's doctor probe documents this exactly; we pre-empt
# it here by writing the standard user@.service.d/delegate.conf
# override that the doctor's remediation tells the operator to write.
#
# Three branches: already-delegated → skip; missing AND sudo available
# → autofix (re-login required for effect on the running user@.service
# instance, see message below); missing AND no sudo → print the same
# recipe so the operator can fix it themselves.
section "Cgroup delegation"
USER_SLICE="/sys/fs/cgroup/user.slice/user-$(id -u).slice"
NEED_DELEGATE_FIX=0
# Both the cgroup-delegation and open-files (nofile) steps below write
# user@.service.d/ drop-ins that only take effect on a fresh user@.service
# instance. They share one re-login advisory: USER_SERVICE_RELOGIN_HINT
# flags that at least one fired, and USER_SERVICE_OVERRIDES accumulates the
# per-file lines printed at the end of the run.
USER_SERVICE_RELOGIN_HINT=0
USER_SERVICE_OVERRIDES=""
if [[ -f "$USER_SLICE/cgroup.controllers" ]]; then
    USER_SLICE_CTL=$(cat "$USER_SLICE/cgroup.controllers" 2>/dev/null || echo "")
    if grep -qw memory <<<"$USER_SLICE_CTL" && grep -qw pids <<<"$USER_SLICE_CTL"; then
        ok "user slice has memory + pids delegated"
    else
        NEED_DELEGATE_FIX=1
    fi
else
    # No user slice file yet — shouldn't happen post-linger, but treat
    # as missing so the override file at least lands on disk.
    NEED_DELEGATE_FIX=1
fi

if (( NEED_DELEGATE_FIX )); then
    DELEGATE_CONF="/etc/systemd/system/user@.service.d/delegate.conf"
    info "Writing $DELEGATE_CONF (requires sudo)"
    # Use interactive sudo, matching the apt + loginctl + usermod
    # steps earlier in this script. By this point in the run the
    # operator has typically already been prompted at least once and
    # the password is cached, so this is a no-op in the common case;
    # for fresh sudo timestamps it prompts. We don't fall back to a
    # warn-only path here — silent-noop memory/pids limits is a real
    # bug, not optional polish.
    $SUDO install -d -m 0755 "$(dirname "$DELEGATE_CONF")"
    $SUDO tee "$DELEGATE_CONF" >/dev/null <<EOF
# Installed by signalk-universal-installer.
# Ensures user@.service delegates memory + pids in addition to the
# defaults, so rootless container resource limits actually enforce.
[Service]
Delegate=cpu cpuset io memory pids
EOF
    $SUDO systemctl daemon-reload
    ok "Installed $DELEGATE_CONF"
    # daemon-reload doesn't re-apply Delegate= to the already-running
    # user@.service instance; the user has to log out and back in (or
    # reboot) for the new delegation to take effect.
    USER_SERVICE_RELOGIN_HINT=1
    USER_SERVICE_OVERRIDES+="  • $DELEGATE_CONF (cgroup memory/pids delegation)"$'\n'
fi

# 4d. Open-files limit (RLIMIT_NOFILE) for the user slice.
#
# Rootless containers inherit their per-process open-files ceiling from
# the parent user@<uid>.service bounding limit, which defaults to
# systemd's DefaultLimitNOFILE (524288 on this Debian/trixie host).
# QuestDB (running inside signalk-server) asks for 1048576 fds and warns
# + risks WAL corruption under heavy ingestion when it gets less, so
# signalk-container clamps the request to the host ceiling and surfaces an
# "open-files limit capped by the host" advisory. The Quadlet's own
# LimitNOFILE=1048576 can't lift the bound on its own — the parent
# user@.service caps it — so we raise the bound here, mirroring the
# user@.service.d/nofile.conf drop-in signalk-container's README prescribes.
#
# Idempotency is by on-disk file content, NOT `systemctl show ... LimitNOFILE`:
# systemctl reports the merged unit definition, while the limit the running
# user@.service actually enforces only changes after re-login. Keying off the
# running value would re-prompt sudo on every re-run until the operator logs
# out and back in; keying off the drop-in's content skips cleanly once written.
section "Open-files limit"
NOFILE_CONF="/etc/systemd/system/user@.service.d/nofile.conf"
if [[ -f "$NOFILE_CONF" ]] && grep -qx 'LimitNOFILE=1048576' "$NOFILE_CONF"; then
    ok "user@.service LimitNOFILE already raised ($NOFILE_CONF present)"
elif [[ "$SUDO" = "MISSING" ]]; then
    warn "Cannot raise user@.service LimitNOFILE without sudo; QuestDB may hit the fd ceiling."
    warn "As root:  install -d -m0755 /etc/systemd/system/user@.service.d && printf '[Service]\\nLimitNOFILE=1048576\\n' > $NOFILE_CONF && systemctl daemon-reload"
else
    info "Writing $NOFILE_CONF (requires sudo)"
    $SUDO install -d -m 0755 "$(dirname "$NOFILE_CONF")"
    $SUDO tee "$NOFILE_CONF" >/dev/null <<EOF
# Installed by signalk-universal-installer.
# Rootless containers (QuestDB inside signalk-server et al.) inherit their
# open-files limit from user@.service; the systemd default
# (DefaultLimitNOFILE=524288) caps QuestDB below the 1048576 it needs and
# risks WAL corruption. Raise the bound so the full limit can be granted.
[Service]
LimitNOFILE=1048576
EOF
    $SUDO systemctl daemon-reload
    ok "Installed $NOFILE_CONF"
    # As with delegation, daemon-reload doesn't re-apply LimitNOFILE to the
    # already-running user@.service instance; a fresh user session (re-login
    # or reboot) is needed before rootless containers see the raised ceiling.
    USER_SERVICE_RELOGIN_HINT=1
    USER_SERVICE_OVERRIDES+="  • $NOFILE_CONF (open-files limit 1048576)"$'\n'
fi

# 5. Groups
section "Group memberships"
# `audio` is what makes rootless /dev/snd passthrough work end-to-end:
# device nodes keep their HOST group (root:audio), and the managed audio
# container (wyoming-satellite) reaches them via the calling user's own
# supplementary groups (crun keep-original-groups), not via a uid map.
# `halpid` exists only after `signalk halpi2 apply` installed the Hat Labs
# daemon; its socket is root:halpid 0660 and the signalk-halpi plugin reaches
# it through this membership (GroupAdd=keep-groups). Silently absent elsewhere.
for g in dialout gpio netdev audio halpid; do
    if getent group "$g" >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
        info "Adding $USER to $g (requires sudo)"
        $SUDO /usr/sbin/usermod -aG "$g" "$USER" || warn "could not add $USER to $g"
    fi
done
ok "groups: dialout, gpio, netdev, audio, halpid (ensured if present on host)"

# 6. Tokens
section "Authentication tokens"
mkdir -p "$UPDATER_DATA" "$DOCTOR_DATA"
# Generate 32 random bytes, base64-encoded. Prefer /dev/urandom (+ base64),
# which are always present, so we don't depend on openssl - it isn't installed
# on every image (e.g. the Fedora podman-machine VM, where this died with
# "openssl: command not found"). Fall back to openssl only if /dev/urandom is
# somehow unreadable.
gen_token() {
    if [[ -r /dev/urandom ]]; then
        head -c 32 /dev/urandom | base64 | tr -d '\n'
    else
        openssl rand -base64 32 | tr -d '\n'
    fi
}
for path in "$UPDATER_DATA/token" "$DOCTOR_DATA/token"; do
    # -s, not -f: (re)generate when the file is missing OR empty. An interrupted
    # earlier run can leave a 0-byte token; with a plain `! -f` check the
    # installer would "preserve" that empty file forever, and the updater/doctor
    # then report "Bearer token unavailable (empty token file)" and run
    # read-only. A non-empty token is still preserved (idempotent).
    if [[ ! -s "$path" ]]; then
        umask 077
        gen_token >"$path"
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
# Fresh detection clobbers operator toggles: detect-hardware.sh always
# emits enabled=false. A re-run of the installer (the documented way to
# refresh templates) used to silently switch off bluetooth/gpio
# passthrough and drop the socketcan candidate. Carry those fields over
# from the previous hardware.json. Per-device serial/can enabled flags
# are NOT carried (the device set itself may have changed; the updater's
# hardware apply flow owns those). The merge filter — and why audio needs
# an explicit has() check rather than jq's `//` — lives in
# lib/hardware-merge.sh, shared with check-hardware-merge.sh.
HW_FRESH=$("$HERE/detect-hardware.sh")
if command -v jq >/dev/null 2>&1 && [[ -s "$UPDATER_DATA/hardware.json" ]]; then
    HW_MERGED=$(hardware_merge "$UPDATER_DATA/hardware.json" <(printf '%s' "$HW_FRESH") 2>/dev/null) \
        && [[ -n "$HW_MERGED" ]] && HW_FRESH="$HW_MERGED"
fi
printf '%s\n' "$HW_FRESH" >"$UPDATER_DATA/hardware.json"
ok "wrote $UPDATER_DATA/hardware.json (operator toggles preserved)"

# 9. Pull images
section "Image pulls"
# Reclaim dangling (<none>) layers before pulling. Every reinstall re-pulls the
# rolling :dirkwa / :latest tags; when a tag's digest has moved, the prior
# digest's layers are orphaned but never reclaimed (nothing else here prunes).
# Across enough reinstalls the rootless store accumulates hundreds of dead
# layers, and on slow SD/eMMC the per-layer commit + metadata rewrite that
# `podman pull` does under the store lock crawls — the "Copying blob …" phase
# appears to hang for many minutes. Dangling-only prune is safe: it never
# touches an image a container references.
if [[ -n "$(podman images -f dangling=true -q 2>/dev/null)" ]]; then
    info "reclaiming dangling image layers from prior installs"
    podman image prune -f >/dev/null 2>&1 || true
fi
# Bound each pull. A stalled pull (slow store, registry hiccup, network path)
# otherwise hangs the installer forever — the bare `podman pull` had no timeout,
# unlike the `timeout 900 podman run` plugin install below. `timeout` exits 124
# on expiry; --retry/--retry-delay cover a transient registry failure (they do
# NOT shorten a slow-but-progressing pull — that is what the timeout bounds).
for img in "$SK_IMAGE" "$UPDATER_IMAGE" "$DOCTOR_IMAGE"; do
    info "pulling $img"
    pull_rc=0
    timeout 900 podman pull --retry 3 --retry-delay 5s "$img" || pull_rc=$?
    if [[ "$pull_rc" -eq 124 ]]; then
        # `timeout` fired: the pull was still running at 900s, not a clean error.
        err "pulling $img did not finish within 900s."
        err "On a Pi this is usually a bloated rootless image store on slow SD"
        err "storage making layer commit crawl. Check and reclaim with:"
        err "    podman system df"
        err "    podman image prune -a -f   # then re-run this installer"
        err "If the store is small, the registry path may be at fault — retry, or"
        err "    podman pull --log-level=debug $img   # to see where it stalls"
        exit 1
    elif [[ "$pull_rc" -ne 0 ]]; then
        err "pulling $img failed (podman exit $pull_rc)."
        err "Inspect the error above; retry, or for detail:"
        err "    podman pull --log-level=debug $img"
        exit 1
    fi
done
ok "all images pulled"

# 10. Quadlet rendering
section "Quadlet rendering"
mkdir -p "$QUADLET_DIR"
# The doctor Quadlet bind-mounts ~/.local/bin for its
# /api/installer/refresh endpoint. On a fresh Pi OS install this
# directory does not exist yet (Debian's ~/.profile only adds it to
# PATH if it's already present), and a missing bind source can
# manifest as a confusing systemd unit-start failure on first run.
# install-{recovery-script,signalk-command}.sh both also mkdir this
# path; the explicit pre-create here removes the dependency on their
# ordering relative to the doctor restart.
mkdir -p "$HOME/.local/bin"

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

# Echo a one-line reason describing how the running signalk-server container
# differs from what the installer just rendered, or empty when they match.
# Truth source is the running container's `.Config.Env` + `.ImageName` +
# `.Image` (the resolved image ID), not Quadlet text — file diffs are noisy
# (template tweaks, the operator-owned user-additions block, hardware-detect
# deltas that have already been picked up by a prior restart). Used to decide
# whether `signalk-server.service` needs a `systemctl --user restart` to apply
# the rewritten Quadlet or a freshly pulled image.
signalk_server_drift_reason() {
    podman container exists signalk-server 2>/dev/null || { echo ""; return 0; }
    local state run_port run_image run_id pulled_id
    state=$(podman inspect signalk-server --format '{{.State.Status}}' 2>/dev/null || echo unknown)
    if [[ "$state" != "running" ]]; then
        echo "container state=$state"
        return 0
    fi
    run_port=$(podman inspect signalk-server \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n 's/^PORT=//p' | head -1)
    run_image=$(podman inspect signalk-server --format '{{.ImageName}}' 2>/dev/null)
    if [[ "$run_port" != "$SK_HTTP_PORT" ]]; then
        echo "PORT env: running=${run_port:-<unset>} rendered=$SK_HTTP_PORT"
        return 0
    fi
    if [[ -n "$run_image" && "$run_image" != "$SK_IMAGE" ]]; then
        echo "image: running=$run_image rendered=$SK_IMAGE"
        return 0
    fi
    # Tag matches but the tag may have MOVED: `:dirkwa` (and `:master`,
    # `:latest`) are rolling tags whose digest changes under a stable name.
    # The image-pull step above already fetched the current digest into local
    # storage, so compare the running container's resolved image ID against
    # what `$SK_IMAGE` now resolves to locally. Without this, a re-run that
    # pulled a newer `:dirkwa` leaves the old container running because the tag
    # string is unchanged — the bug this guard exists to prevent.
    run_id=$(podman inspect signalk-server --format '{{.Image}}' 2>/dev/null)
    pulled_id=$(podman image inspect "$SK_IMAGE" --format '{{.Id}}' 2>/dev/null || echo "")
    if [[ -n "$run_id" && -n "$pulled_id" && "$run_id" != "$pulled_id" ]]; then
        echo "image digest: running=${run_id:0:19} pulled=${pulled_id:0:19}"
        return 0
    fi
    echo ""
}

# Capture a failed unit's status + recent logs to stderr, indented. Shared by
# the signalk-server drift-apply restart and restart_peer_unit so the most
# important restart (the server) gets the same diagnostics the peers already do.
#
# `podman logs` is the authoritative source, not `journalctl --user -u`: rootless
# podman/conmon writes the container's stdout/stderr to the journal under the
# CONTAINER identifier, which `journalctl --user -u <quadlet-unit>` does NOT
# surface — on a typical Pi it returns "No journal files were found" even with a
# persistent journal, so the actual signalk-server startup output (the thing we
# need when a start times out) was invisible. The unit name maps 1:1 to the
# container name (the Quadlet sets ContainerName=<unit-without-.service>). Keep
# the journal line too — harmless, and occasionally carries systemd-side detail.
capture_unit_failure() {
    local unit=$1
    local ctr="${unit%.service}"
    {
        echo "--- systemctl --user status \"$unit\" ---"
        systemctl --user --no-pager --full status "$unit" 2>&1 || true
        echo
        echo "--- podman logs --tail 50 \"$ctr\" ---"
        podman logs --tail 50 "$ctr" 2>&1 || true
        echo
        echo "--- journalctl --user -n 50 -u \"$unit\" ---"
        journalctl --user --no-pager -n 50 -u "$unit" 2>&1 || true
    } | sed 's/^/    /' >&2
}

# A `systemctl --user restart` of a Type=notify (sdnotify=conmon) unit BLOCKS
# until conmon signals ready or TimeoutStartSec elapses, then returns non-zero
# on timeout. But non-zero != "down": on an SD-card host the `podman run
# --replace` create can exceed the timeout, systemd KILLs it, and Restart=always
# silently retries — a later attempt succeeds in seconds. By then the restart
# command has already returned failure. This polls the unit (and an optional
# HTTP health URL) for a grace window so that transient, self-recovering case
# isn't reported as a failure.
#
# Returns 0 as soon as the unit is `active` (and the health URL, if given,
# answers). Short-circuits to 1 the moment the unit reaches `failed`
# (start-limit-hit or a genuine crash that exhausted the burst) — Restart=always
# won't retry from there, so that's a real failure and we stop waiting
# immediately rather than burning the whole window. `is-active` is a
# non-blocking state query, so the loop never hangs. Never aborts under set -e.
#   $1 unit   $2 grace-seconds   $3 (optional) health URL to also require
unit_recovered_within() {
    local unit=$1 secs=$2 health_url=${3:-}
    local start=$SECONDS active
    while (( SECONDS - start < secs )); do
        active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
        if [[ "$active" == "active" ]]; then
            if [[ -z "$health_url" ]] || curl -fsS -o /dev/null -m 5 "$health_url" 2>/dev/null; then
                return 0
            fi
        elif [[ "$active" == "failed" ]]; then
            return 1
        fi
        sleep 3
    done
    return 1
}

# A `systemctl start` that times out (Result: timeout, container KILLed) with no
# crashloop in the journal is, on SD-card hosts especially, almost always
# podman blocking on a DAMAGED or INCOMPLETE overlay layer — an image whose
# extraction was interrupted (a Ctrl-C'd run, a power blip) leaves a layer
# `podman run` can't mount, so conmon never signals ready and systemd kills it
# at TimeoutStartSec. `podman system check --quick` reports this without
# mutating anything; if it finds trouble we print the exact (operator-run,
# non-destructive-first) repair recipe. We do NOT auto-repair: rewriting the
# rootless store unprompted mid-install is riskier than telling the operator
# what to run. Best-effort and never fatal — a podman without `system check`
# (very old) just yields no extra output.
#
# Predicate return: 0 = damage found (and recipe printed), 1 = store clean.
# Call sites need `|| true` because under `set -e` the bare 1 would abort the
# installer; the value is exposed so a future caller can branch on it.
warn_if_storage_damaged() {
    command -v podman >/dev/null 2>&1 || return 0
    local report
    report=$(podman system check --quick 2>&1) || true
    # `--quick` prints "Damaged layer ..." / "incomplete layer" when the store
    # is inconsistent, and nothing (exit 0) when it's clean.
    if printf '%s' "$report" | grep -qiE 'damaged layer|incomplete layer|layer content modified'; then
        warn "podman's image store has damaged/incomplete layers — this is the usual"
        warn "cause of a server start that times out without crash-looping (an"
        warn "interrupted image pull on slow SD-card storage). Recover with:"
        warn "    systemctl --user stop signalk-server signalk-updater-server signalk-doctor-server"
        warn "    podman system check --repair && podman system prune -f"
        warn "    podman pull ${SK_IMAGE:-ghcr.io/dirkwa/signalk-server:dirkwa}"
        warn "    systemctl --user start signalk-doctor-server signalk-updater-server signalk-server"
        warn "  If it still fails, the heavier reset (preserves ~/.signalk data, which"
        warn "  is bind-mounted): podman system reset -f  then re-run this installer."
        return 0
    fi
    return 1
}

snapshot_existing signalk-server.container
snapshot_existing signalk-updater-server.container
snapshot_existing signalk-doctor-server.container

SERVER_QUADLET=$("$HERE/render-server-quadlet.sh" "$UPDATER_DATA/hardware.json" "$HERE/../../quadlets/signalk-server.container.template" \
    | sed -e "s/__SK_HTTP_PORT__/${SK_HTTP_PORT}/g")
atomic_write "$QUADLET_DIR/signalk-server.container" "$SERVER_QUADLET"

# Substitute both the publish host (set earlier from SIGNALK_LOCALHOST_ONLY)
# AND the resolved engine image. The image-pinning rationale lives next to
# the UPDATER_IMAGE / DOCTOR_IMAGE resolution above. `|` separator on the
# Image= line because the image contains `/`.
UPDATER_QUADLET=$(sed \
    -e "s/__PUBLISH_HOST__/${PUBLISH_HOST}/g" \
    -e "s/__SK_HTTP_PORT__/${SK_HTTP_PORT}/g" \
    -e "s|__UPDATER_IMAGE__|${UPDATER_IMAGE}|g" \
    "$HERE/../../quadlets/signalk-updater-server.container.template")
atomic_write "$QUADLET_DIR/signalk-updater-server.container" "$UPDATER_QUADLET"

DOCTOR_QUADLET=$(sed \
    -e "s/__PUBLISH_HOST__/${PUBLISH_HOST}/g" \
    -e "s/__SK_HTTP_PORT__/${SK_HTTP_PORT}/g" \
    -e "s/__SK_HTTPS_PORT__/${SK_HTTPS_PORT}/g" \
    -e "s|__DOCTOR_IMAGE__|${DOCTOR_IMAGE}|g" \
    "$HERE/../../quadlets/signalk-doctor-server.container.template")
atomic_write "$QUADLET_DIR/signalk-doctor-server.container" "$DOCTOR_QUADLET"

# DBus auth proxy sidecar — only where the host actually runs a system
# bus (the quadlet bind-mounts /run/dbus; writing it on a busless host
# would give a unit that fail-loops on start). Written unconditionally
# when the bus exists — even with bluetooth disabled — so the updater's
# hardware-apply toggle can enable BLE later without needing the
# installer tree present. Removed again if the host lost its bus so a
# stale unit can't crash-loop.
if [[ -S /run/dbus/system_bus_socket ]]; then
    snapshot_existing signalk-dbus-proxy.container
    PROXY_QUADLET=$(sed \
        -e "s|__PROXY_IMAGE__|${PROXY_IMAGE}|g" \
        "$HERE/../../quadlets/signalk-dbus-proxy.container.template")
    atomic_write "$QUADLET_DIR/signalk-dbus-proxy.container" "$PROXY_QUADLET"
elif [[ -f "$QUADLET_DIR/signalk-dbus-proxy.container" ]]; then
    warn "host system D-Bus socket gone — removing stale signalk-dbus-proxy quadlet"
    snapshot_existing signalk-dbus-proxy.container
    rm -f "$QUADLET_DIR/signalk-dbus-proxy.container"
fi

ok "Quadlets written to $QUADLET_DIR"

# Stage the doctor's refresh payload from the tree we already fetched: the
# same raw templates + detect-hardware.sh that the doctor's
# /api/installer/refresh pulls from Pages into
# ~/.signalk-doctor/installer-payload. Staging them at install time means
# `signalk bluetooth enable` can render the dbus-proxy quadlet right after
# a fresh install (no `signalk update` round-trip first), and the doctor's
# first refresh after an install reports "unchanged" instead of a
# confusing "updated" for artifacts the installer just laid down live.
# Modes match the refresh writer (0755 script, 0644 templates).
PAYLOAD_DIR="$DOCTOR_DATA/installer-payload"
mkdir -p "$PAYLOAD_DIR"
install -m 0755 "$HERE/detect-hardware.sh" "$PAYLOAD_DIR/detect-hardware.sh"
# render-server-quadlet.sh is staged too so `signalk render-server` (and the
# render step chained off `signalk update`) can rebuild the live
# signalk-server.container from the staged template on an existing box —
# template-only fixes (e.g. Timezone=local) otherwise never reach a deployed
# install without a full re-run of the bash bootstrapper (issue #217). Like
# detect-hardware.sh it's fetched-not-invoked by the doctor; the host CLI runs
# it. 0755 — it's an executable script.
install -m 0755 "$HERE/render-server-quadlet.sh" "$PAYLOAD_DIR/render-server-quadlet.sh"
# signalk-halpi2.tmpl is staged so a box that predates the CLI copy can still
# run `signalk halpi2` from the payload after `signalk update` (the doctor
# refresh list is what keeps it current). Self-contained: sources no lib.
install -m 0755 "$HERE/signalk-halpi2.tmpl" "$PAYLOAD_DIR/signalk-halpi2.tmpl"
# Stage the libs those scripts source, or the staged copies cannot run.
# detect-hardware.sh sources lib/distro.sh unconditionally and died with
# "lib/distro.sh: No such file or directory" — the staged copy was inert in the
# literal sense, not the intended one. hardware-merge.sh is what
# `signalk hardware rescan` needs to carry operator toggles across a re-detect,
# exactly as the installer's own detect step does.
install -d -m 0755 "$PAYLOAD_DIR/lib"
for _l in distro.sh hardware-merge.sh; do
    install -m 0644 "$HERE/lib/$_l" "$PAYLOAD_DIR/lib/$_l"
done
for t in signalk-server signalk-updater-server signalk-doctor-server signalk-dbus-proxy; do
    install -m 0644 "$HERE/../../quadlets/${t}.container.template" \
        "$PAYLOAD_DIR/${t}.container.template"
done
ok "doctor refresh payload staged in $PAYLOAD_DIR"

# 11. daemon-reload
section "systemd-user daemon-reload"
systemctl --user daemon-reload
ok "daemon-reload OK"

# 11a. Install host CLI tools (`signalk` + `signalk-recovery`) BEFORE any
# container restart that might fail. Two reasons:
#
# 1) `signalk uninstall` and `signalk bug-report` must be available to the
#    operator when a peer-container start fails downstream. Installing the
#    CLI after the failure point (as previous versions did) left the
#    operator with no installer-provided way to clean up or gather logs.
# 2) The doctor Quadlet bind-mounts `~/.local/bin` (for the doctor's
#    /api/installer/refresh endpoint). install-recovery-script.sh and
#    install-signalk-command.sh both `mkdir -p ~/.local/bin`, so running
#    them here guarantees the source path exists before the doctor unit
#    starts. (PR2 makes the mkdir explicit at Quadlet-render time as
#    belt-and-braces against future re-ordering.)
section "Host CLI tools"
bash "$HERE/install-recovery-script.sh"
INSTALLER_VERSION="$INSTALLER_VERSION" bash "$HERE/install-signalk-command.sh"
bash "$HERE/install-socketcan-script.sh"
bash "$HERE/install-bluetooth-script.sh"
bash "$HERE/install-halpi2-script.sh"

# Container DNS self-heal (signalk-resolv-watch.path/.service): recreates
# signalk-server if the boot beat DHCP and the container snapshotted an
# empty /etc/resolv.conf (app store offline until restart). The unit
# content lives in the CLI as the single owner — same no-drift rationale
# as render-server-quadlet.sh — so install the units by calling the
# command installed just above. Existing boxes get the same call via
# `signalk update` → render-server.
if ! "$HOME/.local/bin/signalk" resolv-watch; then
    warn "could not install the signalk-resolv-watch units; a boot that beats"
    warn "DHCP may leave the app store offline until signalk-server restarts."
fi

# pasta gateway self-heal (signalk-netgate-watch.timer/.service): restarts an
# engine container that latched onto a stale gateway when it started before
# the host had a route, leaving host.containers.internal black-holed for the
# container's lifetime. The engine Quadlets' ExecStartPre route gate covers
# the fast case; this covers a router that takes minutes, and repairs boxes
# whose Quadlets predate that gate. Same single-owner rationale as above.
if ! "$HOME/.local/bin/signalk" netgate-watch; then
    warn "could not install the signalk-netgate-watch units; a container that"
    warn "starts before the host has a route may stay unreachable until restarted."
fi

# 11a-bis. CPU priority: rank the SK stack above the plugin containers.
#
# cgroup v2 cpu.weight compares siblings only. The Quadlet units (signalk-
# server, updater, doctor) live in the user manager's app.slice; the
# containers signalk-container starts through the podman socket (sk-questdb,
# sk-grafana, chart-import jobs, ...) land in its user.slice. Both slices sit
# at weight 100, so a chart import saturating every core takes half the CPU
# from signalk-server. Raising app.slice to 300 gives the SK stack 3:1 under
# contention and changes nothing on an idle host — it is a weight, not a cap.
# The per-container tiers inside user.slice are signalk-container's job.
#
# A user-manager drop-in, no sudo. daemon-reload applies the new weight to the
# running slice (verified live: app.slice/cpu.weight reads 300 within a couple
# of seconds); removing the file later does NOT restore 100 until re-login,
# which is why both uninstall paths also run `set-property --runtime`. Placed
# after the watcher installs above on purpose: on Windows the podman machine
# creates ~/.config/systemd/user as root, and `signalk resolv-watch` is what
# reclaims it (#260) — an earlier mkdir here would fail on every fresh
# Windows install.
section "CPU priority"
CPU_PRIORITY_DIR="$HOME/.config/systemd/user/app.slice.d"
CPU_PRIORITY_CONF="$CPU_PRIORITY_DIR/50-signalk-cpu-priority.conf"
CPU_PRIORITY_DESIRED='# Installed by signalk-universal-installer.
# signalk-server and the engine consoles run in this slice; the containers
# signalk-container manages run in user.slice next to it. Weight ranks the two
# under CPU contention only (3:1) and never caps either.
[Slice]
CPUWeight=300'
# Keyed on the presence of a CPUWeight= line, not the exact value, so an
# operator who tuned the weight keeps it across re-runs (same rule as the
# podman.service TasksMax drop-in above).
if [[ -f "$CPU_PRIORITY_CONF" ]] && grep -Eq '^[[:space:]]*CPUWeight[[:space:]]*=' "$CPU_PRIORITY_CONF"; then
    ok "app.slice CPUWeight already set ($CPU_PRIORITY_CONF: $(grep -E '^[[:space:]]*CPUWeight[[:space:]]*=' "$CPU_PRIORITY_CONF" | head -1))"
elif mkdir -p "$CPU_PRIORITY_DIR" 2>/dev/null \
    && printf '%s\n' "$CPU_PRIORITY_DESIRED" > "$CPU_PRIORITY_CONF"; then
    if systemctl --user daemon-reload; then
        ok "app.slice CPUWeight=300 applied (SK stack outranks plugin containers 3:1 under contention)"
    else
        warn "Wrote $CPU_PRIORITY_CONF but daemon-reload failed; CPUWeight=300 takes effect on the next login"
    fi
else
    warn "Could not write $CPU_PRIORITY_CONF; SK stack shares CPU 1:1 with plugin containers under contention"
fi

# 11b. signalk-server drift apply
# Re-runs of the installer may change PORT, the image tag (operator picks
# standard ports at the prompt, or bumps the engine channel), or the image
# DIGEST behind an unchanged rolling tag (`:dirkwa` moved since last run, and
# the pull step above fetched it). The rewritten Quadlet is on disk and
# daemon-reload above has parsed it, but the running container keeps its old
# env and image until the unit is restarted — `systemctl restart` recreates
# the container from the Quadlet, so it picks up the just-pulled image. The
# peer-restart block below uses `restart` for doctor+updater for exactly this
# reason; signalk-server needs the same treatment, gated on observable drift
# so no-change re-runs (token refresh, journald drop-in, recovery-script
# regeneration) leave the running container alone.
section "signalk-server"
SK_DRIFT_REASON=$(signalk_server_drift_reason)
if ! podman container exists signalk-server 2>/dev/null; then
    ok "signalk-server not yet running (will start in a later step)"
elif [[ -z "$SK_DRIFT_REASON" ]]; then
    ok "signalk-server matches rendered Quadlet (no restart needed)"
else
    info "config changed: $SK_DRIFT_REASON"
    info "restarting signalk-server.service to apply"
    if systemctl --user restart signalk-server.service; then
        ok "signalk-server restarted"
    elif unit_recovered_within signalk-server.service 120 "$SIGNALK_URL"; then
        # The blocking restart returned non-zero — a start-timeout under SD-card
        # I/O contention, not a fault. Restart=always brought the unit back and
        # it now answers HTTP. Common, self-healing; report it as recovery, not
        # a failure (the alarming `[!]` + empty `podman logs` from the --rm'd
        # container was pure noise here).
        ok "signalk-server recovered after a slow start (SD-card I/O contention)"
    else
        warn "systemctl --user restart signalk-server.service failed and did not recover — capturing diagnostics:"
        capture_unit_failure signalk-server.service
        # A timeout here can also be a damaged overlay layer, not just a slow
        # start; surface the repair recipe when the store is inconsistent.
        warn_if_storage_damaged || true
        warn "continuing — the 'signalk' CLI is already installed for recovery (signalk bug-report, signalk uninstall)"
    fi
fi

# 12. (Re)start doctor + updater
# `restart` instead of `start` so a re-run picks up the rewritten Quadlet
# even when the unit is already active. `systemctl start` on an active unit
# is a no-op — the old container keeps running and the new `Image=` line
# on disk goes unused until the next reboot. `restart` is equivalent to
# `start` for inactive units, so the first-boot path is unaffected.
#
# Failure handling: a bare `systemctl restart` exits non-zero and, under
# `set -e`, would abort the whole installer here. That hides the actual
# reason from the operator (systemd only prints "control process exited
# with error code") AND skips the rest of the install — including the
# health-check warns, the bundled plugin install, and (most painfully)
# the `signalk` CLI install that the operator would need for
# `signalk bug-report` or `signalk uninstall`. So restart_peer_unit
# captures status + the recent journal inline and returns non-zero
# without aborting; the downstream wait_for_http retries cover the case
# where the unit recovers on its own.
section "(Re)starting peer containers"
restart_peer_unit() {
    local unit=$1
    if systemctl --user restart "$unit"; then
        ok "$unit restarted"
        return 0
    fi
    # Same transient-timeout reasoning as signalk-server: let Restart bring it
    # back before alarming. No HTTP arg — the dedicated wait_for_http health
    # checks below confirm the peers — so we only require the unit to reach
    # `active` (the failed-state short-circuit still bails fast on a real crash).
    if unit_recovered_within "$unit" 90; then
        ok "$unit recovered after a slow start"
        return 0
    fi
    warn "$unit failed to restart and did not recover — capturing diagnostics:"
    capture_unit_failure "$unit"
    warn_if_storage_damaged || true
    warn "continuing — health checks below will retry, and 'signalk bug-report' captures full state"
    return 1
}
restart_peer_unit signalk-doctor-server.service || true
restart_peer_unit signalk-updater-server.service || true
# The dbus proxy is best-effort: it only exists where the host has a
# system bus, and only matters once bluetooth passthrough is enabled.
if [[ -f "$QUADLET_DIR/signalk-dbus-proxy.container" ]]; then
    restart_peer_unit signalk-dbus-proxy.service || true
fi

# 13. Wait for health (first-boot tolerant per R1.3)
section "Health checks"
if wait_for_http "${DOCTOR_URL}/api/health" 180; then
    ok "doctor responding on ${DOCTOR_URL}"
else
    warn "doctor did not respond within 180s; check 'podman logs signalk-doctor-server'"
fi
if wait_for_http "${UPDATER_URL}/api/health" 180; then
    ok "updater responding on ${UPDATER_URL}"
else
    warn "updater did not respond within 180s; check 'podman logs signalk-updater-server'"
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
# Support libraries (not plugins — no auto-enable, no appstore entry).
# tz-lookup: 70KB pure-JS lat/lon → IANA-zone lookup the host's
# signalk-timesync agent invokes inside the container (the host has no
# Node; the container has no timezone-setting powers — each side does
# what only it can).
SK_LIBS=(tz-lookup)
mkdir -p "$HOME/.signalk"

# Cold install of three plugins + their transitive deps over the network
# is silent (output goes to $NPM_LOG, --no-progress) and routinely takes a
# few minutes on a fresh VM. Say so up front and tail-able, so the operator
# doesn't read the quiet as a hang.
info "running 'npm install' inside the signalk-server image"
info "cold install pulls 3 plugins + deps — can take a few minutes"
# UserNS mapping: the signalk-server image runs as `node` (UID 1000).
# Bare --userns=keep-id maps the invoking HOST user's UID to the same
# number inside — but on hosts where the invoking user isn't UID 1000
# (e.g. `dirk` at 1001 because `pi` already owned 1000), that leaves
# in-container `node` mapped to some unrelated subuid that can't read
# ~/.signalk (owned by the host user, mode 0700). The explicit form
# maps host-user → in-container UID 1000 regardless of host UID, so
# the bind mount is owned by `node` from inside. Identity mapping
# when the host user already is 1000.
#
# Capture output: previously this ran with >/dev/null 2>&1 so the
# only signal on failure was the generic "npm install failed" warn —
# operators had to re-run the command by hand to see what broke.
# Now we tee npm's output to a temp file and replay it inline when
# the install fails, while still keeping the success path quiet.
NPM_LOG=$(mktemp)
info "  npm output → $NPM_LOG (tail -f to watch)"
# Heartbeat: the install is silent, so emit an elapsed-seconds tick every
# 15s while it runs. Backgrounded, then killed the moment the install
# returns so it never outlives the step.
npm_heartbeat() {
    local s=0
    while sleep 15; do
        s=$((s + 15))
        info "  still installing… (${s}s elapsed)"
    done
}
npm_heartbeat & NPM_HB=$!
# Stop the heartbeat on any exit (incl. Ctrl+C / signal) so it never outlives
# the step. On EXIT, cleanup only. On INT/TERM, cleanup then re-raise the
# signal with the default handler so the interrupt still aborts the
# installer — a cleanup-only INT/TERM trap would swallow Ctrl+C and let the
# install run on.
npm_hb_cleanup() { kill "$NPM_HB" 2>/dev/null || true; wait "$NPM_HB" 2>/dev/null || true; }
trap npm_hb_cleanup EXIT
trap 'npm_hb_cleanup; trap - INT; kill -INT $$' INT
trap 'npm_hb_cleanup; trap - TERM; kill -TERM $$' TERM
# Watchdog: bound the run so a wedged npm/registry fails with the captured
# log replayed (below) instead of hanging the installer forever. `timeout`
# exits 124 on expiry; the failure branch already replays $NPM_LOG.
NPM_RC=0
timeout 900 podman run --rm \
    --userns=keep-id:uid=1000,gid=1000 \
    -v "$HOME/.signalk:/home/node/.signalk:Z" \
    --entrypoint sh \
    "$SK_IMAGE" \
    -c "cd /home/node/.signalk && npm install --ignore-scripts --no-audit --no-fund --no-progress ${SK_PLUGINS[*]} ${SK_LIBS[*]}" >"$NPM_LOG" 2>&1 || NPM_RC=$?
npm_hb_cleanup
trap - EXIT INT TERM
if [[ "$NPM_RC" -eq 0 ]]; then
    rm -f "$NPM_LOG"
    for p in "${SK_PLUGINS[@]}"; do
        if [[ -d "$HOME/.signalk/node_modules/$p" ]]; then
            v=$(grep -m1 '"version"' "$HOME/.signalk/node_modules/$p/package.json" 2>/dev/null \
                | sed 's/.*"\([0-9][^"]*\)".*/\1/')
            ok "$p@${v:-?}"
        else
            warn "$p — install reported ok but module dir is missing"
        fi
    done
    for p in "${SK_LIBS[@]}"; do
        if [[ -d "$HOME/.signalk/node_modules/$p" ]]; then
            ok "$p (support library)"
        else
            warn "$p — install reported ok but module dir is missing"
        fi
    done
else
    if [[ "$NPM_RC" -eq 124 ]]; then
        warn "npm install timed out after 900s; plugins not installed. Install from the SignalK appstore later."
    else
        warn "npm install failed; plugins not installed. Install from the SignalK appstore later."
    fi
    warn "npm output:"
    sed 's/^/    /' "$NPM_LOG" >&2
    rm -f "$NPM_LOG"
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

# Seed sslport so HTTPS lands on the chosen port once the operator
# enables TLS (e.g. via the signalk-ssl plugin). We write ONLY when the
# standard-ports path was chosen AND the key is absent — never clobber a
# value the user set, and never set `ssl: true` (that's the user's
# decision; the SSLPORT env var would force it on before a cert exists,
# which is why we use settings.json, not env, for the HTTPS port).
if [[ "$PRIV_PORTS" = "1" ]] && command -v jq >/dev/null 2>&1; then
    settings="$HOME/.signalk/settings.json"
    [[ -f "$settings" ]] || echo '{}' >"$settings"
    if [[ "$(jq -r 'has("sslport")' "$settings" 2>/dev/null)" != "true" ]]; then
        tmp=$(mktemp "${settings}.XXXXXX")
        if jq --argjson p "$SK_HTTPS_PORT" '.sslport = $p' "$settings" >"$tmp" 2>/dev/null; then
            mv -f "$tmp" "$settings"
            ok "seeded sslport=${SK_HTTPS_PORT} in settings.json (HTTPS uses it once you enable SSL)"
        else
            rm -f "$tmp"
            warn "could not seed sslport into settings.json; set SSL Port=${SK_HTTPS_PORT} in the admin UI"
        fi
    else
        ok "settings.json already has sslport (leaving as-is)"
    fi
fi

# Seed the vessel identity gathered up top into ~/.signalk/baseDeltas.json
# — the same file the admin UI's Server → Settings page writes through
# PUT /skServer/vessel — so it starts pre-filled on first boot. The
# shape must match what the server's DeltaEditor produces for top-level
# paths: ONE values entry with path "" whose value is an object keyed by
# name/mmsi/communication — per-path entries would replay into the data
# model but stay invisible to getSelfValue(), leaving the settings page
# empty. MMSI stays a string (the server rejects numeric mmsi). Without
# an MMSI we must mint the self UUID ourselves: the server only
# auto-generates one when baseDeltas.json is absent entirely, and a
# vessel without mmsi or uuid has no self identity. Guarded at prompt
# time AND here: never overwrite an existing baseDeltas.json, and never
# create one next to a legacy defaults.json it would shadow.
if [[ "$VESSEL_SEED" = "1" ]] && command -v jq >/dev/null 2>&1; then
    base_deltas="$HOME/.signalk/baseDeltas.json"
    if [[ -e "$base_deltas" || -e "$HOME/.signalk/defaults.json" ]]; then
        ok "vessel identity already present (leaving as-is)"
    else
        vessel_uuid=""
        if [[ -z "$VESSEL_MMSI" ]]; then
            vessel_uuid="urn:mrn:signalk:uuid:$(cat /proc/sys/kernel/random/uuid)"
        fi
        tmp=$(mktemp "${base_deltas}.XXXXXX")
        if jq -n --arg name "$VESSEL_NAME" --arg mmsi "$VESSEL_MMSI" \
            --arg cs "$VESSEL_CALLSIGN" --arg uuid "$vessel_uuid" '
            [{context: "vessels.self", updates: [{values: [{path: "", value: (
                (if $name != "" then {name: $name} else {} end)
                + (if $mmsi != "" then {mmsi: $mmsi} else {} end)
                + (if $uuid != "" then {uuid: $uuid} else {} end)
                + (if $cs != "" then {communication: {callsignVhf: $cs}} else {} end)
            )}]}]}]' >"$tmp" 2>/dev/null; then
            mv -f "$tmp" "$base_deltas"
            # signalk-server reads vessel identity from baseDeltas.json ONCE at
            # startup (into app.config.vesselName, which the admin UI Vessel form
            # displays). If the server is already running (a re-run), it won't
            # pick up the just-seeded name until restarted - so flag a restart.
            NEED_SERVER_RESTART=1
            vessel_label="${VESSEL_NAME:+name ${VESSEL_NAME}, }${VESSEL_MMSI:+MMSI ${VESSEL_MMSI}, }${VESSEL_CALLSIGN:+call sign ${VESSEL_CALLSIGN}, }"
            ok "seeded vessel identity (${vessel_label%, }) into baseDeltas.json"
        else
            rm -f "$tmp"
            warn "could not write baseDeltas.json; set vessel data in the admin UI (Server → Settings)"
        fi
    fi
fi

# Seed admin credentials into ~/.signalk/security.json (+ settings.json's
# security.strategy) BEFORE the first start, so signalk-server comes up
# already secured — no window where the LAN sees the "create an account"
# screen. The bcrypt hash is computed inside the signalk-server image
# with the server's own bcryptjs, so it's bit-compatible with what the
# server writes itself and nothing needs installing on the host. The
# password is piped on stdin (never argv/env) and the node script mints
# a stable secretKey — without one the server generates a fresh random
# key every boot, logging everyone (and the doctor token) out on each
# restart. settings.json's security.strategy is what actually switches
# auth on; security.json alone does nothing. Both writes are guarded:
# never overwrite an existing security.json users[] array, never clobber
# an existing security.strategy.
if [[ "$ADMIN_SEED" = "1" ]]; then
    section "Admin login"
    sk_sec_host="$HOME/.signalk/security.json"
    if [[ -f "$sk_sec_host" ]] && command -v jq >/dev/null 2>&1 \
        && [[ "$(jq -r 'has("users")' "$sk_sec_host" 2>/dev/null)" = "true" ]]; then
        ok "security.json already has users (leaving credentials as-is)"
    elif sec_result=$(printf '%s' "$ADMIN_PASSWORD" | podman run --rm -i \
        --userns=keep-id:uid=1000,gid=1000 \
        -v "$HOME/.signalk:/home/node/.signalk:Z" \
        --workdir /home/node/signalk \
        --entrypoint node \
        "$SK_IMAGE" \
        -e '
            const fs = require("fs");
            const crypto = require("crypto");
            const bcrypt = require("bcryptjs");
            const path = "/home/node/.signalk/security.json";
            const username = process.argv[1];
            const password = fs.readFileSync(0, "utf8");
            const config = fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, "utf8")) : {};
            if (Array.isArray(config.users) && config.users.length) {
                console.log("exists");
                process.exit(0);
            }
            if (!config.secretKey) config.secretKey = crypto.randomBytes(256).toString("hex");
            if (typeof config.allow_readonly !== "boolean") config.allow_readonly = false;
            config.users = [{ username, type: "admin", password: bcrypt.hashSync(password, bcrypt.genSaltSync(10)) }];
            fs.writeFileSync(path + ".tmp", JSON.stringify(config, null, 2), { mode: 0o600 });
            fs.renameSync(path + ".tmp", path);
            console.log("created");
        ' "$ADMIN_USER" 2>/dev/null); then
        # Switch auth on. settings.json may not exist yet; jq seeds it.
        sk_settings="$HOME/.signalk/settings.json"
        [[ -f "$sk_settings" ]] || echo '{}' >"$sk_settings"
        if command -v jq >/dev/null 2>&1 \
            && [[ "$(jq -r 'has("security")' "$sk_settings" 2>/dev/null)" != "true" ]]; then
            tmp=$(mktemp "${sk_settings}.XXXXXX")
            if jq '.security = {strategy: "./tokensecurity"}' "$sk_settings" >"$tmp" 2>/dev/null; then
                mv -f "$tmp" "$sk_settings"
            else
                rm -f "$tmp"
                warn "could not enable security in settings.json; set it in the admin UI"
            fi
        fi
        if [[ "$sec_result" = "exists" ]]; then
            ok "security.json already had users (left as-is)"
        else
            # New security only takes effect when the server (re)reads it; on an
            # already-running re-run, restart so auth actually switches on.
            NEED_SERVER_RESTART=1
            ok "created admin user '$ADMIN_USER' — server starts secured"
        fi
    else
        warn "could not seed admin credentials; server will start UNSECURED — set up security in the admin UI"
        ADMIN_UNSECURED=1
    fi
fi
# Don't keep the plaintext password around any longer than necessary.
unset ADMIN_PASSWORD

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
if [[ "$NEED_SERVER_RESTART" = "1" ]] \
    && systemctl --user is-active --quiet signalk-server.service; then
    # Server is already up and we seeded config it only reads at startup
    # (vessel name / security). `start` is a no-op on a running unit, so the new
    # config would never load - restart to apply it.
    info "restarting signalk-server to apply newly seeded config"
    systemctl --user restart signalk-server.service
elif [[ -n "$UP_TOKEN" ]]; then
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

# 15a. Realign the rootless podman API service with the containers' pause
# namespace — done HERE, after the LAST container start above, deliberately.
#
# Rootless podman runs every container under a shared "pause process" whose
# user namespace the containers join. `podman system migrate` (early in this
# run) and starting a `--userns=keep-id` container (signalk-server, just above)
# both (re)create that pause process — so the pause namespace is only final
# once the last container is up. The socket-activated `podman system service`
# (the API the doctor/updater dockerode clients talk to over the bind-mounted
# podman.sock) keeps whatever namespace it had when IT last (re)started. If
# that predates the final pause process, the service sits in a SIBLING user
# namespace it has no authority over, and every API call that must enter a
# container's mount namespace (exec, getArchive, cp) fails with
# `crun: open /proc/<pid>/ns/mnt: Permission denied`. The podman CLI is
# immune (it spawns fresh in the right namespace), so the break is invisible
# until a socket consumer hits it — observed as the doctor's drift scan
# reporting a baffling "Permission denied" reading package.json out of
# signalk-server, while a shell `podman exec` on the same file worked.
#
# Restart ONLY podman.service (never podman.socket): cycling the service makes
# it rejoin the now-final pause namespace, while the socket inode stays put so
# the already-running containers keep their valid file bind-mount of the
# socket (a podman.socket restart would swap the inode and strand every running
# consumer on a dead socket). The socket-activated service respawns on the next
# connection — the health checks below and the engines' own polling trigger it.
# Guarded on "already active" so a first-boot run where the service never came
# up is a clean no-op.
if systemctl --user is-active --quiet podman.service 2>/dev/null; then
    info "Realigning podman API service with the containers' pause namespace"
    systemctl --user restart podman.service >/dev/null 2>&1 \
        || warn "Could not restart podman.service; the API user namespace may be stale (socket exec/cp may fail with 'Permission denied')"
fi

# 15a-bis. Reap superseded image layers now that the containers run the new ones.
#
# The pre-pull prune (step 9) clears dangling layers left by EARLIER installs,
# but the layers this run supersedes only become dangling AFTER the containers
# are recreated onto the freshly pulled images — which is now (the server +
# peer restarts above have happened). When a rolling tag (:dirkwa / :latest)
# moved, its prior digest is no longer referenced by any tag or running
# container, so a dangling-only prune reclaims it here instead of leaving it to
# accumulate until the next install's pre-pull sweep.
#
# Dangling-only (never `-a`): a prune that removed unused-but-TAGGED images
# would delete a previous signalk-server version the operator deliberately kept
# for rollback. First installs and no-change re-runs leave nothing dangling, so
# this is a clean no-op there. Best-effort — never fail the install over GC.
if [[ -n "$(podman images -f dangling=true -q 2>/dev/null)" ]]; then
    info "Reclaiming image layers superseded by this install"
    podman image prune -f >/dev/null 2>&1 || true
fi

# 15b. Provision a doctor-scoped admin token for signalk-server's
# /skServer/diagnostics endpoint.
#
# The doctor's drift scanner needs an admin token to call signalk-
# server's diagnostics endpoint (the GET shipped in SignalK PR #2702).
# Without this file the scanner permanently reports "offline" with the
# Last successful scan as "never". The doctor itself can't generate
# this token — it has no access to signalk-server's security.json
# — so the installer does it here, while we still have podman exec
# rights against the freshly-started signalk-server container.
#
# Idempotency: if a non-empty token already lives at the target path,
# leave it alone. Re-running the installer must not churn the token
# (which would not be a problem on its own, but operators who later
# rotate the admin password expect their replacement token to survive).
#
# Security gate: signalk-server may not have security enabled yet on
# a brand-new install. We check for security.json's `users[]` array
# before attempting; if security isn't enabled the warning explains
# the next step (enable security in the admin UI, then re-run).
DOCTOR_TOKEN_PATH="$HOME/.signalk-doctor/signalk-token"
SK_TOKEN_BIN=/home/node/signalk/node_modules/signalk-server/bin/signalk-generate-token
SK_SECURITY_PATH=/home/node/.signalk/security.json
section "Doctor admin token"
# This step is OPTIONAL and best-effort: it mints a token so the doctor's drift
# scanner can hit the admin-gated diagnostics endpoint. It only does anything
# when the server is secured (has users), and it must NEVER fail the install -
# the stack is fully up by this point. The `podman exec` probes below can return
# non-zero in ways that aren't already in an `if`-condition position (e.g. exit
# 125 if the container's exec path hiccups), which under `set -e` would abort the
# whole install. Guard the section by relaxing `set -e` for it, then restore.
set +e
# The token's `id` claim must match an admin in security.json's users[].
sk_admin_user="$ADMIN_USER"
if [[ -z "$sk_admin_user" ]] && command -v jq >/dev/null 2>&1; then
    sk_admin_user=$(jq -r '[.users[]? | select(.type == "admin")][0].username // empty' \
        "$HOME/.signalk/security.json" 2>/dev/null)
fi
[[ -z "$sk_admin_user" ]] && sk_admin_user="admin"
if [[ -s "$DOCTOR_TOKEN_PATH" ]]; then
    ok "doctor token already present at $DOCTOR_TOKEN_PATH (skipping)"
elif ! podman exec signalk-server test -s "$SK_SECURITY_PATH" 2>/dev/null; then
    warn "signalk-server has no security.json yet — re-run with SIGNALK_ADMIN_USER/SIGNALK_ADMIN_PASSWORD, or set up security in the admin UI then re-run"
    warn "without this, the doctor's drift scan stays offline ('Last successful scan: never')"
elif ! podman exec signalk-server grep -q '"users"' "$SK_SECURITY_PATH" 2>/dev/null; then
    warn "signalk-server security.json exists but has no users — finish security setup in the admin UI, then re-run"
else
    # The token generator writes to stdout. -e 5y is long enough that we
    # don't need to babysit rotation. The doctor invalidates its own
    # cache on 401/403, so rotating later is "regenerate, overwrite this
    # file" — no doctor restart needed.
    if token=$(podman exec signalk-server "$SK_TOKEN_BIN" -u "$sk_admin_user" -e 5y -s "$SK_SECURITY_PATH" 2>/dev/null); then
        if [[ -n "$token" ]]; then
            mkdir -p "$(dirname "$DOCTOR_TOKEN_PATH")"
            old_umask=$(umask)
            umask 077
            printf '%s' "$token" >"$DOCTOR_TOKEN_PATH"
            umask "$old_umask"
            chmod 0600 "$DOCTOR_TOKEN_PATH"
            ok "wrote doctor token to $DOCTOR_TOKEN_PATH (mode 0600)"
        else
            warn "signalk-generate-token produced empty output; doctor drift will stay offline"
        fi
    else
        warn "signalk-generate-token failed; doctor drift will stay offline"
        warn "you can retry with:  podman exec signalk-server $SK_TOKEN_BIN -u $sk_admin_user -e 5y -s $SK_SECURITY_PATH"
    fi
fi
set -e   # end of the relaxed-set-e doctor-token section

# 15c. HALPI2 Signal K connections. When hardware.json says the board is a
# HALPI2, create the NMEA 2000 (can0) and RS-485 (/dev/ttyAMA4) connections
# through the server's admin API with the token written just above — the
# server randomises the N2K unique number and starts the providers itself,
# so nothing under ~/.signalk is edited by the installer. GET-first, so a
# migrated HaLOS settings.json (same ids) is left alone. Best-effort.
# `== false`, not `// true`: jq's `//` treats false as empty, so a confirmed
# board (candidate:false) would read as true and never pass this gate.
if command -v jq >/dev/null 2>&1 \
    && [[ -s "$UPDATER_DATA/hardware.json" ]] \
    && jq -e '.board.model == "halpi2" and .board.candidate == false' "$UPDATER_DATA/hardware.json" >/dev/null 2>&1; then
    section "HALPI2 Signal K connections"
    if ! "$HOME/.local/bin/signalk-halpi2" connections; then
        warn "HALPI2 connections not created — run 'signalk halpi2 connections' once the server is up"
    fi
fi

# 16. Ensure ~/.local/bin is on PATH for future logins.
#
# Debian-derived /etc/profile.d/ adds ~/.local/bin to PATH only when the
# directory existed at login time. Operators running our installer for
# the first time created it just now, so their current shell AND every
# future shell on a system where the conditional doesn't run will miss
# both `signalk` and `signalk-recovery`. Append a guarded export to:
#
# 1) the user's login-shell rc (~/.bashrc or ~/.zshrc), AND
# 2) ~/.profile.
#
# Both are needed because bash's startup file priority differs by mode:
# an interactive non-login shell sources ~/.bashrc directly; an
# interactive login shell sources ~/.profile (which on Debian sources
# ~/.bashrc as a sub-step). On hosts where ~/.bashrc is in a path
# bash decides not to source (or sources non-interactively and exits
# at the standard `case $- in *i*) ;; *) return;; esac` guard), only
# ~/.profile catches the snippet. Writing both makes the failure mode
# go away. The guarded snippet is idempotent so duplication is fine.
section "PATH activation"

PATH_GUARD='# signalk-universal-installer: ensure ~/.local/bin on PATH'

# write_path_snippet <rc-file>: idempotently append the guarded snippet.
write_path_snippet() {
    local rc=$1
    if [[ -f "$rc" ]] && grep -Fq "$PATH_GUARD" "$rc"; then
        ok "PATH snippet already present in $rc"
        return
    fi
    # shellcheck disable=SC2016
    # $PATH / $HOME are written literally on purpose — the user's shell
    # expands them at login, not us here.
    {
        echo
        echo "$PATH_GUARD"
        echo 'case ":$PATH:" in'
        echo '    *":$HOME/.local/bin:"*) ;;'
        echo '    *) export PATH="$HOME/.local/bin:$PATH" ;;'
        echo 'esac'
    } >>"$rc"
    ok "Added PATH snippet to $rc"
}

SHELL_RC=""
case "$(basename "${SHELL:-bash}")" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
esac

write_path_snippet "$HOME/.profile"
if [[ -n "$SHELL_RC" ]]; then
    write_path_snippet "$SHELL_RC"
fi

# Capture whether the current shell needs a reload. The child install
# scripts both create files under $HOME/.local/bin, so we just check
# whether that directory is on PATH right now.
PATH_NEEDS_RELOAD=0
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH_NEEDS_RELOAD=1 ;;
esac

# 16b. System-wide `signalk` symlink for instant availability.
#
# The PATH snippet above only takes effect in NEW shells — this script
# is a child process (usually `curl … | bash`) and can't modify the
# invoking shell's PATH, so right after the install `signalk` would
# still be "command not found" until the user re-logs. /usr/local/bin
# is on PATH in every default shell already, so a symlink there makes
# the command work immediately. The symlink TARGET stays
# ~/.local/bin/signalk: that's the file the doctor's
# /api/installer/refresh rewrites through its ~/.local/bin bind-mount,
# so refresh keeps working through the link. The readlink guard keeps
# no-op re-runs sudo-free (same principle as the journald drop-in).
section "System-wide signalk command"
SIGNALK_LINK=/usr/local/bin/signalk
SIGNALK_CLI="$HOME/.local/bin/signalk"
if [[ "$(readlink "$SIGNALK_LINK" 2>/dev/null)" == "$SIGNALK_CLI" ]]; then
    ok "$SIGNALK_LINK already links to $SIGNALK_CLI"
elif [[ -e "$SIGNALK_LINK" && ! -L "$SIGNALK_LINK" ]]; then
    warn "$SIGNALK_LINK exists and is not a symlink — leaving it alone."
    warn "'signalk' will resolve via ~/.local/bin in new shells instead."
elif $SUDO ln -sfn "$SIGNALK_CLI" "$SIGNALK_LINK"; then
    ok "linked $SIGNALK_LINK -> $SIGNALK_CLI"
else
    warn "could not create $SIGNALK_LINK; 'signalk' available in new shells via ~/.local/bin"
fi

# 17. Journald: persistent storage + size cap.
section "Journald retention drop-in"
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/signalk.conf
# Storage=persistent (not just the size cap): without it, a Pi whose journald
# defaults to volatile — or `auto` with no /var/log/journal — keeps the journal
# in RAM only, so `systemctl --user` unit logs are never written. That's the
# blind spot behind "No journal files were found" when a container start fails:
# neither `signalk bug-report` nor the operator can see what signalk-server
# actually did. Persistent + capped (the cap MUST stay — an uncapped journal on
# an SD card fills the card) makes those failures diagnosable. journald writes
# to /var/log/journal under persistent storage; create it explicitly so the
# first restart has somewhere to write even before systemd-tmpfiles runs.
JOURNALD_DESIRED='# Installed by signalk-universal-installer
[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=14day'
# Plain `cat` (no $SUDO) so the no-op re-run never prompts for a password.
# This works because we write the drop-in world-readable 0644 below — it's
# plain config with no secrets, matching stock /etc/systemd/journald.conf and
# our own /etc/sysctl.d drop-in. A 0600 file (how `$SUDO tee` left it before)
# would make this read fail for the unprivileged user and re-apply every run.
if [[ "$(cat "$JOURNALD_DROPIN" 2>/dev/null)" == "$JOURNALD_DESIRED" ]]; then
    ok "journald persistent + capped already applied (skipping)"
else
    info "Enabling persistent journal, capped to 500M / 14 days (requires sudo)"
    $SUDO install -d -m 0755 /etc/systemd/journald.conf.d
    # 2755, group systemd-journal — matches what journald/systemd-tmpfiles
    # create for /var/log/journal, so journal-group members can read logs
    # without waiting for journald to fix ownership. Pass -g only when the
    # group exists (it does on any systemd host, but `install -g <missing>`
    # errors and set -e would abort); journald's restart below sets the group
    # regardless. Harmless if the dir already exists.
    if getent group systemd-journal >/dev/null 2>&1; then
        $SUDO install -d -m 2755 -g systemd-journal /var/log/journal
    else
        $SUDO install -d -m 2755 /var/log/journal
    fi
    printf '%s\n' "$JOURNALD_DESIRED" | $SUDO install -m 0644 /dev/stdin "$JOURNALD_DROPIN"
    $SUDO systemctl restart systemd-journald
    ok "journald persistent + capped applied"
fi

# 17b. Host time & timezone sync agent.
#
# Root-side by necessity: CLOCK_REALTIME is not namespaced (a rootless
# container can never hold CAP_SYS_TIME in the initial userns), and
# timedated's set-timezone hits polkit auth_admin for session-less
# users — so the in-container plugins (set-system-time,
# signalk-set-gps-timezone's timedatectl path) are structurally unable
# to do this. A root systemd timer has both powers natively; it reads
# GPS datetime/position from the local SignalK REST API (with the
# doctor's admin token) and only ever steps the clock when the host has
# no NTP sync. Content-compared like the journald drop-in so no-change
# re-runs stay sudo-free.
section "Time & timezone sync (signalk-timesync)"
TIMESYNC_BIN=/usr/local/bin/signalk-timesync
TIMESYNC_DESIRED=$(sed \
    -e "s/__SK_USER__/${USER}/g" \
    -e "s/__SK_HTTP_PORT__/${SK_HTTP_PORT}/g" \
    "$HERE/signalk-timesync.tmpl")
TIMESYNC_SERVICE='# Installed by signalk-universal-installer
[Unit]
Description=SignalK GPS time & timezone sync (one pass)
ConditionPathExists=/usr/local/bin/signalk-timesync

[Service]
Type=oneshot
ExecStart=/usr/local/bin/signalk-timesync run'
TIMESYNC_TIMER='# Installed by signalk-universal-installer
[Unit]
Description=SignalK GPS time & timezone sync

[Timer]
OnBootSec=60
OnUnitActiveSec=300
AccuracySec=30

[Install]
WantedBy=timers.target'
if [[ "$(cat "$TIMESYNC_BIN" 2>/dev/null)" == "$TIMESYNC_DESIRED" ]] \
    && [[ "$(cat /etc/systemd/system/signalk-timesync.service 2>/dev/null)" == "$TIMESYNC_SERVICE" ]] \
    && [[ "$(cat /etc/systemd/system/signalk-timesync.timer 2>/dev/null)" == "$TIMESYNC_TIMER" ]]; then
    ok "signalk-timesync already installed (skipping)"
else
    info "Installing signalk-timesync agent + timer (requires sudo)"
    if printf '%s\n' "$TIMESYNC_DESIRED" | $SUDO install -m 0755 -o root -g root /dev/stdin "$TIMESYNC_BIN" \
        && printf '%s\n' "$TIMESYNC_SERVICE" | $SUDO install -m 0644 /dev/stdin /etc/systemd/system/signalk-timesync.service \
        && printf '%s\n' "$TIMESYNC_TIMER" | $SUDO install -m 0644 /dev/stdin /etc/systemd/system/signalk-timesync.timer \
        && $SUDO systemctl daemon-reload \
        && $SUDO systemctl enable --now signalk-timesync.timer; then
        ok "signalk-timesync timer enabled (clock: GPS when no NTP; timezone: GPS position)"
    else
        warn "could not install signalk-timesync; host clock/timezone won't follow GPS."
        warn "Re-run the installer with sudo available to add it."
    fi
fi

# 18. Mark bootstrap-complete
section "Recording bootstrap state"
LAST_GOOD="$DOCTOR_DATA/last-good.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP_LG=$(mktemp)
# Read existing file if it's valid JSON; otherwise start from the
# documented empty shape. Then set updatedAt + bootstrappedAt and
# ensure `quadlets` exists. Atomic write via mv so a torn write can't
# leave a half-written file.
#
# jq is preferred (it preserves any existing fields on a re-run). Without jq
# (e.g. the podman-machine Fedora VM where jq isn't pre-baked) we write the
# minimal documented shape with printf; this only loses a prior `quadlets`
# map, which the doctor reconstructs from the live /quadlets mount anyway.
if command -v jq >/dev/null 2>&1; then
    if [[ -s "$LAST_GOOD" ]] && jq -e . "$LAST_GOOD" >/dev/null 2>&1; then
        jq --arg now "$NOW" \
           '. + {updatedAt: $now, bootstrappedAt: $now} | .quadlets = (.quadlets // {})' \
           "$LAST_GOOD" >"$TMP_LG"
    else
        jq -n --arg now "$NOW" \
           '{updatedAt: $now, bootstrappedAt: $now, quadlets: {}}' >"$TMP_LG"
    fi
else
    printf '{"updatedAt":"%s","bootstrappedAt":"%s","quadlets":{}}\n' "$NOW" "$NOW" >"$TMP_LG"
fi
mv -f "$TMP_LG" "$LAST_GOOD"

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

    # Three services active (+ the dbus proxy where installed)
    verify_units=(signalk-server signalk-updater-server signalk-doctor-server)
    [[ -f "$QUADLET_DIR/signalk-dbus-proxy.container" ]] \
        && verify_units+=(signalk-dbus-proxy)
    for u in "${verify_units[@]}"; do
        active=$(systemctl --user is-active "${u}.service" 2>/dev/null || true)
        if [[ "$active" = "active" ]]; then
            verify_check "${u}.service" "ok"
        else
            verify_check "${u}.service" "state=${active:-unknown}; check 'podman logs ${u}'"
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

    # Three URLs answering. Retry briefly (20s) rather than a single 5s
    # one-shot: on a busy first boot (cold plugin install, image pulls,
    # questdb/grafana starting) the engine containers — the doctor especially,
    # on a low-end Pi/SD-card host — can take a few seconds to answer their own
    # /api/health, enough to trip a bare 5s curl even though the service is
    # fine. The step-13 gate already waits 180s; this shorter post-settle
    # budget keeps a genuinely-down service reporting unreachable promptly.
    if wait_for_http "$UPDATER_URL/api/health" 20; then
        verify_check "updater health (:3003)" "ok"
    else
        verify_check "updater health (:3003)" "unreachable"
    fi
    if wait_for_http "$DOCTOR_URL/api/health" 20; then
        verify_check "doctor health (:3004)" "ok"
    else
        verify_check "doctor health (:3004)" "unreachable"
    fi
    if curl -fsS -o /dev/null -m 5 "$SIGNALK_URL" 2>/dev/null; then
        verify_check "signalk-server (:${SK_HTTP_PORT})" "ok"
    else
        # Probe failed — surface the most actionable hint we can derive.
        # The bare "unreachable" line on its own sends operators to the
        # doctor when in practice the failure is almost always Quadlet
        # drift that the 11b restart should have applied (and either
        # didn't, or the operator is on an older installer).
        verify_actual_port=$(ss -ltn 2>/dev/null \
            | awk -v p=":${SK_HTTP_PORT}" '$4 ~ /:(80|3000|443|3443)$/ && $4 !~ p {sub(/.*:/,"",$4); print $4}' \
            | sort -u | paste -sd, -)
        verify_drift=$(signalk_server_drift_reason)
        if [[ -n "$verify_actual_port" ]]; then
            verify_check "signalk-server (:${SK_HTTP_PORT})" \
                "container listening on :${verify_actual_port} instead — run 'systemctl --user restart signalk-server.service'"
        elif [[ -n "$verify_drift" ]]; then
            verify_check "signalk-server (:${SK_HTTP_PORT})" \
                "unreachable; ${verify_drift} — run 'systemctl --user restart signalk-server.service'"
        else
            verify_check "signalk-server (:${SK_HTTP_PORT})" \
                "unreachable; check 'podman logs signalk-server'"
        fi
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
#
# Print URLs the operator can paste into their browser. Most boats are
# headless and the operator is on a laptop/tablet on the same LAN, so
# when bound to 0.0.0.0 we resolve the primary outbound IP via
# `ip route get` (no packet actually sent — the kernel just reports
# which source it would use). Falls back to `hostname -I` and finally
# to "localhost" so the message always prints something usable.
LAN_HOST=""
if [[ "$PUBLISH_HOST" = "0.0.0.0" ]]; then
    LAN_HOST=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    if [[ -z "$LAN_HOST" ]]; then
        LAN_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
fi
DISPLAY_HOST="${LAN_HOST:-localhost}"

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
    SUMMARY_HEADLINE="${C_GREEN}${C_BOLD}OK — SignalK is up. Open it in your browser:${C_RESET}"
fi

VESSEL_SUMMARY=""
if [[ "$VESSEL_SEED" = "1" && -n "$VESSEL_NAME" ]]; then
    VESSEL_SUMMARY="
  Vessel           : ${VESSEL_NAME} (edit under Server → Settings)"
fi

LOGIN_SUMMARY=""
if [[ "$ADMIN_SEED" = "1" && "$ADMIN_UNSECURED" != "1" ]]; then
    LOGIN_SUMMARY="
  Admin login      : ${sk_admin_user} (the password you set; recover with 'signalk resetadmin')"
elif [[ "$ADMIN_UNSECURED" = "1" ]]; then
    LOGIN_SUMMARY="
  Admin login      : NONE — server is UNSECURED; create an admin in the UI now"
fi

cat <<EOF

${SUMMARY_HEADLINE}

  SignalK admin UI : http://${DISPLAY_HOST}:${SK_HTTP_PORT}${VESSEL_SUMMARY}${LOGIN_SUMMARY}
  Updater Console  : http://${DISPLAY_HOST}:3003
  Doctor Console   : http://${DISPLAY_HOST}:3004

${LAN_NOTE}

Auth tokens are at:
  Updater : ${UPDATER_DATA}/token  (mode 0600)
  Doctor  : ${DOCTOR_DATA}/token   (mode 0600)

The 'signalk' command:
  signalk health         show stack health
  signalk recover        delegate to the SSH-only recovery script
  signalk socketcan      Pi CAN-HAT detection + setup recipe
  signalk update         refresh installer scripts + Quadlet templates via doctor
  signalk resetadmin     reset (or create) the Admin UI login password
  signalk bug-report     bundle logs + state for an issue report
  signalk uninstall      stop services + remove Quadlets (preserves data)
  signalk help           full usage
EOF

# The /usr/local/bin symlink (step 16b) normally makes `signalk` work
# in the CURRENT shell already — `command -v` re-checks it here rather
# than trusting the symlink branch outcome, so the hint also stays
# suppressed when an operator's exotic PATH happens to cover
# ~/.local/bin some other way. The reload hint survives only for the
# fallback case (symlink skipped/failed AND ~/.local/bin not on PATH).
if (( PATH_NEEDS_RELOAD )) && ! command -v signalk >/dev/null 2>&1; then
    SHELL_NAME=$(basename "${SHELL:-bash}")
    # -l forces a login shell which is what an SSH session would
    # already be. The PATH snippet was written to ~/.profile too so
    # the login-shell flow definitely picks it up. Without -l on a
    # login shell, bash may not re-source ~/.bashrc and the snippet
    # never runs.
    cat <<EOF

To use 'signalk' in this shell right now, run:  exec "${SHELL_NAME}" -l
(New logins pick it up automatically — the snippet was added to ~/.profile.)
EOF
fi

if (( USER_SERVICE_RELOGIN_HINT )); then
    cat <<EOF

The following systemd user@.service overrides were installed:
${USER_SERVICE_OVERRIDES}These take effect on NEW user-bus sessions — log out and back in (or reboot)
so a fresh user@.service starts and rootless containers pick up the changes.
EOF
fi
