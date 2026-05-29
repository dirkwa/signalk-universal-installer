# SocketCAN HAT setup on Raspberry Pi

A guided setup helper for getting NMEA 2000 (or other CAN) buses talking to SignalK on a Pi. Targets the four common ways to put a CAN port on a Pi: dual-channel Waveshare, marine PiCAN-M / PiCAN3, generic single-channel MCP2515 boards, and USB CAN adapters.

`signalk socketcan` is a **detect-and-advise** helper. It will not edit `/boot/firmware/config.txt` for you in v1 — a wrong `dtoverlay=` line can prevent the Pi from booting, and the blast radius of config.txt mistakes is bigger than the cmdline.txt patch the installer already does. The command tells you exactly what to add; you run sudo.

## TL;DR

```bash
signalk socketcan          # interactive — pick your HAT, get the recipe
signalk socketcan status   # what's currently detected (no prompts)
signalk socketcan help     # usage
```

The interactive flow:

1. Detects whether you're on a Pi and what config.txt / kernel modules / CAN interfaces are present.
2. Asks which HAT you have (numbered menu).
3. Prints a numbered, copy-pasteable recipe: the `dtoverlay=` line(s) for `config.txt`, a `systemd-networkd` `.network` file for the NMEA 2000 bitrate, and verification commands.
4. Records the chosen HAT in `~/.signalk-updater/hardware.json` under a `socketcanCandidate` field so the bug-report bundle (and, later, the updater UI) can see it.

## Supported HATs

| Menu | HAT | Driver | Bus |
|---|---|---|---|
| 1 | Waveshare 2-CH CAN HAT | `mcp251x` (dual MCP2515 on SPI) | Classical CAN |
| 2 | PiCAN-M / PiCAN3 | `mcp251xfd` (MCP251xFD on SPI) | CAN-FD (v1 recipe uses classical 250k) |
| 3 | Generic MCP2515 (PiCAN2, RS485-CAN-HAT, AliExpress boards) | `mcp251x` (single MCP2515 on SPI) | Classical CAN |
| 4 | USB CAN (gs_usb / Peak / Kvaser / SLCAN) | matching USB-CAN kernel driver | Classical CAN |
| 5 | Custom dtoverlay | you supply the line(s) | — |

### Waveshare 2-CH CAN HAT — what the recipe gives you

```text
1. Add to /boot/firmware/config.txt (requires sudo + reboot):

     dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=25
     dtoverlay=mcp2515-can1,oscillator=16000000,interrupt=24
     dtoverlay=spi-bcm2835-overlay

2. sudo reboot

3. Persist the NMEA 2000 bitrate:

     sudo tee /etc/systemd/network/80-signalk-can0.network > /dev/null <<'EOF'
     [Match]
     Name=can0

     [CAN]
     BitRate=250000
     EOF

     sudo systemctl enable --now systemd-networkd

4. Verify:

     ip -br link show type can
     candump can0
```

### PiCAN-M / PiCAN3 (MCP251xFD)

Same shape; just one dtoverlay (the chip is CAN-FD capable but the v1 recipe configures classical CAN at 250 kbit/s for NMEA 2000 compatibility):

```text
dtoverlay=mcp251xfd-spi0-0,oscillator=20000000,interrupt=25
```

CAN-FD data-bitrate support (e.g. 2 Mbit/s on the data phase) is a v2 follow-up.

### Generic single-channel MCP2515

The interactive prompt asks for the oscillator frequency (8 MHz or 16 MHz, default 16 MHz — most boards) and emits:

```text
dtoverlay=mcp2515-can0,oscillator=<frequency>,interrupt=25
```

### USB CAN adapter

No `config.txt` edit — the kernel auto-loads the driver when the device is plugged in. The recipe is just the networkd `.network` file from step 3 above.

### Custom dtoverlay

For unusual boards: enter your own `dtoverlay=` line(s), one per line, terminate with a blank line. Useful for non-standard interrupt pins or chip-select wiring.

## Why systemd-networkd for bitrate persistence?

`ip link set can0 up type can bitrate 250000` works immediately but is RAM-only — resets on reboot. The persistent options are:

