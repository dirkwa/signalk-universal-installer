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

INSTALLER_VERSION="${INSTALLER_VERSION:-v0.1.0-3-g0fc21b7}"
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
if ! podman machine list --format '{{.Name}}' | grep -qx "$MACHINE_NAME"; then
    info "Creating Podman machine '$MACHINE_NAME' (this takes a few minutes)"
    podman machine init --cpus 2 --memory 4096 --disk-size 30 "$MACHINE_NAME"
fi

if ! podman machine list --format '{{.Name}} {{.Running}}' | grep -q "^$MACHINE_NAME[[:space:]]*true"; then
    info "Starting Podman machine"
    podman machine start "$MACHINE_NAME"
fi
ok "Podman machine '$MACHINE_NAME' running"

podman system connection default "$MACHINE_NAME" 2>/dev/null || true

# 4. Run the Linux installer inside the machine.
section "Bootstrapping inside the Podman machine"

# We pipe install.sh through `podman machine ssh` which runs an interactive
# shell in the VM. The Linux install.sh handles podman, systemd-user, linger,
# Quadlets — all of which exist inside the VM.
LINUX_URL="${INSTALLER_BASE_URL}/installer/linux/install.sh"
info "Fetching $LINUX_URL and running it in the machine"

podman machine ssh "$MACHINE_NAME" -- bash -lc "
    set -euo pipefail
    cd \$HOME
    curl -fsSL '${LINUX_URL}' -o /tmp/sk-install.sh
    chmod +x /tmp/sk-install.sh
    INSTALLER_VERSION='${INSTALLER_VERSION}' INSTALLER_BASE_URL='${INSTALLER_BASE_URL}' bash /tmp/sk-install.sh
"

# 5. Forward the ports out of the machine
section "Port forwarding"
info "Podman Machine forwards rootless container ports to the host automatically."
info "Visit http://localhost:3000 / :3003 / :3004 from macOS."

cat <<EOF

OK — SignalK is up inside Podman Machine '$MACHINE_NAME'.

  SignalK admin UI : http://localhost:3000
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
