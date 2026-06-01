# SocketCAN HAT setup on Raspberry Pi (and beyond)

A guided setup helper for getting NMEA 2000 (or other CAN) buses talking to SignalK. Targets the seven common ways to put a CAN port on the host: dual-channel Waveshare (classic MCP2515), dual-channel Waveshare CAN FD (MCP2518FD), marine PiCAN-M / PiCAN3, generic single-channel MCP2515 boards, SocketCAN-native USB CAN adapters, SLCAN serial-mode USB adapters, and custom dtoverlays. The first four and the custom dtoverlay (option 7) are Pi-only (they edit `/boot/firmware/config.txt`); the USB-CAN and SLCAN paths work on any Linux.

`signalk socketcan` is a **detect-and-advise** helper. It will not edit `/boot/firmware/config.txt` for you — a wrong `dtoverlay=` line can prevent the Pi from booting, and the blast radius of config.txt mistakes is bigger than the cmdline.txt patch the installer already does. The command tells you exactly what to add; you run sudo.

## TL;DR

```bash
signalk socketcan          # interactive — pick your adapter, get the recipe
signalk socketcan status   # what's currently detected (no prompts)
signalk socketcan help     # usage
```

The interactive flow:

1. Detects whether you're on a Pi and what config.txt / kernel modules / CAN interfaces are present.
2. Asks which CAN adapter you have (numbered menu).
3. Prints a numbered, copy-pasteable recipe — config.txt edits (Pi only) or a systemd unit (SLCAN), and a `systemd-networkd` `.network` file for the bitrate.
4. Records the operator's choice in `~/.signalk-updater/hardware.json` under a `socketcanCandidate` field for downstream consumers (the bug-report bundle and, later, an auto-installer / updater UI). This is the operator's stored *intent*, not a live probe.

`signalk socketcan status` is the inverse: it derives a "Detected configuration" from the live config.txt + loaded kernel modules + interface state every run. The detection never reads `socketcanCandidate`, so it cannot go stale relative to what the kernel is actually doing. Use status to ask "what's running right now?", and the persisted candidate to ask "what did the operator last pick?".

## Supported adapters

| Menu | Adapter | Pi-only? | Driver |
|---|---|---|---|
| 1 | Waveshare 2-CH CAN HAT | Yes | `mcp251x` (dual MCP2515 on SPI) |
| 2 | Waveshare 2-CH CAN FD HAT | Yes | `mcp251xfd` (dual MCP2518FD, one per SPI bus) |
| 3 | PiCAN-M / PiCAN3 (marine NMEA 2000) | Yes | `mcp251x` (single MCP2515 on SPI) |
| 4 | Generic single-channel MCP2515 (PiCAN2, RS485-CAN-HAT, AliExpress boards) | Yes | `mcp251x` |
| 5 | USB CAN — SocketCAN-native (gs_usb / Peak / Kvaser) | No | matching USB driver, autoloads |
| 6 | SLCAN (Lawicel CANUSB serial mode, CANable slcan firmware) | No | `slcan` line discipline via `slcand` |
| 7 | Custom dtoverlay | Yes | you supply the line(s) |

> **Heads-up: PiCAN-M and PiCAN3 use the classical MCP2515, not the MCP251xFD.** Some earlier guides (including a previous version of this helper) suggested an `mcp251xfd-spi0-0` overlay for these adapters — wrong chip family, and `mcp251xfd-spi0-0` isn't a real overlay name. If you applied that recipe, `can0` will never come up. The correct overlay is `dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=25`. The `mcp251xfd` driver does have a legitimate home here — the **Waveshare 2-CH CAN FD HAT** (menu option 2 below) — but those boards carry the MCP2518FD chip, not the MCP2515 the Copperhill marine boards use.

### 1. Waveshare 2-CH CAN HAT

