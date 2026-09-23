#!/usr/bin/env bash
# Verifies the crash-loop detection in cmd_health — SignalK/signalk-server#3056.
#
# signalk-server runs StartLimitIntervalSec=0 / Restart=always (see
# quadlets/signalk-server.container.template), so it never latches into
# `failed`. The failure-mode branches in cmd_health all key off server_down,
# which a crash-looping server does not reliably set: with RestartSec=10 a
# server dying on a 2s plugin timer is up most of the time, so the HTTP probe
# lands in an up window and reports [OK]. That is the reported symptom — a
# server looping all day while `signalk health` says everything is fine.
#
# The regression this guards is therefore specifically: HTTP probe OK, unit
# restarting. A test that only drove the server-down path would pass against
# the very bug this exists to catch.
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

body=$(sed -n '/^cmd_health() {/,/^}/p' "$TMPL")
if [[ -z "$body" ]] || ! grep -q '^}' <<<"$body"; then
    miss "cmd_health not extracted cleanly (renamed?)"
    echo "[FAIL] check-health-restart-loop"
    exit 1
fi
ok "cmd_health extracted"

# Drive cmd_health with every external it touches stubbed.
#   $1 label | $2 NRestarts now | $3 pre-seeded stamp ("" = none)
#   $4 grep -E pattern the output must match
#   $5 optional grep -E pattern the output must NOT match
run_case() {
    local label="$1" n="$2" seed="$3" want="$4" forbid="${5:-}"
    local out rc=0 home="$tmp/home"
    rm -rf "$home"; mkdir -p "$home/.cache"
    [[ -n "$seed" ]] && printf '%s\n' "$seed" >"$home/.cache/signalk-health-restarts"
    out=$(
        {
            set -uo pipefail
            # Scoping these to the subshell is the point: each case gets a
            # clean HOME so the stamp file from a previous case cannot leak in.
            # shellcheck disable=SC2030,SC2031
            export HOME="$home" QUADLET_DIR="$home/quadlets"
            # shellcheck disable=SC2030,SC2031
            export SIGNALK_URL="http://stub" UPDATER_URL="http://stub" DOCTOR_URL="http://stub"
            # No XDG_RUNTIME_DIR: exercise the $HOME/.cache fallback.
            unset XDG_RUNTIME_DIR
            mkdir -p "$QUADLET_DIR"
            export SIM_N="$n"
            # Every probe healthy — the [OK]-while-looping case.
            # shellcheck disable=SC2317  # invoked from the eval'd function
            health_probe() { printf 'ok 0.1\n'; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            pub_url() { printf '%s' "$1"; }
            # Answer NRestarts; everything else (Result, ExecMainStatus,
            # list-units) yields empty, as `show` does on a missing unit.
            # shellcheck disable=SC2317  # invoked from the eval'd function
            systemctl() {
                case "$*" in
                    *NRestarts*) printf '%s\n' "$SIM_N" ;;
                    *) : ;;
                esac
            }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            podman() { : ; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            docker() { : ; }
            eval "$body"
            cmd_health
        } 2>&1
    ) || rc=$?
    if (( rc != 0 )); then
        miss "$label: cmd_health exited rc=$rc (out: $(tr '\n' '|' <<<"$out"))"
        return
    fi
    if ! grep -qE "$want" <<<"$out"; then
        miss "$label: output did not match /$want/"
        printf '         %s\n' "$(tr '\n' '|' <<<"$out")" >&2
        return
    fi
    # A presence-only assertion would pass even if the output ALSO cried
    # [LOOP], which is the false positive the no-growth cases exist to catch.
    if [[ -n "$forbid" ]] && grep -qE "$forbid" <<<"$out"; then
        miss "$label: output unexpectedly matched /$forbid/"
        printf '         %s\n' "$(tr '\n' '|' <<<"$out")" >&2
        return
    fi
    ok "$label"
}

# The regression case: server answers HTTP fine, but the count has climbed
# since the last run. Must report [LOOP] despite the probe reading [OK].
run_case "climbing count while HTTP is OK -> [LOOP]" \
    47 "42 $(( $(date +%s) - 30 ))" '\[LOOP\] signalk-server has restarted 5 times'

# The probe really is reporting OK in that case — i.e. the detection does not
# depend on the server being down. Asserted explicitly so a future change that
# makes [LOOP] conditional on server_down fails here.
run_case "loop is reported even though the probe says [OK]" \
    47 "42 $(( $(date +%s) - 30 ))" '\[OK\] +signalk-server'

