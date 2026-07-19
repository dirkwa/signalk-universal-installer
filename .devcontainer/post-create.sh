#!/usr/bin/env bash
# Runs once after the container is created (and after rebuilds).
# Workspace root = signalk-universal-installer repo checkout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${REPO_ROOT}/dev"
SERVER_DIR="${DEV_DIR}/signalk-server"
SK_CONFIG_DIR="${SIGNALK_NODE_CONFIG_DIR:-$HOME/.signalk}"

echo "==> signalk-universal-installer devcontainer setup"

# ── 1. signalk-server ───────────────────────────────────────────────────
# The base image already ships a pre-built signalk-server (production
# parity) at /home/node/signalk — nothing to build for plugin development.
# A source checkout at dev/signalk-server/ (see docs/devcontainer.md,
# "Developing the server") takes precedence in dev/dev.sh; build it here
# when present. (The installer repo itself is bash/PowerShell — nothing to
# npm install at the root.)
if [ -d "${SERVER_DIR}" ]; then
  echo "==> Building signalk-server checkout (a few minutes on first run)..."
  ( cd "${SERVER_DIR}" && npm install && npm run build:all )
else
  echo "==> Using the pre-built signalk-server from the image (no checkout at dev/signalk-server)"
fi

# ── 2. Persistent SignalK dev config ────────────────────────────────────
# No security strategy on purpose: the dev instance must allow anonymous
# reads (classic dev loop, Playwright smoke tests) and is only reachable
# through the devcontainer's port forward. CAUTION: with the optional
# --network=host runArgs (socketcan) it becomes LAN-visible — enable
# security in the admin UI if that matters on your network.
mkdir -p "${SK_CONFIG_DIR}"
if [ ! -f "${SK_CONFIG_DIR}/settings.json" ]; then
  echo "==> Seeding fresh dev config in ${SK_CONFIG_DIR}"
  cat > "${SK_CONFIG_DIR}/settings.json" <<'EOF'
{
  "interfaces": {},
  "ssl": false,
  "pipedProviders": []
}
EOF
fi

# ── 3. Local plugin repos ───────────────────────────────────────────────
# Any plugin checked out under dev/plugins/<name> is linked into the dev
# instance. Add your repos there (clone, submodule, or extra mount).
for plugin in "${DEV_DIR}/plugins"/*/; do
  [ -f "${plugin}/package.json" ] || continue
  name=$(jq -r .name "${plugin}/package.json")
  echo "==> Linking local plugin: ${name}"
  ( cd "${plugin}" && npm install )
  ( cd "${SK_CONFIG_DIR}" && npm install --no-save "${plugin}" )
done

# ── 4. e2e test dependencies ────────────────────────────────────────────
( cd "${DEV_DIR}" && npm install )

echo ""
echo "==> Setup complete."
echo "    Start dev server:   dev/dev.sh start    (http://localhost:4000)"
echo "    Sample NMEA data:   dev/dev.sh demo"
echo "    e2e tests:          cd dev && npm run test:e2e"
echo "    Server-source dev:  clone into dev/signalk-server, re-run this script"
echo "    Companion repos:    dev/clone-companions.sh"
echo "    AI tooling:         claude | cr review --plain"
