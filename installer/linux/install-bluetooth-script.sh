#!/usr/bin/env bash
# Drops ~/.local/bin/signalk-bluetooth — the BLE / D-Bus passthrough
# helper. The body lives in installer/linux/signalk-bluetooth.tmpl as a
# real bash script. Verbatim copy here — no placeholders to substitute,
# same shape as install-socketcan-script.sh.
#
# Invoked via the `signalk bluetooth` dispatcher subcommand; also
# refreshed by the doctor's POST /api/installer/refresh endpoint so
# existing installs pick up new versions without re-running the bash
# installer.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk-bluetooth"
TEMPLATE="${HERE}/signalk-bluetooth.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

cp "$TEMPLATE" "$TARGET"
chmod 0755 "$TARGET"
ok "signalk-bluetooth installed at $TARGET"
