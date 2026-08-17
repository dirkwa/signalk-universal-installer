#!/usr/bin/env bash
# SignalK Universal Installer (v2) — macOS bootstrap.
#
# macOS does not have systemd. We run Podman Machine (a managed Linux VM
# that podman ships with), then run the regular Linux installer INSIDE
# that VM. Result: the same container stack as Linux, accessible from
# macOS via Podman's port-forward layer.
#
# Limitations of this path (intentional, documented in docs/installation.md):
#   - USB serial: requires explicit podman machine init --usb on M-series Macs.
#   - SocketCAN: not supported on macOS.
#   - Bluetooth: not supported on macOS.
#   - GPIO: not applicable.

INSTALLER_VERSION="${INSTALLER_VERSION:-0.0.0-scaffold}"

# Release channel, same rules as installer/linux/install.sh: the site publishes
# the latest RELEASE at its root and master under /dev, and an explicit
# INSTALLER_BASE_URL still wins as the escape hatch for local checkouts, mirrors
# and CI. Without this the hardcoded base URL below was passed explicitly into
# the VM, which beat the channel and pinned macOS to the release tree.
SIGNALK_CHANNEL="${SIGNALK_CHANNEL:-release}"
_SK_SITE_ROOT="https://dirkwa.github.io/signalk-universal-installer"
case "$SIGNALK_CHANNEL" in
    release) _SK_DEFAULT_BASE="$_SK_SITE_ROOT" ;;
    master|dev) _SK_DEFAULT_BASE="${_SK_SITE_ROOT}/dev" ;;
    *)
        echo "[ERR] SIGNALK_CHANNEL must be 'release' or 'master' (got '${SIGNALK_CHANNEL}')" >&2
        exit 1
        ;;
esac
# Whether the caller set it explicitly, before the default fills it in. The VM
# handoff below sends the channel only when they did not: install.sh lets an
# explicit base URL win, so sending both would name two different trees.
if [[ -n "${INSTALLER_BASE_URL:-}" ]]; then
    _SK_EXPLICIT_BASE=true
else
    _SK_EXPLICIT_BASE=false
fi
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-$_SK_DEFAULT_BASE}"

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[ERR] This script only runs on macOS (current: $(uname -s))" >&2
    exit 1
fi

info()    { printf '[i] %s\n' "$*"; }
ok()      { printf '[OK] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*"; }
die()     { printf '[ERR] %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }

RESET_MACHINE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-machine)
            RESET_MACHINE=1
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: install.sh [--reset-machine]

Options:
  --reset-machine  Remove and recreate the Podman machine before install.
USAGE
            exit 0
            ;;
        *)
            die "Unknown argument: $1 (use --help for usage)"
            ;;
    esac
    shift
done

section "SignalK Universal Installer v${INSTALLER_VERSION} (macOS)"

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required. Install from https://brew.sh/, then re-run."
fi
ok "brew $(brew --version | head -1)"

# 2. Podman
if ! command -v podman >/dev/null 2>&1; then
    info "Installing podman via Homebrew"
    brew install podman
fi
ok "podman $(podman --version | awk '{print $3}')"

# 3. Podman Machine
MACHINE_NAME="${PODMAN_MACHINE_NAME:-signalk}"
MACHINE_NAME_EXPLICIT=0
if [[ -n "${PODMAN_MACHINE_NAME:-}" ]]; then
    MACHINE_NAME_EXPLICIT=1
fi

# Podman machine on macOS allows only one active VM at a time. If the default
# machine name is in use and another VM is already running, reuse that active
# VM so installs do not fail on first run.
ACTIVE_MACHINE="$(podman machine list --format '{{.Name}} {{.Running}}' | awk '$2=="true" { print $1; exit }' | tr -d '*[:space:]')"
if [[ -n "$ACTIVE_MACHINE" && "$ACTIVE_MACHINE" != "$MACHINE_NAME" ]]; then
    if (( RESET_MACHINE )); then
        info "Stopping active Podman machine '${ACTIVE_MACHINE}' so '${MACHINE_NAME}' can be reset"
        podman machine stop "$ACTIVE_MACHINE" >/dev/null 2>&1 || die "Could not stop active Podman machine '${ACTIVE_MACHINE}'."
    elif (( MACHINE_NAME_EXPLICIT )); then
        die "Podman machine '${ACTIVE_MACHINE}' is already running; stop it first (podman machine stop '${ACTIVE_MACHINE}') or re-run with PODMAN_MACHINE_NAME='${ACTIVE_MACHINE}'."
    else
        warn "Podman machine '${ACTIVE_MACHINE}' is already running; reusing it instead of '${MACHINE_NAME}'."
        MACHINE_NAME="$ACTIVE_MACHINE"
    fi
