#!/usr/bin/env bash
# Verifies install.sh's earlyoom step against a sandbox root (EARLYOOM_ROOT)
# with systemctl and pkg_install stubbed:
#   1. No earlyoom: the drop-in is written, the package installed, the unit
#      enabled and restarted; a re-run changes nothing.
#   2. An older drop-in of ours: rewritten and restarted.
#   3. systemd-oomd watching a cgroup, or earlyoom installed by the operator
#      (running or stopped): left alone. systemd-oomd watching nothing: set up.
#   4. No sudo, SIGNALK_NO_EARLYOOM=1, or a failed package install: no unit
#      enabled.
#   5. SIGNALK_NO_EARLYOOM=1 after an earlier run set it up: disabled and the
#      drop-in removed; the next run without it leaves earlyoom stopped. After
#      a failed install only the drop-in is removed.
#   6. The manual recipe in docs/recovery.md writes the same ExecStart.
# Run from the repo root.

set -euo pipefail

INSTALL_SH="${INSTALL_SH:-installer/linux/install.sh}"
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
STEP=$(awk '/^section "earlyoom"/{p=1} p{print} /^# ── end of earlyoom ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of earlyoom'* ]]; then
    echo "[ERR] could not extract the earlyoom step from $INSTALL_SH" >&2
    exit 2
fi

# systemctl reports units as active, and earlyoom.service as loaded, from flag
# files in $EARLYOOM_ROOT; a restart of earlyoom.service marks it active.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "is-active --quiet systemd-oomd.service")
        [[ -e "$EARLYOOM_ROOT/oomd-active" ]] ;;
    "is-active --quiet earlyoom.service")
        [[ -e "$EARLYOOM_ROOT/earlyoom-active" ]] ;;
    "show -p LoadState --value earlyoom.service")
        if [[ -e "$EARLYOOM_ROOT/earlyoom-loaded" ]]; then echo loaded; else echo not-found; fi ;;
    "restart earlyoom.service")
        echo "systemctl $*" >>"$STUB_LOG"
        : >"$EARLYOOM_ROOT/earlyoom-active" ;;
    *)
        echo "systemctl $*" >>"$STUB_LOG" ;;
esac
STUB
chmod +x "$tmp/stub/systemctl"
cat >"$tmp/stub/oomctl" <<'STUB'
#!/usr/bin/env bash
cat "$EARLYOOM_ROOT/oomctl.out" 2>/dev/null
STUB
chmod +x "$tmp/stub/oomctl"

