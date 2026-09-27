#!/usr/bin/env bash
# Verifies installer/linux/signalk-kiosk.tmpl without a display, root or a
# running server.
#
#   1. Monitor scan against a fake sysfs tree, including the EDID name decode.
#   2. Touchscreen detection against a stubbed udevadm.
#   3. The rendered unit, PAM stack and slice carry the lines the kiosk depends
#      on (seat session on tty1, getty conflict, the low-priority slice).
#   4. The rendered launcher: waits for the server, clears the crash marker a
#      hard power-off leaves, adds touch flags only when a touchscreen exists,
#      starts the browser anyway once the wait runs out, and with token sign-in
#      starts it on a private start page instead of passing the token on the
#      command line.
#   5. enable/disable end to end in a temp root, with every system command and
#      the Signal K server stubbed: packages, the kiosk's Signal K user and its
#      token, signalk-autologin installed or switched to token sign-in only, the
#      display manager disabled — and disable putting all of it back. Each
#      branch of the sign-in setup starts from a fresh box.
#   6. Both uninstall paths refuse to run while the kiosk is enabled, before
#      they stop the server that `kiosk disable` needs.
#
# Runs on a hermetic PATH (stubs + symlinks to the few real tools the helper
# needs). CI runners ship Chrome and Chromium, and a real browser found on PATH
# would silently skip the install path under test.
#
# Run from the repo root.

set -euo pipefail

TMPL="${TMPL:-installer/linux/signalk-kiosk.tmpl}"
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi
TMPL="$(cd "$(dirname "$TMPL")" && pwd)/$(basename "$TMPL")"

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# A token in the shape signalk-generate-token prints.
JWT="eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InNpZ25hbGsta2lvc2sifQ.c2lnbmF0dXJl"

# ── hermetic PATH ─────────────────────────────────────────────────────────
sysbin="$tmp/sysbin"
mkdir -p "$sysbin"
for t in bash sh cat sed grep head tail tr od mktemp rm rmdir install mkdir \
         readlink basename dirname env jq printf sort uname cut wc touch chmod ln \
         sleep; do
    real=$(command -v "$t") || { echo "[ERR] test needs $t" >&2; exit 2; }
    ln -s "$real" "$sysbin/$t"
done

# ── 1. monitors ───────────────────────────────────────────────────────────
echo "monitor scan"
sysfs="$tmp/sys"
drm="$sysfs/class/drm"
mkdir -p "$drm/card0-HDMI-A-1" "$drm/card0-HDMI-A-2" "$drm/card1-DSI-1"
echo connected    >"$drm/card0-HDMI-A-1/status"
printf '1920x1080\n1280x720\n' >"$drm/card0-HDMI-A-1/modes"
echo disconnected >"$drm/card0-HDMI-A-2/status"
: >"$drm/card0-HDMI-A-2/modes"
echo connected    >"$drm/card1-DSI-1/status"
echo 720x1280     >"$drm/card1-DSI-1/modes"
: >"$drm/card1-DSI-1/edid"

# A 128-byte EDID: header, a timing descriptor at 54 that must be skipped, and
# the monitor-name descriptor (tag 0xFC) at 72.
{
    printf '\x00\xff\xff\xff\xff\xff\xff\x00'
    head -c 46 /dev/zero
    printf '\x02\x3a\x80\x18\x71\x38\x2d\x40\x58\x2c\x45\x00\x00\x00\x00\x00\x00\x1e'
    printf '\x00\x00\x00\xfc\x00DELL U2415\x0a\x20\x20'
    head -c 36 /dev/zero
    head -c 2 /dev/zero
} >"$drm/card0-HDMI-A-1/edid"

scan=$(PATH="$sysbin" KIOSK_SYSFS="$sysfs" bash -c ". '$TMPL'; scan_monitors")
if grep -qx $'HDMI-A-1\tconnected\t1920x1080\tDELL U2415' <<<"$scan"; then
    ok "connected monitor with its preferred mode and EDID name"
else
    miss "HDMI-A-1 line wrong: $(tr '\n' '|' <<<"$scan")"
fi
if grep -qx $'HDMI-A-2\tdisconnected\t-\t-' <<<"$scan"; then
    ok "disconnected connector listed without a mode"
else
    miss "HDMI-A-2 line wrong: $(tr '\n' '|' <<<"$scan")"
fi
if grep -qx $'DSI-1\tconnected\t720x1280\t-' <<<"$scan"; then
    ok "empty EDID (virtual/DSI output) gives no name, no error"
else
    miss "DSI-1 line wrong: $(tr '\n' '|' <<<"$scan")"
fi

# ── 2. touchscreens ───────────────────────────────────────────────────────
echo "touchscreen detection"
stubs="$tmp/stubs"
mkdir -p "$stubs" "$tmp/dev/input" "$sysfs/class/input/event0/device" "$sysfs/class/input/event3/device"
: >"$tmp/dev/input/event0"
: >"$tmp/dev/input/event3"
echo "AT keyboard"                  >"$sysfs/class/input/event0/device/name"
echo "Raspberry Pi Touch Display 2" >"$sysfs/class/input/event3/device/name"
cat >"$stubs/udevadm" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in --name=*) dev="${a#--name=}" ;; esac; done
case "${dev##*/}" in
    event0) printf 'ID_INPUT=1\nID_INPUT_KEYBOARD=1\n' ;;
    event3) printf 'ID_INPUT=1\nID_INPUT_TOUCHSCREEN=1\n' ;;
esac
EOF
chmod +x "$stubs/udevadm"

touch_out=$(PATH="$stubs:$sysbin" KIOSK_SYSFS="$sysfs" KIOSK_DEV_INPUT="$tmp/dev/input" \
    bash -c ". '$TMPL'; detect_touchscreens")
if [[ "$touch_out" == $'event3\tRaspberry Pi Touch Display 2' ]]; then
    ok "only the touchscreen is reported, with its name"
else
    miss "touch detection: $(tr '\n' '|' <<<"$touch_out")"
fi

# ── 3. rendered files ─────────────────────────────────────────────────────
echo "rendered unit, PAM stack and slice"
unit=$(PATH="$sysbin" bash -c ". '$TMPL'; render_unit")
for want in 'User=signalk-kiosk' 'PAMName=signalk-kiosk' 'TTYPath=/dev/tty1' \
            'Conflicts=getty@tty1.service' 'Slice=signalk-kiosk.slice' \
            'ExecStart=/usr/bin/cage -s -d -- /usr/local/lib/signalk-kiosk/browser' \
            'Restart=always' 'WantedBy=multi-user.target'; do
    if grep -qxF "$want" <<<"$unit"; then
        ok "unit: $want"
    else
        miss "unit lacks: $want"
    fi
done
pam=$(PATH="$sysbin" bash -c ". '$TMPL'; render_pam")
if grep -qE '^session +required +pam_systemd\.so class=user type=wayland$' <<<"$pam"; then
    ok "PAM: pam_systemd registers a user-class seat session"
else
    miss "PAM stack lacks the pam_systemd session line"
fi
slice=$(PATH="$sysbin" bash -c ". '$TMPL'; render_slice")
if grep -qxF 'CPUWeight=50' <<<"$slice"; then
    ok "slice: CPUWeight below the default 100 of user.slice"
else
    miss "slice lacks CPUWeight=50"
fi

