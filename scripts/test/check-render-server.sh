#!/usr/bin/env bash
# Verifies `signalk render-server` (cmd_render_server in signalk.tmpl):
# rebuilding the live signalk-server.container from the staged template so a
# template-only fix reaches an already-deployed box (issue #217).
#
# The real command does a systemctl daemon-reload + restart, which needs a live
# systemd-user + updater and can't run in CI. So we source the function out of
# the template, point every path (payload dir, hardware.json, live Quadlet,
# snapshot dir) at a tmp tree, and STUB the side-effecting calls (systemctl,
# _signalk_restart_server, sk_http_port). Then we assert the file-level
# contract that actually matters:
#   1. Idempotent — when the render already matches the live Quadlet, nothing
#      is written and no restart is attempted.
#   2. Applies a template delta — snapshots the old Quadlet (CC-1), rewrites the
#      live one from the template, daemon-reloads, and restarts.
#   3. --no-restart rewrites + daemon-reloads but does NOT restart.
#   4. Missing staged payload → a clear non-zero error (points at `signalk
#      update`), not a cryptic failure.
#
# Run from the repo root.

set -euo pipefail

TMPL="${TMPL:-installer/linux/signalk.tmpl}"
RENDERER="${RENDERER:-installer/linux/render-server-quadlet.sh}"
SERVER_TMPL="${SERVER_TMPL:-quadlets/signalk-server.container.template}"
for f in "$TMPL" "$RENDERER" "$SERVER_TMPL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not installed — render-server-quadlet.sh uses the sed fallback; skip."
    exit 0
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# Strip the dispatcher `case` so sourcing runs only the function defs, then
# render the __SK_VERSION__ placeholder to a dummy (it's just a string).
funcs="$root/funcs.sh"
sed '/^case "${1:-help}" in/,$d' "$TMPL" | sed 's/__SK_VERSION__/test/g' >"$funcs"
# Fail loudly if the strip silently no-op'd (the dispatcher line changed
# wording) — otherwise the case block gets sourced, hits its default branch
# with $1 unset, and may exit and kill the harness with a confusing error far
# from the real cause. Also assert the function we exercise is actually present.
# shellcheck disable=SC2016  # matching the literal dispatcher line, no expansion wanted
if grep -q '^case "${1:-help}" in' "$funcs"; then
    echo "[ERR] failed to strip the dispatcher from $TMPL — the sed pattern no longer matches." >&2
    exit 2
fi
if ! grep -q '^cmd_render_server()' "$funcs"; then
    echo "[ERR] cmd_render_server not found in $TMPL after stripping — refactored away?" >&2
    exit 2
fi

# A hardware.json with a single enabled serial device (mirrors the render test
# fixture). Enough to exercise the hardware block; the point here is the file
# lifecycle, not the block contents. cmd_render_server reads it from
# $HOME/.signalk-updater/hardware.json, so it must live there under $root.
#
# Serial devices are existence-guarded at render time, so the fixture's by-id
# path must exist for the AddDevice= line to render (otherwise the block would
# be empty and the lifecycle assertions, while still valid, wouldn't exercise
# a serial device at all). Point SERIAL_DIR at a seeded temp node; the export
# reaches both canonical() and the renderer spawned inside run_render.
serialdir="$root/serial-by-id"
mkdir -p "$serialdir"
serial_byid="$serialdir/usb-FTDI_TEST-if00-port0"
: >"$serial_byid"
export SERIAL_DIR="$serialdir"

mkdir -p "$root/.signalk-updater"
hw="$root/.signalk-updater/hardware.json"
cat >"$hw" <<JSON
{
  "detectedAt": "2026-01-01T00:00:00Z",
  "serial": [
    {"byId":"$serial_byid","vendor":"FTDI","product":"UART","enabled":true}
  ],
  "can": [],
  "bluetooth": { "dbusAvailable": false, "enabled": false },
  "audio": { "present": false, "enabled": false },
  "gpio": { "platform": "none", "enabled": false }
}
JSON

# The staged payload: the real renderer + real server template, copied in.
payload="$root/.signalk-doctor/installer-payload"
mkdir -p "$payload"
cp "$RENDERER" "$payload/render-server-quadlet.sh"
cp "$SERVER_TMPL" "$payload/signalk-server.container.template"

quadlet_dir="$root/.config/containers/systemd"
mkdir -p "$quadlet_dir"
live="$quadlet_dir/signalk-server.container"

# Produce the canonical render the way cmd_render_server does (renderer + the
# __SK_HTTP_PORT__ sed, port 80 to match our sk_http_port stub) so we can seed
# the "already current" case with a byte-identical live file.
canonical() {
    bash "$payload/render-server-quadlet.sh" "$hw" \
        "$payload/signalk-server.container.template" \
        | sed -e 's/__SK_HTTP_PORT__/80/g'
}

