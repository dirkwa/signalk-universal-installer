---
name: signalk-devpod
description: Use when developing SignalK plugins or the server itself on a boat computer set up with the signalk universal installer — either directly against the live production server or in the disposable DevPod dev environment (signalk devpod up). Covers picking the right mode, the ~/.signalk visibility rule, restarting via the admin UI or updater console (never systemctl), the SK_DEV_PLUGIN_BUILD=1 rebuild gotcha, the four-row update matrix, the port map, and the browser-IDE secure-context and resident-process pitfalls.
---

# Developing on an installer-managed SignalK box

On a box set up with this repo's installer,
signalk-server runs **inside a container** whose lifecycle belongs to the updater engine.
Port map: production server on **80** (or 3000), Updater Console **3003**, Doctor Console
**3004**; the dev environment adds a disposable dev server on **4000** and a browser IDE on
**10800**. The canonical, maintained reference is the installer's
[docs/development.md](../../../docs/development.md)
and [docs/devcontainer.md](../../../docs/devcontainer.md);
this skill carries the decisions and the gotchas that cost time in the field.

## Pick the mode first

| Goal | Mode |
| --- | --- |
| Hack a plugin against real, live boat data | Live-server plugin dev (below) |
| "Does it still happen on beta/master?" | Updater Console **:3003** → Versions tab — pre-built images, two clicks, Doctor rolls back |
| Plugin dev without risking the boat | DevPod dev environment |
| Change signalk-server's own source | DevPod + a `dev/signalk-server/` checkout |

The live server runs **pre-built images only** — there is no pointing it at a source
checkout; that's what the dev environment is for.

## Live-server plugin dev

- **The container sees exactly one directory of yours: `~/.signalk`.** Plugin repos must
  live under it (convention: `~/.signalk/github/`, with `ln -s ~/.signalk/github ~/github`
  for comfort) — anywhere else and the server literally cannot see the files.
- Install by running npm **inside the server's container** (same Node the server uses, no
  host Node needed):
  `podman exec signalk-server sh -c 'cd /home/node/.signalk && npm install ./github/<dir>'`.
  npm links a local folder rather than copying — edits take effect without reinstalling.
- **Restart with the admin-UI Restart button** (or the Updater Console on :3003 when the
  admin UI won't load) — **never `systemctl --user restart signalk-server`**: the updater
  engine owns the server's lifecycle, and reaching past it desyncs version switching and
  `signalk start`/`stop`.
- Toggling a plugin off/on is **not** a code reload (the loaded module stays cached) —
  restart. TypeScript plugins need their build run before the restart.

## The DevPod dev environment

- `signalk devpod up` on the box → browser VS Code on `:10800` and a second, disposable
  SignalK server on `:4000`, host networking for production parity. **Both are
  unauthenticated and LAN-visible by design** (owner-controlled-network assumption) — on any
  network you don't fully control, `tailscale serve` the IDE and enable security in the dev
  server's admin UI. Note each measure covers only its own port, and `tailscale serve` is a
  proxy, not a firewall — the plain ports stay LAN-reachable regardless.
- Plugin repos go under `dev/plugins/` — every `./dev.sh restart` links whatever is there
  into the dev server; missing `node_modules` get installed on the next start. There is no
  install step to run.
- **The gotcha that looks like "my change did nothing": builds are not automatic.** A plugin
  is only built when its compiled entry point is missing. After editing a TypeScript plugin,
  restart with `SK_DEV_PLUGIN_BUILD=1 ./dev.sh restart` — plain restart keeps loading the
  previous build.
- Day-to-day: `./dev.sh start|stop|restart|status|logs`, and `./dev.sh demo` feeds sample
  NMEA data — no boat required.
- Server-source work: put a checkout at `dev/signalk-server/` (run
  `.devcontainer/post-create.sh` once to install and build) — the dev scripts prefer it over
  the pre-built copy automatically. Cycle: edit → `npm run build` (or `build:all` when the
  admin UI / workspace packages changed) → `./dev.sh restart`. Remove the checkout to fall
  back to the pre-built server.
- Persistence: dev-server config, plugin checkouts under `dev/plugins/`, and tool logins
  live in three **named volumes** — `signalk-devpod`, `signalk-devpod-plugins`,
  `signalk-devpod-claude` — per-box shared storage (not backups) that survives both
  `--recreate` and `devpod delete`. The workspace checkout itself is lost on delete — commit
  and push first. Full reset = `podman volume rm` (or `docker volume rm`) of all three.

## Updating — four things change on four schedules

The usual "I pulled but nothing changed" has one of these answers:

| What changed | What actually applies it |
| --- | --- |
| Workspace scripts, tests, docs | `git pull` + `./dev.sh restart` |
| Anything under `.devcontainer/` | `signalk devpod up --recreate` — run from SSH on the box, *not* the IDE terminal (it lives inside the container being replaced) |
| The pre-built server in the image | `podman pull ghcr.io/dirkwa/signalk-server:dirkwa`, then `--recreate` |
| Your own plugin/server checkouts | `git pull` in each — the workspace pull never touches them |

- Check whether a rebuild is even needed: `git fetch && git diff --stat HEAD @{u} -- .devcontainer`
  (no output → no rebuild).
- If only `post-create.sh` / `post-start.sh` changed, rerun that script inside the container —
  both are idempotent, and one does **not** call the other.
- Workspaces track the **`release`** branch. Switching channels
  (`SIGNALK_DEVPOD_REF=master signalk devpod up`) requires `signalk devpod delete` + `up` —
  `--recreate` keeps the clone it already has.
- `signalk update` refreshes the production-side `signalk` command itself (which provides
  `signalk devpod`) — separate from the workspace; worth running before a `--recreate`.

## Sharp edges

- **Browser-IDE webview panels need a secure context.** On plain `http://<lan-ip>:10800`,
  embedded webview panels render blank (`localhost` is exempt; terminal tools are
  unaffected) — `tailscale serve` the IDE port and use the tailnet HTTPS URL.
- **The browser-mode `devpod up` process stays resident** to hold the IDE tunnel. If that
  process is killed or reaped (closed session, harness timeout), devpod's cleanup can take
  the workspace container with it. Start it detached —
  `setsid nohup signalk devpod up > ~/devpod-up.log &` — from anything that might not
  outlive it.

---

*Distilled from this repo's devcontainer field work (PRs #174–#204, July 2026); command
surface, port map, and update matrix verified against `docs/development.md` and
`docs/devcontainer.md` in this repo as of that date. The docs are the canonical reference —
when this skill and they disagree, the docs are current; PRs that change the dev workflow
should update both.*
