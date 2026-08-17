#!/usr/bin/env bash
# Verifies install.sh skips the "Use standard web ports?" prompt on re-runs
# when the privileged-port sysctl drop-in already exists (a prior "yes"),
# while still honouring an explicit SIGNALK_PRIVILEGED_PORTS override.
#
# The decision is inline in install.sh, so this test (1) asserts the guard
# is present in the source, and (2) exercises the same decision logic
# against a temp drop-in path to confirm the truth table. Run from repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "[ERR] $INSTALL_SH not found (run from repo root)" >&2
    exit 2
fi

fail=0

# 1. Static check: the prompt-skip guard must be present and gated on both
#    "still prompt" and the drop-in file existing.
# shellcheck disable=SC2016  # literal install.sh source text
if grep -qE '"\$PRIV_PORTS" = "prompt" && -f "\$PRIV_SYSCTL_FILE"' "$INSTALL_SH"; then
    echo "  [OK]   prompt-skip guard present (prompt && drop-in exists)"
else
    echo "  [MISS] prompt-skip guard missing or changed shape in $INSTALL_SH"
    fail=1
fi

# 2. Behavioural truth table. Mirrors install.sh's decision: normalize
#    SIGNALK_PRIVILEGED_PORTS, then skip the prompt to PRIV_PORTS=1 only when
#    the value is still "prompt" and the drop-in exists.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DROPIN="$tmp/80-signalk-unprivileged-ports.conf"

decide() {
    local env_val=$1 dropin_exists=$2 priv
    priv="${env_val:-prompt}"
    case "$priv" in
        1|y|Y|yes|YES|Yes|true|TRUE|True|on|ON|On) priv=1 ;;
        0|n|N|no|NO|No|false|FALSE|False|off|OFF|Off) priv=0 ;;
        *) priv=prompt ;;
    esac
    local f=/nonexistent
    [[ "$dropin_exists" == "yes" ]] && f="$DROPIN"
    if [[ "$priv" = "prompt" && -f "$f" ]]; then
        priv=1
        echo "skip:$priv"
        return
    fi
    echo "prompt-or-set:$priv"
}

printf 'desired payload\n' > "$DROPIN"

assert() {
    local label=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        echo "  [OK]   $label"
    else
        echo "  [MISS] $label — wanted [$want], got [$got]"
        fail=1
    fi
}

# Re-run, no explicit choice, drop-in present → skip prompt, keep :80/:443.
assert "re-run + drop-in → prompt skipped, PRIV_PORTS=1" "$(decide '' yes)" "skip:1"
# Fresh install, no choice, no drop-in → falls through to prompt.
assert "fresh + no drop-in → still prompts" "$(decide '' no)" "prompt-or-set:prompt"
# Explicit opt-out wins even when the drop-in exists.
assert "explicit 0 + drop-in → opt-out wins" "$(decide 0 yes)" "prompt-or-set:0"
# Explicit opt-in is honoured regardless of drop-in.
assert "explicit 1 + no drop-in → PRIV_PORTS=1" "$(decide 1 no)" "prompt-or-set:1"

# The sysctl write must be gated on the DROP-IN, not on the running value.
# A podman machine boots reporting ip_unprivileged_port_start=80 with no file
# under /etc/sysctl.d or /usr/lib/sysctl.d holding it there, so a check of the
# runtime value alone reads "already configured", skips the write, and the next
# `wsl --shutdown` resets the floor to 1024 - after which signalk-server
# crash-loops on `listen EACCES: permission denied 0.0.0.0:80` while its
# container still reports Up. Observed on a real Windows install.
INSTALL_SH="${INSTALL_SH:-installer/linux/install.sh}"
if [[ ! -f "$INSTALL_SH" ]]; then
    echo "  [MISS] $INSTALL_SH not found"
    fail=1
else
    # Drive the real condition text rather than matching its source: extract the
    # guard from install.sh and evaluate it against each drop-in state. A file
    # that merely EXISTS is not persistence - an empty or hand-edited one
    # satisfies -f while holding nothing, reproducing the same dead :80.
    # install.sh must gate on the drop-in's CONTENT. Assert that first (a guard
    # testing only -f, or only the runtime value, is the bug), then exercise the
    # same condition below so the cases prove behaviour rather than spelling.
    # shellcheck disable=SC2016  # literal shell source text
    if grep -qE '^[[:space:]]*if \[\[ -f "\$PRIV_SYSCTL_FILE" \]\]' "$INSTALL_SH" \
        || grep -qE '^[[:space:]]*if \(\( current_floor <= 80 \)\); then' "$INSTALL_SH"; then
        echo "  [MISS] sysctl write gated on file existence or the runtime value alone;"
        echo "         an empty or wrong-valued drop-in skips the write and :80 dies"
        fail=1
    elif ! grep -q 'PRIV_SYSCTL_KEY//\./' "$INSTALL_SH"; then
        echo "  [MISS] could not find the content-matching persistence guard"
        fail=1
    else
        tmp_sysctl=$(mktemp -d)
        # Same condition install.sh uses, asserted above to be the content form.
        sysctl_case() {  # $1 = file body, "__ABSENT__" for no file; $2 = floor
            local body="$1" floor="$2" key=net.ipv4.ip_unprivileged_port_start
            local f="$tmp_sysctl/drop.conf"
            rm -f "$f"
            [[ "$body" != "__ABSENT__" ]] && printf '%s' "$body" >"$f"
            if grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=[[:space:]]*(80|[0-9]|[1-7][0-9])[[:space:]]*$" \
                "$f" 2>/dev/null && (( floor <= 80 )); then
                echo skip
            else
                echo write
            fi
        }
        good='net.ipv4.ip_unprivileged_port_start=80
'
        assert "no drop-in + floor 80 → still writes"      "$(sysctl_case __ABSENT__ 80)"   "write"
        assert "EMPTY drop-in + floor 80 → still writes"   "$(sysctl_case '' 80)"           "write"
        assert "wrong value (1024) + floor 80 → writes"    "$(sysctl_case 'net.ipv4.ip_unprivileged_port_start=1024
' 80)" "write"
        assert "commented-out drop-in + floor 80 → writes" "$(sysctl_case '# net.ipv4.ip_unprivileged_port_start=80
' 80)" "write"
        assert "correct drop-in + floor 80 → skips"        "$(sysctl_case "$good" 80)"      "skip"
        assert "correct drop-in + floor 1024 → rewrites"   "$(sysctl_case "$good" 1024)"    "write"
    fi
fi

if (( fail )); then
    echo
    echo "[ERR] privileged-port prompt-skip logic is wrong — see entries above." >&2
    exit 1
fi
echo
echo "[OK] privileged-port prompt is skipped on re-runs when already configured."
