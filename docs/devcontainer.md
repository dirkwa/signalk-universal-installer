# Development Environment (Devcontainer)

The universal installer runs signalk-server in a rootless podman container —
great for end users, but it breaks the classic plugin development workflow:
`npm link` points at a host path that does not exist inside the container.

This devcontainer provides a complete, isolated development environment with
one command, covering the development targets of this stack:

1. **This repo** (installer scripts, Quadlets — shellcheck & bash tooling)
2. **The SignalK server** (pre-built in the image; optional source checkout
   under `dev/signalk-server/` for server development)
3. **SignalK plugins** (linked from `dev/plugins/`, no symlink problems)
4. **The companion repos** (optional checkouts via `dev/clone-companions.sh`:
   signalk-updater-server, signalk-doctor-server, signalk-updater,
   signalk-doctor, signalk-container)

The devcontainer is based on the stack's own server image
(`ghcr.io/dirkwa/signalk-server:dirkwa`), so the dev runtime is identical to
production — same Node, same npm behavior (canboatjs allow-scripts fix), same
container CLIs — and signalk-server comes **pre-built**: plugin development
starts right after `devpod up`, with no server clone or build.

Claude Code, CodeRabbit CLI, shellcheck and Playwright e2e testing (Chromium
with all system deps baked into the image) are included. A production stack
installed on the same host is never touched.

## Quick start

```bash
devpod up github.com/dirkwa/signalk-universal-installer
# or clone + VS Code → "Reopen in Container"
```

The first run pulls the server base image and bakes the dev tooling on top —
no signalk-server build happens. (Host requirements: Linux or macOS with
bash; on Windows use WSL — the `initializeCommand` host hook is a bash
script.)

Caveat for **rootless docker + a local folder** as the workspace source:
devpod chowns the workspace to the container user, which lands on subuids
on the host and makes your checkout unwritable outside the container.
Prefer the git-URL form there (devpod keeps its own clone), or restore
with `podman unshare chown -R 0:0 <repo>` afterward.

### Working from another machine (headless box)

When devpod runs on a headless box (Pi, VM, boat computer) and your editor
runs elsewhere, the default `--ide vscode` flow breaks: devpod writes its
SSH alias only into `~/.ssh/config` **on the box**, so your desktop cannot
resolve it. Use the **browser IDE** instead — no desktop tooling at all:

```bash
devpod up github.com/dirkwa/signalk-universal-installer \
  --ide openvscode --ide-option VERSION=v1.109.5 \
  --ide-option FORWARD_PORTS=false
```

(`FORWARD_PORTS=false` because under host networking the ports are on
the box already — a devpod forward would only collide with them.)

On a box provisioned by the universal installer, all of this section is
one command — `signalk devpod up` — which also installs the pinned devpod
CLI to `~/.local/bin` on first use, points it at podman, and — when
tailscale is present and `tailscale serve` is unclaimed — publishes the
IDE as HTTPS on the tailnet automatically (secure context, see the
caveat below; an existing serve config is never touched).

The devcontainer runs with **host networking** (production parity), so
under podman the IDE serves directly on `http://<box-ip>:10800` and the
dev server on `http://<box-ip>:4000` — no forwards, no extra options,
and both keep running after `devpod up` returns. The flip side, stated
plainly: **both are unauthenticated and LAN-visible**, and each needs
its own protection where that matters — for the IDE (:10800) use
`tailscale serve --bg 10800` and reach it only via the tailnet URL; for
the dev server (:4000) enable security in the admin UI. Neither measure
covers the other port, and tailscale serve is a proxy, not a firewall —
the plain ports stay reachable on the LAN. This default is for
owner-controlled networks.

