# Dev workspace (devcontainer)

This directory is the isolated SignalK development workspace inside the
devcontainer. Repo-wide conventions come from the root AGENTS.md (imported
via the root CLAUDE.md) — follow them strictly. This file only adds
workspace-specific context.

## Layout

- `signalk-server/` — OPTIONAL server source checkout (server development
  only; when absent, dev.sh runs the pre-built server baked into the image
  at `/home/node/signalk` — production parity, nothing to build)
- `plugins/<name>/` — local plugin repos, linked into the dev instance
  (named volume `signalk-devpod-plugins` — survives workspace delete)
- `companions/<name>/` — optional checkouts of the stack's companion repos
  (signalk-updater-server, signalk-doctor-server, signalk-updater,
  signalk-doctor, signalk-container) via `./clone-companions.sh`
- `e2e/` — Playwright tests against the dev instance
- `~/.signalk` in the container — persistent dev config (named volume
  `signalk-devpod`, deliberately separate from production `~/.signalk`)

## Port map (do not collide!)

The devcontainer uses **host networking** (production parity): every
port a dev process binds lands DIRECTLY on the box. Taken ports:
80 or 3000 (signalk-server), 3003 (signalk-updater-server), 3004
(signalk-doctor-server) — production; 10800 — this workspace's own
browser IDE. **Dev instance: port 4000.** Dev code must never bind any
of those. For a same-box production connection use the box's
LAN/tailscale IP — `localhost` is SSRF-blocked by the server (127/8).

## Dev server

- `./dev.sh start|stop|restart|status|logs` — manage the instance
- `./dev.sh demo` — start with bundled sample NMEA data; runs on the SAME
  dev config, so linked plugins stay loaded (e2e's `demo-fg` is isolated
  on purpose). Plugins run with their live config: anything that writes
  outward (questdb, grafana, MQTT...) will ingest the SAMPLE data —
  disable such plugins before a demo run if that matters.
- `start`/`demo`/`restart` auto-link every `plugins/<name>` when they launch
  the server (`link-plugins.sh`), building any not built yet, so a freshly
  cloned plugin just works — no manual `npm install`/`post-create`.
  `./dev.sh link` links without a restart; `demo-fg` deliberately does NOT
  (isolated e2e config). See `link-plugins.sh` for the build/link mechanics.
- After changing plugin code, `./dev.sh restart` is required — Node caches
  modules; toggling the plugin in the admin UI is NOT enough. An already-
  built plugin is not rebuilt automatically; after editing a **TypeScript**
  plugin's source: `SK_DEV_PLUGIN_BUILD=1 ./dev.sh restart`.

## Server tests (signalk-server checkout)

Running signalk-server's mocha suites from `signalk-server/` needs two
adjustments to this container's environment:

- **Unset the dev-instance vars.** The shell exports `PORT=4000`,
  `SIGNALK_NODE_CONFIG_DIR` and `SIGNALK_SERVER_IS_UPDATABLE` for the dev
  instance; test servers inherit them and fail (EADDRINUSE on 4000,
  wrong config dir). Invoke as:

  ```
  env -u PORT -u SIGNALK_NODE_CONFIG_DIR -u SIGNALK_SERVER_IS_UPDATABLE \
    NODE_ENV=test npx mocha test/<file>
  ```

- **`TS_NODE_IGNORE` must include `dist/`** — preset in
  `.devcontainer/devcontainer.json` `containerEnv` (see the comment
  there for the value and the mechanism; in a container built before
  it was added, export the same value manually). Without it,
  full-server suites time out in their before hooks on ARM boxes.

Known upstream quirk: `test/subscriptions.js` fails 2 tests when run as
a **single file** — it uses chai `.should` without calling
`chai.should()`, relying on another suite in the same mocha process to
install it. Not an environment problem; run it together with another
suite or fix upstream.

Expect the tcp interface to log `EADDRINUSE :::8375` during test runs
while the dev instance is up — the dev server holds that port; the
tests themselves are unaffected.

## Container-runtime plugins

The host's podman socket dir is mounted at `/run/host-podman/` (probe-and-
fallback: the container starts fine without a socket; post-start prints an
INFO with remediation). `CONTAINER_HOST`/`DOCKER_HOST` and the image's
containers.conf point at `/run/host-podman/podman.sock`, so signalk-container
and its consumer plugins work unchanged.

`signalk-container` is a **default plugin**: `post-create.sh` installs it
from npm (a SAVED dep `^1.22.0` in `~/.signalk`, so `link-plugins` keeps it)
and seeds it enabled, so container-runtime consumer plugins work out of the
box with no manual setup. The install is install-if-missing (offline-safe),
which pins it at first-install — to **upgrade** the default, delete
`~/.signalk/node_modules/signalk-container` and rebuild the workspace.

To **develop** signalk-container itself, check it out under
`dev/plugins/signalk-container` — that local link supersedes the npm copy
(post-create skips the npm install when the checkout is present). Keep the
checkout on a version that satisfies the saved `^1.22.0` range: npm flags a
non-satisfying version (a `0.x`/`2.x` branch, a prerelease) as `invalid` and
strict peer resolution can escalate it to `ERESOLVE`. If you need such a
version, drop the saved dep from `~/.signalk/package.json` first.

Managed containers run as siblings
on the host. `dev.sh` exports `SIGNALK_CONTAINER_NAMESPACE=devpod`, so this
instance's managed containers and jobs are named `devpod-<name>` /
`devpod-job-*` and can never collide with, reap, or recreate the production
`sk-*` stack on the same podman socket. That isolates **names and reaping**,
not host **ports** — a consumer plugin that publishes a fixed host port
still needs a non-colliding port for dev. Inspect with `podman ps` /
`podman logs` (production is `sk-*`, this instance is `devpod-*`).

## Commit & PR conventions (from AGENTS.md — enforced here too)

- **All commits and PRs use Angular conventional naming**:
  `<type>(<scope>): <subject>` (`feat|fix|docs|style|refactor|test|chore|perf`),
  subject ≤ 50 chars, imperative mood, no period. No AI attribution lines.
- **Never push directly to `master`.** Every change goes through a branch — or,
  better, a dedicated git worktree — and lands via a PR. No direct commits to
  `master`, ever.
- Branch names use **hyphens**, never slashes: `fix-something`, `feat-something`.

## Pre-PR (from AGENTS.md, tooling is in this container)

`shellcheck` on all touched shell, `bash -n`, manual smoke, then
`cr review --plain | tee /tmp/cr-review-<branch>.txt`. Branch names use
hyphens; Angular conventional commits; no AI attribution lines.
