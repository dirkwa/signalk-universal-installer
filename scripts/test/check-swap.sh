#!/usr/bin/env bash
# Verifies install.sh's Swap step against a sandbox root (SWAP_ROOT) with
# apt-get, apt-cache, systemctl, findmnt, df and dphys-swapfile stubbed:
#   1. zram already in /proc/swaps: nothing is installed or written.
#   2. A fresh apt host: the zram config is written before the package is
#      installed (its postinst would otherwise start zram0 at the package
#      default), then dev-zram0.swap is started.
#   3. An operator's own zram config, or no sudo: left alone.
#   4. dphys-swapfile at 200 MB on an NVMe with room: raised to 2048 and
#      rebuilt now; on an SD card, low disk, or already 2048: left alone;
#      too little free RAM to swapoff: raised, rebuilt at the next boot.
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

# Lift the step out of install.sh so the test tracks the real source.
STEP=$(awk '/^section "Swap"/{p=1} p{print} /^# ── end of Swap ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of Swap'* ]]; then
    echo "[ERR] could not extract the Swap step from $INSTALL_SH" >&2
    exit 2
fi

mkdir -p "$tmp/bin"
# Each stub logs its call; apt-get also records whether the zram config was
# already in place when it ran.
cat >"$tmp/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >>"$STUB_LOG"
[[ -f "$SWAP_ROOT/etc/systemd/zram-generator.conf" ]] && echo "apt-get saw zram config" >>"$STUB_LOG"
exit 0
STUB
cat >"$tmp/bin/apt-cache" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == "show systemd-zram-generator" ]]
STUB
cat >"$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
STUB
cat >"$tmp/bin/dphys-swapfile" <<'STUB'
#!/usr/bin/env bash
echo "dphys-swapfile $*" >>"$STUB_LOG"
STUB
cat >"$tmp/bin/findmnt" <<'STUB'
#!/usr/bin/env bash
echo "$STUB_SRC"
STUB
cat >"$tmp/bin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1G-blocks Used Available Capacity Mounted\n%s 468G 172G %sG 39%% /\n' "$STUB_SRC" "$STUB_FREE_GB"
STUB
chmod +x "$tmp/bin"/*

# run_step <name> <sudo> [swaps-line] — runs the step in a fresh sandbox
# prepared by the caller in $tmp/<name>.
run_step() {
    local root="$tmp/$1"
    mkdir -p "$root/proc" "$root/etc/systemd" "$root/var"
    [[ -f "$root/proc/swaps" ]] || printf 'Filename Type Size Used Priority\n' >"$root/proc/swaps"
    [[ -f "$root/proc/meminfo" ]] || printf 'MemAvailable:    3000000 kB\n' >"$root/proc/meminfo"
    : >"$root/log"
    out=$(SWAP_ROOT="$root" STUB_LOG="$root/log" PATH="$tmp/bin:$PATH" SUDO="$2" \
        STUB_SRC="${STUB_SRC:-/dev/nvme0n1p2}" STUB_FREE_GB="${STUB_FREE_GB:-273}" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; info() { echo "info: $*"; }; warn() { echo "warn: $*"; }
        '"$STEP" 2>&1) || { miss "$1: step exited non-zero: $out"; return 0; }
    log=$(cat "$root/log")
}

desired=$(awk "/^ZRAM_DESIRED='/{p=1; sub(/^ZRAM_DESIRED='/, \"\")} p{ if (\$0 ~ /'\$/) { sub(/'\$/, \"\"); print; exit } print }" "$INSTALL_SH")

echo "zram"
mkdir -p "$tmp/active/proc"
printf 'Filename Type Size Used Priority\n/dev/zram0 partition 2062832 0 100\n' >"$tmp/active/proc/swaps"
run_step active ""
if [[ "$out" == *"zram swap active (skipping)"* && -z "$log" ]]; then
    ok "zram already active: nothing installed or written"
else
    miss "active zram: out=[$out] log=[$log]"
fi

run_step fresh ""
if [[ "$(cat "$tmp/fresh/etc/systemd/zram-generator.conf" 2>/dev/null)" == "$desired" ]]; then
    ok "fresh host: zram config written"
else
    miss "fresh host: zram config $(cat "$tmp/fresh/etc/systemd/zram-generator.conf" 2>/dev/null)"
fi
if grep -qx "apt-get saw zram config" <<<"$log"; then
    ok "config is in place before the package installs"
else
    miss "package installed before the config: $log"
fi
if grep -qx "systemctl start dev-zram0.swap" <<<"$log"; then
    ok "dev-zram0.swap started"
else
    miss "dev-zram0.swap not started: $log"
fi

mkdir -p "$tmp/own/etc/systemd"
printf '[zram0]\nzram-size = ram\n' >"$tmp/own/etc/systemd/zram-generator.conf"
run_step own ""
if [[ "$out" == *"left as is"* && -z "$log" && "$(cat "$tmp/own/etc/systemd/zram-generator.conf")" == $'[zram0]\nzram-size = ram' ]]; then
    ok "operator's own zram config left alone"
else
    miss "own config: out=[$out] log=[$log]"
fi

run_step nosudo MISSING
if [[ "$out" == *"Cannot set up zram swap without sudo"* && -z "$log" ]]; then
    ok "no sudo: warns, changes nothing"
else
    miss "no sudo: out=[$out] log=[$log]"
fi

echo "dphys-swapfile"
# dphys <name> <CONF_SWAPSIZE> — a sandbox with zram active and a dphys conf.
dphys() {
    mkdir -p "$tmp/$1/proc" "$tmp/$1/etc"
    printf 'Filename Type Size Used Priority\n/var/swap file 204784 100000 -2\n/dev/zram0 partition 2062832 0 100\n' \
        >"$tmp/$1/proc/swaps"
    printf '# comment\nCONF_SWAPSIZE=%s\n#CONF_MAXSWAP=2048\n' "$2" >"$tmp/$1/etc/dphys-swapfile"
}
size_of() { sed -n 's/^CONF_SWAPSIZE=//p' "$tmp/$1/etc/dphys-swapfile"; }

dphys nvme 200
run_step nvme ""
if [[ "$(size_of nvme)" == 2048 ]] && grep -qx "dphys-swapfile swapoff" <<<"$log" \
    && grep -qx "dphys-swapfile setup" <<<"$log" && grep -qx "dphys-swapfile swapon" <<<"$log"; then
    ok "NVMe with room: raised to 2048 and rebuilt now"
else
    miss "NVMe: size=$(size_of nvme) log=[$log] out=[$out]"
fi

dphys sd 200
STUB_SRC=/dev/mmcblk0p2 run_step sd ""
if [[ "$(size_of sd)" == 200 && -z "$log" ]]; then
    ok "SD card: kept at 200"
else
    miss "SD card: size=$(size_of sd) log=[$log]"
fi

dphys lowdisk 200
STUB_FREE_GB=5 run_step lowdisk ""
if [[ "$(size_of lowdisk)" == 200 && -z "$log" ]]; then
    ok "under 20 GB free: kept at 200"
else
    miss "low disk: size=$(size_of lowdisk) log=[$log]"
fi

dphys big 2048
run_step big ""
if [[ "$out" == *"dphys-swapfile 2048 MB (skipping)"* && -z "$log" ]]; then
    ok "already 2048: nothing to do"
else
    miss "2048: out=[$out] log=[$log]"
fi

dphys lowram 200
printf 'MemAvailable:    400000 kB\n' >"$tmp/lowram/proc/meminfo"
run_step lowram ""
if [[ "$(size_of lowram)" == 2048 ]] && ! grep -q "swapoff" <<<"$log" && [[ "$out" == *"next boot"* ]]; then
    ok "too little free RAM to swapoff: raised, rebuilt at the next boot"
else
    miss "low RAM: size=$(size_of lowram) log=[$log] out=[$out]"
fi

if (( fail )); then
    echo "[FAIL] check-swap"
    exit 1
fi
echo "[PASS] check-swap"
