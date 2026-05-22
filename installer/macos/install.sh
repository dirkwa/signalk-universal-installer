#!/usr/bin/env bash
# SignalK Universal Installer (v2) — macOS scaffold
INSTALLER_VERSION="${INSTALLER_VERSION:-0.0.0-scaffold}"

set -euo pipefail

cat <<EOF
SignalK Universal Installer v${INSTALLER_VERSION} (macOS) — SCAFFOLD ONLY.

This release of the script does not install anything yet. The real flow
(brew + Podman Machine + Quadlet bootstrap + peer containers) is being
built in the signalk-universal-installer repo.

Status: https://github.com/dirkwa/signalk-universal-installer
EOF

exit 0
