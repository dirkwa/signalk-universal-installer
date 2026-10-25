#!/usr/bin/env bash
# Verifies install.sh's host power step against a sandbox root (POWER_ROOT)
# and HOME, with systemctl and pkg_install stubbed and PATH limited to the
# tools the step uses, so pkaction is present only where a case puts it:
#   1. polkit present: the rule names the user and the four logind actions,
#      both user units run `systemctl poweroff` / `systemctl reboot`, and the
#      user manager reloads; a re-run without sudo changes nothing, and one
#      that finds the units on disk but not loaded reloads again.
#   2. A rule from an older run: rewritten.
#   3. No pkaction: polkitd is installed and the bus configuration reloaded
#      first; when the install fails, nothing is
#      written, so the updater offers no buttons.
#   4. A podman machine VM, or no sudo: nothing written.
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
STEP=$(awk '/^section "Power off and reboot from the Updater Console"/{p=1} p{print} /^# ── end of host power ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of host power'* ]]; then
    echo "[ERR] could not extract the host power step from $INSTALL_SH" >&2
    exit 2
fi

mkdir -p "$tmp/bin"
for t in bash cat id install mkdir rm; do
    ln -s "$(command -v "$t")" "$tmp/bin/$t"
done
# The user manager loads the power units on daemon-reload; `show` reports
# them loaded from then on, one blank line between units as systemctl
# prints them, and is not logged.
cat >"$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "--user show -p LoadState --value signalk-poweroff.service signalk-reboot.service")
        if [[ -e "$POWER_ROOT/units-loaded" ]]; then printf "loaded\n\nloaded\n"; else printf "not-found\n\nnot-found\n"; fi ;;
    "--user daemon-reload")
        echo "systemctl $*" >>"$STUB_LOG"
        : >"$POWER_ROOT/units-loaded" ;;
    *)
        echo "systemctl $*" >>"$STUB_LOG" ;;
esac
STUB
mkdir -p "$tmp/polkit"
printf '#!/bin/sh\necho "pkaction version 126"\n' >"$tmp/polkit/pkaction"
chmod +x "$tmp/bin/systemctl" "$tmp/polkit/pkaction"

