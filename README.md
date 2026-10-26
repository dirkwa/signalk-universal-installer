# Signal K Universal Installer

One command installs the [Signal K server](https://signalk.org) on a Raspberry Pi, a Linux PC, a Mac or a Windows PC. Signal K runs in containers next to two web consoles that look after it: the **Updater Console** switches Signal K versions and rolls back to the previous one, and the **Doctor Console** checks the installation and restores the last setup that worked.

## Install

**Raspberry Pi and Linux**: Raspberry Pi OS (Trixie), Debian 13, Ubuntu or Kubuntu 25.04 and newer.

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

**macOS**: Apple Silicon or Intel, with [Homebrew](https://brew.sh) installed.

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/macos/install.sh | bash
```

**Windows 11**: in PowerShell, run as administrator.

```powershell
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex
```

The installer needs 2 GB of RAM and 5 GB of free disk space. It asks for your boat's name, MMSI and call sign (Enter skips each one) and for the admin password you will sign in to Signal K with. On Windows without WSL2, it turns WSL2 on and asks for one reboot; run the same command again after the reboot and it carries on.

Running the command again on an installed box keeps your data and settings, and ends by checking that Signal K and both consoles run and answer. [docs/installation.md](docs/installation.md) describes each step on each platform.

## Open Signal K

The installer ends by printing the box's address. Open these in a browser on any phone, tablet or laptop on the boat's network:

| Address | What it is |
|---|---|
| `http://<address>` | Signal K: its webapps and the admin UI |
| `http://<address>/signalk-universal-installer-rpi-mgmt/` | RPI Manager: the computer's temperature, load, memory and storage, and buttons to restart Signal K, reboot or power off |
| `http://<address>:3003` | Updater Console: Signal K versions, rollback, updates for both consoles |
| `http://<address>:3004` | Doctor Console: health checks, snapshots, recovery |

Signal K uses port 80 unless you declined the standard web ports during the install; then it is at `http://<address>:3000`.

## A screen on the box (kiosk)

On a Raspberry Pi or Linux box with a monitor or touchscreen:

```bash
signalk kiosk enable
```

The screen then shows Signal K full screen at every power-on, already signed in, with no desktop, login prompt or browser bars. It opens App Dock with Freeboard-SK; double-tap the screen to switch webapps. While the monitor is switched off, the browser is paused and uses no CPU (on monitors that support DDC/CI). `signalk kiosk disable` gives you the desktop back. [docs/kiosk.md](docs/kiosk.md) has the options and touchscreen notes.

## Connect your instruments

USB gateways (Actisense NGT-1, USB GPS, NMEA 0183 adapters) are passed to Signal K automatically. After plugging one in, run:

```bash
signalk hardware rescan
```

Then add it in the Signal K admin UI under **Server → Data Connections**, choosing the `/dev/serial/by-id/…` path rather than `/dev/ttyUSB0`: with two USB serial devices, the `ttyUSB` numbers can swap at a reboot.

- **CAN HAT on a Raspberry Pi**: `signalk socketcan` detects the HAT and prints the setup steps ([docs/socketcan.md](docs/socketcan.md)).
- **Hat Labs HALPI2**: the installer sets up the board itself: Hat Labs packages, CAN, RS-485 and LEDs ([docs/halpi2.md](docs/halpi2.md)).
- **Bluetooth sensors**: `signalk bluetooth enable`.

[docs/hardware.md](docs/hardware.md) covers audio and input devices, and what to check when a device does not show up.

## The `signalk` command

| Command | What it does |
|---|---|
| `signalk health` | Shows whether Signal K and both consoles run, with their addresses |
| `signalk restart` | Restarts Signal K, for example after a settings change |
| `signalk stop`, `signalk start` | Stops Signal K until `signalk start`, reboots included; data and settings stay |
| `signalk update` | Updates the installer's scripts and container templates |
| `signalk resetadmin` | Sets a new admin password |
| `signalk kiosk enable` | Boots this box's screen into Signal K (Linux) |
| `signalk bug-report` | Packs logs and the installation's state into one file for an issue |
| `signalk uninstall` | Removes the Signal K services and keeps your data |
| `signalk help` | Lists every command |

On Windows, `signalk` works in any new terminal. On macOS the stack runs in a Podman machine: open a shell there with `podman machine ssh signalk` and run `~/.local/bin/signalk`.

## Updates

- **Signal K**: Updater Console → Versions. Pick a version, or roll back to the previous one.
- **Updater and Doctor**: Updater Console → Dashboard.
- **Installer scripts**: `signalk update`.

## When something goes wrong

1. `signalk health` shows what is down.
2. Updater Console → Versions → roll back to the previous Signal K version.
3. Doctor Console → Recover restores the last setup that worked. It does not need the Updater.
4. Over SSH, when neither console answers: `signalk recover rollback-all` restores the last working setup with no container running.

Forgot the admin password: `signalk resetadmin`. To report a problem, run `signalk bug-report` and attach the file to a [GitHub issue](https://github.com/dirkwa/signalk-universal-installer/issues). [docs/recovery.md](docs/recovery.md) goes through each case.

## Known limitations

- **Switching a detected device off** means editing `~/.signalk-updater/hardware.json`; the Updater Console has no hardware tab yet. [docs/hardware.md](docs/hardware.md#re-running-detection) has the steps.
- **The Stop and Remove buttons in the signalk-container plugin** are also offered for the stack's own containers, and pressing them takes Signal K down. Bring it back from the Doctor Console or with `signalk recover rollback-all`.

## More

| Document | Covers |
|---|---|
| [docs/installation.md](docs/installation.md) | Each install step per platform, ports, re-running, [unreleased versions](docs/installation.md#release-channels) |
| [docs/hardware.md](docs/hardware.md) | USB, CAN, Bluetooth, audio and input passthrough |
| [docs/socketcan.md](docs/socketcan.md) | CAN HATs on a Raspberry Pi |
| [docs/halpi2.md](docs/halpi2.md) | Hat Labs HALPI2 |
| [docs/kiosk.md](docs/kiosk.md) | Kiosk mode |
| [docs/recovery.md](docs/recovery.md) | Recovery, case by case |
| [docs/architecture.md](docs/architecture.md) | How the stack is built, and the repositories behind it |
| [docs/development.md](docs/development.md) | Developing plugins or the server on an installed box |
| [docs/devcontainer.md](docs/devcontainer.md) | The development container, in detail |

For development, `signalk devpod up` sets up a separate Signal K server on port 4000 with plugin linking and the test tools, without touching the installed one ([docs/development.md](docs/development.md)). `signalk devpod rust up` does the same for WASM plugins written in Rust, on port 4001, and opens in Zed where Zed is installed ([docs/devcontainer.md](docs/devcontainer.md#rust--wasm-plugins)).

The older installer, with Keeper, Caddy, Kopia, InfluxDB and Grafana bundled, is archived at [signalk-universal-installer-v1](https://github.com/dirkwa/signalk-universal-installer-v1) and on this repository's `legacy-v1-keeper` branch and `v1-keeper-final` tag.
