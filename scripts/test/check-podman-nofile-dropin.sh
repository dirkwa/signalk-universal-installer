#!/usr/bin/env bash
# Verifies install.sh's podman.service open-files step against a sandbox
# HOME with systemctl stubbed:
#   1. A fresh run writes ~/.config/systemd/user/podman.service.d/zz-nofile.conf
#      with LimitNOFILE=1048576, runs daemon-reload and lists the file in
#      the reboot advisory.
#   2. A second run is idempotent: no rewrite, no daemon-reload, no advisory.
#   3. A drop-in with another value is rewritten, reloaded and listed.
#   4. When `systemctl --user show` still reports a lower LimitNOFILE (a
#      drop-in sorting after zz-nofile.conf), the step warns; a numeric
#      1048576 or "infinity" keeps it quiet.
#   5. When daemon-reload fails, the step does not blame a drop-in.
#   6. A re-run after a failed reload (NeedDaemonReload=yes) reloads, then
#      checks; without a successful reload it still blames nothing.
# Whether the running podman.service and its containers get the limit needs
# a live user session and is verified manually.
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

# Lift the step, and the drop-in directory step 4b-ter defines, out of
# install.sh so the test tracks the real source.
LIMITS_DIR_LINE=$(grep -m1 '^PODMAN_LIMITS_DIR=' "$INSTALL_SH")
if [[ -z "$LIMITS_DIR_LINE" ]]; then
    echo "[ERR] could not find PODMAN_LIMITS_DIR in $INSTALL_SH" >&2
    exit 2
fi
STEP=$(awk '/^PODMAN_NOFILE_CONF=/{p=1} p{print} /^# ── end of podman.service open-files limit ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of podman.service open-files limit'* ]]; then
    echo "[ERR] could not extract the podman.service open-files step from $INSTALL_SH" >&2
    exit 2
fi

mkdir -p "$tmp/bin"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [[ "$*" == *" show podman.service -p NeedDaemonReload "* ]]; then
    echo "${NEED_RELOAD:-no}"
elif [[ "$*" == *" show podman.service "* ]]; then
    echo "$SHOW_VALUE"
fi
if [[ "$*" == "--user daemon-reload" && -n "${RELOAD_FAILS:-}" ]]; then
    exit 1
fi
STUB
chmod +x "$tmp/bin/systemctl"
export STUB_LOG="$tmp/systemctl.log"

CONF_REL=".config/systemd/user/podman.service.d/zz-nofile.conf"

# run_step <home> <value `systemctl --user show` reports>
run_step() {
    : > "$STUB_LOG"
    HOME="$1" SHOW_VALUE="$2" PATH="$tmp/bin:$PATH" bash -c '
        set -euo pipefail
        ok() { echo "ok: $1"; }; warn() { echo "warn: $1"; }
        '"$LIMITS_DIR_LINE"'
        USER_SERVICE_RELOGIN_HINT=0
        USER_SERVICE_OVERRIDES=""
        '"$STEP"'
        echo "hint=$USER_SERVICE_RELOGIN_HINT"
        echo "overrides=$USER_SERVICE_OVERRIDES"
    ' 2>&1
}

echo "== fresh run"
home="$tmp/fresh"
mkdir -p "$home"
out=$(run_step "$home" 1048576)
if [[ "$(cat "$home/$CONF_REL" 2>/dev/null)" == $'[Service]\nLimitNOFILE=1048576' ]]; then
    ok "writes [Service] LimitNOFILE=1048576"
else
    miss "drop-in content wrong: $(cat "$home/$CONF_REL" 2>/dev/null || echo '<missing>')"
fi
if grep -qx -- '--user daemon-reload' "$STUB_LOG"; then ok "runs daemon-reload"; else miss "no daemon-reload"; fi
if [[ "$out" == *"hint=1"* && "$out" == *"overrides=  • $home/$CONF_REL (podman.service open-files limit 1048576)"* ]]; then
    ok "lists the drop-in in the reboot advisory"
else
    miss "advisory not set: $out"
fi
if [[ "$out" == *"warn:"* ]]; then miss "warned on a fresh run: $out"; else ok "no warning"; fi

echo "== second run"
before=$(stat -c %Y "$home/$CONF_REL")
sleep 1
out=$(run_step "$home" 1048576)
if [[ "$(stat -c %Y "$home/$CONF_REL")" == "$before" ]]; then ok "no rewrite"; else miss "drop-in rewritten"; fi
if grep -q 'daemon-reload' "$STUB_LOG"; then miss "daemon-reload on a re-run"; else ok "no daemon-reload"; fi
if [[ "$out" == *"hint=0"* && "$out" == *"already raised"* ]]; then ok "reports it as present, no advisory"; else miss "re-run output: $out"; fi

echo "== drop-in with another value"
home="$tmp/other"
mkdir -p "$home/$(dirname "$CONF_REL")"
printf '[Service]\nLimitNOFILE=65536\n' > "$home/$CONF_REL"
out=$(run_step "$home" 1048576)
if grep -qx 'LimitNOFILE=1048576' "$home/$CONF_REL"; then ok "rewritten to 1048576"; else miss "not rewritten: $(cat "$home/$CONF_REL")"; fi
if grep -qx -- '--user daemon-reload' "$STUB_LOG"; then ok "runs daemon-reload"; else miss "no daemon-reload after the rewrite"; fi
if [[ "$out" == *"hint=1"* ]]; then ok "lists the rewritten drop-in"; else miss "advisory not set after the rewrite: $out"; fi

echo "== overriding drop-in"
out=$(run_step "$tmp/fresh" 65535)
if [[ "$out" == *"warn: podman.service gets LimitNOFILE=65535 from a drop-in"* ]]; then
    ok "warns about the lower value"
else
    miss "no warning for 65535: $out"
fi

echo "== infinity"
out=$(run_step "$tmp/fresh" infinity)
if [[ "$out" == *"warn:"* ]]; then miss "warned for infinity: $out"; else ok "quiet for infinity"; fi

echo "== daemon-reload fails"
home="$tmp/noreload"
mkdir -p "$home"
out=$(RELOAD_FAILS=1 run_step "$home" 65535)
if [[ "$out" == *"warn: podman.service gets"* ]]; then miss "blamed a drop-in although the reload failed: $out"; else ok "no drop-in blamed"; fi

echo "== re-run after the failed reload"
out=$(NEED_RELOAD=yes RELOAD_FAILS=1 run_step "$home" 65535)
if [[ "$out" == *"warn: podman.service gets"* ]]; then miss "blamed a drop-in although it is still not loaded: $out"; else ok "no drop-in blamed while the reload keeps failing"; fi
out=$(NEED_RELOAD=yes run_step "$home" 65535)
if grep -qx -- '--user daemon-reload' "$STUB_LOG"; then ok "reloads the pending drop-in"; else miss "no daemon-reload for a pending drop-in"; fi
if [[ "$out" == *"warn: podman.service gets LimitNOFILE=65535"* ]]; then ok "checks the value once loaded"; else miss "no check after the reload: $out"; fi

exit "$fail"