Caveat: over plain `http://<ip>` the browser treats the IDE as an
**insecure context** — the workbench loads, but webview-based extension
panels (the Claude Code window, for one) stay blank. `http://localhost`
is exempt, HTTPS always works. The clean fleet answer is
`tailscale serve --bg 10800` on the box: an HTTPS URL on your tailnet,
secure context included, no LAN exposure — and the missing IDE
authentication stops mattering. To keep using the plain IP instead,
allowlist that exact origin in the browser (Chrome/Edge:
`chrome://flags/#unsafely-treat-insecure-origin-as-secure`, add
`http://<box-ip>:10800`, relaunch) — a per-browser, per-machine setting;
Firefox has no equivalent.

The `VERSION` pin matters: devpod's default openvscode is too old
(v1.84) for current extensions such as Claude Code — set it on the FIRST
`up` (an already-provisioned IDE keeps its installed version; to upgrade
later, delete `~/.openvscode-server` inside the container and re-run —
note this also resets browser-IDE settings and extensions, which live
under that directory).
Open
`http://<box-ip>:10800/?folder=/workspaces/signalk-universal-installer`
(an SSH forward to `localhost:10800` also works and sidesteps the
insecure-context caveat above). Extensions come from Open VSX (Claude
Code is available).

Bridge mode only (no host networking): devpod's port forwards become the
transport again — re-enable them with
`signalk devpod up --ide-option FORWARD_PORTS=true`, keep the `devpod up`
process running (it IS the tunnel then), and disable devpod's ~90s idle
self-termination once per box:

```bash
devpod context set-options -o EXIT_AFTER_TIMEOUT=false
```

Alternatives for a native desktop VS Code:

- **DevPod Desktop on the desktop** with an SSH provider pointing at the
  box — devpod then manages the desktop-side alias itself. This is the
  supported client for remote boxes.
- **Attach to the running container** from an existing VS Code Remote-SSH
  window to the box: install the "Dev Containers" extension, then
  F1 → "Dev Containers: Attach to Running Container…" and open
  `/workspaces/signalk-universal-installer`.
- A hand-rolled SSH chain on the desktop (`ProxyCommand ssh <user>@<box>
  "/usr/local/bin/devpod ssh --stdio --context default --user node
  signalk-universal-installer"`, user `node`, answer **Linux** at the
  platform prompt) also works but is the most fragile option.

Troubleshooting:

- Tunnel fails with `.devpod-internal/0/NOTES.md: permission denied`: the
  box runs a rootless container runtime and devpod's workspace chown
  locked the agent out of its own feature staging. `host-prepare.sh`
  self-heals this on the next connect; the manual cure on the box is
  `podman unshare chown -R 0:0 <workspace-content>/.devcontainer/.devpod-internal`.
- `error unset system credential helper exit status 5` in the `up` log is
  cosmetic devpod noise (it unsets a git config key that was never set).
- Browser IDE ignores the seeded dark theme: the browser caches the last
  active theme per site from earlier sessions. Pick it once
  (Ctrl+K Ctrl+T → "Default Dark Modern") or clear site data for the
  10800 origin; fresh browsers pick up the server-side default directly.
- `traceroute`/`tcpdump` say "Operation not permitted": expected in
  rootless podman containers (raw sockets in the host namespace are out
  of reach) — use them on the box. `ping` works: the image strips its
  file capability so it uses unprivileged ICMP, permitted by systemd
  hosts' `ping_group_range` (a locked-down host can still refuse it).
  `dig`, `nslookup`, `nc`, `wget` and `curl` work everywhere.
- npm fails with `EACCES` inside `/home/node/.signalk` (or files there
  show owner `999`): the volume was written under a different user-id
  mapping than the current runtime uses (devpod runs podman containers
  with keep-id, so `node` is your host user; volumes from another
  runtime era surface as foreign uids). Cure on the box:
  `podman unshare chown -R 0:0 $(podman volume inspect signalk-devpod --format '{{.Mountpoint}}')`
  — repeat for `signalk-devpod-claude` / `signalk-devpod-plugins` (the
  volume names are defined in `.devcontainer/devcontainer.json`).

After the build:

