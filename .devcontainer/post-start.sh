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
# Scan ALL resolved addresses — the link-local entry is not guaranteed
# to come first when the name resolves to several.
pasta_ip="$(getent hosts host.containers.internal 2>/dev/null \
  | awk '$1 ~ /^169\.254\./ { print $1; exit }' || true)"
if [ -n "${pasta_ip}" ]; then
  echo "==> INFO: running under pasta — the host maps to ${pasta_ip}, which"
  echo "    signalk-server's SSRF guard blocks. To connect the dev server to a"
  echo "    production server on THIS box, use the host's tailscale IP in the"
  echo "    connection — or switch the workspace to slirp4netns (see the"
  echo "    commented runArgs in devcontainer.json) and connect to 10.0.2.2."
fi

# ── Browser IDE (openvscode) defaults ───────────────────────────────────
# Seed a dark theme into openvscode's server-side User settings, guarding
# on the KEY rather than the file. openvscode writes settings.json itself
# the moment a developer changes anything in the browser IDE, so a
# file-exists guard loses that race permanently: the file is there, the
# theme key is not, and every later start skips the seed while the IDE
# comes up light. Adding only the absent key keeps every other setting
# intact and still never overwrites an explicit theme choice.
# Desktop VS Code windows use the user's own theme and are unaffected.
# (mkdir is safe: the openvscode tarball ships no data/.)
OVS_USER_DIR="${HOME}/.openvscode-server/data/User"
OVS_SETTINGS="${OVS_USER_DIR}/settings.json"
OVS_THEME="Default Dark Modern"

# Cheap signature of the current settings state, used to notice a write
# that landed while we were deciding what to write.
ovs_settings_sig() {
  if [ -f "${OVS_SETTINGS}" ]; then
    # 2>/dev/null first: the shell reports a failing input redirection
    # itself, and only a stderr already pointed away stays quiet.
    cksum 2>/dev/null < "${OVS_SETTINGS}" || echo unreadable
  else
    echo absent
  fi
}

seed_browser_ide_theme() {
  mkdir -p "${OVS_USER_DIR}" 2>/dev/null || return 1

  # A symlinked settings.json belongs to something else — a dotfiles repo,
  # typically. Publishing through mv would swap the link for a plain file
  # and quietly detach it from its source, so leave it entirely alone.
  [ -L "${OVS_SETTINGS}" ] && return 7

  # Anything else that exists but is not a regular file is not ours to
  # replace either. A directory is the dangerous one: mv moves the temp
  # file *into* it and reports success, so the seed would claim to have
  # worked while no settings file was ever written.
  if [ -e "${OVS_SETTINGS}" ] && [ ! -f "${OVS_SETTINGS}" ]; then
    return 8
  fi

  local sig tmp grep_rc=0
  sig="$(ovs_settings_sig)"
  tmp="$(mktemp "${OVS_USER_DIR}/.settings.json.XXXXXX" 2>/dev/null)" || return 1

  # Is there content worth preserving? grep exits 1 for "no match" — an
  # empty or whitespace-only file, which is what an interrupted write
  # leaves — but greater than 1 on a read error (permission, I/O). Only
  # the first means "nothing to preserve"; reading an unreadable file as
  # empty would clobber settings we simply failed to see.
  if [ -f "${OVS_SETTINGS}" ]; then
    grep -q '[^[:space:]]' "${OVS_SETTINGS}" 2>/dev/null || grep_rc=$?
    if [ "${grep_rc}" -gt 1 ]; then
      rm -f "${tmp}" 2>/dev/null || true
      return 6
    fi
  fi

  if [ ! -f "${OVS_SETTINGS}" ] || [ "${grep_rc}" -eq 1 ]; then
    printf '{\n  "workbench.colorTheme": "%s"\n}\n' "${OVS_THEME}" \
      > "${tmp}" 2>/dev/null || { rm -f "${tmp}" 2>/dev/null || true; return 1; }
  else
    command -v jq >/dev/null 2>&1 || { rm -f "${tmp}" 2>/dev/null || true; return 2; }

    # One jq pass decides and rewrites, so the file is read exactly once:
    # a separate has()-check followed by a merge could lose a theme the
    # developer picked in between. openvscode may well be running here.
    #   jq fails      -> not plain JSON. VS Code accepts JSONC, jq does not,
    #                    and a file we cannot parse is the developer's own.
    #   empty output  -> a theme is already set; leave it be.
    #   JSON output   -> the key was absent, this is the merged result.
    if ! jq --arg theme "${OVS_THEME}" \
         'if has("workbench.colorTheme") then empty
          else . + {"workbench.colorTheme": $theme} end' \
         "${OVS_SETTINGS}" > "${tmp}" 2>/dev/null; then
      rm -f "${tmp}" 2>/dev/null || true
      return 3
    fi
    if [ ! -s "${tmp}" ]; then
      rm -f "${tmp}" 2>/dev/null || true
      return 4
    fi
  fi

  # Publish only if nothing wrote settings while we worked. We cannot lock
  # openvscode out, so we detect its write instead and stand down: a theme
  # that fails to seed is a nuisance, one that eats a developer's settings
  # is not. The next container start seeds it anyway.
  if [ "$(ovs_settings_sig)" != "${sig}" ]; then
    rm -f "${tmp}" 2>/dev/null || true
    return 5
  fi

  # Same-directory temp + mv keeps the replace atomic, so an interrupted
  # start can never leave a half-written settings.json behind. mktemp made
  # the temp 0600; carry the original mode over so the seed does not
  # quietly narrow permissions on a file it only meant to add a key to.
  if [ -f "${OVS_SETTINGS}" ]; then
    chmod --reference="${OVS_SETTINGS}" "${tmp}" 2>/dev/null || true
  fi
  mv "${tmp}" "${OVS_SETTINGS}" 2>/dev/null && return 0
  rm -f "${tmp}" 2>/dev/null || true
  return 1
}

ovs_seed_rc=0
seed_browser_ide_theme || ovs_seed_rc=$?
case "${ovs_seed_rc}" in
  0) echo "==> Seeded dark theme for the browser IDE" ;;
  2) echo "==> INFO: jq unavailable — left the browser-IDE theme alone" ;;
  3) echo "==> INFO: browser-IDE settings.json is not plain JSON — left it alone" ;;
  4) : ;;  # an explicit theme is already set — respect it, silently
  5) echo "==> INFO: browser-IDE settings changed mid-seed — left them alone" ;;
  6) echo "==> INFO: browser-IDE settings.json unreadable — left it alone" ;;
  7) echo "==> INFO: browser-IDE settings.json is a symlink — left it alone" ;;
  8) echo "==> INFO: browser-IDE settings.json is not a regular file — left it alone" ;;
  *) echo "==> INFO: could not seed the browser-IDE theme (non-fatal, defaults apply)" ;;
esac

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