# run_step <name> <sudo> — runs the step in the sandbox $tmp/<name>, which the
# caller may have seeded. POLKIT=1 puts pkaction on PATH; PKG_FAILS=1 makes
# the stubbed pkg_install fail.
run_step() {
    local root="$tmp/$1" path="$tmp/bin"
    mkdir -p "$root/home"
    : >"$root/log"
    [[ -n "${POLKIT:-}" ]] && path="$path:$tmp/polkit"
    out=$(POWER_ROOT="$root" STUB_LOG="$root/log" HOME="$root/home" USER=skuser PATH="$path" \
        SUDO="$2" STUB_PKG_FAILS="${PKG_FAILS:-}" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; info() { echo "info: $*"; }; warn() { echo "warn: $*"; }
        pkg_install() {
            echo "pkg_install $*" >>"$STUB_LOG"
            [[ -z "$STUB_PKG_FAILS" ]]
        }
        '"$STEP" 2>&1) || { miss "$1: step exited non-zero: $out"; return 0; }
    log=$(cat "$root/log")
}

rule_path() { echo "$tmp/$1/etc/polkit-1/rules.d/50-signalk-power.rules"; }
rule_of() { cat "$(rule_path "$1")" 2>/dev/null; }
unit_of() { cat "$tmp/$1/home/.config/systemd/user/signalk-$2.service" 2>/dev/null; }
actions_of() { rule_of "$1" | grep -o '"org\.freedesktop\.login1\.[a-z-]*"' | tr -d '"' | sort | tr '\n' ' '; }
want_actions="org.freedesktop.login1.power-off org.freedesktop.login1.power-off-multiple-sessions org.freedesktop.login1.reboot org.freedesktop.login1.reboot-multiple-sessions "

echo "set up"
POLKIT=1 run_step fresh ""
if [[ "$(rule_of fresh)" == *"subject.user == \"$(id -un)\""* && "$(actions_of fresh)" == "$want_actions" \
    && "$(rule_of fresh)" == *"polkit.Result.YES"* ]]; then
    ok "rule grants the running account (not \$USER) exactly power-off, reboot and their -multiple-sessions forms"
else
    miss "fresh rule: [$(rule_of fresh)]"
fi
if [[ "$(unit_of fresh poweroff)" == *$'Type=oneshot\nRemainAfterExit=yes\nExecStart=systemctl poweroff' \
    && "$(unit_of fresh reboot)" == *$'Type=oneshot\nRemainAfterExit=yes\nExecStart=systemctl reboot' ]]; then
    ok "user units run systemctl poweroff / reboot"
else
    miss "units: poweroff=[$(unit_of fresh poweroff)] reboot=[$(unit_of fresh reboot)]"
fi
if [[ "$log" == "systemctl --user daemon-reload" && "$out" == *"can power off and reboot the host"* ]]; then
    ok "user manager reloaded, no package installed"
else
    miss "fresh: log=[$log] out=[$out]"
fi
if [[ "$(stat -c %a "$(rule_path fresh)" 2>/dev/null)" == 644 ]]; then
    ok "rule is 0644, so a re-run can compare it without sudo"
else
    miss "rule mode $(stat -c %a "$(rule_path fresh)" 2>/dev/null)"
fi

POLKIT=1 run_step fresh MISSING
if [[ "$out" == *"already set up (skipping)"* && -z "$log" ]]; then
    ok "re-run: nothing to do, sudo never touched"
else
    miss "re-run: out=[$out] log=[$log]"
fi

rm "$tmp/fresh/units-loaded"
POLKIT=1 run_step fresh ""
if [[ "$log" == "systemctl --user daemon-reload" && "$out" != *"skipping"* ]]; then
    ok "units on disk but not loaded (an earlier reload failed): reloaded again"
else
    miss "not loaded: out=[$out] log=[$log]"
fi

mkdir -p "$(dirname "$(rule_path older)")"
printf '// an older rule\n' >"$(rule_path older)"
POLKIT=1 run_step older ""
if [[ "$(rule_of older)" == "$(rule_of fresh)" && "$log" == "systemctl --user daemon-reload" ]]; then
    ok "an older rule: rewritten"
else
    miss "older: rule=[$(rule_of older)] log=[$log]"
fi

echo "polkitd missing"
run_step fresh ""
if [[ "$log" == $'pkg_install polkitd\nsystemctl reload dbus.service\nsystemctl --user daemon-reload' ]]; then
    ok "rule and units current but polkitd removed since: reinstalled"
else
    miss "polkitd removed: log=[$log] out=[$out]"
fi

run_step nopolkit ""
if [[ "$log" == $'pkg_install polkitd\nsystemctl reload dbus.service\nsystemctl --user daemon-reload' && "$(rule_of nopolkit)" == "$(rule_of fresh)" ]]; then
    ok "no pkaction: polkitd installed, then rule and units written"
else
    miss "nopolkit: log=[$log] out=[$out]"
fi

PKG_FAILS=1 run_step pkgfail ""
if [[ "$log" == "pkg_install polkitd" && -z "$(rule_of pkgfail)" && -z "$(unit_of pkgfail poweroff)" \
    && "$out" == *"could not set up polkitd"* ]]; then
    ok "polkitd install fails: no rule, no units"
else
    miss "pkgfail: log=[$log] out=[$out]"
fi

echo "not set up"
mkdir -p "$tmp/machine/etc/containers"
: >"$tmp/machine/etc/containers/podman-machine"
POLKIT=1 run_step machine ""
if [[ -z "$(rule_of machine)" && -z "$(unit_of machine poweroff)" && -z "$log" && "$out" == *"podman machine"* ]]; then
    ok "podman machine VM: nothing written"
else
    miss "machine: log=[$log] out=[$out]"
fi

POLKIT=1 run_step nosudo MISSING
if [[ -z "$(rule_of nosudo)" && -z "$(unit_of nosudo poweroff)" && -z "$log" && "$out" == *"without sudo"* ]]; then
    ok "no sudo: warns, writes nothing"
else
    miss "nosudo: log=[$log] out=[$out]"
fi

echo "docs and uninstall"
# The removal recipe in docs/recovery.md and both uninstallers name the paths
# the step writes; a rename must update them too.
rule_file=$(sed -n 's|^POWER_RULE=".*}\(/etc/[^"]*\)"$|\1|p' "$INSTALL_SH")
for f in docs/recovery.md installer/linux/signalk.tmpl scripts/uninstall.sh; do
    if [[ -n "$rule_file" ]] && grep -qF "$rule_file" "$f" \
        && grep -qE 'signalk-(\{poweroff,reboot\}|poweroff)\.service' "$f"; then
        ok "$f names $rule_file and the power units"
    else
        miss "$f does not name the rule ($rule_file) or the power units"
    fi
done

if (( fail )); then
    echo "[FAIL] check-host-power"
    exit 1
fi
echo "[PASS] check-host-power"
