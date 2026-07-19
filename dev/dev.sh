#!/usr/bin/env bash
# Convenience wrapper around the dev SignalK instance.
#
#   dev.sh start     start server on $PORT (default 4000) with ~/.signalk config
#   dev.sh demo      start server with bundled sample NMEA0183 data
#   dev.sh demo-fg   demo server in the FOREGROUND (Playwright webServer)
#   dev.sh stop      stop the dev server
#   dev.sh restart   stop + start (picks up plugin code changes!)
#   dev.sh logs      tail the server log
#   dev.sh status    is it running?
#
# Server resolution: a source checkout at dev/signalk-server/ (server
# development) takes precedence; otherwise the pre-built server baked into
# the image at /home/node/signalk (production parity) is used.
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SIGNALK_NODE_CONFIG_DIR:-$HOME/.signalk}"
PORT="${PORT:-4000}"
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
launch() {
  ( cd "${SERVER_ROOT}" && exec nohup "$@" ) > "${LOGFILE}" 2>&1 &
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

start() {
  if is_running; then
    echo "Dev server already running (pid $(cat "${PIDFILE}"), port ${PORT})"
    return 0
  fi
  ensure_port_free
  echo "Starting SignalK dev server on port ${PORT} — ${SERVER_FLAVOR}..."
  launch env PORT="${PORT}" ./bin/signalk-server -c "${CONFIG_DIR}"
  verify_up
}

# Demo mode notes: direct invocation instead of bin/nmea-from-file (npm
# strips the exec bit from undeclared bin/ scripts). -s always resolves
# relative to the config dir, so unset SIGNALK_NODE_CONFIG_DIR: the config
# dir then defaults to the server root — sample settings and samples/
# resolve, and demo state stays out of the persistent dev config.
demo() {
  if is_running; then stop; fi
  ensure_port_free
  echo "Starting SignalK dev server with sample NMEA data on port ${PORT} — ${SERVER_FLAVOR}..."
  launch env -u SIGNALK_NODE_CONFIG_DIR PORT="${PORT}" ./bin/signalk-server \
    -s settings/volare-file-settings.json
  verify_up
}

# Foreground variant for supervisors that own the process lifecycle
# (Playwright's webServer): no pidfile, no log redirect, exec so the
# supervisor signals the server itself, not a wrapper shell.
demo_fg() {
  ensure_port_free
  cd "${SERVER_ROOT}"
  exec env -u SIGNALK_NODE_CONFIG_DIR PORT="${PORT}" ./bin/signalk-server \
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
  logs)    tail -f "${LOGFILE}" ;;
  status)  is_running && echo "running (pid $(cat "${PIDFILE}"), port ${PORT}, ${SERVER_FLAVOR})" || echo "stopped" ;;
  *) grep '^#   ' "$0" | sed 's/^#   //'; exit 1 ;;
esac
