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
INSTALLER_BASE_URL="${INSTALLER_BASE_URL:-https://dirkwa.github.io/signalk-universal-installer}"

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[ERR] This script only runs on macOS (current: $(uname -s))" >&2
    exit 1
fi

info()    { printf '[i] %s\n' "$*"; }
ok()      { printf '[OK] %s\n' "$*"; }
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

# Optional reset: remove any existing machine before recreating it.
if (( RESET_MACHINE )); then
    if podman machine list --format '{{.Name}}' | grep -q "^${MACHINE_NAME}"; then
        info "Removing existing Podman machine '$MACHINE_NAME' (--reset-machine)"
        podman machine stop "$MACHINE_NAME" 2>/dev/null || true
        podman machine rm -f "$MACHINE_NAME"
    fi
fi

info "Creating Podman machine '$MACHINE_NAME' (${MACHINE_MEMORY_MB} MB; this takes a few minutes)"
podman machine init --cpus 2 --memory "$MACHINE_MEMORY_MB" --disk-size 30 "$MACHINE_NAME"

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

podman machine ssh "$MACHINE_NAME" bash << LINUX_SCRIPT
set -euo pipefail
cd \$HOME
curl -fsSL '${LINUX_URL}' | INSTALLER_VERSION='${INSTALLER_VERSION}' INSTALLER_BASE_URL='${INSTALLER_BASE_URL}' bash
LINUX_SCRIPT

# On SELinux VMs, container label isolation blocks access to the mounted
# rootless podman socket unless SecurityLabelDisable is set.
info "Applying signalk-server socket-access fix for SELinux VMs"
podman machine ssh "$MACHINE_NAME" bash << 'SOCKET_FIX_SCRIPT'
set -euo pipefail
quadlet="$HOME/.config/containers/systemd/signalk-server.container"
if [[ ! -f "$quadlet" ]]; then
    echo "WARN: signalk-server quadlet not found at $quadlet; skipping socket-access fix" >&2
    exit 0
fi

if grep -q '^SecurityLabelDisable=true$' "$quadlet"; then
    echo "signalk-server quadlet already has SecurityLabelDisable=true"
    exit 0
fi

if ! grep -q '^Volume=%t/podman/podman.sock:/var/run/docker.sock$' "$quadlet"; then
    echo "WARN: signalk-server quadlet has no podman socket mount; skipping socket-access fix" >&2
    exit 0
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

systemctl --user daemon-reload
if systemctl --user restart signalk-server.service; then
    echo "Applied socket-access fix and restarted signalk-server.service"
else
    echo "WARN: applied socket-access fix but restart failed; restart signalk-server.service manually" >&2
fi
SOCKET_FIX_SCRIPT

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

pick_free_port() {
    local candidate
    for candidate in "$@"; do
        if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    echo "8080"
    return 0
}

if [[ -n "$_VM_SSH_PORT" && -n "$_VM_SSH_USER" && -n "$_VM_SSH_KEY" ]]; then
    if [[ "$_VM_SERVER_PORT" = "80" ]]; then
        _LOCAL_UI_PORT=$(pick_free_port 8080 8000 8081 8181 18080)
    else
        _LOCAL_UI_PORT=$(pick_free_port 3000 3002 3004 8080 8081 18080)
    fi
    if ! pgrep -f "ssh .*${_LOCAL_UI_PORT}:127.0.0.1:${_VM_SERVER_PORT}.*-p ${_VM_SSH_PORT}.*${_VM_SSH_USER}@127.0.0.1" >/dev/null 2>&1; then
        if ! ssh -f -N \
            -L "${_LOCAL_UI_PORT}:127.0.0.1:${_VM_SERVER_PORT}" \
            -i "$_VM_SSH_KEY" \
            -p "$_VM_SSH_PORT" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            "${_VM_SSH_USER}@127.0.0.1"; then
            warn "Could not establish localhost:${_LOCAL_UI_PORT} SSH tunnel to the VM's SignalK server on port ${_VM_SERVER_PORT}."
        else
            ok "localhost:${_LOCAL_UI_PORT} is forwarded to the VM's SignalK server on port ${_VM_SERVER_PORT}"
        fi
    else
        ok "localhost:${_LOCAL_UI_PORT} SSH tunnel already running"
    fi
else
    warn "Could not determine the Podman machine SSH endpoint; skipping the host-networked UI tunnel."
fi

info "Visit the SignalK admin UI / Updater (:3003) / Doctor (:3004) from macOS."
info "The main server is exposed on localhost:${_LOCAL_UI_PORT} via the VM tunnel."

cat <<EOF

OK — SignalK is up inside Podman Machine '$MACHINE_NAME'.

  SignalK admin UI : http://localhost:${_LOCAL_UI_PORT}  (VM port ${_VM_SERVER_PORT})
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