fi

# Size the VM's memory to fit the host. podman rejects a machine larger than
# total system RAM, and the stack's preflight needs >= 2048 MB inside the VM.
# Target 4096 MB but never more than (host RAM - 1024 headroom for the host OS),
# floored at 2048. Override with PODMAN_MACHINE_MEMORY_MB.
MACHINE_MEMORY_MB="${PODMAN_MACHINE_MEMORY_MB:-}"
if [[ -z "$MACHINE_MEMORY_MB" ]]; then
    total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
    avail=$(( total_mb - 1024 ))
    if (( avail < 4096 )); then MACHINE_MEMORY_MB=$avail; else MACHINE_MEMORY_MB=4096; fi
    if (( MACHINE_MEMORY_MB < 2048 )); then
        die "Not enough RAM: this Mac has ${total_mb} MB. The SignalK stack needs a VM with >= 2048 MB plus ~1024 MB headroom (>= ~3072 MB total)."
    fi
fi
# Validate the resolved value (covers a PODMAN_MACHINE_MEMORY_MB override too):
# must be a plain integer >= 2048, else podman init or the stack preflight fails.
if ! [[ "$MACHINE_MEMORY_MB" =~ ^[0-9]+$ ]] || (( MACHINE_MEMORY_MB < 2048 )); then
    die "PODMAN_MACHINE_MEMORY_MB must be an integer >= 2048 (got '${MACHINE_MEMORY_MB}'); the SignalK stack needs at least 2048 MB inside the VM."
fi

machine_exists=0
if podman machine inspect "$MACHINE_NAME" >/dev/null 2>&1; then
    machine_exists=1
fi

# Optional reset: remove only the exact matching machine before recreating it.
if (( RESET_MACHINE )); then
    if (( machine_exists )); then
        info "Removing existing Podman machine '$MACHINE_NAME' (--reset-machine)"
        podman machine stop "$MACHINE_NAME" 2>/dev/null || true
        podman machine rm -f "$MACHINE_NAME"
        if podman machine inspect "$MACHINE_NAME" >/dev/null 2>&1; then
            die "Failed to remove Podman machine '$MACHINE_NAME' before reset"
        fi
    fi
    machine_exists=0
fi

if (( ! machine_exists )); then
    info "Creating Podman machine '$MACHINE_NAME' (${MACHINE_MEMORY_MB} MB; this takes a few minutes)"
    podman machine init --cpus 2 --memory "$MACHINE_MEMORY_MB" --disk-size 30 "$MACHINE_NAME"
else
    info "Reusing existing Podman machine '$MACHINE_NAME'"
fi

if ! podman machine list --format '{{.Name}} {{.Running}}' | grep -q "^${MACHINE_NAME}[[:space:]]*true"; then
    info "Starting Podman machine"
    podman machine start "$MACHINE_NAME"
fi
ok "Podman machine '$MACHINE_NAME' running"

podman system connection default "$MACHINE_NAME" 2>/dev/null || true

# 4. Run the Linux installer inside the machine.
section "Bootstrapping inside the Podman machine"

# The Linux installer runs as the machine's regular user and sudo's for its few
# system steps. `podman machine ssh` has no TTY, so if that user's sudo wants a
# password the install dies ("a terminal is required to read the password").
# Grant the default user passwordless sudo first, via the root connection
# (podman machine init creates both a user and a root system connection). The
# default user is whoever `podman machine ssh` lands as; we resolve it rather
# than hardcode (it's `core` on Fedora CoreOS, `user` on the WSL Fedora image).
info "Ensuring the machine's user can sudo non-interactively"
# Ask podman (on the macOS side) who the VM's SSH user is — more reliable than
# probing /etc/passwd from inside a freshly-created CoreOS/FCOS image.
_VM_USER=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.RemoteUsername}}' 2>/dev/null || true)
[[ -n "$_VM_USER" ]] || die "Could not determine the VM SSH user from 'podman machine inspect $MACHINE_NAME'"
info "VM SSH user: $_VM_USER"

