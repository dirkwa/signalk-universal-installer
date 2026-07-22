#!/usr/bin/env bash
# dev/link-plugins.sh — build (first run only) and link every local plugin
# under dev/plugins/ into the dev SignalK config, so a freshly cloned plugin
# is picked up with no manual npm steps.
#
# Called automatically by dev.sh (start/demo/restart) and by the
# devcontainer's post-create.sh, and runnable on its own:
#
#   dev/link-plugins.sh                         # build-if-missing + link all
#   SK_DEV_PLUGIN_BUILD=1 dev/link-plugins.sh   # force a rebuild of every plugin
#
# Idempotent and offline-safe: an already-built plugin is NOT rebuilt (no
# repeat vite/wasm network fetch) — only relinked. After editing a
# TypeScript plugin's source, force the rebuild with SK_DEV_PLUGIN_BUILD=1
# (in place of a manual `npm run build`) and restart.
#
# Fail-fast by default; the per-plugin steps that must NOT abort the others
# (install, build) are guarded explicitly.
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${DEV_DIR}/plugins"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '==> WARNING: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { warn "jq is required but not on PATH"; exit 1; }

# Require an explicit config dir — never guess. The devcontainer pins
# SIGNALK_NODE_CONFIG_DIR (containerEnv) to the dev volume, so every real
# caller (dev.sh, post-create.sh, or a bare run inside the container) has it
# already. Refusing to default to $HOME/.signalk guards the one dangerous
# case: a stray run on a host where that path is a PRODUCTION install — the
# bulk npm reify below prunes whatever it deems extraneous and would delete
# real plugins there.
if [ -z "${SIGNALK_NODE_CONFIG_DIR:-}" ]; then
  warn "SIGNALK_NODE_CONFIG_DIR is not set — refusing to guess a config dir"
  warn "that might be a production ~/.signalk. Run via dev.sh, or set it."
  exit 1
fi
CONFIG_DIR="${SIGNALK_NODE_CONFIG_DIR}"

# Canonical absolute path of a directory (or a symlink to one), portably —
# BSD readlink has no -f, so resolve via a subshell cd instead.
realdir() { ( cd "$1" 2>/dev/null && pwd -P ); }

link_plugins() {
  [ -d "${PLUGINS_DIR}" ] || return 0

  local paths=() names=() built=0
  local plugin name main build_failed
  shopt -s nullglob
  for plugin in "${PLUGINS_DIR}"/*/; do
    plugin="${plugin%/}"
    [ -f "${plugin}/package.json" ] || continue
    name="$(jq -r '.name // empty' "${plugin}/package.json" 2>/dev/null || true)"
    [ -n "${name}" ] || { warn "skipping ${plugin##*/} (unreadable package.json / no name)"; continue; }

    # First-time provisioning only — keeps restarts fast and offline-safe.
    # Guarded: a broken plugin must not abort the others.
    if [ ! -d "${plugin}/node_modules" ]; then
      log "Installing deps: ${name}"
      if ! ( cd "${plugin}" && npm install --no-audit --no-fund ); then
        warn "npm install failed for ${name} — skipping"
        continue
      fi
    fi

    # A TypeScript plugin ships no compiled entry in a fresh checkout;
    # without it signalk-server logs "Cannot find module" and silently skips
    # the plugin. Build when the entry is missing, or on demand.
    main="$(jq -r '.main // "index.js"' "${plugin}/package.json" 2>/dev/null || echo index.js)"
    build_failed=0
    if [ "${SK_DEV_PLUGIN_BUILD:-0}" = "1" ] || [ ! -e "${plugin}/${main}" ]; then
      log "Building: ${name}"
      if ( cd "${plugin}" && npm run build --if-present ); then
        built=1
      else
        build_failed=1
        warn "build failed for ${name}"
      fi
    fi

    # Don't link a plugin that can't load correctly: no entry point at all
    # (signalk-server would only log "Cannot find module" and skip it), or a
    # build we attempted that failed — linking the leftover/partial artifact
    # would silently run stale or broken code (a failed tsc can still emit a
    # partial entry). Either way skip it so the rest still link.
    if [ ! -e "${plugin}/${main}" ]; then
      warn "skipping ${name} — no entry point (${main})"
      continue
    fi
    if [ "${build_failed}" -eq 1 ]; then
      warn "skipping ${name} — build failed; not linking stale/partial output"
      continue
    fi

    paths+=("${plugin}")
    names+=("${name}")
  done
  shopt -u nullglob

  # Prune dangling links first: a workspace delete/recreate leaves stale
  # symlinks the config volume outlived, and npm then dies with EACCES
  # reifying over them. Bash globs (portable, no GNU find) over both plain
  # and @scope/ names; a dangling symlink is one whose target is gone.
  local pruned=0 link
  shopt -s nullglob
  for link in "${CONFIG_DIR}"/node_modules/* "${CONFIG_DIR}"/node_modules/@*/*; do
    [ -L "${link}" ] || continue                    # real dirs/files — skip
    if [ -e "${link}" ]; then continue; fi          # live link — keep
    rm -f "${link}" || { warn "could not prune ${link##*/}"; continue; }
    log "Pruned dangling plugin link: ${link##*/}"
    pruned=1
  done
  shopt -u nullglob

  [ "${#paths[@]}" -gt 0 ] || return 0

  # Fast path: skip the (few-second) reify when nothing was built or pruned
  # and every plugin is already linked to its current path.
  if [ "${built}" -eq 0 ] && [ "${pruned}" -eq 0 ]; then
    local i target all=1
    for i in "${!paths[@]}"; do
      target="${CONFIG_DIR}/node_modules/${names[$i]}"
      if [ ! -L "${target}" ] || [ "$(realdir "${target}")" != "$(realdir "${paths[$i]}")" ]; then
        all=0
        break
      fi
    done
    [ "${all}" -eq 1 ] && return 0
  fi

  # Link ALL plugins in ONE call. ~/.signalk/package.json carries no
  # dependencies, so a per-plugin `npm install --no-save <one>` treats every
  # other linked plugin as extraneous and prunes it — one call with all
  # paths keeps them all. A per-plugin build failure above is non-fatal (you
  # may be mid-fix), but the link step itself failing is a real error, so
  # propagate it.
  log "Linking ${#paths[@]} local plugin(s) into ${CONFIG_DIR}"
  if ! ( cd "${CONFIG_DIR}" && npm install --no-save --no-audit --no-fund "${paths[@]}" ); then
    warn "linking plugins failed — see the npm output above"
    return 1
  fi
}

link_plugins
