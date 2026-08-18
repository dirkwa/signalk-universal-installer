#!/usr/bin/env bash
# Verifies install.sh's `podman system migrate` handling against stubs:
#   1. podman_migrate stops podman.service before AND after the migrate when
#      the service is active — and never touches or masks podman.socket.
#   2. podman_migrate leaves systemctl alone when podman.service is inactive.
#   3. The subuid/subgid step calls podman_migrate only when a range was
#      actually added; a re-run with both ranges present migrates nothing.
#   4. Every `podman system migrate` in install.sh lives inside podman_migrate.
# Background: a migrate kills the rootless pause process; a socket-activated
# podman.service that survives it keeps its old user namespace, and containers
# created over the socket before the service restarts become unstoppable
# ("operation not permitted") once it does. Run from the repo root.

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

# Lift the function and the subuid/subgid step out of install.sh so the test
# tracks the real source. The step spans from the podman_migrate definition
# to the `podman_migrate` gate that closes it.
STEP=$(awk '/^podman_migrate\(\) \{/{p=1} p{print} p && /^if \(\( subid_ranges_added \)\); then/{getline; print; getline; print; exit}' "$INSTALL_SH")
if [[ -z "$STEP" ]] || ! grep -q 'usermod --add-subgids' <<<"$STEP"; then
    echo "[ERR] could not extract the subuid/subgid step from $INSTALL_SH" >&2
    exit 2
fi
# Point the range checks at a sandbox /etc.
STEP=${STEP//\/etc\/subuid/$tmp/etc/subuid}
STEP=${STEP//\/etc\/subgid/$tmp/etc/subgid}

mkdir -p "$tmp/bin" "$tmp/etc"
cat > "$tmp/bin/podman" <<'STUB'
#!/usr/bin/env bash
echo "podman $*" >> "$STUB_LOG"
STUB
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
if [[ "$*" == *"is-active"* ]]; then
    [[ "${PODMAN_SERVICE_ACTIVE:-1}" == 1 ]]
fi
STUB
cat > "$tmp/bin/usermod" <<'STUB'
#!/usr/bin/env bash
echo "usermod $*" >> "$STUB_LOG"
STUB
chmod +x "$tmp/bin/podman" "$tmp/bin/systemctl" "$tmp/bin/usermod"
export STUB_LOG="$tmp/calls.log"

run_step() {
    : > "$STUB_LOG"
    PATH="$tmp/bin:$PATH" USER=tester SUDO="" bash -c "
        set -euo pipefail
        ok() { :; }; warn() { echo \"warn: \$1\"; }; info() { :; }
        $STEP
        $1
    " >/dev/null
}

# Both ranges present so the step itself is a no-op and only the explicit
# podman_migrate call reaches the stubs.
printf 'tester:100000:65536\n' > "$tmp/etc/subuid"
printf 'tester:100000:65536\n' > "$tmp/etc/subgid"

echo "== podman_migrate with podman.service active"
PODMAN_SERVICE_ACTIVE=1 run_step "podman_migrate"
if grep -q '^podman system migrate$' "$STUB_LOG"; then ok "runs podman system migrate"; else miss "podman system migrate not called"; fi
if grep -q 'podman.socket' "$STUB_LOG"; then miss "touched podman.socket"; else ok "podman.socket untouched"; fi
if grep -q ' mask ' "$STUB_LOG"; then miss "masked a unit"; else ok "nothing masked"; fi
seq=$(grep -o 'stop podman.service\|system migrate' "$STUB_LOG" | tr '\n' ',')
if [[ "$seq" == "stop podman.service,system migrate,stop podman.service," ]]; then
    ok "stop → migrate → stop"
else
    miss "unexpected call order: $seq"
fi

echo "== podman_migrate with podman.service inactive"
PODMAN_SERVICE_ACTIVE=0 run_step "podman_migrate"
if grep -q '^podman system migrate$' "$STUB_LOG"; then ok "runs podman system migrate"; else miss "podman system migrate not called"; fi
if grep -q 'stop podman.service' "$STUB_LOG"; then miss "stopped an inactive podman.service"; else ok "no stop when inactive"; fi

echo "== subuid/subgid step: re-run with both ranges present"
PODMAN_SERVICE_ACTIVE=1 run_step ":"
if grep -q 'usermod' "$STUB_LOG"; then miss "usermod called although ranges exist"; else ok "no usermod"; fi
if grep -q 'system migrate' "$STUB_LOG"; then miss "migrated on a re-run"; else ok "no migrate on a re-run"; fi
if grep -q 'stop podman.service' "$STUB_LOG"; then miss "stopped podman.service on a re-run"; else ok "podman.service left running"; fi

echo "== subuid/subgid step: fresh host without a subgid range"
: > "$tmp/etc/subgid"
PODMAN_SERVICE_ACTIVE=1 run_step ":"
if grep -q '^usermod --add-subgids 100000-165535 tester$' "$STUB_LOG"; then ok "adds the subgid range"; else miss "subgid range not added"; fi
if grep -q 'add-subuids' "$STUB_LOG"; then miss "re-added an existing subuid range"; else ok "existing subuid range kept"; fi
if grep -q '^podman system migrate$' "$STUB_LOG"; then ok "migrates after adding a range"; else miss "no migrate after adding a range"; fi
if grep -q '^systemctl --user stop podman.service$' "$STUB_LOG"; then ok "stops podman.service after the migrate"; else miss "podman.service not stopped after the migrate"; fi

echo "== every migrate call goes through podman_migrate"
bare=$(grep -n 'podman system migrate' "$INSTALL_SH" | grep -v 'warn "' | grep -v '^[0-9]*:#' || true)
if [[ "$(wc -l <<<"$bare" | tr -d ' ')" == 1 ]] && grep -q 'podman system migrate >/dev/null 2>&1 || true' <<<"$bare"; then
    ok "single call site (inside podman_migrate)"
else
    miss "bare migrate call(s): $bare"
fi

exit "$fail"
