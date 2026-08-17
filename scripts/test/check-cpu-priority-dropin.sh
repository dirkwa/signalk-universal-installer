#!/usr/bin/env bash
# Verifies install.sh's app.slice CPU-priority step and its uninstall twin
# against a sandbox HOME with systemctl/podman stubbed:
#   1. The step writes ~/.config/systemd/user/app.slice.d/50-signalk-cpu-priority.conf
#      as a [Slice] drop-in with CPUWeight=300 and runs daemon-reload once.
#   2. A second run is idempotent: no rewrite, no second daemon-reload.
#   3. uninstall.sh removes the drop-in and resets the live weight
#      (`set-property --runtime app.slice CPUWeight=100`) — deleting the file
#      alone leaves the running slice at 300 until re-login.
# The kernel-side effect (cpu.weight reads 300 after daemon-reload) needs a
# live user session and is verified manually.
# Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}
UNINSTALL_SH=${UNINSTALL_SH:-scripts/uninstall.sh}
for f in "$INSTALL_SH" "$UNINSTALL_SH"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# Lift the step out of install.sh so the test tracks the real source.
STEP=$(awk '/^section "CPU priority"/{p=1} p{print} p && /^fi$/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" ]]; then
    echo "[ERR] could not extract the CPU priority step from $INSTALL_SH" >&2
    exit 2
fi

mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
STUB
cat > "$tmp/bin/podman" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$tmp/bin/systemctl" "$tmp/bin/podman"
export STUB_LOG="$tmp/systemctl.log"
: > "$STUB_LOG"

run_step() {
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c "
        set -euo pipefail
        section() { :; }; ok() { echo \"ok: \$1\"; }; warn() { echo \"warn: \$1\"; }; info() { :; }
        $STEP
    "
}

CONF="$tmp/home/.config/systemd/user/app.slice.d/50-signalk-cpu-priority.conf"

# 1. First run writes the drop-in and reloads once.
out1=$(run_step)
if [[ -f "$CONF" ]]; then ok "drop-in written: ${CONF#"$tmp/home/"}"; else miss "drop-in not written"; fi
if grep -qx '\[Slice\]' "$CONF" 2>/dev/null && grep -qx 'CPUWeight=300' "$CONF" 2>/dev/null; then
    ok "drop-in is a [Slice] section with CPUWeight=300"
else
    miss "drop-in content unexpected: $(cat "$CONF" 2>/dev/null)"
fi
if [[ $(grep -c -- '--user daemon-reload' "$STUB_LOG") -eq 1 ]]; then
    ok "first run reloads the user manager once"
else
    miss "expected exactly one daemon-reload, log: $(cat "$STUB_LOG")"
fi
if [[ "$out1" == *"applied"* ]]; then ok "first run reports applied"; else miss "first run output: $out1"; fi

# 2. Second run is a no-op.
before=$(stat -c %Y "$CONF")
sleep 1
out2=$(run_step)
after=$(stat -c %Y "$CONF")
if [[ "$before" == "$after" ]]; then ok "second run leaves the file untouched"; else miss "second run rewrote the drop-in"; fi
if [[ $(grep -c -- '--user daemon-reload' "$STUB_LOG") -eq 1 ]]; then
    ok "second run does not reload again"
else
    miss "second run reloaded, log: $(cat "$STUB_LOG")"
fi
if [[ "$out2" == *"already set"* ]]; then ok "second run reports already set"; else miss "second run output: $out2"; fi

# 3. uninstall.sh removes the drop-in and resets the live weight.
: > "$STUB_LOG"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$UNINSTALL_SH" >/dev/null
if [[ ! -e "$CONF" ]]; then ok "uninstall removes the drop-in"; else miss "uninstall left $CONF"; fi
if grep -q -- 'set-property --runtime app.slice CPUWeight=100' "$STUB_LOG"; then
    ok "uninstall resets the live app.slice weight"
else
    miss "uninstall did not reset the live weight, log: $(cat "$STUB_LOG")"
fi

echo
if (( fail )); then echo "[FAIL] CPU priority drop-in checks failed"; exit 1; fi
echo "[PASS] CPU priority drop-in checks"
