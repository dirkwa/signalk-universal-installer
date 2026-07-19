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
