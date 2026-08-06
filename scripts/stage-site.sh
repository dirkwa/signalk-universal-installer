#!/usr/bin/env bash
# Stage one publishable copy of the installer tree.
#
#   stage-site.sh <src-checkout> <dest-dir> <installer-version>
#
# Extracted from .github/workflows/pages.yml because the site now publishes TWO
# trees from one deploy -- the latest release at the site root, master under
# /dev -- and the staging had to run twice. Inline workflow shell cannot be
# tested; this can, and check-site-channels.sh does.
#
# The version is injected here rather than at install time. The .tmpl files are
# fetched verbatim by the doctor's /api/installer/refresh, so baking it in means
# `signalk version` reports the same value after a refresh as after a fresh
# bootstrap. The bash one-liner's install-time substitution becomes a no-op
# against the published artifact and still works against a local checkout, where
# the placeholder is untouched.

set -euo pipefail

SRC=${1:?usage: stage-site.sh <src-checkout> <dest-dir> <installer-version>}
DEST=${2:?usage: stage-site.sh <src-checkout> <dest-dir> <installer-version>}
VERSION=${3:?usage: stage-site.sh <src-checkout> <dest-dir> <installer-version>}

if [[ ! -d "$SRC/installer" ]]; then
    echo "[ERR] $SRC does not look like a checkout (no installer/)" >&2
    exit 2
fi

mkdir -p "$DEST"
cp -r "$SRC/installer" "$DEST/"
cp -r "$SRC/quadlets" "$DEST/"
[ -d "$SRC/scripts" ] && cp -r "$SRC/scripts" "$DEST/"
[ -d "$SRC/docs" ] && cp -r "$SRC/docs" "$DEST/"
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$DEST/index.md"

# Inject the version into shell + powershell installers and *.tmpl dispatchers.
find "$DEST/installer" -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.tmpl' \) -print0 |
    xargs -0 sed -i \
        "s|INSTALLER_VERSION:-0.0.0-scaffold|INSTALLER_VERSION:-${VERSION}|g; \
         s|'0.0.0-scaffold'|'${VERSION}'|g; \
         s|__SK_VERSION__|${VERSION}|g"

echo "staged ${SRC} -> ${DEST} as ${VERSION}"
