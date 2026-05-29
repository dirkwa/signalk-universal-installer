#!/usr/bin/env bash
# Drops ~/.local/bin/signalk-socketcan — the Pi CAN-HAT detect/advise
# helper. The body lives in installer/linux/signalk-socketcan.tmpl as a
# real bash script. Verbatim copy here — no placeholders to substitute,
# same shape as install-recovery-script.sh.
#
# Invoked via the `signalk socketcan` dispatcher subcommand; also
# refreshed by the doctor's POST /api/installer/refresh endpoint so
# existing installs pick up new versions without re-running the bash
# installer.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk-socketcan"
TEMPLATE="${HERE}/signalk-socketcan.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

cp "$TEMPLATE" "$TARGET"
chmod 0755 "$TARGET"
ok "signalk-socketcan installed at $TARGET"
