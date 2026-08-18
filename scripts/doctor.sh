#!/usr/bin/env bash
# Post-install standalone health check. Probes the running stack without
# touching it. Safe to run any time. Mirrors the doctor container's probes
# at a coarser granularity — the container's /api/probes endpoint is the
# real diagnostic surface.

set -euo pipefail

# signalk-server's HTTP port is install-time-configurable (80 or 3000).
# Read it from the rendered Quadlet's `Environment=PORT=` line so this
# standalone probe hits the right port without the operator exporting
# SIGNALK_URL; fall back to 80 (the default) when the line is absent.
sk_http_port() {
    local q="${HOME}/.config/containers/systemd/signalk-server.container"
    local p
    # `|| true`: a missing Quadlet makes sed exit 2 (pipefail propagates it);
    # keep the ${p:-80} fallback reachable regardless of call site.
    p=$(sed -n 's/^Environment=PORT=\([0-9][0-9]*\).*/\1/p' "$q" 2>/dev/null | head -1 || true)
    printf '%s' "${p:-80}"
}

UPDATER_URL=${UPDATER_URL:-http://127.0.0.1:3003}
DOCTOR_URL=${DOCTOR_URL:-http://127.0.0.1:3004}
SIGNALK_URL=${SIGNALK_URL:-http://127.0.0.1:$(sk_http_port)/signalk}

check() {
    local name=$1; local url=$2
    if curl -fsS -o /dev/null -m 5 "$url"; then
        printf '  [OK]   %-20s %s\n' "$name" "$url"
    else
        printf '  [FAIL] %-20s %s\n' "$name" "$url"
    fi
}

# Seconds to wait on podman before declaring it wedged, and how long after
# SIGTERM to escalate to SIGKILL. The escalation is load-bearing: a podman
# wedged on the c/storage lock spins in kernel space and IGNORES SIGTERM, and
# timeout(1) then waits for the child rather than returning -- so a plain
# `timeout` bounds nothing at all. Measured against a SIGTERM-ignoring stub,
# `timeout 3` returned only after 121s; `timeout -k 2 3` returned after 5s.
PODMAN_TIMEOUT=${PODMAN_TIMEOUT:-15}
PODMAN_KILL_AFTER=${PODMAN_KILL_AFTER:-5}

# Every podman call here is timeout-guarded, because podman has a failure mode
# where it blocks FOREVER rather than erroring: a SIGKILLed container create
# leaves an incomplete layer whose overlayfs mount survives, podman's cleanup
# spins on it holding the global c/storage lock, and every later command --
# `podman ps` included -- queues behind that lock.
#
# Unguarded, this probe hangs the operator's terminal at exactly the moment
# they most need an answer, and prints nothing at all. Worse, the closing hint
# below sends them to `signalk-recovery`, so the whole diagnostic path dies
# together. A wedged podman is a finding; report it as one.
container_snapshot() {
    local out rc=0
    # Two families, and listing only the first is the 2026-08-18 field bug:
    # engine containers are `signalk-*`, but everything the
    # signalk-container plugin manages is `<namespace>-*` (default `sk-`) —
    # QuestDB, Grafana, Ollama, Whisper and every user-added container. A
    # bare `--filter name=signalk-` hides all of them, which is most of the
    # stack an operator wants to see here.
    #
    # `--filter name=` is a SUBSTRING match and cannot express "starts
    # with", so list once and select on the name column with awk. That also
    # rejects an unrelated container merely CONTAINING the token (someone's
    # `my-signalk-backup`), which the old filter silently included.
    #
    # This script is deliberately standalone (it is the SSH-only recovery
    # surface and sources nothing), so it cannot reuse the CLI's
    # signalk_all_containers() helper — the logic is duplicated on purpose.
    out=$(timeout -k "$PODMAN_KILL_AFTER" "$PODMAN_TIMEOUT" \
        podman ps -a \
        --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null \
        | awk -F'\t' '$1 ~ /^(signalk|sk)-/ { printf "  %s  %s  %s\n", $1, $2, $3 }') || rc=$?
    if [[ $rc -eq 0 ]]; then
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            echo "  (no signalk-* or sk-* containers)"
        fi
        return
    fi
    # 124 = timeout(1) gave up; 137 = 128+SIGKILL, the escalation landed
    # because podman ignored SIGTERM. Both mean the same thing to an operator.
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        echo "  [FAIL] podman did not answer within ${PODMAN_TIMEOUT}s"
        echo "         The c/storage lock is held, usually by a stuck cleanup of an"
        echo "         incomplete layer left behind by a SIGKILLed container create."
        echo "         Confirm:  journalctl --user | grep -i 'incomplete layer'"
        echo "                   dmesg | grep -i overlayfs"
        echo "         Recover:  ~/.local/bin/signalk-recovery unwedge-podman"
    else
        echo "  [WARN] podman unavailable (exit $rc)"
    fi
}

echo "=== SignalK Stack Doctor ==="
check "signalk-server"  "$SIGNALK_URL"
check "updater (:3003)" "$UPDATER_URL/api/health"
check "doctor (:3004)"  "$DOCTOR_URL/api/health"

echo
echo "=== systemd-user units ==="
systemctl --user --no-pager list-units --all 'signalk-*' 2>/dev/null || true

echo
echo "=== Container snapshot ==="
container_snapshot

# Root storage type. Twin of the doctor container's storage-type probe (CC-3),
# but reads the host's real /proc + /sys directly so it works with zero
# containers running. microSD I/O stalls are the usual cause of slow health
# responses; flag it and point at the SSD fix.
echo
echo "=== Host root storage ==="
root_storage() {
    local dev base rot
    dev=$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null)
    if [[ -z "$dev" || "$dev" != /dev/* ]]; then
        echo "  could not determine root device"
        return
    fi
    base=${dev#/dev/}
    case "$base" in
        # Partitioned mmcblk/nvme: strip the pN suffix, keep the device index
        # (mmcblk0p2 -> mmcblk0, nvme0n1p2 -> nvme0n1). A bare mmcblk0/nvme0n1
        # (root on the whole device) matches neither arm and is left intact.
        mmcblk*p[0-9]* | nvme*n[0-9]*p[0-9]*) base=${base%p[0-9]*} ;;
        # Traditional disks only — strip trailing partition digits. Scoped so
        # it can't over-strip a bare nvme/mmc device number.
        sd*[0-9] | hd*[0-9] | vd*[0-9] | xvd*[0-9]) base=${base%%[0-9]*} ;;
    esac
    rot=$(cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo "?")
    case "$base" in
        mmcblk*)
            echo "  [WARN] root on SD card ($base) — microSD I/O stalls cause slow"
            echo "         health/probe responses; a USB3/NVMe SSD removes them"
            ;;
        nvme*)
            echo "  [OK]   root on $base (NVMe SSD)" ;;
        *)
            if [[ "$rot" == "0" ]]; then
                echo "  [OK]   root on $base (SSD/flash)"
            elif [[ "$rot" == "1" ]]; then
                echo "  [OK]   root on $base (spinning disk)"
            else
                echo "  [OK]   root on $base"
            fi
            ;;
    esac
}
root_storage

# app.slice (signalk-server + engine consoles) vs user.slice (containers
# signalk-container manages) — the installer sets app.slice to CPUWeight=300
# so a chart import cannot take half the CPU from signalk-server. Reads the
# live cgroup value, not the drop-in, because a drop-in only takes effect
# after daemon-reload and removal only after re-login.
echo
echo "=== CPU priority ==="
cpu_priority() {
    local slice weight conf configured
    slice="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"
    conf="${HOME}/.config/systemd/user/app.slice.d/50-signalk-cpu-priority.conf"
    weight=$(cat "$slice/cpu.weight" 2>/dev/null || true)
    configured=$(sed -n 's/^[[:space:]]*CPUWeight[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$conf" 2>/dev/null | head -1 || true)
    if [[ -z "$weight" ]]; then
        echo "  [WARN] app.slice cpu.weight unreadable — cgroup v2 cpu controller not"
        echo "         delegated to the user slice; CPU priorities have no effect"
    elif [[ -n "$configured" && "$weight" != "$configured" ]]; then
        echo "  [WARN] app.slice cpu.weight=$weight but $conf says CPUWeight=$configured"
        echo "         Apply:  systemctl --user daemon-reload   (or log out and back in)"
    elif [[ "$weight" -gt 100 ]]; then
        echo "  [OK]   app.slice cpu.weight=$weight (SK stack outranks plugin containers under contention)"
    elif [[ -n "$configured" ]]; then
        echo "  [OK]   app.slice cpu.weight=$weight as configured in $conf"
    else
        echo "  [WARN] app.slice cpu.weight=$weight — SK stack shares CPU 1:1 with plugin"
        echo "         containers under contention; re-run the installer to set the drop-in"
    fi
}
cpu_priority

echo
echo "For deeper diagnostics:"
echo "  curl -fsS $DOCTOR_URL/api/probes | jq ."
echo "  ~/.local/bin/signalk-recovery doctor"
