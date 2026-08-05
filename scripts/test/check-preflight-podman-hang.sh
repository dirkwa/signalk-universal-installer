#!/usr/bin/env bash
# Verifies preflight refuses to hang when podman's storage lock is stuck.
#
# The incident this pins: on a Pi 4 with a wedged podman, `curl … | bash` of the
# installer stopped dead after the /tmp notice and printed NOTHING further --
# no error, no diagnosis, no exit. preflight's first storage-touching check
# (check_ports -> managed_container_running -> `podman ps`) had blocked on the
# c/storage lock, and podman does not fail when that lock is stuck, it blocks
# forever. The operator was left with a silent terminal on a boat.
#
# Why the stub IGNORES SIGTERM, and why that is the whole point: a podman wedged
# on that lock spins in kernel space and does not die on SIGTERM. timeout(1)
# sends SIGTERM and then WAITS for the child, so a plain `timeout` bounds
# nothing. Measured against this stub, `timeout 3` returned only after 121
# SECONDS. Do not simplify this back to a bare `sleep`, which DOES die on
# SIGTERM and would let the test pass against code that still hangs.
#
# Run from repo root.

set -euo pipefail

PREFLIGHT=${PREFLIGHT:-installer/linux/preflight.sh}

if [[ ! -f "$PREFLIGHT" ]]; then
    echo "[ERR] $PREFLIGHT not found (run from repo root)" >&2
    exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/podman" <<'STUB'
#!/bin/sh
# A podman wedged on the c/storage lock: ignores SIGTERM, outlives any guard.
trap '' TERM
i=0; while [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
STUB
chmod +x "$TMP/bin/podman"

fail=0

# The guard is 2s + 1s escalation. Anything under 30s proves the escalation
# landed; a regression to plain `timeout` blows straight past it.
CEILING=30

start=$(date +%s)
# FORCE=1 so the run continues past the deliberate failure and we can observe
# that the LATER podman-dependent checks also decline to hang.
out=$(PATH="$TMP/bin:$PATH" PODMAN_TIMEOUT=2 PODMAN_KILL_AFTER=1 FORCE=1 \
    bash "$PREFLIGHT" 2>&1 || true)
elapsed=$(( $(date +%s) - start ))

if [[ $elapsed -ge $CEILING ]]; then
    echo "  [MISS] preflight did not return promptly (${elapsed}s >= ${CEILING}s)"
    echo "         plain \`timeout\` waits out a SIGTERM-ignoring child;"
    echo "         the guard needs \`timeout -k\`."
    fail=1
else
    echo "  [OK]   preflight returned in ${elapsed}s instead of hanging"
fi

# A silent hang was the actual failure; a silent *exit* would be no better.
if grep -q 'did not answer within' <<<"$out"; then
    echo "  [OK]   reports the wedge explicitly"
else
    echo "  [MISS] returned without naming the wedge"
    fail=1
fi

# The diagnosis is only useful if it says what to run.
if grep -q 'unwedge-podman' <<<"$out"; then
    echo "  [OK]   points at the recovery command"
else
    echo "  [MISS] no recovery command in the output"
    fail=1
fi

# Under FORCE=1 the run continues, and every later podman-dependent check must
# skip rather than block -- otherwise the hang simply moves further down.
if grep -q 'Skipped orphan-container scan' <<<"$out"; then
    echo "  [OK]   later podman-dependent checks skip cleanly"
else
    echo "  [MISS] later checks did not skip (they may still block)"
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] preflight podman hang guard"
    exit 1
fi
echo "[PASS] preflight podman hang guard"
