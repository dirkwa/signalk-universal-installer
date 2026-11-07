#!/usr/bin/env bash
# Verifies install.sh's install_stdin, and that the scripts and docs no longer
# name /dev/stdin: uutils install, Ubuntu's coreutils since 25.10, fails with
# "install: No such file or directory" on it when the destination exists.
#   1. A new file gets the content and the mode given.
#   2. An existing file is replaced and gets the mode given.
#   3. -D creates the missing parent directories.
#   4. A failing install returns non-zero and creates nothing.
#   5. No case leaves a temp file behind.
#   6. No line outside a comment in installer/, scripts/ (scripts/test/ aside)
#      or docs/ names /dev/stdin or its aliases /dev/fd/0 and /proc/self/fd/0.
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

FN=$(awk '/^install_stdin\(\) \{/{p=1} p{print} p && /^\}/{exit}' "$INSTALL_SH")
if [[ "$FN" != *'install_stdin() {'* ]]; then
    echo "[ERR] could not extract install_stdin from $INSTALL_SH" >&2
    exit 2
fi
eval "$FN"

# The function's temp files land in $TMPDIR, so case 5 can look for them.
export TMPDIR="$tmp/temp"
mkdir -p "$TMPDIR" "$tmp/root"
# shellcheck disable=SC2034  # read by install_stdin, loaded by the eval above
SUDO=""

# 1. A new file.
printf 'one\n' | install_stdin -m 0640 "$tmp/root/new"
if [[ "$(cat "$tmp/root/new")" == one && "$(stat -c %a "$tmp/root/new")" == 640 ]]; then
    ok "new file: content and mode 0640"
else
    miss "new file: content '$(cat "$tmp/root/new" 2>&1)', mode $(stat -c %a "$tmp/root/new" 2>&1)"
fi

# 2. An existing file, the case uutils install fails on with /dev/stdin.
printf 'old\n' >"$tmp/root/old"
chmod 0600 "$tmp/root/old"
if printf 'two\n' | install_stdin -m 0644 "$tmp/root/old" \
    && [[ "$(cat "$tmp/root/old")" == two && "$(stat -c %a "$tmp/root/old")" == 644 ]]; then
    ok "existing file: replaced, mode 0600 -> 0644"
else
    miss "existing file: content '$(cat "$tmp/root/old" 2>&1)', mode $(stat -c %a "$tmp/root/old" 2>&1)"
fi

# 3. -D and missing parents.
if printf 'three\n' | install_stdin -D -m 0644 "$tmp/root/a/b/c" \
    && [[ "$(cat "$tmp/root/a/b/c")" == three ]]; then
    ok "-D: parent directories created"
else
    miss "-D: $tmp/root/a/b/c not written"
fi

# 4. install fails: SUDO=false makes `$SUDO install ...` exit 1.
rc=0
printf 'four\n' | SUDO=false install_stdin -m 0644 "$tmp/root/failed" || rc=$?
if (( rc != 0 )) && [[ ! -e "$tmp/root/failed" ]]; then
    ok "failing install: exit $rc, nothing written"
else
    miss "failing install: exit $rc, $tmp/root/failed $( [[ -e "$tmp/root/failed" ]] && echo exists || echo absent)"
fi

# 5. Temp files.
left=$(ls -A "$TMPDIR")
if [[ -z "$left" ]]; then
    ok "no temp file left behind"
else
    miss "temp files left in \$TMPDIR: $left"
fi

# 6. /dev/stdin outside comments. A line continuation or a `$#` before the
#    path does not hide it, and neither does a string that is not an install
#    call; the message then names the line to look at.
hits=$(grep -rnE '/dev/stdin|/dev/fd/0|/proc/self/fd/0' installer scripts docs \
    --include='*.sh' --include='*.bash' --include='*.tmpl' --include='*.md' \
    --exclude-dir=test | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -z "$hits" ]]; then
    ok "no line outside a comment names /dev/stdin"
else
    miss "these lines name /dev/stdin; uutils install fails on it when the destination exists, so use install_stdin or a temp file:"
    printf '         %s\n' "$hits"
fi

if (( fail )); then
    echo "[FAIL] check-install-stdin"
    exit 1
fi
echo "[PASS] check-install-stdin"
