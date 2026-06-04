#!/usr/bin/env bash
# Verifies check_tmp_on_tmpfs() in installer/linux/preflight.sh prints its
# informational heads-up on exactly the right hosts and stays quiet otherwise.
#
# The check reads two host facts: the filesystem backing /tmp (_tmp_fstype)
# and total RAM (_total_ram_mb). Those are split into their own helpers so
# this test can stub them and assert the branching logic host-independently
# — it does not look at the machine it runs on.
#
# Decision table under test (speak up only when BOTH hold):
#   * /tmp is tmpfs (RAM-backed), AND
#   * RAM <= TMPFS_WARN_MAX_RAM_MB (default 8192 — the 4/8 GB Pi fleet).
# Anything else is quiet: /tmp on disk, or tmpfs with RAM headroom.
# The heads-up is informational (info -> stdout, never warn -> stderr),
# non-blocking (always returns 0), and must suggest shrinking the tmpfs cap
# via a tmp.mount.d drop-in (keeps /tmp in RAM, no SSD wear), with the
# percentage taken from TMPFS_RECOMMEND_PCT. It must never suggest masking
# /tmp onto disk.
#
# Run from the repo root.

set -euo pipefail

PREFLIGHT=${PREFLIGHT:-installer/linux/preflight.sh}

if [[ ! -f "$PREFLIGHT" ]]; then
    echo "[ERR] $PREFLIGHT not found (run from repo root)" >&2
    exit 2
fi

# Sourcing runs detect_os at top level (needs lib/), but the BASH_SOURCE
# guard keeps main() from running, so only the helpers get defined.
# shellcheck source=/dev/null
. "$PREFLIGHT" >/dev/null 2>&1

fail=0

# Drive one case: stub the two host reads, capture output, assert verdict.
#   expect = "notice" (emits the informational heads-up) or "quiet" (silent).
run() {
    local expect="$1" max_ram="$4" label="$5"
    # Distinct global names: the stubs are invoked *inside*
    # check_tmp_on_tmpfs, which declares its own `local fstype` — under
    # bash dynamic scope a same-named var would resolve to that
    # not-yet-assigned local and trip `set -u`.
    STUB_FSTYPE="$2"
    STUB_RAM_MB="$3"

    # Invoked indirectly by the sourced check_tmp_on_tmpfs; shellcheck
    # can't see across that call and flags them unreachable.
    # shellcheck disable=SC2317
    _tmp_fstype() { printf '%s\n' "$STUB_FSTYPE"; }
    # shellcheck disable=SC2317
    _total_ram_mb() { printf '%s\n' "$STUB_RAM_MB"; }

    # Capture stdout and stderr separately: the heads-up is informational
    # (info -> stdout), deliberately NOT a warning (warn -> stderr). A
    # regression that re-escalates it to warn would move it to stderr, so
    # we assert the notice lands on stdout and nothing lands on stderr.
    local out err rc
    err=$(mktemp)
    out=$(TMPFS_WARN_MAX_RAM_MB="$max_ram" TMPFS_RECOMMEND_PCT="${RUN_PCT:-20}" \
        check_tmp_on_tmpfs 2>"$err")
    rc=$?
    local stderr_out; stderr_out=$(cat "$err"); rm -f "$err"

    unset -f _tmp_fstype _total_ram_mb

    local got="quiet"
    if grep -q 'tmpfs (RAM-backed)' <<<"$out"; then
        got="notice"
    fi

    # The check must never abort preflight — it's advisory only.
    if (( rc != 0 )); then
        echo "[FAIL] $label -> returned $rc (must be 0; check is non-blocking)" >&2
        fail=1
        return
    fi

    # The heads-up must be informational, never a warning: nothing on stderr.
    if [[ -n "$stderr_out" ]]; then
        echo "[FAIL] $label -> wrote to stderr (should be info on stdout, not warn):" >&2
        printf '%s\n' "$stderr_out" >&2
        fail=1
        return
    fi

    # When it speaks up, the optional tweak must be present: the shrink-the-cap
    # drop-in (keeps /tmp in RAM — no SSD wear), carrying the configured
    # percentage. It must NOT recommend masking /tmp onto disk.
    if [[ "$got" == "notice" ]]; then
        if ! grep -q "tmp.mount.d" <<<"$out" \
            || ! grep -q "size=${RUN_PCT:-20}%" <<<"$out"; then
            echo "[FAIL] $label -> noticed but omitted the size=${RUN_PCT:-20}% drop-in hint" >&2
            fail=1
            return
        fi
        if grep -q 'mask tmp.mount' <<<"$out"; then
            echo "[FAIL] $label -> recommended masking /tmp onto disk (SSD wear)" >&2
            fail=1
            return
        fi
    fi

    if [[ "$got" == "$expect" ]]; then
        echo "[ OK ] $label -> $got"
    else
        echo "[FAIL] $label -> got $got, expected $expect" >&2
        echo "------ output ------" >&2
        printf '%s\n' "$out" >&2
        echo "--------------------" >&2
        fail=1
    fi
}

# expect   fstype  ram_mb  max_ram  label
run quiet  ext4   8192   8192  "/tmp on disk (ext4), small RAM -> quiet"
run quiet  xfs    4096   8192  "/tmp on disk (xfs), tiny RAM -> quiet"
run quiet  ""     4096   8192  "fstype undeterminable -> treated as on-disk, quiet"
run quiet  tmpfs  16384  8192  "tmpfs but 16 GB RAM (headroom) -> quiet"
run quiet  tmpfs  8193   8192  "tmpfs, just over threshold -> quiet (boundary)"
run notice tmpfs  8192   8192  "tmpfs on 8 GB Pi (== threshold) -> NOTICE"
run notice tmpfs  4096   8192  "tmpfs on 4 GB Pi -> NOTICE"
run notice tmpfs  2048   8192  "tmpfs on 2 GB box -> NOTICE"
# Threshold is overridable: raising it makes a big box notice too.
run notice tmpfs  16384  32768 "tmpfs, 16 GB RAM, threshold raised to 32 GB -> NOTICE"
# Recommended percentage flows from TMPFS_RECOMMEND_PCT into the hint (the
# per-case assertion checks for size=${RUN_PCT}% in the output).
RUN_PCT=10 run notice tmpfs 4096 8192 "tmpfs, custom TMPFS_RECOMMEND_PCT=10 -> NOTICE with size=10%"
unset RUN_PCT

if (( fail )); then
    echo "[ERR] check_tmp_on_tmpfs decision table has regressions" >&2
    exit 1
fi
echo "[PASS] check_tmp_on_tmpfs decision table correct"
