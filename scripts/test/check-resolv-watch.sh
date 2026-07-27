#!/usr/bin/env bash
# Verifies the container-DNS self-heal wiring (signalk resolv-watch).
#
# The real heal needs a live stack (podman + a user systemd session), so CI
# checks what CAN be verified host-independently:
#   1. `signalk resolv-watch` lays down both user units (content + enable
#      --now) against a sandbox HOME with systemctl stubbed, and a second
#      run is idempotent (no rewrite, no second enable).
#   2. The oneshot delegates to `signalk resolv-watch heal` (no podman or
#      systemctl in the unit text), and the heal's guard chain — exercised
#      with stubs — restarts only when the host has DNS and the running
#      container has none, via the sanctioned restart helper.
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

# /etc/resolv.conf alone is not enough: on symlink layouts the inotify
# watch follows the link at setup time, so a dangling or rename-swapped
# /run target escapes it. The unit must also watch the well-known
# runtime targets of every mainstream resolver stack.
watch_ok=1
for p in \
    /etc/resolv.conf \
    /run/systemd/resolve/stub-resolv.conf \
    /run/systemd/resolve/resolv.conf \
    /run/NetworkManager/resolv.conf \
    /run/resolvconf/resolv.conf; do
    grep -q "^PathChanged=${p}\$" "$path_unit" 2>/dev/null || watch_ok=0
done
if [[ "$watch_ok" == 1 ]] \
    && grep -q '^WantedBy=default\.target$' "$path_unit" 2>/dev/null; then
    ok "path unit watches /etc/resolv.conf + all runtime resolver targets"
else
    miss "path unit watch list incomplete"
    grep '^PathChanged=' "$path_unit" 2>/dev/null | sed 's/^/         /'
fi

if grep -q 'daemon-reload' "$SYSTEMCTL_LOG" \
    && grep -q -- '--user enable --now signalk-resolv-watch.path' "$SYSTEMCTL_LOG"; then
    ok "daemon-reload + enable --now issued"
else
    miss "expected systemctl calls not recorded"
    sed 's/^/         /' "$SYSTEMCTL_LOG"
fi

# ── 2. Oneshot delegates to the CLI — no direct lifecycle calls ─────────────
# The unit text must carry no podman/systemctl of its own: recovery goes
# through `signalk resolv-watch heal`, which routes the restart via the
# sanctioned path (updater REST first, systemctl fallback).

if grep -q '^ExecStart=%h/\.local/bin/signalk resolv-watch heal$' "$svc_unit" 2>/dev/null \
    && grep -q '^ConditionPathExists=%h/\.local/bin/signalk$' "$svc_unit" 2>/dev/null \
    && ! grep -v '^#' "$svc_unit" | grep -Eq 'podman|systemctl'; then
    ok "oneshot delegates to 'signalk resolv-watch heal'; unit text has no podman/systemctl"
else
    miss "oneshot must delegate to the CLI without direct podman/systemctl calls"
    sed 's/^/         /' "$svc_unit" 2>/dev/null || true
fi

# ── 3. Heal guard chain (behavioral, stubbed) ───────────────────────────────
# Source the CLI functions with the dispatcher stripped (same technique as
# check-render-server.sh), stub podman + the restart helper, and drive the
# guards through the resolv-conf test seam. The restart must fire ONLY when
# the host has a nameserver and the running container has none.

funcs="$tmp/funcs.sh"
sed '/^case "${1:-help}" in/,$d' "$CLI_TMPL" | sed 's/__SK_VERSION__/test/g' >"$funcs"
if ! grep -q '^_signalk_resolv_heal()' "$funcs"; then
    echo "[ERR] _signalk_resolv_heal not found after stripping the dispatcher." >&2
    exit 2
fi

resolv_ok="$tmp/resolv-ok"
echo "nameserver 192.168.0.1" >"$resolv_ok"
resolv_empty="$tmp/resolv-empty"
: >"$resolv_empty"

run_heal() {
    # $1 = resolv fixture, $2 = container state: down | nodns | dns
    rm -f "$tmp/restart.log"
    SIGNALK_RESOLV_CONF="$1" CONTAINER_STATE="$2" MARK="$tmp" bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        . "'"$funcs"'"
        # Stubs AFTER the source, or the real definitions would clobber them.
        podman() {
            case "$*" in
                "exec signalk-server true") [[ "$CONTAINER_STATE" != down ]] ;;
                *grep*) [[ "$CONTAINER_STATE" == dns ]] ;;
                *) return 0 ;;
            esac
        }
        _signalk_restart_server() { echo restart >>"$MARK/restart.log"; }
        _signalk_resolv_heal
    ' >/dev/null
}

heal_case() {
    local desc="$1" resolv="$2" state="$3" want_restart="$4" got=0
    run_heal "$resolv" "$state"
    [[ -f "$tmp/restart.log" ]] && got=1
    if [[ "$got" == "$want_restart" ]]; then
        ok "heal: $desc"
    else
        miss "heal: $desc (restart fired: $got, want $want_restart)"
    fi
}

heal_case "no host nameserver → no restart" "$resolv_empty" nodns 0
heal_case "container not running → no restart" "$resolv_ok" down 0
heal_case "container already has DNS → no restart" "$resolv_ok" dns 0
heal_case "container missing DNS → restart fires" "$resolv_ok" nodns 1

# ── 4. Second run is idempotent ─────────────────────────────────────────────

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

# ── 5. Server Quadlet template carries the bounded pre-start wait ───────────

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
