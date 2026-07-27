#!/usr/bin/env bash
# Verifies the container-DNS self-heal wiring (signalk resolv-watch).
#
# The real heal needs a live stack (podman + a user systemd session), so CI
# checks what CAN be verified host-independently:
#   1. `signalk resolv-watch` lays down both user units (content + enable
#      --now) against a sandbox HOME with systemctl stubbed, and a second
#      run is idempotent (no rewrite, no second enable).
#   2. The oneshot's guard chain runs in the safe order: host-nameserver →
#      container-running → container-nameserver, and only then try-restart.
#   3. The server Quadlet template carries the bounded ExecStartPre resolv
#      wait and always exits 0 (an offline host must still start).
#
# Run from the repo root.

set -euo pipefail

CLI_TMPL="${CLI_TMPL:-installer/linux/signalk.tmpl}"
QUADLET_TMPL="${QUADLET_TMPL:-quadlets/signalk-server.container.template}"
for f in "$CLI_TMPL" "$QUADLET_TMPL"; do
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

# ── Sandbox: fake HOME + a systemctl stub that records calls ────────────────

export HOME="$tmp/home"
mkdir -p "$HOME"
export SYSTEMCTL_LOG="$tmp/systemctl.log"
export SYSTEMCTL_STATE="$tmp/systemctl-state"
mkdir -p "$tmp/bin" "$SYSTEMCTL_STATE"
: >"$SYSTEMCTL_LOG"
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
    *is-enabled*) [[ -f "$SYSTEMCTL_STATE/enabled" ]] || exit 1 ;;
    *"enable --now"*) touch "$SYSTEMCTL_STATE/enabled" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH"

unit_dir="$HOME/.config/systemd/user"
path_unit="$unit_dir/signalk-resolv-watch.path"
svc_unit="$unit_dir/signalk-resolv-watch.service"

# ── 1. First run installs + enables both units ──────────────────────────────

out1=$(bash "$CLI_TMPL" resolv-watch 2>&1) || {
    echo "[ERR] 'signalk resolv-watch' failed:" >&2
    printf '%s\n' "$out1" >&2
    exit 1
}

if [[ -f "$path_unit" && -f "$svc_unit" ]]; then
    ok "both units written under ~/.config/systemd/user"
else
    miss "unit files missing after first run"
fi

if grep -q '^PathChanged=/etc/resolv\.conf$' "$path_unit" 2>/dev/null \
    && grep -q '^WantedBy=default\.target$' "$path_unit" 2>/dev/null; then
    ok "path unit watches /etc/resolv.conf and installs into default.target"
else
    miss "path unit content unexpected"
fi

if grep -q 'daemon-reload' "$SYSTEMCTL_LOG" \
    && grep -q -- '--user enable --now signalk-resolv-watch.path' "$SYSTEMCTL_LOG"; then
    ok "daemon-reload + enable --now issued"
else
    miss "expected systemctl calls not recorded"
    sed 's/^/         /' "$SYSTEMCTL_LOG"
fi

# ── 2. Oneshot guard chain, in order ────────────────────────────────────────

execline=$(grep '^ExecStart=' "$svc_unit" 2>/dev/null || true)
if printf '%s' "$execline" | grep -Eq \
    'nameserver" /etc/resolv\.conf \|\| exit 0;.*podman exec signalk-server true.*\|\| exit 0;.*podman exec signalk-server grep.*nameserver.*&& exit 0;.*try-restart signalk-server\.service'; then
    ok "oneshot guards: host-DNS → container-running → container-DNS → try-restart"
else
    miss "oneshot ExecStart guard chain not in the expected order"
    printf '         %s\n' "$execline"
fi

# ── 3. Second run is idempotent ─────────────────────────────────────────────

out2=$(bash "$CLI_TMPL" resolv-watch 2>&1) || {
    echo "[ERR] second 'signalk resolv-watch' run failed" >&2
    exit 1
}
if printf '%s' "$out2" | grep -q 'already installed'; then
    ok "second run reports already installed"
else
    miss "second run did not short-circuit"
    printf '         %s\n' "$out2"
fi
enables=$(grep -c -- 'enable --now signalk-resolv-watch.path' "$SYSTEMCTL_LOG" || true)
if [[ "$enables" == "1" ]]; then
    ok "enable --now issued exactly once across both runs"
else
    miss "enable --now issued $enables times (want 1)"
fi

# ── 4. Server Quadlet template carries the bounded pre-start wait ───────────

# One directive, and that same directive must be a BOUNDED wait (a finite
# `for` list, not an open-ended loop) that always exits 0 — an unbounded or
# non-fail-safe variant would block server startup on offline boats.
prestart_count=$(grep -c '^ExecStartPre=' "$QUADLET_TMPL" || true)
prestart=$(grep '^ExecStartPre=' "$QUADLET_TMPL" || true)
if [[ "$prestart_count" == "1" ]] \
    && printf '%s' "$prestart" | grep -Eq \
        'for _ in [0-9 ]+; do grep -qs "\^nameserver" /etc/resolv\.conf && break; sleep 1; done; exit 0'; then
    ok "template ExecStartPre: single bounded resolver wait, always exits 0"
else
    miss "template ExecStartPre resolver wait missing, unbounded, or not fail-safe"
    printf '         count=%s %s\n' "$prestart_count" "$prestart"
fi

if [[ "$fail" == 0 ]]; then
    echo "[PASS] resolv-watch wiring checks"
else
    echo "[FAIL] resolv-watch wiring checks" >&2
    exit 1
fi
