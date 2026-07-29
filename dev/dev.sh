#!/usr/bin/env bash
# Convenience wrapper around the dev SignalK instance.
#
#   ./dev.sh start     start server on $PORT (default 4000) with ~/.signalk config
#   ./dev.sh demo      start server with bundled sample NMEA0183 data
#   ./dev.sh demo-fg   demo server in the FOREGROUND (Playwright webServer)
#   ./dev.sh stop      stop the dev server
#   ./dev.sh restart   stop + start (picks up plugin code changes!)
#   ./dev.sh link      build + link dev/plugins/* into the dev config (no restart)
#   ./dev.sh logs      tail the server log
#   ./dev.sh status    is it running?
#
# start/demo/restart auto-link every plugin under dev/plugins/ when launching
# the server (via link-plugins.sh), so a freshly cloned plugin just works.
# Restart after any plugin code change (Node caches modules); for TypeScript
# source edits, force the rebuild with SK_DEV_PLUGIN_BUILD=1 ./dev.sh restart.
#
# Server resolution: a source checkout at dev/signalk-server/ (server
# development) takes precedence; otherwise the pre-built server baked into
# the image at /home/node/signalk (production parity) is used.
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SIGNALK_NODE_CONFIG_DIR:-$HOME/.signalk}"
PORT="${PORT:-4000}"
# Namespace every managed container and one-shot job this dev instance
# creates so it can never collide with, reap, or recreate the production
# `sk-*` stack sharing this host's podman socket. signalk-container reads
# this; builds without namespace support simply ignore it (harmless). The
# `env …` launches below inherit this exported value. Override by exporting
# SIGNALK_CONTAINER_NAMESPACE yourself before invoking dev.sh.
export SIGNALK_CONTAINER_NAMESPACE="${SIGNALK_CONTAINER_NAMESPACE:-devpod}"
# Port-scoped state: a second instance on another port gets its own files
# and can never signal this one.
PIDFILE="/tmp/signalk-dev-${PORT}.pid"
LOGFILE="/tmp/signalk-dev-${PORT}.log"

if [ -x "${DEV_DIR}/signalk-server/bin/signalk-server" ]; then
  SERVER_ROOT="${DEV_DIR}/signalk-server"
  SERVER_FLAVOR="source checkout (dev/signalk-server)"
else
  SERVER_ROOT="/home/node/signalk/node_modules/signalk-server"
  SERVER_FLAVOR="image-baked server (production parity)"
fi

# Only treat the recorded pid as ours if it is alive AND still a
# signalk-server process — guards against pid reuse after a crash.
is_running() {
  [ -f "${PIDFILE}" ] || return 1
  pid="$(cat "${PIDFILE}")"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null || return 1
  grep -qa "signalk-server" "/proc/${pid}/cmdline" 2>/dev/null
}

# Refuse to start when something else already answers on ${PORT} —
# otherwise verify_up would happily attribute a foreign listener to us.
ensure_port_free() {
  if curl -sf -o /dev/null "http://localhost:${PORT}/signalk" 2>/dev/null; then
    echo "Port ${PORT} is already serving a SignalK instance that is not managed by this script." >&2
    echo "Stop it first, or use PORT=<other> $0 ..." >&2
    exit 1
  fi
}

# launch <cmd...>: run the server detached from ${SERVER_ROOT}, record its
# REAL pid. The exec is essential — without it the recorded pid is the
# wrapper subshell, not the node process, and stop()/is_running() silently
# operate on the wrong (dead) pid while old servers pile up on the port.
#
# setsid is equally essential: nohup alone does NOT survive the launching
# terminal for a NODE process. nohup only sets SIGHUP to SIG_IGN, and node
# re-arms the signal after exec, so the SIGHUP the kernel delivers when the
# controlling terminal goes away still terminates the server (a plain
# `sleep`, which keeps the inherited SIG_IGN, does survive — which is what
# made this look like it should already work). Launched from a VS Code task
# terminal — the status-bar Start/Restart/Demo buttons — the server
# therefore died seconds after that terminal was disposed: nothing left on
# ${PORT}, a stale ${PIDFILE} so `status` reports "stopped", and a log whose
# last line is verify_up's own successful probe. Its own session has no
# controlling terminal, so no SIGHUP is ever delivered.
#
# set +m keeps $! pointing at the server: setsid(1) forks only when its
# caller is already a process-group leader, which the backgrounded subshell
# of a job-control-less shell never is.
launch() {
  set +m
  ( cd "${SERVER_ROOT}" && exec setsid nohup "$@" ) > "${LOGFILE}" 2>&1 &
  echo $! > "${PIDFILE}"
}

