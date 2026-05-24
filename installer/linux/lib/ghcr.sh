#!/usr/bin/env bash
# Source me. latest_stable_tag REPO — print the highest semver-shaped
# stable tag for ghcr.io/<REPO>. Falls back to printing "latest" if
# GHCR is unreachable, so install never hangs on a flaky network.
#
# A "stable" tag here is any tag matching ^v?\d+\.\d+\.\d+$ — prerelease
# tags ("0.6.1-beta.1", "master-abc1234", "dirkwa-xxx") are filtered
# out so the installer pins to a release artefact, not a moving tip.
#
# We talk to the v2 distribution API directly rather than the GH
# Packages REST API because the latter requires auth even for public
# images. The anonymous bearer token from /token?scope= is enough to
# list a public repo's tags.

# Print the highest semver-shaped stable tag on success.
# Print "latest" on any failure path.
# Exit code: always 0 — the caller pins to whatever we print.
latest_stable_tag() {
    local repo=$1
    local fallback=${2:-latest}

    # Anonymous pull token. -m 10 caps total time per call; if GHCR
    # hangs we'd rather pin to :latest than wait two minutes.
    #
    # The `|| true` suffix is load-bearing: the caller runs under
    # `set -euo pipefail` (see installer/linux/install.sh:68), and
    # without it a curl failure OR an empty sed extraction would abort
    # the whole installer before the [[ -z "$token" ]] fallback below
    # could fire. The function intentionally swallows all error detail
    # at this layer — its contract is "print a tag or the fallback,
    # never fail."
    local token
    token=$(curl -fsS -m 10 \
        "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" \
        2>/dev/null | \
        sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || true
    if [[ -z "$token" ]]; then
        echo "$fallback"
        return 0
    fi

    # tags/list returns {"name":"...","tags":[...]}. Pagination is via
    # a Link header but the doctor/updater images have <100 tags total
    # so the first page is the whole list.
    local raw
    raw=$(curl -fsS -m 15 \
        -H "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${repo}/tags/list" \
        2>/dev/null) || true
    if [[ -z "$raw" ]]; then
        echo "$fallback"
        return 0
    fi

    # Extract the tags array contents, split on commas, filter to
    # bare semver. sort -V sorts versions; tail -1 keeps the highest.
    # `|| true` because grep exits 1 when no semver tags match
    # (legitimate state — a brand-new repo with only :master tags) and
    # pipefail would otherwise abort the installer.
    local latest
    latest=$(echo "$raw" | \
        sed -n 's/.*"tags":\[\([^]]*\)\].*/\1/p' | \
        tr ',' '\n' | \
        tr -d ' "' | \
        grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | \
        sort -V | \
        tail -1) || true
    if [[ -z "$latest" ]]; then
        echo "$fallback"
        return 0
    fi

    echo "$latest"
}
