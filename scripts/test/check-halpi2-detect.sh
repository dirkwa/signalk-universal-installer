#!/usr/bin/env bash
# Verifies the HALPI2 board-detection ladder in detect-hardware.sh (the
# hardware.json owner) and its mirror in signalk-halpi2.tmpl (`detect`).
# Both are passive: no sudo, no writes. Fixtures replace every host input:
# DT_MODEL_FILE (device-tree model string), a PATH shim for systemctl
# (halpid unit state), HALPI2_I2C_DEV + a PATH shim for i2ctransfer (the
# controller at 0x6d), HALPI2_RS485_DEV (/dev/ttyAMA4). Cases:
#   1. not a CM5            → no `board`, no `onboardSerial`; tmpl detect rc 2
#   2. CM5, nothing else    → board candidate via model-string; tmpl rc 1
#   3. CM5 + halpid active  → confirmed via halpid, onboardSerial present
#   4. CM5 + controller answers over I2C → confirmed via i2c with versions
#   5. CM5 + I2C answers but /dev/ttyAMA4 absent → onboardSerial empty
#
# Run from the repo root.

set -euo pipefail

DETECT=${DETECT:-installer/linux/detect-hardware.sh}
TMPL=${TMPL:-installer/linux/signalk-halpi2.tmpl}
for f in "$DETECT" "$TMPL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not available"
    exit 0
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
bin="$root/bin"; mkdir -p "$bin"

printf 'Raspberry Pi Compute Module 5 Rev 1.0\0' >"$root/model-cm5"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$root/model-pi5"
: >"$root/ttyAMA4"
: >"$root/i2c-1"