# The server catches uncaught exceptions (e.g. EADDRINUSE) and keeps the
# process alive without a listener — so verify the HTTP endpoint, not just
# the pid.
verify_up() {
  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${PORT}/signalk" >/dev/null 2>&1; then
      echo "Up: http://localhost:${PORT}  (logs: dev.sh logs)"
      return 0
    fi
    is_running || break
    sleep 0.5
  done
  echo "Failed to start — last log lines:" >&2
  tail -n 20 "${LOGFILE}" >&2
  exit 1
}

# Build (first run) and link every dev/plugins/* into the dev config so a
# freshly cloned plugin is picked up on start. Pass the resolved config dir
# explicitly — link-plugins.sh refuses to guess one. Exit status is
# preserved so `./dev.sh link` can be scripted; start/demo call it
# non-fatally below — a plugin problem must never stop the server coming up.
link_plugins() {
  SIGNALK_NODE_CONFIG_DIR="${CONFIG_DIR}" bash "${DEV_DIR}/link-plugins.sh"
}

start() {
  if is_running; then
    echo "Dev server already running (pid $(cat "${PIDFILE}"), port ${PORT})"
    return 0
  fi
  ensure_port_free
  link_plugins || echo "WARNING: plugin linking reported errors — starting anyway" >&2
  echo "Starting SignalK dev server on port ${PORT} — ${SERVER_FLAVOR}..."
  launch env PORT="${PORT}" ./bin/signalk-server -c "${CONFIG_DIR}"
  verify_up
}

# Write the sample settings to $1 with the sample-log path pinned to the
# server's own copy: the path in the file is relative and would otherwise
# resolve against the config dir.
#
# jq --arg, not sed: SERVER_ROOT derives from the script's location, and an
# `&`, `\` or `|` anywhere in that path is replacement-expression syntax to
# sed — `&` silently interpolates the whole match, `|` (the delimiter here)
# aborts with "unknown option to `s'". jq takes the value as data, so no
# escaping is needed. A wrong path here is quiet: the feed just never
# arrives. jq is already required (link-plugins.sh hard-fails without it).
#
# Generate then rename, rather than redirecting onto the destination: a
# failure mid-write would otherwise leave a truncated settings file behind,
# and reseeding only triggers when the sample log goes missing — so an empty
# one would persist.
pin_sample_path() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  if jq --arg root "${SERVER_ROOT}" \
    '(.. | objects | select(.filename == "samples/plaka.log") | .filename)
       |= $root + "/samples/plaka.log"' \
    "${SERVER_ROOT}/settings/volare-file-settings.json" > "${tmp}"; then
    mv "${tmp}" "${dest}"
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null || true
  echo "ERROR: could not generate demo settings from ${SERVER_FLAVOR}" >&2
  return 1
}

# Demo mode: the DEV CONFIG DIR with the sample-data settings — linked
# plugins stay loaded (issue #192: demo previously ran on an isolated
# config and "removed" every plugin). The sample settings file is copied
# into the config dir because -s always resolves relative to it; copy
# only when absent so local tweaks survive. Direct signalk-server
# invocation instead of bin/nmea-from-file (npm strips the exec bit from
# undeclared bin/ scripts).
seed_demo_settings() {
  local copy="${CONFIG_DIR}/settings/volare-file-settings.json"
  local sample reseed=1
  if [ -f "${copy}" ]; then
    # Keep an existing copy (local tweaks survive) — but only while the
    # sample file it references still exists. The pinned absolute path
    # breaks when the server flavor changes (e.g. a removed source
    # checkout), and a dead feed is silent — reseed instead.
    sample="$(jq -r 'first(.. | .filename? // empty)' "${copy}" 2>/dev/null || true)"
    if [ -n "${sample}" ] && [ -f "${sample}" ]; then
      reseed=0
    else
      echo "Demo settings referenced a missing sample log — reseeding from ${SERVER_FLAVOR}."
    fi
  fi
  if [ "${reseed}" -eq 1 ]; then
    mkdir -p "${CONFIG_DIR}/settings"
    pin_sample_path "${copy}"
  fi
  # Also guard an existing copy, not just a fresh seed: every volume created
  # before this change holds an unguarded one, and reseeding only happens
  # when the sample log goes missing.
  guard_demo_settings "${copy}" || true
}

