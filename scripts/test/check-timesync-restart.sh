#!/usr/bin/env bash
# Verifies the mid-passage timezone-restart wiring in signalk-timesync.tmpl.
#
# The restart itself (timedatectl / runuser / podman / systemctl) needs root
# and a live stack, so it can't run in CI. Instead this test renders the
# template and checks the two things that actually matter and CAN be checked
# host-independently:
#   1. Structure — the signalk-server recreate is GATED behind the opt-in
#      (SIGNALK_TIMESYNC_TZ_RESTART=on OR `run --confirm-restart`), uses the
#      runuser/systemctl --user pattern, and the opt-out branch still logs the
#      next-restart note.
#   2. Arg parsing — `run --confirm-restart` is accepted and unknown run
#      options are rejected. This runs before any privileged call, so it is
#      exercised for real.
#
# Run from the repo root.

set -euo pipefail

TMPL=${TMPL:-installer/linux/signalk-timesync.tmpl}
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render="$tmp/agent.sh"
sed -e 's/__SK_USER__/tester/g' -e 's/__SK_HTTP_PORT__/4000/g' "$TMPL" >"$render"

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# ── 1. Structural checks on the rendered agent ──────────────────────────────

# The recreate must be guarded by the opt-in condition. Assert both the flag
# and the --confirm-restart var appear in the same guard, and restart_server
# is called from inside it (not unconditionally).
guard=$(grep -n 'SIGNALK_TIMESYNC_TZ_RESTART' "$render" || true)
if grep -Eq 'SIGNALK_TIMESYNC_TZ_RESTART:-off.*==.*"on".*\|\|.*confirm_restart.*==.*true' "$render"; then
    ok "recreate is gated behind flag=on OR --confirm-restart"
else
    miss "recreate guard (flag=on || --confirm-restart) not found as expected"
    [[ -n "$guard" ]] && printf '         %s\n' "$guard"
fi

# restart_server must go through the updater REST API first (the sanctioned
# lifecycle path) and fall back to the drop-to-user systemctl --user restart
# only when the updater is unreachable. Assert both are present. The grep
# patterns are literal ($SK_USER / $UPDATER_URL are matched as text).
# shellcheck disable=SC2016
if grep -q '${UPDATER_URL}/api/signalk/restart' "$render"; then
    ok "restart_server prefers the updater REST /api/signalk/restart"
else
    miss "restart_server does not call the updater REST /api/signalk/restart"
fi
# shellcheck disable=SC2016
if grep -q 'runuser -u "$SK_USER"' "$render" \
   && grep -q 'systemctl --user restart signalk-server.service' "$render"; then
    ok "restart_server keeps the systemctl --user fallback when the updater is down"
else
    miss "restart_server is missing the systemctl --user fallback"
fi

# restart_server must be invoked from INSIDE the opt-in conditional, not just
# somewhere after it. Track the guard's own then-block: open on the guard
# line, close on the matching else/fi, and only count a restart_server call
# that isn't the guard line itself.
if awk '
    /SIGNALK_TIMESYNC_TZ_RESTART:-off/       { inguard=1; next }
    inguard && /^[[:space:]]*(else|fi)\b/    { inguard=0 }
    inguard && /restart_server/              { seen=1 }
    END { exit(seen ? 0 : 1) }
' "$render"; then
    ok "restart_server is called inside the opt-in guard's then-block"
else
    miss "restart_server is not nested inside the opt-in guard"
fi

if grep -q 'picks the new zone up on its next restart' "$render"; then
    ok "opt-out branch still logs the next-restart note"
else
    miss "next-restart note is missing"
fi

# ── 2. Behavioral arg-parsing checks (run before any privileged call) ───────
# Source the functions (strip the dispatcher) and exercise the arg loop with
# id() stubbed non-root so cmd_run exits right after parsing, before any
# timedatectl/podman call.
funcs="$tmp/funcs.sh"
sed '/^case "${1:-status}" in/,$d' "$render" >"$funcs"

# Unknown option → cmd_run must exit non-zero at the arg loop (exit 2), which
# happens before the root check.
if bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    . "'"$funcs"'"
    cmd_run --bogus
' >/dev/null 2>&1; then
    miss "unknown run option was not rejected"
else
    ok "unknown run option is rejected"
fi

# Known option --confirm-restart must pass the arg loop. id -u is forced
# non-root so cmd_run stops deterministically at the root check with exit 1
# (the arg loop's reject is exit 2). Any other rc is a real failure — the
# stub removes environment nondeterminism, so we assert exactly 1.
set +e
bash -c '
    id() { case "$1" in -u) echo 1000 ;; *) command id "$@" ;; esac; }
    # shellcheck source=/dev/null
    . "'"$funcs"'"
    cmd_run --confirm-restart
' >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
    ok "--confirm-restart parses (reaches the root check, exit 1)"
elif [[ "$rc" -eq 2 ]]; then
    miss "--confirm-restart was treated as an unknown option (exit 2)"
else
    miss "--confirm-restart produced unexpected exit $rc (want 1)"
fi

if (( fail )); then
    echo
    echo "[ERR] signalk-timesync restart wiring is broken — see entries above." >&2
    exit 1
fi
echo "[OK] signalk-timesync restart gating is wired correctly."
