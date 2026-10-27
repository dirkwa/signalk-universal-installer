# Kiosk: boot a screen straight into the Signal K GUI

`signalk kiosk` turns a Linux box with a monitor or touchscreen attached into a dedicated Signal K display: at power-on it shows a Signal K page full-screen, already signed in, with no desktop, no login prompt and no browser controls. Written for Raspberry Pi OS and Debian Trixie; Linux only.

The installer puts the helper at `~/.local/bin/signalk-kiosk`. On a box installed before the kiosk existed, `signalk update` adds it once the box runs signalk-doctor-server 1.1.0 or later (the doctor updates from the Updater Console). If `signalk update` reports `signalk-kiosk mount-missing`, the doctor cannot write to `~/.local/bin`; re-running the installer's bash one-liner adds that mount and the helper.

## TL;DR

```bash
signalk kiosk scan             # connected monitors and touchscreens (no sudo)
signalk kiosk enable              # install, sign the kiosk in, boot into App Dock (sudo)
signalk kiosk enable --readwrite  # Freeboard-SK instead, and no reach into the server's settings
signalk kiosk status           # scan + what the kiosk shows, how it signs in, whether it runs
signalk kiosk restart          # restart the browser, e.g. after installing a webapp
signalk kiosk disable          # put the boot back and revoke the kiosk's sign-in (sudo)
```