```text
1. Add to /boot/firmware/config.txt (requires sudo + reboot):

     dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=23
     dtoverlay=mcp2515-can1,oscillator=16000000,interrupt=25

2. sudo reboot

3. Persist the NMEA 2000 bitrate (systemd-networkd):

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

> **Heads-up: interrupt pins.** Waveshare's factory solder default is **INT_0 = GPIO23, INT_1 = GPIO25**. The earliest `signalk socketcan` release used `25/24` (a Copperhill PiCAN-dual convention) by mistake. If your `can0` looks `UP` but `candump` shows no frames, this is the symptom — re-edit config.txt with the correct pins above and reboot. Users who reworked the 0-ohm jumpers on the HAT can override via menu option 7 (custom dtoverlay).
>
> Note these GPIO23/25 pins are for the **classic MCP2515** board. The CAN **FD** sibling (option 2) is a different board with a different default pinout (GPIO25 + GPIO24) — don't cross-apply the recipes.
>
> `dtparam=spi=on` and `dtoverlay=spi-bcm2835-overlay` are NOT needed — the `mcp2515-can*` overlay auto-enables SPI, and `spi-bcm2835-overlay` is not a real overlay (it was on Waveshare's wiki at one point; the upstream Raspberry Pi overlays README has no such entry).

### 2. Waveshare 2-CH CAN FD HAT

The CAN **FD** sibling of option 1. It carries two **MCP2518FD** controllers (`mcp251xfd` driver, not `mcp251x`), and — unlike the classic board, where both MCP2515s share `spi0` via CE0/CE1 — each FD controller sits on its **own SPI bus** (`spi0.0` and `spi1.0`). That second bus must be enabled with `dtoverlay=spi1-3cs` before the `can1` overlay can bind.

```text
1. Add to /boot/firmware/config.txt (requires sudo + reboot):

     dtparam=spi=on
     dtoverlay=spi1-3cs
     dtoverlay=mcp251xfd,spi0-0,interrupt=25
     dtoverlay=mcp251xfd,spi1-0,interrupt=24

2. sudo reboot

3. Persist the NMEA 2000 bitrate (systemd-networkd):

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

