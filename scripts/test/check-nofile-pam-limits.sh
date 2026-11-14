#!/usr/bin/env bash
# Verifies install.sh's PAM open-files step against sandboxed
# /etc/security trees: it warns, naming file and line, when the pam_limits
# entry that wins for the installing user sets a hard nofile below 1048576,
# and stays quiet for soft-only, unlimited, commented and foreign entries.
# Which entry wins follows pam_limits.c: the user's own entry, then @group,
# then *, the last one within a rank, limits.d/*.conf in C-locale order after
# limits.conf; %-domains are ignored for nofile, a "<user> -" line disables
# all limits, and a higher-ranked soft entry also blocks a "-" entry's hard
# half.
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
STEP=$(awk '/^section "PAM open-files limits"/{p=1} p{print} /^# ── end of PAM open-files limits ──/{exit}' "$INSTALL_SH")
if [[ -z "$STEP" || "$STEP" != *'end of PAM open-files limits'* ]]; then
    echo "[ERR] could not extract the PAM open-files step from $INSTALL_SH" >&2
    exit 2
fi

me=$(id -un)
my_group=$(id -gn)

# run_case <name> <file>=<content> ... — writes each file under the sandbox's
# etc/security and runs the step there. CASE_LOCALE, when set, is the locale
# the step runs under.
run_case() {
    local name=$1 root="$tmp/$1"; shift
    mkdir -p "$root/etc/security/limits.d"
    local spec
    for spec in "$@"; do
        printf '%s\n' "${spec#*=}" >"$root/etc/security/${spec%%=*}"
    done
    out=$(PAM_LIMITS_ROOT="$root" USER="$me" LC_ALL="${CASE_LOCALE:-${LC_ALL:-}}" bash -c '
        set -euo pipefail
        section() { :; }; ok() { echo "ok: $*"; }; warn() { echo "warn: $*"; }
        '"$STEP" 2>&1) || { miss "$name: step exited non-zero: $out"; out=""; }
}

expect_warn() { # <case> <expected file:line (value)>
    if [[ "$out" == *"warn: The nofile entry at $tmp/$1/etc/security/$2 caps"* ]]; then
        ok "$1: warns about $2"
    else
        miss "$1: expected a warning about $2, got: $out"
    fi
}

expect_quiet() { # <case>
    if [[ "$out" == "ok: No PAM limits entry caps the open-files limit" ]]; then
        ok "$1: no warning"
    else
        miss "$1: expected no warning, got: $out"
    fi
}

run_case empty
expect_quiet empty

run_case wildcard-hard "limits.conf=# comment
* hard nofile 65536"
expect_warn wildcard-hard "limits.conf:2 (65536)"

run_case wildcard-dash "limits.conf=*  -  nofile  65536  # from a tuning guide"
expect_warn wildcard-dash "limits.conf:1 (65536)"

# pam_limits cuts a line at "#": the second line is a two-field "-" line.
run_case comment-cut "limits.conf=* hard nofile 65536
$me -   # no limits for the boat user"
expect_quiet comment-cut

run_case soft-only "limits.conf=* soft nofile 65536"
expect_quiet soft-only

run_case commented "limits.conf=#* hard nofile 65536"
expect_quiet commented

run_case high-enough "limits.conf=* hard nofile 1048576"
expect_quiet high-enough

run_case unlimited "limits.conf=* hard nofile unlimited"
expect_quiet unlimited

run_case other-user "limits.conf=someone-else hard nofile 65536"
expect_quiet other-user

run_case user-beats-wildcard "limits.conf=* hard nofile 65536" \
    "limits.d/90-sk.conf=$me hard nofile 1048576"
expect_quiet user-beats-wildcard

run_case user-wins-over-later-wildcard "limits.conf=$me hard nofile 65536" \
    "limits.d/90-all.conf=* hard nofile 1048576"
expect_warn user-wins-over-later-wildcard "limits.conf:1 (65536)"

run_case own-group "limits.d/50-group.conf=@$my_group hard nofile 65536"
expect_warn own-group "limits.d/50-group.conf:1 (65536)"

run_case group-beats-wildcard "limits.conf=@$my_group hard nofile 1048576" \
    "limits.d/90-all.conf=* hard nofile 65536"
expect_quiet group-beats-wildcard

# pam_limits applies %-domains to maxlogins only.
run_case percent-ignored "limits.conf=% hard nofile 65536" \
    "limits.d/50-group.conf=%$my_group hard nofile 65536"
expect_quiet percent-ignored

run_case percent-does-not-outrank-wildcard "limits.conf=% hard nofile 1048576" \
    "limits.d/90-all.conf=* hard nofile 65536"
expect_warn percent-does-not-outrank-wildcard "limits.d/90-all.conf:1 (65536)"

# "<user> -" makes pam_limits set no limits at all.
run_case no-limits-line "limits.conf=* hard nofile 65536
$me -"
expect_quiet no-limits-line

run_case no-limits-line-wildcard-ignored "limits.conf=* -
* hard nofile 65536"
expect_warn no-limits-line-wildcard-ignored "limits.conf:2 (65536)"

# A soft entry for the user blocks both halves of a lower-ranked "-" entry.
run_case soft-blocks-dash "limits.conf=$me soft nofile 4096
* - nofile 65536"
expect_quiet soft-blocks-dash

run_case uppercase "limits.conf=* HARD NOFILE 65536"
expect_warn uppercase "limits.conf:1 (65536)"

# strtoul stops at the carriage return of a CRLF file.
run_case crlf "limits.conf=* hard nofile 65536"$'\r'
expect_warn crlf "limits.conf:1 (65536)"

# strtoul reads the leading digits.
run_case value-suffix "limits.conf=* hard nofile 65536k"
expect_warn value-suffix "limits.conf:1 (65536)"

run_case value-plus "limits.conf=* hard nofile +65536"
expect_warn value-plus "limits.conf:1 (65536)"

# pam_limits skips an invalid value, so it does not take the user's rank.
run_case invalid-value-skipped "limits.conf=$me hard nofile lots" \
    "limits.d/90-all.conf=* hard nofile 65536"
expect_warn invalid-value-skipped "limits.d/90-all.conf:1 (65536)"

# The value is the rest of the line, so "unlimited junk" is invalid and skipped.
run_case unlimited-with-trailing-words "limits.conf=$me hard nofile unlimited junk" \
    "limits.d/90-all.conf=* hard nofile 65536"
expect_warn unlimited-with-trailing-words "limits.d/90-all.conf:1 (65536)"

run_case negative-is-unlimited "limits.conf=* hard nofile -1"
expect_quiet negative-is-unlimited

mkdir -p "$tmp/directory-entry/etc/security/limits.d/odd.conf"
run_case directory-entry "limits.conf=* hard nofile 1048576"
expect_quiet directory-entry

run_case foreign-group "limits.conf=@no-such-group-$$ hard nofile 65536"
expect_quiet foreign-group

# C-locale order reads B.conf before a.conf, so a.conf's entry is the last.
# Under a UTF-8 language locale the glob sorts a.conf first; the step must
# not follow it. CI's C.UTF-8 sorts like C, so use a language locale when
# the host has one.
CASE_LOCALE=$(locale -a 2>/dev/null | grep -i -m1 -E '^en_[a-z]+\.utf-?8$' || true)
run_case c-locale-order "limits.d/a.conf=* hard nofile 65536" \
    "limits.d/B.conf=* hard nofile 1048576"
expect_warn c-locale-order "limits.d/a.conf:1 (65536)"
CASE_LOCALE=

run_case last-in-rank "limits.d/10-a.conf=* hard nofile 65536" \
    "limits.d/20-b.conf=* hard nofile 1048576"
expect_quiet last-in-rank

if (( fail )); then
    echo "FAIL"
    exit 1
fi
echo "PASS"
