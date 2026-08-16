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

## Devcontainer

A one-command development environment (pre-built server from the stack's own
`ghcr.io/dirkwa/signalk-server:dirkwa` image, plugin linking, shellcheck,
CodeRabbit CLI, Claude Code, Playwright e2e) lives under `.devcontainer/`
with its workspace in `dev/`. It runs with **host networking** (production
parity — socketcan works, mDNS *discovery* of LAN devices works while the
dev instance's own announcement is seeded off) and the dev signalk-server
on **port 4000**; dev server and browser IDE (:10800) are unauthenticated
and LAN-visible by design. It never touches a production install (production
map: 80/3000 server, 3003 updater, 3004 doctor). `dev/` and `.devcontainer/` are dev-only and NOT
published by GitHub Pages. See docs/devcontainer.md; workspace-specific agent
context is in `dev/CLAUDE.md`. The pre-PR checklist tooling (shellcheck,
`cr review`) is available inside the container.

## Workflow Conventions

This repo is maintained by Dirk Wahrheit. Workflow is deliberate; AI tools should follow it strictly.

### Branch and commit rules

- Branch names use **hyphens**, never slashes: `fix-something`, `feat-something`, `chore-release-1-6-0`.
- Angular conventional commits: `<type>(<scope>): <subject>`. Types: `feat|fix|docs|style|refactor|test|chore|perf`. Subject ≤ 50 chars, imperative mood, no period.
- **Every** commit on the branch follows that format, not just the first.
- One logical change per commit. Each commit is a meaningful, self-contained step.
- A version bump is its own commit and its own PR: `chore(release): X.Y.Z` and nothing else. Never fold a bump into a fix or a feature, and never fold a fix into a bump. The release notes list PRs, so a mixed PR describes itself as whichever half is in its title and hides the other; a lone bump is also the only thing CodeRabbit can safely skip (see below).
- No `Co-Authored-By` lines. No "Generated with Claude Code" attribution.

### PR rules

- Never commit directly to `master`. Every change goes through a PR.
- One logical change per PR. Refactors, behavior changes, and features belong in separate PRs.
- PR titles use the same Angular format as commits: `<type>(<scope>): <subject>`. The generated release notes are a list of PR titles, so a prose title lands in the changelog as prose. The title is also the only thing `.coderabbit.yaml`'s `ignore_title_keywords` can match, so a release PR is titled exactly `chore(release): X.Y.Z` — retitle it and it gets a full review of a one-line diff.
- PR titles describe what changes; PR bodies explain _why_.
- No checkboxes in PR descriptions. If you need a "Tested" section, list what was actually verified, not what's planned.
- PR descriptions must reflect reality. Never list speculative tests.

### Writing style

Applies to everything you write here: replies, commit messages, PR and issue text, docs, code comments. It does not override the PR rules above — a PR body still explains _why_, and a "Tested" section still lists what ran. Never trade accuracy for terseness: if the honest answer needs thirty lines, write thirty lines of fact.

Answer first. If the answer is "no", "nothing", or "I don't know", that is the entire first sentence.

Every sentence names something checkable — a file, a value, a command you ran, a claim you can point at. Generalize only from particulars you can name. A general sentence summarizing specifics you've established is fine; one substituting for specifics you haven't is a failure. Docs and specs are general statements by design — each one still has to be checkable against the thing it documents.

**Coinage.** Inventing a term, or borrowing jargon, then reusing it as though it carried meaning. "Load-bearing", "footgun", "the real X", anything in scare quotes doing definitional work. The term substitutes for the mechanism and hides that you don't have it. Test: replace the term with the literal mechanism. If you can't, say that instead. Use one consistent name for concrete things (the server stays "the server"); that consistency does not extend to invented abstractions.

- "That field is load-bearing." → "Removing that field makes `render-server-quadlet.sh` emit an empty `Image=` line."

**Aphorism.** A ruling that sounds conclusive but names no evidence or mechanism — "The one thing that matters is…". An unfalsifiable sentence has nothing in it to check, so a wrong one survives review. It's the missing mechanism that makes it one, not the sentence shape: "The installer never runs continuously" (line 10) is the same "X is not Y" form and is checkable. These cluster in closing sentences — end on the last concrete fact instead of a summarizing ruling.

- "It isn't being ignored; it's inert." → "`latest_stable_tag` is defined in `installer/linux/lib/ghcr.sh` and called from nothing in the install path."

**Defending in advance.** Hedges, "to be clear", "note that this doesn't mean…", pre-empting objections nobody raised. State the claim once. This does not cover factual limits — what you tested, what you didn't read, the conditions a claim holds under. Those are content, and the PR rules above require them.

**Over-explication.** The fact, plus its implications, plus why it matters, plus a walkthrough.

- "This means that when the cache invalidates, which happens on every write, you'll see the latency spike you were asking about earlier." → "Every write invalidates the cache."

State uncertainty as fact about your own knowledge — "I didn't test this", "I haven't read the caller" — never as a hedge bolted onto an assertion.

**Formatting.** Prose is the default. Headers, bullets, and bold are for genuinely enumerable content: parallel items, ordered steps, a comparison. Never split one thought across bullets. No preamble announcing what you're about to do, no closing offer of further help. In replies, no summary or takeaways section; structured documents like `docs/*.md` and PR bodies keep whatever structure serves them.

### Pre-PR checklist

Before pushing or opening a PR:

1. `shellcheck installer/**/*.sh scripts/*.sh .devcontainer/*.sh dev/*.sh` — lints all shell.
2. `bash -n` on every script to catch syntax errors.
3. Manual smoke: run the script on a clean VM or in a container, verify the documented behavior.
4. `cr review | tee /tmp/cr-review-<branch>.txt` — local CodeRabbit pass (plain text is the default; the CLI no longer knows `--plain`). Commit first, then review.

Skip `cr review` only for `chore(release): X.Y.Z` PRs.

### Release flow

There is no npm publish for this repo — it's pure bash. GitHub Pages publishes the script tree on every push to `master` and on `v*` tags. Tag triggers add the tag name as `INSTALLER_VERSION` via a `sed` substitution at deploy time. A version tag (`vX.Y.Z` — deliberately narrower than the Pages `v*` trigger, which also matches non-version v-tags like `v1-keeper-final`) also force-updates the `release` branch (`.github/workflows/release-branch.yml`) — the channel `signalk devpod up` clones — so master is free to break between tags without breaking new dev workspaces. The same workflow creates a GitHub Release with auto-generated notes (the merged PRs since the previous version tag) — the changelog is generated, never hand-written.

**There is no `CHANGELOG.md` and there should not be one.** The tag is the release act and the notes are generated from the PRs merged since the previous tag, so a hand-maintained file would only ever disagree with them. `.github/release.yml` shapes that output — read it for the current categories and exclusions. The constraint worth knowing before writing a PR: GitHub groups by **label**, not by commit type, and cannot read the Angular type out of a title. Labelling promotes a PR into a section; it is not what makes it appear, and a PR that matches no category still lands in the fallback rather than vanishing.

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
| `~/.config/containers/systemd/signalk-doctor-server.container` | installer | Quadlet for the doctor; not rewritten at runtime. Carries `SIGNALK_URL` / `SIGNALK_HTTPS_URL` templated from the install-time `SK_HTTP_PORT` / `SK_HTTPS_PORT` (80/443 by default) so the doctor's signalk-health probe tracks the chosen ports and follows the HTTP→HTTPS redirect signalk-server emits once TLS is enabled. |
| `~/.signalk/` | signalk-server | SignalK data, owned by signalk-server. The installer's writes here are narrow and idempotent: it installs the bundled plugins (`node_modules/`, via the container's own npm), seeds `plugin-config-data/*.json` to auto-enable them (never overwriting an existing file), and — when standard web ports are chosen — seeds `settings.json`'s `sslport` key only if absent (never sets `ssl`, never clobbers an existing value). It writes nothing else here and never touches user-authored config. |
| `~/.signalk-updater/` | updater container + installer | Tokens, `hardware.json` (detected serial / CAN / Bluetooth / GPIO / audio, on a HALPI2 also `board` + `onboardSerial`, plus an optional `socketcanCandidate` written by `signalk socketcan`), logs. |
| `~/.signalk-updater/install.log` | installer | The installer's own console output, tee'd here so `signalk bug-report` can bundle it (the `curl … \| bash` transcript is otherwise terminal-only). **Truncated, not appended**, at the start of each run — it holds one install's worth of output. Suppressed when `SIGNALK_NO_INSTALL_LOG=1`. Contains no secrets: tokens are written straight to 0600 files or captured via command substitution, never echoed. |
| `~/.signalk-updater/bug-reports/` (Windows only) | Windows `signalk` shim | **Ephemeral** staging dir for `signalk bug-report` on Windows — not a persistent invariant. The shim runs the in-VM bundler with `--to` here (on-disk, not tmpfs), copies the tarball to the Windows Desktop, then deletes the VM-side copy. Not created on Linux/macOS, where `bug-report` writes straight to a host-reachable path. |
| `~/.signalk-doctor/` | doctor container + installer | Snapshots of Quadlets, last-good.json, tokens. |
| `~/.signalk-doctor/installer-payload/` | doctor container (writer) + `signalk-bluetooth` / `signalk render-server` / `signalk halpi2` helpers (readers) | Quadlet templates + detect-hardware.sh + render-server-quadlet.sh + signalk-halpi2.tmpl staged verbatim by the doctor's `/api/installer/refresh` (`signalk update`). Inert until consumed: the bash installer's render step reads them; `signalk bluetooth enable` installs `signalk-dbus-proxy.container.template` from here (substituting the pinned proxy image) when the live quadlet is missing; and `signalk render-server` runs the staged `render-server-quadlet.sh` against `signalk-server.container.template` + `~/.signalk-updater/hardware.json` to rebuild the live server Quadlet on an existing box (#217). |
| `~/.signalk-doctor/signalk-token` | installer | Admin token (mode 0600) generated via `podman exec signalk-server signalk-generate-token -u admin -e 5y …`. Read by the doctor's drift scanner for the admin-gated `/skServer/diagnostics` endpoint. Idempotent: never overwritten by the installer if already non-empty. Rotation is operator-initiated (regenerate, overwrite the file; the doctor invalidates its cache on the next 401/403). |
| `~/.local/bin/signalk-recovery` | installer | Static bash recovery script — works with zero containers running. |
| `~/.local/bin/signalk-halpi2` | installer (`install-halpi2-script.sh`) | Hat Labs HALPI2 helper (`signalk halpi2 status\|detect\|apply\|connections`). `apply` edits, with sudo: `/boot/firmware/config.txt` (marker block, backed up), `/etc/apt/sources.list.d/hatlabs.sources` + `/etc/apt/keyrings/hatlabs.asc`, `/etc/modules-load.d/i2c-dev.conf`, `/etc/systemd/network/80-signalk-can0.network`, `/etc/udev/rules.d/80-signalk-can.rules`. install.sh runs the template directly at step 2c and reuses the preflight "reboot and re-run" exit; also staged in `installer-payload/` as the CLI fallback. docs/halpi2.md. |
| `~/.config/systemd/user/signalk-resolv-watch.{path,service}` | installer (via `signalk resolv-watch`) | Container DNS self-heal: recreates signalk-server when host DNS appeared only after the container started (boot beat DHCP). Unit bodies live in `signalk.tmpl` as the single owner; re-ensured on every `signalk render-server`. |
| `~/.config/systemd/user/signalk-netgate-watch.{timer,service}` | installer (via `signalk netgate-watch`) | pasta gateway self-heal: restarts an engine container that started before the host had a default route and latched onto pasta's link-local fallback, leaving `host.containers.internal` black-holed for the container's lifetime (#250). Same single-owner + ride-along model as resolv-watch. This is the only route by which a box installed before the Quadlets' route gate gets repaired — `render-server` rewrites `signalk-server.container` only. |

The installer's writes under `~/.signalk/` are limited to the narrow, idempotent set described in the table row above (bundled-plugin install, plugin auto-enable config, and the opt-in `sslport` seed). It never edits user-authored config beyond that, and never starts/stops `signalk-server` except via the updater's REST API (with a direct `systemctl --user start` fallback when the updater is unreachable). The HALPI2 connections (step 15c, `signalk halpi2 connections`) go through the server's own admin API (`GET`/`POST /skServer/providers` with `~/.signalk-doctor/signalk-token`), so `settings.json` is written by the server, and only for ids that are absent.

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
