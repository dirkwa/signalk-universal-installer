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

# ── Tools on top of the server image ────────────────────────────────────
# shellcheck: required by the repo's pre-PR checklist (AGENTS.md).
# can-utils/socat: N2K and serial debugging (git, jq, curl already in base).
# unzip: needed by the CodeRabbit CLI installer below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        can-utils \
        socat \
        shellcheck \
        unzip \
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
