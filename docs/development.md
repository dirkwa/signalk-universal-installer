# Development Guide (the simple version)

This guide gets you developing SignalK plugins — or the SignalK server
itself — on a boat computer (Raspberry Pi, Orange Pi, or similar) that was
set up with the universal installer. It assumes the box is **headless**:
no monitor attached, you work from another computer over SSH or a browser.

It deliberately skips the deep technical detail. When you want the full
story (networking modes, volumes, troubleshooting), see the reference:
[devcontainer.md](devcontainer.md).

**Which section do I want?**

| I want to… | Section |
|---|---|
| Hack on a plugin against my real, live server | [1. Plugin development on your live server](#1-plugin-development-on-your-live-server) |
| Try a different server version (beta, master) on my live server | [2. Switching server versions on your live server](#2-switching-server-versions-on-your-live-server) |
| Develop plugins in a safe, separate dev server | [3. Plugin development in a dev environment (DevPod)](#3-plugin-development-in-a-dev-environment-devpod) |
| Change the SignalK server's own source code | [4. SignalK server development in the dev environment](#4-signalk-server-development-in-the-dev-environment) |
| Pick up the latest changes in my dev environment | [5. Keeping the dev environment up to date](#5-keeping-the-dev-environment-up-to-date) |

Sections 1–2 work directly on your **production** install — quick, and you
see real boat data, but a broken plugin breaks your real server. Sections
3–4 use a **separate development server** that runs side by side with
production and can be thrown away and recreated at any time.

---

## 1. Plugin development on your live server

The installer runs signalk-server inside a container. The container can
only see one directory of yours: `~/.signalk` (it appears inside the
container as `/home/node/.signalk`). That leads to the one rule that makes
everything work:

> **Your plugin repositories must live under `~/.signalk`** — anywhere
> else and the server literally cannot see the files.

The convention is `~/.signalk/github/`:

```bash
mkdir -p ~/.signalk/github
cd ~/.signalk/github
git clone https://github.com/you/my-signalk-plugin.git
```

Optional but recommended — a shortcut so your repos feel like they live in
your home directory:

```bash
ln -s ~/.signalk/github ~/github
```

Now `cd ~/github/my-signalk-plugin` works, and the files are still where
the server can see them.

### Install the plugin into the server

Run npm **inside the server's own container** — that way you don't need
Node installed on the box, and you're guaranteed the same Node version the
server uses:

```bash
podman exec signalk-server sh -c 'cd /home/node/.signalk && npm install ./github/my-signalk-plugin'
```

(If you have Node/npm on the host, `cd ~/.signalk && npm install
./github/my-signalk-plugin` works too.)

npm installs a local folder as a **link**, not a copy — so edits to your
repo take effect without reinstalling. Use the folder name of your clone;
the plugin shows up in SignalK under the `name` in its `package.json`.

### Restart and enable

No command line needed for this part: open the admin UI (`http://<box-ip>`,
or `:3000` depending on what you chose at install time), log in, and click
**Restart** in the top-right corner. When the server comes back, go to
**Server → Plugin Config**, find your plugin and enable it.

### The edit cycle

Node caches loaded code, so after every code change restart the server with
the **Restart** button in the admin UI.

Restart it that way, not with `systemctl --user restart signalk-server`. In
this stack the updater container owns the server's lifecycle — it is what
version switching and `signalk stop` / `signalk start` drive, and reaching
past it can leave its idea of the server out of step with what is actually
running. (If you have no admin UI to click — a crashed server, a broken
plugin that won't load — the Updater Console at `http://<box-ip>:3003` has
its own restart control on the Dashboard.)

Toggling the plugin off/on in the admin UI is **not** enough. If your
plugin is TypeScript, run its build (`npm run build` in the repo) before
restarting.

---

## 2. Switching server versions on your live server

One thing to know up front: the live server runs a **pre-built container
image**, not source code on disk. There is no way to point the live server
at a git clone of signalk-server — that's what the dev environment is for
(see [section 4](#4-signalk-server-development-in-the-dev-environment)).

What you *can* do on a live install is switch between **published builds**
— releases, betas, and builds of the latest master branch — with a couple
of clicks:

1. Open the **Updater Console** at `http://<box-ip>:3003`.
2. Go to the **Versions** tab. It lists the available builds, grouped by
   channel (stable releases, plus beta and master builds — tick the
   checkboxes in that view to show the beta/master channels).
3. Pick a version. The updater pulls it in the background, then **Switch**
   restarts the server on the new version.

Switching back is the same process in reverse. If a switch leaves the
server broken, the **Doctor Console** at `http://<box-ip>:3004` can roll
you back to the last-known-good state.

This is the supported way to test "does my problem still happen on
master?" on a real install, without touching git or a compiler.

---

## 3. Plugin development in a dev environment (DevPod)

The dev environment gives you a **second, disposable SignalK server** on
the same box, with a full development setup (editor in the browser, git,
Node, test data). Your production install keeps running untouched — the
dev server uses port **4000** precisely so the two never collide.

Under the hood this is a "devcontainer" managed by a free tool called
[DevPod](https://devpod.sh). There are two ways to start it; pick one.

### Option A: everything on the box (easiest)

If the box was set up with the universal installer, it's one command,
run on the box over SSH:

```bash
signalk devpod up
```

This installs the DevPod command-line tool on first use, builds the dev
environment, and starts a **browser-based VS Code**. When it finishes,
open in your browser:

- **Editor:** `http://<box-ip>:10800/?folder=/workspaces/signalk-universal-installer`
- **Dev SignalK server:** `http://<box-ip>:4000`

Heads-up, and worth taking seriously: both of those are visible to everyone
on your boat/home network and have **no password**. The editor is a shell on
the box for anyone who opens it. This default assumes a network you control
and no untrusted devices on it — on a marina wifi, a shared network, or
anything you don't own, secure them before you start working:

- **Editor (:10800):** `tailscale serve --bg 10800`, then use only the
  tailnet HTTPS URL. If Tailscale is already up on the box, `signalk devpod
  up` does this for you and prints the URL — use that one.
- **Dev server (:4000):** enable security in its admin UI.

Each measure covers only its own port, and `tailscale serve` is a proxy, not
a firewall — the plain ports stay reachable on the LAN either way. Full
detail in
[devcontainer.md](devcontainer.md#working-from-another-machine-headless-box).

### Option B: DevPod Desktop on your laptop (native VS Code)

If you'd rather use VS Code installed on your own computer:

1. Install [DevPod Desktop](https://devpod.sh) on your laptop/desktop.
2. In DevPod, add a **Provider** → choose **SSH** → point it at your box
   (e.g. `pi@boatpi.local`) — the same address you use to SSH in.
3. Create a **Workspace**:
   - Source: `https://github.com/dirkwa/signalk-universal-installer`
     (or your own fork of it)
   - Provider: the SSH provider you just made
   - IDE: **VS Code**
4. DevPod builds the environment on the box and opens your local VS Code
   connected to it.

### Where do plugins go?

Inside the workspace, plugin repos go under `dev/plugins/`:

```bash
cd dev/plugins
git clone https://github.com/you/my-signalk-plugin.git
cd ..
./dev.sh restart
```

That's the whole install: on every start/restart, the dev server finds every
plugin under `dev/plugins/` and links it into the server. There's no
`npm install` step for you to run — a plugin with no `node_modules/` yet
gets its dependencies installed on the next start.

Building is deliberately *not* automatic on every restart — that would make
each one slow. A plugin is built only when its compiled entry point (the
`main` in its `package.json`) is missing, which covers a fresh TypeScript
checkout, or when you ask for it explicitly. So after editing a TypeScript
plugin, restart with:

```bash
SK_DEV_PLUGIN_BUILD=1 ./dev.sh restart
```

Skip that and your edits never get compiled — the server keeps loading the
previous build, and it looks like your change did nothing.

Your plugin checkouts survive even if you delete and recreate the
workspace — they live in a persistent volume on the box.

### Day-to-day commands

Run these from the `dev/` directory (they're also one-click buttons in the
VS Code status bar):

| Command | What it does |
|---|---|
| `./dev.sh start` / `stop` / `restart` | manage the dev server |
| `./dev.sh demo` | feed it sample NMEA data — no boat needed |
| `./dev.sh status` / `logs` | check on it |

The dev server's admin UI is at `http://<box-ip>:4000`.

### How do I get a shell in it?

- Simplest: open a terminal **inside the IDE** (browser VS Code or
  desktop VS Code — Terminal → New Terminal).
- From the box: `signalk devpod ssh`
- From your laptop (Option B): `devpod ssh signalk-universal-installer`

---

## 4. SignalK server development in the dev environment

Set up the dev environment exactly as in
[section 3](#3-plugin-development-in-a-dev-environment-devpod) — nothing
extra to install.

By default the dev server runs a **pre-built** copy of signalk-server
baked into the environment: nothing to compile, and perfect for plugin
work. To work on the server's own source code, put a checkout at
`dev/signalk-server/` — the dev scripts automatically prefer it over the
pre-built copy:

```bash
git clone --filter=blob:none https://github.com/SignalK/signalk-server.git dev/signalk-server
bash .devcontainer/post-create.sh   # installs dependencies + builds (takes a while)
```

Then the cycle is: edit → `npm run build` (in `dev/signalk-server`) →
`dev/dev.sh restart`.

`npm run build` compiles the server itself. If you changed the admin UI or
one of the workspace packages under `packages/`, use `npm run build:all`
instead — it also builds those, and it's the same build the setup script
above runs.

### Using your own fork

Clone your fork instead of the upstream repo, and keep upstream as a
second remote so you can pull in their changes:

```bash
git clone --filter=blob:none https://github.com/YOURNAME/signalk-server.git dev/signalk-server
cd dev/signalk-server
git remote add upstream https://github.com/SignalK/signalk-server.git
```

Switching branches or tags is plain git — check out what you want, then
rebuild and restart:

```bash
cd dev/signalk-server
git fetch upstream
git checkout <branch-or-tag>
npm install          # only needed if the branch changed dependencies
npm run build
cd .. && ./dev.sh restart
```

### Going back to the pre-built server

Remove (or rename) the checkout and restart:

```bash
mv dev/signalk-server dev/signalk-server.off
dev/dev.sh restart
```

For debugging with breakpoints, launch configurations are included — see
["Developing the server" in devcontainer.md](devcontainer.md#developing-the-server).

---

## 5. Keeping the dev environment up to date

This section assumes the dev environment from
[section 3](#3-plugin-development-in-a-dev-environment-devpod) — created
with `signalk devpod up`.

Four things update on their own schedule, and confusing them is the usual
source of "I pulled but nothing changed":

| What changed | What to do |
|---|---|
| Scripts, tests, docs in the workspace | `git pull` (+ `./dev.sh restart`) |
| Anything under `.devcontainer/` | `signalk devpod up --recreate` on the box |
| The pre-built SignalK server in the image | pull the image, then `--recreate` |
| Your own plugin / server checkouts | `git pull` in each of them |

### The everyday update

In a terminal **inside the IDE**:

```bash
cd /workspaces/signalk-universal-installer
git pull
cd dev && ./dev.sh restart
```

That's the whole update for almost everything: `dev.sh` and the plugin
linker, the e2e tests, the installer scripts and Quadlet templates, the
docs. None of it is baked into the container — it's a checkout on the box
that the container simply reads, so a pull takes effect on the next
restart.

Two occasional extras:

- If the pull touched `dev/package.json`: `cd dev && npm install`.
- If it touched `.vscode/tasks.json`: reload the IDE window (*Developer:
  Reload Window*) so the status-bar buttons pick up the new task list.

A workspace created by `signalk devpod up` tracks the **`release`**
branch, so a pull always lands on the latest tagged release, never on a
half-finished master. See
["Release channel" in devcontainer.md](devcontainer.md#release-channel).

### When the container needs rebuilding

The files that *define* the container — `.devcontainer/Dockerfile`,
`devcontainer.json`, `host-prepare.sh` — are only read when the container
is built. Pulling them changes nothing until you rebuild.

Check before you pull:

```bash
git fetch
git diff --stat HEAD @{u} -- .devcontainer
```

No output means no rebuild is needed. If there is output, pull as above,
then run this **from an SSH session on the box** — not from the IDE
terminal, which lives inside the container being replaced:

```bash
signalk devpod up --recreate
```

It rebuilds the image and re-runs the setup script, so give it a few
minutes. The IDE URL doesn't change; reload the browser tab when it's
done.

Nothing of yours is lost. Your dev SignalK config and installed plugins,
your Claude Code / CodeRabbit / `gh` logins, and your plugin checkouts
under `dev/plugins/` all live in named volumes on the box that survive
rebuilds. The workspace itself stays put too, uncommitted edits included
— it's on the box, not in the container.

One shortcut: if the only thing that changed is
`.devcontainer/post-create.sh` or `post-start.sh`, you can run the script
by hand inside the container instead of rebuilding — both are safe to
re-run (they install what's missing and never clobber existing config):

```bash
bash .devcontainer/post-create.sh
```

### Getting a newer pre-built SignalK server

The dev environment is built on the stack's own server image, and it
tracks a channel (`:dirkwa`) rather than a fixed version. Git knows
nothing about that image, and a rebuild happily reuses the copy already on
the box — so a newer server build needs an explicit pull first, on the
box:

```bash
podman pull ghcr.io/dirkwa/signalk-server:dirkwa   # or docker pull
signalk devpod up --recreate
```

This is only about the *pre-built* server. If you have a source checkout
at `dev/signalk-server/` — see
[section 4](#4-signalk-server-development-in-the-dev-environment) — that
one wins and the image copy is unused.

### Your own checkouts

Plugin repos under `dev/plugins/` and a server checkout at
`dev/signalk-server/` are separate git repositories — the workspace pull
never touches them. Update each one where it lives:

```bash
cd dev/plugins/my-signalk-plugin && git pull
cd ../.. && SK_DEV_PLUGIN_BUILD=1 ./dev.sh restart
```

For the server checkout, the fetch/build/restart cycle is the one in
[section 4](#using-your-own-fork).

### Keeping the `signalk` command itself current

`signalk devpod up` comes from the installer's `signalk` command on the
box, which is separate from the dev workspace. Refresh it with:

```bash
signalk update
```

This is a production-side command — it updates `~/.local/bin/signalk` and
the recovery script, and doesn't touch the dev environment. Worth doing
before a `--recreate` if your `signalk` command is old.

### Starting over

A delete and recreate is always safe, and is also how you switch channels
(for instance to test unreleased master):

```bash
signalk devpod delete
signalk devpod up                              # latest release
SIGNALK_DEVPOD_REF=master signalk devpod up    # or unreleased master
```

The volumes — dev config, plugin checkouts, logins — survive the delete.
The workspace checkout does **not**, so commit and push anything you
still want first.
