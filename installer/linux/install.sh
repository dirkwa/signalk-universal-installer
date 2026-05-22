#!/usr/bin/env bash
# SignalK Universal Installer (v2) — Linux scaffold
# INSTALLER_VERSION will be substituted by .github/workflows/pages.yml at deploy time.
INSTALLER_VERSION="${INSTALLER_VERSION:-e503f8e}"

set -euo pipefail

cat <<EOF
SignalK Universal Installer v${INSTALLER_VERSION} (Linux) — SCAFFOLD ONLY.

This release of the script does not install anything yet. The real flow
(Podman + Quadlet bootstrap + updater/doctor peer containers) is being
built in the signalk-universal-installer repo.

Status: https://github.com/dirkwa/signalk-universal-installer
EOF

exit 0
