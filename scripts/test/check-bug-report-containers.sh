#!/usr/bin/env bash
# Verifies signalk_all_containers() discovers BOTH container families:
# the installer's engine containers (signalk-*) and the ones the
# signalk-container plugin manages (<namespace>-*, default sk-*).
#
# Background — the 2026-08-18 field report. A user reported "all my
# containers vanished from the web UI" and sent a `signalk bug-report`
# bundle. Every container query in the CLI was filtered `name=signalk-`,
# so the bundle captured the 4 engine containers plus the 2 that happen
# to be named sk-signalk-* — and silently omitted sk-ollama, sk-whisper,
# sk-piper, sk-openwakeword and sk-wyoming-satellite, i.e. every single
# container the user was actually asking about. Two of them were parked
# in `created` (never started), which was the answer; it had to be
# reconstructed from an unrelated podman ps dump in another file.
#
# Sources the rendered CLI (which defines the helper without running
# main) and feeds it a stub runtime CLI. Run from repo root.

set -euo pipefail

TMPL=${TMPL:-installer/linux/signalk.tmpl}

if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Render the template so the sourced file has no __SK_VERSION__ placeholder.
sed 's/__SK_VERSION__/0.0.0-test/g' "$TMPL" >"$workdir/signalk.sh"

# The CLI's dispatcher at the bottom is `case "${1:-help}"`, i.e. it is NOT
# guarded against being sourced — sourcing it as-is would print usage (and
# with a stray $1, could dispatch a real command). Strip everything from the
# dispatcher onward so only the assignments and function definitions load.
# Keyed on the dispatcher's exact opening line.
awk '/^case "\$\{1:-help\}" in$/{exit} {print}' \
    "$workdir/signalk.sh" >"$workdir/signalk-defs.sh"

if ! grep -q 'signalk_all_containers()' "$workdir/signalk-defs.sh"; then
    echo "[ERR] helper missing after stripping dispatcher — did the dispatcher line change?" >&2
    exit 2
fi

# The awk above is keyed on the dispatcher's exact opening line. If that line
# is ever reworded the awk silently matches nothing, the whole CLI is sourced,
# and the dispatcher runs during the test — so assert the strip actually
# happened rather than trusting it.
if grep -q '^case "\${1:-help}" in$' "$workdir/signalk-defs.sh"; then
    echo "[ERR] dispatcher still present after strip — the awk pattern is stale" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$workdir/signalk-defs.sh"

if ! declare -F signalk_all_containers >/dev/null; then
    echo "[ERR] signalk_all_containers not defined after sourcing $TMPL" >&2
    exit 2
fi

# Stub runtime: emulates `<cli> ps -a --filter name=<x> --format {{.Names}}`
# with podman's real semantics — --filter name= is a SUBSTRING match.
ALL_CONTAINERS='signalk-server
signalk-updater-server
signalk-doctor-server
signalk-dbus-proxy
sk-signalk-questdb
sk-signalk-backup-server
sk-ollama
sk-whisper
sk-piper
sk-openwakeword
sk-wyoming-satellite
devpod-questdb
my-signalk-backup
unrelated-redis
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-probe'

cat >"$workdir/fakectr" <<'STUB'
#!/usr/bin/env bash
# Emulate `ps -a --filter name=<needle> --format ...` (substring match).
needle=""
for arg in "$@"; do
    case "$arg" in
        name=*) needle="${arg#name=}" ;;
    esac
done
printf '%s\n' "$ALL_CONTAINERS" | grep -F "$needle" || true
STUB
chmod +x "$workdir/fakectr"
export ALL_CONTAINERS
export PATH="$workdir:$PATH"

fail=0

assert_set() {
    local label=$1 expected=$2 got
    got=$(signalk_all_containers fakectr | paste -sd' ' -)
    if [[ "$got" == "$expected" ]]; then
        echo "  [OK]   $label"
    else
        echo "  [MISS] $label"
        echo "         expected: [$expected]"
        echo "         got:      [$got]"
        fail=1
    fi
}

# 1. The regression itself: default namespace must capture the engine
#    containers AND every sk-* the plugin manages. Output is sort -u'd.
unset SIGNALK_CONTAINER_NAMESPACE
assert_set "default namespace captures engine + all sk-* plugin containers" \
"signalk-dbus-proxy signalk-doctor-server signalk-server signalk-updater-server sk-ollama sk-openwakeword sk-piper sk-signalk-backup-server sk-signalk-questdb sk-whisper sk-wyoming-satellite"

