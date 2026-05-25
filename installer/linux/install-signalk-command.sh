#!/usr/bin/env bash
# Drops ~/.local/bin/signalk — the user-facing command dispatcher.
# The dispatcher body lives in installer/linux/signalk.tmpl as a real
# bash script (not a heredoc), so it can be byte-for-byte refreshed
# from disk by the doctor's /api/installer/refresh endpoint without
# any container-side bash interpolation. We just sed in the version
# placeholder and chmod it.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk"
TEMPLATE="${HERE}/signalk.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

# Embed the installer-version string so `signalk version` reports
# something useful. Caller (install.sh) exports INSTALLER_VERSION.
SK_VERSION="${INSTALLER_VERSION:-unknown}"

# Use a non-conflicting sed delimiter (|) because INSTALLER_VERSION
# may contain '/' (e.g. branch refs in dev installs).
sed "s|__SK_VERSION__|${SK_VERSION}|g" "$TEMPLATE" >"$TARGET"
chmod 0755 "$TARGET"
ok "Installed $TARGET"
