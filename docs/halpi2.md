# Hat Labs HALPI2 (Raspberry Pi CM5 carrier)

The HALPI2 is Hat Labs' marine computer: a Raspberry Pi Compute Module 5 on a carrier board with an RP2040 controller (power monitoring, supercapacitor-backed shutdown, watchdog, five front-panel RGB LEDs), an MCP2518FD CAN controller for NMEA 2000, an RS-485 port for NMEA 0183, and I2C. Hat Labs ships it with HaLOS, whose images bake the hardware support in at build time. This installer does the same job at runtime on plain Raspberry Pi OS: it detects the board, installs Hat Labs' own Debian packages, and writes the device-tree and network configuration those packages need — nothing is re-implemented.

`signalk halpi2` is the helper; `install.sh` runs it automatically on a Compute Module 5 (step 2c, right after preflight).

This installer is not a Hat Labs product and is not endorsed by Hat Labs. The device-tree lines, the can0 network/udev settings and the Signal K connection ids are taken from Hat Labs' `halos-pi-gen` (BSD-3-Clause, © Hat Labs oy) and their published HALPI2 documentation; the daemons themselves are installed unmodified from `apt.hatlabs.fi` (halpid and blinkenlights-daemon BSD-3-Clause, halpi2-firmware MIT).

## TL;DR

```bash
signalk halpi2 status        # what is detected, installed and configured (default)
signalk halpi2 detect        # JSON board summary; exit 0 confirmed, 1 candidate, 2 not a CM5
signalk halpi2 apply         # install packages + write config (sudo); exit 2 = reboot needed
signalk halpi2 connections   # create the NMEA 2000 / RS-485 Signal K connections
```

Fresh install on a HALPI2:

1. Run the usual one-liner. On a Compute Module 5 the installer probes the HALPI2 controller at I2C address `0x6d`, installs the Hat Labs packages, shows the proposed `config.txt` change, and stops with a "Reboot required" block listing what it wrote.
2. `sudo reboot`.
3. Run the one-liner again. `can0`, `/dev/ttyAMA4` and `halpid` are live now; the normal hardware detection records them, the server Quadlet gets `AddDevice=/dev/ttyAMA4` and the `/run/halpid` mount, and step 15c creates the two Signal K connections.

One reboot, not two. Preflight may also need a kernel cmdline patch on a Pi (`cgroup_enable=memory cgroup_memory=1`, for the memory controller). It used to stop the run on the spot, so a fresh HALPI2 rebooted once for `cmdline.txt` and again for `config.txt`. Both patches now land in the same pass and the run exits once, listing every pending reason. The installer asks for vessel identity and admin credentials only *after* those gates, so a run that ends in a reboot never prompts — before, each cycle discarded what was typed and asked again.

Existing install: `signalk halpi2 apply`, reboot, `signalk hardware rescan`, `signalk halpi2 connections`. `connections` creates a connection only when its device exists (`can0`, `/dev/ttyAMA4`), so it belongs after the reboot; a skipped one is reported and re-running adds it.

## What gets installed and configured

