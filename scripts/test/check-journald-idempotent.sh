#!/usr/bin/env bash
# Verifies install.sh's journald drop-in guard is idempotent AND silent on
# no-op re-runs (no sudo password prompt).
#
# Two bugs this guards against, both around the "already applied (skipping)"
# check #51 introduced:
#
#   1. The drop-in was written by root via `$SUDO tee`, landing mode 0600.
#      The guard read it back with a plain `cat` as the unprivileged user →
#      Permission denied → empty string → never matched → re-applied (sudo
#      prompt + journald restart) on every single run.
#   2. The first fix read it back via `$SUDO cat`. That matched correctly,
#      but sudo prompted for a password just to read the file — so a no-op
#      run still demanded a password for no reason.
#
# The correct shape: write the drop-in world-readable 0644 (it's plain
# config, no secrets — matches stock journald.conf and our sysctl drop-in)
# and read it back with a plain `cat`. A matching re-run then touches sudo
# zero times. This test asserts that shape against the real install.sh.
# Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "[ERR] $INSTALL_SH not found (run from repo root)" >&2
    exit 2
fi

fail=0

# 1. Pull the desired payload out of install.sh so this test tracks the real
#    source rather than a hand-copied duplicate.
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

# shellcheck disable=SC2016  # grep patterns are literal install.sh source text
GUARD_LINE=$(grep -nE 'JOURNALD_DROPIN" 2>/dev/null\)" == "\$JOURNALD_DESIRED"' "$INSTALL_SH" | head -1)
echo "[i] guard line: ${GUARD_LINE:-<not found>}"

# 2a. Static check: the read-back must be a PLAIN cat. `$SUDO cat` here would
#     re-introduce the password prompt on no-op runs (bug #2).
# shellcheck disable=SC2016
if grep -qE '\$\(cat "\$JOURNALD_DROPIN" 2>/dev/null\)" == "\$JOURNALD_DESIRED"' "$INSTALL_SH"; then
    echo "  [OK]   guard reads drop-in with a plain cat (no sudo prompt on no-op)"
else
    echo "  [MISS] guard read-back is not a plain cat — a no-op re-run will touch sudo"
    fail=1
fi
# shellcheck disable=SC2016
if grep -qE '\$\(\$SUDO cat "\$JOURNALD_DROPIN"' "$INSTALL_SH"; then
    echo "  [MISS] guard reads via \$SUDO — prompts for a password just to skip"
    fail=1
fi

# 2b. Static check: the WRITE must set mode 0644 so the plain read above can
#     succeed for the unprivileged user. A bare `$SUDO tee` (root umask 0600)
#     is what made the plain read fail in the first place (bug #1).
# shellcheck disable=SC2016
if grep -qE '\$SUDO install -m 0644 .* "\$JOURNALD_DROPIN"' "$INSTALL_SH"; then
    echo "  [OK]   drop-in is written world-readable (0644)"
else
    echo "  [MISS] drop-in write does not force 0644 — root umask may leave it 0600 and unreadable"
    fail=1
fi

# 3. Behavioural check: a 0644 drop-in written with the desired payload must
#    be readable — and equal — via a plain cat as the current (unprivileged)
#    user, so the guard skips without escalating.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

DROPIN="$tmp/signalk.conf"
printf '%s\n' "$JOURNALD_DESIRED" > "$DROPIN"
chmod 0644 "$DROPIN"

if [[ "$(cat "$DROPIN" 2>/dev/null)" == "$JOURNALD_DESIRED" ]]; then
    echo "  [OK]   plain cat of a 0644 drop-in matches desired payload → guard skips, no sudo"
else
    echo "  [MISS] plain cat of a 0644 drop-in did not match desired payload"
    fail=1
fi

if (( fail )); then
    echo
    echo "[ERR] journald drop-in guard is not idempotent/silent — see entries above." >&2
    exit 1
fi
echo
echo "[OK] journald drop-in guard is idempotent and silent on no-op re-runs."
