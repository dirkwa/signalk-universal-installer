# SignalK development environment for signalk-universal-installer
#
# Based on the stack's own server image: identical runtime to production
# (Ubuntu, Node 24, npm allow-scripts fix for canboatjs, podman + docker
# CLIs, libnss-mdns, containers.conf routing podman to /var/run/docker.sock)
# AND a pre-built signalk-server at /home/node/signalk — plugin development
# starts immediately, no clone/build needed.
FROM ghcr.io/dirkwa/signalk-server:dirkwa

# The image's ENTRYPOINT execs signalk-server and appends any args — the
# devcontainer's keep-alive command would be passed to the server. Reset both;
# the dev server is managed via dev/dev.sh instead.
ENTRYPOINT []
CMD ["/bin/sh"]

USER root

# npm >= 12 gates dependency lifecycle scripts (same trap as canboatjs in
# the server image). The Claude Code devcontainer FEATURE builds on top of
# this image as root and npm-installs @anthropic-ai/claude-code globally —
# without this approval its postinstall is silently skipped and /usr/bin/
# claude stays an error stub ("claude native binary not installed"),
# which also breaks plugin/marketplace installs from .claude/settings.json.
RUN printf 'allow-scripts[]=@anthropic-ai/claude-code\n' >> /root/.npmrc

# ── Tools on top of the server image ────────────────────────────────────
# shellcheck: required by the repo's pre-PR checklist (AGENTS.md).
# can-utils/socat: N2K and serial debugging (git, jq, curl already in base).
# unzip: needed by the CodeRabbit CLI installer below.
# openssh-client: the base image ships git but no ssh — `git clone
# git@github.com:...` dies with "cannot run ssh" (field report).
# gh: GitHub CLI for clone/auth/PR work from inside the container; from
# GitHub's apt repo, same keyring pattern the base uses for docker-ce-cli.
# Basic network debugging (boat networks are half the job): ping,
# nslookup/dig, wget, traceroute, netcat, tcpdump, htop. bind9-dnsutils
# is declared here even though a devcontainer feature happens to drag it
# in — guaranteed, not incidental. Verified caveats: raw-socket tools
# (traceroute, live tcpdump captures) EPERM in rootless podman — run
# those on the HOST. ping is rescued below: its cap_net_raw FILE
# CAPABILITY makes execve itself fail in a rootless userns ("bash:
# /usr/bin/ping: Operation not permitted"); stripped, ping falls back to
# unprivileged ICMP datagram sockets, which the host's ping_group_range
# permits on systemd hosts (field-verified under host networking).
# dig/nslookup/nc/wget/curl use plain sockets and work everywhere.
# pandoc: converts the repo's Markdown (docs/*.md, PR and issue text) to
# HTML/docx/plain text locally. ~198MB installed with its 4 deps
# (pandoc-data, liblua5.4-0, libnuma1, libyaml-0-2). PDF output is NOT
# available: that needs a LaTeX engine or wkhtmltopdf, both of which are
# recommends-only and stay out under --no-install-recommends.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        can-utils \
        socat \
        shellcheck \
        unzip \
        openssh-client \
        gh \
        iputils-ping \
        bind9-dnsutils \
        wget \
        traceroute \
        netcat-openbsd \
        tcpdump \
        htop \
        pandoc \
    && setcap -r /usr/bin/ping \
    && rm -rf /var/lib/apt/lists/*

# ── Playwright / Chromium ────────────────────────────────────────────────
# Browser + system deps in a shared, world-readable location so both the
# 'node' user and CI find them. Baked into the image: e2e tests run
# immediately after `devpod up` — no postCreate download.
# Keep this version in sync with @playwright/test in dev/package.json.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN npx -y playwright@1.61.1 install --with-deps chromium \
    && chmod -R a+rX /opt/playwright

# Stable path to the baked Chromium for tools pinned to a slightly different
# playwright-core (the Playwright MCP server in .mcp.json uses it via
# --executable-path, so it never tries to download its own browser).
RUN ln -s "$(find /opt/playwright/chromium-[0-9]* -name chrome -type f | head -n1)" \
        /usr/local/bin/chromium-baked \
    && /usr/local/bin/chromium-baked --version

# ── Host podman socket ──────────────────────────────────────────────────
# The host's rootless podman socket DIRECTORY is bind-mounted at
# /run/host-podman: a directory mount never fails container creation when
# the socket is absent, and a socket enabled on the host later appears
# inside without a rebuild. Production mounts the socket at
# /var/run/docker.sock, but /run is a tmpfs at runtime (podman), so a baked
# symlink there would not survive — instead the image's containers.conf is
# repointed and devcontainer.json sets CONTAINER_HOST/DOCKER_HOST to match.
# post-start.sh probes the socket and prints an INFO when it is absent.
RUN sed -i 's|unix:///var/run/docker.sock|unix:///run/host-podman/podman.sock|' \
        /etc/containers/containers.conf

# ── CodeRabbit CLI ──────────────────────────────────────────────────────
# Installed for the 'node' user (binary: coderabbit / cr).
# Auth: CODERABBIT_API_KEY (post-start) or `coderabbit auth login`.
# The installer exits non-zero on this base even after a successful
# install — assert the binary instead of trusting the exit code.
USER node
RUN curl -fsSL https://cli.coderabbit.ai/install.sh | sh || true; \
    test -x /home/node/.local/bin/coderabbit
ENV PATH="/home/node/.local/bin:${PATH}"