| What                  | Where / How                              |
|-----------------------|------------------------------------------|
| Dev server            | http://localhost:4000                    |
| Sample NMEA data      | `dev/dev.sh demo`                        |
| Server management     | `dev/dev.sh start\|stop\|restart\|logs`  |
| e2e tests (Chromium)  | `cd dev && npm run test:e2e`             |
| AI pair programming   | `claude` (terminal or VS Code panel)     |
| AI code review        | `cr review`                              |
| Shell lint            | `shellcheck installer/**/*.sh scripts/*.sh .devcontainer/*.sh dev/*.sh` |

The `dev.sh` verbs are also one-click **status-bar buttons** at the
bottom of the IDE (look for `SK Start`). Each verb, plus the Playwright
e2e suite, is a plain VS Code task — `.vscode/tasks.json` is the single
source for the button set — rendered by the pre-installed
`actboy168.tasks` extension, so the same list is under *Terminal → Run
Task* in any IDE flavor. VS Code disables tasks in
Restricted Mode — accept the one-time workspace-trust dialog and the
buttons appear. In a workspace created before
the extension was wired in, `git pull` brings the tasks — add the
buttons by installing "Tasks" (actboy168) once from the Extensions view,
or recreate the workspace.

Dev config, installed plugins and security settings persist in the named
volume `signalk-devpod` (mounted at `/home/node/.signalk`); Claude Code
login, auto memory and the CodeRabbit CLI login persist in
`signalk-devpod-claude`; your plugin
checkouts under `dev/plugins/` persist in `signalk-devpod-plugins`. All
three survive container rebuilds **and** `devpod delete` — deleting and
recreating the workspace is always safe. The volumes are per box and
shared by every workspace on it, so a second workspace sees the same
config, login and plugin checkouts. Volumes are used instead of home-dir
bind mounts so ownership is correct under rootful docker, rootless
docker and podman alike — and the production `~/.signalk*` dirs on the
host are never touched. Inspect from the host with
`docker volume inspect signalk-devpod` (or `podman volume inspect`), or
just browse the paths inside the container. A complete reset is the
volume removal after the workspace delete:
`docker volume rm signalk-devpod signalk-devpod-claude signalk-devpod-plugins`.

Upgrading a workspace created before the plugins volume existed: the
fresh volume shadows plugins already sitting in the workspace tree —
re-clone them once (or copy them from the old location on the host,
`~/.devpod/agent/contexts/default/workspaces/<name>/content/dev/plugins/`).

## Release channel

`signalk devpod up` clones the **`release` branch**, not `master`.
Master is where development happens and may break at any time; the
release branch is force-updated to every version tag (`vX.Y.Z`) by CI
(`.github/workflows/release-branch.yml`) — tagging is the release act.
What this means:

- New workspaces always start from the latest tagged state.
- Upgrading an existing workspace is unchanged — `git pull` inside the
  workspace, then `signalk devpod up --recreate` on the host — but the
  pull now lands on the latest release, never on a half-finished
  master.
- Unreleased state (developing the devcontainer itself, verifying a fix
  before it is tagged): `SIGNALK_DEVPOD_REF=master signalk devpod up`.
  The ref only matters when the workspace is created — an existing
  workspace keeps the clone it was created from until
  `signalk devpod delete` + `up` (the three named volumes survive, so
  delete/recreate stays safe).

Workspaces created before the channel existed track `master`; migrate
once with `signalk devpod delete` + `signalk devpod up`.

## Why port 4000?

The production stack binds 80 or 3000 (signalk-server), 3003 (Updater
Console) and 3004 (Doctor Console). The dev instance uses 4000 so both can
run side by side on the same box.

## Getting data into the dev instance

- **No boat needed:** `dev/dev.sh demo` streams the bundled sample NMEA
  log — enough for most plugin work and for the e2e suite.
- **Live sources** are added as usual in the admin UI (Server → Data
  Connections). With the default **host networking** the container shares
  the box's network: gateways and devices work exactly as they would for
  production. One rule for a production signalk-server **on the same
  box**: connect to the box's **LAN or tailscale IP**, not `localhost` —
  the server's SSRF guard deliberately blocks loopback (127/8) for
  server-to-server connections. The same rule applies to
  WebSocket/Signal K connections and their access-token requests.
