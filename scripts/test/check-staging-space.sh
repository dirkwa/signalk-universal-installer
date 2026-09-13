#!/usr/bin/env bash
# Verifies check_image_staging_space() in installer/linux/preflight.sh gates
# the install on free space in the directory `podman pull` stages into.
#
# Why the check exists: podman decompresses each image layer into a
# container_images_storage* dir under its staging path before committing the
# layer to the store. Measured against a clean store, signalk-server:dirkwa
# (1.4 GB image) peaked at 435.6 MB of staging and signalk-doctor-server
# (297 MB image) at 96 MB. A staging dir smaller than that peak — a
# RAM-backed /tmp or /var/tmp capped at 512 MB on a 4 GB CM4 — fails the
# pull outright, which is what a user reported from the field.
#
# The check reads two host facts: where podman stages (_staging_dir) and how
# much is free there (_dir_avail_mb). Both are their own helpers so this test
# can stub them and assert the branching host-independently — it does not
# look at the machine it runs on.
#
# Decision table under test:
#   * free >= STAGING_REQUIRED_MB          -> ok, returns 0
#   * free <  STAGING_REQUIRED_MB          -> fail (install must not proceed)
#   * free unreadable (empty)              -> warn, returns 0 (cannot judge)
# Unlike the advisory notice this replaced, the shortfall case is BLOCKING:
# the pull cannot succeed without the space, so continuing only relocates the
# failure. The remedy printed must be the image_copy_tmp_dir redirect, never
# a suggestion to shrink or mask a tmpfs.
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

# `fail` in preflight.sh marks the run failed and returns non-zero rather
# than exiting, so the check returns non-zero here too. Stub it to a plain
# marker so this test sees the verdict without preflight's global state.
# shellcheck disable=SC2317
fail() { echo "PREFLIGHT_FAIL: $*"; return 1; }

# The decision-table cases stub the two host-fact helpers and `unset -f`
# them afterwards, which would also drop the real definitions sourced from
# preflight.sh. Save them now so the _staging_dir assertions at the end
# exercise the shipped implementation, not a leftover stub.
eval "real_staging_dir() $(declare -f _staging_dir | tail -n +2)"

# Drive one case: stub the two host reads, capture output, assert verdict.
#   expect = "ok" | "fail" | "warn"
run() {
    local expect="$1" stub_dir="$2" stub_avail="$3" required="$4" label="$5"
    # Distinct global names: the stubs are invoked *inside*
    # check_image_staging_space, which declares its own `local dir`/`avail`
    # — under bash dynamic scope a same-named var would resolve to that
    # not-yet-assigned local and trip `set -u`.
    STUB_DIR="$stub_dir"
    STUB_AVAIL="$stub_avail"

    # Invoked indirectly by the sourced check; shellcheck can't see across
    # that call and flags them unreachable.
    # shellcheck disable=SC2317
    _staging_dir() { printf '%s\n' "$STUB_DIR"; }
    # shellcheck disable=SC2317
    _dir_avail_mb() { printf '%s\n' "$STUB_AVAIL"; }

    local out err rc
    err=$(mktemp)
    out=$(STAGING_REQUIRED_MB="$required" check_image_staging_space 2>"$err") && rc=0 || rc=$?
    local stderr_out; stderr_out=$(cat "$err"); rm -f "$err"

    unset -f _staging_dir _dir_avail_mb

    local got="ok"
    if grep -q 'PREFLIGHT_FAIL' <<<"$out$stderr_out"; then
        got="fail"
    elif grep -qi 'Could not read free space' <<<"$out$stderr_out"; then
        got="warn"
    fi

    # A shortfall must be blocking: `fail` returns non-zero, and the check
    # must propagate that rather than swallowing it.
    if [[ "$got" == "fail" ]] && (( rc == 0 )); then
        echo "[FAIL] $label -> reported a shortfall but returned 0 (must block)" >&2
        fail=1
        return
    fi

    # The ok and warn paths must never abort the install.
    if [[ "$got" != "fail" ]] && (( rc != 0 )); then
        echo "[FAIL] $label -> returned $rc on a non-shortfall verdict" >&2
        fail=1
        return
    fi

    # When it blocks, it must name the redirect that fixes it, and must not
    # revive the old advice (shrinking the tmpfs cap, or masking /tmp).
    if [[ "$got" == "fail" ]]; then
        local all="$out$stderr_out"
        if ! grep -q 'image_copy_tmp_dir' <<<"$all"; then
            echo "[FAIL] $label -> blocked but omitted the image_copy_tmp_dir remedy" >&2
            fail=1
            return
        fi
        # The remedy must write a containers.conf.d drop-in, never append to
        # containers.conf: a second [engine] table in one file is a TOML
        # duplicate-key error ("Key 'engine' has already been defined") that
        # stops podman loading its config at all, breaking every podman
        # command rather than just the pull.
        if ! grep -q 'containers.conf.d' <<<"$all"; then
            echo "[FAIL] $label -> remedy does not use a containers.conf.d drop-in" >&2
            fail=1
            return
        fi
        if grep -qE '>>[[:space:]]*~?/?[^ ]*containers\.conf$' <<<"$all"; then
            echo "[FAIL] $label -> remedy appends to containers.conf (duplicate [engine])" >&2
            fail=1
            return
        fi
        if grep -q 'tmp.mount.d\|mask tmp.mount' <<<"$all"; then
            echo "[FAIL] $label -> revived the tmpfs-cap advice (wrong mechanism)" >&2
            fail=1
            return
        fi
    fi

    if [[ "$got" == "$expect" ]]; then
        echo "[ OK ] $label"
    else
        echo "[FAIL] $label -> got $got, expected $expect" >&2
        echo "------ output ------" >&2
        printf '%s\n%s\n' "$out" "$stderr_out" >&2
        echo "--------------------" >&2
        fail=1
    fi
}