> **Heads-up: this board differs from the classic MCP2515 HAT in three ways.** (1) Chip family — MCP2518FD, so the driver is `mcp251xfd` and the overlay name is `mcp251xfd`, not `mcp2515-can*`. (2) Two SPI buses — the `dtoverlay=spi1-3cs` line is mandatory; without it only `can0` (on `spi0`) appears and `can1` never binds. (3) **No `oscillator=` parameter** — the `mcp251xfd` device-tree default already matches the 40 MHz crystal Waveshare fits (the driver's init log confirms `o:40.00MHz`); adding `oscillator=` here is wrong. The factory interrupt pins are `spi0-0 → GPIO25` and `spi1-0 → GPIO24`. `dtparam=spi=on` is listed explicitly because, unlike `mcp2515-can*`, the bare `spi1-3cs` overlay does not imply the primary SPI controller is enabled.
>
> These recipes use **classical CAN at 250 kbit/s** (NMEA 2000), which the FD controller speaks natively. CAN-FD's higher data-phase bitrate is out of scope (see the end of this doc).

For a single-channel CAN-FD board (Copperhill PiCAN FD, PiCAN FD Duo), use just the `can0` half: `dtparam=spi=on` + `dtoverlay=mcp251xfd,spi0-0,interrupt=25` (no `spi1-3cs`, no second overlay).

### 3. PiCAN-M / PiCAN3 (marine NMEA 2000)

Both Copperhill boards ship the **MCP2515** (not MCP251xFD), per Copperhill's own driver-install blog:

```text
dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=25
```

Rest of the recipe is the same as Waveshare from step 2 onward.

Copperhill's CAN-FD boards (PiCAN FD) use the MCP2518FD instead — see option 2's single-channel note for that overlay.

### 4. Generic single-channel MCP2515

The interactive prompt asks for the oscillator frequency (8 MHz or 16 MHz, default 16 MHz — most boards) and emits:

```text
dtoverlay=mcp2515-can0,oscillator=<frequency>,interrupt=25
```

Boards with unusual oscillators (12 MHz, 20 MHz) belong on menu option 7 (custom dtoverlay) where you type the whole line yourself.

### 5. USB CAN — SocketCAN-native

For gs_usb / candleLight / CANable in candleLight firmware mode, Peak PCAN-USB (`peak_usb`), Kvaser Leaf/USBcan (`kvaser_usb`). The kernel driver autoloads on USB enumeration via modalias; `canX` appears as a netdev with no userspace daemon.

No `config.txt` edit, **no Pi required** — works on x86, ARM, anywhere with mainline Linux.

The recipe is just the systemd-networkd `.network` file from the Waveshare section above (step 3). Plug the adapter in, write the file, reboot or `systemctl restart systemd-networkd`.

### 6. SLCAN (serial-mode USB)

Lawicel CANUSB in serial mode, CANable in slcan firmware, generic FTDI/ACM serial CAN bridges. SLCAN is a **line discipline**: the kernel will not create `canX` until `slcand` (from `can-utils`) attaches it to a `/dev/tty*` node.

No `config.txt` edit, **no Pi required**. The recipe installs `can-utils` and a systemd-system service unit that runs `slcand` and brings `can0` up:

```text
1. Install can-utils (package name is `can-utils` on every major distro):

     Debian / Ubuntu / Raspberry Pi OS:  sudo apt install -y can-utils
     Fedora / RHEL / CentOS Stream:      sudo dnf install -y can-utils
     Arch / Manjaro:                     sudo pacman -S can-utils
     openSUSE:                           sudo zypper in can-utils

2. Create a systemd unit:

     sudo tee /etc/systemd/system/signalk-slcan-can0.service > /dev/null <<'EOF'
     [Unit]
     Description=SLCAN can0 (NMEA 2000 250 kbit/s)

     [Service]
     Type=simple
     ExecStartPre=/bin/sh -c 'i=0; while [ ! -e /dev/serial/by-id/<your-adapter> ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done; [ -e /dev/serial/by-id/<your-adapter> ]'
     ExecStart=/usr/bin/slcand -F -o -c -s5 /dev/serial/by-id/<your-adapter> can0
     ExecStartPost=ip link set up can0
     Restart=on-failure
     RestartSec=5

     [Install]
     WantedBy=multi-user.target
     EOF

     sudo systemctl daemon-reload
     sudo systemctl enable --now signalk-slcan-can0.service

3. Verify:

     systemctl status signalk-slcan-can0.service
     ip -br link show type can
     candump can0
```

The interactive flow autodetects the tty path (one `/dev/serial/by-id/*` entry → suggested as default; multiple → operator picks one).

slcand bitrate codes: `0`=10k `1`=20k `2`=50k `3`=100k `4`=125k `5`=250k `6`=500k `7`=800k `8`=1000k. NMEA 2000 is 250k → `-s5`. For other buses, edit the unit file.

### 7. Custom dtoverlay (Pi-only)

For unusual boards or reworked HATs: enter your own `dtoverlay=` / `dtparam=` line(s), one per line, terminate with a blank line. Useful for non-standard interrupt pins, alternate chip-select wiring, or boards we don't have a preset for.

## Why systemd-networkd for bitrate persistence?

`ip link set can0 up type can bitrate 250000` works immediately but is RAM-only — resets on reboot. The persistent options:

- **`systemd-networkd` `.network` file with `[CAN] BitRate=`** — recommended for Pi HATs + USB-native adapters. Pi OS Trixie defaults to NetworkManager; NetworkManager ignores CAN interfaces (it only manages WiFi/ethernet/bluetooth), so enabling networkd for `can0` does not conflict. networkd is already installed; one `systemctl enable --now systemd-networkd` and the `.network` file is what's needed.

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

- **The SLCAN unit (option 6)** already handles its own `ip link set up` in `ExecStartPost` — no separate networkd file needed for SLCAN.

## Why the Waveshare wiki's `bcm2835` library is NOT required

The Waveshare 2-CH CAN HAT wiki recommends compiling and installing `bcm2835-1.60.tar.gz` (a Mike McCauley userspace GPIO/SPI library). **This is only needed for Waveshare's bundled C example programs** in `2-CH_CAN_HAT_Code/`. SocketCAN does not use it — the `mcp251x` kernel driver talks to the chip via `/dev/spidev*` and has zero dependency on the bcm2835 library. Skip the `wget` / `make` / `sudo make install` block; the recipe above is sufficient.

`mcp251x` and `mcp251xfd` also do NOT need any firmware blob. Verified in the kernel source: neither driver calls `request_firmware()`.

## Verifying

After applying the recipe and rebooting (Pi HATs) or starting the service (USB-CAN / SLCAN):

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

Re-running `signalk socketcan status` after this should show the matching HAT under "Detected configuration" with no warning — for example, a Waveshare 2-CH with the factory pins (23/25) reports `Waveshare 2-CH CAN HAT — factory solder defaults`, and a Waveshare with the older buggy pins (24/25) gets flagged with an actionable warning. The CAN **FD** board is recognised by its two `mcp251xfd` overlays and reports `Waveshare 2-CH CAN FD HAT (dual MCP2518FD) — factory solder defaults (spi0-0=25, spi1-0=24)`; a single `mcp251xfd` overlay reports the single-channel CAN-FD case instead. The detection works off live config.txt + lsmod + ip link, so it's always current; it deliberately ignores the persisted `socketcanCandidate` (which records the operator's last interactive pick, not the running state).

