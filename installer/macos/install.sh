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

if ! podman machine list --format '{{.Name}}' | grep -qx "$MACHINE_NAME"; then
    info "Creating Podman machine '$MACHINE_NAME' (${MACHINE_MEMORY_MB} MB; this takes a few minutes)"
    podman machine init --cpus 2 --memory "$MACHINE_MEMORY_MB" --disk-size 30 "$MACHINE_NAME"
fi

if ! podman machine list --format '{{.Name}} {{.Running}}' | grep -q "^${MACHINE_NAME}[[:space:]]*true"; then
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
    curl -fsSL '${LINUX_URL}' \
      | INSTALLER_VERSION='${INSTALLER_VERSION}' INSTALLER_BASE_URL='${INSTALLER_BASE_URL}' bash
"

# 5. Forward the ports out of the machine
section "Port forwarding"
info "Podman Machine forwards rootless container ports to the host automatically."
info "Visit the SignalK admin UI / Updater (:3003) / Doctor (:3004) from macOS."

cat <<EOF

OK — SignalK is up inside Podman Machine '$MACHINE_NAME'.

  SignalK admin UI : http://localhost  (or :3000 if you declined standard ports)
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
