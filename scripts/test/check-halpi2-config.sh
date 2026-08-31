#!/usr/bin/env bash
# Verifies `signalk halpi2 apply` (cmd_apply in signalk-halpi2.tmpl) against
# a fake root: every path the helper touches is env-overridable and every
# side-effecting command (sudo, apt-get, dpkg-query, systemctl, usermod,
# findmnt, i2ctransfer, dtparam, modprobe, curl) is a PATH shim that logs
# its arguments. Cases:
#   1. not a CM5 → nothing written, rc 0
#   2. confirmed over I2C, NVMe root, no terminal → packages installed,
#      config.txt block appended once with dtparam=sd=off, backup taken,
#      networkd/udev/modules files written, rc 2 (reboot)
#   3. re-run (offline) → nothing rewritten, no apt-get, no key fetch, rc 0
#   4. SD/eMMC root, /dev/root, or a failing findmnt → sd=off is NOT emitted
#   5. candidate only (controller silent), no terminal, auto → nothing
#      Hat-Labs-specific installed, config.txt untouched, recipe printed, rc 1
#   6. candidate + SIGNALK_HALPI2=yes → applied, rc 2
#   7. terminal answers "n" → declined; answers "y" → applied
#   8. stale block from an older template → replaced once, other sections kept;
#      a lone/duplicated marker → refused, file untouched
#   9. SIGNALK_HALPI2=no → nothing, rc 0
#  10. SIGNALK_HALPI2_BLINKENLIGHTS=no → apt-get install lacks blinkenlights-daemon
#
# Run from the repo root.

set -euo pipefail

TMPL=${TMPL:-installer/linux/signalk-halpi2.tmpl}
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

funcs="$root/funcs.sh"
# shellcheck disable=SC2016  # literal dispatcher line, no expansion wanted
sed '/^case "${1:-status}" in/,$d' "$TMPL" >"$funcs"
# shellcheck disable=SC2016
if grep -q '^case "${1:-status}" in' "$funcs"; then
    echo "[ERR] failed to strip the dispatcher from $TMPL — the sed pattern no longer matches." >&2
    exit 2
fi
if ! grep -q '^cmd_apply()' "$funcs"; then
    echo "[ERR] cmd_apply not found in $TMPL after stripping" >&2
    exit 2
fi

# ── shims ─────────────────────────────────────────────────────────────
bin="$root/bin"; mkdir -p "$bin"
LOG="$root/log"; mkdir -p "$LOG"
STATE="$root/state"; mkdir -p "$STATE"
: >"$STATE/installed"           # dpkg-query answers "installed" for names in here

shim() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$bin/$1"; chmod +x "$bin/$1"; }

# A PATH for cases that assert a tool is ABSENT. Mirrors the host's standard
# bin dirs by symlink, MINUS the binaries under test — so the template still
# has its coreutils (env, getent, findmnt, tee …) while `command -v
# i2ctransfer` genuinely finds nothing. Hand-listing what to include drifts:
# the first version omitted `env`, which ensure_i2c_tools calls, so its
# apt-get invocations failed with "env: command not found" and the test
# reached the right branch by the wrong route.
HERMETIC_BIN="$root/hermetic-bin"; mkdir -p "$HERMETIC_BIN"
HERMETIC_EXCLUDE="i2ctransfer dtparam modprobe udevadm"
for _d in /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin; do
    [[ -d "$_d" ]] || continue
    for _p in "$_d"/*; do
        [[ -x "$_p" && ! -d "$_p" ]] || continue
        _n=${_p##*/}
        case " $HERMETIC_EXCLUDE " in *" $_n "*) continue ;; esac
        [[ -e "$HERMETIC_BIN/$_n" ]] || ln -sf "$_p" "$HERMETIC_BIN/$_n"
    done
