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

# Login shells set USER, but `podman exec`, cron, and some systemd contexts
# don't — with `set -u` the first ${USER} dereference then kills the whole
# preflight ("USER: unbound variable"). id -un answers from the kernel.
USER="${USER:-$(id -un)}"

detect_os

REQUIRED_RAM_MB=${REQUIRED_RAM_MB:-2048}
REQUIRED_DISK_GB=${REQUIRED_DISK_GB:-5}
# Above this much RAM, a tmpfs /tmp isn't worth mentioning — there's
# headroom for both the RAM-backed /tmp and the container stack. At or
# below it (the 4 GB / 8 GB Pi4/Pi5 fleet) check_tmp_on_tmpfs prints a
# purely informational heads-up (no problem has been reported; it's a
# "you might want to know" note, not a warning). Overridable.
TMPFS_WARN_MAX_RAM_MB=${TMPFS_WARN_MAX_RAM_MB:-8192}
# Percentage of RAM the heads-up suggests capping a tmpfs /tmp at (the OS
# default is 50%). Shrinking the cap keeps /tmp in RAM — no SSD/SD-card
# write wear, unlike moving it to disk — while bounding how much RAM a
# runaway /tmp can ever consume. 20% of 8 GB is ~1.6 GB, ample for the
# installer's tempfiles while leaving the rest for the containers.
TMPFS_RECOMMEND_PCT=${TMPFS_RECOMMEND_PCT:-20}
# signalk-server's HTTP port (and HTTPS, once TLS is enabled) is chosen
# by install.sh and exported as SK_HTTP_PORT / SK_HTTPS_PORT. Default to
# the standard web ports when run standalone. The HTTPS port is only
# bound once the user enables TLS, but checking it on a fresh box is
# harmless (it'll be free) and catches a collision early. 3003/3004 are
# the fixed updater + doctor engine ports. 3000 is signalk-server's
# default fallback port: when its chosen port (80) is already taken,
# signalk-server falls back to 3000 — so a stray server squatting 3000
# is exactly how a duplicate instance hides. Checking it catches that.
#
# 3010 (signalk-backup) is deliberately NOT checked: this installer
# doesn't install or bind it (no quadlet uses it), so a fresh install's
# only occupant is the user's own leftover backup container from a prior
# run — a false conflict that aborts preflight for no reason. The
# signalk-backup plugin manages that port on its own when enabled.
SK_HTTP_PORT=${SK_HTTP_PORT:-80}
SK_HTTPS_PORT=${SK_HTTPS_PORT:-443}
PORTS_TO_CHECK=("$SK_HTTP_PORT" "$SK_HTTPS_PORT" 3000 3003 3004)
# 5.3: Quadlet gained Type=notify network handling for user units AND the
# `[Quadlet] DefaultDependencies=false` key we rely on to suppress the
# user-session network-wait shim (both landed in podman 5.3.0). On older
# podman the shim blocks unit start for ~90s on fresh boots with no way to
# disable it. Trixie ships 5.4.x, so this excludes no supported host;
# bookworm (4.3.1, no Quadlet) is already blocked in check_distro_blocked.
PODMAN_MIN_VERSION="5.3"

# Which managed container is expected to hold each port. On a re-run a bound
# port is only "expected" if its owning managed container is actually
# running — otherwise something else (a stray container, an unrelated
# service) holds it and that's a real conflict, even in verify mode.
port_owner() {
    case "$1" in
        "$SK_HTTP_PORT" | "$SK_HTTPS_PORT" | 3000) echo "signalk-server" ;;
        3003) echo "signalk-updater-server" ;;
        3004) echo "signalk-doctor-server" ;;
        *) echo "" ;;
    esac
}

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

# Filesystem type backing /tmp ("tmpfs", "ext4", …), or empty if it can't
# be determined. Split out as its own helper so check_tmp_on_tmpfs's
# branching logic can be unit-tested by stubbing this and _total_ram_mb
# (see scripts/test/check-tmpfs-warn.sh).
_tmp_fstype() {
    if command -v findmnt >/dev/null 2>&1; then
        # -T resolves to whatever mount /tmp actually falls under (the
        # /tmp mount itself, or its parent when /tmp isn't a separate
        # mount). Empty/error => caller treats as not-tmpfs and stays quiet.
        findmnt -nro FSTYPE -T /tmp 2>/dev/null || true
    else
        # Fallback for the (rare) host without util-linux findmnt: an
        # exact-path match in /proc/mounts only catches /tmp when it IS a
        # separate mount, which is exactly the tmpfs case we care about.
        awk '$2 == "/tmp" {print $3; exit}' /proc/mounts 2>/dev/null || true
    fi
}

