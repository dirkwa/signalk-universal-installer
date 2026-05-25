# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See [AGENTS.md](AGENTS.md) for the canonical workflow conventions (branch/commit rules, PR rules, pre-PR checklist, release flow), the filesystem invariants the engine containers depend on, and the "engine images run on `:latest`" rationale. **Read AGENTS.md first** — it is the source of truth for how to make changes here. The notes below cover what AGENTS.md does not.

## Shape of this repo

Pure bash + PowerShell. No build system, no `package.json`. Scripts are published verbatim via GitHub Pages on push to `master` and to `v*` tags — so an edit to any `.sh` is what users will execute. There is no test suite; "tests" mean running the actual installer on a clean target. AGENTS.md's "Filesystem invariants" table is the authoritative list of paths the engine containers depend on.

## The user-facing `signalk` command

`installer/linux/install-signalk-command.sh` writes `~/.local/bin/signalk` as a heredoc dispatcher (run `signalk help` for the current subcommand list). Because the file is a heredoc, **all `$` inside the dispatcher body must be escaped as `\$`** (otherwise they expand at install time, not at run time). The single unescaped expansion is `${SK_VERSION}` near the top, which is intentional — it bakes the installer version into the script.

`bug-report` produces `/tmp/signalk-bug-report-*.tar.gz`. The collector is written to redact credentials at every layer (auth tokens are presence-only, plugin configs and other secret-bearing files are excluded or redacted in place); when adding new captures, preserve that invariant rather than relying on the existing list staying current.

## Three-tier recovery model

The installer respects an invariant that the engine containers also enforce:

1. **Updater Console (`:3003`)** is the normal-path UI for version switches and self-update.
2. **Doctor Console (`:3004`)** is independent of the updater — it owns last-known-good snapshots and can recover when the updater is broken.
3. **`~/.local/bin/signalk-recovery`** (installed by `install-recovery-script.sh`) is a static bash script that works with zero containers running — the SSH-only safety net.

Changes that touch any of these tiers must preserve this independence. In particular, the doctor's read-only probes are deliberately unauthenticated so that recovery always answers; the updater's mutating endpoints are token-gated regardless of bind address.

## Pre-PR checks

See AGENTS.md's "Pre-PR checklist" — the same gates apply to Claude-authored changes here.