# run_step <name> <sudo> — runs the step in the sandbox $tmp/<name>, which the
# caller may have seeded. The earlyoom unit is loaded once the stubbed
# pkg_install has run (or the caller loaded it with seed_unit).
run_step() {
    local root="$tmp/$1"
    mkdir -p "$root/etc/systemd/system"
    : >"$root/log"
    out=$(EARLYOOM_ROOT="$root" STUB_LOG="$root/log" PATH="$tmp/stub:$PATH" SUDO="$2" \
        STUB_PKG_FAILS="${PKG_FAILS:-}" SIGNALK_NO_EARLYOOM="${OPT_OUT:-}" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; info() { echo "info: $*"; }; warn() { echo "warn: $*"; }
        pkg_install() {
            echo "pkg_install $*" >>"$STUB_LOG"
            [[ -z "$STUB_PKG_FAILS" ]] || return 1
            : >"$EARLYOOM_ROOT/earlyoom-loaded"
        }
        '"$STEP" 2>&1) || { miss "$1: step exited non-zero: $out"; return 0; }
    log=$(cat "$root/log")
}

dropin_path() { echo "$tmp/$1/etc/systemd/system/earlyoom.service.d/50-signalk.conf"; }
dropin_of() { cat "$(dropin_path "$1")" 2>/dev/null; }
seed_unit() { mkdir -p "$tmp/$1"; : >"$tmp/$1/earlyoom-loaded"; }
desired=$(awk "/^EARLYOOM_DESIRED='/{p=1; sub(/^EARLYOOM_DESIRED='/, \"\")} p{ if (\$0 ~ /'\$/) { sub(/'\$/, \"\"); print; exit } print }" "$INSTALL_SH")
want_log=$'pkg_install earlyoom\nsystemctl daemon-reload\nsystemctl enable earlyoom.service\nsystemctl restart earlyoom.service'

echo "set up"
run_step fresh ""
if [[ "$(dropin_of fresh)" == "$desired" && "$log" == "$want_log" && "$out" == *"earlyoom running ("* ]]; then
    ok "no earlyoom: drop-in written, package installed, unit enabled and restarted"
else
    miss "fresh: dropin=[$(dropin_of fresh)] log=[$log] out=[$out]"
fi
if [[ "$(stat -c %a "$(dropin_path fresh)" 2>/dev/null)" == 644 ]]; then
    ok "drop-in is 0644, so a re-run can compare it without sudo"
else
    miss "drop-in mode $(stat -c %a "$(dropin_path fresh)" 2>/dev/null)"
fi

run_step fresh MISSING
if [[ "$out" == *"earlyoom running (skipping)"* && -z "$log" ]]; then
    ok "re-run: nothing to do, sudo never touched"
else
    miss "re-run: out=[$out] log=[$log]"
fi

mkdir -p "$(dirname "$(dropin_path older)")"
printf '[Service]\nExecStart=\nExecStart=/usr/bin/earlyoom -m 10\n' >"$(dropin_path older)"
seed_unit older
: >"$tmp/older/earlyoom-active"
run_step older ""
if [[ "$(dropin_of older)" == "$desired" && "$log" == *"systemctl restart earlyoom.service"* ]]; then
    ok "an older drop-in of ours: rewritten and restarted"
else
    miss "older: dropin=[$(dropin_of older)] log=[$log]"
fi

echo "left alone"
mkdir -p "$tmp/oomd"
: >"$tmp/oomd/oomd-active"
printf 'Swap Monitored CGroups:\n        Path: /\n' >"$tmp/oomd/oomctl.out"
run_step oomd ""
if [[ -z "$(dropin_of oomd)" && -z "$log" && "$out" == *"systemd-oomd is running"* ]]; then
    ok "systemd-oomd watching a cgroup: nothing written"
else
    miss "oomd: dropin=[$(dropin_of oomd)] log=[$log] out=[$out]"
fi

mkdir -p "$tmp/oomd-idle"
: >"$tmp/oomd-idle/oomd-active"
printf 'Swap Monitored CGroups:\nMemory Pressure Monitored CGroups:\n' >"$tmp/oomd-idle/oomctl.out"
run_step oomd-idle ""
if [[ "$(dropin_of oomd-idle)" == "$desired" && "$log" == "$want_log" ]]; then
    ok "systemd-oomd running but watching nothing: earlyoom set up"
else
    miss "oomd idle: dropin=[$(dropin_of oomd-idle)] log=[$log] out=[$out]"
fi

seed_unit operator
: >"$tmp/operator/earlyoom-active"
run_step operator ""
if [[ -z "$(dropin_of operator)" && -z "$log" && "$out" == *"set up by the operator"* ]]; then
    ok "earlyoom running without our drop-in: left alone"
else
    miss "operator: dropin=[$(dropin_of operator)] log=[$log] out=[$out]"
fi

seed_unit stopped
run_step stopped ""
if [[ -z "$(dropin_of stopped)" && -z "$log" && "$out" == *"stopped by the operator"* ]]; then
    ok "earlyoom installed but stopped: left alone"
else
    miss "stopped: dropin=[$(dropin_of stopped)] log=[$log] out=[$out]"
fi

echo "not set up"
run_step nosudo MISSING
if [[ -z "$(dropin_of nosudo)" && -z "$log" && "$out" == *"without sudo"* ]]; then
    ok "no sudo: warns, writes nothing"
else
    miss "no sudo: dropin=[$(dropin_of nosudo)] log=[$log] out=[$out]"
fi

OPT_OUT=1 run_step optout ""
if [[ -z "$(dropin_of optout)" && -z "$log" && "$out" == *"skipped (SIGNALK_NO_EARLYOOM)"* ]]; then
    ok "SIGNALK_NO_EARLYOOM=1: nothing written"
else
    miss "opt out: dropin=[$(dropin_of optout)] log=[$log] out=[$out]"
fi

mkdir -p "$(dirname "$(dropin_path undo)")"
printf '%s\n' "$desired" >"$(dropin_path undo)"
seed_unit undo
: >"$tmp/undo/earlyoom-active"
OPT_OUT=1 run_step undo ""
if [[ ! -e "$(dropin_path undo)" && "$log" == *"systemctl disable --now earlyoom.service"* \
    && "$log" == *"systemctl daemon-reload"* && "$out" == *"earlyoom off"* ]]; then
    ok "SIGNALK_NO_EARLYOOM=1 after a set-up: disabled, drop-in removed"
else
    miss "undo: dropin=[$(dropin_of undo)] log=[$log] out=[$out]"
fi
rm -f "$tmp/undo/earlyoom-active"
run_step undo ""
if [[ -z "$(dropin_of undo)" && -z "$log" && "$out" == *"stopped by the operator"* ]]; then
    ok "the run after that: earlyoom left stopped"
else
    miss "after undo: dropin=[$(dropin_of undo)] log=[$log] out=[$out]"
fi

mkdir -p "$(dirname "$(dropin_path undo-nopkg)")"
printf '%s\n' "$desired" >"$(dropin_path undo-nopkg)"
OPT_OUT=1 run_step undo-nopkg ""
if [[ ! -e "$(dropin_path undo-nopkg)" && "$log" != *"disable"* && "$out" == *"earlyoom off"* ]]; then
    ok "SIGNALK_NO_EARLYOOM=1 after a failed install: drop-in removed, no unit to disable"
else
    miss "undo, no package: dropin=[$(dropin_of undo-nopkg)] log=[$log] out=[$out]"
fi

PKG_FAILS=1 run_step pkgfail ""
if [[ "$log" == "pkg_install earlyoom" && "$out" == *"could not set up earlyoom"* ]]; then
    ok "package install fails: warns, no unit enabled"
else
    miss "pkg fails: log=[$log] out=[$out]"
fi
PKG_FAILS=1 run_step pkgfail ""
if [[ "$log" == "pkg_install earlyoom" ]]; then
    ok "after a failed install the next run tries again"
else
    miss "pkg fails, re-run: log=[$log] out=[$out]"
fi

echo "docs"
RECOVERY_MD="${RECOVERY_MD:-docs/recovery.md}"
want_exec=$(grep '^ExecStart=/' <<<"$desired")
doc_exec=$(grep -o 'ExecStart=/[^\\]*' "$RECOVERY_MD" || true)
if [[ -n "$doc_exec" && "$doc_exec" == "$want_exec" ]]; then
    ok "docs/recovery.md's manual recipe matches the installer's ExecStart"
else
    miss "docs/recovery.md recipe [$doc_exec] differs from the installer [$want_exec]"
fi

if (( fail )); then
    echo "[FAIL] check-earlyoom"
    exit 1
fi
echo "[PASS] check-earlyoom"
