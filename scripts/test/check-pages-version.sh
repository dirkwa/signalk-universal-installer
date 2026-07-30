#!/usr/bin/env bash
# Verifies scripts/installer-version.sh, the shared version-label helper that
# .github/workflows/pages.yml stamps into the published installer.
#
# Releasing publishes the same commit twice — the PR merge to master, and the
# vX.Y.Z tag pushed at it. Both fire the Pages workflow and both publish to the
# same site, so whichever deploy lands last decides the label. It must
# therefore depend on the COMMIT, not on which ref triggered the run: the two
# runs have to agree, or a release ships correct code wearing a git-describe
# label. v0.4.0 and v0.3.0 both went out as `0.3.0-46-g2663942`.
#
# The helper is a real script rather than an inline workflow block precisely so
# this test can run it directly — no extraction, nothing to drift.
#
# Run from the repo root.

set -euo pipefail

HELPER="${HELPER:-scripts/installer-version.sh}"
WF="${WF:-.github/workflows/pages.yml}"
for f in "$HELPER" "$WF"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0
tmp=$(mktemp -d)
HELPER_ABS="$(cd "$(dirname "$HELPER")" && pwd)/$(basename "$HELPER")"

# Invoked via trap; shellcheck cannot see that call, hence SC2317.
# shellcheck disable=SC2317
cleanup() {
    local wt
    # Drop any worktree this test added before removing its directory.
    while read -r wt; do
        if [[ -n "$wt" ]]; then
            git worktree remove --force "$wt" 2>/dev/null || true
        fi
    done < <(git worktree list --porcelain 2>/dev/null |
             awk -v t="$tmp" '$1=="worktree" && index($2,t)==1 {print $2}')
    rm -rf "$tmp"
}
trap cleanup EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# ── Structure: the workflow must use the shared helper ──────────────────────

# Match an actual invocation, not a mention: the surrounding comments name the
# helper too, so a plain file-wide grep would still pass after the call was
# replaced with inline logic.
if grep -qE '^[^#]*(bash|sh) +[^ ]*scripts/installer-version\.sh' "$WF"; then
    ok "$WF invokes the shared helper"
else
    miss "$WF does not invoke scripts/installer-version.sh — the logic has been inlined again and this test no longer guards it"
fi
# And no run: step may compute the label with its own git describe.
if grep -qE '^[^#]*v="\$\(git describe' "$WF"; then
    miss "$WF computes a version with its own 'git describe' — that copy will drift from the helper"
else
    ok "$WF does not compute the version inline"
fi

# The helper itself must not branch on the trigger ref: that is the bug. (The
# workflow may consult GITHUB_REF_NAME to treat a tag run as authoritative,
# which is deliberate and separate.)
if grep -qE 'GITHUB_REF_TYPE|GITHUB_REF_NAME' "$HELPER"; then
    miss "$HELPER reads GITHUB_REF_* — the label must come from the commit, or a master run and a tag run of the same commit disagree"
else
    ok "$HELPER does not depend on which ref triggered the run"
fi
if grep -q 'tag --points-at HEAD' "$HELPER"; then
    ok "$HELPER derives the label from tags pointing at HEAD"
else
    miss "expected 'git tag --points-at HEAD' in $HELPER"
fi
if grep -q 'fetch --tags' "$HELPER"; then
    ok "$HELPER fetches tags first (closes the merge-then-tag visibility window)"
else
    miss "$HELPER does not fetch tags — a run whose checkout predates the tag push would miss it"
fi

# ── Behaviour: run the helper at real commits ──────────────────────────────

