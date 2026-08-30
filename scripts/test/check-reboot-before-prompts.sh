#!/usr/bin/env bash
# Verifies install.sh never asks for vessel identity or admin credentials on a
# run that is going to exit for a reboot, and that the two reboot gates
# (preflight cmdline patch, HALPI2 config.txt) are batched into one exit.
#
# The bug this guards: the prompts were collected ~1300 lines before either
# answer is written to disk (baseDeltas.json / security.json), while the
# reboot gates exit long before that. Every reboot cycle therefore discarded
# what the operator typed and asked again on the next run — a HALPI2 user hit
# it three times in a row. The fix is an ordering property, so it can silently
# regress on any future edit that moves a block; hence a test that asserts the
# order directly rather than the symptom.
#
# Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}
PREFLIGHT=${PREFLIGHT:-installer/linux/preflight.sh}
TMPL=${TMPL:-installer/linux/signalk-halpi2.tmpl}

for f in "$INSTALL_SH" "$PREFLIGHT" "$TMPL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

echo "check-reboot-before-prompts: reboot gates precede the identity prompts"

# Line number of the first match, or empty when absent.
line_of() { grep -nE -m1 "$1" "$2" 2>/dev/null | cut -d: -f1; }

# 1. Ordering: both reboot gates must sit ABOVE both prompt blocks.
pf_line=$(line_of '^section "Pre-flight"' "$INSTALL_SH")
halpi2_line=$(line_of '^# 2c\. Hat Labs HALPI2 carrier board' "$INSTALL_SH")
exit_line=$(line_of '^if \(\( REBOOT_PENDING \)\); then' "$INSTALL_SH")
# Anchor on the executable prompts, not the comments above them: a comment
# can be left behind by an edit that moves the read, and the ordering claim
# is about what actually asks the operator a question.
vessel_line=$(line_of "printf 'Boat name: '" "$INSTALL_SH")
admin_line=$(line_of "printf 'Admin username \[admin\]: '" "$INSTALL_SH")

if [[ -z "$pf_line" || -z "$halpi2_line" || -z "$exit_line" || -z "$vessel_line" || -z "$admin_line" ]]; then
    miss "could not locate all anchors (preflight=$pf_line halpi2=$halpi2_line exit=$exit_line vessel=$vessel_line admin=$admin_line)"
else
    if (( pf_line < vessel_line && pf_line < admin_line )); then
        ok "preflight (line $pf_line) runs before the prompts ($vessel_line, $admin_line)"
    else
        miss "preflight at line $pf_line is NOT before the prompts ($vessel_line, $admin_line)"
    fi
    if (( halpi2_line < vessel_line && halpi2_line < admin_line )); then
        ok "HALPI2 step (line $halpi2_line) runs before the prompts"
    else
        miss "HALPI2 step at line $halpi2_line is NOT before the prompts"
    fi
    if (( exit_line < vessel_line && exit_line < admin_line )); then
        ok "the reboot exit (line $exit_line) is taken before anything is asked"
    else
        miss "reboot exit at line $exit_line comes after a prompt (vessel $vessel_line, admin $admin_line)"
    fi
    if (( pf_line < halpi2_line )); then
        ok "preflight precedes the HALPI2 step (so both can batch into one exit)"
    else
        miss "preflight ($pf_line) does not precede the HALPI2 step ($halpi2_line)"
    fi
fi

# 2. Consolidation: preflight rc 2 must NOT exit on the spot any more. It sets
#    REBOOT_PENDING and falls through, so a HALPI2 box writes cmdline.txt and
#    config.txt in one pass and reboots once instead of twice.
if grep -qE 'PREFLIGHT_RC == 2 \)\); then' "$INSTALL_SH" \
    && ! grep -A3 'PREFLIGHT_RC == 2 ' "$INSTALL_SH" | grep -qE '^\s*exit 0'; then
    ok "preflight rc 2 defers instead of exiting immediately"
else
    miss "preflight rc 2 still exits on the spot — the two gates cannot batch"
fi

for var in REBOOT_PENDING REBOOT_REASONS; do
    if grep -q "$var" "$INSTALL_SH"; then
        ok "$var is used to carry the deferred reboot"
    else
        miss "$var missing from $INSTALL_SH"
    fi
done

# Both gates must record a reason, so the single exit can list what is pending.
if [[ $(grep -cE '^\s*REBOOT_REASONS\+=\(' "$INSTALL_SH") -eq 2 ]]; then
    ok "both reboot gates append a reason"
else
    miss "expected exactly 2 REBOOT_REASONS+=( sites (preflight and HALPI2)"
fi

# 3. Exactly one reboot instruction reaches the operator. preflight.sh and the
#    HALPI2 template each used to print their own "sudo reboot", which would
#    now contradict a run that keeps going.
if ! grep -qE 'Re-run the installer after the reboot' "$PREFLIGHT"; then
    ok "preflight.sh no longer prints its own re-run instruction"
else
    miss "preflight.sh still tells the operator to reboot and re-run"
fi

if grep -q 'HALPI2_DEFER_REBOOT_NOTICE' "$TMPL" \
    && grep -q 'HALPI2_DEFER_REBOOT_NOTICE=1' "$INSTALL_SH"; then
    ok "HALPI2 template suppresses its own reboot notice when install.sh drives it"
else
    miss "HALPI2_DEFER_REBOOT_NOTICE not wired between install.sh and the template"
fi

# Standalone `signalk halpi2 apply` has no batching caller, so it must KEEP
# printing the instruction itself.
if grep -q 'Reboot required to load the device-tree changes' "$TMPL"; then
    ok "standalone 'signalk halpi2 apply' still prints its reboot instruction"
else
    miss "standalone reboot instruction lost from $TMPL"
fi

# 4. Behavioural: the prompt guards themselves are unchanged — identity is
#    still skipped when the data dir already carries it. (The reordering must
#    not have weakened the existing idempotency.)
if grep -qE '\$HOME/\.signalk/baseDeltas\.json.*\|\|.*\$HOME/\.signalk/defaults\.json' "$INSTALL_SH"; then
    ok "vessel prompt still guarded on baseDeltas.json / defaults.json"
else
    miss "vessel identity guard changed shape — re-runs may re-prompt"
fi

if grep -qE 'security\.json' "$INSTALL_SH" && grep -qE "has\(\"users\"\)" "$INSTALL_SH"; then
    ok "admin prompt still guarded on security.json having users"
else
    miss "admin credential guard changed shape — re-runs may re-prompt"
fi

echo
if (( fail )); then
    echo "[FAIL] reboot gates and identity prompts are mis-ordered."
    exit 1
fi
echo "[OK] Reboot gates run before any prompt; both gates batch into one exit."
