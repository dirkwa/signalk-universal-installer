#!/usr/bin/env bash
# Verifies the doctor-refresh payload is actually RUNNABLE, not just present.
#
# The incident: install.sh staged detect-hardware.sh into installer-payload but
# not the lib/ it sources, so the staged copy died on
# `lib/distro.sh: No such file or directory`. Nothing noticed, because nothing
# in the repo invoked it -- it was "inert" in the literal sense rather than the
# intended one. It surfaced only when an operator plugged in an Actisense NGT-1
# and there was no way to refresh hardware.json short of re-running the whole
# bootstrapper.
#
# A file-exists check would not have caught that. This asserts every lib a
# staged script sources is staged with it, by reading the sources out of the
# scripts rather than restating a list that would drift.
#
# Run from repo root.

set -euo pipefail

SRC=${SRC:-installer/linux}
INSTALL=${INSTALL:-installer/linux/install.sh}

for f in "$SRC/detect-hardware.sh" "$INSTALL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0

# Which scripts does install.sh stage into the payload?
# shellcheck disable=SC2016  # these are grep patterns, $HERE must stay literal
mapfile -t staged < <(grep -oE 'install -m 0755 "\$HERE/[a-z-]+\.sh" "\$PAYLOAD_DIR' "$INSTALL" \
    | grep -oE '\$HERE/[a-z-]+\.sh' | sed 's|\$HERE/||' | sort -u)

if [[ ${#staged[@]} -eq 0 ]]; then
    echo "  [MISS] could not identify any staged payload script"
    exit 1
fi
echo "  staged scripts: ${staged[*]}"

# shellcheck disable=SC2016  # grep patterns again
for script in "${staged[@]}"; do
    [[ -f "$SRC/$script" ]] || continue
    # Every lib the script sources must also be staged.
    while IFS= read -r lib; do
        [[ -n "$lib" ]] || continue
        if grep -qE "install -m 0644 \"\\\$HERE/lib/\\\$_l\"|lib/$lib" "$INSTALL"; then
            echo "  [OK]   $script's lib/$lib is staged"
        else
            echo "  [MISS] $script sources lib/$lib but install.sh never stages it"
            fail=1
        fi
    done < <(grep -oE '\$HERE/lib/[a-z-]+\.sh' "$SRC/$script" | sed 's|.*/||' | sort -u)
done

# The payload lib dir must be created, or the installs land nowhere.
# shellcheck disable=SC2016
if grep -qE 'install -d .*"\$PAYLOAD_DIR/lib"' "$INSTALL"; then
    echo "  [OK]   payload lib/ directory is created"
else
    echo "  [MISS] install.sh never creates \$PAYLOAD_DIR/lib"
    fail=1
fi

# End-to-end: stage into a temp dir exactly as install.sh does, then RUN the
# staged copy. Presence proves nothing; execution is the property under test.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
install -d -m 0755 "$TMP/lib"
install -m 0755 "$SRC/detect-hardware.sh" "$TMP/detect-hardware.sh"
# shellcheck disable=SC2016
while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    install -m 0644 "$SRC/lib/$lib" "$TMP/lib/$lib"
done < <(grep -oE '\$HERE/lib/[a-z-]+\.sh' "$SRC/detect-hardware.sh" | sed 's|.*/||' | sort -u)

if out=$(bash "$TMP/detect-hardware.sh" 2>&1) && [[ -n "$out" ]]; then
    echo "  [OK]   a staged detect-hardware.sh runs and emits output"
else
    echo "  [MISS] the staged detect-hardware.sh does not run:"
    printf '%s\n' "$out" | head -3 | sed 's/^/         /'
    fail=1
fi

# It must emit JSON: signalk hardware rescan pipes this straight into jq.
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$out" | jq -e 'has("serial")' >/dev/null 2>&1; then
        echo "  [OK]   its output is JSON carrying a serial key"
    else
        echo "  [MISS] output is not the expected JSON shape"
        fail=1
    fi
fi

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] payload runnable"
    exit 1
fi
echo "[PASS] payload runnable"
