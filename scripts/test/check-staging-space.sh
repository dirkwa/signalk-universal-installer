#!/usr/bin/env bash
# Verifies check_image_staging_space() in installer/linux/preflight.sh gates
# the install on free space in the directory `podman pull` stages into.
#
# Why the check exists: podman decompresses each image layer into a
# container_images_storage* dir under its staging path before committing the
# layer to the store. Measured against a clean store, signalk-server:dirkwa
# (1.4 GB image) peaked at 435.6 MB of staging and signalk-doctor-server
# (297 MB image) at 96 MB. A staging dir smaller than that peak — a
# RAM-backed /var/tmp (podman's default staging path) or /tmp — fails the
# pull outright. Reported from a 4 GB CM4 whose /var/tmp was tmpfs at
# size=262144k, 256 MB, against a 435.6 MB staging peak.
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

# Every mktemp path this script creates, removed from one EXIT trap. The
# explicit rm calls below stay — they keep each probe's scope obvious — but a
# command failing between mktemp and its rm would otherwise leave the path in
# /tmp. Registering is cheap and removing twice is harmless.
# scratch() must assign in the PARENT shell: a `p=$(scratch ...)` form runs the
# function in a subshell, where the array append is discarded when the
# substitution ends — leaving the trap with nothing to remove. Take the
# variable name instead and assign through it.
SCRATCH=()
scratch() {
    local -n _dest=$1
    _dest=$(mktemp "${@:2}")
    SCRATCH+=("$_dest")
}
cleanup_scratch() { (( ${#SCRATCH[@]} )) && rm -rf -- "${SCRATCH[@]}"; return 0; }
trap cleanup_scratch EXIT


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
eval "real_dir_avail_mb() $(declare -f _dir_avail_mb | tail -n +2)"

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
    scratch err
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
run fail /tmp         200    768  "tmpfs /tmp, 200MB free -> FAIL"
run fail /tmp         0      768  "staging dir full -> FAIL"
# The reported CM4: /var/tmp on tmpfs at 256 MB. Podman stages there by
# default, so signalk-server's 435.6 MB peak never fits — measured free
# space is the whole cap, and it is still short.
run fail /var/tmp     256    768  "CM4 256MB tmpfs /var/tmp -> FAIL"
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

# A failing `df` must degrade to the warn path, not abort preflight. The
# stubbed cases above pass an empty string through _dir_avail_mb, which does
# not exercise the pipeline itself: preflight runs under `set -euo pipefail`,
# so a df that exits non-zero fails the pipeline, and the unguarded
# `avail=$(_dir_avail_mb "$dir")` in the caller would kill the whole preflight
# under set -e — before reaching the warn branch written for this case.
#
# Run in a separate bash process rather than a $(…) subshell here: `set -e` is
# not inherited into command substitution in this harness, so a subshell would
# report SURVIVED either way and the assertion would pass against the bug.
df_probe=""; scratch df_probe
cat >"$df_probe" <<'PROBE'
set -euo pipefail
# shellcheck source=/dev/null
. "${PREFLIGHT:-installer/linux/preflight.sh}" >/dev/null 2>&1
fail() { echo "PREFLIGHT_FAIL: $*"; return 1; }
_staging_dir() { printf '%s\n' /var/tmp; }
df() { return 1; }
check_image_staging_space
echo "SURVIVED"
PROBE
df_out=$(PREFLIGHT="$PREFLIGHT" bash "$df_probe" 2>&1 || true)
rm -f "$df_probe"
if grep -q 'SURVIVED' <<<"$df_out" && grep -qi 'Could not read free space' <<<"$df_out"; then
    echo "[ OK ] a failing df warns and continues (does not abort preflight)"
else
    echo "[FAIL] a failing df aborted the check instead of warning" >&2
    printf '%s\n' "$df_out" >&2
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

# A relative staging path must still be measured. SK_STAGING_DIR is settable
# from the environment, and a relative value made the ancestor walk stop on a
# bare segment and return empty — which reads as "could not measure" and skips
# the check, while install.sh creates and pulls into that same path. Empty
# input stays empty: there is genuinely nothing to measure.
rel_avail=$(real_dir_avail_mb "cache/podman" 2>/dev/null || true)
empty_avail=$(real_dir_avail_mb "" 2>/dev/null || true)
if [[ "$rel_avail" =~ ^[0-9]+$ ]] && [[ -z "$empty_avail" ]]; then
    echo "[ OK ] a relative staging path is measured, an empty one is not"
else
    echo "[FAIL] relative path handling wrong -> relative='${rel_avail:-<empty>}' empty='${empty_avail:-<empty>}'" >&2
    fail=1
fi

# A malformed numeric override must be rejected by name. These are documented
# settings, so a typo reaches them; under `set -u` a non-numeric value dies
# inside the first (( … )) with bash's own "unbound variable" and no clue
# which setting was wrong.
for bad_case in "STAGING_REQUIRED_MB=foo" "REQUIRED_DISK_GB=-5" "REQUIRED_RAM_MB=1.5"; do
    bad_name=${bad_case%%=*}
    bad_out=$(env "$bad_case" bash "$PREFLIGHT" 2>&1 | head -3 || true)
    if grep -q "$bad_name must be a whole number" <<<"$bad_out"; then
        echo "[ OK ] $bad_case rejected by name"
    else
        echo "[FAIL] $bad_case not rejected cleanly" >&2
        printf '%s\n' "$bad_out" >&2
        fail=1
    fi
done

# --- the store resolver must follow a relocated store ---------------------
# The images land on the container store's filesystem, which storage.conf's
# rootless_storage_path can move off $HOME's disk. podman_storage_root must
# report where podman will ACTUALLY put the store, not a hand-derived XDG
# default — deriving it by hand reports the wrong filesystem on such a host,
# so check_disk would measure a disk the images never touch and pass a host
# whose real store is full.
#
# Exercise the shipped resolver against a real podman with a pinned
# CONTAINERS_STORAGE_CONF, rather than stubbing it: a stub would assert the
# test's own arithmetic and could not catch the resolver reading the wrong
# source. Skipped when podman is unavailable — there is nothing to resolve.
if command -v podman >/dev/null 2>&1; then
    store_tmp=""; scratch store_tmp -d
    moved="$store_tmp/moved-store"
    mkdir -p "$moved"
    printf '[storage]\ndriver = "overlay"\nrootless_storage_path = "%s"\n' \
        "$moved" >"$store_tmp/storage.conf"

    resolved=$(CONTAINERS_STORAGE_CONF="$store_tmp/storage.conf" PREFLIGHT="$PREFLIGHT" \
        bash -c '. "${PREFLIGHT:-installer/linux/preflight.sh}" >/dev/null 2>&1; podman_storage_root' \
        2>/dev/null || true)

    if [[ "$resolved" == "$moved" ]]; then
        echo "[ OK ] podman_storage_root follows rootless_storage_path"
    else
        echo "[FAIL] podman_storage_root ignored rootless_storage_path" >&2
        echo "       expected '$moved', got '${resolved:-<empty>}'" >&2
        fail=1
    fi

    # Wedged podman must not be probed: podman_guarded would burn its timeout
    # on a host check_podman_responsive has already diagnosed. Falls back to
    # the default layout instead.
    #
    # Pin XDG_DATA_HOME at a directory this test creates, rather than letting
    # the fallback walk the ambient home: podman_storage_root climbs to the
    # nearest existing ancestor, so on a host that has never run rootless
    # podman it would return ~/.local/share or $HOME and fail for host
    # reasons rather than a code defect.
    mkdir -p "$store_tmp/xdg/containers/storage"
    wedged=$(PREFLIGHT="$PREFLIGHT" XDG_DATA_HOME="$store_tmp/xdg" \
        bash -c '. "${PREFLIGHT:-installer/linux/preflight.sh}" >/dev/null 2>&1
        PODMAN_WEDGED=1 podman_storage_root' 2>/dev/null || true)
    if [[ "$wedged" == "$store_tmp/xdg/containers/storage" ]]; then
        echo "[ OK ] podman_storage_root falls back when podman is wedged"
    else
        echo "[FAIL] wedged fallback wrong -> '${wedged:-<empty>}'" >&2
        fail=1
    fi

    rm -rf "$store_tmp"
else
    echo "[SKIP] podman not installed — store resolver not exercised"
fi

# --- check_disk must measure the store's filesystem, not just $HOME -------
# With the resolver correct, check_disk has to actually consult it and fail
# when that filesystem is short. $HOME ample, store short, different devices.
disk_probe=""; scratch disk_probe
cat >"$disk_probe" <<'PROBE'
set -euo pipefail
# shellcheck source=/dev/null
. "${PREFLIGHT:-installer/linux/preflight.sh}" >/dev/null 2>&1
fail() { echo "PREFLIGHT_FAIL: $*"; return 1; }
podman_storage_root() { printf '%s\n' /mnt/moved-store; }
df() {
    local last="${!#}"
    case "$last" in
        /mnt/moved-store*)
            if [[ "$*" == *--output=source* ]]; then printf 'Filesystem\ntmpfs\n'
            else printf 'Avail\n2G\n'; fi ;;
        *)
            if [[ "$*" == *--output=source* ]]; then printf 'Filesystem\n/dev/sda2\n'
            else printf 'Avail\n500G\n'; fi ;;
    esac
}
REQUIRED_DISK_GB=5 check_disk
PROBE
disk_out=$(PREFLIGHT="$PREFLIGHT" bash "$disk_probe" 2>&1 || true)
rm -f "$disk_probe"
if grep -q 'PREFLIGHT_FAIL' <<<"$disk_out" && grep -q 'container store' <<<"$disk_out"; then
    echo "[ OK ] check_disk fails when the store's filesystem is short"
else
    echo "[FAIL] check_disk missed a short container store on another filesystem" >&2
    printf '%s\n' "$disk_out" >&2
    fail=1
fi

# check_disk's own df pipelines must degrade to the warn path too — the same
# pipefail hazard _dir_avail_mb guards. A plain assignment from a failing df
# aborts the whole preflight under set -e, before the empty-value branch can
# report anything. Separate bash process for the reason noted above.
cd_probe=""; scratch cd_probe
cat >"$cd_probe" <<'PROBE'
set -euo pipefail
# shellcheck source=/dev/null
. "${PREFLIGHT:-installer/linux/preflight.sh}" >/dev/null 2>&1
fail() { echo "PREFLIGHT_FAIL: $*"; return 1; }
df() { return 1; }
check_disk
echo "SURVIVED"
PROBE
cd_out=$(PREFLIGHT="$PREFLIGHT" bash "$cd_probe" 2>&1 || true)
rm -f "$cd_probe"
if grep -q 'SURVIVED' <<<"$cd_out" && grep -qi 'Could not read free disk' <<<"$cd_out"; then
    echo "[ OK ] check_disk warns and continues when df fails"
else
    echo "[FAIL] check_disk aborted preflight instead of warning on a failing df" >&2
    printf '%s\n' "$cd_out" >&2
    fail=1
fi

# On a default host the store shares $HOME's filesystem: report once, not
# twice, and do not fail for a disk already checked.
same_probe=""; scratch same_probe
cat >"$same_probe" <<'PROBE'
set -euo pipefail
# shellcheck source=/dev/null
. "${PREFLIGHT:-installer/linux/preflight.sh}" >/dev/null 2>&1
fail() { echo "PREFLIGHT_FAIL: $*"; return 1; }
podman_storage_root() { printf '%s\n' "$HOME/.local/share/containers"; }
df() {
    if [[ "$*" == *--output=source* ]]; then printf 'Filesystem\n/dev/sda2\n'
    else printf 'Avail\n500G\n'; fi
}
REQUIRED_DISK_GB=5 check_disk
PROBE
same_out=$(PREFLIGHT="$PREFLIGHT" bash "$same_probe" 2>&1 || true)
rm -f "$same_probe"
if [[ "$(grep -c 'Free disk' <<<"$same_out")" == "1" ]] \
    && ! grep -q 'PREFLIGHT_FAIL' <<<"$same_out"; then
    echo "[ OK ] check_disk reports once when the store shares \$HOME's filesystem"
else
    echo "[FAIL] check_disk double-reported or failed on a single-filesystem host" >&2
    printf '%s\n' "$same_out" >&2
    fail=1
fi

# --- staging must land on the store's own filesystem ----------------------
# install.sh derives the staging dir from GraphRoot. The normal shape is
# …/containers/storage, where a sibling …/containers/tmp shares the
# filesystem and sits outside the store (podman system reset wipes the store
# directory). But GraphRoot can itself be a mount point — rootless_storage_path
# aimed at a dedicated disk — and then the sibling is on the PARENT filesystem,
# defeating the colocation. Extract the derivation from install.sh and drive it
# with both shapes, using /dev/shm as a real mount point whose parent (/dev) is
# a different filesystem.
INSTALL_SH=${INSTALL_SH:-installer/linux/install.sh}

# Run install.sh's own lines, not a copy of them: a re-implementation here
# would keep passing while install.sh changed the device comparison or the
# fallback target — the drift class this file already guards for
# docs/installation.md. Cut the block between the sibling assignment and the
# fi that closes its if, and feed it to bash with SK_GRAPHROOT preset.
staging_branch=$(sed -n '/^ *SK_STAGING_SIBLING=/,/^ *fi$/p' "$INSTALL_SH")

if [[ -z "$staging_branch" ]]; then
    echo "[FAIL] could not extract the staging derivation from $INSTALL_SH" >&2
    fail=1
else
    derive_staging() {
        SK_GRAPHROOT=$1 bash -c "
            set -u
            $staging_branch
            printf '%s\n' \"\$SK_STAGING_DIR\""
    }

    normal_store="$HOME/.local/share/containers/storage"
    got_normal=$(derive_staging "$normal_store" 2>/dev/null || true)
    if [[ "$got_normal" == "$(dirname "$normal_store")/tmp" ]]; then
        echo "[ OK ] normal GraphRoot stages in the sibling containers/tmp"
    else
        echo "[FAIL] normal GraphRoot derivation wrong -> '${got_normal:-<empty>}'" >&2
        fail=1
    fi

    # /dev/shm is a mount point on every Linux host running this installer,
    # and /dev is a different filesystem — the exact shape that breaks a
    # blind sibling.
    if [[ -d /dev/shm ]] \
        && [[ "$(stat -c '%d' /dev/shm 2>/dev/null)" != "$(stat -c '%d' /dev 2>/dev/null)" ]]; then
        got_mount=$(derive_staging /dev/shm 2>/dev/null || true)
        if [[ "$got_mount" == "/dev/shm/tmp" ]]; then
            echo "[ OK ] GraphRoot that is a mount point stages inside it"
        else
            echo "[FAIL] mount-point GraphRoot escaped to another filesystem -> '${got_mount:-<empty>}'" >&2
            fail=1
        fi
    else
        echo "[SKIP] /dev/shm is not a separate filesystem here"
    fi
fi

# --- docs/installation.md must not drift from the implementation ----------
# The installation guide repeats three values owned by preflight.sh: the
# required size, the drop-in filename the remedy writes, and the podman key
# it sets. A reader following a stale figure configures the wrong thing, so
# assert the doc agrees with the code rather than trusting them to be edited
# together.
DOCS=${DOCS:-docs/installation.md}
if [[ -f "$DOCS" ]]; then
    # The default, as preflight.sh defines it — not the value this test may
    # have overridden per-case above.
    # shellcheck disable=SC2016  # literal preflight.sh source text, no expansion wanted
    doc_required=$(sed -n 's/^STAGING_REQUIRED_MB=${STAGING_REQUIRED_MB:-\([0-9]*\)}.*/\1/p' "$PREFLIGHT")
    if [[ -n "$doc_required" ]] && grep -q "${doc_required} MB" "$DOCS"; then
        echo "[ OK ] docs quote the STAGING_REQUIRED_MB default (${doc_required} MB)"
    else
        echo "[FAIL] docs do not quote preflight's STAGING_REQUIRED_MB default (${doc_required:-unset})" >&2
        fail=1
    fi

    # Compare the whole remedy, not a few tokens: the doc block and the
    # printed remedy are the same four commands, and a token check would
    # miss a changed redirect, a renamed key, or a reordered step — exactly
    # the semantic drift that leaves a reader running a command that no
    # longer matches what the installer does.
    #
    # Normalise both sides to bare command lines: strip the doc's fence and
    # indentation, strip preflight's `err "` wrapper and its indentation, and
    # expand the $HOME preflight interpolates so the two are comparable.
    # shellcheck disable=SC2016  # literal sed patterns, no expansion wanted
    doc_cmds=$(sed -n '/^   ```sh$/,/^   ```$/p' "$DOCS" \
        | sed -e '1d' -e '$d' -e 's/^   //' -e 's/[[:space:]]*#.*$//' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
    pf_cmds=$(sed -n 's/^[[:space:]]*err "[[:space:]]*\(.*\)"$/\1/p' "$PREFLIGHT" \
        | sed -e 's/\\\\n/\\n/g' -e 's/\\"/"/g' -e 's/\\\\$/\\/' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')

    # Keep only the lines of the remedy block: from the mkdir to the verify.
    doc_block=$(sed -n '/^mkdir -p/,$p' <<<"$doc_cmds")
    # preflight prefixes the last line with "Verify:"; strip that before
    # taking the range, so both sides end on the same command.
    # shellcheck disable=SC2001  # sed is the pipeline stage here, not a substring swap
    pf_block=$(sed 's/^Verify:[[:space:]]*//' <<<"$pf_cmds" \
        | sed -n '/^mkdir -p/,/^podman info/p')

    if [[ -n "$doc_block" ]] && [[ "$doc_block" == "$pf_block" ]]; then
        echo "[ OK ] docs remedy matches preflight's printed remedy verbatim"
    else
        echo "[FAIL] docs remedy has drifted from preflight's printed remedy" >&2
        echo "--- docs ---" >&2; printf '%s\n' "$doc_block" >&2
        echo "--- preflight ---" >&2; printf '%s\n' "$pf_block" >&2
        fail=1
    fi

    # Names the guide quotes that belong to the scripts. Each is matched
    # against the EXPRESSION that implements it, not the bare name: a plain
    # substring search is satisfied by a leftover comment, so deleting the
    # implementation and leaving the prose behind would pass.
    # rootless_storage_path in particular appears only in comments — the
    # behaviour is carried by the GraphRoot query, which is what to check.
    #
    # The direction matters: a name the guide mentions must still be
    # implemented, because a reader sent to a variable that was renamed is
    # stranded. The reverse is NOT asserted — the guide is free to stop
    # mentioning an internal identifier, and requiring it to name one would
    # make a rename in both places fail for no user-visible reason.
    check_contract() {
        local doc_name="$1" file="$2" pattern="$3"
        grep -qF "$doc_name" "$DOCS" || return 0   # docs dropped it: fine
        if grep -qE "$pattern" "$file"; then
            echo "[ OK ] docs name '$doc_name'; $(basename "$file") still implements it"
        else
            echo "[FAIL] docs name '$doc_name' but $file no longer implements it" >&2
            echo "       (looked for: $pattern)" >&2
            fail=1
        fi
    }

    # shellcheck disable=SC2016  # literal grep -E patterns, no expansion wanted
    check_contract 'SK_STAGING_DIR' installer/linux/install.sh \
        'TMPDIR="\$SK_STAGING_DIR"'
    check_contract 'GraphRoot' installer/linux/install.sh \
        "podman info --format '\{\{\.Store\.GraphRoot\}\}'"
    # A relocated store is followed by asking podman, not by parsing
    # storage.conf — so the contract for rootless_storage_path is that same
    # query in preflight's resolver.
    check_contract 'rootless_storage_path' installer/linux/preflight.sh \
        "podman_guarded info --format '\{\{\.Store\.GraphRoot\}\}'"
    check_contract 'STAGING_REQUIRED_MB' installer/linux/preflight.sh \
        '^STAGING_REQUIRED_MB=\$\{STAGING_REQUIRED_MB:-[0-9]+\}'
    check_contract '/var/tmp' installer/linux/preflight.sh \
        'd="\$\{TMPDIR:-/var/tmp\}"'

    # The old advice must not survive anywhere: it named the wrong mechanism
    # (shrinking a tmpfs cap) for this failure.
    if grep -qE 'tmp\.mount\.d|TMPFS_RECOMMEND_PCT|TMPFS_WARN_MAX_RAM_MB' "$DOCS"; then
        echo "[FAIL] docs still carry the superseded tmpfs-cap advice" >&2
        fail=1
    else
        echo "[ OK ] docs carry no leftover tmpfs-cap advice"
    fi
else
    echo "[FAIL] $DOCS not found (run from repo root)" >&2
    fail=1
fi

if (( fail )); then
    echo "[ERR] check_image_staging_space decision table has regressions" >&2
    exit 1
fi
echo "[PASS] check_image_staging_space decision table correct"
