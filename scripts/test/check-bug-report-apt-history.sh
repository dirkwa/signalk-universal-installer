#!/usr/bin/env bash
# Verifies the apt-history section of `signalk bug-report` reports WHEN a
# hardware-relevant package was installed, not just that it is present.
#
# Background — the 2026-08-30 HALPI2 field report. A user was told "the HALPI2
# controller did not answer at I2C 0x6d" on a genuine board. The bundle showed
# i2c-tools installed, which looked like it exonerated the probe tool; what it
# could not show was that the package may have arrived with apply_packages,
# AFTER the probe already ran. "Installed in the same apt transaction as
# halpid" and "installed earlier" are different diagnoses, and the package
# list alone cannot tell them apart.
#
# apt's history.log is stanza-structured: the timestamp is on Start-Date: and
# the packages on Install:/Upgrade:, i.e. different lines of the same record.
# A line-oriented grep captures one or the other but never the pair, which is
# what makes the output useless for this question — so that pairing is what
# this test pins.
#
# Run from the repo root.

set -euo pipefail

TMPL=${TMPL:-installer/linux/signalk.tmpl}

if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

echo "check-bug-report-apt-history: install timestamps, not just presence"

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

# A history.log with the real stanza shape: the interesting pair straddles
# three lines, and an unrelated transaction must not be reported.
cat >"$root/history.log" <<'EOF'
Start-Date: 2026-08-29  11:02:03
Commandline: apt install curl
Install: curl:arm64 (8.5.0-1)
End-Date: 2026-08-29  11:02:05

Start-Date: 2026-08-30  12:30:18
Commandline: apt-get install -y -qq i2c-tools
Install: i2c-tools:arm64 (4.3-2)
End-Date: 2026-08-30  12:30:20

Start-Date: 2026-08-30  12:31:55
Commandline: apt-get install -y halpid halpi2-firmware
Install: halpid:arm64 (0.9.1), halpi2-firmware:arm64 (1.2.0)
End-Date: 2026-08-30  12:32:40
EOF

# The extraction, lifted from signalk.tmpl. Kept in step by assertion 4 below.
extract() {
    awk 'BEGIN{RS="";FS="\n"}
         /i2c-tools|can-utils|halpid|halpi2-firmware|blinkenlights|gpsd/{
           d="";p="";
           for(i=1;i<=NF;i++){
             if($i ~ /^Start-Date:/) d=substr($i,13);
             if($i ~ /^(Install|Upgrade):/) p=$i;
           }
           if(p!="") print d"  "p;
         }' "$1"
}

out=$(extract "$root/history.log")

# 1. Every matching stanza carries its timestamp — the whole point.
if [[ "$(printf '%s\n' "$out" | grep -c '^2026-08-30')" -eq 2 ]]; then
    ok "both hardware transactions reported with their Start-Date"
else
    miss "expected 2 timestamped hardware rows, got: $out"
fi

# 2. The timestamp and the package list appear on the SAME line. A
#    line-oriented grep yields one without the other, which is the failure
#    this section exists to avoid.
if printf '%s\n' "$out" | grep -q '^2026-08-30  12:30:18  Install: i2c-tools'; then
    ok "timestamp and package pinned together on one line"
else
    miss "i2c-tools row lost its Start-Date (line-oriented match?): $out"
fi

# 3. Unrelated transactions stay out.
if ! printf '%s\n' "$out" | grep -q 'curl'; then
    ok "unrelated installs (curl) not reported"
else
    miss "unrelated install leaked into the section"
fi

# 4. The distinction the field report needed: i2c-tools and halpid must be
#    separable. Same timestamp => the probe ran before its tool existed;
#    different => the tool was already there and the board really was silent.
i2c_ts=$(printf '%s\n' "$out" | grep 'i2c-tools' | awk '{print $1" "$2}')
hal_ts=$(printf '%s\n' "$out" | grep 'halpid'    | awk '{print $1" "$2}')
if [[ -n "$i2c_ts" && -n "$hal_ts" && "$i2c_ts" != "$hal_ts" ]]; then
    ok "i2c-tools and halpid transactions are distinguishable ($i2c_ts vs $hal_ts)"
else
    miss "cannot separate i2c-tools from halpid: '$i2c_ts' / '$hal_ts'"
fi

# 5. The awk in signalk.tmpl must be the one tested here.
for frag in 'RS=""' 'Start-Date:' '(Install|Upgrade):' 'i2c-tools|can-utils|halpid'; do
    if grep -qF "$frag" "$TMPL"; then
        ok "signalk.tmpl still carries the stanza parser fragment: $frag"
    else
        miss "signalk.tmpl no longer contains '$frag' — this test has drifted"
    fi
done

# 6. Absent logs degrade to a message, never an error.
if grep -q 'not an apt host, or logs rotated away' "$TMPL"; then
    ok "non-apt hosts get an explanation rather than a silent gap"
else
    miss "no fallback message for hosts without /var/log/apt/history.log"
fi

echo
if (( fail )); then
    echo "[FAIL] apt-history capture does not pin install timestamps."
    exit 1
fi
echo "[OK] Bug reports capture WHEN hardware packages landed, not just that they did."
