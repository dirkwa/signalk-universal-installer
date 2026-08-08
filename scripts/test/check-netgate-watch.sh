#!/usr/bin/env bash
# Verifies the pasta gateway self-heal wiring (signalk netgate-watch).
#
# pasta reads the host's routes once, at container create, and latches the
# result for the container's lifetime. A container that starts before the
# host has a default route ends up on the link-local fallback, and its
# host.containers.internal points at an address nothing listens on -- for
# good. The engine Quadlets' ExecStartPre gate covers the fast case; these
# units cover a router that takes minutes, and repair boxes whose Quadlets
# predate the gate (issue #250).
#
# The real heal needs a live stack (podman + a user systemd session), so CI
# checks what CAN be verified host-independently:
#   1. `signalk netgate-watch` lays down both user units (content + enable
#      --now) against a sandbox HOME with systemctl stubbed, and a second
#      run is idempotent (no rewrite, no second enable).
#   2. The oneshot delegates to `signalk netgate-watch heal`, and the unit
#      text carries no podman or systemctl of its own.
#   3. The heal's guard chain -- exercised with stubs -- restarts only a
#      running container whose default gateway disagrees with the host's,
#      heals each container independently, and never probes over the
#      network (the probe is what hangs).
#
# Run from the repo root.

set -euo pipefail

CLI_TMPL="${CLI_TMPL:-installer/linux/signalk.tmpl}"
if [[ ! -f "$CLI_TMPL" ]]; then
    echo "[ERR] $CLI_TMPL not found (run from repo root)" >&2
    exit 2
fi

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# ── Sandbox: fake HOME, plus systemctl and podman stubs that record calls ──

export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/bin"
export SYSTEMCTL_LOG="$tmp/systemctl.log"
export SYSTEMCTL_STATE="$tmp/systemctl-state"
mkdir -p "$SYSTEMCTL_STATE"
: >"$SYSTEMCTL_LOG"

cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
    *is-enabled*) [[ -f "$SYSTEMCTL_STATE/enabled" ]] || exit 1 ;;
    *"enable --now"*) touch "$SYSTEMCTL_STATE/enabled" ;;
esac
exit 0
EOF

# podman stub. PODMAN_RUNNING is the set of running containers;
# PODMAN_GW_<name with - as _> is the gateway each reports from
# /proc/net/route. Any call that is not `exec` fails, so a heal that reached
# for the network (or for `podman inspect`) would be caught here.
cat >"$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$PODMAN_LOG"
[[ "$1" == "exec" ]] || exit 1
ctr="$2"; shift 2
case " ${PODMAN_RUNNING:-} " in *" $ctr "*) ;; *) exit 1 ;; esac
[[ "$1" == "true" ]] && exit 0
var="PODMAN_GW_${ctr//-/_}"
printf '%s\n' "${!var:-}"
EOF

chmod +x "$tmp/bin/systemctl" "$tmp/bin/podman"
export PATH="$tmp/bin:$PATH"
export PODMAN_LOG="$tmp/podman.log"
: >"$PODMAN_LOG"

unit_dir="$HOME/.config/systemd/user"
timer_unit="$unit_dir/signalk-netgate-watch.timer"
svc_unit="$unit_dir/signalk-netgate-watch.service"

# ── 1. Both units installed, enabled, and idempotent on a second run ───────

out1=$(bash "$CLI_TMPL" netgate-watch 2>&1) || {
    echo "[ERR] 'signalk netgate-watch' failed:" >&2
    printf '%s\n' "$out1" >&2
    exit 1
}

if [[ -f "$timer_unit" && -f "$svc_unit" ]]; then
    ok "both user units written"
else
    miss "expected $timer_unit and $svc_unit"
fi

# A timer belongs in timers.target, not default.target: under Linger=yes the
# latter would still work but is the wrong dependency for a timer.
if grep -q '^WantedBy=timers.target$' "$timer_unit" 2>/dev/null \
    && grep -q '^OnBootSec=' "$timer_unit" 2>/dev/null \
    && grep -q '^OnUnitActiveSec=' "$timer_unit" 2>/dev/null; then
    ok "timer is WantedBy=timers.target with boot + repeat triggers"