# ── 3b. URL resolution ────────────────────────────────────────────────────
echo "URL resolution"
check_url() {
    local got
    got=$(PATH="$sysbin" bash -c ". '$TMPL'; resolve_url \"\$1\" http://127.0.0.1:80" _ "$1")
    if [[ "$got" == "$2" ]]; then
        ok "$3"
    else
        miss "$3: got '$got'"
    fi
}
check_url / "http://127.0.0.1:80/" "the server's landing page"
check_url /@mxtommy/kip/ "http://127.0.0.1:80/@mxtommy/kip/" "a path on this server"
check_url @mxtommy/kip/ "http://127.0.0.1:80/@mxtommy/kip/" "a path without the leading slash"
check_url https://example.test/x "https://example.test/x" "a full URL is used as given"
check_url http://localhost/@signalk/freeboard-sk/ "http://127.0.0.1:80/@signalk/freeboard-sk/" \
    "this server spelled localhost, no port: rewritten onto the base"
check_url http://127.0.0.1:80 "http://127.0.0.1:80/" "this server's bare origin: its landing page"
check_url "http://[::1]:80/app/" "http://127.0.0.1:80/app/" "this server over IPv6 loopback"
check_url HTTP://LOCALHOST/app/ "http://127.0.0.1:80/app/" "this server with scheme and host in capitals"
check_url http://127.0.0.1:3000/app "http://127.0.0.1:3000/app" "another port on this host is another server"

# ── 4. the launcher ───────────────────────────────────────────────────────
echo "launcher"
launcher="$tmp/browser-launcher"
PATH="$sysbin" bash -c ". '$TMPL'; render_launcher" >"$launcher"
chmod +x "$launcher"
if PATH="$sysbin" bash -n "$launcher"; then
    ok "launcher parses"
else
    miss "launcher has a syntax error"
fi

lbin="$tmp/lbin"
mkdir -p "$lbin"
cp "$stubs/udevadm" "$lbin/udevadm"
# Fails until $tmp/server-up exists, like a server still starting. Prints what
# the launcher asks for, "<status> <redirect target>": with $tmp/tls the answer
# of a server with TLS enabled, with $tmp/redirect-http a redirect that is not.
cat >"$lbin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\${@: -1}" >"$tmp/probe-url"
if [[ -e "$tmp/server-up" ]]; then
    if [[ -e "$tmp/tls" ]]; then printf '302 https://127.0.0.1:443/signalk'
    elif [[ -e "$tmp/redirect-http" ]]; then printf '301 http://127.0.0.1:80/signalk/'
    else printf '200 '; fi
    exit 0
fi
echo x >>"$tmp/probes"
printf '000 '
exit 7
EOF
cat >"$lbin/sleep" <<EOF
#!/bin/bash
# The third wait "finds" the server up.
n=\$(wc -l <"$tmp/probes" 2>/dev/null || echo 0)
(( n >= 3 )) && : >"$tmp/server-up"
exit 0
EOF
cat >"$lbin/fakebrowser" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >"$tmp/browser-args"
EOF
chmod +x "$lbin/curl" "$lbin/sleep" "$lbin/fakebrowser"
cat >"$tmp/kiosk.conf" <<EOF
KIOSK_URL=http://127.0.0.1:80/@mxtommy/kip/
KIOSK_BROWSER=$lbin/fakebrowser
KIOSK_BASE=http://127.0.0.1:80
KIOSK_SIGNIN=none
EOF
sed 's/^KIOSK_SIGNIN=none$/KIOSK_SIGNIN=token/' "$tmp/kiosk.conf" >"$tmp/kiosk-token.conf"
# A page whose path carries the characters URLSearchParams splits or decodes on.
cat >"$tmp/kiosk-next.conf" <<EOF
KIOSK_URL=http://127.0.0.1:80/app/?a=1&b=é#x
KIOSK_BROWSER=$lbin/fakebrowser
KIOSK_BASE=http://127.0.0.1:80
KIOSK_SIGNIN=token
EOF
printf '%s\n' "$JWT" >"$tmp/kiosk.token"
profile="$tmp/profile"
mkdir -p "$profile/Default"
printf '{"profile":{"exit_type":"Crashed","exited_cleanly":false,"name":"x"}}' >"$profile/Default/Preferences"

# run_launcher <input dir> <wait step> [conf] [token file]
run_launcher() {
    rm -f "$tmp/browser-args"
    PATH="$lbin:$sysbin" HOME="$tmp" KIOSK_CONF="${3:-$tmp/kiosk.conf}" \
        KIOSK_TOKEN_FILE="${4:-$tmp/kiosk.token}" KIOSK_PROFILE="$profile" \
        KIOSK_SYSFS="$sysfs" KIOSK_DEV_INPUT="$1" KIOSK_WAIT_STEP="$2" "$launcher" 2>/dev/null
}

rm -f "$tmp/server-up" "$tmp/probes"
run_launcher "$tmp/dev/input" 2
if [[ -f "$tmp/server-up" && "$(wc -l <"$tmp/probes")" -ge 3 ]]; then
    ok "waits for the server before starting the browser"
else
    miss "did not wait for the server (probes: $({ wc -l <"$tmp/probes"; } 2>/dev/null || echo 0))"