- **can0 / socketcan**: on a Linux host with a CAN interface it is
  simply present under host networking — add the connection in the admin
  UI (docs/socketcan.md for host-side CAN setup). macOS/Windows hosts
  have no SocketCAN; use a network gateway or USB device there.
- The dev instance's own inbound NMEA0183 (:10110) and Signal K TCP
  (:8375) listeners are seeded **off**: under host networking they would
  claim the very ports the production stack already holds. Re-enable
  them in Server → Settings when a dev consumer needs them (pick free
  ports).

## Developing plugins

Put your plugin repos under `dev/plugins/`:

```bash
cd dev/plugins
git clone https://github.com/you/your-signalk-plugin.git
bash ../../.devcontainer/post-create.sh   # links it into the dev instance
```

Because plugin and server live in the same container, `npm install <path>`
works again — the symlink problem of the containerized production setup does
not exist here. After code changes run `dev/dev.sh restart` (Node caches
modules; toggling the plugin in the admin UI is not enough).

To verify against a production install afterward: `npm pack` the plugin and
install the tarball there, or add a bind mount for the plugin directory in
the USER ADDITIONS block of the signalk-server Quadlet.

## Plugins that use signalk-container

The host's rootless podman socket **directory** is bind-mounted at
`/run/host-podman/`, and `CONTAINER_HOST`/`DOCKER_HOST` (plus the image's
`containers.conf`) point at `/run/host-podman/podman.sock` — so
signalk-container and its consumer plugins work unchanged. Managed
containers run as siblings on the host, the same topology as production.

This is probe-and-fallback: container creation never fails when the host has
no podman socket (or no podman at all — macOS/Windows). At every start,
`post-start.sh` probes the socket and either confirms it or prints an INFO
with the remediation:

```bash
# on the host, once (host-prepare attempts this automatically):
systemctl --user enable --now podman.socket
# then just RESTART the devcontainer — no rebuild: the socket appears
# inside the already-mounted directory.

# in the devcontainer, after enabling the plugin:
curl http://localhost:4000/plugins/signalk-container/api/doctor/deployment
podman ps    # inspect what the plugin spawned (talks to the host socket)
```

Managed containers land on the host next to any production-managed ones —
pick distinct container names/ports in the plugin's dev config. If the
devcontainer itself runs under podman and the socket yields permission
errors, add `"--userns=keep-id"` to `runArgs`.

## Connecting to a production server on the same box

With the default **host networking**: use the box's LAN or tailscale IP
in the Data Connection — not `localhost`, which the SSRF guard blocks
(127/8). That is the whole rule.

**Bridge mode only** (host networking removed from `runArgs`): what "the
host" resolves to inside the container depends on the runtime — and
signalk-server's SSRF guard (deliberately, and correctly for production)
blocks link-local addresses:

| Runtime | Host maps to | Works? |
|---|---|---|
| Docker Desktop (Mac/Win) | `host.docker.internal` → `192.168.65.x` | yes |
| Rootful docker (Linux) | `172.17.0.1` | yes |
| Rootless podman + slirp4netns | `10.0.2.2` | yes |
| Rootless podman + **pasta** (the podman ≥ 5 default) | `169.254.1.2` | **no — SSRF-blocked** |

Under pasta the connection test fails with the generic
`Could not connect to Signal K server` (issue #191); `post-start.sh`
detects this and prints the remediation at container start. Two verified
ways out:

- Use the **host's tailscale IP** (CGNAT `100.64/10` is allowed and not
  mirrored by pasta) in the Data Connection.
- Or switch the workspace to slirp4netns — uncomment in
  `devcontainer.json`:

  ```jsonc
  "runArgs": ["--network=slirp4netns:allow_host_loopback=true"]
  ```

  rebuild, and connect to `10.0.2.2:<port>` instead.

Devices elsewhere on the LAN are unaffected either way — pasta mirrors
the host's own address, everything else routes normally.