# The settings file passed with -s REPLACES settings.json — signalk-server
# resolves one or the other (config.js::getSettingsFilename), never merges —
# so none of the dev config's defaults reach a demo run. Left alone, demo
# mode therefore claims the Signal K TCP (:8375) and inbound NMEA0183
# (:10110) ports the production stack already holds under host networking,
# and announces THIS instance over mDNS so nav apps find two servers. Those
# are exactly the three keys post-create.sh seeds off in settings.json;
# stamp them into the demo settings too.
#
# Unset keys only, so a developer who deliberately re-enabled a listener on
# a free port keeps it — the same rule post-create.sh's migration follows.
# "Unset" means null as well as absent: `has()` reports true for an explicit
# null, so a null would have been left in place. Harmless for the listeners
# (the server treats null as off) but it left `mdns: null` where the seed
# writes false, so the migrated file did not match a fresh one.
# Non-fatal by design: a demo server that binds a busy port still comes up
# (the server logs EADDRINUSE and carries on), so a jq problem here must not
# block the sample feed.
guard_demo_settings() {
  local file="$1" tmp
  command -v jq >/dev/null 2>&1 || {
    echo "WARNING: jq unavailable — demo may bind :8375/:10110 and announce mDNS" >&2
    return 1
  }
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if jq '.interfaces //= {}
    | if (.interfaces.tcp != null) then . else .interfaces.tcp = false end
    | if (.interfaces["nmea-tcp"] != null) then . else .interfaces["nmea-tcp"] = false end
    | if (.mdns != null) then . else .mdns = false end' \
    "${file}" > "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
    # Carry the original mode over — mktemp made the temp 0600.
    chmod --reference="${file}" "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${file}"
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null || true
  echo "WARNING: could not guard ${file##*/} — demo may bind :8375/:10110 and announce mDNS" >&2
  return 1
}

demo() {
  if is_running; then stop; fi
  ensure_port_free
  link_plugins || echo "WARNING: plugin linking reported errors — starting anyway" >&2
  seed_demo_settings
  echo "Starting SignalK dev server with sample NMEA data on port ${PORT} — ${SERVER_FLAVOR}..."
  launch env PORT="${PORT}" ./bin/signalk-server \
    -c "${CONFIG_DIR}" -s settings/volare-file-settings.json
  verify_up
}

# Foreground variant for supervisors that own the process lifecycle
# (Playwright's webServer): no pidfile, no log redirect, exec so the
# supervisor signals the server itself, not a wrapper shell. DELIBERATELY
# stays on the isolated package config (SIGNALK_NODE_CONFIG_DIR unset):
# e2e must be deterministic and independent of whatever plugins a
# developer has linked into the dev config.
#
# It needs the same listener/mDNS guard as demo() — an e2e run must not
# fight the production stack for :8375/:10110 or announce itself either.
# The guarded copy goes to a temp dir rather than into the package tree,
# which is an image directory: SIGNALK_NODE_SETTINGS overrides the settings
# FILE without touching config-dir resolution. `-s` therefore stays, unused
# for its filename but still required: getConfigDirectory() reads it as the
# "use appPath as the config dir" signal, and dropping it would fall
# through to ${HOME}/.signalk — the dev config this variant exists to
# avoid.
#
# mktemp, not a fixed name: a predictable path in a world-writable /tmp can
# be pre-created as a symlink that the redirect below then follows. Also
# gives a fresh file per run, so e2e never inherits yesterday's edits. We
# exec, so no trap can clean up — the file has to outlive this shell for the
# server to read it. Sweep older copies instead, and only ones a day old:
# a concurrent run on another E2E_PORT must keep its own file, which it may
# not have finished reading yet.
demo_fg() {
  ensure_port_free
  local settings tmpdir="${TMPDIR:-/tmp}"
  find "${tmpdir}" -maxdepth 1 -name 'signalk-dev-e2e-settings-*.json' \
    -user "$(id -u)" -mtime +0 -delete 2>/dev/null || true
  settings="$(mktemp "${tmpdir}/signalk-dev-e2e-settings-XXXXXX.json")"
  pin_sample_path "${settings}"
  guard_demo_settings "${settings}" || true
  cd "${SERVER_ROOT}"
  exec env -u SIGNALK_NODE_CONFIG_DIR PORT="${PORT}" \
    SIGNALK_NODE_SETTINGS="${settings}" ./bin/signalk-server \
    -s settings/volare-file-settings.json
}

stop() {
  if is_running; then
    pid="$(cat "${PIDFILE}")"
    kill "${pid}"
    # Wait for the port to actually free up; escalate if the server hangs.
    for _ in $(seq 1 20); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "${pid}" 2>/dev/null || true
    rm -f "${PIDFILE}"
    echo "Stopped."
  else
    rm -f "${PIDFILE}"
    echo "Not running."
  fi
}

case "${1:-}" in
  start)   start ;;
  demo)    demo ;;
  demo-fg) demo_fg ;;
  stop)    stop ;;
  restart) stop; start ;;
  link)    link_plugins ;;
  logs)    tail -f "${LOGFILE}" ;;
  status)  is_running && echo "running (pid $(cat "${PIDFILE}"), port ${PORT}, ${SERVER_FLAVOR})" || echo "stopped" ;;
  *) grep '^#   ' "$0" | sed 's/^#   //'; exit 1 ;;
esac