podman machine ssh --username root "$MACHINE_NAME" bash << SUDO_SCRIPT
set -euo pipefail
f="/etc/sudoers.d/90-signalk-nopasswd"
printf "%s ALL=(ALL) NOPASSWD:ALL\n" "${_VM_USER}" > "\$f"
chmod 0440 "\$f"
if ! visudo -cf "\$f"; then
    echo "ERR: sudoers drop-in for ${_VM_USER} failed validation; removing it" >&2
    rm -f "\$f"; exit 1
fi
echo "granted NOPASSWD sudo to ${_VM_USER}"
SUDO_SCRIPT

# We pipe install.sh through `podman machine ssh` which runs an interactive
# shell in the VM. The Linux install.sh handles podman, systemd-user, linger,
# Quadlets — all of which exist inside the VM.
LINUX_URL="${INSTALLER_BASE_URL}/installer/linux/install.sh"
info "Fetching $LINUX_URL and running it in the machine"

# Send the channel only when the caller did NOT pin a base URL explicitly (see
# above). The assignment goes on the `bash` side of the pipe, never on curl:
# it is read by the DOWNLOADED installer, so on curl it would be ignored and
# the run would fetch install.sh from one tree and the rest of its files from
# the other.
_SK_CHAN_ENV=""
if [[ "$_SK_EXPLICIT_BASE" == false ]]; then
    _SK_CHAN_ENV="SIGNALK_CHANNEL='${SIGNALK_CHANNEL}' "
fi

podman machine ssh "$MACHINE_NAME" bash << LINUX_SCRIPT
set -euo pipefail
cd \$HOME
curl -fsSL '${LINUX_URL}' | ${_SK_CHAN_ENV}INSTALLER_VERSION='${INSTALLER_VERSION}' INSTALLER_BASE_URL='${INSTALLER_BASE_URL}' bash
LINUX_SCRIPT

# On SELinux VMs, container label isolation blocks access to the mounted
# rootless podman socket unless SecurityLabelDisable is set.
info "Applying socket-access fix for SELinux VMs"
podman machine ssh "$MACHINE_NAME" bash << 'SOCKET_FIX_SCRIPT'
set -euo pipefail
changed=0
for unit in signalk-server signalk-updater-server signalk-doctor-server; do
    quadlet="$HOME/.config/containers/systemd/${unit}.container"
    if [[ ! -f "$quadlet" ]]; then
        echo "WARN: ${unit} quadlet not found at $quadlet; skipping socket-access fix" >&2
        continue
    fi

    if grep -q '^SecurityLabelDisable=true$' "$quadlet"; then
        echo "${unit} quadlet already has SecurityLabelDisable=true"
        continue
    fi

    if ! grep -q '^Volume=%t/podman/podman.sock:/var/run/docker.sock$' "$quadlet"; then
        echo "WARN: ${unit} quadlet has no podman socket mount; skipping socket-access fix" >&2
        continue
    fi

    tmp="${quadlet}.tmp"
    awk '
        BEGIN { inserted = 0 }
        /^Volume=%t\/podman\/podman\.sock:\/var\/run\/docker\.sock$/ {
            print
            if (!inserted) {
                print "SecurityLabelDisable=true"
                inserted = 1
            }
            next
        }
        { print }
    ' "$quadlet" > "$tmp"
    mv "$tmp" "$quadlet"
    changed=1
    echo "Applied socket-access fix to ${unit}.container"
done

if [[ "$changed" -eq 1 ]]; then
    systemctl --user daemon-reload
fi

for service in signalk-updater-server.service signalk-doctor-server.service; do
    if systemctl --user restart "$service"; then
        echo "Restarted $service"
    else
        echo "WARN: restart failed for $service; restart it manually" >&2
    fi
done

updater_url="http://127.0.0.1:3003"
token_file="$HOME/.signalk-updater/token"

if [[ -s "$token_file" ]]; then
    token=$(<"$token_file")
    set +e
    restart_resp=$(curl -sS -m 10 -o /tmp/signalk-restart-api.body -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        "${updater_url}/api/signalk/restart")
    curl_rc=$?
    set -e

    if [[ "$curl_rc" -eq 0 ]]; then
        if [[ "$restart_resp" =~ ^2 ]]; then
            echo "Restarted signalk-server via updater API"
        else
            echo "WARN: updater API restart failed (HTTP ${restart_resp})" >&2
        fi
    else
        echo "WARN: updater unreachable for signalk restart; using systemctl fallback" >&2
        if systemctl --user start signalk-server.service; then
            echo "Started signalk-server.service via fallback"
        else
            echo "WARN: fallback start failed for signalk-server.service" >&2
        fi
    fi
