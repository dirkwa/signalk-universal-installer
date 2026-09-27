#!/usr/bin/env bash
# Drops ~/.local/bin/signalk-kiosk — boots a connected screen straight into
# the Signal K GUI (docs/kiosk.md). The body lives in installer/linux/
# signalk-kiosk.tmpl as a real bash script. Verbatim copy here — no
# placeholders to substitute, same shape as install-halpi2-script.sh.
#
# Invoked via the `signalk kiosk` dispatcher subcommand. Installing the helper
# changes nothing on the box: the kiosk exists only after `signalk kiosk
# enable`.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk-kiosk"
TEMPLATE="${HERE}/signalk-kiosk.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

install -m 0755 "$TEMPLATE" "$TARGET"
ok "signalk-kiosk installed at $TARGET"
