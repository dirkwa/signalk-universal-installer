#!/usr/bin/env bash
# Verifies the USB serial hotplug wiring (signalk hardware-watch).
#
# The real pass needs udev, podman and a user systemd session, so CI checks
# what can be verified host-independently:
#   1. `signalk hardware-watch` lays down both user units against a sandbox
#      HOME with systemctl stubbed, and a second run is idempotent.
#   2. The oneshot delegates to `signalk hardware-watch heal`, with no podman
#      or systemctl in the unit text.
#   3. The heal pass, with podman, the rescan and the restart stubbed, rescans
#      for an unlisted device (render only, no restart, while the server is
#      stopped), restarts for a listed device the container lacks or holds
#      as another device node, defers with exit 75 while operation.lock is
#      held, and does nothing otherwise.
#
# Run from the repo root.

set -euo pipefail

CLI_TMPL="${CLI_TMPL:-installer/linux/signalk.tmpl}"
if [[ ! -f "$CLI_TMPL" ]]; then
    echo "[ERR] $CLI_TMPL not found (run from repo root)" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "[ERR] jq is required for this check" >&2
    exit 2
fi

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

export HOME="$tmp/home"
mkdir -p "$HOME"
export SYSTEMCTL_LOG="$tmp/systemctl.log"
export SYSTEMCTL_STATE="$tmp/systemctl-state"
mkdir -p "$tmp/bin" "$SYSTEMCTL_STATE"
: >"$SYSTEMCTL_LOG"
cat >"$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
    *is-enabled*) [[ -f "$SYSTEMCTL_STATE/enabled" ]] || exit 1 ;;
    *"enable --now"*) touch "$SYSTEMCTL_STATE/enabled" ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH"

unit_dir="$HOME/.config/systemd/user"
path_unit="$unit_dir/signalk-hardware-watch.path"
svc_unit="$unit_dir/signalk-hardware-watch.service"

# ── 1. First run installs + enables both units ──────────────────────────────

out1=$(bash "$CLI_TMPL" hardware-watch 2>&1) || {
    echo "[ERR] 'signalk hardware-watch' failed:" >&2
    printf '%s\n' "$out1" >&2
    exit 1
}

if grep -q '^PathChanged=/dev/serial/by-id$' "$path_unit" 2>/dev/null \
    && grep -q '^WantedBy=default\.target$' "$path_unit" 2>/dev/null; then
    ok "path unit watches /dev/serial/by-id"
else
    miss "path unit missing or not watching /dev/serial/by-id"
fi

if grep -q 'daemon-reload' "$SYSTEMCTL_LOG" \
    && grep -q -- '--user enable --now signalk-hardware-watch.path' "$SYSTEMCTL_LOG" \
    && ! grep -q -- 'start --no-block signalk-hardware-watch.service' "$SYSTEMCTL_LOG"; then
    ok "daemon-reload + enable --now issued; no pass from a bare install (install.sh detects itself)"
else
    miss "expected systemctl calls not recorded"
    sed 's/^/         /' "$SYSTEMCTL_LOG"
fi

