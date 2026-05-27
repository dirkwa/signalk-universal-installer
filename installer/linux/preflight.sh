#!/usr/bin/env bash
# Pre-install checks: RAM, disk, ports, cgroups, podman, subuid/subgid,
# linger, rootless-storage backing filesystem, legacy units.
# Exits non-zero on the first hard failure unless FORCE=1 is set.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"
# shellcheck disable=SC1091
. "$HERE/lib/distro.sh"

detect_os

REQUIRED_RAM_MB=${REQUIRED_RAM_MB:-2048}
REQUIRED_DISK_GB=${REQUIRED_DISK_GB:-5}
PORTS_TO_CHECK=(3000 3003 3004 3010)
PODMAN_MIN_VERSION="4.4"

fail() {
    err "$@"
    if [[ "${FORCE:-0}" != "1" ]]; then
        die "Aborting. Set FORCE=1 to override (not recommended)."
    fi
    warn "FORCE=1, continuing despite failure"
}

check_ram() {
    local mb
    mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    if (( mb < REQUIRED_RAM_MB )); then
        fail "RAM ${mb}MB < required ${REQUIRED_RAM_MB}MB"
    else
        ok "RAM ${mb}MB"
    fi
}

check_disk() {
    local target="${HOME}"
    local gb
    gb=$(df -BG --output=avail "$target" | tail -1 | tr -dc 0-9)
    if (( gb < REQUIRED_DISK_GB )); then
        fail "Free disk on ${target}: ${gb}GB < required ${REQUIRED_DISK_GB}GB"
    else
        ok "Free disk ${gb}GB on ${target}"
    fi
}

# `bootstrappedAt` in ~/.signalk-doctor/last-good.json is written by
# install.sh's last step on every successful pass. Its presence means
# this isn't a fresh install — ports being held by signalk-* services
# is the expected state, not a collision.
is_verify_mode() {
    local marker="${HOME}/.signalk-doctor/last-good.json"
    [[ -f "$marker" ]] && grep -q '"bootstrappedAt"' "$marker" 2>/dev/null
}