| Item | Where | Source of the value |
|---|---|---|
| Hat Labs APT key + source | `/etc/apt/keyrings/hatlabs.asc`, `/etc/apt/sources.list.d/hatlabs.sources` (`Suites: trixie-stable` / `bookworm-stable`, `Components: hatlabs`; other distros `stable`/`main`) | `https://apt.hatlabs.fi` |
| `halpid` | Power/watchdog daemon; `halpi` CLI; sockets `/run/halpid/halpid.sock` (group `halpid`, GID 960) and `/run/halpid/led.sock` | hatlabs/HALPI2-rust-daemon |
| `halpi2-firmware` | Controller firmware; its postinst flashes via `halpi flash` (`AUTO_FLASH_ON_INSTALL` in `/etc/halpid/firmware.conf`) | hatlabs/HALPI2-firmware |
| `blinkenlights-daemon` | Front-panel LED display daemon (default: CPU bar; marine examples under `/usr/share/blinkenlights/examples/`) | hatlabs/HALPI2-blinkenlights |
| `i2c-tools`, `can-utils` | `i2ctransfer` for the controller probe, `candump` for verification | Debian |
| Device tree | Marker block in `/boot/firmware/config.txt` (below) | halos-pi-gen `stage-halpi2-common` |
| `i2c-dev` at boot | `/etc/modules-load.d/i2c-dev.conf` | Hat Labs recipe |
| can0 bitrate | `/etc/systemd/network/80-signalk-can0.network` (`BitRate=250000`, `RestartSec=100ms`), `systemctl enable systemd-networkd` | halos-pi-gen |
| can0 queue | `/etc/udev/rules.d/80-signalk-can.rules` (`tx_queue_len=1000`) | halos-pi-gen |
| Groups | `halpid` and `dialout` for the installing user (`halpid`'s postinst covers UID 1000 only) | — |
| Signal K | connections `halpi2-nmea2000` (canbus-canboatjs on `can0`) and `halpi2-rs485` (serial `/dev/ttyAMA4` @ 4800) | HaLOS `stage-halpi2-marine` |

The config.txt block is written between `# >>> signalk-installer halpi2 >>>` and `# <<< signalk-installer halpi2 <<<` and replaced as a whole on the next apply. Its effective lines (the helper adds a comment per line; `render_block()` in `signalk-halpi2.tmpl` is the source):

```text
[all]
dtparam=i2c_arm=on
dtparam=ant2
dtoverlay=spi0-2cs,cs1_pin=6
dtoverlay=mcp251xfd,spi0-1,interrupt=26,oscillator=40000000
dtoverlay=uart4-pi5
dtparam=sd=off
```

`dtparam=sd=off` is what HaLOS ships to avoid a shutdown stall long enough to drain the supercapacitors (raspberrypi/linux#7014). It also disables the microSD slot and, on a CM5 with eMMC, the eMMC. The helper writes it only when `/`, `/boot/firmware` and `/boot` all resolve (`findmnt -T`) to `/dev/nvme*`, `/dev/sd*` or `/dev/disk/*`; on an SD/eMMC-booted system, or when the boot device cannot be determined (`/dev/root`, no `findmnt`), the block carries a comment saying the line was omitted. `check-halpi2-config.sh` compares the lines above with what `render_block()` emits, so this excerpt cannot drift silently.

## How detection works

`detect-hardware.sh` (and `signalk halpi2 detect`) is passive — no sudo, no writes:

1. `/proc/device-tree/model` contains "Compute Module 5" → the box is a *candidate* (`board.candidate: true`, `detectedVia: "model-string"`). Other CM5 carriers exist, so this alone never triggers a write.
2. `systemctl is-active halpid` → confirmed (`detectedVia: "halpid"`).
3. `/dev/i2c-1` readable and `i2ctransfer -y 1 w1@0x6d 0x04 r4` answers → confirmed (`detectedVia: "i2c"`, `firmwareVersion` / `hardwareVersion` filled in). This is the same write-register-then-read-4-bytes transaction `halpid` uses.

`signalk halpi2 apply` runs the same ladder after installing `i2c-tools`, and when `/dev/i2c-1` is missing it brings I2C up live first, so a first run can confirm the board before the reboot. `modprobe i2c-dev` is what creates the device node and runs on any Debian; `dtparam i2c_arm=on` sets the pin mux and runs only where `dtparam` exists (Raspberry Pi OS). `dtparam` runs first where it exists, since on a Pi it brings in `i2c-dev` itself; `modprobe` is the fallback for hosts without it. Where the firmware cannot apply `i2c_arm` at runtime the bus stays off until the reboot, so a first run may still fall through to the candidate prompt.

hardware.json then carries a `board` object and an `onboardSerial` list (shapes in [docs/hardware.md](hardware.md)). `onboardSerial` is listed whenever `/dev/ttyAMA4` exists (the node only appears once the `uart4-pi5` overlay is active), is opt-out like USB serial, and its `enabled` survives a re-detect. `board` is a hardware fact and is regenerated every time. The renderer passes the RS-485 port into the container (existence-guarded, like USB serial) and bind-mounts `/run/halpid` read-only while `halpid.sock` exists, so the `signalk-halpi` plugin from the App Store can read the controller's voltages, temperatures and state.

## Why this helper edits config.txt when `signalk socketcan` only prints a recipe

`docs/socketcan.md` keeps config.txt hands-off because the overlay there is the operator's guess for an unknown HAT. Here the overlay set is fixed for one board, the board has answered at I2C `0x6d` before anything is written, the one line that can make a box unbootable (`sd=off`) is dropped when the boot device is SD/eMMC, and the write follows `preflight.sh`'s cmdline.txt pattern: `diff -u` preview, confirm, timestamped `cp -p` backup, post-write check (exactly one marker pair, no lines lost outside the block), restore on failure.

Prompt behaviour:

| Situation | What `apply` does |
|---|---|
| Terminal, controller confirmed | installs the packages, shows the config.txt diff, asks `[Y/n]` |
| Terminal, candidate only | asks "continue with the HALPI2 setup anyway? `[y/N]`" before installing anything; on yes proceeds as confirmed |
| No terminal, controller confirmed | installs and writes without a prompt |
| No terminal, candidate only | prints the manual recipe and stops before the Hat Labs packages (only `i2c-tools` was installed for the probe), exit 1 |
| `SIGNALK_HALPI2=yes` | no prompts; installs and writes even when the probe could not run (the Compute Module 5 check still applies) |
| `SIGNALK_HALPI2=no` | skips the whole step |

Order inside `apply`: `i2c-tools` (Debian) → live I2C enable + probe → the confirmation gate above → Hat Labs repo + packages → config.txt → `i2c-dev.conf`, networkd file, udev rule, groups. Declining the config.txt diff after the gate still leaves the packages and the can0/i2c-dev files in place (none of them can affect a boot) and exits 1 with the recipe.

## Reboot vs. power-off

The device-tree block needs a reboot; that is why `apply` exits 2 and `install.sh` stops with "reboot and re-run". Controller firmware is different: `halpi2-firmware`'s postinst flashes it, but the controller only loads new firmware on the next full power-off — a reboot does not do it. Units produced since early 2026 ship with `auto_restart` disabled, so a `shutdown -h now` leaves the box off until someone presses the power button or cycles input power. Do the power cycle when you are next to the box; the old firmware keeps running until then. (Hat Labs' upstream note: the flash-on-install can fail silently on some releases — HALPI2-firmware issue #40 — so compare `halpi status` with the package version after a power cycle.)

## Migrating from HaLOS

HaLOS runs Signal K as a container app with its data under `/var/lib/container-apps/marine-signalk-server-container/data/data`. Copy that directory to `~/.signalk` on the new Raspberry Pi OS install before running the installer; the migrated `settings.json` already contains `halpi2-nmea2000` and `halpi2-rs485`, and `signalk halpi2 connections` lists the existing ids first and adds nothing. HaLOS itself does not preinstall `blinkenlights-daemon`; this installer does (`SIGNALK_HALPI2_BLINKENLIGHTS=no` opts out), with the upstream default configuration.

## Blinkenlights

`blinkenlights-daemon` starts with a CPU-load bar and a red flash above 90 %. The reference configurations under `/usr/share/blinkenlights/examples/` (`marine-basic.toml`: supercap/V_in bar, N2K activity, GPS status; `marine-full.toml`: rotating marine pages) can point at this stack's Signal K on `http://127.0.0.1:80` (or `:3000` when standard ports were declined). Switching:

```bash
sudo rm -f /etc/blinkenlights/sources/*.toml /etc/blinkenlights/displays/*.toml
sudo cp /usr/share/blinkenlights/examples/marine-basic.toml /etc/blinkenlights/blinkenlights.toml
sudo systemctl restart blinkenlights-daemon
```

## Verifying

```bash
signalk halpi2 status                 # one screen: board, packages, units, config, can0, ttyAMA4, connections
halpi status                          # controller state, voltages, firmware version (group halpid; re-login once)
ip -br link show can0                 # UP after the reboot
candump can0                          # NMEA 2000 frames when a bus is attached
ls -l /dev/ttyAMA4                    # the RS-485 port
systemctl status halpid blinkenlights-daemon
```

## Optional GNSS HAT (gpsd on UART0)

Not installed or configured by this installer — `signalk halpi2 apply` writes
`uart4-pi5` for RS-485 and nothing for UART0. This is the manual recipe for a
u-blox receiver (e.g. a Waveshare MAX-M8Q) on the HALPI2's UART0, contributed
by a HALPI2 operator and checked against the packages it names.

**1. Enable UART0 and free it from the serial console.** On Raspberry Pi OS,
`sudo raspi-config` → *Interface Options* → *Serial Port* → login shell **no**,
serial hardware **yes**. On plain Debian there is no `raspi-config`: add
`enable_uart=1` to `/boot/firmware/config.txt` and remove any
`console=serial0,115200` from `/boot/firmware/cmdline.txt` (keep it one line).
Either way, reboot and confirm `/dev/ttyAMA0` exists and no getty holds it.

**2. Install gpsd.**

```bash
sudo apt install -y gpsd gpsd-clients
```

**3. Point gpsd at the receiver.** Edit `/etc/default/gpsd`:

```sh
DEVICES="/dev/ttyAMA0"
GPSD_OPTIONS="-s 115200"
USBAUTO="true"
```

Set `-s 9600` instead if you skip step 4 — that is the receiver's factory rate.

**4. Optional: marine auto-configuration.** ROM-based u-blox modules like the
MAX-M8Q have no backup battery and lose their settings on every power cycle, so
the rate and dynamic model have to be reapplied at each boot. Hat Labs packages
that as `halos-ublox-config`, usable without a full HaLOS image:

The repository is suited per Debian release; derive it rather than hardcoding
`trixie`, and check the suite exists before adding the source:

```bash
SUITE=$(. /etc/os-release && echo "$VERSION_CODENAME")
curl -fsSL "https://apt.halos.fi/dists/${SUITE}-stable/Release" -o /dev/null \
    || echo "no halos suite for ${SUITE} — skip this step"
curl -fsSL https://apt.halos.fi/halos-apt-key.asc \
    | sudo gpg --dearmor -o /usr/share/keyrings/halos.gpg
echo "deb [signed-by=/usr/share/keyrings/halos.gpg] https://apt.halos.fi ${SUITE}-stable main" \
    | sudo tee /etc/apt/sources.list.d/halos.list
sudo apt update && sudo apt install -y halos-ublox-config
```

It installs `configure-ublox-marine.service`, a `Before=gpsd.service` oneshot
that reads `DEVICES` from `/etc/default/gpsd`, probes each device at 115200 and
9600, and sets 115200 baud, a 100 ms rate (10 Hz) and dynamic model 5 (Sea).
It **reads** `/etc/default/gpsd` and never writes it, so step 3 is still
required. Verify with `systemctl status configure-ublox-marine.service` and
`gpspipe -r -n 5`.

This is a third-party repository run by the HaLOS developer, not by this
project and not by Debian. Skipping step 4 leaves the receiver at its factory
defaults (9600 baud, 1 Hz), which Signal K reads fine.

**5. Add the Signal K connection.** Admin UI → *Server* → *Connections* → *Add*,
data type NMEA 0183, source `gpsd`, host `localhost`, port `2947`.

## Troubleshooting

**"Compute Module 5 detected but the HALPI2 controller did not answer at I2C
0x6d" on a genuine HALPI2.** Most often the probe tool is missing rather than
the controller silent: `apply` installs `i2c-tools` first, but `apt-get install
-y -qq` exits 0 even when it resolves nothing from a stale index, so a failed
install used to pass unnoticed and the probe then failed on the absent
`i2ctransfer`. It now says so explicitly; `sudo apt-get update && sudo apt-get
install i2c-tools`, then re-run.

Otherwise the bus itself is not up yet. `apply` enables it live before probing
(`dtparam i2c_arm=on`, which on a Pi also brings in `i2c-dev`), but where the
firmware refuses that at runtime the bus stays off until the `config.txt` block
is written and the box rebooted — and `halpid` is not installed at that point
either, so neither detection rung can answer. Answering `y` there is the
documented candidate path and is correct on real HALPI2 hardware: the reboot
brings up both rungs and the next run confirms the board via `halpid`.

**Asked for boat name, MMSI and credentials on every run.** Older installers
prompted before the reboot gates, and neither answer is written to disk until
much later in the run, so each reboot cycle discarded them. Nothing is wrong
with the answers — the run never got far enough to save them. Re-running after
the final reboot keeps whatever the last completed run stored.

## Out of scope

- Flashing controller firmware from this helper (`halpi flash`); the package postinst owns that.
- CAN-FD data-phase bitrates; the MCP2518FD runs classical CAN at 250 kbit/s for NMEA 2000, same as `docs/socketcan.md`.
- HALPI (first generation, Pi 4 + SH-RPi) and other CM5 carriers.
