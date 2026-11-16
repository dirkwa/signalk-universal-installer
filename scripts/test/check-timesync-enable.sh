#!/usr/bin/env bash
# Runs install.sh's signalk-timesync step (17b) against a scratch root with a
# stub systemctl, and checks that a re-run with every file already in place
# enables a timer that was switched off, and leaves an enabled one alone
# without calling sudo.
#
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

# check <ok text> <miss text> <command...>
check() {
    local good=$1 bad=$2
    shift 2
    if "$@"; then echo "  [OK]   $good"; else echo "  [MISS] $bad"; fail=1; fi
}

# The step, from its section line to the line before 17c, with the host paths
# moved under the scratch root.
step="$tmp/step.sh"
awk '/^section "Time & timezone sync/ { on = 1 } /^# 17c\./ { on = 0 } on' "$INSTALL_SH" \
    | sed -e "s#/usr/local/bin/signalk-timesync#$tmp/bin/signalk-timesync#g" \
          -e "s#/etc/systemd/system/#$tmp/units/#g" >"$step"
grep -q 'TIMESYNC_TIMER=' "$step" || { echo "[ERR] could not extract step 17b" >&2; exit 2; }
mkdir -p "$tmp/bin" "$tmp/units" "$tmp/path"

# Stub systemctl: is-enabled/is-active answer from $tmp/state, enable records
# itself and switches the state on.
cat >"$tmp/path/systemctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
    is-enabled|is-active) [[ "\$(cat "$tmp/state")" == on ]] ;;
    enable) echo "\$*" >>"$tmp/calls"; echo on >"$tmp/state" ;;
    daemon-reload) echo daemon-reload >>"$tmp/calls" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmp/path/systemctl"

run_step() {
    : >"$tmp/calls"
    : >"$tmp/out"
    PATH="$tmp/path:$PATH" HERE="installer/linux" USER=tester SK_HTTP_PORT=3000 \
        SUDO="$tmp/sudo" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; info() { echo "info: $*"; }; warn() { echo "warn: $*"; }
        install_stdin() { local src; src=$(mktemp); cat >"$src"; $SUDO install "${@:1:$#-1}" "$src" "${!#}"; rm -f "$src"; }
        . "$1"' _ "$step" >"$tmp/out"
}

# sudo stub: counts its use, drops -o/-g (no root here), runs the rest.
cat >"$tmp/sudo" <<EOF
#!/usr/bin/env bash
echo sudo >>"$tmp/sudo-calls"
args=()
while (( \$# )); do
    case "\$1" in -o|-g) shift 2 ;; *) args+=("\$1"); shift ;; esac
done
PATH="$tmp/path:\$PATH" "\${args[@]}"
EOF
chmod +x "$tmp/sudo"

echo "[i] fresh install writes the files and enables the timer"
echo off >"$tmp/state"
run_step
check "agent and units written" "agent and units not written" \
    test -s "$tmp/bin/signalk-timesync" -a -s "$tmp/units/signalk-timesync.timer"
check "timer enabled" "timer not enabled" \
    grep -q 'enable --now signalk-timesync.timer' "$tmp/calls"

echo "[i] re-run with the timer still on changes nothing and does not use sudo"
: >"$tmp/sudo-calls"
run_step
check "no systemctl change" "systemctl changed the timer" test ! -s "$tmp/calls"
check "no sudo" "sudo used on a no-op run" test ! -s "$tmp/sudo-calls"
check "reports skipping" "no skip message" grep -q 'already installed' "$tmp/out"

echo "[i] re-run after the timer was switched off enables it again"
echo off >"$tmp/state"
run_step
check "timer enabled again" "switched-off timer left off" \
    grep -q 'enable --now signalk-timesync.timer' "$tmp/calls"
check "files not rewritten" "unchanged files were rewritten" \
    test "$(grep -c daemon-reload "$tmp/calls" || true)" = 0

if (( fail )); then
    echo "[FAIL] timesync enable checks failed"
    exit 1
fi
echo "[PASS] timesync enable checks"
