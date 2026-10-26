#!/usr/bin/env bash
# Verifies where the installer finds signalk-server's JWT signing key. Newer
# servers keep the key in security-secret.key, and security.json
# has no secretKey; a secretKey written into security.json replaces the key
# file on the next start. Runs the node scripts lifted from the installer
# with a stub jsonwebtoken module and /home/node/.signalk pointed
# at a sandbox:
#   1. SK_TOKEN_JS is the same in install.sh and signalk-kiosk.tmpl.
#   2. It signs with security.json's secretKey when set, else with
#      security-secret.key (trimmed), and exits non-zero with neither.
# Run from the repo root.

set -euo pipefail

INSTALL_SH="${INSTALL_SH:-installer/linux/install.sh}"
KIOSK_TMPL="${KIOSK_TMPL:-installer/linux/signalk-kiosk.tmpl}"
SIGNALK_TMPL="${SIGNALK_TMPL:-installer/linux/signalk.tmpl}"
for f in "$INSTALL_SH" "$KIOSK_TMPL" "$SIGNALK_TMPL"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERR] $f not found (run from repo root)" >&2
        exit 2
    fi
done

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# token_js <file> — the SK_TOKEN_JS='...' block, without the quotes.
token_js() {
    awk "/^SK_TOKEN_JS='\$/{p=1; next} p && /^'\$/{exit} p{print}" "$1"
}
install_js=$(token_js "$INSTALL_SH")
kiosk_js=$(token_js "$KIOSK_TMPL")
for v in install_js kiosk_js; do
    if [[ -z "${!v}" ]]; then
        echo "[ERR] could not extract $v" >&2
        exit 2
    fi
done

# Stub modules: sign() prints what it was asked to sign with.
mkdir -p "$tmp/mods/node_modules/jsonwebtoken"
cat >"$tmp/mods/node_modules/jsonwebtoken/index.js" <<'EOF'
exports.sign = (payload, key, opts) => `${key}|${payload.id}|${opts.expiresIn}`;
EOF

# sign <case> — runs SK_TOKEN_JS against $tmp/<case>.
sign() {
    (cd "$tmp/mods" && node - "$tmp/$1" admin 5y <<<"$install_js" 2>/dev/null)
}
echo "token signing"
if [[ "$install_js" == "$kiosk_js" ]]; then
    ok "install.sh and signalk-kiosk sign with the same script"
else
    miss "SK_TOKEN_JS differs between $INSTALL_SH and $KIOSK_TMPL"
fi

mkdir -p "$tmp/json"
echo '{"secretKey":"jsonkey","users":[]}' >"$tmp/json/security.json"
echo 'filekey' >"$tmp/json/security-secret.key"
if [[ "$(sign json)" == "jsonkey|admin|5y" ]]; then
    ok "security.json's secretKey wins when set (the server moves it into the key file)"
else
    miss "json: $(sign json)"
fi

mkdir -p "$tmp/file"
echo '{"users":[]}' >"$tmp/file/security.json"
printf 'filekey\n' >"$tmp/file/security-secret.key"
if [[ "$(sign file)" == "filekey|admin|5y" ]]; then
    ok "no secretKey in security.json: signs with security-secret.key"
else
    miss "file: $(sign file)"
fi

mkdir -p "$tmp/none"
echo '{"users":[]}' >"$tmp/none/security.json"
if out=$(sign none); then
    miss "no key anywhere: exited 0 with [$out]"
else
    ok "no key anywhere: exits non-zero, prints no token"
fi

if (( fail )); then
    echo "[FAIL] check-token-secret-key"
    exit 1
fi
echo "[PASS] check-token-secret-key"
