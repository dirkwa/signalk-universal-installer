#!/usr/bin/env bash
# Clone the SignalK stack's companion repos into dev/companions/ for
# cross-repo development. Idempotent; safe to re-run.
set -euo pipefail
DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${DEV_DIR}/companions"
for repo in signalk-updater-server signalk-doctor-server \
            signalk-updater signalk-doctor signalk-container; do
  dest="${DEV_DIR}/companions/${repo}"
  if [ -d "${dest}/.git" ]; then
    echo "==> ${repo} already present"
  else
    git clone "https://github.com/dirkwa/${repo}.git" "${dest}"
  fi
done
echo "Done. Plugin-type companions can be linked like any dev/plugins entry."