`enable` shows [App Dock](https://github.com/SignalK/app-dock) (`/@signalk/app-dock/`), which switches between webapps — double-tap the screen to bring it up. Installed by `enable`, it starts with Freeboard-SK, opened at once, RPI Manager (the computer's health and its restart, reboot and power-off buttons) when the installer has installed it, and Settings, the Admin UI, as the last entry. `--readwrite` opens Freeboard-SK instead (see below). To show another page on this server, pass its path: `signalk kiosk enable --url /@signalk/freeboard-sk/`.

## What `enable` does

1. Installs `cage`, `chromium` (the distro package — `chromium-browser` on Raspberry Pi OS Bookworm; on Raspberry Pi OS also `rpi-chromium-mods`), `jq`, `fonts-noto-color-emoji` and, unless given `--no-screen-pause`, `i2c-tools` with apt, without Recommends, skipping what is already there.
2. Creates an unprivileged system user, `signalk-kiosk`, with its home at `/var/lib/signalk-kiosk`. The browser runs as this user, not as the user that owns `~/.signalk` and the podman socket.
3. Installs App Dock through the server's App Store when App Dock is the page and is not installed. Before its first start, `enable` writes the app list described above. An App Dock that is already installed keeps its own list; if it is switched off, `enable` says so and leaves it off. If App Dock was the default page and cannot be installed, the kiosk shows Freeboard-SK instead; one asked for with `--url` stays.
4. Sets up the sign-in (next section): the Signal K user `signalk-kiosk`, its token, and the signalk-autologin plugin. Skip with `--no-autologin`.
5. Restarts the server when step 3 or 4 installed something, since the server loads a newly installed package only when it starts.
6. Writes the files in the table below and enables `signalk-kiosk.service`, and the service that pauses the browser while the monitor is off ([Monitor off](#monitor-off)).
7. Disables the desktop login if the box has one, and starts the kiosk — immediately on a box without a desktop, at the next reboot on one with a desktop still running.

The App Store installs and the sign-in go through the server's admin API with the installer's admin token, `~/.signalk-doctor/signalk-token`. Without that file, `enable` still sets up the kiosk, which then opens its page signed out.

| Path | Purpose |
|---|---|
| `/etc/systemd/system/signalk-kiosk.service` | Runs cage with the launcher on tty1 as `signalk-kiosk`, restarts it whenever it exits, and takes tty1 from the console login. |
| `/etc/systemd/system/user-<uid>.slice.d/50-signalk-kiosk.conf` | `CPUWeight=50` on the `signalk-kiosk` user's slice, where cage and the browser run (logind's session scope and the kiosk user's own systemd both sit under it). The Signal K server runs in its owner's slice next to it at the default weight of 100, so under CPU contention the browser yields to the server. `enable` also applies the weight to the running slice with `systemctl set-property --runtime`. |
| `/etc/pam.d/signalk-kiosk` | The PAM stack the unit opens its session with. systemd never calls `pam_authenticate` for a service, so nothing asks for a password; `pam_systemd` registers the session on seat0, which is what lets cage open the display and input devices. |
| `/etc/udev/rules.d/61-signalk-kiosk-cec.rules` | Makes the Raspberry Pi's HDMI-CEC inputs keyboards instead of pointers (see [Touchscreens](#touchscreens)). Matches nothing on other hardware. |
| `/usr/local/lib/signalk-kiosk/browser` | The launcher cage runs: waits for the server, clears the crash marker, adds touch flags, writes the sign-in start page, starts the browser. |
| `/etc/signalk-kiosk.conf` | The page, browser, sign-in mode and colour scheme the launcher uses, plus what `disable` has to undo (the desktop login unit, whether the kiosk installed or switched on signalk-autologin, whether it created the Signal K user). |
| `/etc/signalk-kiosk.token` | The kiosk's sign-in token, readable by root and the `signalk-kiosk` group only. |
| `/var/lib/signalk-kiosk/start.html` | Written by the launcher at every start and readable by the kiosk user only: the page that hands the token to the server (next section). |

`installer/linux/signalk-kiosk.tmpl` renders all of these; the exact directives and modes are there.

`enable` can be re-run at any time to change `--url`, `--readwrite`, `--browser`, `--light` or `--no-screen-pause`; it keeps what the first run recorded.

## Signing in

The server runs with security enabled, so a browser that has never logged in stops at a login form — on a screen that may have no keyboard. `enable` gives the kiosk its own Signal K user instead:

- **The user.** `signalk-kiosk`, created through the admin API with no password, so the only way it can sign in is with a token. It is an admin, so Settings in App Dock opens the Admin UI signed in — and **anyone at the screen can change the server's settings, plugins and users**. Other devices still log in.
- **The token.** Signed inside the server container the way the installer signs the doctor's admin token (see [installation](installation.md)), long-lived, and stored in `/etc/signalk-kiosk.token`. `enable` checks that it signs in before it relies on it.
- **The browser.** At every start the launcher writes `start.html` into the kiosk user's home and starts the browser on it. That page opens signalk-autologin's `/signalk-autologin/seed#token=…`, which sends the token to the server once, in an `Authorization` header, and the server answers with the session cookie. The token rides in the URL fragment, which a browser never sends to the server, so it does not reach the server's request log or a `signalk bug-report` bundle; and it is never on the browser's command line, which every local user can read through `/proc`. Chromium caps a cookie's lifetime at 400 days, so signing in again at every start is also what keeps a kiosk that never reboots signed in.
- **The plugin.** [signalk-autologin](https://www.npmjs.com/package/signalk-autologin) is installed if missing and switched on if it is off, in token-sign-in-only mode: every other device still logs in as before. When `enable` installs it, it writes the plugin's configuration first, so the plugin starts in that mode. The server keeps a plugin's configuration after an uninstall, and `enable` does not overwrite one; if an earlier install's configuration brings the plugin back granting admin to every device, `enable` switches it to token sign-in only through the admin API once the server has loaded it. An installed release without token sign-in is updated. If the plugin was already installed and on, granting admin to every device — its own setting, for a trusted network — `enable` leaves that setting alone and says so; the kiosk still signs in with its own token.

### `--readwrite`

For a screen that should not reach the server's settings, `enable --readwrite` makes `signalk-kiosk` a readwrite user: webapps get live data and can write values (PUT requests), while the server's admin API answers the kiosk with 401. Its default page is Freeboard-SK rather than App Dock, which reads its app list and saves its welcome tour's dismissal only for an admin: shown to a readwrite user with `--url /@signalk/app-dock/`, App Dock falls back to its built-in app list, shows the tour at every start, and its Settings entry asks for a login.

### Other pages and no sign-in

`--url` takes a path on this server (`/@signalk/freeboard-sk/`) or a full URL. A full URL that names this server another way (`http://localhost/…`, with or without the port) counts as a path on it. The kiosk signs in only to this server; a URL on another host is shown as it is. `--no-autologin` skips the sign-in: the kiosk opens its page signed out, as a new browser would. A re-run with `--no-autologin` or a page on another host stops the kiosk, removes the browser's session cookie, and deletes the Signal K user an earlier `enable` created. A `signalk-kiosk` user that existed before the kiosk is not deleted.

A re-run whose sign-in setup fails keeps what an earlier `enable` set up: the token, the session cookie and the Signal K user stay, and `enable` says to run it again. The exception is an admin kiosk re-run with `--readwrite`: its admin sign-in is removed as if the setup had never worked, so a screen meant to lose admin does not keep it. When the server does not answer at the sign-in step (it restarts after an update, for example), `enable` first waits up to 300s for it.

### Revoking the sign-in

`disable` deletes the Signal K user `signalk-kiosk` if `enable` created it, and with it every token issued for it. A user of that name that existed before the first `enable` (created by hand, for example) is not the kiosk's. `enable` uses it only when its type already matches — admin, or readwrite with `--readwrite` — and otherwise stops the sign-in setup and says so: such a user may have a password, which the admin API does not show, and changing its type would give that password the new rights. `disable` leaves such a user in place, and its tokens, the kiosk's included, keep working. In both cases `disable` removes the kiosk's copies of the token: the token file, the start page, the browser's session cookie, and with `--purge` the whole browser profile. Whatever `disable` cannot undo — the server not answering, an admin call failing — stays recorded in `/etc/signalk-kiosk.conf`, and running it again finishes the job. A Signal K token names a user and nothing else, so once a user of that name exists again — after a later `enable` — tokens issued before work again. Only a new server secret key (`secretKey` in `~/.signalk/security.json`, or `~/.signalk/security-secret.key`) invalidates them for good, and it invalidates every other token with them, the installer's admin token in `~/.signalk-doctor/signalk-token` included.

## TLS

The kiosk talks plain HTTP to this server. With TLS enabled on the server, its HTTP port only redirects to HTTPS, where the browser would stop at a certificate warning. So `signalk kiosk enable` stops with an explanation before it changes anything, and a kiosk set up before TLS was switched on shows a page saying the same instead of that warning. A page on another host (`--url https://…`) is not affected.

## Dark mode

The browser starts in dark mode (`--force-dark-mode`): it tells every page it prefers a dark colour scheme (`prefers-color-scheme: dark`). Pages that have a dark theme switch to it, including Freeboard-SK, which follows the browser unless its own setting says otherwise. Pages without one are shown as they are; the kiosk does not recolour them. `enable --light` turns this off, for a screen that is easier to read in bright sunlight. The choice is kept in `/etc/signalk-kiosk.conf` (`KIOSK_COLOR_SCHEME`), shown by `signalk kiosk status`, and applies from the next browser start.

## Monitor off

While the monitor is switched off, the kiosk pauses the browser, so it stops using CPU, and resumes it when the monitor comes back on. `enable` sets this up unless given `--no-screen-pause`; `signalk kiosk status` shows which.

A monitor switched off with its power button often still tells the box it is connected, so the kiosk asks the monitor itself. `signalk-kiosk-screen.service` sends a DDC/CI request (the monitor control channel in the HDMI or DisplayPort cable) to every connected monitor every 5 seconds with `i2ctransfer`. A monitor that is on acknowledges it; one that is off does not. After three checks in a row in which every monitor that has answered before stays silent, or nothing is connected at all, the service stops the browser's processes with SIGSTOP; the first answer continues them with SIGCONT. A monitor that has never answered — one without DDC/CI — counts as on, so on such a monitor the browser keeps running. A monitor with no DDC bus (DSI panels, most touch displays) counts as on as well.

The service remembers each monitor that has answered, by its connector (such as `HDMI-A-1`) and a hash of its EDID, in `/var/lib/signalk-kiosk-screen/answered`. A box that boots, or restarts the kiosk, with that monitor switched off pauses the browser as well, at the third check, about 10 seconds after the start. A different monitor on the same connector is not taken for the remembered one, and a monitor whose EDID cannot be read is never remembered. Every `enable` starts this memory afresh. If a remembered monitor's DDC/CI is switched off in its menu, the service would pause the browser while the screen is lit; run `signalk kiosk enable` again to clear the memory.

While the browser is paused, the page does nothing: it plays no sounds, so alarms that sound through the kiosk's speakers stay silent until the monitor is back on, and its connection to the server drops. Most webapps reconnect by themselves on resume. For a kiosk that has to sound alarms with the monitor off, use `signalk kiosk enable --no-screen-pause`, which removes the service.

| Path | Purpose |
|---|---|
| `/etc/systemd/system/signalk-kiosk-screen.service` | Runs the watch as root, started and stopped with `signalk-kiosk.service`. Stopping it resumes the browser. |
| `/usr/local/lib/signalk-kiosk/screen-watch` | The watch itself. |
| `/etc/modules-load.d/signalk-kiosk-i2c.conf` | Loads `i2c-dev`, which gives each DDC bus its `/dev/i2c-N` device. |
| `/var/lib/signalk-kiosk-screen/answered` | The monitors that have answered DDC/CI, one line per connector and EDID. Written by the watch, emptied by `enable`, removed by `disable` and `--no-screen-pause`. |

`enable` also installs `i2c-tools`, which provides `i2ctransfer`. `journalctl -u signalk-kiosk-screen.service` shows each pause and resume.

## Touchscreens

The launcher checks for a touchscreen (`ID_INPUT_TOUCHSCREEN=1` in udev) every time it starts, so plugging one in and running `signalk kiosk restart` is enough. With one present, the browser starts with touch events on, and with pinch-zoom and swipe-to-go-back off: a stray two-finger touch does not zoom a chart, and a sideways swipe does not navigate away from the dashboard.

cage shows a mouse cursor only while a pointing device is connected. A Raspberry Pi always has one even with no mouse attached: the HDMI-CEC input of each HDMI port (`vc4-hdmi-0`, `vc4-hdmi-1`), which carries the TV remote's arrow keys and is tagged a pointing stick by udev. `enable` writes a udev rule that removes that tag, so the remote's keys still work and the cursor stays hidden until a real mouse is plugged in.

Some touchscreens carry a USB hub with a serial port of their own beside the touch controller, for example an NXP `VCOM Port` used for the display's own control. Hardware detection passes it to the server like any USB serial device. The hub disconnects whenever the monitor is switched off, and `signalk-server` then starts without that port ([#309](https://github.com/dirkwa/signalk-universal-installer/issues/309)).

The kiosk does not rotate the display (the official Raspberry Pi Touch Display 2 is portrait-native), map a touchscreen to one of several monitors, or provide an on-screen keyboard.

## Power cuts and boot order

After a hard power-off Chromium would open with a "Restore pages?" bar over the dashboard. The launcher marks the last session as a clean exit before every start, so it never appears.

At boot the kiosk usually starts before the server, whose container waits for the network. The launcher polls `http://127.0.0.1:<port>/signalk` and starts the browser once the server answers; by then the server has started its plugins, signalk-autologin's sign-in included. If it has not answered within the time the server unit itself is given to start, the browser starts anyway and shows its connection error, rather than leaving a black screen.

## Several monitors

The browser shows on one output only: cage runs with `-m last`, which uses the output cage finds last and blanks the others. With several monitors connected when the kiosk starts, that order comes from the graphics driver, not from when each was plugged in. Spanning several outputs can make the browser window wider or taller than 4096 px, the largest texture the Raspberry Pi's GPU handles in either direction (two 3440 px monitors side by side make 6880 px, two 1920 px ones 3840 px), and Chromium then draws the page in software at a few frames per second. To choose the monitor, leave only that one connected when the kiosk starts (at boot or on `signalk kiosk restart`).

`signalk kiosk scan` shows what is connected and warns about two cases that make the kiosk slow or show it on the wrong output:

- a monitor whose preferred mode is wider or taller than 4096 px (some ultrawide monitors), which Chromium may draw in software if the kiosk uses that output;
- a connector forced on with `video=<connector>:<mode>e`, or `video=<connector>:<mode>D` for a digital output (or `video=<mode>e` / `video=<mode>D` without a connector, which applies to every connector without an entry of its own), in the kernel command line (`/boot/firmware/cmdline.txt` on Raspberry Pi OS), which reports a monitor as connected even with nothing plugged in. Remove that entry unless a monitor that fails to report itself needs it.

While such an entry is there, the kiosk leaves `-m last` out and the browser spans all outputs: cage may receive the forced connector last, and `-m last` would then put the browser on a screen nobody sees. `enable` makes this choice when it writes the unit, so after adding or removing such an entry, reboot to apply the kernel command line, then run `signalk kiosk enable` again with the options it was enabled with (see below); `signalk kiosk restart` keeps the unit as it is.

With cage 0.1.4 (Debian Bookworm), whose `-m last` crashes cage at start, the kiosk leaves the option out and the browser spans all outputs; `signalk kiosk scan` says which applies. A kiosk enabled before this change keeps spanning all outputs until `signalk kiosk enable` runs again and rewrites the unit. `enable` starts from its defaults, so repeat the options the kiosk was enabled with, such as `--readwrite`, `--url` or `--no-screen-pause`; `signalk kiosk status` shows the current settings.

## Getting a console

Ctrl+Alt+F2 switches to a text console (cage runs with `-s`), where a normal login works. Ctrl+Alt+F1 goes back to the kiosk.

## Troubleshooting

```bash
signalk kiosk status                        # service state, page, browser, sign-in
journalctl -u signalk-kiosk.service -b      # cage + launcher + browser output
loginctl list-sessions                      # the kiosk session should be on seat0, tty1
```

"waiting for http://127.0.0.1…" lines in the journal mean the server was not answering yet — check `signalk health`.

The kiosk is signed out although `status` says `sign-in token`: the Signal K user `signalk-kiosk` was deleted or signalk-autologin was switched off. `signalk kiosk enable` sets both up again.

## Undo

```bash
signalk kiosk disable           # desktop login (or the tty1 console) back, Signal K user deleted
signalk kiosk disable --purge   # also removes the signalk-kiosk system user and its browser profile
```

`disable` switches signalk-autologin off again when the kiosk installed it or switched it on (it stays installed, with its settings); if it was on before, `disable` leaves it on. App Dock stays installed. So do the packages (`cage`, `chromium`, `jq`, `fonts-noto-color-emoji`, `i2c-tools`); remove them with apt if nothing else needs them.

Uninstalling the stack does not undo the kiosk — `signalk uninstall` runs without sudo. While the kiosk is enabled, `signalk uninstall` and `scripts/uninstall.sh` refuse to run and ask for `signalk kiosk disable --purge` first: `disable` deletes the kiosk's Signal K user through the server, which the uninstall stops.