fn_body=$(awk '
    /^_signalk_ensure_hardware_watch\(\) \{/ { inblock = 1 }
    inblock { print }
    inblock && /^\}$/ { exit }
' "$CLI_TMPL")
if grep -q '_signalk_ensure_unit_dir' <<<"$fn_body" \
    && ! grep -qE '(^|[^_[:alnum:]])mkdir([[:space:]]|$)' <<<"$fn_body"; then
    ok "unit dir created through the ownership-aware helper"
else
    miss "_signalk_ensure_hardware_watch must use _signalk_ensure_unit_dir, not mkdir"
fi

# ── 2. Oneshot delegates to the CLI ─────────────────────────────────────────

if grep -q '^ExecStart=%h/\.local/bin/signalk hardware-watch heal$' "$svc_unit" 2>/dev/null \
    && grep -q '^ConditionPathExists=%h/\.local/bin/signalk$' "$svc_unit" 2>/dev/null \
    && grep -q '^RestartForceExitStatus=75$' "$svc_unit" 2>/dev/null \
    && ! grep -v '^#' "$svc_unit" | grep -Eq 'podman|systemctl'; then
    ok "oneshot delegates to 'signalk hardware-watch heal', retries exit 75; unit text has no podman/systemctl"
else
    miss "oneshot must delegate to the CLI without direct podman/systemctl calls"
    sed 's/^/         /' "$svc_unit" 2>/dev/null || true
fi

# ── 3. Heal decisions (stubbed) ─────────────────────────────────────────────

funcs="$tmp/funcs.sh"
sed '/^case "${1:-help}" in/,$d' "$CLI_TMPL" | sed 's/__SK_VERSION__/test/g' >"$funcs"
if ! grep -q '^_signalk_hardware_heal()' "$funcs"; then
    echo "[ERR] _signalk_hardware_heal not found after stripping the dispatcher." >&2
    exit 2
fi

by_id="$tmp/by-id"
gw="$by_id/usb-Actisense_NGT-1_3A055-if00-port0"
hw_dir="$HOME/.signalk-updater"
mkdir -p "$hw_dir"

# $1 = devices on the host (space separated names under $by_id)
# $2 = hardware.json serial entries as JSON, or "none" for no file
# $3 = container: down | has | lacks | stale (holds another device node)
# $4 = operation.lock: none | held
run_heal() {
    rm -rf "$by_id" "$tmp/marks"
    mkdir -p "$by_id" "$tmp/marks"
    local d
    for d in $1; do : >"$by_id/$d"; done
    if [[ "$2" == none ]]; then
        rm -f "$hw_dir/hardware.json"
    else
        printf '{"serial": %s}\n' "$2" >"$hw_dir/hardware.json"
    fi
    rm -f "$tmp/op.lock"
    if [[ "${4:-none}" == held ]]; then : >"$tmp/op.lock"; fi
    SIGNALK_SERIAL_BY_ID="$by_id" SIGNALK_HARDWARE_SETTLE=0 \
        SIGNALK_OPERATION_LOCK="$tmp/op.lock" \
        CONTAINER_STATE="$3" MARK="$tmp/marks" bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        . "'"$funcs"'"
        podman() {
            case "$*" in
                "exec signalk-server true") [[ "$CONTAINER_STATE" != down ]] ;;
                "exec signalk-server stat "*)
                    case "$CONTAINER_STATE" in
                        has) stat -L -c "%t:%T" "${@: -1}" ;;
                        stale) echo "bc:1" ;;
                        *) return 1 ;;
                    esac ;;
                *) return 0 ;;
            esac
        }
        cmd_hardware() { echo "$*" >>"$MARK/rescan.log"; }
        cmd_render_server() { echo "render $*" >>"$MARK/rescan.log"; }
        _signalk_restart_server() { echo restart >>"$MARK/restart.log"; }
        rc=0
        _signalk_hardware_heal || rc=$?
        echo "$rc" >"$MARK/rc"
    ' >/dev/null
}

# Exit status, rescan calls and restarts are recorded and compared as one
# string, so a case that exits 75 after a rescan, or restarts after a
# render-only pass, fails.
heal_case() {
    local desc="$1" want="$2" got rescans=none restarts=0
    shift 2
    run_heal "$@"
    if [[ -f "$tmp/marks/rescan.log" ]]; then
        rescans=$(paste -sd ';' "$tmp/marks/rescan.log")
    fi
    if [[ -f "$tmp/marks/restart.log" ]]; then
        restarts=$(wc -l <"$tmp/marks/restart.log" | tr -d ' ')
    fi
    got="rc=$(cat "$tmp/marks/rc") rescan=${rescans} restarts=${restarts}"
    if [[ "$got" == "$want" ]]; then
        ok "heal: $desc"
    else
        miss "heal: $desc (got '$got', want '$want')"
    fi
}

