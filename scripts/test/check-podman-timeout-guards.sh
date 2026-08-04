#!/usr/bin/env bash
# Verifies the diagnostic tools stay responsive when podman is wedged.
#
# Background: podman blocks FOREVER rather than erroring when the c/storage
# lock is held by a stuck incomplete-layer cleanup. doctor.sh and
# signalk-recovery both call podman, so unguarded they hang at exactly the
# moment an operator needs them — signalk-recovery being the tier-3 SSH-only
# safety net makes that especially bad.
#
# Why the stub IGNORES SIGTERM, and why that is the entire point of this test:
# a wedged podman is spinning in kernel space and does not die on SIGTERM.
# timeout(1) sends SIGTERM, and when the child ignores it timeout WAITS for the
# child rather than returning — so a plain `timeout` bounds nothing. Measured
# against this stub, `timeout 3` returned 124 only after 121 SECONDS with the
# process still alive; `timeout -k 2 3` returned after 5s.
#
# An earlier revision of these guards was "verified" with a stub that ran a
# plain `sleep`, which DOES die on SIGTERM. That test passed while the real
# failure mode was untouched. Do not simplify this stub back to a bare sleep.
#
# Run from repo root.

set -euo pipefail

DOCTOR=${DOCTOR:-scripts/doctor.sh}
RECOVERY=${RECOVERY:-installer/linux/signalk-recovery.tmpl}

for f in "$DOCTOR" "$RECOVERY"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stub podman: ignores SIGTERM and outlives any sane guard window.
cat > "$TMP/bin/podman" <<'STUB'
#!/bin/sh
trap '' TERM
i=0; while [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
STUB
chmod +x "$TMP/bin/podman"

fail=0

# Generous ceiling: the guard is 2s + 1s escalation, so anything under 30s
# proves the escalation landed. A regression to plain `timeout` blows past it.
CEILING=30

assert_bounded() {
    local label=$1; shift
    local start elapsed out
    start=$(date +%s)
    # The tools are expected to keep going and exit non-zero or zero on their
    # own terms; we only care that they RETURN and say something useful.
    out=$(PATH="$TMP/bin:$PATH" PODMAN_TIMEOUT=2 PODMAN_KILL_AFTER=1 \
        "$@" 2>&1 || true)
    elapsed=$(( $(date +%s) - start ))

    if [[ $elapsed -ge $CEILING ]]; then
        echo "  [MISS] $label did not return promptly (${elapsed}s >= ${CEILING}s)"
        echo "         plain \`timeout\` waits out a SIGTERM-ignoring child;"
        echo "         the guard needs \`timeout -k\`."
        fail=1
        return
    fi
    if ! grep -qi 'did not answer' <<<"$out"; then
        echo "  [MISS] $label returned in ${elapsed}s but never reported the wedge"
        echo "         output was: $(head -c 200 <<<"$out")"
        fail=1
        return
    fi
    echo "  [OK]   $label returned in ${elapsed}s and reported the wedge"
}

assert_bounded "doctor.sh"              bash "$DOCTOR"
assert_bounded "signalk-recovery doctor" bash "$RECOVERY" doctor

# The recovery dump must not stop at its first podman call — the sections after
# it are the ones that still work when podman does not.
reach=$(PATH="$TMP/bin:$PATH" PODMAN_TIMEOUT=2 PODMAN_KILL_AFTER=1 \
    bash "$RECOVERY" doctor 2>&1 || true)
if grep -q 'systemd-user signalk-\* units' <<<"$reach"; then
    echo "  [OK]   recovery dump continues past the wedged podman section"
else
    echo "  [MISS] recovery dump stopped at the podman section"
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] podman timeout guards"
    exit 1
fi
echo "[PASS] podman timeout guards"
