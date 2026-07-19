#!/usr/bin/env bash
# The pinned dbus-auth-proxy image reference exists in two places by
# necessity: install.sh's PROXY_IMAGE default (fresh installs render the
# quadlet template directly) and signalk-bluetooth.tmpl's
# DEFAULT_PROXY_IMAGE (the helper renders the doctor-staged copy of the
# same template on `enable`). The helper runs on hosts without the
# installer tree, so it cannot source install.sh — the value is
# duplicated, and a drifted pin would mean fresh installs and
# payload-installs silently run different proxy code. This check makes
# the drift a CI failure instead.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

INSTALL_SH="$REPO_ROOT/installer/linux/install.sh"
HELPER_TMPL="$REPO_ROOT/installer/linux/signalk-bluetooth.tmpl"

# SC2016: the ${PROXY_IMAGE:-...} in the pattern is literal text being
# matched in install.sh, not a shell expansion here.
# shellcheck disable=SC2016
installer_pin=$(sed -n 's/^PROXY_IMAGE=\${PROXY_IMAGE:-\(.*\)}$/\1/p' "$INSTALL_SH")
helper_pin=$(sed -n 's/^DEFAULT_PROXY_IMAGE="\(.*\)"$/\1/p' "$HELPER_TMPL")

fail=0
if [[ -z "$installer_pin" ]]; then
    echo "  [MISS] could not extract PROXY_IMAGE default from install.sh"
    fail=1
else
    echo "  [OK]   install.sh pin: $installer_pin"
fi
if [[ -z "$helper_pin" ]]; then
    echo "  [MISS] could not extract DEFAULT_PROXY_IMAGE from signalk-bluetooth.tmpl"
    fail=1
else
    echo "  [OK]   helper pin:     $helper_pin"
fi
if [[ -n "$installer_pin" && -n "$helper_pin" && "$installer_pin" != "$helper_pin" ]]; then
    echo "  [MISS] proxy image pins differ between install.sh and the helper"
    fail=1
fi

if (( fail )); then
    echo
    echo "[ERR] dbus-auth-proxy image pin drift — keep both defaults identical." >&2
    exit 1
fi
echo
echo "[OK] dbus-auth-proxy image pin is in sync."
