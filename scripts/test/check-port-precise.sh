#!/usr/bin/env bash
# Verifies preflight's check_ports is precise on re-runs: a bound port is
# only "expected" when the managed container that owns it is actually
# running. A stray/duplicate process holding the port (the failure mode that
# served stale code from a leftover container) is flagged even in verify
# mode. Also verifies 3000 (signalk-server's fallback port) is checked.
#
# Sources preflight.sh (guarded so main() doesn't run) and drives check_ports
# with stubbed ss / managed_container_running / is_verify_mode. Run from repo
# root.

set -euo pipefail

PREFLIGHT=${PREFLIGHT:-installer/linux/preflight.sh}

if [[ ! -f "$PREFLIGHT" ]]; then
    echo "[ERR] $PREFLIGHT not found (run from repo root)" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$PREFLIGHT"

if ! declare -F check_ports >/dev/null; then
    echo "[ERR] check_ports not defined after sourcing $PREFLIGHT" >&2
    exit 2
fi

fail=0

# Static check: 3000 must be in the checked set (signalk-server's fallback).
if printf '%s\n' "${PORTS_TO_CHECK[@]}" | grep -qx 3000; then
    echo "  [OK]   3000 (fallback port) is in PORTS_TO_CHECK"
else
    echo "  [MISS] 3000 not checked — a stray server on the fallback port hides"
    fail=1
fi

# run_case <label> <bound-ports-csv> <verify 0|1> <running-owners-csv> <expect-rc 0|1>
# Stubs ss() to report the given ports as bound, managed_container_running()
# to succeed only for the listed owners, and is_verify_mode() per the flag.
run_case() {
    local label=$1 bound=$2 verify=$3 running=$4 want_rc=$5
    local rc
    rc=$(
        BOUND_PORTS="$bound" RUNNING_OWNERS="$running" VERIFY="$verify" bash -c '
            source "'"$PREFLIGHT"'"
            ss() {
                local q="$*"
                local p
                for p in ${BOUND_PORTS//,/ }; do
                    if [[ "$q" == *":$p "* || "$q" == *":$p)"* ]]; then
                        printf "State\nLISTEN 0 511 *:%s *:*\n" "$p"
                        return 0
                    fi
                done
                printf "State\n"
            }
            managed_container_running() {
                local o
                for o in ${RUNNING_OWNERS//,/ }; do
                    [[ "$1" == "$o" ]] && return 0
                done
                return 1
            }
            is_verify_mode() { [[ "$VERIFY" == "1" ]]; }
            FORCE=0
            check_ports >/dev/null 2>&1
        '
        echo "rc=$?"
    )
    rc=${rc##*rc=}
    if [[ "$rc" == "$want_rc" ]]; then
        echo "  [OK]   $label (rc=$rc)"
    else
        echo "  [MISS] $label — wanted rc=$want_rc, got rc=$rc"
        fail=1
    fi
}

# 1. Fresh install, nothing bound → pass.
run_case "fresh install, all ports free" "" 0 "" 0

# 2. Fresh install, port 80 already taken → fail (real conflict).
run_case "fresh install, 80 occupied" "80" 0 "" 1

# 3. Re-run, 80 bound and signalk-server running → expected, pass.
run_case "re-run, 80 held by running signalk-server" "80" 1 "signalk-server" 0

# 4. Re-run, 3000 bound but signalk-server NOT running → stray, fail.
#    This is the incident: a leftover container squats the fallback port.
run_case "re-run, 3000 held but owner not running (stray)" "3000" 1 "" 1

# 5. Re-run, 3003 bound and updater running → expected, pass.
run_case "re-run, 3003 held by running updater" "3003" 1 "signalk-updater-server" 0

# 6. Re-run, 3003 bound but updater NOT running → stray, fail.
run_case "re-run, 3003 held but updater not running" "3003" 1 "signalk-server" 1

if (( fail )); then
    echo
    echo "[ERR] check_ports precision is wrong — see entries above." >&2
    exit 1
fi
echo
echo "[OK] check_ports flags strays even in verify mode and checks the fallback port."
