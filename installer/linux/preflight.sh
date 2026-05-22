#!/usr/bin/env bash
# Pre-install checks: RAM, disk, ports, cgroups, podman, subuid/subgid, linger.
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
        if is_pi; then
            warn "On Raspberry Pi, edit /boot/firmware/cmdline.txt and add: cgroup_enable=memory cgroup_memory=1 systemd.unified_cgroup_hierarchy=1"
        fi
    else
        ok "cgroups v2 with memory + pids"
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
    check_podman
    check_subid
    check_linger
    check_legacy_install
}

main "$@"
