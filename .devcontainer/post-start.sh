#!/usr/bin/env bash
# Runs every time the container starts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Host podman socket probe (for signalk-container-based plugins) ──────
# The host socket dir is bind-mounted at /run/host-podman; the socket file
# itself may or may not exist. Probe and report — never fail the start.
SOCK=/run/host-podman/podman.sock
if [ -S "${SOCK}" ] && podman --url "unix://${SOCK}" info >/dev/null 2>&1; then
  echo "==> Host podman socket OK — signalk-container-based plugins can spawn sibling containers."
elif [ -S "${SOCK}" ]; then
  echo "==> INFO: host podman socket exists but is not accessible from this container user."
  echo "    This happens under a rootless-Docker runtime (uid mapping). To opt in, run on the HOST:"
  echo "      chmod 666 \"\${XDG_RUNTIME_DIR}/podman/podman.sock\""
  echo "    (contained risk: /run/user/<uid> itself is 0700, other host users cannot reach the path)"
  echo "    then restart this container. Until then sibling-container plugin dev is disabled."
else
  echo "==> INFO: host podman socket not available (${SOCK})."
  echo "    Sibling-container plugin dev is disabled; everything else works."
  echo "    To enable, run on the HOST:  systemctl --user enable --now podman.socket"
  echo "    then restart this container (no rebuild — the socket appears in the mounted dir)."
fi

# ── Same-host production reachability (issue #191) ──────────────────────
# pasta (rootless podman's default network) maps "the host" to link-local
# 169.254.1.2 — an address signalk-server's SSRF guard deliberately
# blocks. A dev-server connection to a production server on the SAME box
# then fails with the generic "Could not connect to Signal K server".
# Detect the situation and say so up front instead of letting it surface
# as a mystery in the admin UI.
host_ip="$(getent hosts host.containers.internal 2>/dev/null | awk '{print $1; exit}' || true)"
case "${host_ip}" in
  169.254.*)
    echo "==> INFO: running under pasta — the host maps to ${host_ip}, which"
    echo "    signalk-server's SSRF guard blocks. To connect the dev server to a"
    echo "    production server on THIS box, use the host's tailscale IP in the"
    echo "    connection — or switch the workspace to slirp4netns (see the"
    echo "    commented runArgs in devcontainer.json) and connect to 10.0.2.2."
    ;;
esac

# ── Browser IDE (openvscode) defaults ───────────────────────────────────
# Seed a dark theme into openvscode's server-side User settings — only
# when no settings exist yet, so a developer's later theme choice is
# never overwritten. Desktop VS Code windows use the user's own theme and
# are unaffected. (mkdir is safe: the openvscode tarball ships no data/.)
OVS_USER_DIR="${HOME}/.openvscode-server/data/User"
if [ ! -f "${OVS_USER_DIR}/settings.json" ]; then
  mkdir -p "${OVS_USER_DIR}" 2>/dev/null || true
  if printf '{\n  "workbench.colorTheme": "Default Dark Modern"\n}\n' \
      > "${OVS_USER_DIR}/settings.json" 2>/dev/null; then
    echo "==> Seeded dark theme for the browser IDE"
  else
    echo "==> INFO: could not seed the browser-IDE theme (non-fatal, defaults apply)"
  fi
fi

# ── CodeRabbit CLI: non-interactive auth if an API key is forwarded ─────
# (Browser login does not survive container rebuilds; an API key from the
# host via CODERABBIT_API_KEY does. Alternative: use the native Claude Code
# CodeRabbit plugin — its state persists via the ~/.claude mount.)
if command -v coderabbit >/dev/null 2>&1 && [ -n "${CODERABBIT_API_KEY:-}" ]; then
  if ! coderabbit auth status >/dev/null 2>&1; then
    echo "==> Authenticating CodeRabbit CLI via CODERABBIT_API_KEY..."
    coderabbit auth login --api-key "${CODERABBIT_API_KEY}" >/dev/null 2>&1 || \
      echo "    (CodeRabbit auth failed — run 'coderabbit auth login' manually)"
  fi
fi

# ── Auto-start dev server (disable with SK_DEV_AUTOSTART=0, e.g. when
#    debugging the server from VS Code instead) ─────────────────────────
if [ "${SK_DEV_AUTOSTART:-1}" = "1" ]; then
  "${REPO_ROOT}/dev/dev.sh" start || true
fi
