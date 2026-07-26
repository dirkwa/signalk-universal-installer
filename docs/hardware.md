# Hardware passthrough

The installer detects host hardware at install time and passes it through to the `signalk-server` container via Quadlet `AddDevice=` and `Volume=` lines. The detection runs in `installer/linux/detect-hardware.sh` and the result is persisted to `~/.signalk-updater/hardware.json`.

## What's detected

| Class | Source | Default | Persisted as |
|---|---|---|---|
| **USB serial** | Every entry under `/dev/serial/by-id/*` (stable across renumbering) | **Enabled** — most boats want USB-serial gateways (NMEA0183, NMEA2000 via Actisense / Yacht Devices / iKommunicate) reachable from signalk-server | `{ byId, vendor, product, enabled }` per device |
| **SocketCAN** | `ip -o link show type can` (every `can*` netlink interface) | Disabled (requires explicit opt-in) — CAN interfaces can be physical (NGT-1 plugged in over USB-CAN) or virtual (`vcan0` for testing) and surfacing them all by default is noisy | `{ interface, type: "socketcan", enabled }` per interface |
| **Bluetooth (DBus)** | Presence of `/run/dbus/system_bus_socket` | Disabled — BLE on Linux requires the host DBus to be reachable from the container, and not every install needs it | `{ enabled, dbusAvailable }` (no per-device list; toggle mounts the dbus-auth-proxy socket volume — see [Bluetooth / BLE passthrough](#bluetooth--ble-passthrough)) |
| **Raspberry Pi GPIO** | `/proc/device-tree/model` matched against `Pi[ ]*[3-5]` | Disabled (opt-in) — only meaningful on Pi hosts | `{ enabled, platform: "rpi5"\|"rpi4"\|"rpi3"\|"rpi-other"\|"none" }` |
| **ALSA audio** | Presence of `/dev/snd` | **Enabled when present** — the mount is a read-only *metadata view* for signalk-container's device probe, not direct audio access (see [Audio passthrough](#audio-passthrough)); the low risk doesn't warrant install-time friction for voice-stack users | `{ present, enabled }` |

For each enabled entry the renderer (`render-server-quadlet.sh`) emits an `AddDevice=` line (USB serial, CAN) or a `Volume=` line (DBus, GPIO, audio) inside a managed `# === BEGIN HARDWARE / END HARDWARE ===` block in `signalk-server.container`. Anything outside that block — including the separate `# === BEGIN USER ADDITIONS ===` block — is preserved verbatim across re-detects and version switches.

## Group memberships

Rootless Podman needs the calling user in the right Unix groups to forward devices into the container without `--privileged`:

| Group | Required for |
|---|---|
| `dialout` | USB serial (`/dev/ttyUSB*`, `/dev/serial/by-id/*`) |
| `gpio` | Raspberry Pi GPIO (`/dev/gpiomem`) |
| `netdev` | SocketCAN (`vcan` setup, `ip` administration) |
| `audio` | ALSA devices (`/dev/snd/*`) opened by managed audio containers (see [Audio passthrough](#audio-passthrough)) |

The installer adds you to all four at step 5 of `install.sh`. Group changes only take effect on a new login session, so on a `curl … | bash` first run you'll see a hint to log out and back in.

## Re-running detection

Hardware changes (plugging in a new USB gateway, adding a CAN interface) require re-running detection so the Quadlet picks them up. The supported path is to re-run the bash installer:

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

`curl … | bash` is idempotent; it re-runs `detect-hardware.sh`, the result feeds into a Quadlet rewrite via `render-server-quadlet.sh`, and `systemctl --user daemon-reload` + `restart signalk-server.service` picks up the new `AddDevice=` lines.

The `hardware.json` file is the source of truth: if you want to disable a USB-serial device you'd otherwise pass through, edit the `enabled` field directly and either re-run the installer (which calls `render-server-quadlet.sh` for you) or POST the new payload to `/api/hardware/apply` on the Updater (bearer-token-gated).

## Bluetooth / BLE passthrough

BLE plugins (bt-sensors and anything built on `node-ble` / `dbus-next` / `dbus-native`) talk to the host's bluez over the **system D-Bus**. A rootless container cannot simply bind-mount `/run/dbus`: D-Bus `AUTH EXTERNAL` compares the uid the client sends (its in-container uid) with the kernel's `SO_PEERCRED` (the host-side uid). On any host where the SignalK user isn't uid 1000 those differ, the daemon never completes the handshake, and after its 30 s auth timeout the plugin dies with `Tried to write a message to a closed stream`. A missing mount fails earlier and louder: `connect ENOENT /var/run/dbus/system_bus_socket`.

The installer therefore ships a sidecar, `signalk-dbus-proxy` ([dbus-auth-proxy](https://github.com/yichenshen/dbus-auth-proxy)), which exposes a rewritten `system_bus_socket` in the named volume `signalk-dbus-socket`. When bluetooth is enabled the renderer mounts that volume at `/run/dbus` inside `signalk-server`, so D-Bus clients find a socket at the standard path whose `AUTH EXTERNAL` uid is corrected in transit.

```bash
signalk bluetooth status    # host bluez, proxy chain, and which installed modules dial D-Bus
signalk bluetooth enable    # mount the proxy socket into signalk-server + restart
signalk bluetooth disable   # unmount + restart
```

`enable`/`disable` edit only the bluetooth line of the managed HARDWARE block (and migrate away any legacy direct `/run/dbus` bind mount from older installs). The host needs `bluez` running; the container needs no bluez of its own.

On installs that predate the proxy, `signalk update` alone is enough: it stages the proxy Quadlet template in the doctor's installer payload, and `signalk bluetooth enable` installs it from there (substituting the pinned proxy image) — no re-run of the bash installer required.

## Audio passthrough

Voice-assistant plugins (the [signalk-wyoming](https://github.com/hoeken/signalk-wyoming) family) run their audio consumer — a [wyoming-satellite](https://github.com/hoeken/wyoming-satellite) container holding the mic/speaker — as a **sibling container managed through signalk-container**. The sound card reaches that sibling via signalk-container's own device emission (`/dev/snd` bind + `audio` group), *not* via this installer.

What the installer contributes is one level of indirection up: signalk-container runs *inside* the signalk-server container and stats a plugin's requested device paths on its **own** filesystem before emitting them for the target container. The HARDWARE block's

```ini
Volume=/dev/snd:/dev/snd:ro
```

gives it a truthful view of the host's sound devices — full drift fidelity, live hot-plug tracking, and correct doctor reporting. It is deliberately **read-only and metadata-only**: signalk-server itself never opens audio devices, and the audio consumer container gets its own (writable) bind from signalk-container. Newer signalk-container releases also emit well-known device paths *unverified* when they can't see them locally, so audio can work without this mount — the mount removes the guesswork.

Two guards keep it safe:

- **Render-time existence check** (same as the avahi socket): a `Volume=` whose source is missing fails the whole unit at start, so a stale `enabled: true` on a host that lost its sound devices renders nothing instead of bricking the server.
- **`enabled` in `hardware.json`** is the operator opt-out, like every other class.

The `audio` group membership (step 5) is the other half: under rootless Podman the device nodes keep their host ownership (`root:audio`), and the consumer container's access rides on the calling user's own supplementary groups (crun's keep-original-groups), not on a uid mapping.

## Platform notes

### Raspberry Pi (3 / 4 / 5)

Detected automatically via `/proc/device-tree/model`. On the Pi the installer also nudges cgroup memory + pids delegation onto the user slice (some Pi-OS images ship without the right `Delegate=` set on `user@.service`), so engine containers can apply memory limits.

GPIO passthrough mounts `/dev/gpiomem` only — not `/dev/mem`. Plugins that need the full memory map for low-level peripherals won't work in this configuration; they'd need to run on the host, not in the container.

### macOS (Apple Silicon and Intel)

USB serial is supported **only** when the Podman Machine is created with `--usb`. See [docs/installation.md](installation.md#macos-usb-serial) for the recreate recipe.

CAN, Bluetooth, and GPIO are **not** supported on macOS Podman Machine — there's no host CAN stack to forward, no DBus, and no GPIO.

### Windows (WSL2)

USB serial requires [usbipd-win](https://github.com/dorssel/usbipd-win) to attach the device to the Linux side. See [docs/installation.md](installation.md#windows-usb-serial). CAN, Bluetooth, and GPIO are not supported.
