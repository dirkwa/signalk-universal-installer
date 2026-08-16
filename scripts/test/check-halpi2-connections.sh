#!/usr/bin/env bash
# Verifies `signalk halpi2 connections` (cmd_connections in
# signalk-halpi2.tmpl): the two HALPI2 Signal K connections are created
# through the server's admin API (POST /skServer/providers) with the
# installer's admin token, GET-first so an existing id (a migrated HaLOS
# settings.json uses the same ids) is never re-posted. curl is a PATH shim
# that answers GET with a canned list and logs every POST body. Cases:
#   1. no admin token           → rc 1, zero curl calls, actionable message
#   2. empty provider list      → two POSTs with the exact bodies, rc 0
#   3. both ids already present → zero POSTs, rc 0
#   4. one present              → exactly the missing one is posted
#   5. server unreachable (GET fails) → rc 1, no POST
#
# Run from the repo root.

set -euo pipefail

TMPL=${TMPL:-installer/linux/signalk-halpi2.tmpl}
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not available"
    exit 0
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
bin="$root/bin"; mkdir -p "$bin" "$root/doctor"
LOG="$root/log"; mkdir -p "$LOG"

# curl shim: GET → $SHIM_GET_FILE (rc 22 when SHIM_GET_FAIL=1, like curl -f
# on a 5xx); POST → log the --data body, print $SHIM_POST_CODE (default 200).
# shellcheck disable=SC2016  # literal shim body
cat >"$bin/curl" <<'SHIM'
#!/usr/bin/env bash
method=GET; data=""; url=""
while (( $# )); do
    case "$1" in
        -X) method=$2; shift ;;
        --data) data=$2; shift ;;
        -H|-m|-o|-w) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
echo "$method $url" >>"$LOG/curl"
if [[ "$method" == POST ]]; then
    printf '%s\n' "$data" >>"$LOG/post-bodies"
    printf '%s' "${SHIM_POST_CODE:-200}"
    exit 0
fi
[[ "${SHIM_GET_FAIL:-0}" == 1 ]] && exit 22
cat "$SHIM_GET_FILE"
SHIM
chmod +x "$bin/curl"

run_connections() {
    set +e
    env -i HOME="$root" PATH="$bin:$PATH" DOCTOR_DATA="$root/doctor" SIGNALK_URL="http://127.0.0.1:80/signalk" \
        LOG="$LOG" NO_COLOR=1 "$@" bash "$TMPL" connections >"$root/out" 2>&1
    local rc=$?
    set -e
    echo "$rc"
}
reset_log() { rm -f "$LOG"/*; }
posts() { if [[ -f "$LOG/post-bodies" ]]; then grep -c '' "$LOG/post-bodies"; else echo 0; fi; }

echo "check-halpi2-connections: signalk halpi2 connections against a curl shim"

# 1. no token
reset_log
rc=$(run_connections SHIM_GET_FILE=/dev/null)
if [[ "$rc" == 1 && ! -f "$LOG/curl" ]]; then ok "no admin token: rc 1, no curl calls"; else miss "no admin token: rc $rc, curl log $(cat "$LOG/curl" 2>/dev/null)"; fi
if grep -q "signalk-token" "$root/out"; then ok "no admin token: message names the token path"; else miss "no admin token: message unhelpful: $(cat "$root/out")"; fi

printf 'tok-123' >"$root/doctor/signalk-token"

# 2. empty list → two POSTs
reset_log
echo '[]' >"$root/empty.json"
rc=$(run_connections SHIM_GET_FILE="$root/empty.json")
if [[ "$rc" == 0 ]]; then ok "empty list: rc 0"; else miss "empty list: rc $rc — $(cat "$root/out")"; fi
if [[ "$(posts)" == 2 ]]; then ok "empty list: two POSTs"; else miss "empty list: $(posts) POSTs"; fi
n2k=$(jq -c 'select(.id=="halpi2-nmea2000")' "$LOG/post-bodies" 2>/dev/null || true)
rs=$(jq -c 'select(.id=="halpi2-rs485")' "$LOG/post-bodies" 2>/dev/null || true)
if [[ "$n2k" == '{"id":"halpi2-nmea2000","enabled":true,"type":"NMEA2000","logging":false,"options":{"type":"canbus-canboatjs","interface":"can0"}}' ]]; then
    ok "N2K body: canbus-canboatjs on can0, no uniqueNumber (server randomises)"
else
    miss "N2K body: $n2k"
fi
if [[ "$rs" == '{"id":"halpi2-rs485","enabled":true,"type":"NMEA0183","logging":false,"options":{"type":"serial","device":"/dev/ttyAMA4","baudrate":4800}}' ]]; then
    ok "RS-485 body: serial /dev/ttyAMA4 @ 4800"
else
    miss "RS-485 body: $rs"
fi
if grep -q "^GET http://127.0.0.1:80/skServer/providers" "$LOG/curl"; then ok "GET-first against /skServer/providers"; else miss "GET missing: $(cat "$LOG/curl")"; fi

# 3. both present → no POST
reset_log
echo '[{"id":"halpi2-nmea2000","enabled":true},{"id":"halpi2-rs485","enabled":true},{"id":"other"}]' >"$root/both.json"
rc=$(run_connections SHIM_GET_FILE="$root/both.json")
if [[ "$rc" == 0 && "$(posts)" == 0 ]]; then ok "both present: rc 0, zero POSTs"; else miss "both present: rc $rc, $(posts) POSTs"; fi

# 4. one present → only the other
reset_log
echo '[{"id":"halpi2-nmea2000","enabled":true}]' >"$root/one.json"
rc=$(run_connections SHIM_GET_FILE="$root/one.json")
if [[ "$rc" == 0 && "$(posts)" == 1 ]] && jq -e 'select(.id=="halpi2-rs485")' "$LOG/post-bodies" >/dev/null; then
    ok "one present: only halpi2-rs485 posted"
else
    miss "one present: rc $rc, bodies: $(cat "$LOG/post-bodies" 2>/dev/null)"
fi

# 5. GET fails
reset_log
rc=$(run_connections SHIM_GET_FILE="$root/empty.json" SHIM_GET_FAIL=1)
if [[ "$rc" == 1 && "$(posts)" == 0 ]]; then ok "server unreachable: rc 1, no POST"; else miss "server unreachable: rc $rc, $(posts) POSTs"; fi

# 6. POST answered 401 → reported, rc 1
reset_log
rc=$(run_connections SHIM_GET_FILE="$root/empty.json" SHIM_POST_CODE=401)
if [[ "$rc" == 1 ]] && grep -q "401" "$root/out"; then ok "POST 401: reported, rc 1"; else miss "POST 401: rc $rc — $(cat "$root/out")"; fi

if (( fail )); then
    echo "[FAIL] signalk halpi2 connections — see entries above" >&2
    exit 1
fi
echo "[OK] signalk halpi2 connections: token gate, GET-first idempotency, exact provider bodies."
