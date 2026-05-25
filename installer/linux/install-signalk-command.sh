#!/usr/bin/env bash
# Drops ~/.local/bin/signalk — the user-facing command dispatcher.
# Wraps health, uninstall, bug-report, and recovery so operators don't
# have to remember the four script paths. ~/.local/bin/signalk-recovery
# is still installed as the SSH-only safety net (CC-3) and is the
# delegation target for `signalk recover`.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/colors.sh"

BIN_DIR="${HOME}/.local/bin"
TARGET="${BIN_DIR}/signalk"
mkdir -p "$BIN_DIR"

# Embed the installer-version string so `signalk version` reports
# something useful. Caller (install.sh) exports INSTALLER_VERSION.
SK_VERSION="${INSTALLER_VERSION:-unknown}"

cat >"$TARGET" <<SIGNALK_DISPATCHER_EOF
#!/usr/bin/env bash
# signalk — user-facing dispatcher for the SignalK container stack.
# Installed by signalk-universal-installer.
#
# Usage:
#   signalk health         show stack health (containers, services, URLs)
#   signalk recover [...]  delegate to ~/.local/bin/signalk-recovery
#   signalk bug-report     bundle logs + state into /tmp/signalk-bug-report-*.tar.gz
#   signalk uninstall      stop services + remove Quadlets (preserves data)
#   signalk version        print installer version
#   signalk help           show this help

set -euo pipefail

SK_VERSION="${SK_VERSION}"

