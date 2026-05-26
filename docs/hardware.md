# Hardware passthrough

The installer detects host hardware at install time and passes it through to the `signalk-server` container via Quadlet `AddDevice=` and `Volume=` lines. The detection runs in `installer/linux/detect-hardware.sh` and the result is persisted to `~/.signalk-updater/hardware.json`.

## What's detected

| Class | Source | Default | Persisted as |
|---|---|---|---|
| **USB serial** | Every entry under `/dev/serial/by-id/*` (stable across renumbering) | **Enabled** — most boats want USB-serial gateways (NMEA0183, NMEA2000 via Actisense / Yacht Devices / iKommunicate) reachable from signalk-server | `{ byId, vendor, product, enabled }` per device |
| **SocketCAN** | `ip -o link show type can` (every `can*` netlink interface) | Disabled (requires explicit opt-in) — CAN interfaces can be physical (NGT-1 plugged in over USB-CAN) or virtual (`vcan0` for testing) and surfacing them all by default is noisy | `{ interface, type: "socketcan", enabled }` per interface |
| **Bluetooth (DBus)** | Presence of `/run/dbus/system_bus_socket` | Disabled — BLE on linux requires shared host DBus and not every install needs it | `{ enabled, dbusAvailable }` (no per-device list; toggle adds a single DBus passthrough) |
| **Raspberry Pi GPIO** | `/proc/device-tree/model` matched against `Pi[ ]*[3-5]` | Disabled (opt-in) — only meaningful on Pi hosts | `{ enabled, platform: "rpi5"\|"rpi4"\|"rpi3"\|"rpi-other"\|"none" }` |

For each enabled entry the renderer (`render-server-quadlet.sh`) emits an `AddDevice=` line (USB serial, CAN) or a `Volume=` line (DBus, GPIO) inside a managed `# === BEGIN HARDWARE / END HARDWARE ===` block in `signalk-server.container`. Anything outside that block — including the separate `# === BEGIN USER ADDITIONS ===` block — is preserved verbatim across re-detects and version switches.

## Group memberships

Rootless Podman needs the calling user in the right Unix groups to forward devices into the container without `--privileged`:

| Group | Required for |
|---|---|
| `dialout` | USB serial (`/dev/ttyUSB*`, `/dev/serial/by-id/*`) |
| `gpio` | Raspberry Pi GPIO (`/dev/gpiomem`) |
| `netdev` | SocketCAN (`vcan` setup, `ip` administration) |

The installer adds you to all three at step 5 of `install.sh`. Group changes only take effect on a new login session, so on a `curl … | bash` first run you'll see a hint to log out and back in.

## Re-running detection

Hardware changes (plugging in a new USB gateway, adding a CAN interface) require re-running detection so the Quadlet picks them up. Two paths:

1. **Re-run the bash installer.** `curl … | bash` is idempotent; it re-runs `detect-hardware.sh`, the result feeds into a Quadlet rewrite via `render-server-quadlet.sh`, and `systemctl --user daemon-reload` + `restart signalk-server.service` picks up the new `AddDevice=` lines.
2. **The Updater Console's Hardware tab** — planned, not yet implemented. The REST endpoint `POST /api/hardware/apply` exists and is tested; the in-browser UI for toggling individual devices on/off is a deferred Roadmap item.

The `hardware.json` file is the source of truth — if you want to disable a USB-serial device you'd otherwise pass through, edit the `enabled` field directly and re-run `render-server-quadlet.sh` (or trigger `/api/hardware/apply` with the new payload).

## Platform notes

### Raspberry Pi (3 / 4 / 5)

Detected automatically via `/proc/device-tree/model`. On the Pi the installer also nudges cgroup memory + pids delegation onto the user slice (some Pi-OS images ship without the right `Delegate=` set on `user@.service`), so engine containers can apply memory limits.

GPIO passthrough mounts `/dev/gpiomem` only — not `/dev/mem`. Plugins that need the full memory map for low-level peripherals won't work in this configuration; they'd need to run on the host, not in the container.

### macOS (Apple Silicon and Intel)

USB serial is supported **only** when the Podman Machine is created with `--usb`. See [docs/installation.md](installation.md#macos-usb-serial) for the recreate recipe.

CAN, Bluetooth, and GPIO are **not** supported on macOS Podman Machine — there's no host CAN stack to forward, no DBus, and no GPIO.

### Windows (WSL2)

USB serial requires [usbipd-win](https://github.com/dorssel/usbipd-win) to attach the device to the Linux side. See [docs/installation.md](installation.md#windows-usb-serial). CAN, Bluetooth, and GPIO are not supported.