# Harness that sources the funcs with all side-effecting calls stubbed and the
# paths pointed at $root. Records restart/daemon-reload into marker files so the
# assertions can see whether they fired. $1 = extra args to cmd_render_server.
# AUDIO_DIR unset so the audio Volume line is deterministic across hosts.
run_render() {
    HOME="$root" \
    DOCTOR_DATA="$root/.signalk-doctor" \
    QUADLET_DIR="$quadlet_dir" \
    MARK="$root/marks" \
    bash -c '
        set -euo pipefail
        mkdir -p "$MARK"
        # systemctl is an external command (not defined in the template), so a
        # stub set any time before the call wins.
        systemctl() { echo "$*" >>"$MARK/systemctl.log"; return 0; }
        # shellcheck source=/dev/null
        . "'"$funcs"'"
        # sk_http_port and _signalk_restart_server ARE defined in the template,
        # so their stubs must come AFTER the source or the real definitions
        # would clobber them. Override the port (deterministic 80) and turn the
        # restart into an observable marker instead of a live systemctl/curl.
        sk_http_port() { printf 80; }
        _signalk_restart_server() { echo "restart" >>"$MARK/restart.log"; return 0; }
        cmd_render_server "$@"
    ' _ "$@"
}

# Prime the resolv-watch units once: cmd_render_server ensures them on every
# run (that's the feature — they ride along with `signalk update`), so the
# idempotency case below exercises the ALREADY-INSTALLED path, which is
# read-only (a single `is-enabled` probe).
HOME="$root" bash -c '
    set -euo pipefail
    systemctl() { return 0; }
    # shellcheck source=/dev/null
    . "'"$funcs"'"
    _signalk_ensure_resolv_watch >/dev/null
'

# ── 1. Idempotent: live already matches the render ─────────────────────────
canonical >"$live"
rm -rf "$root/marks"
if out=$(run_render 2>&1); then
    # The resolv-watch ensure must have run — but only its read-only
    # `is-enabled` probe (units were primed above). Requiring the log to be
    # exactly that one line catches both regressions at once: cmd_render_server
    # dropping the ensure entirely (empty log) and the ensure doing real work
    # on the already-installed path (extra lines).
    if grep -q 'already matches' <<<"$out" \
        && [[ ! -f "$root/marks/restart.log" ]] \
        && [[ "$(cat "$root/marks/systemctl.log" 2>/dev/null)" == "--user is-enabled signalk-resolv-watch.path" ]]; then
        ok "no-op when live Quadlet already matches the template (no restart, no daemon-reload)"
    else
        miss "idempotent path did work it shouldn't have"
        printf '         %s\n' "$out"
        # Plain `if`, not `[[ … ]] && echo`: a trailing && that evaluates false
        # would become the else-block's (and the whole if's) exit status and
        # abort the harness under set -e before the remaining cases run.
        if [[ -f "$root/marks/systemctl.log" ]]; then echo "         systemctl WAS called"; fi
        if [[ -f "$root/marks/restart.log" ]]; then echo "         restart WAS called"; fi
    fi
else
    miss "render-server errored on the already-current case"
    printf '         %s\n' "$out"
fi

# ── 2. Template delta: snapshot + rewrite + daemon-reload + restart ────────
# Seed a live Quadlet that differs from the render (drop a line) so cmd_render_
# server must apply the delta.
canonical | grep -v '^Timezone=' >"$live"
before_hash=$(sha256sum "$live" | cut -d' ' -f1)
rm -rf "$root/marks"
if out=$(run_render 2>&1); then
    after_hash=$(sha256sum "$live" | cut -d' ' -f1)
    snap_count=$(find "$root/.signalk-doctor/snapshots" -name '*-signalk-server.container' 2>/dev/null | wc -l) || true
    reloaded=0; grep -q 'daemon-reload' "$root/marks/systemctl.log" 2>/dev/null && reloaded=1
    restarted=0; [[ -f "$root/marks/restart.log" ]] && restarted=1
    live_matches=0
    [[ "$(cat "$live")" == "$(canonical)" ]] && live_matches=1
    if [[ "$before_hash" != "$after_hash" && "$snap_count" -eq 1 \
          && "$reloaded" -eq 1 && "$restarted" -eq 1 && "$live_matches" -eq 1 ]]; then
        ok "template delta: snapshot taken, live rewritten to match template, daemon-reload + restart fired"
    else
        miss "delta path incomplete (rewritten=$([[ "$before_hash" != "$after_hash" ]] && echo 1 || echo 0) snapshots=$snap_count reload=$reloaded restart=$restarted matches=$live_matches)"
        printf '         %s\n' "$out"
    fi
else
    miss "render-server errored on the delta case"
    printf '         %s\n' "$out"
fi