else
    miss "timer missing WantedBy=timers.target, OnBootSec or OnUnitActiveSec"
fi

if grep -q -- '--user enable --now signalk-netgate-watch.timer' "$SYSTEMCTL_LOG"; then
    ok "timer enabled --now"
else
    miss "no 'enable --now signalk-netgate-watch.timer' recorded"
fi

timer_before=$(cat "$timer_unit")
svc_before=$(cat "$svc_unit")

out2=$(bash "$CLI_TMPL" netgate-watch 2>&1) || {
    echo "[ERR] second 'signalk netgate-watch' run failed" >&2
    printf '%s\n' "$out2" >&2
    exit 1
}

if [[ "$(cat "$timer_unit")" == "$timer_before" && "$(cat "$svc_unit")" == "$svc_before" ]]; then
    ok "second run left both units byte-identical"
else
    miss "second run rewrote a unit"
fi

enables=$(grep -c -- 'enable --now signalk-netgate-watch.timer' "$SYSTEMCTL_LOG" || true)
if [[ "$enables" == "1" ]]; then
    ok "enable --now issued exactly once across both runs"
else
    miss "enable --now issued $enables times (want 1)"
fi

# ── 2. The oneshot delegates to the CLI ────────────────────────────────────

# Keeping the logic in the CLI (not the unit) is what lets `signalk update`
# ship a fixed heal to an existing box without rewriting its units.
if grep -q '^ExecStart=%h/\.local/bin/signalk netgate-watch heal$' "$svc_unit" 2>/dev/null \
    && ! grep -qE '(podman|systemctl)' "$svc_unit"; then
    ok "oneshot delegates to 'signalk netgate-watch heal'; unit text has no podman/systemctl"
else
    miss "oneshot does not delegate cleanly to the CLI"
fi

# ── 3. Heal guard chain ────────────────────────────────────────────────────

# Host has a default route via 192.168.0.1 -> 0100A8C0 (little-endian hex).
printf 'Iface\tDestination\tGateway\tFlags\n' >"$tmp/route-up"
printf 'eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n' >>"$tmp/route-up"
# No default route at all (destination is a subnet, not 00000000).
printf 'Iface\tDestination\tGateway\tFlags\n' >"$tmp/route-down"
printf 'eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n' >>"$tmp/route-down"

# 0202FEA9 is 169.254.2.2 little-endian: pasta's link-local fallback gateway.
LINK_LOCAL=0202FEA9
HOST_GW=0100A8C0

heal_restarts() {
    # $1 = host route file, rest = env assignments for the podman stub
    local route="$1"; shift
    : >"$SYSTEMCTL_LOG"
    : >"$PODMAN_LOG"
    env SIGNALK_NETGATE_ROUTE="$route" "$@" \
        bash "$CLI_TMPL" netgate-watch heal >"$tmp/heal.out" 2>&1 || true
    grep -c 'restart' "$SYSTEMCTL_LOG" || true
}

both="signalk-doctor-server signalk-updater-server"

n=$(heal_restarts "$tmp/route-down" PODMAN_RUNNING="$both" \
        PODMAN_GW_signalk_doctor_server="$LINK_LOCAL" \
        PODMAN_GW_signalk_updater_server="$LINK_LOCAL")
if [[ "$n" == "0" ]]; then
    ok "guard 1: host has no default route -> no restart"
else
    miss "guard 1: restarted $n container(s) with no host route (want 0)"
fi

n=$(heal_restarts "$tmp/route-up" PODMAN_RUNNING="")
if [[ "$n" == "0" ]]; then
    ok "guard 2: container not running -> no restart (try-restart semantics)"
else
    miss "guard 2: restarted $n stopped container(s) (want 0)"
fi

n=$(heal_restarts "$tmp/route-up" PODMAN_RUNNING="$both" \
        PODMAN_GW_signalk_doctor_server="$HOST_GW" \
        PODMAN_GW_signalk_updater_server="$HOST_GW")
