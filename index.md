# SignalK Universal Installer (v2)

Bash/PowerShell bootstrap for the SignalK container stack on Linux, macOS, and Windows (WSL2).

> Status: **scaffold**. The real installer flow lands in a later phase. The current `install.sh` prints a placeholder and exits.

## What this installs

A peer-container stack managed by `systemd --user`:

- `signalk-server` — the SignalK Node Server in a container.
- `signalk-updater-server` — image lifecycle, version switching, self-update, hardware UI (`:3003`).
- `signalk-doctor-server` — read-only diagnostics, last-known-good recovery, the offline safety net (`:3004`).

All three run rootless under Podman with `Restart=on-failure` + crashloop guards. Recovery never depends on `signalk-server` being healthy, and never depends on the updater being healthy — the doctor is independent of both.

## Components

| Repo | Role |
|---|---|
| [signalk-universal-installer](https://github.com/dirkwa/signalk-universal-installer) | This repo. Bash + PowerShell + Quadlet templates. |
| [signalk-updater-server](https://github.com/dirkwa/signalk-updater-server) | Engine container — mutates the stack. |
| [signalk-doctor-server](https://github.com/dirkwa/signalk-doctor-server) | Engine container — diagnoses and recovers. |
| [signalk-updater](https://github.com/dirkwa/signalk-updater) | Thin-shell plugin inside signalk-server, deep-links to the updater console. |
| [signalk-doctor](https://github.com/dirkwa/signalk-doctor) | Thin-shell plugin, deep-links to the doctor console. |
| [signalk-container](https://github.com/dirkwa/signalk-container) | Cross-plugin container-runtime substrate. |

## Quick start (placeholder)

```bash
# Linux
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash

# macOS
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/macos/install.sh | bash

# Windows (PowerShell, WSL2 expected)
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex
```

## Predecessor

The legacy "Universal Installer" with bundled Keeper, Caddy, Kopia, InfluxDB, and Grafana is preserved at [signalk-universal-installer-v1](https://github.com/dirkwa/signalk-universal-installer-v1) (archived) and locally on the `legacy-v1-keeper` branch / `v1-keeper-final` tag.