done
# shellcheck disable=SC2016  # shim bodies are literal scripts; $vars expand when the shim runs
{
shim sudo       'exec "$@"'
shim dpkg-query 'grep -qx "${!#}" "$STATE/installed" && echo "install ok installed" || exit 1'
shim apt-get    'echo "$*" >>"$LOG/apt-get"; if [[ "$1" == install ]]; then for a in "$@"; do case "$a" in -*|install) ;; *) echo "$a" >>"$STATE/installed";; esac; done; fi'
shim systemctl  'echo "$*" >>"$LOG/systemctl"; case "$*" in "is-active --quiet halpid") [[ "${SHIM_HALPID:-}" == active ]];; "is-enabled --quiet systemd-networkd") [[ -f "$STATE/networkd-enabled" ]];; "enable systemd-networkd") touch "$STATE/networkd-enabled";; *) exit 0;; esac'
shim usermod    'echo "$*" >>"$LOG/usermod"'
shim findmnt    'echo "${SHIM_ROOTDEV:-/dev/nvme0n1p2}"'
shim i2ctransfer 'echo "$*" >>"$LOG/i2ctransfer"; [[ "${SHIM_I2C:-ok}" == ok ]] || exit 1; case "$4" in 0x04) echo "0x03 0x03 0x01 0xff";; 0x03) echo "0x02 0x00 0x00 0xff";; esac'
# shellcheck disable=SC2016  # shim bodies are literal scripts; $vars expand when they run
shim dtparam    'echo "$*" >>"$LOG/dtparam"'
# shellcheck disable=SC2016
shim modprobe   'echo "$*" >>"$LOG/modprobe"'
shim curl       '[[ "${SHIM_CURL_FAIL:-0}" == 1 ]] && exit 22; echo "-----BEGIN PGP PUBLIC KEY BLOCK-----FAKE-----END PGP PUBLIC KEY BLOCK-----"'
}

printf 'Raspberry Pi Compute Module 5 Rev 1.0\0' >"$root/model-cm5"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$root/model-pi5"
printf 'PRETTY_NAME="Raspberry Pi OS"\nVERSION_CODENAME=trixie\n' >"$root/os-release"

