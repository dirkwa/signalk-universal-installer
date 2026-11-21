#!/usr/bin/env bash
# Runs signalk-timesync's `run` pass with the server, timedatectl and the
# tz-lookup call into the server container stubbed, and checks which GPS
# positions reach tz-lookup and set the host zone.
#
# Needs jq and the host's /usr/share/zoneinfo. Run from the repo root.

set -euo pipefail

TMPL="${TMPL:-installer/linux/signalk-timesync.tmpl}"
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "[ERR] jq not installed" >&2; exit 2; }
[[ -f /usr/share/zoneinfo/Pacific/Noumea ]] \
    || { echo "[ERR] /usr/share/zoneinfo/Pacific/Noumea missing (tzdata)" >&2; exit 2; }

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# The agent's functions without its dispatcher, so cmd_run can be called
# after the stubs below replace what needs root or a live stack.
sed -e 's/__SK_USER__/tester/g' -e 's/__SK_HTTP_PORT__/4000/g' "$TMPL" |
    sed '/^case "${1:-status}" in/,$d' >"$tmp/funcs.sh"
mkdir -p "$tmp/home/.signalk-doctor"
echo test-token >"$tmp/home/.signalk-doctor/signalk-token"

cat >"$tmp/run.sh" <<'EOF'
. "$FUNCS"
id() { if [[ "$*" == "-u" ]]; then echo 0; else echo 1000; fi; }
home_dir() { echo "$HOME_DIR"; }
api() {
    case "$1" in
        navigation/datetime) printf '{"value":"%s","timestamp":"%s"}' "$NOW_ISO" "$NOW_ISO" ;;
        navigation/position) printf '%s' "$POSITION" ;;
    esac
}
timedatectl() {
    case "$*" in
        "show -p NTPSynchronized --value") echo yes ;;
        "show -p Timezone --value") echo Pacific/Fiji ;;
        "set-timezone "*) echo "$2" >>"$CALLS/set-timezone" ;;
    esac
}
runuser() { echo "$*" >>"$CALLS/tz-lookup"; echo Pacific/Noumea; }
cmd_run
EOF

now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
stale=$(date -u -d '-10 min' +%Y-%m-%dT%H:%M:%S.000Z)

# Runs the pass with one position response, under the locale in $LOCALE if
# set; leaves the agent's output in $out and what it called in $calls/.
run_pass() {
    calls="$tmp/calls-$1"
    mkdir -p "$calls"
    local rc=0
    out=$(FUNCS="$tmp/funcs.sh" HOME_DIR="$tmp/home" NOW_ISO="$now" \
        POSITION="$2" CALLS="$calls" LC_ALL="${LOCALE:-${LC_ALL:-}}" \
        bash "$tmp/run.sh" 2>&1) || rc=$?
    if (( rc != 0 )); then
        miss "$1: the pass exited $rc: $out"
        return 1
    fi
}

# A position from an IPG100 NMEA 2000 gateway, as signalk-server passes it on.
if run_pass precise \
    '{"value":{"latitude":-22.284428328118082,"longitude":166.4314020608548},"timestamp":"'"$now"'"}'; then
    if grep -qF '(-22.284428328118082,166.4314020608548)' "$calls/tz-lookup" 2>/dev/null \
        && [[ "$(cat "$calls/set-timezone" 2>/dev/null)" == Pacific/Noumea ]]; then
        ok "a position with 15 decimals sets the zone tz-lookup returns"
    else
        miss "a position with 15 decimals did not set the zone (output: $out)"
    fi
fi

if run_pass string \
    '{"value":{"latitude":"-22.28,require(\"child_process\")","longitude":166.43},"timestamp":"'"$now"'"}'; then
    if [[ ! -e "$calls/tz-lookup" && ! -e "$calls/set-timezone" \
        && "$out" == *'not a plain decimal number'* ]]; then
        ok "a latitude that is not a plain decimal number never reaches tz-lookup"
    else
        miss "a latitude that is not a plain decimal number was not rejected (output: $out)"
    fi
fi

# In C and C.UTF-8 a 0-9 range matches ASCII digits only; in a locale like
# en_GB.UTF-8, which the service gets from the host, it also matches 〇.
utf8=$(locale -a 2>/dev/null | grep -iE '^[a-z]{2}_[a-z]{2}\.utf-?8$' | head -1 || true)
if [[ -z "$utf8" ]]; then
    echo "  [SKIP] no xx_XX.UTF-8 locale generated; non-ASCII digits not checked"
elif LOCALE="$utf8" run_pass digits \
    '{"value":{"latitude":"〇.〡〢","longitude":166.43},"timestamp":"'"$now"'"}'; then
    if [[ ! -e "$calls/tz-lookup" && ! -e "$calls/set-timezone" \
        && "$out" == *'not a plain decimal number'* ]]; then
        ok "a latitude in non-ASCII digits never reaches tz-lookup ($utf8)"
    else
        miss "a latitude in non-ASCII digits was not rejected under $utf8 (output: $out)"
    fi
fi

if run_pass stale \
    '{"value":{"latitude":-22.28,"longitude":166.43},"timestamp":"'"$stale"'"}'; then
    if [[ ! -e "$calls/tz-lookup" && ! -e "$calls/set-timezone" \
        && "$out" == *'no fresh GPS position'* ]]; then
        ok "a position 10 minutes old leaves the zone alone"
    else
        miss "a position 10 minutes old was acted on (output: $out)"
    fi
fi

if (( fail )); then
    echo "[FAIL] timesync position checks"
    exit 1
fi
echo "[PASS] timesync position checks"
