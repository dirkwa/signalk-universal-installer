# SignalK Universal Installer (v2)

Bash/PowerShell bootstrap for the SignalK container stack on Linux, macOS, and Windows (WSL2).

## What this installs

A peer-container stack managed by `systemd --user`:

- `signalk-server` — the SignalK Node Server in a container.
- `signalk-updater-server` — image lifecycle, version switching, self-update, hardware passthrough (`:3003`). Web console with Dashboard / Versions / Logs tabs.
- `signalk-doctor-server` — read-only diagnostics, last-known-good recovery, the offline safety net (`:3004`). Web console with Health / Drift / Logs / Snapshots / Recover / Installer tabs.

All three run rootless under Podman. `signalk-updater-server` and `signalk-doctor-server` use `Restart=on-failure`; `signalk-server` uses `Restart=always` (the admin UI's "Restart" button does a clean `process.exit(0)` that `on-failure` wouldn't recover from). Both policies sit behind `StartLimitBurst=5` crashloop guards (the peers over a 300s `StartLimitIntervalSec`; `signalk-server` over 1800s, widened to match its longer `TimeoutStartSec=300` so a slow-but-recovering start on SD-card hosts isn't cut off). Recovery never depends on `signalk-server` being healthy, and never depends on the updater being healthy — the doctor is independent of both, and a host-resident bash script (`~/.local/bin/signalk-recovery`) backs both of them when neither container can respond.

During bootstrap, the installer runs `npm install` for three companion SignalK plugins (`signalk-container`, `signalk-updater`, `signalk-doctor`) inside the `signalk-server` container — the container does the actual writes to its `~/.signalk/` mount — and seeds default plugin config files (if absent). User-disabled plugins are never re-enabled on re-runs.

## Components

| Repo                                                                                 | Role                                                                          |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| [signalk-universal-installer](https://github.com/dirkwa/signalk-universal-installer) | This repo. Bash + PowerShell + Quadlet templates.                             |
| [signalk-updater-server](https://github.com/dirkwa/signalk-updater-server)           | Engine container — mutates the stack (version switch, self-update, hardware). |
| [signalk-doctor-server](https://github.com/dirkwa/signalk-doctor-server)             | Engine container — diagnoses and recovers (probes, last-known-good restore).  |
| [signalk-updater](https://github.com/dirkwa/signalk-updater)                         | Thin-shell plugin inside signalk-server, deep-links to the updater console.   |
| [signalk-doctor](https://github.com/dirkwa/signalk-doctor)                           | Thin-shell plugin, deep-links to the doctor console.                          |
| [signalk-container](https://github.com/dirkwa/signalk-container)                     | Cross-plugin container-runtime substrate.                                     |

## Quick start

```bash
# Linux (Debian 13 / trixie, Raspberry Pi OS trixie+, Ubuntu/Kubuntu 25.04+)
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash

# macOS (Apple Silicon and Intel; Homebrew required)
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/macos/install.sh | bash
```

```powershell
# Windows 11 (PowerShell as administrator; enables WSL2, then Podman Machine runs the stack)
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex
```

### Release channels

The one-liners above install the latest **release**. `signalk update` follows the
same channel, because the doctor's refresh reads the same published tree.

To track `master` instead — for development or to test an unreleased fix:

```bash
# Linux
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/dev/installer/linux/install.sh | SIGNALK_CHANNEL=master bash

# macOS
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/dev/installer/macos/install.sh | SIGNALK_CHANNEL=master bash

# either, afterwards
SIGNALK_CHANNEL=master signalk update
```

The variable goes on `bash`, not on `curl`: it is read by the downloaded
installer, not by the fetch. Set on `curl` it would be silently ignored and the
run would pull the rest of its tree from the release channel.

On Windows the channel is a parameter rather than an environment variable, so
`iwr … | iex` cannot carry it — `iex` has nowhere to put arguments. Download the
script first, then invoke it:

```powershell
# Windows
iwr -useb https://dirkwa.github.io/signalk-universal-installer/dev/installer/windows/install.ps1 -OutFile install.ps1
.\install.ps1 -Channel master
```

The installed `signalk` command remembers the channel it was installed from, so
`signalk update` on a master box stays on master. Set `$env:SIGNALK_CHANNEL` to
override a single run.

`INSTALLER_BASE_URL` (Linux/macOS) and `-InstallerBaseUrl` (Windows) still
override both, for mirrors, CI and local checkouts.

Then open:

- `http://localhost` — SignalK admin UI (port 80 by default; `:3000` if you decline standard ports at install).
- `http://localhost:3003` — Updater Console.
- `http://localhost:3004` — Doctor Console.

### Connecting NMEA hardware

USB gateways (Actisense NGT-1, USB GPS, NMEA 0183 adapters) are detected and passed into the container automatically. After plugging one in:

```bash
signalk hardware rescan
```

Then add the connection in the SignalK admin UI under **Server → Data Connections**, using the stable `by-id` path rather than `/dev/ttyUSB0` — with two USB serial devices the `ttyUSB` numbering can swap on reboot.

See [docs/hardware.md](docs/hardware.md) for the walkthrough, SocketCAN, Bluetooth and audio passthrough, and what to check when a device does not appear. On a Hat Labs HALPI2 the installer also sets up the carrier board itself (Hat Labs packages, CAN, RS-485, LEDs) — [docs/halpi2.md](docs/halpi2.md).

See [docs/installation.md](docs/installation.md) for the full per-platform walkthrough, and [docs/recovery.md](docs/recovery.md) for the recovery playbook.

## Development

One command gives you a complete, isolated dev environment — the stack's own pre-built signalk-server on port 4000 (clear of a production install), plugin linking, shellcheck, Playwright e2e, and AI tooling:

```bash
devpod up github.com/dirkwa/signalk-universal-installer
# or: clone + VS Code → "Reopen in Container"
# or, on a box the installer already provisioned (installs devpod itself):
signalk devpod up
```

See [docs/devcontainer.md](docs/devcontainer.md) for plugin/server/installer workflows, NMEA 2000 access, and troubleshooting.

## Known limitations

- **Toggling an individual device on or off means editing `hardware.json`.** Re-*detection* is a one-liner (`signalk hardware rescan`), and the `POST /api/hardware/apply` endpoint works end-to-end, but the Updater Console doesn't expose a Hardware tab — so switching a detected device off, rather than picking up a new one, still means editing the `enabled` field directly.
- **The signalk-container config panel does not gate Stop / Remove on `io.signalk.persistent=true`.** Engine Quadlets are stamped with the label and `signalk-container` reads it from `ContainerConfig.labels`, but the UI still offers Stop and Remove buttons for engine containers. Pressing them takes the stack down; recover via the Doctor Console or `~/.local/bin/signalk-recovery`.
- **Real-hardware smoke tests run in front of physical devices.** Pi 5 / Pi 4 / macOS Podman Machine + USB / WSL2 + usbipd are documented in `docs/installation.md` but not part of the CI matrix.

## Predecessor

The legacy "Universal Installer" with bundled Keeper, Caddy, Kopia, InfluxDB, and Grafana is preserved at [signalk-universal-installer-v1](https://github.com/dirkwa/signalk-universal-installer-v1) (archived) and locally on the `legacy-v1-keeper` branch / `v1-keeper-final` tag.