reset_fs() {
    rm -rf "${root:?}/etc" "$root/i2c-1"
    mkdir -p "$root/etc"
    cat >"$root/config.txt" <<'EOF'
# For more options and information see
# http://rptl.io/configtxt
dtparam=audio=on
[cm4]
otg_mode=1
[all]
EOF
    rm -f "$root"/config.txt.bak.* "$LOG"/*
    : >"$STATE/installed"
    rm -f "$STATE/networkd-enabled"
}

# run_apply <extra env assignments...>  → prints rc, output in $root/out
run_apply() {
    set +e
    local _path="$bin:$PATH"
    # HERMETIC_PATH=1: $bin plus a private dir of symlinks to the coreutils the
    # script needs, and nothing else. Used by cases asserting a tool is ABSENT:
    # the default "$bin:$PATH" would let a host i2ctransfer satisfy `command -v`
    # once the shim is hidden, silently testing the wrong branch on any box
    # that really has i2c-tools.
    [[ "${HERMETIC_PATH:-0}" = "1" ]] && _path="$bin:$HERMETIC_BIN"
    # shellcheck disable=SC2016  # the -c body is sourced later, not expanded here
    env -i HOME="$root" PATH="$_path" USER=tester \
        DT_MODEL_FILE="$root/model-cm5" HALPI2_CONFIG_TXT="$root/config.txt" \
        HALPI2_ETC="$root" HALPI2_I2C_DEV="$root/i2c-1" HALPI2_RS485_DEV="$root/ttyAMA4" \
        HALPI2_OS_RELEASE="$root/os-release" HALPI2_TTY_IN=/nonexistent HALPI2_TTY_OUT=/nonexistent \
        HALPI2_APT_KEY_URL=fake://key STATE="$STATE" LOG="$LOG" NO_COLOR=1 \
        "$@" bash -c '. "$1"; cmd_apply' _ "$funcs" >"$root/out" 2>&1
    local rc=$?
    set -e
    echo "$rc"
}

block_count() { grep -cxF '# >>> signalk-installer halpi2 >>>' "$root/config.txt" || true; }

echo "check-halpi2-config: signalk halpi2 apply against a fake root"

# 1. not a CM5
reset_fs
rc=$(run_apply DT_MODEL_FILE="$root/model-pi5")
if [[ "$rc" == 0 ]]; then ok "non-CM5: rc 0"; else miss "non-CM5: rc $rc (want 0)"; fi
if [[ "$(block_count)" == 0 && ! -f "$LOG/apt-get" && ! -e "$root/etc/apt" ]]; then ok "non-CM5: nothing written"; else miss "non-CM5: wrote something"; fi

# 2. confirmed over I2C, NVMe, non-interactive
reset_fs
touch "$root/i2c-1"
rc=$(run_apply)
if [[ "$rc" == 2 ]]; then ok "confirmed/NVMe/no-tty: rc 2 (reboot)"; else miss "confirmed: rc $rc (want 2)"; cat "$root/out"; fi
if grep -q "apt.hatlabs.fi" "$root/etc/apt/sources.list.d/hatlabs.sources" 2>/dev/null && grep -q "^Suites: trixie-stable" "$root/etc/apt/sources.list.d/hatlabs.sources"; then ok "hatlabs.sources written with trixie-stable"; else miss "hatlabs.sources missing/wrong"; fi
if [[ -s "$root/etc/apt/keyrings/hatlabs.asc" ]]; then ok "apt key written"; else miss "apt key missing"; fi
if grep -q "^install .*halpid" "$LOG/apt-get" 2>/dev/null && grep -q "blinkenlights-daemon" "$LOG/apt-get"; then ok "apt-get install ran with halpid + blinkenlights-daemon"; else miss "apt-get install missing packages"; fi
if grep -q "^update" "$LOG/apt-get"; then ok "apt-get update ran before install"; else miss "apt-get update did not run"; fi
if [[ "$(block_count)" == 1 ]]; then ok "config.txt: block appended once"; else miss "config.txt: block count $(block_count)"; fi
if grep -qx 'dtparam=sd=off' "$root/config.txt"; then ok "config.txt: dtparam=sd=off present on NVMe root"; else miss "config.txt: sd=off missing on NVMe root"; fi
if grep -qx 'dtoverlay=mcp251xfd,spi0-1,interrupt=26,oscillator=40000000' "$root/config.txt"; then ok "config.txt: CAN overlay present"; else miss "config.txt: CAN overlay missing"; fi
if grep -qx 'otg_mode=1' "$root/config.txt"; then ok "config.txt: pre-existing lines kept"; else miss "config.txt: lost pre-existing lines"; fi
if ls "$root"/config.txt.bak.* >/dev/null 2>&1; then ok "config.txt: backup taken"; else miss "config.txt: no backup"; fi
if [[ "$(cat "$root/etc/modules-load.d/i2c-dev.conf")" == "i2c-dev" ]]; then ok "modules-load: i2c-dev"; else miss "modules-load missing"; fi
if grep -q "^BitRate=250000" "$root/etc/systemd/network/80-signalk-can0.network" 2>/dev/null && grep -q "^RestartSec=100ms" "$root/etc/systemd/network/80-signalk-can0.network"; then ok "80-signalk-can0.network written"; else miss "80-signalk-can0.network missing/wrong"; fi
if grep -q 'tx_queue_len' "$root/etc/udev/rules.d/80-signalk-can.rules" 2>/dev/null; then ok "udev rule written"; else miss "udev rule missing"; fi
if grep -q "enable systemd-networkd" "$LOG/systemctl"; then ok "systemd-networkd enabled"; else miss "systemd-networkd not enabled"; fi
if grep -q "w1@0x6d 0x04 r4" "$LOG/i2ctransfer"; then ok "controller probed at 0x6d"; else miss "controller not probed"; fi

# 3. re-run is a no-op — offline too (no key re-fetch once configured)
rm -f "$LOG"/*
before=$(sha256sum "$root/config.txt")
rc=$(run_apply SHIM_CURL_FAIL=1)
if [[ "$rc" == 0 ]]; then ok "re-run: rc 0"; else miss "re-run: rc $rc (want 0)"; cat "$root/out"; fi
if [[ "$(sha256sum "$root/config.txt")" == "$before" ]]; then ok "re-run: config.txt unchanged"; else miss "re-run: config.txt rewritten"; fi
if [[ ! -f "$LOG/apt-get" ]]; then ok "re-run: no apt-get"; else miss "re-run: apt-get ran"; fi
if [[ "$(find "$root" -maxdepth 1 -name "config.txt.bak.*" | wc -l)" == 1 ]]; then ok "re-run: no new backup"; else miss "re-run: extra backup"; fi

# 4. SD/eMMC root → no sd=off
reset_fs; touch "$root/i2c-1"
rc=$(run_apply SHIM_ROOTDEV=/dev/mmcblk0p2)
if [[ "$rc" == 2 ]]; then ok "SD root: rc 2"; else miss "SD root: rc $rc"; fi
if grep -qx 'dtparam=sd=off' "$root/config.txt"; then miss "SD root: sd=off emitted (would disable the boot device)"; else ok "SD root: sd=off omitted"; fi
if grep -q 'sd=off omitted' "$root/config.txt"; then ok "SD root: omission noted in the block"; else miss "SD root: omission note missing"; fi

# 4b. undeterminable boot device (/dev/root, or no findmnt) → no sd=off
reset_fs; touch "$root/i2c-1"
rc=$(run_apply SHIM_ROOTDEV=/dev/root)
if [[ "$rc" == 2 ]] && ! grep -qx 'dtparam=sd=off' "$root/config.txt"; then ok "/dev/root source: sd=off omitted (fail-safe)"; else miss "/dev/root source: rc $rc, sd=off present=$(grep -cx 'dtparam=sd=off' "$root/config.txt")"; fi
# findmnt failing / printing nothing (a shim that exits 1 — PATH still holds
# the host's coreutils, so removing the shim would just expose the real one)
reset_fs; touch "$root/i2c-1"; mv "$bin/findmnt" "$bin/findmnt.ok"
shim findmnt 'exit 1'
rc=$(run_apply)
if [[ "$rc" == 2 ]] && ! grep -qx 'dtparam=sd=off' "$root/config.txt"; then ok "findmnt failing: sd=off omitted (fail-safe)"; else miss "findmnt failing: rc $rc, sd=off present=$(grep -cx 'dtparam=sd=off' "$root/config.txt")"; fi
mv "$bin/findmnt.ok" "$bin/findmnt"

# 5. candidate only, non-interactive, auto → untouched
reset_fs
rc=$(run_apply SHIM_I2C=fail)
if [[ "$rc" == 1 ]]; then ok "candidate/no-tty/auto: rc 1"; else miss "candidate: rc $rc (want 1)"; cat "$root/out"; fi
if [[ "$(block_count)" == 0 ]]; then ok "candidate: config.txt untouched"; else miss "candidate: config.txt written"; fi
if grep -q "Manual recipe" "$root/out"; then ok "candidate: recipe printed"; else miss "candidate: no recipe"; fi
if grep -q "i2c_arm=on" "$LOG/dtparam" 2>/dev/null; then ok "candidate: tried enabling I2C live"; else miss "candidate: dtparam not attempted"; fi
if ! grep -q "halpid" "$LOG/apt-get" 2>/dev/null && [[ ! -e "$root/etc/apt/sources.list.d/hatlabs.sources" ]]; then
    ok "candidate: no Hat Labs repo or packages installed"
else
    miss "candidate: Hat Labs packages/repo touched before confirmation"
fi

# 5b. no dtparam on PATH: the i2c-dev module must still be loaded. modprobe
# creates the /dev/i2c-* node and works on any Debian; dtparam enables the
# bus and exists only where raspi-utils is installed. The two ran under one
# condition, tying a distro-agnostic step to a Raspberry-Pi-OS-only binary.
reset_fs
rm -f "$root/i2c-1"                 # node absent: this is what triggers the load
mv "$bin/dtparam" "$root/dtparam.hidden"
rc=$(run_apply SHIM_I2C=fail)
mv "$root/dtparam.hidden" "$bin/dtparam"
if grep -q "i2c-dev" "$LOG/modprobe" 2>/dev/null; then
    ok "no dtparam: modprobe i2c-dev still attempted"
else
    miss "no dtparam: modprobe i2c-dev skipped — the node is never created"
fi
if [[ "$rc" == 1 ]]; then ok "no dtparam: still a clean candidate rc 1"; else miss "no dtparam: rc $rc (want 1)"; fi

# 5b-bis. apt exits 0 but i2ctransfer never appears (stale index, or the
# package silently unresolvable — apt-get install -y -qq returns 0 in that
# case and every stream here is sent to /dev/null). The probe would then fail
# at the `command -v i2ctransfer` gate and report "did not answer at 0x6d",
# blaming the hardware for a missing tool. ensure_i2c_tools must catch it.
reset_fs
mv "$bin/i2ctransfer" "$root/i2ctransfer.hidden"
rc=$(run_apply)
mv "$root/i2ctransfer.hidden" "$bin/i2ctransfer"
if grep -q "i2ctransfer is still missing" "$root/out"; then
    ok "apt no-op: missing i2ctransfer reported, not silently probed"
else
    miss "apt no-op: no warning that i2ctransfer is absent"
fi

# 5b-ter. When the bus cannot be brought up, the warning must name the step
# that fell short. Every call in the live-enable path is best-effort
# (`2>/dev/null || true`), which made a failed enable indistinguishable from a
# silent controller: a board with i2c-tools already present still reached
# "did not answer at 0x6d" with nothing saying whether /dev/i2c-1 ever
# appeared — the ambiguity that made the 2026-08 field report undiagnosable.
reset_fs
rm -f "$root/i2c-1"
mv "$bin/dtparam" "$root/dtparam.hidden"
printf '#!/usr/bin/env bash
exit 1
' >"$bin/modprobe"   # node never appears
rc=$(run_apply SHIM_I2C=fail)
mv "$root/dtparam.hidden" "$bin/dtparam"
# shellcheck disable=SC2016  # shim body is a literal script; $vars expand when it runs
shim modprobe 'echo "$*" >>"$LOG/modprobe"'
if grep -q "still absent after" "$root/out" \
    && ! grep -q "did not answer at I2C 0x6d" "$root/out"; then
    ok "failed bus bring-up names the step and does not claim the board was asked"
else
    miss "bus never came up but the run blamed the controller: $(grep -i '0x6d\|absent after' "$root/out" | head -2)"
fi
if grep -qE "dtparam absent|modprobe i2c-dev failed" "$root/out"; then
    ok "the diagnostic identifies which call fell short"
else
    miss "diagnostic present but does not say which step failed"
fi

# 5b-quater. dtparam present but FAILING is a different branch from dtparam
# absent, and it is the likelier one on a stock HALPI2: the binary ships with
# Raspberry Pi OS, and i2c_arm only reaches config.txt via the block `apply`
# itself writes.
reset_fs
rm -f "$root/i2c-1"
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/dtparam"
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/modprobe"
rc=$(run_apply SHIM_I2C=fail)
# shellcheck disable=SC2016  # shim bodies are literal scripts; $vars expand when they run
shim dtparam  'echo "$*" >>"$LOG/dtparam"'
# shellcheck disable=SC2016
shim modprobe 'echo "$*" >>"$LOG/modprobe"'
if grep -q "dtparam i2c_arm=on failed" "$root/out"; then
    ok "a failing dtparam is reported as failed, not as absent"
else
    miss "dtparam failure not distinguished: $(grep -i 'absent after' "$root/out" | head -1)"
fi

# 5b-quinquies. SIGNALK_HALPI2=yes takes its own branch, and unattended runs
# are where the diagnostic matters most — nobody is watching.
reset_fs
rm -f "$root/i2c-1"
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/dtparam"
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/modprobe"
rc=$(run_apply SHIM_I2C=fail SIGNALK_HALPI2=yes)
# shellcheck disable=SC2016  # shim bodies are literal scripts; $vars expand when they run
shim dtparam  'echo "$*" >>"$LOG/dtparam"'
# shellcheck disable=SC2016
shim modprobe 'echo "$*" >>"$LOG/modprobe"'
if grep -q "still absent after" "$root/out"; then
    ok "SIGNALK_HALPI2=yes keeps the bus diagnostic"
else
    miss "unattended mode lost the diagnostic: $(grep -i '0x6d' "$root/out" | head -1)"
fi

# 5b-sexies. Unattended mode with no probe tool: nothing was ever asked of the
# controller, so saying it "did not answer" sends the operator after the board
# for a missing package. The interactive branch already distinguishes these.
reset_fs
# Shadow rather than remove: run_apply appends the host PATH, so on a box that
# really has i2c-tools (a HALPI2, or CI with it installed) deleting the shim
# would fall through to the real binary and quietly test the wrong branch.
# `command -v` must find nothing, so the shim has to be gone from $bin AND
# unreachable on the host path — use a PATH with no host directories.
mv "$bin/i2ctransfer" "$root/i2ctransfer.hidden"
rc=$(HERMETIC_PATH=1 run_apply SIGNALK_HALPI2=yes)
mv "$root/i2ctransfer.hidden" "$bin/i2ctransfer"
if grep -q "probe could not run" "$root/out" \
    && ! grep -q "controller did not answer at I2C 0x6d" "$root/out"; then
    ok "unattended + no i2ctransfer: reports the missing tool, not a silent board"
else
    miss "unattended run blamed the controller for a missing tool: $(grep -i '0x6d\|probe could not' "$root/out" | head -2)"
fi

# 5c. the i2c node already exists → no module load needed, and no dtparam call
reset_fs
touch "$root/i2c-1"
rc=$(run_apply SHIM_HALPID=active)
if [[ ! -s "$LOG/modprobe" && ! -s "$LOG/dtparam" ]]; then
    ok "i2c node present: neither modprobe nor dtparam called"
else
    miss "i2c node present: modprobe='$(cat "$LOG/modprobe" 2>/dev/null)' dtparam='$(cat "$LOG/dtparam" 2>/dev/null)'"
fi

# 6. candidate + SIGNALK_HALPI2=yes → applied
reset_fs
rc=$(run_apply SHIM_I2C=fail SIGNALK_HALPI2=yes)
if [[ "$rc" == 2 && "$(block_count)" == 1 ]]; then ok "candidate + yes: applied, rc 2"; else miss "candidate + yes: rc $rc, blocks $(block_count)"; fi

# 7. interactive: n declines, y applies
reset_fs; touch "$root/i2c-1"
echo n >"$root/answer"; : >"$root/tty-out"
rc=$(run_apply HALPI2_TTY_IN="$root/answer" HALPI2_TTY_OUT="$root/tty-out")
if [[ "$rc" == 1 && "$(block_count)" == 0 ]]; then ok "tty answer n: declined, untouched"; else miss "tty answer n: rc $rc, blocks $(block_count)"; fi
if grep -q "^+dtparam=i2c_arm=on" "$root/tty-out"; then ok "tty: diff preview shown"; else miss "tty: no diff preview"; fi
if grep -q "\[Y/n\]" "$root/tty-out"; then ok "tty: default is yes when confirmed"; else miss "tty: prompt default wrong"; fi
echo y >"$root/answer"; : >"$root/tty-out"
rc=$(run_apply HALPI2_TTY_IN="$root/answer" HALPI2_TTY_OUT="$root/tty-out")
if [[ "$rc" == 2 && "$(block_count)" == 1 ]]; then ok "tty answer y: applied"; else miss "tty answer y: rc $rc, blocks $(block_count)"; fi
: >"$root/tty-out"; reset_fs; echo n >"$root/answer"
rc=$(run_apply SHIM_I2C=fail HALPI2_TTY_IN="$root/answer" HALPI2_TTY_OUT="$root/tty-out")
if grep -q "Continue with the HALPI2 setup anyway.*\[y/N\]" "$root/tty-out"; then ok "tty: unconfirmed board asks before installing, default no"; else miss "tty: unconfirmed prompt missing/default wrong"; fi
if [[ "$rc" == 1 && "$(block_count)" == 0 && ! -e "$root/etc/apt/sources.list.d/hatlabs.sources" ]]; then ok "tty: declining the unconfirmed board installs nothing"; else miss "tty: declined unconfirmed board still acted (rc $rc)"; fi
# operator says yes → proceeds like a confirmed board (config prompt defaults to yes)
reset_fs; printf 'y\ny\n' >"$root/answer"; : >"$root/tty-out"
rc=$(run_apply SHIM_I2C=fail HALPI2_TTY_IN="$root/answer" HALPI2_TTY_OUT="$root/tty-out")
if [[ "$rc" == 2 && "$(block_count)" == 1 ]] && grep -q "halpid" "$LOG/apt-get"; then ok "tty: operator-confirmed board is set up"; else miss "tty: operator-confirmed board rc $rc, blocks $(block_count)"; fi

# 8. stale block gets replaced, not duplicated
reset_fs; touch "$root/i2c-1"
cat >>"$root/config.txt" <<'EOF'
# >>> signalk-installer halpi2 >>>
[all]
dtparam=i2c_arm=on
# <<< signalk-installer halpi2 <<<
[pi4]
arm_boost=1
EOF
rc=$(run_apply)
if [[ "$rc" == 2 && "$(block_count)" == 1 ]]; then ok "stale block: replaced once"; else miss "stale block: rc $rc, blocks $(block_count)"; fi
if grep -qx 'arm_boost=1' "$root/config.txt"; then ok "stale block: trailing section kept"; else miss "stale block: trailing section lost"; fi
if [[ "$(grep -cxF '# <<< signalk-installer halpi2 <<<' "$root/config.txt")" == 1 ]]; then ok "stale block: one end marker"; else miss "stale block: end marker count"; fi

# 8b. malformed markers (lone begin) → refuse, file untouched
reset_fs; touch "$root/i2c-1"
printf '# >>> signalk-installer halpi2 >>>\n[all]\ndtparam=i2c_arm=on\n[pi4]\narm_boost=1\n' >>"$root/config.txt"
before=$(sha256sum "$root/config.txt")
rc=$(run_apply)
if [[ "$rc" == 1 && "$(sha256sum "$root/config.txt")" == "$before" ]] && grep -q "malformed" "$root/out"; then ok "lone begin marker: refused, config.txt untouched"; else miss "lone begin marker: rc $rc, changed=$([[ "$(sha256sum "$root/config.txt")" == "$before" ]] && echo no || echo yes)"; fi

for fixture in "dup-begin" "dup-end" "end-first"; do
    reset_fs; touch "$root/i2c-1"
    case $fixture in
        dup-begin) printf '# >>> signalk-installer halpi2 >>>\n[all]\n# >>> signalk-installer halpi2 >>>\ndtparam=i2c_arm=on\n# <<< signalk-installer halpi2 <<<\n' >>"$root/config.txt" ;;
        dup-end)   printf '# >>> signalk-installer halpi2 >>>\ndtparam=i2c_arm=on\n# <<< signalk-installer halpi2 <<<\n# <<< signalk-installer halpi2 <<<\n' >>"$root/config.txt" ;;
        end-first) printf '# <<< signalk-installer halpi2 <<<\n# >>> signalk-installer halpi2 >>>\ndtparam=i2c_arm=on\n' >>"$root/config.txt" ;;
    esac
    before=$(sha256sum "$root/config.txt")
    rc=$(run_apply)
    if [[ "$rc" == 1 && "$(sha256sum "$root/config.txt")" == "$before" ]] && grep -q "malformed" "$root/out"; then ok "${fixture} markers: refused, config.txt untouched"; else miss "${fixture} markers: rc $rc, changed=$([[ "$(sha256sum "$root/config.txt")" == "$before" ]] && echo no || echo yes)"; fi
done

# 8c. docs/halpi2.md shows the block's effective lines — keep them in sync
DOC=${DOC:-docs/halpi2.md}
if [[ -f "$DOC" ]]; then
    doc_lines=$(awk '/^```text$/{f=1; next} /^```$/{f=0} f' "$DOC" | grep -E '^(\[all\]|dt(param|overlay)=)' | sort)
    # shellcheck disable=SC2016  # the -c body is sourced later, not expanded here
    real_lines=$(env -i HOME="$root" PATH="$bin:$PATH" bash -c '. "$1"; render_block' _ "$funcs" | grep -E '^(\[all\]|dt(param|overlay)=)' | sort)
    if [[ -n "$doc_lines" && "$doc_lines" == "$real_lines" ]]; then ok "docs/halpi2.md block matches render_block"; else miss "docs/halpi2.md block drifted from render_block"; diff <(echo "$doc_lines") <(echo "$real_lines") || true; fi

    # The troubleshooting entry quotes the diagnostics verbatim so an operator
    # can match the string their terminal printed. That only helps while the
    # two agree, so pin it: any reword in the template must reach the docs.
    # Markdown wraps prose, so compare against the doc with newlines folded to
    # spaces — otherwise a quoted phrase split across two lines reads as absent.
    doc_flat=$(tr '\n' ' ' <"$DOC" | tr -s ' ')
    for phrase in "still absent after" "dtparam i2c_arm=on failed" \
                  "probe at I2C 0x6d failed" "probe could not run" \
                  "i2ctransfer missing"; do
        if grep -qF "$phrase" "$TMPL" && printf '%s' "$doc_flat" | grep -qF "$phrase"; then
            ok "docs quote the live diagnostic: \"$phrase\""
        elif grep -qF "$phrase" "$TMPL"; then
            miss "\"$phrase\" is emitted by $TMPL but missing from $DOC"
        else
            miss "\"$phrase\" no longer emitted by $TMPL — docs now describe a dead string"
        fi
    done
fi

# 9. SIGNALK_HALPI2=no
reset_fs; touch "$root/i2c-1"
rc=$(run_apply SIGNALK_HALPI2=no)
if [[ "$rc" == 0 && "$(block_count)" == 0 && ! -f "$LOG/apt-get" ]]; then ok "SIGNALK_HALPI2=no: skipped"; else miss "SIGNALK_HALPI2=no: acted"; fi

# 10. blinkenlights opt-out
reset_fs; touch "$root/i2c-1"
rc=$(run_apply SIGNALK_HALPI2_BLINKENLIGHTS=no)
if grep -q "^install" "$LOG/apt-get" && ! grep -q "blinkenlights-daemon" "$LOG/apt-get"; then ok "blinkenlights opt-out: not installed"; else miss "blinkenlights opt-out: still installed"; fi

if (( fail )); then
    echo "[FAIL] signalk halpi2 apply — see entries above" >&2
    exit 1
fi
echo "[OK] signalk halpi2 apply: detection gate, config.txt block, package/network files, prompts."