# No prior stamp: nothing to compare against yet, so report the total and ask
# for a second look rather than crying loop on a long-uptime host.
run_case "first run (no stamp) -> total only, no [LOOP]" \
    9 "" 'restart count: 9' '\[LOOP\]'

# Steady count: restarts happened once, long ago. Not a loop.
run_case "unchanged count -> no [LOOP]" \
    9 "9 $(( $(date +%s) - 300 ))" 'restart count: 9' '\[LOOP\]'

# A fresh unit that has never restarted must stay silent entirely. Asserted as
# a true absence: run_case only matches presence, so this is checked inline.
run_zero_case() {
    local out rc=0 home="$tmp/home"
    rm -rf "$home"; mkdir -p "$home/.cache"
    out=$(
        {
            set -uo pipefail
            # Scoping these to the subshell is the point: each case gets a
            # clean HOME so the stamp file from a previous case cannot leak in.
            # shellcheck disable=SC2030,SC2031
            export HOME="$home" QUADLET_DIR="$home/quadlets"
            # shellcheck disable=SC2030,SC2031
            export SIGNALK_URL="http://stub" UPDATER_URL="http://stub" DOCTOR_URL="http://stub"
            unset XDG_RUNTIME_DIR
            mkdir -p "$QUADLET_DIR"
            # shellcheck disable=SC2317  # invoked from the eval'd function
            health_probe() { printf 'ok 0.1\n'; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            pub_url() { printf '%s' "$1"; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            systemctl() { case "$*" in *NRestarts*) printf '0\n' ;; *) : ;; esac; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            podman() { : ; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            docker() { : ; }
            eval "$body"
            cmd_health
        } 2>&1
    ) || rc=$?
    if (( rc != 0 )); then
        miss "zero restarts: cmd_health exited rc=$rc"
    elif grep -qiE 'restart count|\[LOOP\]' <<<"$out"; then
        miss "zero restarts: expected no restart output, got: $(tr '\n' '|' <<<"$out")"
    else
        ok "zero restarts -> no restart output at all"
    fi
}
run_zero_case

# Corrupt stamp must not crash or produce a bogus delta.
run_case "unparseable stamp -> falls back to total, no crash" \
    9 "garbage" 'restart count: 9' '\[LOOP\]'

# A single restart is ordinary operation: the admin UI's Restart button is a
# clean exit(0) that Restart=always brings back. Reporting that as a crash
# loop would make [LOOP] untrustworthy, so it must report the change plainly.
run_case "one restart (Restart button) -> reported, NOT a loop" \
    10 "9 $(( $(date +%s) - 30 ))" 'restarted 1 time\(s\) in the last' '\[LOOP\]'

# Two restarts spread over an hour average well past the rate threshold.
run_case "two restarts an hour apart -> not a loop" \
    11 "9 $(( $(date +%s) - 3600 ))" 'restarted 2 time\(s\) in the last' '\[LOOP\]'

# `systemctl stop` resets NRestarts to 0 (verified on systemd 257), so the
# counter can go DOWN between runs — after a `signalk stop; signalk start`, or
# any restart that goes through a full stop. A decrease must not be read as a
# delta, and the stamp is re-seeded from the current value so the next run
# compares against a real baseline.
run_case "counter reset (stop/start) -> no [LOOP], reports current total" \
    3 "20 $(( $(date +%s) - 30 ))" 'restart count: 3' '\[LOOP\]'

# A backward clock step (a boat with no RTC gets its time from NTP after boot)
# makes now-prev_t negative. The clamp keeps the average positive so a genuine
# loop is still reported rather than divided by a negative interval.
run_case "backward clock step with a real loop -> still [LOOP]" \
    8 "5 $(( $(date +%s) + 3600 ))" '\[LOOP\]'

# The stamp is written so the NEXT run has a baseline. Driven by its own case
# rather than inspecting whatever the last run_case happened to leave, so
# adding or reordering cases above cannot silently invalidate this.
run_case "stamp is written for the next run" 77 "" 'restart count: 77' '\[LOOP\]'
stampfile="$tmp/home/.cache/signalk-health-restarts"
if [[ -s "$stampfile" ]] && [[ "$(cut -d' ' -f1 <"$stampfile")" == "77" ]]; then
    ok "stamp file records the current count for the next run"
else
    miss "stamp file not written with the current count (got: $(cat "$stampfile" 2>/dev/null))"
fi

if (( fail )); then
    echo "[FAIL] check-health-restart-loop"
    exit 1
fi
echo "[PASS] check-health-restart-loop"
