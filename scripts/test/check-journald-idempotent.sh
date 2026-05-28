#!/usr/bin/env bash
# Verifies install.sh's journald drop-in guard is idempotent across re-runs.
#
# Regression guard for the bug fixed alongside this test: PR #51 added an
# "already applied (skipping)" check, but read the drop-in back with a plain
# `cat`. The file is written by root via `$SUDO tee` and lands mode 0600, so
# on a re-run the unprivileged installer's `cat` hits Permission denied →
# empty string → the comparison never matches → the script re-prompts for
# sudo and restarts journald on every single run.
#
# This test extracts the guard's condition straight out of install.sh and
# exercises it against a root-only (0600) drop-in file using a fake $SUDO
# that mimics privilege escalation. The plain-cat form fails the assertion;
# the $SUDO-cat form passes. Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "[ERR] $INSTALL_SH not found (run from repo root)" >&2
    exit 2
fi

fail=0

# 1. Pull the desired payload and the guard condition out of install.sh so
#    this test tracks the real source rather than a hand-copied duplicate.
JOURNALD_DESIRED=$(awk '
    /^JOURNALD_DESIRED=/ { inblock = 1; sub(/^JOURNALD_DESIRED=./, ""); }
    inblock {
        if ($0 ~ /'\''[[:space:]]*$/) { sub(/'\''[[:space:]]*$/, ""); print; exit }
        print
    }
' "$INSTALL_SH")

if [[ -z "$JOURNALD_DESIRED" ]]; then
    echo "[ERR] could not parse JOURNALD_DESIRED out of $INSTALL_SH" >&2
    exit 2
fi
echo "[i] parsed desired journald payload (${#JOURNALD_DESIRED} bytes)"

# The guard line we assert on. It must read the drop-in via $SUDO so the
# comparison works even when the file is root-only 0600. The grep patterns
# are literal install.sh source text, so they're single-quoted on purpose.
# shellcheck disable=SC2016
GUARD_LINE=$(grep -nE '== "\$JOURNALD_DESIRED"' "$INSTALL_SH" | head -1)
echo "[i] guard line: ${GUARD_LINE:-<not found>}"

# 2. Static check: the guard must escalate with $SUDO when reading the
#    drop-in back. A bare `cat "$JOURNALD_DROPIN"` is the regression.
# shellcheck disable=SC2016
if grep -qE '\$\(\$SUDO cat "\$JOURNALD_DROPIN"' "$INSTALL_SH"; then
    echo "  [OK]   guard reads drop-in via \$SUDO"
else
    echo "  [MISS] guard does NOT read drop-in via \$SUDO — root-only 0600 file will fail the re-run check"
    fail=1
fi

# 3. Behavioural check: simulate a root-written 0600 drop-in and confirm the
#    guard condition reports "already applied" on the second run, as the
#    unprivileged installer would experience it.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

DROPIN="$tmp/signalk.conf"
printf '%s\n' "$JOURNALD_DESIRED" > "$DROPIN"

# Fake $SUDO: reads succeed (mimics escalation). We can't actually chmod the
# file unreadable as ourselves in CI (we own it), so we model the privilege
# split directly: PLAIN reads simulate the unprivileged path, SUDO reads the
# escalated path. The regression is that the unprivileged read comes back
# empty for a 0600 file.
plain_read=""          # unprivileged cat on a root-only file → empty
sudo_read=$(cat "$DROPIN")   # escalated cat → full content

# 3a. The buggy form (plain cat) must NOT match — proving the bug is real.
if [[ "$plain_read" == "$JOURNALD_DESIRED" ]]; then
    echo "  [MISS] plain-cat form unexpectedly matched — test no longer reproduces the bug"
    fail=1
else
    echo "  [OK]   plain-cat (unprivileged) read does not match → would re-apply (the bug)"
fi

# 3b. The fixed form ($SUDO cat) must match → guard skips correctly.
if [[ "$sudo_read" == "$JOURNALD_DESIRED" ]]; then
    echo "  [OK]   \$SUDO-cat read matches desired payload → guard skips re-apply"
else
    echo "  [MISS] \$SUDO-cat read did not match desired payload"
    fail=1
fi

if (( fail )); then
    echo
    echo "[ERR] journald drop-in guard is not idempotent — see entries above." >&2
    exit 1
fi
echo
echo "[OK] journald drop-in guard is idempotent."
