# How the stack is built

## What the installer sets up

A peer-container stack managed by `systemd --user`:

- `signalk-server` — the SignalK Node Server in a container.
- `signalk-updater-server` — image lifecycle, version switching, self-update, hardware passthrough (`:3003`). Web console with Dashboard / Versions / Logs tabs.
- `signalk-doctor-server` — read-only diagnostics, last-known-good recovery, the offline safety net (`:3004`). Web console with Health / Drift / Logs / Snapshots / Recover / Installer tabs.

All three run rootless under Podman. `signalk-updater-server` and `signalk-doctor-server` use `Restart=on-failure` behind a `StartLimitBurst=5` crashloop guard over a 300s `StartLimitIntervalSec`. `signalk-server` uses `Restart=always` (the admin UI's "Restart" button does a clean `process.exit(0)` that `on-failure` wouldn't recover from) with `RestartSec=10` and no start limit (`StartLimitIntervalSec=0`, #235): a limit tight enough to catch a crashloop also trips on plugin-development restarts and OOM kills, and a tripped unit stays down until `systemctl --user reset-failed`. `quadlets/signalk-server.container.template` has the full rationale. Recovery never depends on `signalk-server` being healthy, and never depends on the updater being healthy — the doctor is independent of both, and a host-resident bash script (`~/.local/bin/signalk-recovery`) backs both of them when neither container can respond.

During bootstrap, the installer runs `npm install` for three companion SignalK plugins (`signalk-container`, `signalk-updater`, `signalk-doctor`) inside the `signalk-server` container — the container does the actual writes to its `~/.signalk/` mount — and seeds default plugin config files (if absent). User-disabled plugins are never re-enabled on re-runs.

[installation.md](installation.md) lists every install step, and its [Quadlet layout](installation.md#quadlet-layout) section the settings of each container.

## Components

| Repo                                                                                 | Role                                                                          |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| [signalk-universal-installer](https://github.com/dirkwa/signalk-universal-installer) | This repo. Bash + PowerShell + Quadlet templates.                             |
| [signalk-updater-server](https://github.com/dirkwa/signalk-updater-server)           | Engine container — mutates the stack (version switch, self-update, hardware). |
| [signalk-doctor-server](https://github.com/dirkwa/signalk-doctor-server)             | Engine container — diagnoses and recovers (probes, last-known-good restore).  |
| [signalk-updater](https://github.com/dirkwa/signalk-updater)                         | Thin-shell plugin inside signalk-server, deep-links to the updater console.   |
| [signalk-doctor](https://github.com/dirkwa/signalk-doctor)                           | Thin-shell plugin, deep-links to the doctor console.                          |
| [signalk-container](https://github.com/dirkwa/signalk-container)                     | Cross-plugin container-runtime substrate.                                     |

## Real-hardware testing

Real-hardware smoke tests run in front of physical devices. Pi 5 / Pi 4 / macOS Podman Machine + USB / WSL2 + usbipd are documented in [installation.md](installation.md) but not part of the CI matrix.