# 2. A container merely CONTAINING the token is not swept in. `--filter
#    name=` is a substring match, so `my-signalk-backup` matches the raw
#    filter; the helper's ^-anchored grep must reject it. Same for
#    unrelated-redis, and for devpod-* when that namespace is not active.
got_all=$(signalk_all_containers fakectr)
for unwanted in my-signalk-backup unrelated-redis devpod-questdb; do
    if printf '%s\n' "$got_all" | grep -qx "$unwanted"; then
        echo "  [MISS] substring-only match '$unwanted' must not be captured"
        fail=1
    else
        echo "  [OK]   substring-only match '$unwanted' correctly excluded"
    fi
done

# 3. A devcontainer namespace adds devpod-* while keeping sk-* (a host can
#    run both stacks; the bundle should show each).
export SIGNALK_CONTAINER_NAMESPACE=devpod
assert_set "devpod namespace adds devpod-* alongside sk-*" \
"devpod-questdb signalk-dbus-proxy signalk-doctor-server signalk-server signalk-updater-server sk-ollama sk-openwakeword sk-piper sk-signalk-backup-server sk-signalk-questdb sk-whisper sk-wyoming-satellite"

# 4. An invalid namespace (typo, broken expansion) must not build a bogus
#    pattern — fall back to the defaults, same as the plugin does.
export SIGNALK_CONTAINER_NAMESPACE='bad ns!'
assert_set "invalid namespace falls back to defaults" \
"signalk-dbus-proxy signalk-doctor-server signalk-server signalk-updater-server sk-ollama sk-openwakeword sk-piper sk-signalk-backup-server sk-signalk-questdb sk-whisper sk-wyoming-satellite"

# 5. Explicit `sk` namespace resolves to exactly the default set. Asserted
#    as an exact set, NOT with `uniq -d`: the helper ends in `sort -u`, so a
#    duplicate check passes for every possible input and proves nothing.
export SIGNALK_CONTAINER_NAMESPACE=sk
assert_set "namespace 'sk' matches the default set" \
"signalk-dbus-proxy signalk-doctor-server signalk-server signalk-updater-server sk-ollama sk-openwakeword sk-piper sk-signalk-backup-server sk-signalk-questdb sk-whisper sk-wyoming-satellite"

# 5b. An over-long namespace is invalid (the plugin caps it at 32 chars) and
#     must fall back to the defaults. ALL_CONTAINERS carries a container
#     named for that 40-char prefix, so without the length guard the helper
#     would pick it up and this assertion fails — i.e. the case is
#     falsifiable rather than vacuously true.
long_ns=$(printf 'a%.0s' {1..40})
export SIGNALK_CONTAINER_NAMESPACE="$long_ns"
assert_set "over-long namespace falls back to defaults" \
"signalk-dbus-proxy signalk-doctor-server signalk-server signalk-updater-server sk-ollama sk-openwakeword sk-piper sk-signalk-backup-server sk-signalk-questdb sk-whisper sk-wyoming-satellite"

# 6. No containers at all → empty output, no error under set -e. Run in a
#    subshell so the ALL_CONTAINERS override cannot leak into later tests.
unset SIGNALK_CONTAINER_NAMESPACE
( ALL_CONTAINERS=''; export ALL_CONTAINERS
  assert_set "no containers → empty result" "" ) || fail=1

# 7. Static guard against reintroducing the bug. The helper exists so that
#    no call site hand-rolls `--filter name=signalk-` again; a new diagnostic
#    added later would silently reacquire the original blind spot. Comments
#    are stripped first — the helper and several call sites document the old
#    form by quoting it, and matching those would make this unfalsifiable.
#    scripts/doctor.sh is covered too: it is standalone (it cannot source the
#    helper) so it duplicates the logic, and it had the identical blind spot.
# Blank comment lines rather than deleting them, so grep -n reports line
# numbers that match $TMPL itself — with grep -v the stream is renumbered
# and every reported location would be wrong. The character class covers
# the unquoted, single- and double-quoted spellings of the filter.
DOCTOR_SH=${DOCTOR_SH:-scripts/doctor.sh}
offenders=""
for src in "$TMPL" "$DOCTOR_SH"; do
    [[ -f "$src" ]] || continue
    hits=$(sed 's/^[[:space:]]*#.*$//' "$src" \
        | grep -nE "filter[ =]+[\"']?name=signalk-" || true)
    [[ -n "$hits" ]] && offenders+="$src:$hits"$'\n'
done
offenders=${offenders%$'\n'}
if [[ -z "$offenders" ]]; then
    echo "  [OK]   no call site hand-rolls the signalk- only filter"
else
    echo "  [MISS] a call site still filters on 'name=signalk-' directly:"
    printf '         %s
' "$offenders"
    echo "         use signalk_all_containers() instead — it covers sk-* too"
    fail=1
fi

if (( fail )); then
    echo
    echo "[ERR] bug-report container discovery is wrong — see entries above." >&2
    exit 1
fi
echo
echo "[OK] bug-report captures engine and plugin-managed containers."
