# SignalK Universal Installer (v2)

Bash/PowerShell bootstrap for the SignalK container stack on Linux, macOS, and Windows (WSL2).

> Status: **v0.1.0 — first end-to-end runnable release.** Engine container images published to GHCR; the `curl … | bash` one-liner is wired up and ready for real-VM smoke testing. See "Roadmap" below for what's deferred.

## What this installs

A peer-container stack managed by `systemd --user`:

- `signalk-server` — the SignalK Node Server in a container.
- `signalk-updater-server` — image lifecycle, version switching, self-update, hardware UI (`:3003`).
- `signalk-doctor-server` — read-only diagnostics, last-known-good recovery, the offline safety net (`:3004`).

All three run rootless under Podman with `Restart=on-failure` + crashloop guards. Recovery never depends on `signalk-server` being healthy, and never depends on the updater being healthy — the doctor is independent of both, and a host-resident bash script (`~/.local/bin/signalk-recovery`) backs both of them when neither container can respond.

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
# Linux (Debian 13, Ubuntu 24.04+, Raspberry Pi OS bookworm+)
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

Things deferred to follow-up PRs (not blockers for v0.1.0):

- **Webapp UI for the engine containers.** Phases 4 and 5 built REST APIs only; a real UI (Vite + React + shadcn) is a separate effort. For now `curl`-driven workflows work end-to-end.
- **Persistent-label config-panel hiding.** signalk-container 1.11+ will hide Stop/Remove for `io.signalk.persistent=true` containers in its config UI. The label write path is in place (`ContainerConfig.labels`) but the UI affordance isn't.
- **Hardware re-detect from inside the container.** Phase 10 added the apply path; re-running detection still requires SSH + `signalk-recovery doctor` or `detect-hardware.sh`.
- **Pi 5 / Pi 4 / macOS / Windows real-hardware smoke tests.** Documented in `docs/installation.md`; runs in front of physical devices.

## Predecessor

The legacy "Universal Installer" with bundled Keeper, Caddy, Kopia, InfluxDB, and Grafana is preserved at [signalk-universal-installer-v1](https://github.com/dirkwa/signalk-universal-installer-v1) (archived) and locally on the `legacy-v1-keeper` branch / `v1-keeper-final` tag.