# expect dir          avail  required  label
run ok   /var/tmp     4096   768  "ample space on /var/tmp -> ok"
run ok   /var/tmp     768    768  "exactly at requirement -> ok (boundary)"
run fail /var/tmp     767    768  "one MB short -> FAIL (boundary)"
run fail /tmp         200    768  "512MB tmpfs /tmp, 200MB free -> FAIL"
run fail /tmp         0      768  "staging dir full -> FAIL"
# The reported CM4: 512 MB RAM-backed /tmp cannot hold signalk-server's
# 435.6 MB peak once anything else is using it.
run fail /tmp         430    768  "CM4 512MB tmpfs, 430MB free -> FAIL"
# Unreadable free space is not a verdict: warn, don't block a host whose
# df output we couldn't parse.
run warn /var/tmp     ""     768  "free space unreadable -> warn, non-blocking"
# Threshold is overridable: lowering it lets a small dir pass.
run ok   /tmp         300    256  "tmpfs 300MB free, requirement lowered to 256 -> ok"

# _staging_dir must prefer STAGING_DIR_HINT: install.sh redirects the pull to
# its own disk-backed dir, so that is the path whose free space decides the
# outcome. Asking podman here would measure a directory the pull never uses.
hint_got=$(STAGING_DIR_HINT=/home/u/.local/share/containers/tmp real_staging_dir)
if [[ "$hint_got" == "/home/u/.local/share/containers/tmp" ]]; then
    echo "[ OK ] STAGING_DIR_HINT overrides podman's configured staging dir"
else
    echo "[FAIL] STAGING_DIR_HINT ignored -> got '$hint_got'" >&2
    fail=1
fi

# Without the hint it falls back to TMPDIR, matching containers.conf(5)'s
# documented order (TMPDIR wins over engine.image_copy_tmp_dir).
env_got=$(STAGING_DIR_HINT="" TMPDIR=/some/tmpdir PODMAN_WEDGED=1 real_staging_dir)
if [[ "$env_got" == "/some/tmpdir" ]]; then
    echo "[ OK ] falls back to TMPDIR when podman can't be asked"
else
    echo "[FAIL] TMPDIR fallback wrong -> got '$env_got'" >&2
    fail=1
fi

if (( fail )); then
    echo "[ERR] check_image_staging_space decision table has regressions" >&2
    exit 1
fi
echo "[PASS] check_image_staging_space decision table correct"
