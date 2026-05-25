# signalk-universal-installer

Bash + PowerShell bootstrap for the SignalK container stack. This repo holds:

- Platform installers under `installer/{linux,macos,windows}/`.
- Quadlet templates under `quadlets/`.
- A standalone post-install health-check (`scripts/doctor.sh`) and uninstaller (`scripts/uninstall.sh`).
- GitHub Pages publishes `installer/`, `quadlets/`, and `scripts/` so the `curl … | bash` one-liner just works.

The installer is a **one-shot bootstrapper**. After it finishes, systemd and the engine containers own the runtime. The installer never runs continuously and never holds state beyond what it writes to `~/.config/containers/systemd/` and `~/.signalk-{updater,doctor}/`.

## Companion repos

| Repo | Role |
|---|---|
| [signalk-updater-server](https://github.com/dirkwa/signalk-updater-server) | Engine container — image lifecycle, version switching, self-update. |
| [signalk-doctor-server](https://github.com/dirkwa/signalk-doctor-server) | Engine container — diagnostics, last-known-good recovery. |
| [signalk-updater](https://github.com/dirkwa/signalk-updater) | Thin-shell plugin inside signalk-server. |
| [signalk-doctor](https://github.com/dirkwa/signalk-doctor) | Thin-shell plugin inside signalk-server. |

## Workflow Conventions

This repo is maintained by Dirk Wahrheit. Workflow is deliberate; AI tools should follow it strictly.

### Branch and commit rules

- Branch names use **hyphens**, never slashes: `fix-something`, `feat-something`, `chore-release-1-6-0`.
- Angular conventional commits: `<type>(<scope>): <subject>`. Types: `feat|fix|docs|style|refactor|test|chore|perf`. Subject ≤ 50 chars, imperative mood, no period.
- One logical change per commit. Each commit is a meaningful, self-contained step.
- No `Co-Authored-By` lines. No "Generated with Claude Code" attribution.

### PR rules

- Never commit directly to `master`. Every change goes through a PR.
- One logical change per PR. Refactors, behavior changes, and features belong in separate PRs.
- PR titles describe what changes; PR bodies explain _why_.
- No checkboxes in PR descriptions. If you need a "Tested" section, list what was actually verified, not what's planned.
- PR descriptions must reflect reality. Never list speculative tests.

### Pre-PR checklist

Before pushing or opening a PR:

1. `shellcheck installer/**/*.sh scripts/*.sh` — lints all shell.
2. `bash -n` on every script to catch syntax errors.
3. Manual smoke: run the script on a clean VM or in a container, verify the documented behavior.
4. `cr review --plain | tee /tmp/cr-review-<branch>.txt` — local CodeRabbit pass. Commit first, then review.

Skip `cr review` only for `chore(release): X.Y.Z` PRs.

### Release flow

There is no npm publish for this repo — it's pure bash. GitHub Pages publishes the script tree on every push to `master` and on `v*` tags. Tag triggers add the tag name as `INSTALLER_VERSION` via a `sed` substitution at deploy time.

### Branch protection / merging

- Never push without explicit approval — except when the session goal explicitly delegates it.
- Never merge a PR without explicit approval — except as above.
- Never force-push unless the user asked for it.

## Filesystem invariants

Paths the installer creates and the engine containers depend on:

| Path | Owner | Purpose |
|---|---|---|
| `~/.config/containers/systemd/signalk-server.container` | installer + updater | Quadlet, rewritten on version switch and hardware change. |
| `~/.config/containers/systemd/signalk-updater-server.container` | installer + updater (self-update) | Quadlet for the updater itself. |
| `~/.config/containers/systemd/signalk-doctor-server.container` | installer | Quadlet for the doctor; not rewritten at runtime. |
| `~/.signalk/` | signalk-server | SignalK data — never touched by installer or doctor. |
| `~/.signalk-updater/` | updater container + installer | Tokens, hardware.json, logs. |
| `~/.signalk-doctor/` | doctor container + installer | Snapshots of Quadlets, last-good.json, tokens. |
| `~/.local/bin/signalk-recovery` | installer | Static bash recovery script — works with zero containers running. |

The installer never writes to `~/.signalk/` and never starts/stops `signalk-server` except via the updater's REST API (with a direct `systemctl --user start` fallback when the updater is unreachable).

## Engine images run on `:latest`

The Quadlets for `signalk-updater-server` and `signalk-doctor-server` pin `Image=ghcr.io/dirkwa/signalk-*-server:latest` by default. This is OperatorIntent = "stay on the channel" — the engine's own auth-gated self-update flow is the authoritative version-advancer.

PR #36 once tried to resolve a specific semver tag from GHCR at install time and pin the Quadlet to it. That made the engine permanently responsible for migrating its own Quadlet pin on every update — fragile, and circular: a broken engine couldn't move itself forward without an SSH-and-edit recovery. This PR reverses that decision.

The model relies on signalk-updater-server's separation of OperatorIntent (the Quadlet tag), RuntimeIdentity (the engine's `/api/health.version`), and LatestAvailable (the GHCR cache). When the operator clicks Self-update:

1. The engine pulls a specific semver tag explicitly (e.g. `podman pull ghcr.io/dirkwa/signalk-updater-server:<semver>`).
2. `daemon-reload` + `restartUnit` fires.
3. podman picks up the just-pulled image because `:latest` now resolves to it — no Quadlet rewrite required.
4. The Dashboard's Updater card shows the runtime semver (from `health.version`) and the configured channel `:latest (stable)` (from the Quadlet) as separate rows.

`UPDATER_IMAGE` / `DOCTOR_IMAGE` env vars still override at install time for CI and power-user setups. `installer/linux/lib/ghcr.sh::latest_stable_tag` remains in the tree as a debug helper but is not called from the install path.

The signalk-server image is a separate case: it defaults to `:dirkwa` (the fork channel, not a version pin) and is updated via the engine's Versions tab, which DOES rewrite the Quadlet because version switching on the data plane is an operator-driven choice with semantic consequences (config compatibility, plugin breakage).

## Three-tier recovery model

Each tier is independent of the one above it. Changes that touch any of them must preserve that independence.

1. **Updater Console (`:3003`)** — the normal-path UI for version switches and self-update.
2. **Doctor Console (`:3004`)** — independent of the updater; owns last-known-good snapshots and can recover when the updater is broken. The doctor's read-only probes are deliberately unauthenticated so recovery always answers; only `/api/recover` is token-gated.
3. **`~/.local/bin/signalk-recovery`** (installed by `installer/linux/install-recovery-script.sh`) — a static bash script that works with zero containers running; the SSH-only safety net.

The updater's mutating endpoints are token-gated regardless of bind address.

## `install-signalk-command.sh` is a heredoc

`installer/linux/install-signalk-command.sh` writes `~/.local/bin/signalk` as a heredoc. **Every `$` inside the dispatcher body must be escaped as `\$`** — otherwise it expands at install time, not at run time. The single intentional unescaped expansion is `${SK_VERSION}` near the top, which bakes the installer version into the script.