name=$(basename "$gw")
listed_on="[{\"byId\":\"$gw\",\"enabled\":true}]"
listed_off="[{\"byId\":\"$gw\",\"enabled\":false}]"

heal_case "unlisted device → rescan" "rc=0 rescan=rescan restarts=0" "$name" "[]" lacks
heal_case "listed device the container lacks → restart" "rc=0 rescan=none restarts=1" "$name" "$listed_on" lacks
heal_case "listed device the container has → nothing" "rc=0 rescan=none restarts=0" "$name" "$listed_on" has
heal_case "device switched off → nothing" "rc=0 rescan=none restarts=0" "$name" "$listed_off" lacks
heal_case "unplug (no device on host) → nothing" "rc=0 rescan=none restarts=0" "" "$listed_on" lacks
heal_case "listed device replugged as another node → restart" "rc=0 rescan=none restarts=1" "$name" "$listed_on" stale
heal_case "server stopped, unlisted device → hardware.json + Quadlet, no restart" \
    "rc=0 rescan=rescan --no-render;render --no-restart restarts=0" "$name" "[]" down
heal_case "server stopped, listed device → nothing" "rc=0 rescan=none restarts=0" "$name" "$listed_on" down
heal_case "operation.lock held → exit 75, nothing else" "rc=75 rescan=none restarts=0" "$name" "[]" lacks held
heal_case "no hardware.json → nothing" "rc=0 rescan=none restarts=0" "$name" none lacks

# ── 3b. render-server starts the first pass after its render ──────────────
# A pass started before the render's write could rescan while the render
# still works from the old hardware.json. The render body is stubbed to call
# the real ensure (as the real body does) and then log its write.

first_pass() {
    local h="$tmp/fp-home"
    rm -rf "$h"
    mkdir -p "$h"
    : >"$tmp/fp.log"
    HOME="$h" FP_LOG="$tmp/fp.log" bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        . "'"$funcs"'"
        systemctl() {
            case "$*" in *is-enabled*) return 1 ;; esac
            echo "systemctl $*" >>"$FP_LOG"
        }
        _signalk_render_server() {
            _signalk_ensure_hardware_watch >/dev/null
            echo "render-written" >>"$FP_LOG"
        }
        cmd_render_server "$@"
    ' _ "$@" >/dev/null
}

first_pass
order=$(grep -n -e 'render-written' -e 'start --no-block signalk-hardware-watch.service' "$tmp/fp.log" | cut -d: -f2-)
if [[ "$order" == "render-written
systemctl --user start --no-block signalk-hardware-watch.service" ]]; then
    ok "render-server starts the first pass after the render is written"
else
    miss "first pass not started after the render"
    sed 's/^/         /' "$tmp/fp.log"
fi

first_pass --no-restart
if ! grep -q 'start --no-block signalk-hardware-watch.service' "$tmp/fp.log"; then
    ok "render-server --no-restart starts no pass (a pass may restart the server)"
else
    miss "render-server --no-restart started a pass"
fi

# ── 4. Second run is idempotent ─────────────────────────────────────────────

out2=$(bash "$CLI_TMPL" hardware-watch 2>&1) || {
    echo "[ERR] second 'signalk hardware-watch' run failed" >&2
    exit 1
}
enables=$(grep -c -- 'enable --now signalk-hardware-watch.path' "$SYSTEMCTL_LOG" || true)
if grep -q 'already installed' <<<"$out2" && [[ "$enables" == 1 ]]; then
    ok "second run short-circuits; enable --now issued once"
else
    miss "second run not idempotent (enables: $enables)"
    printf '         %s\n' "$out2"
fi

if [[ "$fail" == 0 ]]; then
    echo "[PASS] hardware-watch wiring checks"
else
    echo "[FAIL] hardware-watch wiring checks" >&2
    exit 1
fi