## Wiring SignalK to the can0 interface

`signalk socketcan` only configures the kernel side. To plug `can0` into SignalK's data flow you still need to add a Connection in the SignalK admin UI:

1. Open the SignalK admin at `http://<your-host>/admin/`.
2. **Server → Connections → Add**.
3. **Input Type:** NMEA 2000.
4. **NMEA 2000 source:** `canbus-canboatjs` (or `socketcan-canboatjs` depending on server version).
5. **Interface:** `can0`.
6. Save and enable.

You should see PGNs appearing in the **Data Browser** within seconds.

## Troubleshooting

**`status` says "No CAN interface present" after reboot** — the dtoverlay didn't load. Check `dmesg | grep -iE 'mcp25|spi'` for errors. Common causes: wrong oscillator frequency for your board (try 8 MHz instead of 16 MHz on cheap clones), wrong interrupt pin (see Waveshare 23/25 vs 25/24 note above; PiCAN variants are 25 by default).

**`candump` shows nothing but the interface is UP** — likely a wiring issue (CAN-H/CAN-L swapped, missing termination on a long bus, no other devices powered) — OR you're hit by the Waveshare wrong-pins regression (recipe `25/24` instead of `23/25`). On a properly-terminated NMEA 2000 backbone with at least one transmitting device, `candump` should show frames within a second or two.

**SLCAN service flapping** — `systemctl status signalk-slcan-can0.service` shows the journal slice. Check that `/dev/serial/by-id/<your-adapter>` actually exists; the `ExecStartPre` loop in the unit waits for it but won't give up. If the adapter never enumerates, `lsusb` and `dmesg | tail` will tell you why.

**`signalk bug-report` for context** — the bundle's `hardware-raw.txt` shows your loaded modules, ip link state, and config.txt dtoverlay lines all in one place. Plus `socketcanCandidate` from `hardware.json` if you ran `signalk socketcan`.

## Out of scope (today)

- **Auto-applying the config.txt patch with sudo prompt.** The cmdline.txt patch the installer already does is a precedent, but config.txt's blast radius (HDMI, memory split, GPIO pinmux) is wider.
- **CAN-FD data-phase bitrate.** Option 2 (Waveshare CAN FD HAT) runs its MCP2518FD controllers in **classical CAN @ 250 kbit/s** — the right mode for NMEA 2000, which is not an FD bus. True CAN-FD with a faster data phase (2 / 4 / 5 Mbit/s on top of the 250k/500k arbitration phase) is still out of scope: it needs a `[CAN] DataBitRate=` / `FDMode=` block on the networkd side and is only useful on non-NMEA-2000 FD buses.
- **Auto-discovering SLCAN tty when more than one is plugged in.** The current flow asks the operator to paste a full path. A future version might offer a numbered sub-menu.