# shellcheck disable=SC2016  # shim bodies are literal scripts
{
printf '#!/usr/bin/env bash\n[[ "$*" == "is-active --quiet halpid" && "${SHIM_HALPID:-}" == active ]]\n' >"$bin/systemctl"
printf '#!/usr/bin/env bash\n[[ "${SHIM_I2C:-fail}" == ok ]] || exit 1; case "$4" in 0x04) echo "0x03 0x03 0x01 0xff";; 0x03) echo "0x02 0x00 0x00 0xff";; esac\n' >"$bin/i2ctransfer"
}
chmod +x "$bin"/*

# run_detect <model-file> <i2c-dev> <rs485-dev> [ENV=val ...] → hardware.json on stdout
run_detect() {
    local model=$1 i2c=$2 rs=$3; shift 3
    env -i HOME="$root" PATH="$bin:$PATH" DT_MODEL_FILE="$model" HALPI2_I2C_DEV="$i2c" HALPI2_RS485_DEV="$rs" "$@" \
        bash "$DETECT"
}
# run_tmpl_detect … → prints "<rc> <json>"
run_tmpl_detect() {
    local model=$1 i2c=$2 rs=$3; shift 3
    local out rc=0
    out=$(env -i HOME="$root" PATH="$bin:$PATH" DT_MODEL_FILE="$model" HALPI2_I2C_DEV="$i2c" HALPI2_RS485_DEV="$rs" "$@" \
        bash "$TMPL" detect 2>/dev/null) || rc=$?
    printf '%s %s' "$rc" "$out"
}

echo "check-halpi2-detect: board ladder in detect-hardware.sh and signalk-halpi2 detect"

# 1. not a CM5
hw=$(run_detect "$root/model-pi5" "$root/i2c-1" "$root/ttyAMA4" SHIM_I2C=ok SHIM_HALPID=active)
if [[ "$(jq -r 'has("board")' <<<"$hw")" == false && "$(jq -r 'has("onboardSerial")' <<<"$hw")" == false ]]; then
    ok "non-CM5: no board / onboardSerial keys"
else
    miss "non-CM5: emitted board/onboardSerial: $(jq -c '{board,onboardSerial}' <<<"$hw")"
fi
if jq -e '.serial and .can and .bluetooth and .audio and .gpio' <<<"$hw" >/dev/null; then
    ok "non-CM5: existing classes untouched"
else
    miss "non-CM5: existing classes missing"
fi
read -r rc _ <<<"$(run_tmpl_detect "$root/model-pi5" "$root/i2c-1" "$root/ttyAMA4")"
if [[ "$rc" == 2 ]]; then ok "tmpl detect: non-CM5 rc 2"; else miss "tmpl detect: non-CM5 rc $rc"; fi

# 2. CM5 alone → candidate
hw=$(run_detect "$root/model-cm5" "$root/no-i2c" "$root/ttyAMA4")
if [[ "$(jq -c '.board' <<<"$hw")" == '{"model":"halpi2","candidate":true,"detectedVia":"model-string","hardwareVersion":null,"firmwareVersion":null}' ]]; then
    ok "CM5 alone: candidate via model-string"
else
    miss "CM5 alone: board = $(jq -c '.board' <<<"$hw")"
fi
if [[ "$(jq -c '.onboardSerial' <<<"$hw")" == "[]" ]]; then ok "CM5 alone: onboardSerial empty (not confirmed)"; else miss "CM5 alone: onboardSerial = $(jq -c '.onboardSerial' <<<"$hw")"; fi
read -r rc json <<<"$(run_tmpl_detect "$root/model-cm5" "$root/no-i2c" "$root/ttyAMA4")"
if [[ "$rc" == 1 && "$(jq -r '.candidate' <<<"$json")" == true ]]; then ok "tmpl detect: candidate rc 1"; else miss "tmpl detect: candidate rc $rc json $json"; fi

# 3. halpid active → confirmed
hw=$(run_detect "$root/model-cm5" "$root/no-i2c" "$root/ttyAMA4" SHIM_HALPID=active)
if [[ "$(jq -r '.board.detectedVia' <<<"$hw")" == halpid && "$(jq -r '.board.candidate' <<<"$hw")" == false ]]; then ok "halpid active: confirmed via halpid"; else miss "halpid active: board = $(jq -c '.board' <<<"$hw")"; fi
if [[ "$(jq -r '.onboardSerial[0].device' <<<"$hw")" == "$root/ttyAMA4" && "$(jq -r '.onboardSerial[0].enabled' <<<"$hw")" == true ]]; then ok "halpid active: onboardSerial /dev/ttyAMA4 enabled"; else miss "halpid active: onboardSerial = $(jq -c '.onboardSerial' <<<"$hw")"; fi
read -r rc json <<<"$(run_tmpl_detect "$root/model-cm5" "$root/no-i2c" "$root/ttyAMA4" SHIM_HALPID=active)"
if [[ "$rc" == 0 && "$(jq -r '.detectedVia' <<<"$json")" == halpid ]]; then ok "tmpl detect: halpid rc 0"; else miss "tmpl detect: halpid rc $rc json $json"; fi

# 4. controller answers over I2C → confirmed with versions
hw=$(run_detect "$root/model-cm5" "$root/i2c-1" "$root/ttyAMA4" SHIM_I2C=ok)
if [[ "$(jq -c '.board' <<<"$hw")" == '{"model":"halpi2","candidate":false,"detectedVia":"i2c","hardwareVersion":"2.0.0","firmwareVersion":"3.3.1"}' ]]; then
    ok "I2C answer: confirmed via i2c with firmware 3.3.1 / hardware 2.0.0"
else
    miss "I2C answer: board = $(jq -c '.board' <<<"$hw")"
fi
read -r rc json <<<"$(run_tmpl_detect "$root/model-cm5" "$root/i2c-1" "$root/ttyAMA4" SHIM_I2C=ok)"
if [[ "$rc" == 0 && "$(jq -r '.firmwareVersion' <<<"$json")" == "3.3.1" ]]; then ok "tmpl detect: i2c rc 0 with version"; else miss "tmpl detect: i2c rc $rc json $json"; fi

# 5. confirmed but RS-485 node absent
hw=$(run_detect "$root/model-cm5" "$root/i2c-1" "$root/no-tty" SHIM_I2C=ok)
if [[ "$(jq -c '.onboardSerial' <<<"$hw")" == "[]" ]]; then ok "RS-485 node absent: onboardSerial empty"; else miss "RS-485 node absent: onboardSerial = $(jq -c '.onboardSerial' <<<"$hw")"; fi

if (( fail )); then
    echo "[FAIL] HALPI2 detection ladder — see entries above" >&2
    exit 1
fi
echo "[OK] HALPI2 detection ladder: model-string → halpid → i2c, onboardSerial only when confirmed."
