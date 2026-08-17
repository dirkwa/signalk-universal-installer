#!/usr/bin/env bash
# Drops ~/.local/bin/signalk-halpi2 — the Hat Labs HALPI2 carrier-board
# helper (docs/halpi2.md). The body lives in installer/linux/
# signalk-halpi2.tmpl as a real bash script. Verbatim copy here — no
# placeholders to substitute, same shape as install-bluetooth-script.sh.
#
# Invoked via the `signalk halpi2` dispatcher subcommand. install.sh runs
# the template directly for its own step 2c (the CLI is not installed yet
# at that point); this copy is what `signalk halpi2 …` runs afterwards.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk-halpi2"
TEMPLATE="${HERE}/signalk-halpi2.tmpl"
mkdir -p "$BIN_DIR"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[ERR] missing template: $TEMPLATE" >&2
    exit 1
fi

install -m 0755 "$TEMPLATE" "$TARGET"
ok "signalk-halpi2 installed at $TARGET"