check_ports() {
    local p
    local conflicts=()
    for p in "${PORTS_TO_CHECK[@]}"; do
        if ss -ltn "( sport = :$p )" 2>/dev/null | tail -n +2 | grep -q .; then
            conflicts+=("$p")
        fi
    done
    if (( ${#conflicts[@]} > 0 )); then
        if is_verify_mode; then
            ok "Ports ${conflicts[*]} bound (expected — existing install)"
        else
            fail "Port(s) already in use: ${conflicts[*]} — stop the conflicting service or set a different port"
        fi
    else
        ok "Ports ${PORTS_TO_CHECK[*]} are free"
    fi
}

check_cgroups_v2() {
    if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        fail "cgroups v2 not detected (no /sys/fs/cgroup/cgroup.controllers)"
        return
    fi
    local ctl
    ctl=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo "")
    local missing=""
    grep -qw memory <<<"$ctl" || missing+=" memory"
    grep -qw pids <<<"$ctl" || missing+=" pids"
    if [[ -n "$missing" ]]; then
        # On a Pi, surface the recipe and the interactive autofix BEFORE
        # calling fail() — fail() exits, so anything after it is dead code
        # on a default-config run. If offer_pi_cmdline_fix returns 0, the
        # patch was applied and the operator just needs to reboot; exit
        # cleanly so they don't see the FORCE=1 advisory. Print the error
        # header now so the warn block below is contextually anchored.
        err "cgroups v2 missing controller(s):$missing"
        if is_pi && [[ -r /proc/cmdline ]] && grep -qw 'cgroup_disable=memory' /proc/cmdline; then
            # Pi OS Trixie ships with cgroup_disable=memory injected by
            # the GPU firmware. Until the memory controller is enabled
            # at the kernel level, systemd's Delegate=memory has nothing
            # to delegate, and consumer-plugin memory limits are silently
            # dropped (signalk-container doctor remediation, verbatim).
            warn "Detected cgroup_disable=memory in /proc/cmdline."
            warn "Enable the memory controller (one-time, requires sudo + reboot):"
            warn "  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak.\$(date +%Y%m%d)"
            warn "  sudo sed -i 's/\\bcgroup_disable=memory\\b//; s/\$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt"
            warn "  # /boot/firmware/cmdline.txt must remain a single line — verify: wc -l /boot/firmware/cmdline.txt"
            warn "  sudo reboot"
            if offer_pi_cmdline_fix strip-disable; then
                exit 0
            fi
        elif is_pi; then
            warn "On Raspberry Pi, enable the memory controller (one-time, requires sudo + reboot):"
            warn "  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak.\$(date +%Y%m%d)"
            warn "  sudo sed -i 's/\$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt"
            warn "  # /boot/firmware/cmdline.txt must remain a single line — verify: wc -l /boot/firmware/cmdline.txt"
            warn "  sudo reboot"
            if offer_pi_cmdline_fix enable-only; then
                exit 0
            fi
        fi
        # Already printed via err above; honor FORCE=1 the same way fail() would.
        if [[ "${FORCE:-0}" != "1" ]]; then
            die "Aborting. Set FORCE=1 to override (not recommended)."
        fi
        warn "FORCE=1, continuing despite failure"
    else
        ok "cgroups v2 with memory + pids"
    fi
}

# Offer to apply the cmdline.txt patch interactively. Mode is either
# "strip-disable" (also removes cgroup_disable=memory) or "enable-only"
# (just appends the enable flags). Skips silently when there's no TTY
# (curl|bash from cron, CI), when cmdline.txt isn't where we expect, or
# when the user declines. Never auto-reboots.
#
# Returns 0 only when the patch was applied successfully (caller should
# then exit cleanly so the operator sees "reboot, then re-run" instead
# of the generic preflight-fail message). Returns 1 in every other case
# so the caller falls through to the normal fail() path.
offer_pi_cmdline_fix() {
    local mode=$1
    local cmdline=/boot/firmware/cmdline.txt
    if [[ ! -f "$cmdline" ]]; then
        return 1
    fi
    if [[ ! -r /dev/tty ]] || [[ ! -w /dev/tty ]]; then
        # No controlling terminal — curl|bash from a non-interactive
        # context. Leave the printed instructions as the only path.
        return 1
    fi
    local current proposed
    current=$(cat "$cmdline")
    case "$mode" in
        strip-disable)
            # \b is GNU-sed only; bash regex below is portable and matches
            # cgroup_disable=memory only as a whole token.
            proposed=$(sed -E 's/(^|[[:space:]])cgroup_disable=memory($|[[:space:]])/\1\2/g' <<<"$current")
            proposed="${proposed%$'\n'} cgroup_enable=memory cgroup_memory=1"
            ;;
        enable-only)
            proposed="${current%$'\n'} cgroup_enable=memory cgroup_memory=1"
            ;;
        *)
            return 1
            ;;
    esac
    # Collapse any double spaces produced by the strip, then trim
    # leading/trailing whitespace (strip can leave a leading space when
    # cgroup_disable=memory was the first token).
    proposed=$(tr -s ' ' <<<"$proposed")
    proposed="${proposed#"${proposed%%[![:space:]]*}"}"
    proposed="${proposed%"${proposed##*[![:space:]]}"}"
    # Refuse the patch if it ended up empty or multi-line.
    if [[ -z "$proposed" ]] || [[ $(wc -l <<<"$proposed") -ne 1 ]]; then
        warn "Refusing to offer auto-patch: proposed cmdline is not a single line."
        return 1
    fi
    printf '\n%sProposed change to %s:%s\n' "$C_BOLD" "$cmdline" "$C_RESET" >/dev/tty
    diff -u --label "current" --label "proposed" \
        <(printf '%s\n' "$current") <(printf '%s\n' "$proposed") >/dev/tty || true
    printf '\nApply this patch now (sudo, no reboot)? [y/N] ' >/dev/tty
    local reply=""
    read -r reply </dev/tty || return 1
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            info "Skipped cmdline.txt patch. Apply manually with the commands above when ready."
            return 1
            ;;
    esac
    local backup ts
    ts=$(date +%Y%m%d-%H%M%S)
    backup="${cmdline}.bak.${ts}"
    local sudo_cmd=""
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd="sudo"
        else
            err "sudo not available — cannot edit $cmdline as $USER."
            return 1
        fi
    fi
    # Intentional word-splitting on $sudo_cmd below: empty disappears, non-empty prefixes the command.
    info "Backing up $cmdline → $backup"
    if ! $sudo_cmd cp -p "$cmdline" "$backup"; then
        err "Backup failed; not editing $cmdline."
        return 1
    fi
    if ! printf '%s\n' "$proposed" | $sudo_cmd tee "$cmdline" >/dev/null; then
        err "Write to $cmdline failed; restoring backup."
        $sudo_cmd cp -p "$backup" "$cmdline" || err "Restore from $backup also failed — fix manually before rebooting."
        return 1
    fi
    # Final safety check: cmdline.txt MUST be a single line; some bootloaders
    # silently refuse to apply settings past the first newline. An empty
    # file is also a failure mode — restore on any non-1 line count.
    local lines
    lines=$(wc -l <"$cmdline")
    if [[ "$lines" -ne 1 ]]; then
        err "$cmdline ended up with $lines lines; restoring backup."
        $sudo_cmd cp -p "$backup" "$cmdline" || err "Restore from $backup also failed — fix manually before rebooting."
        return 1
    fi
    ok "Patched $cmdline (backup at $backup)."
    warn "Reboot required for the kernel to expose the memory controller:"
    warn "  sudo reboot"
    warn "Re-run the installer after the reboot."
    return 0
}

