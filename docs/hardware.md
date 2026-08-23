# Hardware passthrough

The installer detects host hardware at install time and passes it through to the `signalk-server` container via Quadlet `AddDevice=` and `Volume=` lines. The detection runs in `installer/linux/detect-hardware.sh` and the result is persisted to `~/.signalk-updater/hardware.json`.

## What's detected

| Class | Source | Default | Persisted as |
|---|---|---|---|
| **USB serial** | Every entry under `/dev/serial/by-id/*` (stable across renumbering) | **Enabled** — most boats want USB-serial gateways (NMEA0183, NMEA2000 via Actisense / Yacht Devices / iKommunicate) reachable from signalk-server | `{ byId, vendor, product, enabled }` per device |
| **SocketCAN** | `ip -o link show type can` (every `can*` netlink interface) | Disabled (requires explicit opt-in) — CAN interfaces can be physical (NGT-1 plugged in over USB-CAN) or virtual (`vcan0` for testing) and surfacing them all by default is noisy | `{ interface, type: "socketcan", enabled }` per interface |
| **Bluetooth (DBus)** | Presence of `/run/dbus/system_bus_socket` | Disabled — BLE on Linux requires the host DBus to be reachable from the container, and not every install needs it | `{ enabled, dbusAvailable }` (no per-device list; toggle mounts the dbus-auth-proxy socket volume — see [Bluetooth / BLE passthrough](#bluetooth--ble-passthrough)) |
| **Raspberry Pi GPIO** | `/proc/device-tree/model` matched against `Pi[ ]*[3-5]` | Disabled (opt-in) — only meaningful on Pi hosts | `{ enabled, platform: "rpi5"\|"rpi4"\|"rpi3"\|"rpi-other"\|"none" }` |
| **HALPI2 board** | `/proc/device-tree/model` says Compute Module 5, then `halpid` active or the controller answering at I2C `0x6d` (see [docs/halpi2.md](halpi2.md)) | Informational — drives the `/run/halpid` mount and the install-time connection step; the `signalk halpi2 apply` step itself is triggered by the model string, before this file is written | `{ model: "halpi2", candidate, detectedVia: "model-string"\|"halpid"\|"i2c", hardwareVersion, firmwareVersion }` — absent on other hosts |
| **Onboard serial** | Fixed UARTs a detected board provides (HALPI2: `/dev/ttyAMA4`, RS-485) | **Enabled** — same reasoning as USB serial | `{ device, label, enabled }` per port, under `onboardSerial` |
| **ALSA audio** | Presence of `/dev/snd` | **Enabled when present** — the mount is a read-only *metadata view* for signalk-container's device probe, not direct audio access (see [Audio passthrough](#audio-passthrough)); the low risk doesn't warrant install-time friction for voice-stack users | `{ present, enabled }` |
| **Input devices** | Presence of `/dev/input` | **Enabled when present** — same read-only *metadata view* as audio, for encoders and keypads (see [Input passthrough](#input-passthrough)) | `{ present, enabled }` |

For each enabled entry the renderer (`render-server-quadlet.sh`) emits an `AddDevice=` line (USB serial, onboard serial, CAN) or a `Volume=` line (DBus, GPIO, audio, input, halpid socket) inside a managed `# === BEGIN HARDWARE / END HARDWARE ===` block in `signalk-server.container`. Anything outside that block — including the separate `# === BEGIN USER ADDITIONS ===` block — is preserved verbatim across re-detects and version switches.

## Group memberships

Rootless Podman needs the calling user in the right Unix groups to forward devices into the container without `--privileged`:

| Group | Required for |
|---|---|
| `dialout` | USB serial (`/dev/ttyUSB*`, `/dev/serial/by-id/*`) |
| `gpio` | Raspberry Pi GPIO (`/dev/gpiomem`) |
| `netdev` | SocketCAN (`vcan` setup, `ip` administration) |
| `audio` | ALSA devices (`/dev/snd/*`) opened by managed audio containers (see [Audio passthrough](#audio-passthrough)) |

The installer adds you to all four at step 5 of `install.sh`. `input` is deliberately **not** among them — see [Input passthrough](#input-passthrough) for why. Group changes only take effect on a new login session, so on a `curl … | bash` first run you'll see a hint to log out and back in.

**Host membership alone is not sufficient.** `UserNS=keep-id:uid=1000,gid=1000` maps only your uid and gid into the container, so a supplementary group such as `dialout` (GID 20) arrives inside as an unmapped 100020. A `/dev/tty*` node is `root:dialout` mode 660, the container process does not hold GID 20, and every `open()` fails — silently, because SignalK reports the connection as *down* rather than surfacing a permission error.

The server Quadlet therefore carries `GroupAdd=keep-groups`, which tells crun to keep your real host GIDs on the process instead of mapping them. Both halves are required: the installer puts you in the group, and `keep-groups` carries that membership across the user namespace.

`keep-groups` passes your *whole* supplementary set, which on a stock Pi OS install includes `sudo` and `adm`. Those GIDs arrive unmapped inside the namespace (they show as `nogroup`) so they grant nothing against the container's own `/etc/group` — `sudo` inside is still denied — and matter only for kernel permission checks against host objects, which is exactly the device node this exists for.

## Re-running detection

`hardware.json` is written once, at detection time. Plug in a USB gateway afterwards and nothing notices until detection runs again.

```bash
signalk hardware status    # what was detected, and when
signalk hardware rescan    # re-detect, re-render the Quadlet, restart if it changed
```

`rescan` carries your operator toggles across the re-detect — a fresh detection reports bluetooth and GPIO as disabled, and audio and input at their `/dev/snd`- and `/dev/input`-derived defaults, so a naive overwrite would switch off passthrough you had turned on. If it cannot merge (no `jq`, or the payload is incomplete) it refuses to write rather than clobbering them. `--no-render` stops before touching the Quadlet.

Re-running the bash installer also works and is idempotent, but it re-pulls every image as well; on an SD-card host that is minutes and a restarted server to pick up a device that is already plugged in.

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

The `hardware.json` file is the source of truth: if you want to disable a USB-serial device you'd otherwise pass through, edit the `enabled` field directly and either re-run the installer (which calls `render-server-quadlet.sh` for you) or POST the new payload to `/api/hardware/apply` on the Updater (bearer-token-gated).

## Connecting a USB NMEA gateway

Worked example with an Actisense NGT-1; a USB GPS or an NMEA 0183 adapter is the same shape.

1. Plug it in and confirm the host sees it:

   ```bash
   ls -l /dev/serial/by-id/
   # usb-Actisense_NGT-1_3A055-if00-port0 -> ../../ttyUSB0
   ```

2. Re-detect and re-render:

   ```bash
   signalk hardware rescan
   ```

3. Add the connection in the SignalK admin UI under **Server → Data Connections**. For an NGT-1 that is type **NMEA 2000**, source **Actisense NGT-1**, baud **115200**.

**Use the `by-id` path as the device**, not `/dev/ttyUSB0`:

```
/dev/serial/by-id/usb-Actisense_NGT-1_3A055-if00-port0
```

Both work — each device is passed into the container twice, once mapped to its stable `by-id` name and once bare, which podman resolves to `/dev/ttyUSB*`. The bare form exists so configs and guides that say `/dev/ttyUSB0` keep working. But `ttyUSB` numbering is assigned in enumeration order: add a second USB serial device and the two can swap on reboot, at which point SignalK reads the wrong one from a config that still looks correct. The `by-id` name cannot do that.

### When it does not work

| Symptom | Cause |
|---|---|
| `Error: No such file or directory, cannot open /dev/ttyUSB0` | The device is not in the Quadlet. Run `signalk hardware status` — if it is not listed, `signalk hardware rescan`. |
| Connection shows as down, no error | Permissions. Check `GroupAdd=keep-groups` is in `~/.config/containers/systemd/signalk-server.container`, and that `id -nG` includes `dialout`. |
| `spawn udevadm ENOENT` in the log | Harmless. The serial library shells out to `udevadm` for metadata; it is absent from the image and the port still opens. |

To confirm the container can actually reach the device:

```bash
podman exec signalk-server ls -l /dev/serial/by-id/
podman exec signalk-server sh -c '[ -w /dev/ttyUSB0 ] && echo writable'
```

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

## Input passthrough

Plugins that drive a rotary encoder, a keypad, or a joystick run their consumer as a **sibling container managed through signalk-container**, exactly like the audio case above. signalk-container emits the `/dev/input` bind and the `input` group for that container; the installer does not.

What the installer contributes is the same one level of indirection:

```ini
Volume=/dev/input:/dev/input:ro
```

signalk-container runs *inside* the signalk-server container and stats a plugin's requested device paths on its **own** filesystem before emitting them for the target container. Without this view the probe cannot see the host's input nodes.

`:ro` here means the *mount* is read-only — nothing in the container can create or remove nodes under it. It does **not** stop a process from opening a node for reading; that is governed by the node's own permissions, and `/dev/input/event*` is `root:input` mode 0660. So whether the server container can read your keystrokes comes down to one thing: whether it holds the `input` group.

It does not. Unlike `audio`, the installer deliberately does **not** add you to `input` at step 5, because `GroupAdd=keep-groups` is server-wide and would carry that membership into signalk-server itself. signalk-container's probe only ever calls `readdir` and `stat`, and both work without the group — `stat` reports the overflow gid, which the probe resolves through udev convention instead. A consumer container that genuinely needs to read an encoder gets its own group emitted by signalk-container, scoped to that one container.

`check-render-quadlet.sh` asserts the `:ro` flag is present.

The same two guards apply as for audio: a render-time existence check (a `Volume=` with a missing source fails the whole unit at start), and `enabled` in `hardware.json` as the operator opt-out.

This is where audio and input differ. Audio needs the group: `wyoming-satellite` opens the sound card, and under rootless Podman that access rides on the calling user's supplementary groups via crun's keep-original-groups, so the installer adds you to `audio`. Input needs no such thing at the server level — the probe never opens a node — so the group is left off and the read capability never reaches signalk-server.

### Hand-crafted Podman

If you run `signalk-server` from your own `podman run` or compose file rather than the installer's Quadlet, give the device probe the same views the Quadlet does. Rather than reproduce the flags here — this file would drift from the renderer that actually emits them — read them out of the generated unit:

```bash
grep -E '^(Volume=/dev/|GroupAdd=)' ~/.config/containers/systemd/signalk-server.container
```

On a host with both classes detected that prints the `/dev/snd` and `/dev/input` binds and `GroupAdd=keep-groups`. `installer/linux/render-server-quadlet.sh` is the single source for those lines; if you have no install to read from, that script and `quadlets/signalk-server.container.template` are the files to consult.

Two things to carry across to a hand-written unit. Bind each device directory **`:ro`**, and omit any whose directory the host does not have. And do not add yourself to `input`: `keep-groups` is container-wide, so that membership would let anything in the server container open `/dev/input/event*` and read every keystroke on the host. The probe does not need it (see above).

Neither mount is strictly required. signalk-container knows `/dev/snd`, `/dev/input` and `/dev/dri` as well-known hot-plug directories and emits them **unverified** when it cannot see them locally, so a consumer container can still work without them. What the mounts buy is a truthful probe: correct drift detection, live hot-plug tracking, and accurate `signalk doctor` reporting instead of a guess.

## Platform notes

### Raspberry Pi (3 / 4 / 5)

Detected automatically via `/proc/device-tree/model`. On the Pi the installer also nudges cgroup memory + pids delegation onto the user slice (some Pi-OS images ship without the right `Delegate=` set on `user@.service`), so engine containers can apply memory limits.

GPIO passthrough mounts `/dev/gpiomem` only — not `/dev/mem`. Plugins that need the full memory map for low-level peripherals won't work in this configuration; they'd need to run on the host, not in the container.

### Hat Labs HALPI2 (Compute Module 5 carrier)

Detected via the Compute Module 5 model string plus the HALPI2 controller at I2C `0x6d` (or a running `halpid`). The installer then runs `signalk halpi2 apply`: Hat Labs' APT repository and packages (`halpid`, `halpi2-firmware`, `blinkenlights-daemon`), the device-tree block for CAN / RS-485 / I2C in `config.txt`, the can0 bitrate, and a reboot; the re-run passes `/dev/ttyAMA4` and `/run/halpid` into the container and creates the NMEA 2000 and RS-485 connections through the server's admin API. Everything, including the `sd=off` guard and the prompt rules, is in [docs/halpi2.md](halpi2.md).

### macOS (Apple Silicon and Intel)

USB serial is supported **only** when the Podman Machine is created with `--usb`. See [docs/installation.md](installation.md#macos-usb-serial) for the recreate recipe.

CAN, Bluetooth, and GPIO are **not** supported on macOS Podman Machine — there's no host CAN stack to forward, no DBus, and no GPIO.

Audio and input are likewise unavailable: detection runs inside the Podman Machine VM, whose `/dev/snd` and `/dev/input` (when present at all) belong to the VM, not to the Mac. Neither class is passed through from macOS.

### Windows (WSL2)

USB serial requires [usbipd-win](https://github.com/dorssel/usbipd-win) to attach the device to the Linux side. See [docs/installation.md](installation.md#windows-usb-serial). CAN, Bluetooth, and GPIO are not supported.

Audio and input carry the same WSL2 caveat as macOS: detection sees the WSL2 VM's devices, not Windows'. A USB sound card or encoder has to be attached with `usbipd-win` before it exists on the Linux side at all.
