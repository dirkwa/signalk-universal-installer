#!/usr/bin/env bash
# Drops ~/.local/bin/signalk-recovery — the SSH-only safety net described
# by CC-3. It can restore Quadlets from ~/.signalk-doctor/snapshots/ and
# kick systemd into reloading them, even with zero containers running.
#
# The recovery body lives in installer/linux/signalk-recovery.tmpl as a
# real bash script. Verbatim copy here — no placeholders to substitute,
# unlike the signalk dispatcher which embeds INSTALLER_VERSION.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk-recovery"
TEMPLATE="${HERE}/signalk-recovery.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

cp "$TEMPLATE" "$TARGET"
chmod 0755 "$TARGET"
ok "signalk-recovery installed at $TARGET"
