# SignalK Universal Installer (v2)

Bash/PowerShell bootstrap for the SignalK container stack on Linux, macOS, and Windows (WSL2).

## What this installs

A peer-container stack managed by `systemd --user`:

- `signalk-server` — the SignalK Node Server in a container.
- `signalk-updater-server` — image lifecycle, version switching, self-update, hardware passthrough (`:3003`). Web console with Dashboard / Versions / Logs tabs.
- `signalk-doctor-server` — read-only diagnostics, last-known-good recovery, the offline safety net (`:3004`). Web console with Health / Drift / Logs / Snapshots / Recover / Installer tabs.

All three run rootless under Podman. `signalk-updater-server` and `signalk-doctor-server` use `Restart=on-failure`; `signalk-server` uses `Restart=always` (the admin UI's "Restart" button does a clean `process.exit(0)` that `on-failure` wouldn't recover from). Both policies sit behind `StartLimitIntervalSec=300` + `StartLimitBurst=5` crashloop guards. Recovery never depends on `signalk-server` being healthy, and never depends on the updater being healthy — the doctor is independent of both, and a host-resident bash script (`~/.local/bin/signalk-recovery`) backs both of them when neither container can respond.

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
# Linux (Debian 13 / trixie, Ubuntu 24.04+, Raspberry Pi OS trixie+)
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash

# macOS (Apple Silicon and Intel; Homebrew required)
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/macos/install.sh | bash

# Windows (PowerShell as administrator, WSL2 will be installed if absent)
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex
```

Then open:

- `http://localhost:3000` — SignalK admin UI.
- `http://localhost:3003` — Updater Console.
- `http://localhost:3004` — Doctor Console.

See [docs/installation.md](docs/installation.md) for the full per-platform walkthrough, and [docs/recovery.md](docs/recovery.md) for the recovery playbook.

## Known limitations

- **Hardware device toggling requires re-running the installer.** The `POST /api/hardware/apply` endpoint and on-disk `~/.signalk-updater/hardware.json` work end-to-end; the Updater Console doesn't expose a Hardware tab, so toggling individual devices on or off means editing `hardware.json` directly (or re-running `curl … | bash`, which re-runs detection and is idempotent on identical input).
- **The signalk-container config panel does not gate Stop / Remove on `io.signalk.persistent=true`.** Engine Quadlets are stamped with the label and `signalk-container` reads it from `ContainerConfig.labels`, but the UI still offers Stop and Remove buttons for engine containers. Pressing them takes the stack down; recover via the Doctor Console or `~/.local/bin/signalk-recovery`.
- **Real-hardware smoke tests run in front of physical devices.** Pi 5 / Pi 4 / macOS Podman Machine + USB / WSL2 + usbipd are documented in `docs/installation.md` but not part of the CI matrix.

## Predecessor

The legacy "Universal Installer" with bundled Keeper, Caddy, Kopia, InfluxDB, and Grafana is preserved at [signalk-universal-installer-v1](https://github.com/dirkwa/signalk-universal-installer-v1) (archived) and locally on the `legacy-v1-keeper` branch / `v1-keeper-final` tag.