if [[ "$n" == "0" ]]; then
    ok "guard 3: gateways match -> no restart (self-limiting)"
else
    miss "guard 3: restarted $n healthy container(s) (want 0)"
fi

# A running container that reports no gateway at all is not evidence of a
# stale mapping -- restarting on "no answer" would make the heal fire on any
# transient read failure.
n=$(heal_restarts "$tmp/route-up" PODMAN_RUNNING="$both" \
        PODMAN_GW_signalk_doctor_server="" \
        PODMAN_GW_signalk_updater_server="")
if [[ "$n" == "0" ]]; then
    ok "guard 3: container reports no gateway -> no restart"
else
    miss "guard 3: restarted $n container(s) that reported no gateway (want 0)"
fi

n=$(heal_restarts "$tmp/route-up" PODMAN_RUNNING="$both" \
        PODMAN_GW_signalk_doctor_server="$LINK_LOCAL" \
        PODMAN_GW_signalk_updater_server="$HOST_GW")
if [[ "$n" == "1" ]] \
    && grep -q 'restart signalk-doctor-server.service' "$SYSTEMCTL_LOG"; then
    ok "guard 4: heals only the container on the stale gateway"
else
    miss "guard 4: expected exactly the doctor restarted, got $n restart(s)"
fi

n=$(heal_restarts "$tmp/route-up" PODMAN_RUNNING="$both" \
        PODMAN_GW_signalk_doctor_server="$LINK_LOCAL" \
        PODMAN_GW_signalk_updater_server="$LINK_LOCAL")
if [[ "$n" == "2" ]]; then
    ok "guard 4: heals both containers independently when both are stale"
else
    miss "guard 4: expected 2 restarts when both are stale, got $n"
fi

# The heal must never probe over the network: that request is exactly what
# black-holes, and a timeout could not distinguish a broken pasta mapping
# from a server that is merely down. Only `podman exec` is legitimate.
if grep -qE 'curl|wget|host\.containers\.internal|inspect' "$PODMAN_LOG" 2>/dev/null; then
    miss "heal reached for the network or podman inspect (must compare routes only)"
else
    ok "heal used podman exec only -- no network probe"
fi

# ── 4. Wiring: dispatcher, render ride-along, installer, Windows shim ──────

if grep -q 'netgate-watch) shift; cmd_netgate_watch' "$CLI_TMPL"; then
    ok "dispatcher routes 'netgate-watch'"
else
    miss "no dispatcher arm for 'netgate-watch'"
fi

# The ride-along is the ONLY route by which an existing box gets the fix:
# render-server rewrites signalk-server.container only, so engine Quadlets
# installed before the route gate are never refreshed.
# Assert the call sits INSIDE cmd_render_server, not merely somewhere in the
# file: the definition and the dispatcher arm would satisfy a naive count
# even with the ride-along deleted.
if awk '/^cmd_render_server\(\)/{inside=1} inside && /_signalk_ensure_netgate_watch/{found=1} inside && /^}/{exit} END{exit !found}' \
        "$CLI_TMPL"; then
    ok "render-server ride-along calls _signalk_ensure_netgate_watch"
else
    miss "netgate-watch does not ride along with render-server (existing boxes would never get it)"
fi

if grep -q 'netgate-watch' installer/linux/install.sh; then
    ok "fresh install invokes 'signalk netgate-watch'"
else
    miss "install.sh never installs the netgate-watch units"
fi

# The Windows shim hides Linux-host-only commands from its help output.
if grep -q 'resolv-watch|netgate-watch' "$CLI_TMPL"; then
    ok "Windows shim help-suppression lists netgate-watch"
else
    miss "netgate-watch missing from the Windows shim help-suppression regex"
fi

if [[ "$fail" == 0 ]]; then
    echo "[PASS] netgate-watch wiring checks"
else
    echo "[FAIL] netgate-watch wiring checks" >&2
    exit 1
fi
