#!/usr/bin/env bash
# Verifies install.sh's Hardware watchdog step against a sandbox root
# (WATCHDOG_ROOT) with systemctl and is_pi stubbed:
#   1. A Pi with /dev/watchdog0 and RuntimeWatchdogSec off: the drop-in is
#      written and daemon-reload arms it; a re-run changes nothing.
#   2. A drop-in written but never reloaded, or an older drop-in of ours:
#      rewritten and reloaded.
#   3. RuntimeWatchdogSec set by the operator, the watchdog daemon running,
#      or the device held by another program: left alone.
#   4. Not a Pi, no /dev/watchdog0, or no sudo: nothing written.
#   5. SIGNALK_NO_WATCHDOG=1: our drop-in is removed and reloaded.
#   6. The drop-in's timeout fits bcm2835_wdt's counter (1-15 s).
# Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}
if [[ ! -f "$INSTALL_SH" ]]; then
    echo "[ERR] $INSTALL_SH not found (run from repo root)" >&2
    exit 2
fi

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# Lift the step out of install.sh so the test tracks the real source.
STEP=$(awk '/^section "Hardware watchdog"/{p=1} p{print} /^# ── end of Hardware watchdog ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of Hardware watchdog'* ]]; then
    echo "[ERR] could not extract the Hardware watchdog step from $INSTALL_SH" >&2
    exit 2
fi

mkdir -p "$tmp/bin"
# systemctl models PID 1: `show` reports $WATCHDOG_ROOT/runtime, and
# daemon-reload recomputes it from the drop-in, falling back to the value an
# operator's own config would give ($WATCHDOG_ROOT/runtime.other) or 0.
cat >"$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
dropin="$WATCHDOG_ROOT/etc/systemd/system.conf.d/50-signalk-watchdog.conf"
case "$*" in
    "show -p RuntimeWatchdogUSec --value")
        cat "$WATCHDOG_ROOT/runtime" 2>/dev/null || echo 0 ;;
    "is-active --quiet watchdog.service")
        [[ -e "$WATCHDOG_ROOT/watchdog-daemon-active" ]] ;;
    daemon-reload)
        echo "systemctl daemon-reload" >>"$STUB_LOG"
        if grep -qx 'RuntimeWatchdogSec=15' "$dropin" 2>/dev/null; then
            echo 15s >"$WATCHDOG_ROOT/runtime"
        else
            cat "$WATCHDOG_ROOT/runtime.other" 2>/dev/null >"$WATCHDOG_ROOT/runtime" || echo 0 >"$WATCHDOG_ROOT/runtime"
        fi ;;
    *)
        echo "systemctl $*" >>"$STUB_LOG" ;;
esac
STUB
chmod +x "$tmp/bin/systemctl"

