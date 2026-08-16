# Installation

## Linux (Debian 13 / trixie, Raspberry Pi OS trixie+, Ubuntu/Kubuntu 25.04+)

> The installer needs Podman ≥ 5.3 (for the `[Quadlet] DefaultDependencies=false` key the engine units rely on). The tested targets all clear that floor from their own archives: Debian 13 / Raspberry Pi OS trixie (Podman 5.4.x) and Ubuntu/Kubuntu 25.04 (5.4.1) / 25.10 (5.4.2) / 26.04 (5.7.0). All Ubuntu flavours (Kubuntu, Xubuntu, …) share `ID=ubuntu`, so they're all covered.
>
> The distro allowlist (`is_supported_distro`) is only a soft pre-check that decides whether you see an "untested, continuing" warning; the hard backstop is the Podman ≥ 5.3 version gate in `install.sh`, which aborts after `apt` if the archive Podman is too old.
>
> Debian 12 (bookworm) is **not** supported — its Podman is too old. Bookworm gets an explicit, step-by-step upgrade-to-trixie recipe and aborts before `apt` runs. The EOL Ubuntu 24.x line is likewise too old (24.10 ships Podman 5.0.3, 24.04 ships 4.9.3 — both below 5.3): it isn't special-cased, so it falls to the post-install Podman ≥ 5.3 version gate in `install.sh`, which aborts with a "Podman too old, install ≥ 5.3" message rather than a tailored upgrade recipe.

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

The installer:

