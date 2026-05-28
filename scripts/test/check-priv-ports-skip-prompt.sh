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

if (( fail )); then
    echo
    echo "[ERR] privileged-port prompt-skip logic is wrong — see entries above." >&2
    exit 1
fi
echo
echo "[OK] privileged-port prompt is skipped on re-runs when already configured."