else
    echo "WARN: updater token missing at ${token_file}; cannot request signalk restart via updater API" >&2
fi
SOCKET_FIX_SCRIPT

# Some Podman-machine networking setups resolve host.containers.internal to an
# address that is not reachable from updater/doctor containers.
info "Checking engine-to-server health URL reachability"
podman machine ssh "$MACHINE_NAME" bash << 'HEALTH_URL_FIX_SCRIPT'
set -euo pipefail

doctor_container="signalk-doctor-server"
updater_quadlet="$HOME/.config/containers/systemd/signalk-updater-server.container"
doctor_quadlet="$HOME/.config/containers/systemd/signalk-doctor-server.container"
server_quadlet="$HOME/.config/containers/systemd/signalk-server.container"

if ! podman container exists "$doctor_container"; then
    systemctl --user start signalk-doctor-server.service || true
    for _ in 1 2 3 4 5; do
        podman container exists "$doctor_container" && break
        sleep 1
    done
fi
if ! podman container exists "$doctor_container"; then
    echo "WARN: doctor container is not running; skipping health URL reachability fix" >&2
    exit 0
fi

sk_http_port=$(grep -E '^Environment=PORT=' "$server_quadlet" 2>/dev/null | awk -F= '{print $NF}' | tail -n1)
sk_http_port=${sk_http_port:-80}
sk_https_port=$(grep -E '"sslport"' "$HOME/.signalk/settings.json" 2>/dev/null | sed -E 's/[^0-9]*([0-9]+).*/\1/' | head -n1)
sk_https_port=${sk_https_port:-443}

probe_signalk_http() {
        local host="$1"
        local port="$2"
    podman exec "$doctor_container" node -e '
const url = process.argv[1];
const ok = (s) => s >= 200 && s < 400;
fetch(url, { redirect: "manual", signal: AbortSignal.timeout(2500) })
    .then((r) => {
        console.log(ok(r.status) ? "ok" : `status-${r.status}`);
    })
    .catch(() => {
        console.log("error");
    });
' "http://${host}:${port}/signalk" 2>/dev/null | grep -q '^ok$'
}

probe_host_port() {
    local host="$1"
    local port="$2"
    podman exec "$doctor_container" node -e '
const net = require("net");
const host = process.argv[1];
const port = Number(process.argv[2]);
const s = net.createConnection({ host, port, timeout: 2500 }, () => {
  console.log("ok");
  s.destroy();
});
s.on("timeout", () => { console.log("timeout"); s.destroy(); });
s.on("error", () => { console.log("error"); });
' "$host" "$port" 2>/dev/null | grep -q '^ok$'
}

pick_signalk_http_port() {
    local host="$1"
    if probe_signalk_http "$host" "$sk_http_port"; then
        echo "$sk_http_port"
        return 0
    fi
    if [[ "$sk_http_port" != "3000" ]] && probe_signalk_http "$host" "3000"; then
        echo "3000"
        return 0
    fi
    if [[ "$sk_http_port" != "80" ]] && probe_signalk_http "$host" "80"; then
        echo "80"
        return 0
    fi
    return 1
}

sync_host="host.containers.internal"
resolved_http_port=""
if resolved_http_port="$(pick_signalk_http_port "$sync_host")"; then
    sk_http_port="$resolved_http_port"
    if ! probe_signalk_http "$sync_host" "$sk_http_port"; then
        echo "WARN: required host alias ${sync_host}:${sk_http_port} is unavailable; leaving existing updater/doctor health URLs unchanged" >&2
        exit 0
    fi
    tmp="${updater_quadlet}.tmp"
    awk -v host="$sync_host" -v p="$sk_http_port" '
        index($0, "Environment=SIGNALK_HEALTH_URL=") == 1 { $0 = "Environment=SIGNALK_HEALTH_URL=http://" host ":" p "/signalk" }
        index($0, "Environment=SIGNALK_URL=") == 1 { $0 = "Environment=SIGNALK_URL=http://" host ":" p }
        { print }
    ' "$updater_quadlet" > "$tmp"
    mv "$tmp" "$updater_quadlet"

    tmp="${doctor_quadlet}.tmp"
    awk -v host="$sync_host" -v hp="$sk_http_port" -v sp="$sk_https_port" '
        index($0, "Environment=SIGNALK_URL=") == 1 { $0 = "Environment=SIGNALK_URL=http://" host ":" hp "/signalk" }
        index($0, "Environment=SIGNALK_HTTPS_URL=") == 1 { $0 = "Environment=SIGNALK_HTTPS_URL=https://" host ":" sp "/signalk" }
        { print }
    ' "$doctor_quadlet" > "$tmp"
    mv "$tmp" "$doctor_quadlet"

    systemctl --user daemon-reload
    systemctl --user restart signalk-updater-server.service signalk-doctor-server.service
    echo "Synchronized updater/doctor health URLs to ${sync_host}:${sk_http_port}"
    exit 0
