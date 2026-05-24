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

check_ports() {
    local p
    local conflicts=()
    for p in "${PORTS_TO_CHECK[@]}"; do
        if ss -ltn "( sport = :$p )" 2>/dev/null | tail -n +2 | grep -q .; then
            conflicts+=("$p")
        fi
    done
    if (( ${#conflicts[@]} > 0 )); then
        fail "Port(s) already in use: ${conflicts[*]} — stop the conflicting service or set a different port"
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
        fail "cgroups v2 missing controller(s):$missing"
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
        elif is_pi; then
            warn "On Raspberry Pi, enable the memory controller (one-time, requires sudo + reboot):"
            warn "  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak.\$(date +%Y%m%d)"
            warn "  sudo sed -i 's/\$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt"
            warn "  # /boot/firmware/cmdline.txt must remain a single line — verify: wc -l /boot/firmware/cmdline.txt"
            warn "  sudo reboot"
        fi
    else
        ok "cgroups v2 with memory + pids"
    fi
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

main() {
    section "Pre-flight on ${DISTRO_PRETTY} (${ARCH_NORM})"
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