UPDATER_URL=\${UPDATER_URL:-http://127.0.0.1:3003}
DOCTOR_URL=\${DOCTOR_URL:-http://127.0.0.1:3004}
SIGNALK_URL=\${SIGNALK_URL:-http://127.0.0.1:3000/signalk}
QUADLET_DIR="\${HOME}/.config/containers/systemd"
UNITS=(signalk-server signalk-updater-server signalk-doctor-server)

usage() {
    sed -n '2,11p' "\$0" | sed 's/^# \\{0,1\\}//'
}

cmd_version() {
    echo "signalk \$SK_VERSION"
}

cmd_health() {
    echo "=== SignalK Stack Health ==="
    for entry in \\
        "signalk-server  \$SIGNALK_URL" \\
        "updater (:3003) \$UPDATER_URL/api/health" \\
        "doctor (:3004)  \$DOCTOR_URL/api/health"; do
        name=\${entry% *}
        url=\${entry##* }
        if curl -fsS -o /dev/null -m 5 "\$url"; then
            printf '  [OK]   %-20s %s\\n' "\$name" "\$url"
        else
            printf '  [FAIL] %-20s %s\\n' "\$name" "\$url"
        fi
    done

    echo
    echo "=== systemd-user units ==="
    systemctl --user --no-pager list-units --all 'signalk-*' 2>/dev/null || true

    echo
    echo "=== Container snapshot ==="
    podman ps -a --filter 'name=signalk-' \\
        --format '{{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true

    echo
    echo "For deeper diagnostics:"
    echo "  curl -fsS \$DOCTOR_URL/api/probes | jq ."
    echo "  signalk recover doctor"
}

cmd_recover() {
    if [[ ! -x "\$HOME/.local/bin/signalk-recovery" ]]; then
        echo "[ERR] ~/.local/bin/signalk-recovery is missing; reinstall the stack" >&2
        exit 1
    fi
    exec "\$HOME/.local/bin/signalk-recovery" "\$@"
}

cmd_uninstall() {
    echo "Stopping signalk-* units..."
    for u in "\${UNITS[@]}"; do
        systemctl --user stop "\${u}.service" 2>/dev/null || true
    done

    echo "Removing Quadlet files..."
    for u in "\${UNITS[@]}"; do
        rm -f "\$QUADLET_DIR/\${u}.container"
    done

    echo "Removing podman containers..."
    for u in "\${UNITS[@]}"; do
        if podman container exists "\$u" 2>/dev/null; then
            podman rm -f "\$u" 2>/dev/null || true
        fi
    done

    systemctl --user daemon-reload || true

    echo
    echo "Preserved (intentional):"
    echo "  ~/.signalk/                — SignalK configs + plugins"
    echo "  ~/.signalk-updater/        — Tokens, hardware.json"
    echo "  ~/.signalk-doctor/         — Snapshots, last-good.json"
    echo "  ~/.signalk-backup/         — Backup repo (if present)"
    echo "  ~/.local/bin/signalk-recovery — Host recovery script"
    echo "  ~/.local/bin/signalk       — This command"
    echo
    echo "To purge ALL data, run:"
    echo "  rm -rf ~/.signalk ~/.signalk-updater ~/.signalk-doctor ~/.signalk-backup"
    echo "  rm -f  ~/.local/bin/signalk ~/.local/bin/signalk-recovery"
    echo "Done."
}

cmd_bug_report() {
    local stamp
    stamp=\$(date -u +%Y%m%dT%H%M%SZ)
    local outdir
    outdir=\$(mktemp -d -t signalk-bug-report.XXXXXX)
    local bundle="\$outdir/signalk-bug-report-\$stamp"
    mkdir -p "\$bundle"

    echo "[i] Collecting diagnostics into \$bundle"

    # Host context.
    {
        echo "=== signalk version ==="
        echo "installer: \$SK_VERSION"
        echo
        echo "=== uname -a ==="
        uname -a 2>&1 || true
        echo
        echo "=== /etc/os-release ==="
        cat /etc/os-release 2>&1 || true
        echo
        echo "=== date ==="
        date -u 2>&1 || true
        echo
        echo "=== uptime ==="
        uptime 2>&1 || true
    } >"\$bundle/host.txt" 2>&1

    # Container runtime.
    {
        echo "=== podman --version ==="
        podman --version 2>&1 || true
        echo
        echo "=== podman info ==="
        podman info 2>&1 || true
        echo
        echo "=== podman ps -a (signalk-) ==="
        podman ps -a --filter 'name=signalk-' \\
            --format '{{.Names}}\\t{{.Status}}\\t{{.Image}}' 2>&1 || true
        echo
        echo "=== podman images (signalk + dirkwa) ==="
        podman images --format '{{.Repository}}:{{.Tag}}\\t{{.ID}}\\t{{.Created}}' \\
            2>&1 | grep -E 'signalk|dirkwa' || true
        echo
        echo "=== docker --version (if shim) ==="
        docker --version 2>&1 || true
    } >"\$bundle/runtime.txt" 2>&1

    # systemd-user state.
    {
        echo "=== systemctl --user list-unit-files signalk-* ==="
        systemctl --user list-unit-files 'signalk-*' 2>&1 || true
        echo
        echo "=== systemctl --user list-units signalk-* (incl. inactive) ==="
        systemctl --user list-units --all 'signalk-*' 2>&1 || true
        echo
        # Per-unit status with -l so long lines aren't truncated. The
        # restart-timing field 'Active: active (running) since ...' and
        # the recent journal slice 'systemd[778]: Scheduled restart job,
        # restart counter is at N' are the most useful pieces for
        # diagnosing "I clicked Restart but it didn't come back".
        for u in "\${UNITS[@]}"; do
            echo "=== systemctl --user status -l \${u}.service ==="
            systemctl --user status -l --no-pager "\${u}.service" 2>&1 || true
            echo
        done
        # Drop-ins under .service.d/ are operator overrides the Quadlet
        # itself doesn't show. They explain otherwise-surprising
        # behavior changes; capture path + contents.
        for u in "\${UNITS[@]}"; do
            dropdir="\$HOME/.config/systemd/user/\${u}.service.d"
            if [[ -d "\$dropdir" ]]; then
                echo "=== \$dropdir contents ==="
                ls -la "\$dropdir" 2>&1 || true
                for f in "\$dropdir"/*.conf; do
                    [[ -f "\$f" ]] || continue
                    echo "--- \$f ---"
                    cat "\$f" 2>&1 || true
                done
                echo
            fi
        done
        echo "=== systemd-analyze --user blame (top 15) ==="
        systemd-analyze --user blame 2>&1 | head -15 || true
        echo
        echo "=== systemctl --user list-jobs ==="
        # If a start/restart is stuck waiting on a dependency the
        # journal often hides, the job queue surfaces it.
        systemctl --user list-jobs 2>&1 || true
        echo
        echo "=== loginctl show-user (Linger) ==="
        loginctl show-user "\$USER" -p Linger 2>&1 || true
    } >"\$bundle/systemd.txt" 2>&1

    # Journal — last 24h per unit. -x adds systemd's explanation lines
    # (Subject:/Defined-By: blocks). Truncate aggressively; logs are
    # noisy but the explanation lines are essential for "why didn't
    # this unit start when it should have."
    for u in "\${UNITS[@]}"; do
        journalctl --user -xeu "\${u}.service" --since '24 hours ago' --no-pager \\
            >"\$bundle/journal-\${u}.log" 2>&1 || true
    done

    # Quadlet sources (config, not secrets).
    mkdir -p "\$bundle/quadlets"
    for u in "\${UNITS[@]}"; do
        if [[ -f "\$QUADLET_DIR/\${u}.container" ]]; then
            cp "\$QUADLET_DIR/\${u}.container" "\$bundle/quadlets/\${u}.container"
        fi
    done

    # Doctor snapshots index (file listing only — snapshot contents
    # could be large and contain the same Quadlets we already copied).
    {
        echo "=== last-good.json ==="
        cat "\$HOME/.signalk-doctor/last-good.json" 2>&1 || true
        echo
        echo "=== snapshot file listing ==="
        ls -la "\$HOME/.signalk-doctor/snapshots/" 2>&1 || true
    } >"\$bundle/doctor-state.txt" 2>&1

    # Token presence — NEVER the value.
    {
        for f in "\$HOME/.signalk-updater/token" "\$HOME/.signalk-doctor/token"; do
            if [[ -f "\$f" ]]; then
                local mode
                mode=\$(stat -c '%a' "\$f" 2>/dev/null || echo "?")
                printf '%s — present, mode %s\\n' "\$f" "\$mode"
            else
                printf '%s — MISSING\\n' "\$f"
            fi
        done
    } >"\$bundle/tokens.txt" 2>&1

    # Console health.
    {
        for entry in \\
            "signalk-server  \$SIGNALK_URL" \\
            "updater (:3003) \$UPDATER_URL/api/health" \\
            "doctor (:3004)  \$DOCTOR_URL/api/health"; do
            name=\${entry% *}
            url=\${entry##* }
            echo "--- \$name (\$url) ---"
            curl -fsS -m 5 "\$url" 2>&1 || echo "(unreachable)"
            echo
        done
    } >"\$bundle/console-health.txt" 2>&1

    # Hardware detection (non-secret).
    if [[ -f "\$HOME/.signalk-updater/hardware.json" ]]; then
        cp "\$HOME/.signalk-updater/hardware.json" "\$bundle/hardware.json"
    fi

    # SignalK plugin state — metadata only, no configuration bodies.
    # Plugin configs in plugin-config-data/*.json routinely hold
    # secrets (MQTT passwords, cloud-sync API keys, OAuth tokens) and
    # there is no central registry of which fields are sensitive across
    # the whole plugin ecosystem. Limit the bundle to id + version +
    # enabled flag so the bug report shows which plugins are installed
    # and which are running, without leaking credentials. Operators who
    # need to share a specific plugin's config can attach it manually.
    SIGNALK_DIR="\$HOME/.signalk"
    if [[ -d "\$SIGNALK_DIR" ]] && command -v jq >/dev/null 2>&1; then
        cfg_dir="\$SIGNALK_DIR/plugin-config-data"
        pkg="\$SIGNALK_DIR/package.json"
        {
            echo "=== SignalK plugin state (metadata only) ==="
            echo "# Configuration bodies are intentionally NOT included."
            echo "# Plugin configs routinely contain credentials."
            echo
            count=0
            if [[ -d "\$cfg_dir" ]]; then
                for f in "\$cfg_dir"/*.json; do
                    [[ -f "\$f" ]] || continue
                    plugin_id=\$(basename "\$f" .json)
                    enabled=\$(jq -r '.enabled // "?"' "\$f" 2>/dev/null || echo "?")
                    case "\$enabled" in
                        true)  flag="on " ;;
                        false) flag="off" ;;
                        *)     flag="?  " ;;
                    esac
                    version=""
                    if [[ -f "\$pkg" ]]; then
                        # Scoped packages: config file is unscoped
                        # (zones.json) but the dependency key is scoped
                        # (@signalk/zones). Try the literal id, then
                        # walk dependencies for any key ending in /<id>.
                        version=\$(jq -r --arg id "\$plugin_id" '
                            .dependencies[\$id] //
                            (.dependencies | to_entries
                                | map(select(.key | endswith("/" + \$id)))
                                | .[0].value) //
                            "(not in package.json)"
                        ' "\$pkg" 2>/dev/null || echo "?")
                    else
                        version="(no package.json)"
                    fi
                    printf '  [%s] %-30s  %s\\n' "\$flag" "\$plugin_id" "\$version"
                    count=\$((count + 1))
                done
            fi
            echo
            echo "\$count plugin(s) with config files in plugin-config-data/."
        } >"\$bundle/signalk-plugins.txt" 2>&1
    elif [[ -d "\$SIGNALK_DIR" ]]; then
        echo "jq not installed; signalk-plugins.txt and signalk-settings.json skipped." \\
            >"\$bundle/signalk-plugins.txt"
    fi

    # SignalK server settings — connections, source priorities, security
    # strategy. settings.json is mostly safe but pipedProviders' .options
    # block sometimes holds passwords (ydwg auth, MQTT bridges). Redact
    # those values (keeping option keys so connection schema stays
    # visible); leave the rest of settings.json verbatim.
    if [[ -f "\$SIGNALK_DIR/settings.json" ]] && command -v jq >/dev/null 2>&1; then
        # walk(...) recursively visits every node; we target objects
        # that look like a provider with .options and replace each
        # value under .options with "<redacted>" while preserving keys.
        jq '(.pipedProviders // []) |= map(
                if (.options | type) == "object"
                then .options |= with_entries(.value = "<redacted>")
                else .
                end
            )' \\
            "\$SIGNALK_DIR/settings.json" >"\$bundle/signalk-settings.json" 2>&1 \\
            || echo "# failed to parse \$SIGNALK_DIR/settings.json" >"\$bundle/signalk-settings.json"
    fi

    # Container storage state — surfaces ZFS/idmap hazards.
    {
        echo "=== rootless storage path ==="
        echo "\${XDG_DATA_HOME:-\$HOME/.local/share}/containers/storage"
        echo
        echo "=== stat -f -c %T ==="
        stat -f -c '%T' "\${XDG_DATA_HOME:-\$HOME/.local/share}/containers/storage" 2>&1 || true
        echo
        echo "=== ~/.config/containers/storage.conf ==="
        cat "\${XDG_CONFIG_HOME:-\$HOME/.config}/containers/storage.conf" 2>&1 || echo "(absent — using podman defaults)"
        echo
        echo "=== /proc/cmdline ==="
        cat /proc/cmdline 2>&1 || true
        echo
        echo "=== /sys/fs/cgroup/cgroup.controllers ==="
        cat /sys/fs/cgroup/cgroup.controllers 2>&1 || true
    } >"\$bundle/storage-and-cgroup.txt" 2>&1

    # Tar it up.
    local tarball="/tmp/signalk-bug-report-\$stamp.tar.gz"
    tar -C "\$outdir" -czf "\$tarball" "signalk-bug-report-\$stamp"
    rm -rf "\$outdir"

    echo
    echo "[OK] Bundle ready:"
    echo "  \$tarball"
    echo
    echo "Contents are limited to host metadata, container state, recent journals,"
    echo "and SignalK plugin metadata. Auth tokens are reported as presence-only"
    echo "(mode + 'present') and their values are NEVER included. SignalK plugin"
    echo "configuration bodies (which routinely hold secrets) are also NEVER included;"
    echo "settings.json is included with pipedProviders' options redacted."

    # Optional upload + issue-opening. Two prompts because the privacy
    # tradeoff is real: filebin.net is unauthenticated public storage
    # (anyone with the bin URL can download), and although the bundle
    # has tokens/pipedProviders redacted, it still contains settings.json,
    # hardware.json, plugin versions, and 24h of journals. Operators on
    # shared boats or with custom plugins should know that before they
    # upload. Both defaults are Y — most operators running \`signalk
    # bug-report\` want to file an issue, and a default-N upload
    # silently produced "attach this file manually" bodies that surprised
    # users in practice. The explicit consent text above makes the
    # tradeoff visible; operators with concerns can type N.
    local issue_url_base="https://github.com/SignalK/signalk-server/issues/new"
    local tarball_url=""

    # Non-interactive callers (cron, CI, \`signalk bug-report < /dev/null\`)
    # would see \`read\` return immediately with an empty string, and the
    # issue-page prompt's default-Y would then silently spawn xdg-open.
    # Skip both prompts when stdin isn't a TTY and just print the manual
    # instructions.
    if [[ ! -t 0 ]]; then
        echo
        echo "Non-interactive shell — skipping upload and browser prompts."
        echo "Attach \$tarball to a new issue at:"
        echo "  \$issue_url_base"
        return
    fi

    echo
    echo "Upload the bundle to filebin.net so it can be linked from the issue?"
    echo "  - filebin.net is PUBLIC: anyone with the bin URL can download it."
    echo "  - The bundle has tokens and pipedProviders options redacted, but"
    echo "    still contains settings.json, hardware.json, plugin versions,"
    echo "    and 24 hours of journal output. Review the tarball first if"
    echo "    you are on a shared boat or run custom plugins."
    echo "  - filebin auto-expires bins after ~6 days."
    # Guard read against EOF — \`set -e\` would otherwise kill the script
    # before the default is applied (e.g. stdin closed after the first
    # prompt, broken pipe).
    if ! read -r -p "Upload now? [Y/n] " ans_upload; then
        ans_upload=""
    fi
    ans_upload=\${ans_upload:-Y}
    if [[ "\$ans_upload" =~ ^[Yy]\$ ]]; then
        # Bin name mixes timestamp + \$RANDOM so guessing the URL is
        # infeasible; this is the only access control filebin offers.
        local bin
        bin="signalk-\$(date -u +%Y%m%d-%H%M%S)-\$RANDOM"
        local fname
        fname=\$(basename "\$tarball")
        echo "[i] Uploading \$tarball …"
        if curl -fsS --max-time 120 \\
             -H "Content-Type: application/gzip" \\
             --data-binary "@\$tarball" \\
             "https://filebin.net/\$bin/\$fname" >/dev/null; then
            tarball_url="https://filebin.net/\$bin/\$fname"
            echo "[OK] Uploaded:"
            echo "  \$tarball_url"
        else
            echo "[WARN] Upload failed. Attach \$tarball to the issue manually."
        fi
    fi

    echo
    if ! read -r -p "Open the GitHub issue page in your browser? [Y/n] " ans_issue; then
        ans_issue=""
    fi
    ans_issue=\${ans_issue:-Y}
    if [[ "\$ans_issue" =~ ^[Yy]\$ ]]; then
        local body
        if [[ -n "\$tarball_url" ]]; then
            body="**Bug report bundle:** \$tarball_url"\$'\\n'"_(filebin link, auto-expires in ~6 days — please download soon)_"
        else
            body="**Bug report bundle:** attach \\\`\$(basename "\$tarball")\\\` from \$(dirname "\$tarball")/"
        fi
        body+=\$'\\n\\n'"**What happened:**"\$'\\n\\n'"**Expected:**"\$'\\n\\n'"**Steps to reproduce:**"\$'\\n'
        # URL-encode the body for the query string. python3 is present
        # on every distro the installer targets; jq's @uri is the
        # fallback when python3 is unavailable.
        local encoded_body=""
        if command -v python3 >/dev/null 2>&1; then
            encoded_body=\$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))' <<<"\$body")
        elif command -v jq >/dev/null 2>&1; then
            encoded_body=\$(jq -rn --arg s "\$body" '\$s|@uri')
        fi
        local issue_url
        if [[ -n "\$encoded_body" ]]; then
            issue_url="\$issue_url_base?title=Bug%20report%20\$stamp&body=\$encoded_body"
        else
            issue_url="\$issue_url_base"
            echo "[WARN] Could not URL-encode the issue body (no python3 or jq)."
            echo "       Paste this into the issue manually:"
            echo
            printf '%s\\n' "\$body"
            echo
        fi
        echo "[i] Opening:"
        echo "  \$issue_url"
        if command -v xdg-open >/dev/null 2>&1; then
            # Detach so we don't block the shell on slow GUI startup.
            xdg-open "\$issue_url" >/dev/null 2>&1 &
        else
            echo "(no xdg-open — copy the URL above into your browser)"
        fi
    else
        echo "Open this when you're ready:"
        echo "  \$issue_url_base"
    fi
}

case "\${1:-help}" in
    health)     cmd_health ;;
    recover)    shift; cmd_recover "\$@" ;;
    bug-report) cmd_bug_report ;;
    uninstall)  cmd_uninstall ;;
    version|--version|-v) cmd_version ;;
    help|--help|-h) usage ;;
    *)
        echo "[ERR] Unknown command: \$1" >&2
        usage
        exit 1
        ;;
esac
SIGNALK_DISPATCHER_EOF

chmod 0755 "$TARGET"
ok "Installed $TARGET"
