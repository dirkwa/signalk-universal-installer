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
with `podman unshare chown -R 0:0 <repo>` afterwards. After the build:

| What                  | Where / How                              |
|-----------------------|------------------------------------------|
| Dev server            | http://localhost:4000                    |
| Sample NMEA data      | `dev/dev.sh demo`                        |
| Server management     | `dev/dev.sh start\|stop\|restart\|logs`  |
| e2e tests (Chromium)  | `cd dev && npm run test:e2e`             |
| AI pair programming   | `claude` (terminal or VS Code panel)     |
| AI code review        | `cr review --plain`                      |
| Shell lint            | `shellcheck installer/**/*.sh scripts/*.sh` |

Dev config, installed plugins and security settings persist in the named
volume `signalk-devpod` (mounted at `/home/node/.signalk`); Claude Code
login and auto memory persist in `signalk-devpod-claude`. Both survive
container rebuilds. Volumes are used instead of home-dir bind mounts so
ownership is correct under rootful docker, rootless docker and podman
alike — and the production `~/.signalk*` dirs on the host are never
touched. Inspect from the host with `docker volume inspect signalk-devpod`
(or `podman volume inspect`), or just browse `/home/node/.signalk` inside
the container.

## Why port 4000?

The production stack binds 80 or 3000 (signalk-server), 3003 (Updater
Console) and 3004 (Doctor Console). The dev instance uses 4000 so both can
run side by side on the same box.

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

To verify against a production install afterwards: `npm pack` the plugin and
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
- **socketcan** (CAN hat): uncomment `--network=host`. Multiple readers are
  fine; sending is fine too — each instance performs its own N2K address
  claim and gets its own source address. See also docs/socketcan.md.
  Note: the dev instance runs **without authentication** (anonymous reads
  for the dev loop and e2e); with `--network=host` it becomes visible on
  the LAN — enable security in the admin UI if that matters.

## AI tooling

- **Claude Code** is installed via the official Anthropic devcontainer
  feature (CLI + VS Code extension). It loads the root `CLAUDE.md`
  (→ AGENTS.md workflow conventions) and the workspace context in
  `dev/CLAUDE.md` automatically.
  Auth: run `claude` once, or forward `ANTHROPIC_API_KEY` from the host.
- **Memory**: `CLAUDE.md`/`AGENTS.md` are the committed project memory;
  Claude Code's *auto memory* (per-project notes under `~/.claude`) is
  persisted in the `signalk-devpod-claude` volume, so login and
  accumulated context survive rebuilds. Personal, uncommitted notes go in
  `CLAUDE.local.md` (gitignored).
- **CodeRabbit** — the repo's `.coderabbit.yaml` applies. Three auth paths:
  the native Claude Code plugin (state persists via the `~/.claude` mount),
  the CLI with a forwarded `CODERABBIT_API_KEY` (post-start authenticates
  automatically), or interactive `coderabbit auth login` (repeat after
  rebuilds). `cr review --plain` matches the pre-PR checklist.
- The Playwright MCP server in `.mcp.json` lets Claude Code drive a browser
  against the admin UI on port 4000 — available to both the CLI and the
  VS Code extension.

## e2e testing

Playwright + Chromium (with system deps) are pre-installed in the image.
`cd dev && npm run test:e2e` starts the demo server automatically if needed
and runs the smoke tests in `dev/e2e/`. The Playwright version is pinned in
two places that must stay in sync: `.devcontainer/Dockerfile` (baked
browser) and `dev/package.json` (`@playwright/test`).
