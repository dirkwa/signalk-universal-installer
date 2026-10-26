#!/usr/bin/env bash
# Verifies install.sh's "Stop plugin containers at shutdown" step against a
# sandbox root (CONTAINER_STOP_ROOT), with systemctl stubbed:
#   1. Fresh: the unit is ordered after user@<uid>.service, runs as the
#      installing account with its XDG_RUNTIME_DIR, stops only the sk-*
#      containers signalk-container creates, and is enabled and started.
#   2. A re-run without sudo changes nothing; one that finds the unit on
#      disk but inactive or disabled enables and starts it again; an older
#      unit is rewritten.
#   3. SIGNALK_CONTAINER_NAMESPACE picks the prefix; an invalid one is sk.
#   4. No sudo: nothing written.
#   5. docs/recovery.md and both uninstallers name the unit.
# Run from the repo root.

set -euo pipefail
# The step reads the namespace from the environment; the cases below set it.
unset SIGNALK_CONTAINER_NAMESPACE

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
STEP=$(awk '/^section "Stop plugin containers at shutdown"/{p=1} p{print} /^# ── end of container stop ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of container stop'* ]]; then
    echo "[ERR] could not extract the container stop step from $INSTALL_SH" >&2
    exit 2
fi

mkdir -p "$tmp/bin"
for t in bash cat dirname id install mkdir; do
    ln -s "$(command -v "$t")" "$tmp/bin/$t"
done
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/podman"
# `enable` and `start` mark the unit enabled and active; `is-enabled` and
# `is-active` report that and are not logged.
cat >"$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "is-active --quiet signalk-container-stop.service")
        [[ -e "$CONTAINER_STOP_ROOT/active" ]] ;;
    "is-enabled --quiet signalk-container-stop.service")
        [[ -e "$CONTAINER_STOP_ROOT/enabled" ]] ;;
    "enable signalk-container-stop.service")
        echo "systemctl $*" >>"$STUB_LOG"
        : >"$CONTAINER_STOP_ROOT/enabled" ;;
    "start signalk-container-stop.service")
        echo "systemctl $*" >>"$STUB_LOG"
        : >"$CONTAINER_STOP_ROOT/active" ;;
    *)
        echo "systemctl $*" >>"$STUB_LOG" ;;
esac
STUB
chmod +x "$tmp/bin/systemctl" "$tmp/bin/podman"

# run_step <name> <sudo> — runs the step in the sandbox $tmp/<name>, which the
# caller may have seeded.
run_step() {
    local root="$tmp/$1"
    mkdir -p "$root"
    : >"$root/log"
    out=$(SIGNALK_CONTAINER_NAMESPACE="${SIGNALK_CONTAINER_NAMESPACE:-}" CONTAINER_STOP_ROOT="$root" STUB_LOG="$root/log" PATH="$tmp/bin" SUDO="$2" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; info() { echo "info: $*"; }; warn() { echo "warn: $*"; }
        '"$STEP" 2>&1) || { miss "$1: step exited non-zero: $out"; return 0; }
    log=$(cat "$root/log")
}

unit_path() { echo "$tmp/$1/etc/systemd/system/signalk-container-stop.service"; }
unit_of() { cat "$(unit_path "$1")" 2>/dev/null; }
uid=$(id -u)
user=$(id -un)
want_log=$'systemctl daemon-reload\nsystemctl enable signalk-container-stop.service\nsystemctl start signalk-container-stop.service'

echo "set up"
run_step fresh ""
unit=$(unit_of fresh)
if [[ "$unit" == *"After=user@${uid}.service"* && "$unit" == *"User=${user}"* \
    && "$unit" == *"Environment=XDG_RUNTIME_DIR=/run/user/${uid}"* \
    && "$unit" == *$'Type=oneshot\nRemainAfterExit=yes'* \
    && "$unit" == *"WantedBy=multi-user.target"* ]]; then
    ok "unit stops before user@${uid}.service and runs as ${user}"
else
    miss "fresh unit: [$unit]"
fi
if [[ "$unit" == *"ExecStop=/bin/sh -c 'ids=\$\$(\"$tmp/bin/podman\" ps -q --filter name=^sk-) || exit 1; [ -z \"\$\$ids\" ] || exec \"$tmp/bin/podman\" stop \$\$ids'"* ]]; then
    ok "ExecStop stops only the sk-* containers, with podman's absolute path"
else
    miss "ExecStop: [$(grep ExecStop <<<"$unit")]"
fi
if [[ "$log" == "$want_log" && "$out" == *"stop before the user manager"* ]]; then
    ok "unit enabled and started"
else
    miss "fresh: log=[$log] out=[$out]"
fi
if [[ "$(stat -c %a "$(unit_path fresh)" 2>/dev/null)" == 644 ]]; then
    ok "unit is 0644, so a re-run can compare it without sudo"
else
    miss "unit mode $(stat -c %a "$(unit_path fresh)" 2>/dev/null)"
fi

run_step fresh MISSING
if [[ "$out" == *"(skipping)"* && -z "$log" ]]; then
    ok "re-run: nothing to do, sudo never touched"
else
    miss "re-run: out=[$out] log=[$log]"
fi

rm "$tmp/fresh/active"
run_step fresh ""
if [[ "$log" == "$want_log" ]]; then
    ok "unit on disk but inactive: enabled and started again"
else
    miss "inactive: out=[$out] log=[$log]"
fi

rm "$tmp/fresh/enabled"
run_step fresh ""
if [[ "$log" == "$want_log" ]]; then
    ok "unit active but disabled: enabled again"
else
    miss "disabled: out=[$out] log=[$log]"
fi

mkdir -p "$(dirname "$(unit_path older)")"
printf '# an older unit\n' >"$(unit_path older)"
: >"$tmp/older/active"
: >"$tmp/older/enabled"
run_step older ""
if [[ "$(unit_of older)" == "$(unit_of fresh)" && "$log" == "$want_log" ]]; then
    ok "an older unit: rewritten"
else
    miss "older: unit=[$(unit_of older)] log=[$log]"
fi

echo "namespace"
SIGNALK_CONTAINER_NAMESPACE=devpod run_step devpod ""
if [[ "$(unit_of devpod)" == *"--filter name=^devpod-)"* ]]; then
    ok "SIGNALK_CONTAINER_NAMESPACE=devpod: stops devpod-* containers"
else
    miss "devpod: [$(grep ExecStop <<<"$(unit_of devpod)")]"
fi
SIGNALK_CONTAINER_NAMESPACE='bad ns!' run_step badns ""
if [[ "$(unit_of badns)" == *"--filter name=^sk-)"* ]]; then
    ok "an invalid namespace falls back to sk"
else
    miss "badns: [$(grep ExecStop <<<"$(unit_of badns)")]"
fi

echo "not set up"
run_step nosudo MISSING
if [[ -z "$(unit_of nosudo)" && -z "$log" && "$out" == *"without sudo"* ]]; then
    ok "no sudo: warns, writes nothing"
else
    miss "nosudo: log=[$log] out=[$out]"
fi

echo "docs and uninstall"
for f in docs/recovery.md installer/linux/signalk.tmpl scripts/uninstall.sh; do
    if grep -qF /etc/systemd/system/signalk-container-stop.service "$f" \
        && grep -qF 'systemctl disable --now signalk-container-stop.service' "$f"; then
        ok "$f names the unit and disables and stops it"
    else
        miss "$f does not name /etc/systemd/system/signalk-container-stop.service"
    fi
done

if (( fail )); then
    echo "[FAIL] check-container-stop"
    exit 1
fi
echo "[PASS] check-container-stop"
