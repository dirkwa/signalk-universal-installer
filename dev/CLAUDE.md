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
- `companions/<name>/` — optional checkouts of the stack's companion repos
  (signalk-updater-server, signalk-doctor-server, signalk-updater,
  signalk-doctor, signalk-container) via `./clone-companions.sh`
- `e2e/` — Playwright tests against the dev instance
- `~/.signalk` in the container — persistent dev config (named volume
  `signalk-devpod`, deliberately separate from production `~/.signalk`)

## Port map (do not collide!)

Production stack on the host: 80 or 3000 (signalk-server), 3003
(signalk-updater-server), 3004 (signalk-doctor-server).
**Dev instance: port 4000.** Never bind 80, 3000, 3003 or 3004.

## Dev server

- `./dev.sh start|stop|restart|status|logs` — manage the instance
- `./dev.sh demo` — start with bundled sample NMEA data; runs on the SAME
  dev config, so linked plugins stay loaded (e2e's `demo-fg` is isolated
  on purpose). Plugins run with their live config: anything that writes
  outward (questdb, grafana, MQTT...) will ingest the SAMPLE data —
  disable such plugins before a demo run if that matters.
- After changing plugin code, `./dev.sh restart` is required — Node caches
  modules; toggling the plugin in the admin UI is NOT enough.

## Container-runtime plugins

The host's podman socket dir is mounted at `/run/host-podman/` (probe-and-
fallback: the container starts fine without a socket; post-start prints an
INFO with remediation). `CONTAINER_HOST`/`DOCKER_HOST` and the image's
containers.conf point at `/run/host-podman/podman.sock`, so signalk-container
and its consumer plugins work unchanged. Managed containers run as siblings
on the host: pick container names/ports that don't clash with the production
stack. Inspect with `podman ps` / `podman logs`.

## Pre-PR (from AGENTS.md, tooling is in this container)

`shellcheck` on all touched shell, `bash -n`, manual smoke, then
`cr review --plain | tee /tmp/cr-review-<branch>.txt`. Branch names use
hyphens; Angular conventional commits; no AI attribution lines.