# $1 label | $2 committish | $3 mode: exact:<value> | describe | $4 expected
run_at() {
    local label="$1" ref="$2" mode="$3" want="${4:-}"
    local wt="$tmp/wt-$$-$RANDOM" got
    if ! git worktree add -q --detach "$wt" "$ref" 2>/dev/null; then
        miss "$label: could not create a worktree at $ref"
        return
    fi
    got=$(bash "$HELPER_ABS" "$wt" 2>/dev/null || true)
    git worktree remove --force "$wt" 2>/dev/null || true

    if [[ -z "$got" ]]; then
        miss "$label: helper produced no output"
        return
    fi
    case "$mode" in
        exact)
            if [[ "$got" != "$want" ]]; then
                miss "$label: expected '$want', got '$got'"
                return
            fi
            ;;
        describe)
            # Must NOT be a bare release version it has no right to claim, and
            # must look like a describe/dev label. Asserting "non-empty" would
            # accept a wrong bare version, which is the failure mode that
            # matters here.
            if [[ "$got" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
                miss "$label: got bare release version '$got' for an untagged commit"
                return
            fi
            if [[ ! "$got" =~ (-g[0-9a-f]+|^dev-) ]]; then
                miss "$label: '$got' is not a describe-style or dev- label"
                return
            fi
            ;;
    esac
    ok "$label -> $got"
}

latest_tag=$(git tag --sort=-v:refname 2>/dev/null |
             grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' | head -1 || true)

if [[ -z "$latest_tag" ]]; then
    ok "no vX.Y.Z tag in this clone — skipping the tagged-commit cases"
else
    tag_commit="$(git rev-parse "${latest_tag}^{commit}")"
    # The regression: the release commit must label bare, and must label the
    # SAME whether reached via the tag or via a branch at that commit.
    run_at "tagged release commit ($latest_tag)" "$tag_commit" exact "${latest_tag#v}"
    run_at "same commit via its raw sha (branch-push view)" "$tag_commit" exact "${latest_tag#v}"

    # An untagged commit must fall back — pick one that genuinely carries no
    # version tag rather than assuming HEAD~1 is untagged.
    untagged=""
    for c in $(git rev-list -n 25 "$tag_commit" 2>/dev/null); do
        [[ "$c" == "$tag_commit" ]] && continue
        if ! git tag --points-at "$c" 2>/dev/null |
             grep -qE '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
            untagged="$c"
            break
        fi
    done
    if [[ -n "$untagged" ]]; then
        run_at "untagged commit falls back to describe" "$untagged" describe
    else
        miss "could not find an untagged commit to exercise the fallback"
    fi

    # Leading zeros are not a release tag: `v01.2.3` must not be adopted as the
    # bare version `01.2.3`. Uses a real leading-zero tag (no suffix — a suffix
    # would make `git describe` echo the tag name and prove nothing about the
    # version filter). Asserting on the exact value rather than the describe
    # shape, since describe legitimately names the nearest tag.
    if [[ -n "$untagged" ]]; then
        zerotag="v09.9.9"
        if git rev-parse -q --verify "refs/tags/${zerotag}" >/dev/null 2>&1; then
            ok "skipped leading-zero case (${zerotag} already exists in this clone)"
        elif git tag "$zerotag" "$untagged" 2>/dev/null; then
            got_zero="$(bash "$HELPER_ABS" "$(git rev-parse --show-toplevel)" 2>/dev/null || true)"
            # Run it at the tagged commit itself via a worktree.
            wtz="$tmp/wtz-$$"
            if git worktree add -q --detach "$wtz" "$untagged" 2>/dev/null; then
                got_zero="$(bash "$HELPER_ABS" "$wtz" 2>/dev/null || true)"
                git worktree remove --force "$wtz" 2>/dev/null || true
            fi
            if [[ "$got_zero" == "09.9.9" ]]; then
                miss "leading-zero tag ${zerotag} was adopted as the bare version '09.9.9'"
            else
                ok "leading-zero tag ${zerotag} is not treated as a release -> ${got_zero}"
            fi
            git tag -d "$zerotag" >/dev/null 2>&1 || true
        else
            ok "skipped leading-zero case (could not create a throwaway tag)"
        fi
    fi
fi

if [[ "$fail" -eq 0 ]]; then
    echo "[PASS] check-pages-version"
else
    echo "[FAIL] check-pages-version"
fi
exit "$fail"
