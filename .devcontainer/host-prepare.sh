#!/usr/bin/env bash
# Runs on the HOST (devcontainer initializeCommand) before every build/up.
# Prepares the podman-socket mount source. Must never hard-fail: a host
# without podman (or macOS/Windows via WSL) still gets a working
# devcontainer — only sibling-container plugin dev is unavailable there,
# which .devcontainer/post-start.sh reports from inside.
# Strict mode per repo convention; every fallible step below is guarded so
# the script still never aborts devcontainer creation.
set -euo pipefail

# The devcontainer bind-mounts this DIRECTORY (not the socket file), so the
# mount succeeds even when no socket exists yet. If podman is present, try
# to bring the user socket up; the socket then appears inside a running
# container without a rebuild.
sock_dir="${XDG_RUNTIME_DIR:-/tmp}/podman"
mkdir -p "${sock_dir}" 2>/dev/null || true

if [ -S "${sock_dir}/podman.sock" ]; then
  echo "host-prepare: podman socket live at ${sock_dir}/podman.sock"
elif command -v systemctl >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
  if systemctl --user enable --now podman.socket >/dev/null 2>&1; then
    echo "host-prepare: enabled podman.socket (${sock_dir}/podman.sock)"
  else
    echo "host-prepare: could not enable podman.socket — sibling-container plugin dev will be unavailable"
  fi
else
  echo "host-prepare: no podman/systemctl on host — sibling-container plugin dev will be unavailable"
fi

# devpod-on-rootless-docker self-heal: devpod stages feature files under
# .devcontainer/.devpod-internal/ and its container-setup chown hands the
# whole workspace — staging included — to subordinate uids. The devpod
# agent (running as the host user) then cannot rewrite its own staging on
# the next connect, and every tunnel dies with
# ".devpod-internal/0/NOTES.md: permission denied". initializeCommand runs
# before that step, so reclaim the staging tree here. Best-effort: no-op
# when absent, already ours, or podman is unavailable.
staging=".devcontainer/.devpod-internal"
if [ -d "${staging}" ] \
    && [ -n "$(find "${staging}" ! -writable -print -quit 2>/dev/null)" ] \
    && command -v podman >/dev/null 2>&1; then
  if podman unshare chown -R 0:0 "${staging}" 2>/dev/null; then
    echo "host-prepare: reclaimed ${staging} (rootless-runtime chown side effect)"
  else
    echo "host-prepare: ${staging} not writable — devpod tunnel may fail;"
    echo "  manual fix: podman unshare chown -R 0:0 ${staging}"
  fi
fi

exit 0
