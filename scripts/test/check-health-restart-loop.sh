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

# cmd_health runs its log scan as `"${exc_tmo[@]}" podman logs ...`, and with
# coreutils timeout present exc_tmo is `timeout -k 5 10` — which EXECS the real
# podman, bypassing each case's shell-function stub and reaching host Podman
# (host-dependent results, and up to a 10s wait per case). Stubbing timeout
# here, once, keeps every case hermetic: strip timeout's own flags and the
# duration, then run the rest through the shell so the stubs apply.
# shellcheck disable=SC2317  # invoked from the eval'd cmd_health
timeout_stub() {
    while [[ "${1:-}" == -* ]]; do
        [[ "$1" == "-k" ]] && shift
        shift
    done
    shift || true   # the duration
    "$@"
}

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
            timeout() { timeout_stub "$@"; }
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
            timeout() { timeout_stub "$@"; }
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

# A full stop resets NRestarts to 0. The zero run must stay silent but still
# re-seed the stamp: leaving a stale high baseline makes the NEXT run compare
# a fresh low count against it, fail the growth check, and miss a loop for a
# whole window.
zero_reseeds_stamp() {
    local home="$tmp/home" out rc=0 now_n
    rm -rf "$home"; mkdir -p "$home/.cache"
    printf '20 %s\n' "$(( $(date +%s) - 30 ))" >"$home/.cache/signalk-health-restarts"
    out=$(
        {
            set -uo pipefail
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
    now_n=$(cut -d' ' -f1 <"$home/.cache/signalk-health-restarts" 2>/dev/null || echo MISSING)
    if (( rc != 0 )); then
        miss "zero re-seeds stamp: cmd_health exited rc=$rc"
    elif grep -qiE 'restart count|\[LOOP\]' <<<"$out"; then
        miss "zero re-seeds stamp: expected silence, got: $(tr '\n' '|' <<<"$out")"
    elif [[ "$now_n" != "0" ]]; then
        miss "zero re-seeds stamp: stamp still [$now_n], expected 0 (stale baseline hides the next loop)"
    elif ! grep -q "Container snapshot" <<<"$out"; then
        miss "zero re-seeds stamp: cmd_health returned early — later sections missing"
    else
        ok "counter reset to 0 -> silent, stamp re-seeded, rest of health still runs"
    fi
}
zero_reseeds_stamp

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

# The OTHER [OK]-while-broken case: a plugin throwing continuously WITHOUT
# killing the process. The uncaughtException handler in src/index.ts absorbs
# it, so NRestarts stays 0 and the restart check above says nothing — verified
# live with signalk-barometer 1.1.0 (60 exceptions in 120s, NRestarts=0,
# Result=success, every probe [OK]). Detection reads the container log instead.
#   $1 label | $2 simulated log body | $3 expect-match | $4 expect-NO-match
run_throw_case() {
    local label="$1" log="$2" want="$3" forbid="${4:-}"
    local out rc=0 home="$tmp/home"
    rm -rf "$home"; mkdir -p "$home/.cache"
    out=$(
        {
            set -uo pipefail
            # shellcheck disable=SC2030,SC2031
            export HOME="$home" QUADLET_DIR="$home/quadlets"
            # shellcheck disable=SC2030,SC2031
            export SIGNALK_URL="http://stub" UPDATER_URL="http://stub" DOCTOR_URL="http://stub"
            unset XDG_RUNTIME_DIR
            mkdir -p "$QUADLET_DIR"
            export SIM_LOG="$log"
            # shellcheck disable=SC2317  # invoked from the eval'd function
            health_probe() { printf 'ok 0.1\n'; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            pub_url() { printf '%s' "$1"; }
            # No restarts: this failure mode leaves NRestarts at 0, which is
            # the whole point — the restart check must stay silent.
            # shellcheck disable=SC2317  # invoked from the eval'd function
            systemctl() { case "$*" in *NRestarts*) printf '0\n' ;; *) : ;; esac; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            podman() { case "$*" in logs*) printf '%s\n' "$SIM_LOG" ;; *) : ;; esac; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            timeout() { timeout_stub "$@"; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            docker() { : ; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            signalk_all_containers() { : ; }
            eval "$body"
            cmd_health
        } 2>&1
    ) || rc=$?
    if (( rc != 0 )); then
        miss "$label: cmd_health exited rc=$rc"
        return
    fi
    if ! grep -qE "$want" <<<"$out"; then
        miss "$label: output did not match /$want/"
        printf '         %s\n' "$(tr '\n' '|' <<<"$out")" >&2
        return
    fi
    if [[ -n "$forbid" ]] && grep -qE "$forbid" <<<"$out"; then
        miss "$label: output unexpectedly matched /$forbid/"
        return
    fi
    ok "$label"
}

throwing_log=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    throwing_log+="Uncaught exception: TypeError: Cannot read properties of undefined (reading 'value')
    at publishReadings (/home/node/.signalk/node_modules/signalk-barometer/index.js:142:38)
"
done
run_throw_case "12 exceptions, NRestarts=0 -> [THROW] naming the plugin" \
    "$throwing_log" '\[THROW\].*12 uncaught exceptions'
run_throw_case "the throwing plugin is named" \
    "$throwing_log" 'nearest the throw point at: signalk-barometer'

# Attribution must take the frame CLOSEST to the throw, not the most frequent
# node_modules frame overall — a chatty dependency deeper in the stack would
# otherwise outvote the plugin and the diagnostic would name the wrong package.
mixed_log=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    mixed_log+="Uncaught exception: TypeError: Cannot read properties of undefined (reading 'value')
    at publishReadings (/home/node/.signalk/node_modules/signalk-barometer/index.js:142:38)
    at wrapped (/home/node/.signalk/node_modules/lodash/lodash.js:1:1)
    at wrapped2 (/home/node/.signalk/node_modules/lodash/lodash.js:2:2)
"
done
run_throw_case "dependency frames must not outvote the plugin" \
    "$mixed_log" 'nearest the throw point at: signalk-barometer' 'point at: lodash'

# A scoped package keeps its @scope/name; truncating to @scope names no plugin.
scoped_log=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    scoped_log+="Uncaught exception: TypeError: boom
    at tick (/home/node/.signalk/node_modules/@signalk/some-plugin/index.js:1:1)
"
done
run_throw_case "scoped plugin name is kept whole" \
    "$scoped_log" 'nearest the throw point at: @signalk/some-plugin'

# A couple of startup exceptions are ordinary (this box logs a dbus ENOENT on
# every boot). Below the threshold, so no [THROW] — otherwise the line cries
# wolf on every healthy install.
run_throw_case "2 exceptions -> no [THROW]" \
    "Uncaught exception: Error: connect ENOENT /var/run/dbus/system_bus_socket
Uncaught exception: Error: connect ENOENT /var/run/dbus/system_bus_socket" \
    '=== SignalK Stack Health ===' '\[THROW\]'

# Exactly 10 is the boundary: the threshold is "more than", so 10 stays quiet
# and 11 reports. Asserted from both sides so a >= / > slip cannot pass.
boundary_log=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    boundary_log+="Uncaught exception: TypeError: boom
    at tick (/home/node/.signalk/node_modules/signalk-barometer/index.js:1:1)
"
done
run_throw_case "exactly 10 exceptions -> no [THROW]" \
    "$boundary_log" '=== SignalK Stack Health ===' '\[THROW\]'
run_throw_case "11 exceptions -> [THROW]" \
    "${boundary_log}Uncaught exception: TypeError: boom
    at tick (/home/node/.signalk/node_modules/signalk-barometer/index.js:1:1)" \
    '\[THROW\].*11 uncaught exceptions'

# A log query that fails or times out captures nothing, which counts as zero
# exceptions — indistinguishable from a healthy server. It must say so rather
# than reporting a clean bill of health it did not establish.
scan_fails_case() {
    local label="$1" rc="$2" want="$3"
    local out home="$tmp/home" crc=0
    rm -rf "$home"; mkdir -p "$home/.cache"
    out=$(
        {
            set -uo pipefail
            # shellcheck disable=SC2030,SC2031
            export HOME="$home" QUADLET_DIR="$home/quadlets"
            # shellcheck disable=SC2030,SC2031
            export SIGNALK_URL="http://stub" UPDATER_URL="http://stub" DOCTOR_URL="http://stub"
            unset XDG_RUNTIME_DIR
            mkdir -p "$QUADLET_DIR"
            export SIM_RC="$rc"
            # shellcheck disable=SC2317  # invoked from the eval'd function
            health_probe() { printf 'ok 0.1\n'; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            pub_url() { printf '%s' "$1"; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            systemctl() { case "$*" in *NRestarts*) printf '0\n' ;; *) : ;; esac; }
            # A wedged runtime: no output, non-zero status.
            # shellcheck disable=SC2317  # invoked from the eval'd function
            podman() { case "$*" in logs*) return "$SIM_RC" ;; *) : ;; esac; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            timeout() { timeout_stub "$@"; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            docker() { : ; }
            # shellcheck disable=SC2317  # invoked from the eval'd function
            signalk_all_containers() { : ; }
            eval "$body"
            cmd_health
        } 2>&1
    ) || crc=$?
    if (( crc != 0 )); then
        miss "$label: cmd_health exited rc=$crc"
    elif ! grep -qE "$want" <<<"$out"; then
        miss "$label: output did not match /$want/ — a failed scan read as healthy"
        printf '         %s\n' "$(tr '\n' '|' <<<"$out")" >&2
    else
        ok "$label"
    fi
}
scan_fails_case "log scan times out -> [WARN], not silence" 124 '\[WARN\] could not scan the server log'
scan_fails_case "log scan errors -> [WARN] with the exit code" 125 '\[WARN\] could not read the server log \(exit 125\)'

run_throw_case "quiet log -> no [THROW]" \
    "signalk-server running at 0.0.0.0:3000" \
    '=== SignalK Stack Health ===' '\[THROW\]'

if (( fail )); then
    echo "[FAIL] check-health-restart-loop"
    exit 1
fi
echo "[PASS] check-health-restart-loop"
