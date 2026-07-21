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
# The inbound NMEA0183 (:10110) and Signal K TCP (:8375) listeners are
# seeded OFF: devpod auto-forwards every listening port to the host,
# where a production stack already holds those two (field report:
# "8375: address already in use"). Re-enable in Server → Settings when a
# dev consumer actually needs them.
mkdir -p "${SK_CONFIG_DIR}"
if [ ! -f "${SK_CONFIG_DIR}/settings.json" ]; then
  echo "==> Seeding fresh dev config in ${SK_CONFIG_DIR}"
  cat > "${SK_CONFIG_DIR}/settings.json" <<'EOF'
{
  "interfaces": {
    "tcp": false,
    "nmea-tcp": false
  },
  "ssl": false,
  "pipedProviders": []
}
EOF
else
  # Existing volumes predate the listener-off default and would recreate
  # the port collision on rebuild. Idempotent migration: fill ONLY the
  # missing listener keys — a value the user has set (either way) is
  # never touched. Best-effort: a parse failure leaves the file alone.
  migrated="$(jq '.interfaces //= {}
    | if (.interfaces | has("tcp")) then . else .interfaces.tcp = false end
    | if (.interfaces | has("nmea-tcp")) then . else .interfaces["nmea-tcp"] = false end' \
    "${SK_CONFIG_DIR}/settings.json" 2>/dev/null || true)"
  if [ -n "${migrated}" ] \
      && ! printf '%s\n' "${migrated}" | cmp -s - "${SK_CONFIG_DIR}/settings.json"; then
    # Atomic replace (temp file + rename in the same dir): a crash mid-
    # write must never leave a truncated settings.json behind.
    if tmp="$(mktemp "${SK_CONFIG_DIR}/.settings.json.XXXXXX" 2>/dev/null)"; then
      printf '%s\n' "${migrated}" > "${tmp}"
      mv "${tmp}" "${SK_CONFIG_DIR}/settings.json"
      echo "==> Migrated dev config: inbound tcp/nmea-tcp listeners default to off"
    else
      echo "==> WARNING: could not write migrated dev config (mktemp failed)."
      echo "    Inbound :10110/:8375 listeners may still be enabled — devpod's"
      echo "    port forward can collide with a production stack. Disable them"
      echo "    manually in Server → Settings."
    fi
  fi
fi

# ── 3. Local plugin repos ───────────────────────────────────────────────
# Any plugin checked out under dev/plugins/<name> is linked into the dev
# instance. Add your repos there (clone, submodule, or extra mount).
# dev/plugins is the signalk-devpod-plugins VOLUME (survives workspace
# rebuilds and deletes); it shadows the repo's .gitkeep, so restore it —
# otherwise the workspace repo shows a phantom deletion in git status.
[ -f "${DEV_DIR}/plugins/.gitkeep" ] || touch "${DEV_DIR}/plugins/.gitkeep" 2>/dev/null || true
for plugin in "${DEV_DIR}/plugins"/*/; do
  [ -f "${plugin}/package.json" ] || continue
  name=$(jq -r .name "${plugin}/package.json")
  echo "==> Linking local plugin: ${name}"
  ( cd "${plugin}" && npm install )
  ( cd "${SK_CONFIG_DIR}" && npm install --no-save "${plugin}" )
done

# ── 4. e2e test dependencies ────────────────────────────────────────────
( cd "${DEV_DIR}" && npm install )

# ── 5. Claude Code binary sanity ────────────────────────────────────────
# If the feature's npm postinstall was script-gated anyway, /usr/bin/claude
# is an error stub. We cannot fix it as the node user (module dir is
# root-owned) — detect and print the remediation instead of failing later
# in a confusing place (broken plugin installs, missing skills).
if command -v claude >/dev/null 2>&1 && ! claude --version >/dev/null 2>&1; then
  echo "==> WARNING: claude native binary missing (npm script gate)."
  echo "    Fix from the HOST:  docker exec -u root <container> \\"
  echo "      node /usr/lib/node_modules/@anthropic-ai/claude-code/install.cjs"
fi

echo ""
echo "==> Setup complete."
echo "    Start dev server:   dev/dev.sh start    (http://localhost:4000)"
echo "    Sample NMEA data:   dev/dev.sh demo"
echo "    e2e tests:          cd dev && npm run test:e2e"
echo "    Server-source dev:  clone into dev/signalk-server, re-run this script"
echo "    Companion repos:    dev/clone-companions.sh"
echo "    AI tooling:         claude | cr review --plain"