fi
if [[ "$(cat "$tmp/probe-url" 2>/dev/null)" == http://127.0.0.1:80/signalk ]]; then
    ok "probes the server's /signalk endpoint"
else
    miss "probe URL: $(cat "$tmp/probe-url" 2>/dev/null)"
fi
args=$(cat "$tmp/browser-args" 2>/dev/null || true)
if grep -qx -- '--kiosk' <<<"$args"; then
    ok "browser started with --kiosk"
else
    miss "no --kiosk: $(tr '\n' ' ' <<<"$args")"
fi
if [[ "$(tail -1 <<<"$args")" == http://127.0.0.1:80/@mxtommy/kip/ ]]; then
    ok "no sign-in: the page from the conf file is the last argument, token file or not"
else
    miss "URL wrong: $(tail -1 <<<"$args")"
fi
if grep -qx -- "--user-data-dir=$profile" <<<"$args"; then
    ok "dedicated browser profile"
else
    miss "no --user-data-dir"
fi
for f in --touch-events=enabled --disable-pinch --overscroll-history-navigation=0; do
    if grep -qx -- "$f" <<<"$args"; then
        ok "touchscreen present: $f"
    else
        miss "touch flag missing: $f"
    fi
done
prefs=$(cat "$profile/Default/Preferences")
if [[ "$prefs" == *'"exit_type":"Normal"'* && "$prefs" == *'"exited_cleanly":true'* && "$prefs" == *'"name":"x"'* ]]; then
    ok "crash marker cleared, rest of Preferences untouched"
else
    miss "Preferences after launch: $prefs"
fi

: >"$tmp/server-up"
mkdir -p "$tmp/dev/noinput"
run_launcher "$tmp/dev/noinput" 2
args=$(cat "$tmp/browser-args" 2>/dev/null || true)
if grep -q -- '--disable-pinch' <<<"$args"; then
    miss "touch flags added with no touchscreen present"
else
    ok "no touchscreen: no touch flags"
fi

# A server that never answers: the browser still starts after the 300s cap,
# so the operator sees an error page rather than a black screen.
rm -f "$tmp/server-up" "$tmp/probes"
cat >"$lbin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
run_launcher "$tmp/dev/noinput" 100
if [[ -s "$tmp/browser-args" && "$(wc -l <"$tmp/probes")" -eq 4 ]]; then
    ok "server never answers: gives up after 300s and starts the browser anyway"
else
    miss "wait cap wrong (probes: $({ wc -l <"$tmp/probes"; } 2>/dev/null || echo 0), browser started: $([[ -s "$tmp/browser-args" ]] && echo yes || echo no))"
fi

# Token sign-in.
: >"$tmp/server-up"
rm -f "$tmp/start.html"
run_launcher "$tmp/dev/noinput" 2 "$tmp/kiosk-token.conf"
args=$(cat "$tmp/browser-args" 2>/dev/null || true)
if [[ "$(tail -1 <<<"$args")" == "file://$tmp/start.html" ]]; then
    ok "token sign-in: the browser starts on the start page in the kiosk user's home"
else
    miss "token sign-in start URL: $(tail -1 <<<"$args")"
fi
if grep -qF "$JWT" <<<"$args"; then
    miss "the token is on the browser's command line"
else
    ok "the token is not on the browser's command line"
fi
want_page="<!doctype html><meta charset=\"utf-8\"><script>location.replace(\"http://127.0.0.1:80/signalk-autologin/seed#token=${JWT}&next=%2F%40mxtommy%2Fkip%2F\")</script>"
if [[ "$(cat "$tmp/start.html" 2>/dev/null)" == "$want_page" ]]; then
    ok "start page: the seed page, token in the fragment, the conf file's page as next"
else
    miss "start page: $(cat "$tmp/start.html" 2>/dev/null)"
fi
if [[ "$(stat -c %a "$tmp/start.html" 2>/dev/null)" == 600 ]]; then
    ok "start page readable by the kiosk user only (0600)"
else
    miss "start page mode: $(stat -c %a "$tmp/start.html" 2>/dev/null)"
fi
run_launcher "$tmp/dev/noinput" 2 "$tmp/kiosk-next.conf"
if grep -qF 'next=%2Fapp%2F%3Fa%3D1%26b%3D%C3%A9%23x")' "$tmp/start.html" 2>/dev/null; then
    ok "next is percent-encoded as UTF-8, so & and # stay part of the path"
else
    miss "next encoding: $(cat "$tmp/start.html" 2>/dev/null)"
fi
run_launcher "$tmp/dev/noinput" 2 "$tmp/kiosk-token.conf" "$tmp/no-such-token"
if [[ "$(tail -1 "$tmp/browser-args" 2>/dev/null)" == http://127.0.0.1:80/@mxtommy/kip/ ]]; then
    ok "token sign-in with no readable token: the page itself, which shows the login"
else
    miss "unreadable token fallback: $(tail -1 "$tmp/browser-args" 2>/dev/null)"
fi

# TLS switched on after the kiosk was set up.
: >"$tmp/tls"
rm -f "$tmp/start.html"
run_launcher "$tmp/dev/noinput" 2 "$tmp/kiosk-token.conf"
last=$(tail -1 "$tmp/browser-args" 2>/dev/null)
if [[ "$last" == data:text/html\;charset=utf-8,* && "$last" == *has%20TLS%20enabled* ]]; then
    ok "server redirects to HTTPS: the browser shows why the kiosk cannot use it"
else
    miss "TLS page: last arg ${last:0:120}"
fi
if [[ -e "$tmp/start.html" ]]; then
    miss "wrote the token start page for a server it cannot sign in to"
else
    ok "no token start page on a TLS server"
fi
cat >"$tmp/kiosk-external.conf" <<EOF
KIOSK_URL=https://example.test/x
KIOSK_BROWSER=$lbin/fakebrowser
KIOSK_BASE=http://127.0.0.1:80
KIOSK_SIGNIN=none
EOF
run_launcher "$tmp/dev/noinput" 2 "$tmp/kiosk-external.conf"
if [[ "$(tail -1 "$tmp/browser-args" 2>/dev/null)" == https://example.test/x ]]; then
    ok "a page on another host still opens while this server redirects to HTTPS"
else
    miss "external page with local TLS: last arg $(tail -1 "$tmp/browser-args" 2>/dev/null)"
fi
rm -f "$tmp/tls"
: >"$tmp/redirect-http"
run_launcher "$tmp/dev/noinput" 2
if [[ "$(tail -1 "$tmp/browser-args" 2>/dev/null)" == http://127.0.0.1:80/@mxtommy/kip/ ]]; then
    ok "a redirect that is not to HTTPS: the page, not the TLS explanation"
else
    miss "plain redirect: last arg $(tail -1 "$tmp/browser-args" 2>/dev/null)"
fi
rm -f "$tmp/redirect-http"

# ── 5. enable / disable end to end ────────────────────────────────────────
echo "enable / disable"
ADMIN_TOKEN="test-admin-token"
# No jq here: enable must install it before the sign-in step uses it.
sysbin5="$tmp/sysbin5"
mkdir -p "$sysbin5"
for l in "$sysbin"/*; do [[ "${l##*/}" == jq ]] || ln -s "$(readlink "$l")" "$sysbin5/${l##*/}"; done
realjq=$(readlink "$sysbin/jq")
root="$tmp/root"
home="$tmp/home"
ebin="$tmp/ebin"
state="$tmp/state"
conf="$root/etc/signalk-kiosk.conf"
tokfile="$root/etc/signalk-kiosk.token"
startpage="$root/var/lib/signalk-kiosk/start.html"
pkg="$home/.signalk/node_modules/signalk-autologin/package.json"
kippkg="$home/.signalk/node_modules/@mxtommy/kip/package.json"
cfgf="$home/.signalk/plugin-config-data/signalk-autologin.json"
mkdir -p "$ebin"
cp "$stubs/udevadm" "$ebin/udevadm"

# The stubs read STUB_* from the environment run_helper sets.
cat >"$ebin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
# run_helper keeps the helper's 1s wait step, so every wait loop still ends at
# its limit (a step of 0 would spin forever on a condition that never holds);
# only the sleeping is skipped.
cat >"$ebin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
# Disabling a unit does not stop it: lightdm runs until a test marks the box
# rebooted with it disabled (lightdm-stopped).
cat >"$ebin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$STUB_STATE/calls"
case "$*" in
    "disable lightdm.service")
        rm -f "$STUB_ROOT/etc/systemd/system/display-manager.service" ;;
    "enable --now lightdm.service")
        if [[ -e "$STUB_STATE/lightdm-removed" ]]; then
            echo "Failed to enable unit: Unit file lightdm.service does not exist." >&2
            exit 1
        fi
        ln -sf /lib/systemd/system/lightdm.service "$STUB_ROOT/etc/systemd/system/display-manager.service"
        rm -f "$STUB_STATE/lightdm-stopped" ;;
    "is-active --quiet lightdm.service")
        [[ ! -e "$STUB_STATE/lightdm-stopped" ]]; exit ;;
    "is-enabled signalk-kiosk.service") echo enabled ;;
    "is-active signalk-kiosk.service") echo active ;;
esac
exit 0
EOF
cat >"$ebin/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >>"$STUB_STATE/calls"
if [[ "$1" == install ]]; then
    for p in "$@"; do
        case "$p" in
            cage|chromium) printf '#!/bin/bash\n' >"$STUB_EBIN/$p"; chmod +x "$STUB_EBIN/$p" ;;
            jq) ln -sf "$STUB_JQ" "$STUB_EBIN/jq" ;;
        esac
    done
fi
EOF
cat >"$ebin/apt-cache" <<'EOF'
#!/bin/bash
[[ "$*" == "show chromium" ]] && exit 0
[[ "$*" == "show rpi-chromium-mods" && -e "$STUB_STATE/pi-os" ]]
EOF
cat >"$ebin/getent" <<'EOF'
#!/bin/bash
[[ -e "$STUB_STATE/user-exists" ]] || exit 2
home=$(cat "$STUB_STATE/kiosk-home" 2>/dev/null || echo /var/lib/signalk-kiosk)
echo "signalk-kiosk:x:999:999::${home}:/usr/sbin/nologin"
EOF
cat >"$ebin/useradd" <<'EOF'
#!/bin/bash
echo "useradd $*" >>"$STUB_STATE/calls"
: >"$STUB_STATE/user-exists"
EOF
cat >"$ebin/userdel" <<'EOF'
#!/bin/bash
echo "userdel $*" >>"$STUB_STATE/calls"
rm -f "$STUB_STATE/user-exists"
EOF
cat >"$ebin/chgrp" <<'EOF'
#!/bin/bash
echo "chgrp $*" >>"$STUB_STATE/calls"
EOF
cat >"$ebin/podman" <<'EOF'
#!/bin/bash
echo "podman $*" >>"$STUB_STATE/calls"
[[ "$1" == exec ]] && printf '%s\n' "$STUB_JWT"
exit 0
EOF
# Like the updater's restart, this returns once the restart is queued: the
# process being replaced still answers the next three requests (see curl).
cat >"$ebin/signalk" <<'EOF'
#!/bin/bash
echo "signalk $*" >>"$STUB_STATE/calls"
[[ "$1" == restart ]] && echo 3 >"$STUB_STATE/old-answers"
exit 0
EOF
# The server and the npm registry, as far as the helper uses them. What is
# installed is where the server keeps it: package.json files and the plugin's
# plugin-config-data file under $HOME/.signalk. What the running process has
# loaded is in $STUB_STATE: loaded-version for signalk-autologin (1.1.0 is the
# first release with token sign-in) and kip-loaded for KIP.
cat >"$ebin/curl" <<'EOF'
#!/bin/bash
method=GET out="" wfmt="" fail=0 data="" url="" auth=""
while (( $# )); do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -w) wfmt="$2"; shift 2 ;;
        -H) [[ "$2" == 'Authorization: Bearer '* ]] && auth="${2#Authorization: Bearer }"; shift 2 ;;
        -m) shift 2 ;;
        --data) data="$2"; shift 2 ;;
        -f*) fail=1; shift ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
s="$STUB_STATE" jq="$STUB_JQ" sk=http://127.0.0.1:80
pkg="$HOME/.signalk/node_modules/signalk-autologin/package.json"
kip="$HOME/.signalk/node_modules/@mxtommy/kip/package.json"
cfg="$HOME/.signalk/plugin-config-data/signalk-autologin.json"
# The admin token the server accepts; the helper sends whatever its token
# file holds.
admin="$STUB_ADMIN"
echo "$method $url" >>"$s/requests"
# A stopped server: connection refused.
[[ -e "$s/server-down" && "$url" == "$sk/"* ]] && exit 7
if [[ -e "$s/old-answers" ]]; then
    n=$(cat "$s/old-answers")
    if (( n > 0 )); then
        echo $(( n - 1 )) >"$s/old-answers"
    else
        # The new process: it loaded what is installed now.
        rm -f "$s/old-answers" "$s/loaded-version" "$s/kip-loaded"
        "$jq" -r .version "$pkg" >"$s/loaded-version" 2>/dev/null || rm -f "$s/loaded-version"
        [[ -e "$kip" ]] && : >"$s/kip-loaded"
    fi
fi
loaded() { [[ -s "$s/loaded-version" ]]; }
# Enabled when its config says nothing: the package sets
# signalk-plugin-enabled-by-default.
enabled() { loaded && { [[ ! -e "$cfg" ]] || "$jq" -e '.enabled != false' "$cfg" >/dev/null; }; }
token_signin() { enabled && [[ "$(cat "$s/loaded-version")" == 1.1.0 ]]; }
set_users() { local u; u=$("$jq" -c "$@" "$s/users.json") && printf '%s\n' "$u" >"$s/users.json"; }
body="" code=200 redirect=""
if [[ "$url" == "$sk/skServer/"* && ( -z "$admin" || "$auth" != "$admin" ) ]]; then
    code=401 body=Unauthorized
else
    case "$method $url" in
        "GET https://registry.test/signalk-autologin/latest")
            body='{"name":"signalk-autologin","version":"1.1.0"}' ;;
        "GET https://registry.test/@mxtommy/kip/latest")
            body='{"name":"@mxtommy/kip","version":"4.8.5"}' ;;
        "POST $sk/skServer/appstore/install/signalk-autologin/1.1.0")
            # What the plugin reads when it first starts.
            cat "$cfg" >"$s/config-at-install" 2>/dev/null || echo none >"$s/config-at-install"
            mkdir -p "${pkg%/*}"
            echo '{"name":"signalk-autologin","version":"1.1.0"}' >"$pkg"
            body='"Installing signalk-autologin..."' ;;
        "POST $sk/skServer/appstore/install/@mxtommy/kip/4.8.5")
            mkdir -p "${kip%/*}"
            echo '{"name":"@mxtommy/kip","version":"4.8.5"}' >"$kip"
            body='"Installing @mxtommy/kip..."' ;;
        "GET $sk/@mxtommy/kip/")
            if [[ -e "$s/kip-loaded" ]]; then body='<!doctype html>'; else code=404; fi ;;
        "GET $sk/skServer/plugins/signalk-autologin")
            if ! loaded; then code=404 body='Cannot GET'
            else
                body=$("$jq" -nc --argjson e "$(enabled && echo true || echo false)" \
                    --arg v "$(cat "$s/loaded-version")" '{enabled: $e, version: $v}')
            fi ;;
        "GET $sk/skServer/plugins/signalk-autologin/config")
            body=$(cat "$cfg" 2>/dev/null || echo '{}') ;;
        "POST $sk/skServer/plugins/signalk-autologin/config")
            printf '%s\n' "$data" >"$cfg"
            printf '%s\n' "$data" >>"$s/config-posts" ;;
        "GET $sk/signalk")
            # TLS enabled: the HTTP port only redirects.
            if [[ -e "$s/tls" ]]; then code=302 redirect="https://127.0.0.1:443/signalk"
            else body='{}'; fi ;;
        "GET $sk/signalk-autologin/seed")
            if token_signin; then body="fetch('/signalk-autologin/session'"; else code=404; fi ;;
        "POST $sk/signalk-autologin/session")
            printf '%s\n' "$auth" >>"$s/session-tokens"
            if ! token_signin; then code=404
            elif [[ "$auth" == "$STUB_JWT" ]]; then code=204
            else code=401; fi ;;
        "GET $sk/skServer/security/users") body=$(cat "$s/users.json") ;;
        "POST $sk/skServer/security/users/signalk-kiosk")
            echo "POST $data" >>"$s/user-calls"
            set_users --argjson d "$data" '. + [{userId: "signalk-kiosk", type: $d.type}]' ;;
        "PUT $sk/skServer/security/users/signalk-kiosk")
            if [[ -e "$s/put-fails" ]]; then code=500
            else
                echo "PUT $data" >>"$s/user-calls"
                set_users --argjson d "$data" 'map(if .userId == "signalk-kiosk" then .type = $d.type else . end)'
            fi ;;
        "DELETE $sk/skServer/security/users/signalk-kiosk")
            echo DELETE >>"$s/user-calls"
            set_users 'map(select(.userId != "signalk-kiosk"))' ;;
        *)
            code=404 body="unexpected $method $url"
            echo "$method $url" >>"$s/unexpected" ;;
    esac