# run_step <name> <sudo> — runs the step in the sandbox $tmp/<name>, which the
# caller may have seeded; a Pi with /dev/watchdog0 unless told otherwise.
run_step() {
    local root="$tmp/$1"
    mkdir -p "$root/dev" "$root/etc/systemd" "$root/sys/class/watchdog/watchdog0"
    [[ -n "${NO_DEVICE:-}" ]] || : >"$root/dev/watchdog0"
    : >"$root/log"
    out=$(WATCHDOG_ROOT="$root" STUB_LOG="$root/log" PATH="$tmp/bin:$PATH" SUDO="$2" \
        STUB_NOT_PI="${NOT_PI:-}" SIGNALK_NO_WATCHDOG="${OPT_OUT:-}" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; info() { echo "info: $*"; }; warn() { echo "warn: $*"; }
        is_pi() { [[ -z "$STUB_NOT_PI" ]]; }
        '"$STEP" 2>&1) || { miss "$1: step exited non-zero: $out"; return 0; }
    log=$(cat "$root/log")
}

dropin_of() { cat "$tmp/$1/etc/systemd/system.conf.d/50-signalk-watchdog.conf" 2>/dev/null; }
desired=$(awk "/^WATCHDOG_DESIRED='/{p=1; sub(/^WATCHDOG_DESIRED='/, \"\")} p{ if (\$0 ~ /'\$/) { sub(/'\$/, \"\"); print; exit } print }" "$INSTALL_SH")

echo "enable"
run_step fresh ""
if [[ "$(dropin_of fresh)" == "$desired" ]] && grep -qx "systemctl daemon-reload" <<<"$log" \
    && [[ "$out" == *"Hardware watchdog armed, 15 s ("* ]]; then
    ok "Pi with /dev/watchdog0: drop-in written, daemon-reload armed it"
else
    miss "fresh Pi: dropin=[$(dropin_of fresh)] log=[$log] out=[$out]"
fi
if [[ "$(stat -c %a "$tmp/fresh/etc/systemd/system.conf.d/50-signalk-watchdog.conf" 2>/dev/null)" == 644 ]]; then
    ok "drop-in is 0644, so a re-run can compare it without sudo"
else
    miss "drop-in mode $(stat -c %a "$tmp/fresh/etc/systemd/system.conf.d/50-signalk-watchdog.conf" 2>/dev/null)"
fi

run_step fresh MISSING
if [[ "$out" == *"armed, 15 s (skipping)"* && -z "$log" ]]; then
    ok "re-run: nothing to do, sudo never touched"
else
    miss "re-run: out=[$out] log=[$log]"
fi

mkdir -p "$tmp/unreloaded/etc/systemd/system.conf.d"
printf '%s\n' "$desired" >"$tmp/unreloaded/etc/systemd/system.conf.d/50-signalk-watchdog.conf"
run_step unreloaded ""
if grep -qx "systemctl daemon-reload" <<<"$log" && [[ "$out" == *"armed, 15 s ("* ]]; then
    ok "drop-in written but never reloaded: reloaded"
else
    miss "unreloaded: out=[$out] log=[$log]"
fi

mkdir -p "$tmp/older/etc/systemd/system.conf.d"
printf '[Manager]\nRuntimeWatchdogSec=10\n' >"$tmp/older/etc/systemd/system.conf.d/50-signalk-watchdog.conf"
echo 10s >"$tmp/older/runtime"
run_step older ""
if [[ "$(dropin_of older)" == "$desired" ]] && grep -qx "systemctl daemon-reload" <<<"$log"; then
    ok "an older drop-in of ours: rewritten"
else
    miss "older: dropin=[$(dropin_of older)] log=[$log]"
fi

echo "left alone"
mkdir -p "$tmp/operator"
echo 30s >"$tmp/operator/runtime"
run_step operator ""
if [[ -z "$(dropin_of operator)" && -z "$log" && "$out" == *"RuntimeWatchdogSec=30s; left as is"* ]]; then
    ok "RuntimeWatchdogSec set by the operator: left alone, and says what it is"
else
    miss "operator: dropin=[$(dropin_of operator)] log=[$log] out=[$out]"
fi

mkdir -p "$tmp/daemon"
: >"$tmp/daemon/watchdog-daemon-active"
run_step daemon ""
if [[ -z "$(dropin_of daemon)" && -z "$log" && "$out" == *"held by another program"* ]]; then
    ok "watchdog daemon running: left alone"
else
    miss "daemon: dropin=[$(dropin_of daemon)] log=[$log] out=[$out]"
fi

mkdir -p "$tmp/held/sys/class/watchdog/watchdog0"
echo active >"$tmp/held/sys/class/watchdog/watchdog0/state"
run_step held ""
if [[ -z "$(dropin_of held)" && -z "$log" && "$out" == *"held by another program"* ]]; then
    ok "device active with systemd not driving it: left alone"
else
    miss "held: dropin=[$(dropin_of held)] log=[$log] out=[$out]"
fi

NOT_PI=1 run_step notpi ""
if [[ -z "$(dropin_of notpi)" && -z "$log" && "$out" == *"Not a Raspberry Pi"* ]]; then
    ok "not a Pi: nothing written"
else
    miss "not a Pi: dropin=[$(dropin_of notpi)] log=[$log] out=[$out]"
fi

NO_DEVICE=1 run_step nodevice ""
if [[ -z "$(dropin_of nodevice)" && -z "$log" && "$out" == *"No /dev/watchdog0"* ]]; then
    ok "no /dev/watchdog0: nothing written"
else
    miss "no device: dropin=[$(dropin_of nodevice)] log=[$log] out=[$out]"
fi

run_step nosudo MISSING
if [[ -z "$(dropin_of nosudo)" && -z "$log" && "$out" == *"without sudo"* ]]; then
    ok "no sudo: warns, writes nothing"
else
    miss "no sudo: dropin=[$(dropin_of nosudo)] log=[$log] out=[$out]"
fi

echo "opt out"
mkdir -p "$tmp/optout/etc/systemd/system.conf.d"
printf '%s\n' "$desired" >"$tmp/optout/etc/systemd/system.conf.d/50-signalk-watchdog.conf"
echo 15s >"$tmp/optout/runtime"
OPT_OUT=1 run_step optout ""
if [[ ! -e "$tmp/optout/etc/systemd/system.conf.d/50-signalk-watchdog.conf" ]] \
    && grep -qx "systemctl daemon-reload" <<<"$log" && [[ "$(cat "$tmp/optout/runtime")" == 0 ]]; then
    ok "SIGNALK_NO_WATCHDOG=1: drop-in removed, watchdog off after reload"
else
    miss "opt out: log=[$log] runtime=[$(cat "$tmp/optout/runtime")] out=[$out]"
fi

OPT_OUT=1 run_step optout-none ""
if [[ -z "$(dropin_of optout-none)" && -z "$log" && "$out" == *"skipped (SIGNALK_NO_WATCHDOG)"* ]]; then
    ok "SIGNALK_NO_WATCHDOG=1 with no drop-in: nothing to do"
else
    miss "opt out, no drop-in: log=[$log] out=[$out]"
fi

echo "timeout"
secs=$(sed -n 's/^RuntimeWatchdogSec=\([0-9][0-9]*\)$/\1/p' <<<"$desired")
if [[ -n "$secs" ]] && (( secs >= 1 && secs <= 15 )); then
    ok "RuntimeWatchdogSec=$secs fits bcm2835_wdt's 20-bit counter"
else
    miss "RuntimeWatchdogSec='$secs': bcm2835_wdt holds 1-15 s; 16 s programs 0 ticks"
fi

if (( fail )); then
    echo "[FAIL] check-watchdog"
    exit 1
fi
echo "[PASS] check-watchdog"