- **`systemd-networkd` `.network` file with `[CAN] BitRate=`** — recommended. Pi OS Trixie defaults to NetworkManager; NetworkManager ignores CAN interfaces (it only manages WiFi/ethernet/bluetooth), so enabling networkd for `can0` does not conflict. networkd is already installed; one `systemctl enable --now systemd-networkd` and the file from step 3 above is what's needed.

- **Custom `systemd-system` service unit** running `ip link set can0 up type can bitrate 250000` on boot. Alternative if you'd rather not enable networkd at all:

  ```ini
  # /etc/systemd/system/signalk-can0.service
  [Unit]
  Description=Bring up can0 at NMEA 2000 bitrate
  After=sys-subsystem-net-devices-can0.device
  Requires=sys-subsystem-net-devices-can0.device

  [Service]
  Type=oneshot
  ExecStart=/usr/sbin/ip link set can0 up type can bitrate 250000
  RemainAfterExit=yes

  [Install]
  WantedBy=multi-user.target
  ```

  Then `sudo systemctl enable --now signalk-can0.service`.

- **`/etc/network/interfaces.d/` snippet** — possible but Pi OS uses NetworkManager, so this is not picked up by default. Skipped in v1.

## Verifying

After applying the recipe and rebooting:

```bash
# Interface present and UP at 250k?
ip -br link show type can
# Expected: can0   UP   <bitrate>250000</bitrate>

# Are NMEA 2000 frames arriving?
# (install can-utils once: sudo apt install can-utils)
candump can0
# Expected: a stream of frames; PGNs in the 60000-130999 range are
# typical NMEA 2000 messages from the bus.
```

Re-running `signalk socketcan status` after this will show `socketcanCandidate.configApplied=true` and `socketcanCandidate.ipLinkUp=true` in `~/.signalk-updater/hardware.json`.

## Wiring SignalK to the can0 interface

`signalk socketcan` only configures the kernel side. To plug `can0` into SignalK's data flow you still need to add a Connection in the SignalK admin UI:

1. Open the SignalK admin at `http://<your-pi>/admin/`.
2. **Server → Connections → Add**.
3. **Input Type:** NMEA 2000.
4. **NMEA 2000 source:** `canbus-canboatjs` (or `socketcan-canboatjs` depending on server version).
5. **Interface:** `can0`.
6. Save and enable.

You should see PGNs appearing in the **Data Browser** within seconds.

## Troubleshooting

**`status` says "No CAN interface present" after reboot** — the dtoverlay didn't load. Check `dmesg | grep -iE 'mcp25|spi'` for errors. Common causes: wrong oscillator frequency for your board (try 8 MHz instead of 16 MHz on cheap clones), wrong interrupt pin (PiCAN variants use GPIO13, not 25), SPI not enabled (some HATs need `dtparam=spi=on` in addition to the dtoverlay).

**`candump` shows nothing but the interface is UP** — likely a wiring issue (CAN-H/CAN-L swapped, missing termination on a long bus, no other devices powered). On a properly-terminated NMEA 2000 backbone with at least one transmitting device, `candump` should show frames within a second or two.

**`signalk bug-report` for context** — include `hardware-raw.txt` (added in PR #71) which shows your loaded modules, ip link state, and config.txt dtoverlay lines all in one place. Plus `socketcanCandidate` from `hardware.json` if you ran `signalk socketcan`.

## Out of scope (today)

- **Auto-applying the config.txt patch with sudo prompt.** v2 candidate. The cmdline.txt patch the installer already does is a precedent, but config.txt's blast radius (HDMI, memory split, GPIO pinmux) is wider.
- **CAN-FD data bitrate.** v1 uses classical CAN @ 250 kbit/s. PiCAN-M / PiCAN3 hardware supports CAN-FD with a separate data bitrate (2 Mbit/s, 4 Mbit/s, 5 Mbit/s); needs more options on the networkd side and is a follow-up.
- **Non-Pi Linux.** SocketCAN works on any Linux, but the device-tree overlay path is Pi-specific. x86 Linux with a USB CAN adapter is supported via menu option 4 (no overlay needed), but the helper still gates on `/proc/device-tree/model` containing "raspberry pi". Loosening that is a separate PR if there's demand.
