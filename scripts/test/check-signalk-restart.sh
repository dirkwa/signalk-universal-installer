#!/usr/bin/env bash
# Verifies `signalk restart` (cmd_restart in signalk.tmpl) — issue #222.
#
# The restart itself needs a live stack, so what this checks is the decision
# logic around it, which is where the subtle mistakes live:
#   1. Structure — the verb is dispatched and documented, and it does NOT go
#      through _signalk_lifecycle (that helper is for the DURABLE pause/resume
#      pair; a restart must not touch `[Install] WantedBy=`).
#   2. Behaviour — every branch of cmd_restart, driven for real with systemctl
#      and curl stubbed out: refuses when the server is down, uses the updater
#      REST route when it answers, falls back to systemctl on 404/000, and
#      fails hard on any other HTTP status.
#
# Run from the repo root.

set -euo pipefail

TMPL="${TMPL:-installer/linux/signalk.tmpl}"
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# ── 1. Structure ────────────────────────────────────────────────────────────

if grep -Eq '^\s*restart\)\s+cmd_restart\s*;;' "$TMPL"; then
    ok "dispatcher routes 'restart' to cmd_restart"
else
    miss "dispatcher entry 'restart) cmd_restart ;;' not found"
fi

if grep -q '^#   signalk restart' "$TMPL"; then
    ok "help text documents 'signalk restart'"
else
    miss "no '#   signalk restart' line in the header help block"
fi

# A restart must not be routed through the durable pause/resume helper: that
# rewrites the Quadlet's WantedBy=, which would make a restart change
# boot-start as a side effect.
body=$(sed -n '/^cmd_restart() {/,/^}/p' "$TMPL")
if [[ -z "$body" ]]; then
    miss "cmd_restart not found (renamed?)"
    echo "[FAIL] check-signalk-restart"
    exit 1
fi
if grep -q '^}' <<<"$body"; then
    ok "cmd_restart extraction found a closing brace"
else
    miss "cmd_restart extraction did not terminate — over-captured"
fi
if grep -q '_signalk_lifecycle' <<<"$body"; then
    miss "cmd_restart calls _signalk_lifecycle (durable pause/resume) — it must not"
else
    ok "cmd_restart does not use the durable pause/resume helper"
fi
# Match the CODE, not the docblock: a comment mentioning the route would
# otherwise satisfy this while the actual POST went somewhere else (e.g. the
# durable /pause), which is exactly the regression worth catching.
# shellcheck disable=SC2016  # matching the literal '${UPDATER_URL}' text, not expanding it
if grep -v '^\s*#' <<<"$body" | grep -q '\${UPDATER_URL}/api/signalk/restart'; then
    ok "cmd_restart POSTs to \${UPDATER_URL}/api/signalk/restart"
else
    miss "cmd_restart does not POST to \${UPDATER_URL}/api/signalk/restart"
fi
# Nothing in cmd_restart may touch the durable pause/resume routes.
if grep -v '^\s*#' <<<"$body" | grep -Eq 'api/signalk/(pause|resume)'; then
    miss "cmd_restart references the durable pause/resume route — it must not"
else
    ok "cmd_restart never touches /api/signalk/{pause,resume}"
fi

# ── 2. Behaviour: drive every branch with systemctl/curl stubbed ────────────

