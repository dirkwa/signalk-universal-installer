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

Heads-up: both of those are visible to everyone on your boat/home network
and have **no password**. Fine on a network you control; see
[devcontainer.md](devcontainer.md#working-from-another-machine-headless-box)
for how to secure them (short version: Tailscale).

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