# ── 3. --no-restart rewrites + reloads but does NOT restart ────────────────
canonical | grep -v '^Timezone=' >"$live"
rm -rf "$root/marks"
if out=$(run_render --no-restart 2>&1); then
    reloaded=0; grep -q 'daemon-reload' "$root/marks/systemctl.log" 2>/dev/null && reloaded=1
    restarted=0; [[ -f "$root/marks/restart.log" ]] && restarted=1
    live_matches=0
    [[ "$(cat "$live")" == "$(canonical)" ]] && live_matches=1
    if [[ "$reloaded" -eq 1 && "$restarted" -eq 0 && "$live_matches" -eq 1 ]]; then
        ok "--no-restart: Quadlet rewritten + daemon-reloaded, server NOT restarted"
    else
        miss "--no-restart path wrong (reload=$reloaded restart=$restarted matches=$live_matches)"
        printf '         %s\n' "$out"
    fi
else
    miss "render-server errored on the --no-restart case"
    printf '         %s\n' "$out"
fi

# ── 4. Missing staged payload → clear error ────────────────────────────────
missing_payload=$(mktemp -d)
if out=$(HOME="$root" DOCTOR_DATA="$missing_payload" QUADLET_DIR="$quadlet_dir" MARK="$root/marks2" \
    bash -c '
        set -euo pipefail
        systemctl() { return 0; }
        # shellcheck source=/dev/null
        . "'"$funcs"'"
        sk_http_port() { printf 80; }
        _signalk_restart_server() { return 0; }
        cmd_render_server
    ' 2>&1); then
    miss "missing payload did not fail (should exit non-zero)"
    printf '         %s\n' "$out"
else
    if grep -q 'signalk update' <<<"$out"; then
        ok "missing staged payload fails with a 'run signalk update' hint"
    else
        miss "missing-payload error lacks the 'signalk update' hint"
        printf '         %s\n' "$out"
    fi
fi
rm -rf "$missing_payload"

# ── 5. USER ADDITIONS block + live Image= tag preserved across a re-render ──
# Seed a live Quadlet that (a) carries an operator hand-edit inside the USER
# ADDITIONS block, (b) has a switched Image= tag (the updater's version-of-
# record), and (c) is missing Timezone= (a real template delta forcing a
# rewrite). After render, the custom line AND the switched image must survive,
# AND the template delta (Timezone=local) must be applied — the whole point of
# #217 without clobbering the operator's hand-edits or version choice. Requires
# the template to carry the USER ADDITIONS markers and an Image= line.
if grep -qF '# === BEGIN USER ADDITIONS ===' "$payload/signalk-server.container.template" \
    && grep -q '^Image=' "$payload/signalk-server.container.template"; then
    custom='Environment=MY_CUSTOM_VAR=42'
    switched_image='Image=ghcr.io/dirkwa/signalk-server:v2.99.0-operator-choice'
    # Build: canonical render, drop Timezone (delta), swap in the operator's
    # image tag, and inject the custom line just after the BEGIN marker.
    canonical | grep -v '^Timezone=' | awk -v add="$custom" -v img="$switched_image" '
        /^Image=/ { print img; next }
        /^# === BEGIN USER ADDITIONS ===/ { print; print add; next }
        { print }
    ' >"$live"
    rm -rf "$root/marks"
    if out=$(run_render 2>&1); then
        has_custom=0; grep -qF "$custom" "$live" && has_custom=1
        has_tz=0; grep -q '^Timezone=local' "$live" && has_tz=1
        has_image=0; grep -qF "$switched_image" "$live" && has_image=1
        # No reversion to the template's default tag, and the custom line and
        # Image line must each appear exactly once (splice must not duplicate).
        no_default_image=0; grep -q '^Image=ghcr.io/dirkwa/signalk-server:dirkwa$' "$live" || no_default_image=1
        custom_count=$(grep -cF "$custom" "$live" || true)
        image_count=$(grep -c '^Image=' "$live" || true)
        if [[ "$has_custom" -eq 1 && "$has_tz" -eq 1 && "$has_image" -eq 1 \
              && "$no_default_image" -eq 1 && "$custom_count" -eq 1 && "$image_count" -eq 1 ]]; then
            ok "USER ADDITIONS + live Image= tag preserved AND template delta (Timezone=local) applied"
        else
            miss "preservation wrong (custom=$has_custom count=$custom_count timezone=$has_tz image=$has_image no-default=$no_default_image image_count=$image_count)"
            printf '         %s\n' "$out"
        fi
    else
        miss "render-server errored on the preservation case"
        printf '         %s\n' "$out"
    fi
else
    echo "  [SKIP] template lacks USER ADDITIONS markers or Image= — preservation N/A"
fi

if (( fail )); then
    echo
    echo "[ERR] render-server wiring is broken — see entries above." >&2
    exit 1
fi
echo "[OK] render-server idempotence + apply + --no-restart + user-additions + missing-payload paths are correct."
