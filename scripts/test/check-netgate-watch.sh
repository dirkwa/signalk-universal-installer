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
    # Point the lock at a path that does not exist so these cases exercise
    # the gateway logic, not guard 0.
    env SIGNALK_NETGATE_ROUTE="$route" SIGNALK_OPERATION_LOCK="$tmp/no-lock" "$@" \
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

# Guard 0: operation.lock serialises version switches, self-updates,
# doctor-switches, hardware-applies and recovery. It lives on a host
# bind-mount, so restarting a container does NOT release it -- killing a
# holder mid-flight strands a lock that needs a manual `rm` over SSH, which
# is worse than the stale gateway. But a stuck lock must not disable the
# heal forever, so a clearly-stale one is overridden.
lock_stub() {
    env SIGNALK_NETGATE_ROUTE="$tmp/route-up" SIGNALK_OPERATION_LOCK="$1" \
        PODMAN_RUNNING="$both" \
        PODMAN_GW_signalk_doctor_server="$LINK_LOCAL" \
        PODMAN_GW_signalk_updater_server="$LINK_LOCAL" \
        bash "$CLI_TMPL" netgate-watch heal >"$tmp/heal.out" 2>&1 || true
}

: >"$SYSTEMCTL_LOG"
touch "$tmp/op.lock"
lock_stub "$tmp/op.lock"
if [[ "$(grep -c 'restart' "$SYSTEMCTL_LOG" || true)" == "0" ]] \
    && grep -q 'operation is in progress' "$tmp/heal.out"; then
    ok "guard 0: a held operation.lock defers the heal (no mid-operation restart)"
else
    miss "guard 0: heal restarted a container while operation.lock was held"
fi

: >"$SYSTEMCTL_LOG"
touch -d '20 minutes ago' "$tmp/op.lock" 2>/dev/null || touch -t "$(date -d '20 minutes ago' +%Y%m%d%H%M 2>/dev/null || echo 197001010000)" "$tmp/op.lock"
lock_stub "$tmp/op.lock"
if [[ "$(grep -c 'restart' "$SYSTEMCTL_LOG" || true)" == "2" ]] \
    && grep -q 'treating it as stale' "$tmp/heal.out"; then
    ok "guard 0: a stale operation.lock is overridden, with a warning"
else
    miss "guard 0: stale lock blocked the heal (one stuck file would disable it forever)"
fi
rm -f "$tmp/op.lock"

# A restart that does not converge must say so. Guard 3 only self-limits when
# the new container picks up the host gateway; without a post-restart check
# a permanently stale container would be restarted on every pass forever,
# with nothing in the journal but a repeating line (the engine start limit
# does not catch it: 1 start/10min is under 5 per 300s).
: >"$SYSTEMCTL_LOG"
: >"$PODMAN_LOG"
cat >"$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$PODMAN_LOG"
[[ "$1" == "exec" ]] || exit 1
ctr="$2"; shift 2
[[ "$1" == "true" ]] && exit 0
# The doctor never converges; the updater is healthy.
[[ "$ctr" == "signalk-doctor-server" ]] && { printf '0202FEA9\n'; exit 0; }
printf '0100A8C0\n'
EOF
chmod +x "$tmp/bin/podman"
nc_rc=0
env SIGNALK_NETGATE_ROUTE="$tmp/route-up" bash "$CLI_TMPL" netgate-watch heal \
    >"$tmp/heal.out" 2>&1 || nc_rc=$?
if [[ "$nc_rc" == "0" ]] \
    && grep -q 'STILL on gateway' "$tmp/heal.out" \
    && ! grep -q 'healed 1' "$tmp/heal.out"; then
    ok "a restart that does not converge warns and is not counted as healed"
else
    miss "non-converging restart did not produce an actionable warning (rc=$nc_rc)"
    printf '         %s\n' "$(head -2 "$tmp/heal.out")"
fi

# A container can stop between the running probe and the gateway read. Under
# `set -e` an unabsorbed failure there aborts the whole heal, so the OTHER
# container silently goes unchecked -- the containers must stay independent.
: >"$SYSTEMCTL_LOG"
: >"$PODMAN_LOG"
cat >"$tmp/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$PODMAN_LOG"
[[ "$1" == "exec" ]] || exit 1
ctr="$2"; shift 2
[[ "$1" == "true" ]] && exit 0
# The doctor raced away after the running probe; the updater is stale.
[[ "$ctr" == "signalk-doctor-server" ]] && exit 1
printf '0202FEA9\n'
EOF
chmod +x "$tmp/bin/podman"
# `|| rc=$?` and not a bare call: this script runs under `set -e` too, so an
# aborting heal would kill the test instead of being reported as a failure.
rc=0
env SIGNALK_NETGATE_ROUTE="$tmp/route-up" bash "$CLI_TMPL" netgate-watch heal \
    >"$tmp/heal.out" 2>&1 || rc=$?
if [[ "$rc" == "0" ]] && grep -q 'restart signalk-updater-server.service' "$SYSTEMCTL_LOG"; then
    ok "a container vanishing mid-run does not abort the heal for the other"
else
    miss "container vanishing mid-run aborted the heal (rc=$rc); the other went unchecked"
fi

# A missing/unreadable route file is "no route", not a fatal error.
: >"$SYSTEMCTL_LOG"
if env SIGNALK_NETGATE_ROUTE="$tmp/no-such-file" bash "$CLI_TMPL" netgate-watch heal \
        >/dev/null 2>&1; then
    ok "unreadable host route file exits cleanly (treated as no route)"
else
    miss "unreadable host route file made the heal exit non-zero"
fi

# Restore the standard stub for the checks below.
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
chmod +x "$tmp/bin/podman"

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

# Match the invocation, not the bare name: install.sh explains the units in
# a comment right above the call, so a plain name grep would still pass with
# the call deleted.
if grep -qE '^[^#]*signalk"? netgate-watch' installer/linux/install.sh; then
    ok "fresh install invokes 'signalk netgate-watch'"
else
    miss "install.sh never installs the netgate-watch units"
fi

# netgate-watch must NOT be hidden from Windows help. It heals the pasta
# gateway with `podman exec` and `systemctl --user`, both of which exist inside
# the Podman machine, and install.sh installs its units on the Windows path
# like any other. It was suppressed here on the same mistaken grounds that hid
# render-server -- that the VM has no host-side state -- which told Windows
# operators a working recovery tool did not exist.
if grep -qE '^[[:space:]]*/\^.*signalk \([a-z|-]*netgate-watch[a-z|-]*\)' "$CLI_TMPL"; then
    miss "netgate-watch is hidden from Windows help, but it works inside the VM"
else
    ok "netgate-watch stays visible in Windows help"
fi

if [[ "$fail" == 0 ]]; then
    echo "[PASS] netgate-watch wiring checks"
else
    echo "[FAIL] netgate-watch wiring checks" >&2
    exit 1
fi
