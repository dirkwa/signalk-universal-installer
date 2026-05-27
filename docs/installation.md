# Installation

## Linux (Debian 13 / trixie, Ubuntu 24.04+, Raspberry Pi OS trixie+)

> Debian 12 (bookworm) is **not** supported — its Podman is too old for the Quadlet features we use. The installer aborts on bookworm with a recipe to upgrade to trixie.

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

The installer:

1. Detects host (OS, arch, distro family) and runs pre-flight: RAM ≥ 2 GB, disk ≥ 5 GB, the signalk-server ports (80 + 443, or 3000 + 3443 if you decline standard ports) and 3003 / 3004 / 3010 free, cgroups v2 with memory + pids delegation to the user slice (autofixed when possible), Podman ≥ 4.4.
2. Installs Podman + `uidmap` + `slirp4netns` via `apt` if missing.
3. Enables `loginctl enable-linger $USER` so the stack survives reboots.
4. Adds you to `dialout`, `gpio`, `netdev` groups for USB serial / GPIO / CAN. Group memberships only take effect on a new login session, so on a `curl … | bash` first run you'll see a hint to log out and back in.
5. Generates bearer-auth tokens at `~/.signalk-updater/token` and `~/.signalk-doctor/token` (mode 0600). Idempotent: never overwrites existing tokens.
6. Initialises the doctor's state directory (`~/.signalk-doctor/snapshots/`, `last-good.json`) and generates an admin signalk-token at `~/.signalk-doctor/signalk-token` (mode 0600) via `podman exec signalk-server signalk-generate-token` so the doctor's drift scanner can read the admin-gated `/skServer/diagnostics` endpoint.
7. Detects USB serial / SocketCAN / Bluetooth-DBus / Pi GPIO into `~/.signalk-updater/hardware.json`.
8. Pulls the three container images (multi-arch: amd64 + arm64).
9. Atomically writes three Quadlets into `~/.config/containers/systemd/` (see [Quadlet layout](#quadlet-layout) below).
10. `systemctl --user daemon-reload`, then starts (or restarts, on re-run) the doctor and updater services and asks the updater to start signalk-server via its REST API. Falls back to a direct `systemctl --user start` if the updater is unreachable, with a short warm-up retry to absorb a daemon-reload's transient socket downtime.
11. Installs and auto-enables the bundled SignalK plugins (`signalk-container`, `signalk-updater`, `signalk-doctor`) into `~/.signalk/node_modules/` via the signalk-server container's bundled npm. Plugin config files are written **only** if absent — re-running the installer never overrides a user-disabled plugin.
12. Installs the SSH-only recovery script at `~/.local/bin/signalk-recovery` (the safety net for when both engine containers are down).
13. Installs the `signalk` command at `~/.local/bin/signalk` — a dispatcher for `health`, `recover`, `update`, `bug-report`, and `uninstall`. Run `signalk help` for usage. (`signalk update` calls the doctor's `/api/installer/refresh` endpoint to rewrite the host-resident scripts and Quadlet templates without restarting containers.) The installer also persists `~/.local/bin` on your PATH if it isn't already.
14. Drops a journald retention drop-in at `/etc/systemd/journald.conf.d/signalk.conf` (`SystemMaxUse=500M`, `MaxRetentionSec=14day`) via `sudo`. Idempotent: skipped silently if the drop-in already exists. On Pi this prevents the SD card from filling.
15. Marks bootstrap-complete in `~/.signalk-doctor/last-good.json` so the doctor knows the install was validated end-to-end. Re-runs check this marker and switch to a "verify mode" summary instead of repeating the full install.

When it finishes you have three URLs: `:80` (SignalK — `:3000` if you declined standard ports), `:3003` (Updater Console), `:3004` (Doctor Console). The installer binds the engine containers to `0.0.0.0` by default because most users install headless and reach the consoles from another machine. The updater's mutating endpoints and the doctor's `/api/recover` are gated by bearer tokens (see `~/.signalk-{updater,doctor}/token`); the doctor's read-only probes are unauthenticated by design (recovery surface that always answers). To restrict everything to localhost set `SIGNALK_LOCALHOST_ONLY=true` before running the installer — useful on shared/guest WiFi where you'd rather not expose probe output.

### Quadlet layout

The installer drops three Quadlet files under `~/.config/containers/systemd/`. Key bits, beyond the obvious `Image=` and `ContainerName=`:

| Quadlet | Notable settings |
|---|---|
| `signalk-server.container` | `Network=host` so signalk-server listens directly on the host's HTTP port (`:80` by default, `:3000` if you declined standard ports); `Environment=PORT=` carries that choice; `UserNS=keep-id` so the in-container `node` user maps to the host user and `~/.signalk/` stays writable; `Restart=always` because the SignalK admin UI's "Restart" button does a clean `process.exit(0)` that `on-failure` wouldn't recover from; `StopTimeout=5` cuts podman's SIGTERM → SIGKILL grace from the default 10s to 5s (signalk-server doesn't trap SIGTERM upstream, so the full grace is dead time on every version switch). |
| `signalk-updater-server.container` | Pasta networking with `PublishPort=…:3003:3003`; mounts `~/.signalk-updater`, `~/.signalk-doctor`, the Quadlet dir, the podman socket, and the host DBus session bus; pins `Environment=SIGNALK_HEALTH_URL`, `SIGNALK_URL`, `DOCTOR_HEALTH_URL` to `host.containers.internal` (with the chosen HTTP port substituted in) so the updater can reach signalk-server and the doctor (`:3004`) across pasta's network boundary (`127.0.0.1` from inside this container would be its own loopback). |
| `signalk-doctor-server.container` | Same shape as the updater; mounts `~/.signalk-doctor` rw, `~/.signalk-updater` rw for the shared operation-lock, and `~/.local/bin` rw so the doctor's `/api/installer/refresh` can rewrite the host `signalk` / `signalk-recovery` scripts. |

The updater rewrites `signalk-server.container`'s `Image=` line on each version switch (atomically — snapshot first, then rename + dir-fsync). Everything else in the Quadlet, including the env vars above and `StopTimeout`, is preserved verbatim.

### Standard web ports (80 / 443)

By default the installer puts signalk-server on the standard web ports — **HTTP `:80`**, and **HTTPS `:443`** once you enable TLS (e.g. with the [signalk-ssl](https://github.com/dirkwa/signalk-ssl) plugin). The interactive installer asks `Use standard web ports? [Y/n]`; a piped `curl … | bash` run takes the default (yes). Decline, and signalk-server stays on the historical `:3000` / `:3443`.

Making a privileged port (< 1024) bind from a rootless, non-root container is **not** a Quadlet capability question. `Network=host` means the container shares the host's network namespace, and the `node` process is non-root — so `AddCapability=CAP_NET_BIND_SERVICE` lands in the bounding set but never becomes *effective* for the process, and a network sysctl can't be set from inside a host-netns container. The only lever that works is the **host's** `net.ipv4.ip_unprivileged_port_start`. When you accept standard ports, the installer lowers it to `80` via a persistent drop-in at `/etc/sysctl.d/80-signalk-unprivileged-ports.conf` (requires sudo). This is a **host-wide** change: any unprivileged process on the box may then bind ports 80–1023.

Mechanics:

- **HTTP** is set with `Environment=PORT=80` in the server Quadlet (signalk-server reads `PORT` ahead of `settings.json`).
- **HTTPS** is seeded as `sslport: 443` in `~/.signalk/settings.json` — *not* via the `SSLPORT` env var, because that would force `ssl: true` and make signalk-server serve a self-signed cert before you've set up a real one. The seed is written only if `sslport` is absent (your value is never overwritten) and only takes effect once you enable SSL.
- Binding `:443` does **not** free `:80`; signalk-server's plain-HTTP listener and its HTTP→HTTPS redirect stay on the configured HTTP port.

To stay on the old ports on a one-liner install, set `SIGNALK_PRIVILEGED_PORTS=0` in the environment; to force standard ports without the prompt (CI/unattended), set `SIGNALK_PRIVILEGED_PORTS=1`.

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

Then in WSL, the device shows up as `/dev/ttyUSB0` etc. Re-run the bash installer inside WSL to re-detect hardware and rewrite the signalk-server Quadlet's `AddDevice=` lines. (The Updater Console has no Hardware tab — see [docs/hardware.md](hardware.md) for the supported re-detection paths.)

## Recovery

If the install completes but something doesn't work, see [docs/recovery.md](recovery.md) for the full playbook. The short version, ordered by ease of use:

1. **Updater Console** at `http://localhost:3003` — Versions tab, "Roll back to previous version."
2. **Doctor Console** at `http://localhost:3004` — Recover tab, "Recover" button that restores Quadlets from the last-known-good snapshot.
3. **`~/.local/bin/signalk-recovery`** — pure bash, zero container dependencies. Works from SSH even if both engine containers are dead.