# Verify the user slice actually sees memory + pids. The kernel may
# have them at the root, but systemd's default user@.service Delegate=
# value varies by distro/version and on some systems memory + pids
# don't propagate to user-<uid>.slice. When that happens, container
# resource limits silently no-op (signalk-container's doctor
# remediationCgroupControllers documents the fix).
#
# Informational warning only — install.sh autofixes via the
# user@.service delegate override (needs sudo).
check_user_slice_delegation() {
    local uid slice ctl missing
    uid=$(id -u)
    slice="/sys/fs/cgroup/user.slice/user-${uid}.slice"
    if [[ ! -f "$slice/cgroup.controllers" ]]; then
        # User slice not yet created (linger off + user not logged in
        # via systemd-logind). install.sh's linger step + a subsequent
        # bus startup will materialise it; can't probe further here.
        warn "user-${uid}.slice not present yet — install.sh will create it via linger"
        return
    fi
    ctl=$(cat "$slice/cgroup.controllers" 2>/dev/null || echo "")
    missing=""
    grep -qw memory <<<"$ctl" || missing+=" memory"
    grep -qw pids <<<"$ctl" || missing+=" pids"
    if [[ -n "$missing" ]]; then
        warn "user-${uid}.slice missing delegated controller(s):${missing} — installer will autofix (requires sudo, takes effect on next login)"
    else
        ok "user-${uid}.slice has memory + pids delegated"
    fi
}

check_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        warn "Podman not installed — installer will install it"
        return
    fi
    local v
    v=$(podman --version 2>/dev/null | awk '{print $3}')
    # Compare major.minor only
    local req_major=${PODMAN_MIN_VERSION%%.*}
    local req_minor=${PODMAN_MIN_VERSION#*.}
    local cur_major cur_minor
    cur_major=$(cut -d. -f1 <<<"$v")
    cur_minor=$(cut -d. -f2 <<<"$v")
    if (( cur_major < req_major )) || { (( cur_major == req_major )) && (( cur_minor < req_minor )); }; then
        fail "Podman $v < required $PODMAN_MIN_VERSION (Quadlet support)"
    else
        ok "Podman $v"
    fi
}

check_subid() {
    if [[ ! -f /etc/subuid ]] || ! grep -q "^${USER}:" /etc/subuid; then
        warn "User $USER lacks subuid mapping — installer will run: sudo usermod --add-subuids 100000-165535"
    fi
    if [[ ! -f /etc/subgid ]] || ! grep -q "^${USER}:" /etc/subgid; then
        warn "User $USER lacks subgid mapping — installer will run: sudo usermod --add-subgids 100000-165535"
    fi
    ok "subuid/subgid will be ensured by installer"
}

