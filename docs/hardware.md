# Hardware passthrough

The installer detects host hardware at install time and passes it through to the `signalk-server` container: serial devices at each start of the server, the other classes via Quadlet `Volume=` lines. SocketCAN needs no passthrough: signalk-server shares the host's network, which includes its CAN interfaces. The detection runs in `installer/linux/detect-hardware.sh` and the result is persisted to `~/.signalk-updater/hardware.json`.

## What's detected

| Class | Source | Default | Persisted as |
|---|---|---|---|
| **USB serial** | Every entry under `/dev/serial/by-id/*` (stable across renumbering) | **Enabled** — most boats want USB-serial gateways (NMEA0183, NMEA2000 via Actisense / Yacht Devices / iKommunicate) reachable from signalk-server | `{ byId, vendor, product, enabled }` per device |
| **SocketCAN** | `ip -o link show type can` (every `can*` netlink interface) | Disabled, and informational only: a SocketCAN interface is a network device with no `/dev` node, and signalk-server runs with `Network=host`, so every CAN interface on the host is reachable whether it is enabled here or not. No Quadlet line is rendered for it | `{ interface, type: "socketcan", enabled }` per interface |
| **Bluetooth (DBus)** | Presence of `/run/dbus/system_bus_socket` | Disabled — BLE on Linux requires the host DBus to be reachable from the container, and not every install needs it | `{ enabled, dbusAvailable }` (no per-device list; toggle mounts the dbus-auth-proxy socket volume — see [Bluetooth / BLE passthrough](#bluetooth--ble-passthrough)) |
| **Raspberry Pi GPIO** | `/proc/device-tree/model` matched against `Pi[ ]*[3-5]` | Disabled (opt-in) — only meaningful on Pi hosts | `{ enabled, platform: "rpi5"\|"rpi4"\|"rpi3"\|"rpi-other"\|"none" }` |
| **HALPI2 board** | `/proc/device-tree/model` says Compute Module 5, then `halpid` active or the controller answering at I2C `0x6d` (see [docs/halpi2.md](halpi2.md)) | Informational — drives the `/run/halpid` mount and the install-time connection step; the `signalk halpi2 apply` step itself is triggered by the model string, before this file is written | `{ model: "halpi2", candidate, detectedVia: "model-string"\|"halpid"\|"i2c", hardwareVersion, firmwareVersion }` — absent on other hosts |
| **Onboard serial** | Fixed UARTs a detected board provides (HALPI2: `/dev/ttyAMA4`, RS-485) | **Enabled** — same reasoning as USB serial | `{ device, label, enabled }` per port, under `onboardSerial` |
| **ALSA audio** | Presence of `/dev/snd` | **Enabled when present** — the mount is a read-only *metadata view* for signalk-container's device probe, not direct audio access (see [Audio passthrough](#audio-passthrough)); the low risk doesn't warrant install-time friction for voice-stack users | `{ present, enabled }` |
| **Input devices** | Presence of `/dev/input` | **Enabled when present** — same read-only *metadata view* as audio, for encoders and keypads (see [Input passthrough](#input-passthrough)) | `{ present, enabled }` |

The renderer (`render-server-quadlet.sh`) emits a `Volume=` line for each enabled DBus, GPIO, audio and input entry, and for the halpid socket on a HALPI2, inside a managed `# === BEGIN HARDWARE / END HARDWARE ===` block in `signalk-server.container`. An enabled SocketCAN entry gets no line. Enabled serial devices (USB serial and onboard serial) go into a second managed block in the `[Service]` section, `# === BEGIN SERIAL DEVICES / END SERIAL DEVICES ===`, as one `Environment="SIGNALK_SERIAL_DEVICES=…"` line. Anything outside those blocks — including the separate `# === BEGIN USER ADDITIONS ===` block — is preserved verbatim across re-detects and version switches.

Serial devices are checked at every start of `signalk-server`, not when the Quadlet is rendered. podman refuses to create the container (exit 125) when a `--device` path is missing, so with `AddDevice=` lines one unplugged device kept the whole server down ([#309](https://github.com/dirkwa/signalk-universal-installer/issues/309): a touchscreen's serial port that disappears whenever the monitor is switched off). Instead, an `ExecStartPre` in the server unit waits up to 15 seconds for any listed device that is missing, then writes `--device` arguments for the devices that exist to `$XDG_RUNTIME_DIR/signalk-server-devices.env`, which `PodmanArgs=$SIGNALK_DEVICE_ARGS` hands to podman. A device that is still missing is left out, and the server starts without it; `journalctl --user -u signalk-server` shows `starting without absent serial device(s): …`. A device that comes back is passed at the next start of the server, without a re-render.

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

`rescan` carries your operator toggles across the re-detect: the bluetooth, GPIO, audio, input and on-board serial switches, and the `enabled` of each USB serial device (matched by its `by-id` path) and CAN interface (matched by name). A USB serial device or CAN interface you switched off stays in the file, still off, while it is unplugged; an on-board serial port missing from the detection is dropped with its setting. A device seen for the first time gets the detection default (see `installer/linux/detect-hardware.sh`). If it cannot merge (no `jq`, the payload is incomplete, or the merge fails) it refuses to write and leaves the file as it is. A `hardware.json` that is not one JSON object has no toggles left to keep, so it is replaced by the fresh detection once the old file is copied to `hardware.json.bak`; if that copy fails, `rescan` refuses. `--no-render` stops before touching the Quadlet.

Re-running the bash installer also works and is idempotent, but it re-pulls every image as well; on an SD-card host that is minutes and a restarted server to pick up a device that is already plugged in. It merges the same way. When it cannot merge, it keeps the existing file unchanged and goes on with the install, so a device attached since that file was written is not added until a `rescan` with `jq` installed.

```bash
curl -fsSL https://dirkwa.github.io/signalk-universal-installer/installer/linux/install.sh | bash
```

The `hardware.json` file is the source of truth: if you want to disable a USB-serial device you'd otherwise pass through, set its `enabled` field to `false` and run `signalk render-server`, re-run the installer (which calls `render-server-quadlet.sh` for you), or POST the new payload to `/api/hardware/apply` on the Updater (bearer-token-gated). The setting survives later `signalk hardware rescan` and installer runs.

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
| Same error, and the device is listed | It was missing when the server last started (`journalctl --user -u signalk-server \| grep 'absent serial'`). Plug it in and run `signalk restart`. |
| Connection shows as down, no error | Permissions. Check `GroupAdd=keep-groups` is in `~/.config/containers/systemd/signalk-server.container`, and that `id -nG` includes `dialout`. |
| `spawn udevadm ENOENT` in the log | Harmless. The serial library shells out to `udevadm` for metadata; it is absent from the image and the port still opens. |

To confirm the container can actually reach the device:

```bash
podman exec signalk-server ls -l /dev/serial/by-id/
podman exec signalk-server sh -c '[ -w /dev/ttyUSB0 ] && echo writable'
```

## Running your own program as a data source

Signal K Server can start a program and read one Signal K delta per line from its standard output, through a `providers/execute` entry in `settings.json`. The admin UI cannot create this connection type, so the entry is added by hand. In this stack the server starts the program **inside the `signalk-server` container**, which changes three things compared with a server installed with npm.

The program gets the same access as the server: the host network, the devices passed into the container, and the Podman API socket, which controls all of your user's containers. Run only programs you trust.

**The program has to be inside `~/.signalk`.** That directory is the only part of your home the container mounts, at `/home/node/.signalk`. A path such as `/home/pi/bin/wind-sensor` does not exist inside the container.

```bash
mkdir -p ~/.signalk/bin
cp wind-sensor ~/.signalk/bin/
chmod +x ~/.signalk/bin/wind-sensor
```

**It has to run on the container's OS.** The image is Ubuntu 26.04, built for `arm64` and `amd64`, so a 32-bit `armhf` binary does not run. A 64-bit binary built on Raspberry Pi OS bookworm or trixie needs no newer C library than the container has. Every other shared library it links, for example `libdbus-1` for some BLE crates, must also exist in the container. A statically linked build, such as Rust's `aarch64-unknown-linux-musl` target, needs none of them. To check, list what is missing and then run it the way the server will:

```bash
podman exec signalk-server sh -c 'ldd /home/node/.signalk/bin/wind-sensor | grep "not found"'
podman exec signalk-server /home/node/.signalk/bin/wind-sensor
```

**Devices it opens have to be passed through.** A USB serial device needs `signalk hardware rescan`, as in [Connecting a USB NMEA gateway](#connecting-a-usb-nmea-gateway). A program that uses BLE through bluez needs `signalk bluetooth enable` ([Bluetooth / BLE passthrough](#bluetooth--ble-passthrough)).

Then add the connection. Stop the server first with `signalk stop`, because the server writes `settings.json` from memory and can overwrite an edit made while it runs. Add this entry to the `pipedProviders` array in `~/.signalk/settings.json` and leave the rest of the file unchanged:

```json
{
  "id": "wind-sensor",
  "enabled": true,
  "pipeElements": [
    {
      "type": "providers/execute",
      "options": {
        "command": "/home/node/.signalk/bin/wind-sensor"
      }
    },
    { "type": "providers/liner" },
    { "type": "providers/from_json" }
  ]
}
```

Start it again with `signalk start`. The connection is listed under **Server → Data Connections** as read-only JSON, and its data shows in the **Data Browser** with `wind-sensor` as the source. Each line the program prints must be a complete delta, for example `{"updates":[{"values":[{"path":"environment.wind.speedApparent","value":5.2}]}]}`, with values in SI units. Without a `context` the values go to your own vessel. Output on standard error appears in the server log (`journalctl --user -u signalk-server`).

The `settings/commandline-provider-settings.json` file in the signalk-server repository is an example of the same entry. Copying that file into `~/.signalk` does nothing: it is a complete settings file for `signalk-server -s <file>`, and the server reads only `settings.json`. Its `vessel` block is not needed either; the vessel name and MMSI are set under **Server → Settings**.

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

gives it a truthful view of the host's sound devices — full drift fidelity, live hot-plug tracking, and correct doctor reporting. It is deliberately **read-only and metadata-only**: signalk-server itself never opens audio devices, and the audio consumer container gets its own (writable) bind from signalk-container. signalk-container 1.24.0 and newer also emit well-known device paths *unverified* when they can't see them locally, so audio can work without this mount — the mount removes the guesswork.

Two guards keep it safe:

- **Render-time existence check** (same as the avahi socket): a `Volume=` whose source is missing fails the whole unit at start, so a stale `enabled: true` on a host that lost its sound devices renders nothing instead of bricking the server.
- **`enabled` in `hardware.json`** is the operator opt-out, like every other class.

The `audio` group membership (step 5) is the other half: under rootless Podman the device nodes keep their host ownership (`root:audio`), and the consumer container's access rides on the calling user's own supplementary groups (crun's keep-original-groups), not on a uid mapping.

## Input passthrough

Plugins that drive a rotary encoder, a keypad, or a joystick run their consumer as a **sibling container managed through signalk-container**, exactly like the audio case above. signalk-container emits the `/dev/input` bind and the `input` group for that container; the installer does not.

What the installer contributes is the same one level of indirection: a read-only bind of the host's `/dev/input` into the server container. `installer/linux/render-server-quadlet.sh` emits it and owns its exact form; run the `grep` under [Hand-crafted Podman](#hand-crafted-podman) against your generated `signalk-server.container` to see what your host actually got.

signalk-container runs *inside* the signalk-server container and stats a plugin's requested device paths on its **own** filesystem before emitting them for the target container. Without this view the probe cannot see the host's input nodes.

### Why the group matters more than the mount

`:ro` makes the *mount* read-only — nothing in the container can create or remove nodes under it. It does **not** stop a process from opening a node for reading; that is governed by the node's own permissions, and `/dev/input/event*` is `root:input` mode 0660. So whether the server container can read your keystrokes comes down to one thing: whether it holds the `input` group.

`GroupAdd=keep-groups` carries **every** supplementary host group into the container, whoever granted it. Two things follow, and both are enforced:

- The installer never adds you to `input` at step 5, unlike `audio`. `check-render-quadlet.sh` guards against that regressing, scanning install.sh for the group-management patterns it knows (`for g in …`, `usermod`, `gpasswd`, `adduser`, `groupadd`, a `GROUPS` list), with comments stripped and line continuations joined. It is a regression guard over known shapes, not a proof of absence — the render-time check below is what actually enforces the outcome.
- Membership you already had is not the installer's to remove, and this renderer also runs on hosts the installer did not set up. So the mount is **withheld entirely** when the service user is in `input`, with a comment in the rendered unit saying why. Losing it costs only probe accuracy: signalk-container 1.24.0 and newer fall back to emitting `/dev/input` unverified, so a consumer container still works. The installer bundles the current release, but an install that has held signalk-container below 1.24.0 gets no fallback — there the consumer container needs the device declared explicitly.

The probe itself never needs the group. It only calls `readdir` and `stat`, both of which work without it — `stat` reports the overflow gid, which the probe resolves through udev convention instead. A consumer container that genuinely needs to read an encoder gets its own group emitted by signalk-container, scoped to that one container.

This is where audio and input differ. Audio needs the group: `wyoming-satellite` opens the sound card, and under rootless Podman that access rides on the calling user's supplementary groups via crun's keep-original-groups, so the installer adds you to `audio`. Input needs no such thing at the server level, so the group is left off — and the mount steps aside when the host grants it anyway.

Beyond that, the same two guards apply as for audio: a render-time existence check (a `Volume=` with a missing source fails the whole unit at start), and `enabled` in `hardware.json` as the operator opt-out.

### Hand-crafted Podman

If you run `signalk-server` from your own `podman run` or compose file rather than the installer's Quadlet, give the device probe the same views the Quadlet does. Rather than reproduce the flags here — this file would drift from the renderer that actually emits them — read them out of the generated unit:

```bash
grep -E '^(Volume=/dev/|GroupAdd=)' ~/.config/containers/systemd/signalk-server.container
```

On a host with both classes detected that prints the `/dev/snd` and `/dev/input` binds and `GroupAdd=keep-groups`. `installer/linux/render-server-quadlet.sh` is the single source for those lines; if you have no install to read from, that script and `quadlets/signalk-server.container.template` are the files to consult.

Two things to carry across to a hand-written unit. Bind each device directory **`:ro`**, and omit any whose directory the host does not have. And check `id -nG` before binding `/dev/input` at all: if the user running the container is in the `input` group, leave that bind out. `keep-groups` is container-wide, so the membership would let anything in the server container open `/dev/input/event*` and read every keystroke on the host, and `:ro` does not prevent it. The installer's renderer applies this same rule automatically. The probe does not need the group (see above).

Neither mount is strictly required. signalk-container 1.24.0 and newer know `/dev/snd`, `/dev/input` and `/dev/dri` as well-known hot-plug directories and emit them **unverified** when they cannot be seen locally, so a consumer container can still work without them. What the mounts buy is a truthful probe: correct drift detection, live hot-plug tracking, and accurate `signalk doctor` reporting instead of a guess.

## Platform notes

### Raspberry Pi (3 / 4 / 5)

Detected automatically via `/proc/device-tree/model`. On the Pi the installer also nudges cgroup memory + pids delegation onto the user slice (some Pi-OS images ship without the right `Delegate=` set on `user@.service`), so engine containers can apply memory limits.

The installer arms the Pi's hardware watchdog through systemd, so a Pi whose kernel or systemd hangs resets itself. [docs/recovery.md](recovery.md#hardware-watchdog-raspberry-pi) has the check, the manual recipe and the opt-out.

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