fi
if (( fail )) && (( code >= 400 )); then exit 22; fi
[[ "$out" == /dev/null ]] || printf '%s' "$body"
if [[ -n "$wfmt" ]]; then
    wfmt=${wfmt//'%{http_code}'/$code}
    printf '%s' "${wfmt//'%{redirect_url}'/$redirect}"
fi
exit 0
EOF
chmod +x "$ebin"/*

run_helper() {
    PATH="$ebin:$sysbin5" HOME="$home" KIOSK_ROOT="$root" KIOSK_SYSFS="$sysfs" \
        KIOSK_DEV_INPUT="$tmp/dev/input" SIGNALK_URL="http://127.0.0.1:80/signalk" \
        SIGNALK_CLI="$ebin/signalk" KIOSK_NPM_REGISTRY="https://registry.test" \
        KIOSK_WAIT_STEP=1 NO_COLOR=1 \
        STUB_STATE="$state" STUB_ROOT="$root" STUB_EBIN="$ebin" STUB_JQ="$realjq" STUB_JWT="$JWT" \
        STUB_ADMIN="$ADMIN_TOKEN" bash "$TMPL" "$@"
}

# A box with a desktop installed and running (display-manager.service →
# lightdm), the installer's admin token, one admin user on the server, and
# nothing of the kiosk's.
reset_box() {
    rm -rf "$root" "$home" "$state"
    rm -f "$ebin/cage" "$ebin/chromium" "$ebin/jq"
    mkdir -p "$root/etc/systemd/system" "$home/.signalk" "$home/.signalk-doctor" "$state"
    printf '%s\n' "$ADMIN_TOKEN" >"$home/.signalk-doctor/signalk-token"
    echo '[{"userId":"admin","type":"admin"}]' >"$state/users.json"
    ln -s /lib/systemd/system/lightdm.service "$root/etc/systemd/system/display-manager.service"
}

# An installed signalk-autologin <version> the server has loaded, with <config>.
preinstall_autologin() {
    mkdir -p "${pkg%/*}" "${cfgf%/*}"
    printf '{"name":"signalk-autologin","version":"%s"}\n' "$1" >"$pkg"
    printf '%s\n' "$2" >"$cfgf"
    echo "$1" >"$state/loaded-version"
}

# KIP installed and served, as after an App Store install and a restart.
preinstall_kip() {
    mkdir -p "${kippkg%/*}"
    echo '{"name":"@mxtommy/kip","version":"4.8.5"}' >"$kippkg"
    : >"$state/kip-loaded"
}

restarts() { grep -cx 'signalk restart' "$state/calls" 2>/dev/null || true; }

# conf_has <line> [description]
conf_has() {
    if grep -qxF "$1" "$conf" 2>/dev/null; then
        ok "${2:-conf: $1}"
    else
        miss "${2:-conf} — want '$1', have '$(grep "^${1%%=*}=" "$conf" 2>/dev/null)'"
    fi
}
# call_made <exact call> <description>
call_made() {
    if grep -qxF "$1" "$state/calls" 2>/dev/null; then
        ok "$2"
    else
        miss "$2 — no call: $1"
    fi
}
call_not_made() {
    if grep -qxF "$1" "$state/calls" 2>/dev/null; then
        miss "$2 — unexpected call: $1"
    else
        ok "$2"
    fi
}
out_has() {
    if grep -qF -- "$1" <<<"$out"; then
        ok "$2"
    else
        miss "$2 — output lacks: $1"
    fi
}
no_unexpected_requests() {
    if [[ -s "$state/unexpected" ]]; then
        miss "requests outside the stubbed API: $(tr '\n' '|' <"$state/unexpected")"
    else
        ok "no requests outside the stubbed API"
    fi
}
run_enable() {
    if out=$(run_helper enable "$@" 2>&1); then
        ok "enable $* exits 0"
    else
        miss "enable $* failed: $(tail -5 <<<"$out" | tr '\n' '|')"
    fi
}

echo "  fresh box, desktop running"
reset_box
run_enable
call_made 'apt-get install -y --no-install-recommends cage jq chromium' \
    "installs cage, jq and the distro chromium package"
call_made 'useradd --system --home-dir /var/lib/signalk-kiosk --create-home --shell /usr/sbin/nologin --user-group signalk-kiosk' \
    "creates the unprivileged kiosk system user"
if [[ -f "$kippkg" ]]; then
    ok "installs KIP, the default page, which the server image does not ship"
else
    miss "KIP not installed"
fi
if [[ "$(cat "$state/config-at-install" 2>/dev/null)" == '{"enabled":true,"configuration":{"networkWideAdmin":false}}' ]]; then
    ok "signalk-autologin's first start reads a token-only configuration"
else
    miss "plugin config when the install ran: $(cat "$state/config-at-install" 2>/dev/null)"
fi
if [[ "$(restarts)" == 1 && -e "$state/kip-loaded" && "$(cat "$state/loaded-version" 2>/dev/null)" == 1.1.0 ]]; then
    ok "one server restart loads both KIP and signalk-autologin"
else
    miss "restarts: $(restarts), KIP loaded: $([[ -e "$state/kip-loaded" ]] && echo yes || echo no), plugin loaded: $(cat "$state/loaded-version" 2>/dev/null)"
fi
if [[ -s "$state/config-posts" ]]; then
    miss "re-posted the plugin config: $(tr '\n' '|' <"$state/config-posts")"
else
    ok "no config re-post (a post restarts the plugin)"
fi
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == 'POST {"type":"readwrite"}' ]]; then
    ok "creates Signal K user signalk-kiosk as readwrite, with no password"
else
    miss "Signal K user calls: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
call_made 'podman exec signalk-server /home/node/signalk/node_modules/signalk-server/bin/signalk-generate-token -u signalk-kiosk -e 10y -s /home/node/.signalk/security.json' \
    "mints the kiosk's token inside the server container"
if [[ "$(cat "$state/session-tokens" 2>/dev/null)" == "$JWT" ]]; then
    ok "checks that the token signs in before relying on it"
else
    miss "session POSTs carried: $(tr '\n' '|' <"$state/session-tokens" 2>/dev/null)"
fi
if [[ "$(cat "$tokfile" 2>/dev/null)" == "$JWT" && "$(stat -c %a "$tokfile" 2>/dev/null)" == 640 ]]; then
    ok "token file written, mode 0640"
else
    miss "token file: mode $(stat -c %a "$tokfile" 2>/dev/null), content $(cat "$tokfile" 2>/dev/null)"
fi
call_made "chgrp signalk-kiosk $tokfile" "token file's group is the kiosk user's"
if grep -qF "$JWT" <<<"$out" || grep -qF "$JWT" "$conf" 2>/dev/null; then
    miss "the token is printed or in the conf file"
else
    ok "the token is neither printed nor in the conf file"
fi
call_made 'systemctl disable lightdm.service' "disables the running desktop login"
call_made 'systemctl enable signalk-kiosk.service' "enables the kiosk unit"
call_not_made 'systemctl restart signalk-kiosk.service' \
    "desktop still running: the kiosk waits for the reboot instead of fighting it"
conf_has 'KIOSK_URL=http://127.0.0.1:80/@mxtommy/kip/' "default page: KIP"
conf_has 'KIOSK_BASE=http://127.0.0.1:80'
conf_has 'KIOSK_SIGNIN=token'
conf_has 'KIOSK_SK_USER_TYPE=readwrite'
conf_has "KIOSK_BROWSER=$ebin/chromium" "conf: browser path resolved after the install"
conf_has 'KIOSK_PREV_DISPLAY_MANAGER=lightdm.service'
conf_has 'KIOSK_AUTOLOGIN_CHANGED=installed'
conf_has 'KIOSK_SK_USER_CREATED=1'
for f in etc/systemd/system/signalk-kiosk.service etc/systemd/system/signalk-kiosk.slice \
         etc/pam.d/signalk-kiosk usr/local/lib/signalk-kiosk/browser; do
    if [[ -f "$root/$f" ]]; then
        ok "written: /$f"
    else
        miss "not written: /$f"
    fi
done
if [[ -x "$root/usr/local/lib/signalk-kiosk/browser" ]]; then
    ok "launcher is executable"
else
    miss "launcher not executable"
fi
if grep -qe '--admin:' -e 'every device' <<<"$out"; then
    miss "admin warning printed: $(grep -e '--admin:' -e 'every device' <<<"$out" | tr '\n' '|')"
else
    ok "no admin warnings"
fi
no_unexpected_requests

echo "  re-enable before the reboot, desktop still running"
: >"$state/calls"
run_enable
call_not_made 'systemctl restart signalk-kiosk.service' \
    "the disabled desktop still holds the screen: no kiosk restart"
out_has 'the desktop is still running; reboot' "says to reboot"

echo "  re-enable with --admin after the reboot"
: >"$state/lightdm-stopped"
: >"$state/calls"
rm -f "$state/user-calls"
run_enable --admin
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == 'PUT {"type":"admin"}' ]]; then
    ok "the existing kiosk user is changed to admin"
else
    miss "Signal K user calls: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
conf_has 'KIOSK_URL=http://127.0.0.1:80/' "--admin: default page is the server's landing page"
conf_has 'KIOSK_SK_USER_TYPE=admin'
out_has '--admin: the kiosk signs in as an admin' "--admin: warns that anyone at the screen is admin"
conf_has 'KIOSK_PREV_DISPLAY_MANAGER=lightdm.service' "re-enable keeps the recorded display manager"
conf_has 'KIOSK_AUTOLOGIN_CHANGED=installed' "re-enable keeps the recorded plugin install"
conf_has 'KIOSK_SK_USER_CREATED=1' "re-enable keeps the recorded Signal K user"
call_not_made 'signalk restart' "plugin already loaded: no server restart"
call_made 'systemctl restart signalk-kiosk.service' "no desktop running: restarts the kiosk"
no_unexpected_requests

echo "  disable --purge"
: >"$state/calls"
rm -f "$state/user-calls" "$state/config-posts"
mkdir -p "${startpage%/*}"
printf '%s\n' "$JWT" >"$startpage"
# A setting changed in the plugin's own panel in the meantime.
new=$(jq -c '.configuration.adminUser = "skipper"' "$cfgf") && printf '%s\n' "$new" >"$cfgf"
if out=$(run_helper disable --purge 2>&1); then
    ok "disable exits 0"
else
    miss "disable failed: $(tail -5 <<<"$out" | tr '\n' '|')"
fi
call_made 'systemctl disable --now signalk-kiosk.service' "stops and disables the kiosk unit"
call_made 'systemctl enable --now lightdm.service' "gives the desktop login back"
for f in etc/systemd/system/signalk-kiosk.service etc/systemd/system/signalk-kiosk.slice \
         etc/pam.d/signalk-kiosk etc/signalk-kiosk.conf etc/signalk-kiosk.token \
         var/lib/signalk-kiosk/start.html usr/local/lib/signalk-kiosk; do
    if [[ ! -e "$root/$f" ]]; then
        ok "removed: /$f"
    else
        miss "left behind: /$f"
    fi
done
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == DELETE ]]; then
    ok "deletes Signal K user signalk-kiosk, which revokes its token"
else
    miss "Signal K user calls: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
if jq -e '.enabled == false and .configuration == {"networkWideAdmin": false, "adminUser": "skipper"}' "$cfgf" >/dev/null 2>&1; then
    ok "switches signalk-autologin off again, keeping its settings"
else
    miss "plugin config after disable: $(cat "$cfgf" 2>/dev/null)"
fi
call_made 'userdel --remove signalk-kiosk' "--purge removes the kiosk system user"
no_unexpected_requests

echo "  re-enable with --no-autologin"
reset_box
run_helper enable >/dev/null 2>&1 || true
mkdir -p "${startpage%/*}"
printf '%s\n' "$JWT" >"$startpage"
rm -f "$state/user-calls"
run_enable --no-autologin
conf_has 'KIOSK_SIGNIN=none'
if [[ -e "$tokfile" || -e "$startpage" ]]; then
    miss "a file holding the token is left: $(for f in "$tokfile" "$startpage"; do [[ -e "$f" ]] && printf '%s ' "$f"; done)"
else
    ok "token file and start page removed"
fi
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == DELETE ]]; then
    ok "deletes the Signal K user the first enable created, which signs the browser out"
else
    miss "Signal K user calls: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
conf_has 'KIOSK_SK_USER_CREATED=' "the deleted user is no longer recorded"
conf_has 'KIOSK_AUTOLOGIN_CHANGED=installed' "the plugin install stays recorded for disable"
rm -f "$state/user-calls"
run_helper disable >/dev/null 2>&1 || true
if [[ -e "$state/user-calls" ]]; then
    miss "disable touched Signal K users again: $(tr '\n' '|' <"$state/user-calls")"
else
    ok "disable does not delete the user a second time"
fi
if jq -e '.enabled == false' "$cfgf" >/dev/null 2>&1; then
    ok "disable still switches off the plugin the kiosk installed"
else
    miss "plugin config after disable: $(cat "$cfgf" 2>/dev/null)"
fi
no_unexpected_requests

echo "  disable with the server stopped"
reset_box
run_helper enable >/dev/null 2>&1 || true
: >"$state/server-down"
: >"$state/requests"
if out=$(run_helper disable --purge 2>&1); then
    ok "disable exits 0 with the server stopped"
else
    miss "disable failed: $(tail -5 <<<"$out" | tr '\n' '|')"
fi
if grep -qx '\[!\]   the Signal K user signalk-kiosk' <<<"$out" && grep -qx '\[!\]   signalk-autologin, switched on' <<<"$out"; then
    ok "says what stays behind in the server's data"
else
    miss "server-down message: $(grep -A3 'not answering' <<<"$out" | tr '\n' '|')"
fi
if [[ "$(cat "$state/requests")" == "GET http://127.0.0.1:80/signalk" ]]; then
    ok "one probe, no further server calls"
else
    miss "requests with the server down: $(tr '\n' '|' <"$state/requests")"
fi
if grep -qe 'Security → Users' -e 'Plugin Config' <<<"$out"; then
    miss "points at an Admin UI that is not running: $(grep -e 'Security → Users' -e 'Plugin Config' <<<"$out" | tr '\n' '|')"
else
    ok "does not point at the Admin UI of a stopped server"
fi
if [[ ! -e "$tokfile" && ! -e "$root/etc/systemd/system/signalk-kiosk.service" ]]; then
    ok "boot files and token removed regardless"
else
    miss "kiosk files left with the server stopped"
fi
call_made 'systemctl enable --now lightdm.service' "gives the desktop login back"
conf_has 'KIOSK_URL=' "the conf keeps nothing but the sign-in record"
conf_has 'KIOSK_SK_USER_CREATED=1' "the record of the Signal K user stays for a retry"
conf_has 'KIOSK_AUTOLOGIN_CHANGED=installed' "the record of the plugin install stays for a retry"
out_has 'again to put them back' "says how to finish"
# The server is back: disable again finishes the sign-in part only.
rm -f "$state/server-down" "$state/user-calls" "$state/config-posts"
: >"$state/calls"
if out=$(run_helper disable 2>&1); then
    ok "disable again exits 0"
else
    miss "second disable failed: $(tail -5 <<<"$out" | tr '\n' '|')"
fi
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == DELETE ]] && jq -e '.enabled == false' "$cfgf" >/dev/null 2>&1; then
    ok "the second disable deletes the user and switches the plugin off"
else
    miss "second disable: users $(tr '\n' '|' <"$state/user-calls" 2>/dev/null), plugin $(cat "$cfgf" 2>/dev/null)"
fi
if [[ -e "$conf" ]]; then
    miss "the record is still there after the cleanup: $(grep -v '^#' "$conf" | tr '\n' '|')"
else
    ok "the record is gone once the cleanup is done"
fi
if grep -q 'getty@tty1\|lightdm' "$state/calls"; then
    miss "the second disable touched tty1 or the desktop: $(grep 'getty\|lightdm' "$state/calls" | tr '\n' '|')"
else
    ok "the second disable leaves tty1 and the desktop alone"
fi

echo "  disable after the desktop was uninstalled"
reset_box
run_helper enable >/dev/null 2>&1 || true
: >"$state/lightdm-removed"
: >"$state/calls"
rm -f "$state/user-calls"
if out=$(run_helper disable --purge 2>&1); then
    ok "disable exits 0"
else
    miss "disable failed: $(tail -5 <<<"$out" | tr '\n' '|')"
fi
out_has 'could not re-enable lightdm.service' "says the desktop login could not be re-enabled"
call_made 'systemctl start getty@tty1.service' "gives tty1 the console login instead"
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == DELETE ]]; then
    ok "still deletes the kiosk's Signal K user"
else
    miss "Signal K user calls: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
if jq -e '.enabled == false' "$cfgf" >/dev/null 2>&1; then
    ok "still switches signalk-autologin off"
else
    miss "plugin config after disable: $(cat "$cfgf" 2>/dev/null)"
fi
call_made 'userdel --remove signalk-kiosk' "still removes the kiosk system user"

echo "  Raspberry Pi OS, a page on another host"
reset_box
: >"$state/pi-os"
run_enable --url https://example.test/x
call_made 'apt-get install -y --no-install-recommends cage jq chromium rpi-chromium-mods' \
    "Pi OS: installs rpi-chromium-mods alongside chromium"
out_has 'is not on this server' "another host: says the kiosk cannot sign in there"
conf_has 'KIOSK_URL=https://example.test/x'
conf_has 'KIOSK_SIGNIN=none'
if [[ -e "$state/requests" ]]; then
    miss "contacted the server: $(tr '\n' '|' <"$state/requests")"
else
    ok "no requests to the server or npm"
fi

echo "  signalk-autologin 1.0.0 installed by the owner, admin for every device"
reset_box
preinstall_kip
preinstall_autologin 1.0.0 '{"enabled":true,"configuration":{"adminUser":"skipper"}}'
run_enable
out_has 'already granting admin to every device' "says the plugin grants admin network-wide by its own setting"
if [[ -s "$state/config-posts" ]]; then
    miss "changed the owner's plugin settings: $(tr '\n' '|' <"$state/config-posts")"
else
    ok "leaves the owner's plugin settings alone"
fi
if [[ "$(cat "$state/loaded-version" 2>/dev/null)" == 1.1.0 ]] && grep -qx 'signalk restart' "$state/calls"; then
    ok "updates the plugin to a release with token sign-in and restarts the server"
else
    miss "loaded version after enable: $(cat "$state/loaded-version" 2>/dev/null)"
fi
conf_has 'KIOSK_SIGNIN=token' "signs in after the update"
conf_has 'KIOSK_AUTOLOGIN_CHANGED=' "the owner's plugin: nothing recorded for disable to undo"
run_helper disable >/dev/null 2>&1 || true
if [[ -s "$state/config-posts" ]]; then
    miss "disable changed the owner's plugin: $(tr '\n' '|' <"$state/config-posts")"
else
    ok "disable leaves the owner's plugin on"
fi
no_unexpected_requests

echo "  signalk-autologin installed and switched off, KIP missing"
reset_box
preinstall_autologin 1.1.0 '{"enabled":false,"configuration":{"adminUser":"skipper"}}'
run_enable
if tail -1 "$state/config-posts" 2>/dev/null \
        | jq -e '.enabled == true and .configuration == {"adminUser": "skipper", "networkWideAdmin": false}' >/dev/null 2>&1; then
    ok "switches it on for token sign-in only, keeping its other settings"
else
    miss "config posts: $(tr '\n' '|' <"$state/config-posts" 2>/dev/null)"
fi
conf_has 'KIOSK_AUTOLOGIN_CHANGED=enabled'
conf_has 'KIOSK_SIGNIN=token'
if [[ "$(restarts)" == 1 && -e "$state/kip-loaded" ]]; then
    ok "restarts once for KIP, with the plugin already loaded"
else
    miss "restarts: $(restarts), KIP loaded: $([[ -e "$state/kip-loaded" ]] && echo yes || echo no)"
fi
no_unexpected_requests

echo "  KIP missing, --no-autologin"
reset_box
run_enable --no-autologin
if [[ -f "$kippkg" && "$(restarts)" == 1 && -e "$state/kip-loaded" ]]; then
    ok "installs KIP and restarts the server to serve it"
else
    miss "KIP installed: $([[ -f "$kippkg" ]] && echo yes || echo no), restarts: $(restarts), KIP loaded: $([[ -e "$state/kip-loaded" ]] && echo yes || echo no)"
fi
if grep -q 'autologin' "$state/requests" 2>/dev/null; then
    miss "touched signalk-autologin: $(grep autologin "$state/requests" | tr '\n' '|')"
else
    ok "leaves signalk-autologin alone"
fi
conf_has 'KIOSK_SIGNIN=none'
no_unexpected_requests

echo "  an earlier install left a configuration for every device"
reset_box
preinstall_kip
mkdir -p "${cfgf%/*}"
echo '{"enabled":true,"configuration":{}}' >"$cfgf"
run_enable
if [[ "$(cat "$state/config-at-install" 2>/dev/null)" == '{"enabled":true,"configuration":{}}' ]]; then
    ok "the existing configuration file is not overwritten"
else
    miss "plugin config when the install ran: $(cat "$state/config-at-install" 2>/dev/null)"
fi
if jq -e '.enabled == true and .configuration.networkWideAdmin == false' "$cfgf" >/dev/null 2>&1; then
    ok "the plugin the kiosk installed is switched to token sign-in only"
else
    miss "plugin config after enable: $(cat "$cfgf" 2>/dev/null)"
fi
out_has 'switched it to token sign-in only' "says it switched the plugin"
conf_has 'KIOSK_AUTOLOGIN_CHANGED=installed'
no_unexpected_requests

echo "  a Signal K user signalk-kiosk existed before the kiosk"
reset_box
preinstall_kip
preinstall_autologin 1.1.0 '{"enabled":true,"configuration":{"networkWideAdmin":false}}'
echo '[{"userId":"admin","type":"admin"},{"userId":"signalk-kiosk","type":"readonly"}]' >"$state/users.json"
run_enable --admin
conf_has 'KIOSK_SK_USER_CREATED=' "not recorded as created by the kiosk"
conf_has 'KIOSK_SK_USER_PREVIOUS_TYPE=readonly' "records the type the user had before"
run_enable
conf_has 'KIOSK_SK_USER_PREVIOUS_TYPE=readonly' "a later enable keeps the first recorded type"
cookies="$root/var/lib/signalk-kiosk/chromium/Default"
mkdir -p "$cookies/Network"
: >"$cookies/Cookies"
: >"$cookies/Network/Cookies"
: >"$state/put-fails"
out=$(run_helper disable 2>&1) || true
conf_has 'KIOSK_SK_USER_PREVIOUS_TYPE=readonly' "a restore that fails with the server up stays recorded"
out_has 'left for now' "says what is left"
rm -f "$state/put-fails" "$state/user-calls"
run_helper disable >/dev/null 2>&1 || true
if [[ -e "$conf" ]]; then
    miss "the record stays after the retry succeeded"
else
    ok "disable run again restores the type and drops the record"
fi
if [[ -e "$cookies/Cookies" || -e "$cookies/Network/Cookies" ]]; then
    miss "disable left the browser's session cookie for a user whose tokens stay valid"
else
    ok "disable removes the browser's session cookie, since the user's tokens stay valid"
fi
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == 'PUT {"type":"readonly"}' ]]; then
    ok "disable gives the user back its earlier type instead of deleting it"
else
    miss "Signal K user calls on disable: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
if jq -e '.[] | select(.userId == "signalk-kiosk") | .type == "readonly"' "$state/users.json" >/dev/null; then
    ok "the user is readonly again"
else
    miss "users after disable: $(cat "$state/users.json")"
fi
reset_box
preinstall_kip
preinstall_autologin 1.1.0 '{"enabled":true,"configuration":{"networkWideAdmin":false}}'
echo '[{"userId":"admin","type":"admin"},{"userId":"signalk-kiosk","type":"readonly"}]' >"$state/users.json"
run_helper enable --admin >/dev/null 2>&1 || true
mkdir -p "$cookies/Network"
: >"$cookies/Network/Cookies"
rm -f "$state/user-calls"
: >"$state/calls"
run_enable --no-autologin
if [[ -e "$cookies/Network/Cookies" ]]; then
    miss "--no-autologin left the browser signed in"
else
    ok "--no-autologin removes the browser's session cookie"
fi
call_made 'systemctl stop signalk-kiosk.service' "stops the kiosk before touching its cookies"
if [[ "$(cat "$state/user-calls" 2>/dev/null)" == 'PUT {"type":"readonly"}' ]]; then
    ok "a re-run with --no-autologin gives the user back its earlier type too"
else
    miss "Signal K user calls on --no-autologin: $(tr '\n' '|' <"$state/user-calls" 2>/dev/null)"
fi
conf_has 'KIOSK_SK_USER_PREVIOUS_TYPE=' "and no longer records it"
no_unexpected_requests

echo "  a found user of the right type, and a kiosk system user with its own home"
reset_box
preinstall_kip
preinstall_autologin 1.1.0 '{"enabled":true,"configuration":{"networkWideAdmin":false}}'
echo '[{"userId":"admin","type":"admin"},{"userId":"signalk-kiosk","type":"readwrite"}]' >"$state/users.json"
: >"$state/user-exists"
echo /home/kiosk >"$state/kiosk-home"
run_enable
conf_has 'KIOSK_SK_USER_PREVIOUS_TYPE=' "no type change, nothing to put back"
ownhome="$root/home/kiosk"
mkdir -p "$ownhome/chromium/Default/Network"
: >"$ownhome/chromium/Default/Network/Cookies"
: >"$ownhome/start.html"
: >"$state/calls"
run_enable --no-autologin
call_made 'systemctl stop signalk-kiosk.service' "sign-in off: stops the kiosk"
if [[ -e "$ownhome/chromium/Default/Network/Cookies" || -e "$ownhome/start.html" ]]; then
    miss "sign-in off left the session cookie or start page in the user's own home"
else
    ok "sign-in off clears the session cookie and start page in the user's own home"
fi
run_helper enable >/dev/null 2>&1 || true
: >"$ownhome/chromium/Default/Network/Cookies"
run_helper disable >/dev/null 2>&1 || true
if [[ -e "$ownhome/chromium/Default/Network/Cookies" ]]; then
    miss "disable left the session cookie of a user whose tokens stay valid"
else
    ok "disable clears the session cookie there too"
fi
no_unexpected_requests

echo "  the server has TLS enabled"
reset_box
: >"$state/tls"
if out=$(run_helper enable 2>&1); then
    miss "enable went ahead on a server with TLS enabled"
else
    ok "enable refuses"
fi
out_has 'has TLS enabled' "says the server has TLS enabled"
if [[ -e "$state/calls" ]]; then
    miss "changed something before refusing: $(tr '\n' '|' <"$state/calls")"
else
    ok "refuses before changing anything"
fi
for u in https://127.0.0.1:443/@mxtommy/kip/ https://localhost/@mxtommy/kip/ http://localhost/@mxtommy/kip/; do
    if out=$(run_helper enable --url "$u" 2>&1); then
        miss "enable went ahead with $u, this server's own address"
    else
        ok "refused: $u"
    fi
done
# A page on another host does not go through this server.
run_enable --url https://example.test/x
conf_has 'KIOSK_URL=https://example.test/x' "a page on another host is still set up"

echo "  the server refuses the admin token"
reset_box
preinstall_kip
preinstall_autologin 1.1.0 '{"enabled":true,"configuration":{"networkWideAdmin":false}}'
echo "a-rotated-token" >"$home/.signalk-doctor/signalk-token"
run_enable
out_has 'the server refused the admin token' "says the admin token was refused"
if [[ "$(restarts)" == 0 ]]; then
    ok "no server restart for a refused token"
else
    miss "restarted the server $(restarts) times for a refused token"
fi
conf_has 'KIOSK_SIGNIN=none' "falls back to the login page"
no_unexpected_requests

echo "  no admin token"
reset_box
rm -f "$home/.signalk-doctor/signalk-token"
run_enable
out_has 'KIP is not installed, and without an admin token' "says why it cannot install KIP"
out_has 'no admin token' "says why the kiosk cannot sign in"
conf_has 'KIOSK_SIGNIN=none' "falls back to the login page"
call_made 'systemctl enable signalk-kiosk.service' "the kiosk itself is still enabled"

# ── 5b. status capture ────────────────────────────────────────────────────
# On a connection failure curl prints its own 000 via -w and exits non-zero,
# so `$(curl … || echo 000)` yields 000000 (see check-curl-status-capture.sh).
echo "status capture"
if grep -n '|| echo 000)' "$TMPL"; then
    miss "a status capture appends to curl's own 000"
else
    ok "every status capture assigns 000 outside the substitution"
fi

# ── 6. uninstall while the kiosk is enabled ───────────────────────────────
echo "uninstall with the kiosk enabled"
ubin="$tmp/ubin"
uroot="$tmp/uroot"
mkdir -p "$ubin" "$uroot/etc/systemd/system" "$tmp/uhome"
: >"$uroot/etc/systemd/system/signalk-kiosk.service"
for c in systemctl podman; do
    printf '#!/bin/bash\necho "%s $*" >>"%s/ucalls"\n' "$c" "$tmp" >"$ubin/$c"
done
chmod +x "$ubin"/*
check_refusal() {
    local label="$1"
    shift
    : >"$tmp/ucalls"
    if out=$(HOME="$tmp/uhome" KIOSK_ROOT="$uroot" PATH="$ubin:$PATH" "$@" 2>&1); then
        miss "$label ran with the kiosk enabled"
    elif grep -qF "Run 'signalk kiosk disable --purge' first" <<<"$out" && [[ ! -s "$tmp/ucalls" ]]; then
        ok "$label refuses before stopping anything"
    else
        miss "$label: $(tr '\n' '|' <<<"$out") calls: $(tr '\n' '|' <"$tmp/ucalls")"
    fi
}
check_refusal "signalk uninstall" bash installer/linux/signalk.tmpl uninstall
check_refusal "scripts/uninstall.sh" bash scripts/uninstall.sh

if (( fail )); then
    echo "[FAIL] check-kiosk"
    exit 1
fi
echo "[PASS] check-kiosk"
