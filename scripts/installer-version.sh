#!/usr/bin/env bash
# Print the installer version label for the current checkout.
#
# Used by .github/workflows/pages.yml to stamp INSTALLER_VERSION into the
# published artifact, and by scripts/test/check-pages-version.sh. It lives
# here rather than inline in the workflow so the test exercises the shipped
# logic instead of a copy that could drift from it.
#
# Releasing pushes the same commit twice: the PR merge lands on master and the
# vX.Y.Z tag is pushed at it. Both fire the Pages workflow, both publish to the
# same site, and the artifacts differ only in this string — so whichever deploy
# lands last decides the label. Deriving it from the TRIGGER REF made the two
# runs disagree, and when the master run won a release shipped correct code
# labelled `0.3.0-46-g2663942` instead of `0.4.0` (v0.4.0, and v0.3.0 before).
#
# So derive it from the COMMIT instead: if a version tag points at HEAD, use it
# regardless of which ref triggered the run. Both runs then produce identical
# artifacts and the race stops mattering.
#
# Tag visibility is the catch. `git tag --points-at` only sees refs that exist
# when the checkout runs, and the merge lands ~90s before the tag is pushed
# (measured on the v0.4.0 release), so the master run's checkout genuinely
# cannot see the tag yet. Fetch tags first — cheap, and it closes the window
# for every run that starts after the tag reaches the remote. A master run that
# starts BEFORE the tag exists still cannot see it; that residual case is why
# the workflow also treats the tag-triggered run as authoritative.
#
# Usage: installer-version.sh [<git-dir-or-worktree>]
#   With no argument, operates on the current directory.
#   --release-tag-pattern  print the release-tag regex and exit, so callers
#                          that need the same rule (pages.yml) share it rather
#                          than re-declaring a copy that can drift.

set -euo pipefail

# Strict semver, no leading zeros in any component: `v01.2.3` is not a release
# tag. Single definition — see --release-tag-pattern above.
RELEASE_TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ "${1:-}" == "--release-tag-pattern" ]]; then
    printf '%s\n' "$RELEASE_TAG_RE"
    exit 0
fi

if [[ $# -gt 0 && -n "$1" ]]; then
    cd "$1"
fi

# Best-effort: an offline or credential-less checkout must still yield a label.
git fetch --tags --quiet 2>/dev/null || true

# Newest first, so a commit carrying several version tags takes the highest
# rather than an arbitrary one. `|| true` keeps `pipefail` from aborting when
# grep matches nothing, which is the normal untagged case.
tag="$(git tag --points-at HEAD --sort=-v:refname 2>/dev/null \
       | grep -E "$RELEASE_TAG_RE" \
       | head -1 || true)"

if [[ -n "$tag" ]]; then
    printf '%s\n' "${tag#v}"
    exit 0
fi

# Untagged commit: a describe-style label, never a bare version it cannot
# claim.
#
# --match restricts describe to release-shaped tags. Without it, describe names
# whatever tag is nearest, so a stray `v09.9.9` or `v1-keeper-final` would come
# back verbatim and — after the `v` strip below — read exactly like a release
# version. The glob cannot express "no leading zeros" (that is why the tag
# lookup above uses a regex), but it does keep non-version tags out, and the
# check below rejects anything that still looks bare.
v="$(git describe --tags --always --dirty --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
if [[ -z "$v" ]]; then
    v="$(git describe --always --dirty 2>/dev/null || true)"
fi
if [[ -z "$v" ]]; then
    v="dev-${GITHUB_SHA:-unknown}"
    v="${v:0:11}"
fi
# Strip a leading `v` so install.sh's `v${INSTALLER_VERSION}` does not render
# as `vv0.1.0-NN-gXXXXXXX`.
v="${v#v}"
# Belt and braces: if a describe result still reads as a bare release version,
# this commit is not that release (the tag lookup above would have returned).
# Fall back to the bare sha rather than mislabel it.
if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    v="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
printf '%s\n' "$v"
