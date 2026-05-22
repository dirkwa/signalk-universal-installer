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
