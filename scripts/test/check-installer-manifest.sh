#!/usr/bin/env bash
# Verifies install.sh's curl-piped fetch list against the repo.
#
# The curl-piped path (`curl -fsSL .../install.sh | bash`) downloads a
# hardcoded list of files into a tempdir before re-exec'ing install.sh
# from there. When a contributor adds a new file the runtime depends on
# but forgets to update the fetch list, local-clone installs keep
# working but the bash one-liner fails partway through. This script
# closes that gap by:
#
#   1. Parsing the fetch list out of install.sh.
#   2. Asserting every path resolves to an existing file in the repo.
#   3. Optionally asserting every path returns HTTP 200 from the
#      GitHub Pages base (--remote; off by default in CI so we don't
#      flake on Pages-deploy races right after a merge).
#
# Exits non-zero on the first missing path. Run from the repo root.

set -euo pipefail

INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}
BASE_URL=${INSTALLER_BASE_URL:-https://dirkwa.github.io/signalk-universal-installer}
CHECK_REMOTE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) CHECK_REMOTE=1 ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[ERR] unknown flag: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "[ERR] $INSTALL_SH not found (run from repo root)" >&2
    exit 2
fi

# Extract the fetch list. The block opens with `for f in \` and ends on
# the line containing `; do`. Inside the block, each entry is a relative
# path optionally followed by a trailing backslash for line continuation
# or `; do` on the final entry. awk handles the multi-line shape; we
# stop reading the moment the `; do` terminator appears so we don't
# greedily consume the rest of install.sh.
mapfile -t paths < <(awk '
    /^[[:space:]]*for f in[[:space:]]*\\[[:space:]]*$/ {
        inblock = 1
        next
    }
    inblock {
        line = $0
        # Note whether this line is the terminator before we strip ; do.
        terminates = (line ~ /;[[:space:]]*do[[:space:]]*$/)
        # Remove trailing backslash continuation or "; do" terminator.
        sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
        sub(/[[:space:]]*;[[:space:]]*do[[:space:]]*$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "") print line
        if (terminates) {
            inblock = 0
            exit
        }
    }
' "$INSTALL_SH")

if [[ ${#paths[@]} -eq 0 ]]; then
    echo "[ERR] could not parse fetch list out of $INSTALL_SH" >&2
    exit 2
fi

echo "[i] parsed ${#paths[@]} path(s) from $INSTALL_SH"

fail=0
# Check 1: every entry in the fetch list must exist in the repo. Catches
# the "added entry for a file we never created" direction.
for p in "${paths[@]}"; do
    if [[ -f "$p" ]]; then
        printf '  [OK]   %s\n' "$p"
    else
        printf '  [MISS] %s (in fetch list but not in repo)\n' "$p"
        fail=1
    fi
done

# Check 2: every runtime file in the repo must be in the fetch list.
# This is the direction that caught us when signalk.tmpl shipped without
# being listed. Scan the same directories the fetch list pulls from and
# warn on any file not referenced.
#
# Patterns are intentionally conservative — they match the kinds of files
# install.sh re-execs or sources. Add new patterns here (or to the
# allowlist below) when the install path grows.
declare -A in_list=()
for p in "${paths[@]}"; do
    in_list["$p"]=1
done

# Files that exist under installer/ or quadlets/ but are deliberately NOT
# in the fetch list. Keep this short and commented so it doesn't become
# a parking lot.
declare -A allowlist=(
    # (none yet — every file under installer/linux/ + quadlets/ is
    # currently runtime-required by the curl-piped path.)
    [unused]=1
)
unset 'allowlist[unused]'

echo
echo "[i] checking runtime files are listed"
while IFS= read -r -d '' p; do
    if [[ -n "${in_list[$p]:-}" ]]; then
        continue
    fi
    if [[ -n "${allowlist[$p]:-}" ]]; then
        printf '  [SKIP] %s (allowlisted)\n' "$p"
        continue
    fi
    printf '  [MISS] %s (in repo but not in fetch list)\n' "$p"
    fail=1
done < <(find installer/linux quadlets -type f \
    \( -name '*.sh' -o -name '*.tmpl' -o -name '*.template' \) \
    -print0)

if (( CHECK_REMOTE )); then
    echo
    echo "[i] checking $BASE_URL"
    for p in "${paths[@]}"; do
        # Assign outside the substitution: curl prints its own status via -w and
        # ALSO exits non-zero on failure, so `|| echo "000"` inside would append
        # (see #229). No -f: it makes curl exit non-zero on 4xx/5xx too, so the
        # fallback would overwrite a real 404 with "000" and the diagnostic
        # below would lose the status it exists to report. Without -f only a
        # genuine connection failure trips the fallback.
        code=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/${p}") || code="000"
        if [[ "$code" == "200" ]]; then
            printf '  [%s] %s\n' "$code" "$p"
        else
            printf '  [%s] %s — not served by Pages\n' "$code" "$p"
            fail=1
        fi
    done
fi

if (( fail )); then
    echo
    echo "[ERR] fetch-list manifest is inconsistent — see entries above." >&2
    exit 1
fi
echo
echo "[OK] fetch list is consistent."