## Developing the server

By default the dev instance runs the **pre-built server baked into the
image** — nothing to build, production parity. For server-source work,
clone a checkout; `dev/dev.sh` automatically prefers it:

```bash
git clone --filter=blob:none https://github.com/SignalK/signalk-server.git dev/signalk-server
bash .devcontainer/post-create.sh   # npm install + build:all
```

Edit, `npm run build` (or the package-specific build), `dev/dev.sh restart`.
For debugging use the launch configs in `.vscode/launch.json` — stop the
background instance first (`dev/dev.sh stop`) or start the container with
`SK_DEV_AUTOSTART=0`. Breakpoints work in server code and in plugins linked
from `dev/plugins/` alike, since both run in the same Node process. To go
back to the baked server, remove or rename `dev/signalk-server/`.

## Developing the installer itself

The repo root is the workspace; shellcheck and bash are in the image, so
the pre-PR checklist from AGENTS.md runs entirely inside the container.
The installer's systemd/Quadlet integration cannot be exercised against
the container's own runtime — full end-to-end installs still need a clean
VM as described in AGENTS.md.

## NMEA 2000 access

- **Network gateway / TCP** (YDWG-02, W2K-1, or a TCP feed from the
  production instance): add the connection in the admin UI — nothing to
  configure in the container.
- **USB gateway** (NGT-1 etc.): uncomment the `--device` line in
  `devcontainer.json`. Serial devices are exclusive — production and dev
  cannot open the same one simultaneously; let production forward via TCP.
- **socketcan** (CAN hat): on a Linux host with a CAN interface, `can0`
  is present in the container under the default host networking (no
  SocketCAN exists on macOS/Windows hosts — use a gateway or USB there).
  Multiple readers are fine; sending is fine too — each instance
  performs its own N2K address claim and gets its own source address.
  See also docs/socketcan.md.
  Reminder: the dev instance runs **without authentication** and, under
  host networking, LAN-visible — enable security in the admin UI if that
  matters on your network.

## AI tooling

- **Claude Code** is installed via the official Anthropic devcontainer
  feature (CLI + VS Code extension). It loads the root `CLAUDE.md`
  (→ AGENTS.md workflow conventions) and the workspace context in
  `dev/CLAUDE.md` automatically.
  Skills come from the sailingnaturali/claude-skills plugin marketplace
  declared in `.claude/settings.json` — the six plugins install
  automatically when a user trusts the workspace.
  Auth: run `claude` once, or forward `ANTHROPIC_API_KEY` from the host.
- **Memory**: `CLAUDE.md`/`AGENTS.md` are the committed project memory;
  Claude Code's *auto memory* (per-project notes under `~/.claude`) is
  persisted in the `signalk-devpod-claude` volume, so login and
  accumulated context survive rebuilds. Personal, uncommitted notes go in
  `CLAUDE.local.md` (gitignored).
- **CodeRabbit** — the repo's `.coderabbit.yaml` applies. Three auth paths:
  the native Claude Code plugin (state persists via the `~/.claude` mount),
  the CLI with a forwarded `CODERABBIT_API_KEY` (post-start authenticates
  automatically), or interactive `coderabbit auth login` — a one-time act:
  post-create symlinks `~/.coderabbit` into the `signalk-devpod-claude`
  volume, so the login survives rebuilds and recreates. `cr review`
  matches the pre-PR checklist.
- The Playwright MCP server in `.mcp.json` lets Claude Code drive a browser
  against the admin UI on port 4000 — available to both the CLI and the
  VS Code extension.

## e2e testing

Playwright + Chromium (with system deps) are pre-installed in the image.
`cd dev && npm run test:e2e` starts its own foreground demo server on a
dedicated port (4100, override with `E2E_PORT`) and runs the smoke tests
in `dev/e2e/` — your dev instance on 4000 is neither reused nor touched.
The Playwright version is pinned in two places that must stay in sync:
`.devcontainer/Dockerfile` (baked browser) and `dev/package.json`
(`@playwright/test`).
