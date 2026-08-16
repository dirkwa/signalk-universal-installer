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

1. Run the usual one-liner. On a Compute Module 5 the installer probes the HALPI2 controller at I2C address `0x6d`, shows the proposed `config.txt` change, installs the packages, and stops with "reboot and re-run this installer".
2. `sudo reboot`.
3. Run the one-liner again. `can0`, `/dev/ttyAMA4` and `halpid` are live now; the normal hardware detection records them, the server Quadlet gets `AddDevice=/dev/ttyAMA4` and the `/run/halpid` mount, and step 15c creates the two Signal K connections.

Existing install: `signalk halpi2 apply`, reboot, `signalk hardware rescan`, `signalk halpi2 connections`.

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

`dtparam=sd=off` is what HaLOS ships to avoid a shutdown stall long enough to drain the supercapacitors (raspberrypi/linux#7014). It also disables the microSD slot and, on a CM5 with eMMC, the eMMC. The helper writes it only when neither `/` nor `/boot/firmware` is on `/dev/mmcblk*`; on an SD/eMMC-booted system the block carries a comment saying the line was omitted.

## How detection works

`detect-hardware.sh` (and `signalk halpi2 detect`) is passive — no sudo, no writes:

1. `/proc/device-tree/model` contains "Compute Module 5" → the box is a *candidate* (`board.candidate: true`, `detectedVia: "model-string"`). Other CM5 carriers exist, so this alone never triggers a write.
2. `systemctl is-active halpid` → confirmed (`detectedVia: "halpid"`).
3. `/dev/i2c-1` readable and `i2ctransfer -y 1 w1@0x6d 0x04 r4` answers → confirmed (`detectedVia: "i2c"`, `firmwareVersion` / `hardwareVersion` filled in). This is the same write-register-then-read-4-bytes transaction `halpid` uses.

`signalk halpi2 apply` runs the same ladder after installing `i2c-tools`, and — when `/dev/i2c-1` is missing and `dtparam` exists (Raspberry Pi OS) — enables I2C live with `dtparam i2c_arm=on` + `modprobe i2c-dev` first, exactly what raspi-config does, so a first run can confirm the board before the reboot.

hardware.json then carries:

```json
"board": { "model": "halpi2", "candidate": false, "detectedVia": "i2c",
           "hardwareVersion": "2.0.0", "firmwareVersion": "3.3.1" },
"onboardSerial": [ { "device": "/dev/ttyAMA4", "label": "HALPI2 RS-485", "enabled": true } ]
```

`onboardSerial` is opt-out like USB serial; its `enabled` survives a re-detect. `board` is a hardware fact and is regenerated every time. The renderer emits `AddDevice=/dev/ttyAMA4` (existence-guarded, like USB serial) and `Volume=/run/halpid:/run/halpid:rw` (only while `/run/halpid/halpid.sock` exists), so the `signalk-halpi` plugin from the App Store can read the controller's voltages, temperatures and state.

## Why this helper edits config.txt when `signalk socketcan` only prints a recipe

`docs/socketcan.md` keeps config.txt hands-off because the overlay there is the operator's guess for an unknown HAT. Here the overlay set is fixed for one board, the board has answered at I2C `0x6d` before anything is written, the one line that can make a box unbootable (`sd=off`) is dropped when the boot device is SD/eMMC, and the write follows `preflight.sh`'s cmdline.txt pattern: `diff -u` preview, confirm, timestamped `cp -p` backup, post-write check (exactly one marker pair, no lines lost outside the block), restore on failure.

Prompt behaviour:

| Situation | What `apply` does |
|---|---|
| Terminal, controller confirmed | installs the packages, shows the config.txt diff, asks `[Y/n]` |
| Terminal, candidate only | asks "continue with the HALPI2 setup anyway? `[y/N]`" before installing anything; on yes proceeds as confirmed |
| No terminal, controller confirmed | installs and writes without a prompt |
| No terminal, candidate only | prints the manual recipe, installs and changes nothing, exit 1 |
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

## Out of scope

- Flashing controller firmware from this helper (`halpi flash`); the package postinst owns that.
- The optional MAX-M8Q GNSS HAT (`dtparam=uart0=on`, gpsd on `/dev/ttyAMA0`, `halos-ublox-config`).
- CAN-FD data-phase bitrates; the MCP2518FD runs classical CAN at 250 kbit/s for NMEA 2000, same as `docs/socketcan.md`.
- HALPI (first generation, Pi 4 + SH-RPi) and other CM5 carriers.
