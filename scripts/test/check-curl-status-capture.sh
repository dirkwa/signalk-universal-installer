#!/usr/bin/env bash
# Verifies the HTTP-status capture in signalk.tmpl — issue #229.
#
# On a connection failure curl PRINTS its own "000" (via -w '%{http_code}')
# *and* exits non-zero. So `http=$(curl … || echo "000")` appends rather than
# replaces, yielding "000000" — which matches no `000)` case arm, silently
# skipping the unreachable-service branch in exactly the situation that branch
# exists for. The correct shape assigns outside the substitution:
#
#     http=$(curl …) || http="000"
#
# Two checks, because neither alone is sufficient:
#   1. Static — no status capture anywhere in the template uses the appending
#      form. Cheap, and covers call sites this test does not execute.
#   2. Behavioural — _signalk_lifecycle() is driven for real with a curl stub
#      that behaves like the real thing (prints "000", exits non-zero), and
#      must reach its systemctl fallback (rc 3) rather than the catch-all.
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

# ── 1. Static: the appending form must not appear in any status capture ─────
#
# Strip comments first — the fixed call sites document the trap by quoting the
# broken form, and matching those would make this assertion unfalsifiable.
offenders=$(grep -vE '^\s*#' "$TMPL" | grep -nE '\|\| *echo *"?000"?\)' || true)
if [[ -z "$offenders" ]]; then
    ok "no status capture uses the appending '|| echo 000' form"
else
    miss "appending '|| echo 000' still present in code:"
    printf '         %s\n' "$offenders" >&2
fi

# EVERY status capture that lands in a variable must pair with an outside
# fallback assignment. A floor of "at least one" would let a newly added
# unguarded capture through, so require the counts to match exactly.
#
# Only captures whose -w format is a BARE '%{http_code}' assigned to a
# variable count. Two shapes are deliberately excluded because neither can
# double up:
#   - inline `[[ "$(curl … -w '%{http_code}' …)" == "404" ]]` (the devpod
#     release-branch probe): no variable to reassign, and a doubled "000"
#     just fails the ==, which is the safe direction there (proceed).
#   - `-w '\n%{http_code}'` captured whole (cmd_resetadmin's loginStatus
#     probe): the status is extracted with ${resp##*$'\n'}, i.e. everything
#     after the LAST newline, which is "000" even when curl also failed.
captures=$(grep -cE "^\s*[A-Za-z_][A-Za-z0-9_]*=\\\$\(curl .*-w '%\{http_code\}'" "$TMPL" || true)
assigns=$(grep -cE '\) *\|\| *[A-Za-z_][A-Za-z0-9_]*="000"' "$TMPL" || true)
if [[ "$captures" -ge 1 && "$assigns" -eq "$captures" ]]; then
    ok "all ${captures} variable status capture(s) have an outside fallback assignment"
else
    miss "every variable curl capture needs a '\$(…) || var=\"000\"' fallback (captures=${captures}, assigns=${assigns})"
fi

# ── 2. Behavioural: _signalk_lifecycle must reach its systemctl fallback ────

body=$(sed -n '/^_signalk_lifecycle() {/,/^}/p' "$TMPL")
if [[ -z "$body" ]] || ! grep -q '^}' <<<"$body"; then
    miss "_signalk_lifecycle not extracted cleanly (renamed?)"
    echo "[FAIL] check-curl-status-capture"
    exit 1
fi
ok "_signalk_lifecycle extracted"

# $1 label | $2 simulated HTTP body | $3 curl exit status | $4 expected rc
#   $5 expect a systemctl fallback call? (yes/no)
run_case() {
    local label="$1" http="$2" curl_rc="$3" want_rc="$4" want_fb="$5"
    local out rc=0 calls="$tmp/calls.log"
    : >"$calls"
    out=$(
        {
            set -uo pipefail
            export HOME="$tmp/home" UPDATER_URL="http://stub" CALLS="$calls"
            mkdir -p "$HOME/.signalk-updater"
            echo tok >"$HOME/.signalk-updater/token"
            SIM_HTTP="$http" SIM_CURL_RC="$curl_rc"
            # Print the status like -w does, THEN exit non-zero — both halves,
            # exactly as real curl behaves on a connection failure. A stub that
            # only printed could not tell the broken form from the correct one,
            # which is why this bug shipped.
            # shellcheck disable=SC2317  # invoked from the eval'd function
            curl() { printf '%s' "$SIM_HTTP"; return "$SIM_CURL_RC"; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            systemctl() { printf '%s\n' "$*" >>"$CALLS"; return 0; }
            eval "$body"
            _signalk_lifecycle pause stop
        } 2>&1
    ) || rc=$?
    if [[ "$rc" != "$want_rc" ]]; then
        miss "$label: expected rc=$want_rc, got rc=$rc (out: $(tr '\n' '|' <<<"$out"))"
        return
    fi
    local called=no
    grep -q . "$calls" && called=yes
    if [[ "$called" != "$want_fb" ]]; then
        miss "$label: systemctl fallback called=$called, expected $want_fb"
        return
    fi
    ok "$label"
}

# The regression case: curl fails AND prints 000. rc 3 is the documented
# "acted via systemctl, not durable" contract; the bug produced rc 1 instead.
run_case "unreachable updater (curl prints 000, exits 7) -> systemctl fallback, rc 3" \
    000 7 3 yes
# Reachable paths must be unaffected by the fix.
run_case "updater 200 -> success, no systemctl" \
    200 0 0 no
run_case "updater 404 (too old) -> refuses with rc 2, no systemctl" \
    404 0 2 no
run_case "updater 500 -> hard failure rc 1, no systemctl" \
    500 0 1 no

if [[ "$fail" -eq 0 ]]; then
    echo "[PASS] check-curl-status-capture"
else
    echo "[FAIL] check-curl-status-capture"
fi
exit "$fail"