# Total RAM in MB. Own helper for the same testability reason as _tmp_fstype.
_total_ram_mb() {
    awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo
}

# Debian 13 / trixie (and Raspberry Pi OS trixie+) mount /tmp on tmpfs by
# default — earlier releases kept it on disk. tmpfs is RAM-backed, so on a
# small-RAM Pi a process that fills /tmp (a big build, a runaway log, a
# large download) could use memory the container stack wants. No user has
# actually hit this, so this is an informational heads-up (info, not warn,
# non-blocking) — not a problem the installer found. Shown only on machines
# small enough for it to matter (RAM <= TMPFS_WARN_MAX_RAM_MB).
#
# The suggested tweak SHRINKS the tmpfs cap (size=20%) rather than moving
# /tmp back to disk: keeping it in RAM avoids the SSD/SD-card write wear that
# disk-backed /tmp churn would add, while still bounding the RAM a runaway
# /tmp can consume. A systemd drop-in overrides just the mount Options,
# leaving the vendor unit untouched and surviving OS updates.
check_tmp_on_tmpfs() {
    local fstype
    fstype=$(_tmp_fstype)

    if [[ "$fstype" != "tmpfs" ]]; then
        ok "/tmp is on disk (${fstype:-unknown} fs)"
        return 0
    fi

    local ram_mb cap_mb
    ram_mb=$(_total_ram_mb)
    # tmpfs /tmp size cap in MB (the OS default is 50% of RAM). Best-effort;
    # used only to make the warning concrete, never to gate it.
    cap_mb=$(df -BM --output=size /tmp 2>/dev/null | tail -1 | tr -dc 0-9)

    if (( ram_mb > TMPFS_WARN_MAX_RAM_MB )); then
        ok "/tmp is on tmpfs (cap ${cap_mb:-?}MB; ${ram_mb}MB RAM — headroom OK)"
        return 0
    fi

    # Mirror trixie's vendor tmp.mount Options, swapping only the size= so
    # the drop-in changes the cap and nothing else.
    local opts="mode=1777,strictatime,nosuid,nodev,size=${TMPFS_RECOMMEND_PCT}%,nr_inodes=1m"
    info "/tmp is on tmpfs (RAM-backed): cap ${cap_mb:-?}MB on ${ram_mb}MB RAM."
    info "  This is the Debian 13 / trixie default, not set by this installer,"
    info "  and is fine as-is — just a heads-up: if something fills /tmp it"
    info "  uses RAM the containers could otherwise have. If you'd rather cap"
    info "  that, shrink the tmpfs to ${TMPFS_RECOMMEND_PCT}% of RAM (stays in RAM, no SSD wear):"
    info "    sudo mkdir -p /etc/systemd/system/tmp.mount.d"
    info "    printf '[Mount]\\nOptions=${opts}\\n' \\"
    info "      | sudo tee /etc/systemd/system/tmp.mount.d/size.conf"
    info "    sudo systemctl daemon-reload && sudo reboot"
}

# `bootstrappedAt` in ~/.signalk-doctor/last-good.json is written by
# install.sh's last step on every successful pass. Its presence means
# this isn't a fresh install — ports held by the managed signalk-*
# containers are the expected state, not a collision.
is_verify_mode() {
    local marker="${HOME}/.signalk-doctor/last-good.json"
    [[ -f "$marker" ]] && grep -q '"bootstrappedAt"' "$marker" 2>/dev/null
}

# True if a named container is currently running. Used to decide whether a
# bound port is held by the managed container that should own it.
managed_container_running() {
    local name=$1
    command -v podman >/dev/null 2>&1 || return 1
    podman ps --filter "name=^${name}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "$name"
}