# $1 label | $2 is-active (yes/no) | $3 simulated HTTP | $4 expected rc
#   $5 regex the output must match | $6 expect a systemctl restart? (yes/no)
#   $7 curl exit status (0 = answered; non-zero = connection failure)
#   $8 systemctl restart exit status (default 0)
#
# $6 is asserted in BOTH directions against a log of the stub's calls. Checking
# only the message would pass a fallback that announces itself and then
# restarts nothing, and would equally miss a REST-success path that restarted
# the unit a second time behind the updater's back.
#
# $7 models curl faithfully, which matters more than it looks: on a connection
# failure real curl PRINTS "000" via -w *and* exits non-zero. A stub that only
# printed could not distinguish `$(curl … || echo 000)` — which appends, giving
# "000000" — from the correct `$(curl …) || http=000`. That is a real bug this
# suite missed until the stub grew an exit status.
run_case() {
    local label="$1" active="$2" http="$3" want_rc="$4" want_re="$5" want_fallback="$6"
    local curl_rc="${7:-0}" sysd_rc="${8:-0}"
    local out rc=0 calls="$tmp/systemctl.log"
    : >"$calls"
    # 2>&1 INSIDE the substitution: cmd_restart writes its errors to stderr,
    # and redirecting outside the $( ) would let them escape to the console
    # unmatched (making a failing assertion look like a passing one).
    out=$(
        {
            set -uo pipefail
            export HOME="$tmp/home" UPDATER_URL="http://stub" CALLS="$calls"
            mkdir -p "$HOME/.signalk-updater"
            echo tok >"$HOME/.signalk-updater/token"
            SIM_ACTIVE="$active" SIM_HTTP="$http"
            SIM_CURL_RC="$curl_rc" SIM_SYSD_RC="$sysd_rc"
            # is-active decides the guard; any other systemctl call is the
            # fallback restart — record it so the caller can assert on it.
            # SC2317: these stubs are called from the eval'd cmd_restart below,
            # which shellcheck cannot see, so it reads them as unreachable.
            # shellcheck disable=SC2317
            systemctl() {
                if [[ "${2:-}" == "is-active" ]]; then
                    [[ "$SIM_ACTIVE" == yes ]]
                    return $?
                fi
                printf '%s\n' "$*" >>"$CALLS"
                return "$SIM_SYSD_RC"
            }
            # Print the status like -w does, THEN exit with the simulated
            # status — both halves, exactly as real curl behaves.
            # shellcheck disable=SC2317  # called from the eval'd cmd_restart
            curl() { printf '%s' "$SIM_HTTP"; return "$SIM_CURL_RC"; }
            eval "$body"
            cmd_restart
        } 2>&1
    ) || rc=$?
    if [[ "$rc" != "$want_rc" ]]; then
        miss "$label: expected rc=$want_rc, got rc=$rc"
        return
    fi
    if ! grep -Eq "$want_re" <<<"$out"; then
        miss "$label: output did not match /$want_re/ (got: $(tr '\n' '|' <<<"$out"))"
        return
    fi
    local restarted=no
    grep -Eq '(^| )restart( |$)' "$calls" && restarted=yes
    if [[ "$restarted" != "$want_fallback" ]]; then
        if [[ "$want_fallback" == yes ]]; then
            miss "$label: expected a 'systemctl restart' fallback, none was called"
        else
            miss "$label: unexpected 'systemctl restart' ($(tr '\n' '|' <"$calls"))"
        fi
        return
    fi
    ok "$label"
}

#                                                          rc  match  fallback  curl  sysd
run_case "server down -> refuses and points at 'signalk start'" \
    no 000 1 'Start it with: signalk start' no
run_case "updater 200 -> restarted via the REST route, no systemctl" \
    yes 200 0 '\[OK\] SignalK restarted' no
run_case "updater 404 (too old) -> systemctl fallback actually restarts" \
    yes 404 0 'restarting the unit directly' yes
# Unreachable for real: curl prints "000" AND exits non-zero (7 = couldn't
# connect). This is the case that must not end up as "HTTP 000000".
run_case "updater unreachable (curl fails, prints 000) -> fallback restarts" \
    yes 000 0 'restarting the unit directly' yes 7
run_case "fallback restart itself fails -> hard failure" \
    yes 000 1 'systemctl --user restart signalk-server.service failed' yes 7 1
run_case "updater 500 -> hard failure, no fallback restart" \
    yes 500 1 'Updater returned HTTP 500' no

if [[ "$fail" -eq 0 ]]; then
    echo "[PASS] check-signalk-restart"
else
    echo "[FAIL] check-signalk-restart"
fi
exit "$fail"
