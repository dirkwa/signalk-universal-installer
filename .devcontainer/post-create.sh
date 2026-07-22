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
# reads (classic dev loop, Playwright smoke tests). CAUTION: with the
# default host networking it is LAN-visible on :4000 — enable security
# in the admin UI where the network is not owner-controlled.
# The inbound NMEA0183 (:10110) and Signal K TCP (:8375) listeners are
# seeded OFF — under host networking they would claim the very ports the
# production stack already holds (field report: "8375: address already
# in use"). Re-enable in Server → Settings when a dev consumer actually
# needs them. mDNS announcement is seeded OFF too: with host networking
# the dev instance would otherwise advertise itself on the real LAN and
# every nav app would discover TWO SignalK servers.
mkdir -p "${SK_CONFIG_DIR}"
if [ ! -f "${SK_CONFIG_DIR}/settings.json" ]; then
  echo "==> Seeding fresh dev config in ${SK_CONFIG_DIR}"
  cat > "${SK_CONFIG_DIR}/settings.json" <<'EOF'
{
  "interfaces": {
    "tcp": false,
    "nmea-tcp": false
  },
  "mdns": false,
  "ssl": false,
  "pipedProviders": []
}
EOF
else
  # Existing volumes predate the listener-off/mdns-off defaults and would
  # recreate the collisions on rebuild. Idempotent migration: fill ONLY
  # the missing keys — a value the user has set (either way) is never
  # touched. Best-effort: a parse failure leaves the file alone.
  migrated="$(jq '.interfaces //= {}
    | if (.interfaces | has("tcp")) then . else .interfaces.tcp = false end
    | if (.interfaces | has("nmea-tcp")) then . else .interfaces["nmea-tcp"] = false end
    | if has("mdns") then . else .mdns = false end' \
    "${SK_CONFIG_DIR}/settings.json" 2>/dev/null || true)"
  if [ -n "${migrated}" ] \
      && ! printf '%s\n' "${migrated}" | cmp -s - "${SK_CONFIG_DIR}/settings.json"; then
    # Atomic replace (temp file + rename in the same dir): a crash mid-
    # write must never leave a truncated settings.json behind.
    if tmp="$(mktemp "${SK_CONFIG_DIR}/.settings.json.XXXXXX" 2>/dev/null)"; then
      printf '%s\n' "${migrated}" > "${tmp}"
      mv "${tmp}" "${SK_CONFIG_DIR}/settings.json"
      echo "==> Migrated dev config defaults (unset keys only: tcp/nmea-tcp listeners, mdns -> off)"
    else
      echo "==> WARNING: could not write migrated dev config (mktemp failed)."
      echo "    Inbound :10110/:8375 listeners may still be enabled — devpod's"
      echo "    port forward can collide with a production stack. Disable them"
      echo "    manually in Server → Settings."
    fi
  fi
fi

# ── 3. Local plugin repos ───────────────────────────────────────────────
# Any plugin checked out under dev/plugins/<name> is built and linked into
# the dev instance. Add your repos there (clone, submodule, or extra mount).
# dev/plugins is the signalk-devpod-plugins VOLUME (survives workspace
# rebuilds and deletes); it shadows the repo's .gitkeep, so restore it —
# otherwise the workspace repo shows a phantom deletion in git status.
[ -f "${DEV_DIR}/plugins/.gitkeep" ] || touch "${DEV_DIR}/plugins/.gitkeep" 2>/dev/null || true
# Delegate to the shared linker that dev.sh (start/restart) runs too, so the
# two never diverge: it prunes dangling links (the config volume outlives
# workspaces, so after a delete/recreate the old links dangle and npm dies
# with EACCES reifying over them), builds each plugin on first run, and
# links them ALL in one npm call — a per-plugin install would prune the
# others, since ~/.signalk/package.json carries no dependencies.
SIGNALK_NODE_CONFIG_DIR="${SK_CONFIG_DIR}" bash "${DEV_DIR}/link-plugins.sh" \
  || echo "==> WARNING: plugin linking reported errors (see above)"

# ── 4. e2e test dependencies ────────────────────────────────────────────
( cd "${DEV_DIR}" && npm install )

# ── 5. CodeRabbit auth persistence ──────────────────────────────────────
# The CLI keeps its login in ~/.coderabbit (auth.json) — container-
# lifetime storage, so every workspace recreate logged the user out
# (field report). Symlink it into the signalk-devpod-claude volume.
# State written by a previous container (before the link existed) is
# migrated; on conflict the volume copy wins — it is the one that
# survived recreates.
CR_HOME="${HOME}/.coderabbit"
CR_STATE="${HOME}/.claude/.coderabbit"
if [ ! -L "${CR_HOME}" ]; then
  mkdir -p "${CR_STATE}"
  if [ -d "${CR_HOME}" ]; then
    # Delete the original only after a successful copy — a permission
    # or I/O failure must never destroy the one working login. cp -n
    # skips files the volume already has (they survived recreates and
    # win) without failing.
    # Never abort workspace setup over CodeRabbit state (set -e is
    # active): a failed rm leaves a real dir behind — the volume copy
    # already exists, and the next recreate starts clean and links it.
    if cp -an "${CR_HOME}/." "${CR_STATE}/" 2>/dev/null; then
      rm -rf "${CR_HOME}" 2>/dev/null || true
    else
      echo "==> WARNING: could not migrate CodeRabbit state into the volume;"
      echo "    keeping ${CR_HOME} as-is (login will not survive recreates)."
    fi
  fi
  if [ ! -e "${CR_HOME}" ]; then
    if ln -s "${CR_STATE}" "${CR_HOME}" 2>/dev/null; then
      echo "==> CodeRabbit login now persists across rebuilds (claude volume)"
    else
      echo "==> WARNING: could not link ${CR_HOME} into the volume;"
      echo "    CodeRabbit login will not survive recreates."
    fi
  fi
fi

# ── 6. Claude Code binary sanity ────────────────────────────────────────
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
echo "    AI tooling:         claude | cr review"