fi

alias_ip=$(podman exec "$doctor_container" sh -lc "getent hosts host.containers.internal | awk '{print \$1}' | head -n1" 2>/dev/null || true)
if [[ -z "$alias_ip" ]]; then
    echo "WARN: could not resolve host.containers.internal from doctor container; skipping health URL fix" >&2
    exit 0
fi

fallback_ip=$(echo "$alias_ip" | awk -F. 'NF==4 { print $1"."$2"."$3".1" }')
if [[ -z "$fallback_ip" ]]; then
    echo "WARN: could not derive fallback host IP from ${alias_ip}; skipping health URL fix" >&2
    exit 0
fi

resolved_http_port="$(pick_signalk_http_port "$fallback_ip" || true)"
if [[ -z "$resolved_http_port" ]]; then
    fallback_reachable=0
    for candidate_port in "$sk_http_port" "3000" "80"; do
        if probe_host_port "$fallback_ip" "$candidate_port"; then
            fallback_reachable=1
        fi
    done
    if (( fallback_reachable == 0 )); then
        echo "WARN: derived fallback host IP ${fallback_ip} is not reachable on ports ${sk_http_port}, 3000, or 80; skipping health URL fix" >&2
    else
        echo "WARN: derived fallback host IP ${fallback_ip} is reachable, but no SignalK endpoint responded on ports ${sk_http_port}, 3000, or 80" >&2
    fi
    exit 0
fi
sk_http_port="$resolved_http_port"
if ! probe_signalk_http "$sync_host" "$sk_http_port"; then
    echo "WARN: required host alias ${sync_host}:${sk_http_port} is unavailable; leaving existing updater/doctor health URLs unchanged" >&2
    exit 0
fi

tmp="${updater_quadlet}.tmp"
awk -v host="$sync_host" -v p="$sk_http_port" '
    index($0, "Environment=SIGNALK_HEALTH_URL=") == 1 { $0 = "Environment=SIGNALK_HEALTH_URL=http://" host ":" p "/signalk" }
    index($0, "Environment=SIGNALK_URL=") == 1 { $0 = "Environment=SIGNALK_URL=http://" host ":" p }
    { print }
' "$updater_quadlet" > "$tmp"
mv "$tmp" "$updater_quadlet"

tmp="${doctor_quadlet}.tmp"
awk -v host="$sync_host" -v hp="$sk_http_port" -v sp="$sk_https_port" '
    index($0, "Environment=SIGNALK_URL=") == 1 { $0 = "Environment=SIGNALK_URL=http://" host ":" hp "/signalk" }
    index($0, "Environment=SIGNALK_HTTPS_URL=") == 1 { $0 = "Environment=SIGNALK_HTTPS_URL=https://" host ":" sp "/signalk" }
    { print }
' "$doctor_quadlet" > "$tmp"
mv "$tmp" "$doctor_quadlet"

systemctl --user daemon-reload
systemctl --user restart signalk-updater-server.service signalk-doctor-server.service
echo "Synchronized updater/doctor health URLs to ${sync_host}:${sk_http_port} (probed via fallback ${fallback_ip})"
HEALTH_URL_FIX_SCRIPT

# 5. Forward the ports out of the machine
section "Port forwarding"
info "Podman Machine forwards rootless container ports to the host automatically."
info "The main SignalK server runs with Network=host inside the VM, so we also forward localhost:3000 over SSH."

