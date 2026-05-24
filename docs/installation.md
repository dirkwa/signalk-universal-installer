# Installation

## Linux (Debian 13, Ubuntu 24.04+, Raspberry Pi OS bookworm+)

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

The installer:

1. Detects your distro and runs pre-flight (RAM ≥ 2 GB, disk ≥ 5 GB, ports 3000/3003/3004/3010 free, cgroups v2, Podman ≥ 4.4).
2. Installs Podman + `uidmap` + `slirp4netns` via `apt` if missing.
3. Enables `loginctl enable-linger $USER` so the stack survives reboots.
4. Adds you to `dialout`, `gpio`, `netdev` groups for USB serial / GPIO / CAN.
5. Generates bearer-auth tokens for the updater and doctor (mode 0600).
6. Detects USB serial / SocketCAN / Bluetooth-DBus / Pi GPIO into `~/.signalk-updater/hardware.json`.
7. Pulls the three container images (multi-arch: amd64 + arm64).
8. Atomically writes three Quadlets into `~/.config/containers/systemd/`.
9. Starts the doctor and updater services, then asks the updater to start signalk-server (with a `systemctl --user` fallback).
10. Installs the SSH-only recovery script at `~/.local/bin/signalk-recovery` (the safety net for when both engine containers are down).
11. Installs the `signalk` command at `~/.local/bin/signalk` — a dispatcher for `health`, `recover`, `bug-report`, and `uninstall`. Run `signalk help` for usage.
12. Drops a journald retention drop-in at `/etc/systemd/journald.conf.d/signalk.conf` (uses `sudo`).

When it finishes you have three URLs reachable from the LAN: `:3000` (SignalK), `:3003` (Updater Console), `:3004` (Doctor Console). The installer binds the engine containers to `0.0.0.0` by default because most users install headless and reach the consoles from another machine. The updater's mutating endpoints and the doctor's `/api/recover` are gated by bearer tokens (see `~/.signalk-{updater,doctor}/token`); the doctor's read-only probes are unauthenticated by design (recovery surface that always answers). To restrict everything to localhost set `SIGNALK_LOCALHOST_ONLY=true` before running the installer — useful on shared/guest WiFi where you'd rather not expose probe output.

### Re-running

The installer is idempotent. If a step fails, fix the issue (e.g. install missing apt deps, free a port) and re-run.

### Migrating from the v1 (Keeper-based) installer

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/legacy-cleanup.sh | bash
```

This removes the v1 systemd units (`signalk-keeper`, `signalk-caddy`, `signalk-kopia`, etc.) and Quadlets but preserves `~/.signalk/` and `~/.signalk-backup/`. Then re-run `install.sh`.

## macOS (Apple Silicon and Intel)

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/macos/install.sh | bash
```

The macOS installer assumes Homebrew is installed. It:

1. Installs Podman via `brew install podman`.
2. Creates a Podman Machine (`signalk`, 2 CPUs / 4 GB / 30 GB disk by default).
3. Starts the machine.
4. Runs the Linux installer **inside** the machine via `podman machine ssh`. Everything you see at `http://localhost:3000` is actually running on the Linux VM the machine provides.

Podman Machine handles port forwarding to the host transparently.

### macOS USB serial

Podman Machine on macOS exposes USB devices into the Linux VM only when the machine is created with `--usb`. If you need USB-serial passthrough (NMEA2000 gateway etc.), recreate the machine:

```bash
podman machine stop signalk
podman machine rm signalk
podman machine init --cpus 2 --memory 4096 --disk-size 30 --usb signalk
# … then re-run install.sh
```

CAN, Bluetooth, and GPIO are **not supported** on macOS Podman Machine.

## Windows (WSL2)

Open PowerShell **as administrator**:

```powershell
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex
```

The Windows installer:

1. Checks for Administrator + Windows 10 build 19041+ / Windows 11.
2. Runs `wsl --install -d Debian` if WSL is missing.
3. Hands off to the Linux installer inside WSL.

Result: the same container stack as Linux, accessible from Windows via WSL's automatic localhost port forwarding.

### Windows USB serial

WSL2 doesn't expose USB devices to the Linux side by default. Use [usbipd-win](https://github.com/dorssel/usbipd-win) to attach a USB-serial device to WSL:

```powershell
winget install --id dorssel.usbipd-win
usbipd list                             # find the BUSID of your gateway
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>     # while WSL is running
```

Then in WSL, the device shows up as `/dev/ttyUSB0` etc. and you can re-run the hardware re-detect from the Updater Console.

## Recovery

If the install completes but something doesn't work, your two recovery surfaces are:

1. **Doctor Console** at `http://localhost:3004` — read-only probes + a "Recover" button that restores Quadlets from the last-known-good snapshot.
2. **`~/.local/bin/signalk-recovery`** — pure bash, zero container dependencies. Works from SSH even if both engine containers are dead.

```bash
~/.local/bin/signalk-recovery status         # what's running, what's broken
~/.local/bin/signalk-recovery doctor         # full diagnostics dump
~/.local/bin/signalk-recovery rollback-all   # restore from snapshots
```

See [docs/recovery.md](recovery.md) for the deeper recovery playbook.