check_ports() {
    local p owner
    # A real conflict: a bound port whose owning managed container is NOT running
    # (so something else holds it — e.g. a stray duplicate server on 3000).
    local conflicts=()
    # Expected: bound, and the managed container that should own it IS up.
    local expected=()
    # `managed_container_running` is the authoritative signal that a bound port
    # belongs to OUR stack - so it decides per-port, NOT the is_verify_mode
    # marker. The marker (bootstrappedAt in last-good.json) is written only at the
    # very last install step, so an install that finished bringing the stack up
    # but died in a later optional step would leave it unset; gating on it broke
    # re-runs (the running signalk-* containers looked like a port conflict).
    # We still compute verify only to word the failure hint.
    local verify=0
    is_verify_mode && verify=1
    for p in "${PORTS_TO_CHECK[@]}"; do
        ss -ltn "( sport = :$p )" 2>/dev/null | tail -n +2 | grep -q . || continue
        owner=$(port_owner "$p")
        if [[ -n "$owner" ]] && managed_container_running "$owner"; then
            expected+=("$p")
        else
            conflicts+=("$p")
        fi
    done
    if (( ${#conflicts[@]} > 0 )); then
        if (( verify )); then
            fail "Port(s) in use but not by the expected managed container: ${conflicts[*]} — a stray/duplicate process is holding them. Check 'podman ps' for unmanaged containers, or stop the conflicting service."
        else
            fail "Port(s) already in use: ${conflicts[*]} — stop the conflicting service or set a different port"
        fi
    elif (( ${#expected[@]} > 0 )); then
        ok "Ports ${expected[*]} held by the managed signalk containers (expected — existing install)"
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
                # Patch landed but the running kernel still lacks the
                # controller. Exit non-zero so the parent install.sh
                # (which calls `bash preflight.sh` and runs under set -e)
                # halts instead of marching on to podman/linger steps
                # that would silently no-op without memory cgroups.
                exit 2
            fi
        elif is_pi; then
            warn "On Raspberry Pi, enable the memory controller (one-time, requires sudo + reboot):"
            warn "  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak.\$(date +%Y%m%d)"
            warn "  sudo sed -i 's/\$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt"
            warn "  # /boot/firmware/cmdline.txt must remain a single line — verify: wc -l /boot/firmware/cmdline.txt"
            warn "  sudo reboot"
            if offer_pi_cmdline_fix enable-only; then
                exit 2
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
    if [[ ! -f "$cmdline" ]] || [[ ! -r "$cmdline" ]]; then
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
    local sudo_cmd=()
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd=(sudo)
        else
            err "sudo not available — cannot edit $cmdline as $USER."
            return 1
        fi
    fi
    info "Backing up $cmdline → $backup"
    if ! "${sudo_cmd[@]}" cp -p "$cmdline" "$backup"; then
        err "Backup failed; not editing $cmdline."
        return 1
    fi
    if ! printf '%s\n' "$proposed" | "${sudo_cmd[@]}" tee "$cmdline" >/dev/null; then
        err "Write to $cmdline failed; restoring backup."
        "${sudo_cmd[@]}" cp -p "$backup" "$cmdline" || err "Restore from $backup also failed — fix manually before rebooting."
        return 1
    fi
    # Final safety check: cmdline.txt MUST be a single line; some bootloaders
    # silently refuse to apply settings past the first newline. An empty
    # file is also a failure mode — restore on any non-1 line count.
    local lines
    lines=$(wc -l <"$cmdline")
    if [[ "$lines" -ne 1 ]]; then
        err "$cmdline ended up with $lines lines; restoring backup."
        "${sudo_cmd[@]}" cp -p "$backup" "$cmdline" || err "Restore from $backup also failed — fix manually before rebooting."
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
        fail "Podman $v < required $PODMAN_MIN_VERSION (Quadlet network-dependency control)"
    else
        ok "Podman $v"
    fi
}

# aardvark-dns serves DNS on user-defined container networks (netavark
# hands containers the bridge gateway as nameserver; aardvark-dns is what
# answers there). On Debian it is only a Recommends of netavark, and
# Armbian ships with APT::Install-Recommends off, so podman can be fully
# functional while every lookup inside grafana/questdb-style containers
# fails with "connection refused". Ask podman where it resolved the
# helper (covers custom helper_binaries_dir); the binary is not on PATH,
# so fall back to the packaged locations.
check_aardvark_dns() {
    local p=""
    if command -v podman >/dev/null 2>&1; then
        p="$(podman info --format '{{.Host.NetworkBackendInfo.DNS.Path}}' 2>/dev/null || true)"
    fi
    if [[ -n "$p" && -x "$p" ]] \
        || [[ -x /usr/lib/podman/aardvark-dns || -x /usr/libexec/podman/aardvark-dns ]] \
        || command -v aardvark-dns >/dev/null 2>&1; then
        ok "aardvark-dns present (DNS for user-defined container networks)"
    else
        warn "aardvark-dns missing — installer will install it (container DNS on user-defined networks)"
    fi
}

# netavark's firewall driver execs the nft binary when it wires a container
# network. nftables is only a Recommends of netavark on Debian, and Armbian
# ships with APT::Install-Recommends off — podman looks healthy while every
# bridge-networked container fails to start with "netavark: unable to
# execute nft: No such file or directory". nft lives in /usr/sbin, which
# user shells often drop from PATH, so probe the packaged locations too.
check_nftables() {
    if command -v nft >/dev/null 2>&1 || [[ -x /usr/sbin/nft || -x /sbin/nft ]]; then
        ok "nftables present (netavark firewall backend)"
    else
        warn "nftables missing — installer will install it (netavark firewall for container networks)"
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

# Filter `Name|Image` lines (stdin) down to orphan container names: those
# whose image reference contains "signalk-server" (tag/owner-agnostic) but
# whose name is not one of the three Quadlet-managed containers. Split out
# from check_orphan_containers so it can be unit-tested with fixture input.
_orphan_names_from_ps() {
    local managed="signalk-server signalk-updater-server signalk-doctor-server"
    local name image
    # `|| [[ -n "$name" ]]` so a final line with no trailing newline is still
    # processed (read returns non-zero at EOF but has assigned the fields).
    while IFS='|' read -r name image || [[ -n "$name" ]]; do
        [[ -z "$name" ]] && continue
        case "$image" in
            *signalk-server*) ;;
            *) continue ;;
        esac
        case " $managed " in
            *" $name "*) continue ;;
        esac
        printf '%s\n' "$name"
    done
}

# Detect containers running a signalk-server image that are NOT the
# Quadlet-managed `signalk-server`. These come from ad-hoc `podman run`
# (e.g. a capability/bind probe whose entrypoint booted a full server) and
# survive across re-runs because they aren't systemd-managed and carry
# random names, so no `name=signalk-` filter ever sees them. On Network=host
# they squat signalk-server's port (or its 3000 fallback) and serve stale
# code from an older image — which looks exactly like "my changes aren't
# arriving." Offer to remove them interactively; warn otherwise.
check_orphan_containers() {
    if ! command -v podman >/dev/null 2>&1; then
        return 0
    fi
    local orphans=()
    mapfile -t orphans < <(podman ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | _orphan_names_from_ps)

    if (( ${#orphans[@]} == 0 )); then
        ok "No orphan signalk-server containers"
        return 0
    fi

    warn "Unmanaged signalk-server container(s) running: ${orphans[*]}"
    warn "These are not part of the systemd stack. On host networking they can"
    warn "squat signalk-server's port and serve stale code from an older image."

    if [[ ! -r /dev/tty ]] || [[ ! -w /dev/tty ]]; then
        warn "Remove them with:  podman rm -f ${orphans[*]}"
        return 0
    fi
    printf '\nRemove these orphan container(s) now? [y/N] ' >/dev/tty
    local reply=""
    read -r reply </dev/tty || return 0
    case "$reply" in
        y|Y|yes|YES)
            if podman rm -f "${orphans[@]}" >/dev/null 2>&1; then
                ok "Removed orphan container(s): ${orphans[*]}"
            else
                warn "Failed to remove some orphan container(s). Remove manually: podman rm -f ${orphans[*]}"
            fi
            ;;
        *)
            info "Left orphan container(s) in place. Remove later: podman rm -f ${orphans[*]}"
            ;;
    esac
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
    check_tmp_on_tmpfs
    check_ports
    check_cgroups_v2
    check_user_slice_delegation
    check_podman
    check_aardvark_dns
    check_nftables
    check_subid
    check_linger
    check_storage_fs
    check_legacy_install
    check_orphan_containers
}

# Only run the checks when executed directly. When sourced (e.g. by the
# test harness to exercise individual helpers like _orphan_names_from_ps),
# define the functions but don't run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
