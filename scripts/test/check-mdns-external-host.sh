#!/usr/bin/env bash
# Guards the mDNS EXTERNALHOST wiring.
#
# On Windows the podman machine inherits the WINDOWS host's name, so
# signalk-server's default advertisement collides with the Windows mDNS
# responder already claiming it: LAN clients resolve the host's other
# adapters instead of the server, and the box is absent from `avahi-browse`
# on another machine. EXTERNALHOST overrides the advertised name.
#
# On Linux/macOS the host owns its own name, so the placeholder must render
# EMPTY - signalk-server treats an empty env var as unset and falls back to
# os.hostname(), preserving the operator's chosen hostname.

set -euo pipefail

TMPL="${QUADLET_TMPL:-quadlets/signalk-server.container.template}"
INSTALL_SH="${INSTALL_SH:-installer/linux/install.sh}"
CLI_TMPL="${CLI_TMPL:-installer/linux/signalk.tmpl}"

fail=0
ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

for f in "$TMPL" "$INSTALL_SH" "$CLI_TMPL"; do
    [[ -f "$f" ]] || { echo "[ERR] $f not found (run from repo root)" >&2; exit 2; }
done

# 1. the template carries the placeholder
if grep -q '^Environment=EXTERNALHOST=__SK_EXTERNAL_HOST__$' "$TMPL"; then
    ok "server template carries the EXTERNALHOST placeholder"
else
    miss "server template has no EXTERNALHOST=__SK_EXTERNAL_HOST__ line"
fi

# 2. install.sh substitutes it - an unsubstituted placeholder would reach the
#    live Quadlet and signalk-server would advertise the literal string.
# shellcheck disable=SC2016  # literal shell source text
if grep -q '__SK_EXTERNAL_HOST__/\${SK_EXTERNAL_HOST}' "$INSTALL_SH"; then
    ok "install.sh substitutes the placeholder"
else
    miss "install.sh never substitutes __SK_EXTERNAL_HOST__"
fi

# 3. the CLI carries it forward on re-render, or `signalk update` drops it
# shellcheck disable=SC2016  # literal shell source text
if grep -q 'sk_external_host()' "$CLI_TMPL" \
    && grep -q '__SK_EXTERNAL_HOST__/\${ext_host}' "$CLI_TMPL"; then
    ok "the CLI re-render preserves EXTERNALHOST"
else
    miss "cmd_render_server does not carry EXTERNALHOST forward; a re-render drops it"
fi

# 4. behaviour of the resolution block, driven from install.sh itself
block=$(sed -n '/^SK_EXTERNAL_HOST=""$/,/^fi$/p' "$INSTALL_SH")
if [[ -z "$block" ]]; then
    miss "could not extract the EXTERNALHOST resolution block from $INSTALL_SH"
else
    # The assignments below feed the eval'd block, and info() is called by
    # it - shellcheck cannot see through eval, hence the disables.
    # shellcheck disable=SC2034,SC2317
    resolve() {
        (
            set +u
            SIGNALK_WINDOWS_SHIM="$1"
            [[ -n "${2:-}" ]] && SIGNALK_MDNS_HOST="$2"
            info() { :; }
            eval "$block"
            printf '%s' "$SK_EXTERNAL_HOST"
        )
    }
    got=$(resolve 1 "")
    if [[ "$got" == "signalk" ]]; then ok "Windows default -> signalk"
    else miss "Windows default -> '$got' (wanted signalk)"; fi

    got=$(resolve 1 "nav-pi")
    if [[ "$got" == "nav-pi" ]]; then ok "SIGNALK_MDNS_HOST override honoured"
    else miss "override -> '$got' (wanted nav-pi)"; fi

    got=$(resolve 1 "signalk.local")
    if [[ "$got" == "signalk" ]]; then ok "a trailing .local is stripped"
    else miss "'signalk.local' -> '$got' (wanted signalk)"; fi

    # An empty result here would advertise nothing; a raw one could emit a
    # label mDNS cannot carry.
    got=$(resolve 1 'bad name!!')
    if [[ "$got" == "bad-name" ]]; then ok "illegal label characters are sanitised"
    else miss "'bad name!!' -> '$got' (wanted bad-name)"; fi

    # The load-bearing case: Linux/macOS must render EMPTY so signalk-server
    # falls back to os.hostname().
    got=$(resolve 0 "")
    if [[ -z "$got" ]]; then ok "non-Windows renders empty (os.hostname() fallback)"
    else miss "non-Windows -> '$got' (wanted empty)"; fi

    got=$(resolve 0 "nav-pi")
    if [[ -z "$got" ]]; then ok "non-Windows ignores SIGNALK_MDNS_HOST"
    else miss "non-Windows with override -> '$got' (wanted empty)"; fi
fi

if (( fail )); then
    echo
    echo "[ERR] mDNS EXTERNALHOST wiring is wrong — see entries above." >&2
    exit 1
fi
echo
echo "[OK] mDNS EXTERNALHOST wiring is intact."