check_linger() {
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        ok "linger enabled for $USER"
    else
        warn "linger not yet enabled — installer will run: loginctl enable-linger $USER"
    fi
}

# Path rootless Podman uses for its image+container storage (graphroot).
# Matches Podman's own default: $XDG_DATA_HOME/containers/storage,
# falling back to ~/.local/share/containers/storage. The actual path
# may not exist yet on a fresh host; we walk up to the nearest existing
# parent so `stat -f` always has something to work with.
podman_storage_root() {
    local root="${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
    local probe="$root"
    while [[ -n "$probe" && ! -e "$probe" ]]; do
        probe="${probe%/*}"
    done
    printf '%s\n' "${probe:-/}"
}

# Reports the backing filesystem type for podman's rootless storage.
# Echoes the fstype (e.g. ext4, btrfs, zfs, overlay) or empty on error.
podman_storage_fstype() {
    stat -f -c '%T' "$(podman_storage_root)" 2>/dev/null || true
}

check_storage_fs() {
    local fs
    fs=$(podman_storage_fstype)
    case "$fs" in
        zfs)
            # Doctor probe IDMAP_HAZARD_FSTYPES in signalk-container
            # classifies ZFS as catastrophic for the default overlay
            # driver + --userns=keep-id (Podman's storage-chown-by-maps
            # sweep crawls on CoW metadata; some kernels fail outright
            # writing /proc/<pid>/gid_map). install.sh autofixes this
            # by installing fuse-overlayfs and writing a storage.conf
            # before the first image pull.
            warn "Rootless storage is on ZFS — installer will switch to fuse-overlayfs"
            ;;
        "")
            warn "Could not determine rootless storage filesystem (probed $(podman_storage_root))"
            ;;
        *)
            ok "Rootless storage on $fs (no special handling needed)"
            ;;
    esac
}

check_legacy_install() {
    local legacy_units=(signalk-keeper signalk-caddy signalk-kopia)
    local found=()
    for u in "${legacy_units[@]}"; do
        if systemctl --user list-unit-files "${u}*.service" 2>/dev/null | grep -q "${u}"; then
            found+=("$u")
        fi
    done
    if (( ${#found[@]} > 0 )); then
        fail "Detected legacy v1 systemd units: ${found[*]}. Run scripts/uninstall.sh from the v1 repo first, or run installer/linux/legacy-cleanup.sh."
    else
        ok "No legacy v1 units detected"
    fi
}

check_distro_blocked() {
    # Debian 12 (bookworm) ships podman 4.3.1; Quadlet support arrived
    # in 4.4. We previously enabled bookworm-backports to upgrade, but
    # Debian removed podman from bookworm-backports — so there is no
    # in-Debian-repo path to a usable version. Bail with a clear
    # upgrade-to-trixie message rather than failing later, mid-apt,
    # with a confusing dependency error.
    if [[ "$DISTRO_ID" = "debian" && "$DISTRO_CODENAME" = "bookworm" ]]; then
        err "Debian 12 (bookworm) is no longer supported by this installer."
        echo >&2
        err "Bookworm ships Podman 4.3.1 which lacks Quadlet (added in 4.4),"
        err "and bookworm-backports does not carry a newer version."
        echo >&2
        err "Upgrade to Debian 13 (trixie):"
        err "  1. As root, edit /etc/apt/sources.list and replace 'bookworm'"
        err "     with 'trixie' on every active line (also under"
        err "     /etc/apt/sources.list.d/ if you have files there)."
        err "  2. apt-get update"
        err "  3. apt-get full-upgrade"
        err "  4. reboot"
        err "  5. Re-run this installer."
        exit 1
    fi
}

main() {
    section "Pre-flight on ${DISTRO_PRETTY} (${ARCH_NORM})"
    check_distro_blocked
    if ! is_supported_distro; then
        warn "Untested on ${DISTRO_PRETTY}; continuing"
    fi
    check_ram
    check_disk
    check_ports
    check_cgroups_v2
    check_user_slice_delegation
    check_podman
    check_subid
    check_linger
    check_storage_fs
    check_legacy_install
}

main "$@"