1. Detects host (OS, arch, distro family) and runs pre-flight: RAM ≥ 2 GB, disk ≥ 5 GB, the signalk-server ports (80 + 443, or 3000 + 3443 if you decline standard ports) and 3003 / 3004 free, cgroups v2 with memory + pids delegation to the user slice (autofixed when possible), Podman ≥ 5.3.

   On small-RAM hosts preflight also prints an **informational heads-up** — non-blocking, not a warning — if `/tmp` is on tmpfs, the Debian 13 / trixie default: a RAM-backed `/tmp` shares memory with the containers, so if something fills it the box has less RAM for the stack. No one has reported this biting in practice; it's just a "you might want to know." If you'd rather cap it, the note suggests **shrinking the tmpfs cap** via a `tmp.mount.d` drop-in — this keeps `/tmp` in RAM (no extra SSD/SD-card write wear, unlike moving it to disk) while bounding how much RAM a runaway `/tmp` can take, and prints the exact `sudo` commands. The RAM threshold below which it shows the note, and the suggested cap percentage, are `TMPFS_WARN_MAX_RAM_MB` and `TMPFS_RECOMMEND_PCT` (see their definitions in `installer/linux/preflight.sh` for the current defaults).

   Before preflight, the installer also asks for the **vessel identity** — boat name, MMSI (9 digits), VHF call sign. Every field is optional (Enter skips). The answers are seeded into `~/.signalk/baseDeltas.json` just before signalk-server's first start, so the admin UI's Server → Settings page comes up pre-filled. With an MMSI the vessel's self identity becomes `urn:mrn:imo:mmsi:…`; without one the installer mints a `urn:mrn:signalk:uuid:…` identity instead (the server only auto-generates a UUID when `baseDeltas.json` is absent entirely). For unattended runs set `SIGNALK_VESSEL_NAME`, `SIGNALK_VESSEL_MMSI`, `SIGNALK_VESSEL_CALLSIGN` in the environment (any non-empty value suppresses the prompts); with no TTY and no non-empty env values the step is skipped. The seed is written only when the data dir has no vessel identity yet (no `baseDeltas.json`, no legacy `defaults.json`) — re-runs never prompt again and never overwrite what you changed in the admin UI.

   It also asks for an **admin login** — username (default `admin`) and a password typed twice. This is seeded into `~/.signalk/security.json` (a bcrypt hash, computed inside the signalk-server image with the server's own `bcryptjs`, plus a stable `secretKey`) and `settings.json`'s `security.strategy` **before** the first start, so signalk-server comes up already secured and never shows its "create an account" screen to whoever reaches the LAN first. Read access requires login too (`allow_readonly` is `false`). The password is read without echo and piped to the hashing step — it never appears on a command line or in `~/.signalk-updater/install.log`. For unattended runs set `SIGNALK_ADMIN_USER` and `SIGNALK_ADMIN_PASSWORD` (the password is forwarded into the `curl … | bash` re-exec by inheritance, kept off every command line). With no TTY and no `SIGNALK_ADMIN_PASSWORD`, the install proceeds **unsecured** with a loud warning rather than failing — secure it from the admin UI, or re-run with the env vars set. Skipped (no prompt, credentials untouched) when `~/.signalk/security.json` already has users. Lost the password later? `signalk resetadmin` resets it in place, preserving the `secretKey` so existing tokens stay valid.
2. Installs Podman + `passt` + `uidmap` + `slirp4netns` via `apt` if missing (and ensures `passt` separately on hosts that came with Podman preinstalled — Armbian ships APT recommends off, leaving pasta-networked containers unable to start).
3. Enables `loginctl enable-linger $USER` so the stack survives reboots.
4. Adds you to `dialout`, `gpio`, `netdev`, `audio` groups for USB serial / GPIO / CAN / ALSA. Group memberships only take effect on a new login session, so on a `curl … | bash` first run you'll see a hint to log out and back in.
5. Generates bearer-auth tokens at `~/.signalk-updater/token` and `~/.signalk-doctor/token` (mode 0600). Idempotent: never overwrites existing tokens.
6. Initialises the doctor's state directory (`~/.signalk-doctor/snapshots/`, `last-good.json`) and generates an admin signalk-token at `~/.signalk-doctor/signalk-token` (mode 0600) via `podman exec signalk-server signalk-generate-token` (for the admin user created above) so the doctor's drift scanner can read the admin-gated `/skServer/diagnostics` endpoint. With the security seed in step 1 this now succeeds on the first install instead of waiting for security to be enabled by hand.
7. Detects USB serial / SocketCAN / Bluetooth-DBus / Pi GPIO into `~/.signalk-updater/hardware.json`.
8. Pulls the three core container images (multi-arch: amd64 + arm64). The optional D-Bus proxy sidecar image is pulled on first start of its unit.
9. Atomically writes the three core Quadlets — plus `signalk-dbus-proxy.container` on hosts with a system D-Bus — into `~/.config/containers/systemd/` (see [Quadlet layout](#quadlet-layout) below).
10. `systemctl --user daemon-reload`, then starts (or restarts, on re-run) the doctor and updater services and asks the updater to start signalk-server via its REST API. Falls back to a direct `systemctl --user start` if the updater is unreachable, with a short warm-up retry to absorb a daemon-reload's transient socket downtime.
11. Installs and auto-enables the bundled SignalK plugins (`signalk-container`, `signalk-updater`, `signalk-doctor`) into `~/.signalk/node_modules/` via the signalk-server container's bundled npm. Plugin config files are written **only** if absent — re-running the installer never overrides a user-disabled plugin.
12. Installs the SSH-only recovery script at `~/.local/bin/signalk-recovery` (the safety net for when both engine containers are down).
13. Installs the `signalk` command at `~/.local/bin/signalk` — a dispatcher for `health`, `recover`, `socketcan`, `bluetooth`, `timesync`, `update`, `hardware`, `render-server`, `resolv-watch`, `netgate-watch`, `resetadmin`, `bug-report`, `stop`, `start`, `restart`, `devpod`, and `uninstall`. Run `signalk help` for usage. (`signalk update` calls the doctor's `/api/installer/refresh` endpoint to rewrite the host-resident scripts and Quadlet templates. The refresh itself restarts nothing, but `update` then re-renders the live server Quadlet from the refreshed template, which restarts `signalk-server` if that changed anything — pass `--no-render` to skip it.) The installer also persists `~/.local/bin` on your PATH if it isn't already.

    The installer tees its own console output to `~/.signalk-updater/install.log` (truncated at the start of each run), and `signalk bug-report` copies that file into its bundle. So a failed install — including a pre-container failure where no container ever started to log to journald — leaves an on-disk trace you can attach to an issue. Set `SIGNALK_NO_INSTALL_LOG=1` to skip it (e.g. a read-only home).
14. Installs the `signalk-timesync` host agent (root-owned script + systemd system timer, every 5 minutes): steps the host clock from SignalK's GPS `navigation.datetime` **only when the host has no NTP sync** (offline passages, RTC-less cold boot — an in-container plugin can never do this: `CLOCK_REALTIME` needs `CAP_SYS_TIME` in the initial user namespace), and follows the GPS position's IANA timezone via `tz-lookup` (installed into `~/.signalk/node_modules`; the lookup runs inside the container, the root-side `timedatectl` applies it — no polkit rule needed). NTP-synchronized boats are left alone. Opt out via `/etc/default/signalk-timesync` (`SIGNALK_TIMESYNC=off`, or `SIGNALK_TIMESYNC_TZ=off` for clock-only). `signalk timesync status` shows timer state and recent decisions.

    A zone change that happens **while the stack is running** (crossing a boundary mid-passage) reaches the host but not an already-running `signalk-server` — its `/etc/localtime` is frozen at container-create by `Timezone=local`, and long-running Node/JVM/Go processes cache the zone at startup, so only a **recreate** picks up a new zone. Recreating `signalk-server` (via the updater's lifecycle API) re-runs `Timezone=local` and, through signalk-container's TZ propagation, updates the peer containers it manages (questdb, grafana, Node-RED); the updater and doctor containers keep their own zone until they are themselves recreated. This is **off by default** (a restart briefly drops WebSocket clients and costs a short outage). To have the agent do it automatically on a GPS-driven zone change, opt in via `/etc/default/signalk-timesync` (see `signalk timesync help` for the flag) or run a pass with `signalk timesync run --confirm-restart` (crontab-friendly). Without opt-in the agent still updates the host zone and logs that the container picks it up on its next restart. The Doctor Console also detects this host↔container zone drift and offers a one-click restart.
15. Drops a journald retention drop-in at `/etc/systemd/journald.conf.d/signalk.conf` (`SystemMaxUse=500M`, `MaxRetentionSec=14day`) via `sudo`. Idempotent: skipped silently if the drop-in already exists. On Pi this prevents the SD card from filling.
16. Marks bootstrap-complete in `~/.signalk-doctor/last-good.json` so the doctor knows the install was validated end-to-end. Re-runs check this marker and switch to a "verify mode" summary instead of repeating the full install.

When it finishes you have three URLs: `:80` (SignalK — `:3000` if you declined standard ports), `:3003` (Updater Console), `:3004` (Doctor Console). The installer binds the engine containers to `0.0.0.0` by default because most users install headless and reach the consoles from another machine. The updater's mutating endpoints and the doctor's `/api/recover` are gated by bearer tokens (see `~/.signalk-{updater,doctor}/token`); the doctor's read-only probes are unauthenticated by design (recovery surface that always answers). To restrict everything to localhost set `SIGNALK_LOCALHOST_ONLY=true` before running the installer — useful on shared/guest WiFi where you'd rather not expose probe output.

### Quadlet layout

The installer drops three core Quadlet files — four on hosts with a system D-Bus socket — under `~/.config/containers/systemd/`. Key bits, beyond the obvious `Image=` and `ContainerName=`:

| Quadlet | Notable settings |
|---|---|
| `signalk-server.container` | `Network=host` so signalk-server listens directly on the host's HTTP port (`:80` by default, `:3000` if you declined standard ports); `Environment=PORT=` carries that choice; `UserNS=keep-id:uid=1000,gid=1000` so the invoking host user maps to the in-container `node` user (uid 1000) regardless of the host uid and `~/.signalk/` stays writable; `Restart=always` because the SignalK admin UI's "Restart" button does a clean `process.exit(0)` that `on-failure` wouldn't recover from; `StopTimeout=5` cuts podman's SIGTERM → SIGKILL grace from the default 10s to 5s (signalk-server doesn't trap SIGTERM upstream, so the full grace is dead time on every version switch). |
| `signalk-updater-server.container` | Pasta networking with `PublishPort=…:3003:3003`; mounts `~/.signalk-updater`, `~/.signalk-doctor`, the Quadlet dir, the podman socket, and the host DBus session bus; pins `Environment=SIGNALK_HEALTH_URL`, `SIGNALK_URL`, `DOCTOR_HEALTH_URL` to `host.containers.internal` (with the chosen HTTP port substituted in) so the updater can reach signalk-server and the doctor (`:3004`) across pasta's network boundary (`127.0.0.1` from inside this container would be its own loopback). |
| `signalk-doctor-server.container` | Same shape as the updater; mounts `~/.signalk-doctor` rw, `~/.signalk-updater` rw for the shared operation-lock, and `~/.local/bin` rw so the doctor's `/api/installer/refresh` can rewrite the host `signalk` / `signalk-recovery` scripts. |
| `signalk-dbus-proxy.container` | Written only on hosts with a system D-Bus socket. Runs [dbus-auth-proxy](https://github.com/yichenshen/dbus-auth-proxy) under bare `UserNS=keep-id` and publishes a rewritten `system_bus_socket` into the named volume `signalk-dbus-socket`, which `signalk-server` mounts at `/run/dbus` when bluetooth passthrough is enabled (`signalk bluetooth enable`). Exists because a direct `/run/dbus` bind mount cannot pass D-Bus `AUTH EXTERNAL` from a rootless container on hosts where the user isn't uid 1000 — see [docs/hardware.md](hardware.md#bluetooth--ble-passthrough). |

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

### Pausing the stack (`signalk stop` / `signalk start`)

To stop SignalK for a while **without uninstalling** — preserving all data, config, and plugins — use `signalk stop`, not `uninstall`. It stops `signalk-server` (the heavy data plane) and keeps it **down across reboots**; the lightweight updater and doctor consoles stay up so you can bring it back. `signalk start` resumes it and re-arms start-at-boot.

The durable part (staying down across a reboot) is owned by the updater: `signalk stop` asks it to persist signalk-server's boot state, and `signalk start` restores it. The `signalk` CLI never changes that boot state itself. Because of this, durable pause needs a recent updater — if yours predates it, `signalk stop` will say so and ask you to update the updater first (Updater console → Dashboard → Self-update) rather than do a stop that silently comes back at the next boot. (If the updater is unreachable, `signalk stop` falls back to a plain stop and tells you it may not survive a reboot.)

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

## Windows (Podman Machine)

**Requires Windows 11** (or Server 2022) with WSL2 and hardware virtualization. The stack runs inside a Podman Machine VM — the same model as macOS — not a user-managed Linux distro.

Open PowerShell **as administrator**:

```powershell
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex
```

The WSL2 platform step downloads the WSL kernel from the Microsoft Store and can sit for **several minutes with little or no output** — that is normal, not a hang; don't close the window.

**To capture a log** (recommended, especially if a run closed its window before you could read it — the installer exits the window for the reboot, and `iwr … | iex` closes with it), wrap it in a transcript:

```powershell
Start-Transcript -Path "$env:USERPROFILE\Desktop\signalk-install.log"
try { iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 | iex }
finally { Stop-Transcript; Read-Host 'Press Enter to close' }
```

The transcript on your Desktop survives the window closing and the reboot exit, and the `Read-Host` keeps the window open so you can read the result. Attach `signalk-install.log` if you report a problem.

**Release channel.** The one-liner installs the latest release. To track `master` instead, pass `-Channel master` — which means downloading the script rather than piping it, because `iex` has nowhere to put parameters:

```powershell
iwr -useb https://dirkwa.github.io/signalk-universal-installer/dev/installer/windows/install.ps1 -OutFile install.ps1
.\install.ps1 -Channel master
```

The `signalk` command remembers the channel it was installed from, so `signalk update` on a master box stays on master rather than silently reverting to release. Set `$env:SIGNALK_CHANNEL` to override a single run, or pass `-InstallerBaseUrl` to point at a mirror or local checkout (an explicit base URL wins over the channel).

The Windows installer:

1. Checks for Administrator and Windows 11.
2. Installs the WSL2 platform with `wsl --install --no-distribution` (no user-facing distro, no OOBE prompt).
3. Installs the Podman CLI via `winget install RedHat.Podman`.
4. Enables **mirrored networking** (`networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`) and adds a `localhost`→IPv4 rule to `%USERPROFILE%\.ssh\config` (see "Headless / always-on" below). Both are merged into existing files, never clobbered.
5. Runs `podman machine init` / `podman machine start`, which creates and owns its own Linux VM (already has systemd + rootless podman set up).
6. Hands off to the Linux installer inside the machine via `podman machine ssh`.
7. Registers a boot **Scheduled Task** that starts the machine after a Windows restart (see below).

**Expect one reboot on a fresh machine — this is normal, not an error.** Enabling WSL2 turns on a Windows feature (VirtualMachinePlatform) that only activates after a restart. The installer enables WSL2 up front, then tells you to reboot and re-run; it is idempotent, so re-running after the reboot picks up where it left off and continues to Podman. (Doing this up front avoids a confusing mid-install failure where Podman would otherwise enable the feature itself and fail to create the VM before the reboot.)

Result: the same container stack as Linux. With mirrored networking the Podman Machine VM shares the Windows host's LAN IP, so you reach the stack from **any device** at `http://<windows-host-ip>` — admin UI (`:3000` if you decline standard ports), `:3003` (Updater), `:3004` (Doctor). The installer prints the exact address at the end. **Note:** under mirrored mode `http://localhost` on the Windows box itself does **not** reach the stack — mirrored networking replaces the NAT localhost-forward, so always use the host's LAN IP (even from the same PC).

### Headless / always-on (boat PC)

A boat PC should power on and serve the stack with **no one logged in**. That works, but it leans on four Windows-specific pieces the installer sets up — worth understanding:

- **Boot Scheduled Task.** A Podman machine does not start when Windows boots. The installer registers a task (`SignalK Podman Machine (signalk)`) that runs `podman machine start signalk` **at startup, with nobody signed in** — using an **S4U** ("run whether logged on or not", *do not store password*) principal. No password is stored and no prompt is needed; it works for any account, including one **linked to a Microsoft account** (the common default), because S4U logs the task in without a password. It can't be a Windows *service*: the machine is a per-user WSL2 distro and WSL2 only starts from a user session, which `LocalSystem`/session-0 services don't have — but an S4U startup task running *as your user* does, even with no interactive sign-in. The task runs as the installing user, so the per-user machine it starts is the right one (and `signalk` keeps working in that user's normal session). systemd inside the VM then starts the containers.
- **Mirrored networking.** Without it, the VM sits behind a private NAT address with no inbound path, so other devices can't reach it. Mirrored mode gives the VM the host's LAN IP. (Trade-off: under mirrored mode `podman machine start` prints a harmless `could not start api proxy … expected pipe is not available` line — that's the Docker-API named pipe, which the stack doesn't use; and `localhost` on the host no longer reaches the stack — use the LAN IP.)
- **Firewall rules.** The installer opens inbound TCP for the stack's ports (80/443/3000/3443/3003/3004). Under mirrored mode inbound LAN traffic hits the Windows host firewall first (default-block), so without these rules other devices can't connect (and you'd have to disable the firewall entirely).
- **`localhost`→IPv4 in `~/.ssh/config`.** podman runs `ssh user@localhost`; Windows resolves `localhost` to IPv6 `::1` first, but the VM's SSH forward is IPv4-only, so each `podman machine ssh` would stall ~21 s on an IPv6 timeout before falling back. The `Host localhost` / `AddressFamily inet` rule forces IPv4 and keeps the `signalk` CLI fast.

After a reboot — **with no one signed in** — give the machine ~30–60 s, then the stack is reachable at `http://<windows-host-ip>` from any device.

The installer also drops a `signalk` command on your PATH (open a **new** terminal to use it) that forwards into the machine, so `signalk health`, `signalk version`, etc. work the same as on Linux. Several subcommands get Windows-aware handling because they can't run unchanged inside the VM:

- `signalk resetadmin [user]` — prompts for the new password **on Windows** (the VM has no terminal to prompt on) and applies it inside the machine.
- `signalk bug-report` — generates the bundle inside the machine and copies the resulting `.tar.gz` out to your **Desktop**, so you have a file you can actually attach to an issue.
- `signalk machine stop` / `signalk machine start` — Windows-only, one level **above** `signalk stop`: stops the Podman machine itself (the whole VM goes down and frees RAM, consoles included) and disables the boot task so a restart won't bring it back. `machine start` reverses both. Nothing is removed.
- `signalk uninstall` — removes the stack inside the machine, then offers to remove the Podman machine itself (and with it **all** SignalK data — on Windows there is no `~/.signalk*` on the host; everything lives in the VM) plus the `signalk` command and its PATH entry.

`signalk stop`, `start` and `restart` are **not** Windows-specific — they run inside the machine and mean exactly what they mean on Linux: `stop` pauses signalk-server (the data plane) and durably keeps it down across reboots, while the Updater (`:3003`) and Doctor (`:3004`) consoles **stay reachable** so you can still diagnose and recover. `restart` bounces signalk-server to pick up config changes without touching boot behaviour.

So there are two levels of "off", and which you want depends on why:

| Goal | Command | Consoles |
|---|---|---|
| Pause the nav server, keep diagnosing | `signalk stop` | up |
| Free the VM's RAM / lay the boat up | `signalk machine stop` | down |

To **pause** SignalK for later (the common "I don't need it running right now" case), use `signalk stop` — not `uninstall`. Resume with `signalk start`, or just re-run the installer (it resumes a stopped stack).

> **Changed in this release.** `signalk stop` / `start` on Windows previously stopped and started the whole Podman machine. They now match Linux and act on signalk-server only; the old behaviour moved to `signalk machine stop` / `signalk machine start`. The previous form took the Doctor console down together with the server — removing the recovery surface at exactly the moment you might need it.

### Windows troubleshooting

- **`podman machine init`/`start` fails / "virtualization not enabled" / `HCS_E_HYPERV_NOT_INSTALLED`** — the Windows hypervisor can't create the VM. If this is a guest VM, enable **nested virtualization** on the host (the VM must be powered off): Hyper-V `Set-VMProcessor -VMName <VM> -ExposeVirtualizationExtensions $true`; VMware "Virtualize Intel VT-x/EPT or AMD-V/RVI"; Proxmox/KVM CPU type `host` + nested KVM. On bare metal, enable VT-x/AMD-V in BIOS/UEFI. Confirm with `(Get-CimInstance Win32_ComputerSystem).HypervisorPresent` (want `True`). See <https://aka.ms/enablevirtualization>.
- **WSL won't start after the reboot** — confirm hardware virtualization is enabled in BIOS/UEFI.
- **"Podman isn't on PATH"** — open a new Administrator PowerShell after the winget install and re-run.
- Reset the machine if needed: `podman machine stop signalk; podman machine rm signalk` then re-run. **Note:** unlike Linux/macOS, on Windows your SignalK data lives **inside** the machine, so removing it discards all configs, plugins, and tokens — back up anything you need first. Run the backup through `cmd /c` so the redirect goes through the native shell, not PowerShell's pipeline (PowerShell before 7.4 transcodes a `>`-redirected byte stream and corrupts the `.tgz`): `cmd /c "podman machine ssh signalk -- tar czf - .signalk > backup.tgz"`. `signalk uninstall` does this teardown for you, with a confirmation prompt.

### Windows NMEA over the network (UDP)

If a gateway streams NMEA **into** the boat PC over UDP — a Yacht Devices or Actisense unit on `2000`, an NMEA-0183 feed on `10110` — open those ports at install time with `-NmeaUdpPorts`.

The quick-start one-liner pipes the script straight to `iex`, which has nowhere to put parameters, so download it first:

```powershell
iwr -useb https://dirkwa.github.io/signalk-universal-installer/installer/windows/install.ps1 -OutFile install.ps1
.\install.ps1 -NmeaUdpPorts 2000,10110
```

Either firewall layer can drop the feed, so both have to allow the port. Windows filters traffic to WSL at **two independent layers** — the ordinary Windows firewall, and a separate **Hyper-V firewall** between the host and the VM. The Hyper-V layer drops **silently**: the packets are visible in Wireshark on Windows and simply never arrive inside the machine, with nothing logged anywhere. `-NmeaUdpPorts` opens both.

This is also why "multicast doesn't work in WSL" is a common and wrong conclusion. Windows preinstalls an allow rule for UDP 5353, so mDNS works out of the box while the *same* multicast group on any other port receives nothing — the port was never allowed, and nothing said so.

The installer opens **inbound TCP** on the console ports only (`80`, `443`, `3000`, `3443`, `3003`, `3004`), at both layers, with no flag needed. It does not open arbitrary TCP ports: a TCP or UDP connection the server makes *outbound* — SignalK dialling a gateway rather than receiving a stream — needs no rule in either layer, because the reply arrives on an established connection. Only unsolicited **inbound** traffic on a non-console port needs `-NmeaUdpPorts`. On Windows 10 and pre-22H2 Windows 11 there is no Hyper-V firewall layer to program, and none filtering either.

### Reaching SignalK's files from Windows

The stack's data lives inside the machine, but Windows Explorer can open it directly. The machine is a WSL distro, and `wsl --list` shows every distro on the box — including any unrelated Ubuntu or Debian you may have. The SignalK one is the `podman-` entry matching your machine name (`podman-signalk` for the default install):

```powershell
podman machine list         # the machine name, e.g. signalk
wsl --list --quiet          # the distro: that name with a podman- prefix
```

Then paste the path into Explorer's address bar, substituting that name:

```text
\\wsl.localhost\<distro>\home\user\.signalk
```

Inside `.signalk\`, `plugin-config-data\` holds the per-plugin JSON. The updater's and doctor's own state live one level up, in `.signalk-updater\` and `.signalk-doctor\` next to `.signalk\` rather than inside it. Files copy in and out like any network share. To put it on a drive letter:

```powershell
net use Z: \\wsl.localhost\<distro>\home\user /persistent:yes
```

`/persistent:yes` makes Windows *remember* the mapping, not keep it live: `\\wsl.localhost` only answers while the machine is running, so after a reboot `Z:` shows as disconnected until the machine starts and you open the drive again.

For a support bundle, prefer `signalk bug-report` — it collects logs and config inside the machine and drops the `.tar.gz` on your **Desktop**.

### Windows USB serial

Podman Machine's VM doesn't expose USB devices by default. Use [usbipd-win](https://github.com/dorssel/usbipd-win) to attach a USB-serial device to the WSL2 backend the machine runs on:

```powershell
winget install --id dorssel.usbipd-win
usbipd list                             # find the BUSID of your gateway
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>     # while the machine is running
```

The device then shows up as `/dev/ttyUSB0` etc. inside the machine. Run `signalk hardware rescan` to re-detect and rewrite the signalk-server Quadlet's `AddDevice=` lines (re-running the installer also works, but re-pulls every image). (The Updater Console has no Hardware tab — see [docs/hardware.md](hardware.md) for the supported re-detection paths.)

## Recovery

If the install completes but something doesn't work, see [docs/recovery.md](recovery.md) for the full playbook. The short version, ordered by ease of use:

1. **Updater Console** at `http://localhost:3003` — Versions tab, "Roll back to previous version."
2. **Doctor Console** at `http://localhost:3004` — Recover tab, "Recover" button that restores Quadlets from the last-known-good snapshot.
3. **`~/.local/bin/signalk-recovery`** — pure bash, zero container dependencies. Works from SSH even if both engine containers are dead.
