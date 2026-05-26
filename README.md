# SignalK Universal Installer (v2)

Bash/PowerShell bootstrap for the SignalK container stack on Linux, macOS, and Windows (WSL2).

## What this installs

A peer-container stack managed by `systemd --user`:

- `signalk-server` — the SignalK Node Server in a container.
- `signalk-updater-server` — image lifecycle, version switching, self-update, hardware passthrough (`:3003`). Web console with Dashboard / Versions / Logs tabs.
- `signalk-doctor-server` — read-only diagnostics, last-known-good recovery, the offline safety net (`:3004`). Web console with Health / Drift / Logs / Snapshots / Recover / Installer tabs.

All three run rootless under Podman. `signalk-updater-server` and `signalk-doctor-server` use `Restart=on-failure`; `signalk-server` uses `Restart=always` (the admin UI's "Restart" button does a clean `process.exit(0)` that `on-failure` wouldn't recover from). Both policies sit behind `StartLimitIntervalSec=300` + `StartLimitBurst=5` crashloop guards. Recovery never depends on `signalk-server` being healthy, and never depends on the updater being healthy — the doctor is independent of both, and a host-resident bash script (`~/.local/bin/signalk-recovery`) backs both of them when neither container can respond.

The installer also installs and auto-enables the three companion SignalK plugins (`signalk-container`, `signalk-updater`, `signalk-doctor`) into `~/.signalk/` so the admin UI gets the in-server side of the stack on first boot.

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

## Roadmap

Outstanding work:

- **Updater Console Hardware tab.** The hardware-apply REST endpoint and on-disk `~/.signalk-updater/hardware.json` are in place; the in-browser UI for toggling devices is not. Until it lands, re-running hardware detection requires re-running the bash installer (which re-runs `detect-hardware.sh` and the apply path is idempotent on identical input).
- **Persistent-label config-panel hiding.** Engine Quadlets are stamped with `io.signalk.persistent=true` (`signalk-container` reads this from `ContainerConfig.labels`), but its config panel UI doesn't yet hide Stop / Remove buttons for persistent containers. Stop/Remove on an engine container today is still possible from the panel — a future signalk-container release will gate those controls on the label.
- **Pi 5 / Pi 4 / macOS / Windows real-hardware smoke tests.** Documented in `docs/installation.md`; runs in front of physical devices.

## Predecessor

The legacy "Universal Installer" with bundled Keeper, Caddy, Kopia, InfluxDB, and Grafana is preserved at [signalk-universal-installer-v1](https://github.com/dirkwa/signalk-universal-installer-v1) (archived) and locally on the `legacy-v1-keeper` branch / `v1-keeper-final` tag.