# A host-networked server inside podman machine is not automatically forwarded by
# Podman itself. Detect the VM's real SignalK server port (80 or 3000) and bind
# the local macOS tunnel to a free port instead of assuming a hardcoded one.
_VM_SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}' 2>/dev/null || true)
_VM_SSH_USER=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.RemoteUsername}}' 2>/dev/null || true)
_VM_SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}' 2>/dev/null || true)
_VM_SERVER_PORT=$(podman machine ssh "$MACHINE_NAME" "grep -E '^Environment=PORT=' ~/.config/containers/systemd/signalk-server.container 2>/dev/null | awk -F= '{print \$NF}' || echo 80" 2>/dev/null || true)
_VM_SERVER_PORT=${_VM_SERVER_PORT:-80}
_LOCAL_UI_PORT=""
_TUNNEL_READY=0

pick_free_port() {
    local candidate
    for candidate in "$@"; do
        if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if [[ -n "$_VM_SSH_PORT" && -n "$_VM_SSH_USER" && -n "$_VM_SSH_KEY" ]]; then
    _VM_KNOWN_HOSTS="${HOME}/.ssh/known_hosts.${MACHINE_NAME}"
    mkdir -p "${HOME}/.ssh"
    touch "$_VM_KNOWN_HOSTS"
    chmod 600 "$_VM_KNOWN_HOSTS" 2>/dev/null || true

    if [[ "$_VM_SERVER_PORT" = "80" ]]; then
        if ! _LOCAL_UI_PORT=$(pick_free_port 8080 8000 8081 8181 18080); then
            warn "No free local UI port found for VM server port 80; skipping host-networked UI tunnel."
            _LOCAL_UI_PORT=""
        fi
    else
        if ! _LOCAL_UI_PORT=$(pick_free_port 3000 3002 3004 8080 8081 18080); then
            warn "No free local UI port found for VM server port ${_VM_SERVER_PORT}; skipping host-networked UI tunnel."
            _LOCAL_UI_PORT=""
        fi
    fi
    if [[ -n "$_LOCAL_UI_PORT" ]]; then
        if ! pgrep -f "ssh .*${_LOCAL_UI_PORT}:127.0.0.1:${_VM_SERVER_PORT}.*-p ${_VM_SSH_PORT}.*${_VM_SSH_USER}@127.0.0.1" >/dev/null 2>&1; then
            if ! ssh -f -N \
                -L "${_LOCAL_UI_PORT}:127.0.0.1:${_VM_SERVER_PORT}" \
                -i "$_VM_SSH_KEY" \
                -p "$_VM_SSH_PORT" \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile="$_VM_KNOWN_HOSTS" \
                -o IdentitiesOnly=yes \
                "${_VM_SSH_USER}@127.0.0.1"; then
                warn "Could not establish localhost:${_LOCAL_UI_PORT} SSH tunnel to the VM's SignalK server on port ${_VM_SERVER_PORT}."
            else
                _TUNNEL_READY=1
                ok "localhost:${_LOCAL_UI_PORT} is forwarded to the VM's SignalK server on port ${_VM_SERVER_PORT}"
            fi
        else
            _TUNNEL_READY=1
            ok "localhost:${_LOCAL_UI_PORT} SSH tunnel already running"
        fi
    fi
else
    warn "Could not determine the Podman machine SSH endpoint; skipping the host-networked UI tunnel."
fi

info "Visit the SignalK admin UI / Updater (:3003) / Doctor (:3004) from macOS."
if (( _TUNNEL_READY )) && [[ -n "$_LOCAL_UI_PORT" ]]; then
    info "The main server is exposed on localhost:${_LOCAL_UI_PORT} via the VM tunnel."
else
    info "No local UI tunnel was created automatically; choose a free local port and tunnel manually if needed."
fi

cat <<EOF

OK — SignalK is up inside Podman Machine '$MACHINE_NAME'.

    SignalK admin UI : $([ "$_TUNNEL_READY" -eq 1 ] && printf 'http://localhost:%s' "$_LOCAL_UI_PORT" || printf 'not auto-forwarded')  (VM port ${_VM_SERVER_PORT})
  Updater Console  : http://localhost:3003
  Doctor Console   : http://localhost:3004

To SSH into the machine for diagnostics:
  podman machine ssh $MACHINE_NAME
  ~/.local/bin/signalk-recovery status

Tokens (read inside the VM with podman machine ssh):
  ~/.signalk-updater/token
  ~/.signalk-doctor/token

USB serial passthrough on macOS requires explicit setup; see
docs/installation.md (section "macOS USB").
EOF
