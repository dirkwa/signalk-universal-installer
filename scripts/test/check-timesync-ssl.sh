#!/usr/bin/env bash
# Runs signalk-timesync's api() against a stand-in for a signalk-server with
# SSL enabled: an HTTP port that only redirects to an HTTPS port with a
# self-signed certificate, which answers only requests carrying the token.
#
# Needs python3 and openssl. Run from the repo root.

set -euo pipefail

TMPL="${TMPL:-installer/linux/signalk-timesync.tmpl}"
if [[ ! -f "$TMPL" ]]; then
    echo "[ERR] $TMPL not found (run from repo root)" >&2
    exit 2
fi

tmp=$(mktemp -d)
pids=()
cleanup() {
    if (( ${#pids[@]} )); then kill "${pids[@]}" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

cat >"$tmp/server.py" <<'EOF'
import http.server, json, socket, ssl, sys, threading

token, cert, key, portfile = sys.argv[1:5]

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port

https_port, http_port = free_port(), free_port()

class Redirect(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", f"https://127.0.0.1:{https_port}{self.path}")
        self.end_headers()
    def log_message(self, *a): pass

class Api(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != f"Bearer {token}":
            self.send_response(401); self.end_headers(); return
        body = json.dumps({"value": "2026-11-16T20:00:00.000Z",
                           "timestamp": "2026-11-16T20:00:00.000Z"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

https = http.server.HTTPServer(("127.0.0.1", https_port), Api)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
https.socket = ctx.wrap_socket(https.socket, server_side=True)
plain = http.server.HTTPServer(("127.0.0.1", http_port), Redirect)
threading.Thread(target=https.serve_forever, daemon=True).start()
with open(portfile, "w") as f:
    f.write(str(http_port))
plain.serve_forever()
EOF

TOKEN=test-token
python3 "$tmp/server.py" "$TOKEN" "$tmp/cert.pem" "$tmp/key.pem" "$tmp/port" &
pids+=("$!")
for _ in $(seq 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
[[ -s "$tmp/port" ]] || { echo "[ERR] test server did not start" >&2; exit 2; }
port=$(<"$tmp/port")

# api() from the rendered agent, with the HTTP port of the stand-in server.
sed -e 's/__SK_USER__/tester/g' -e "s/__SK_HTTP_PORT__/$port/g" "$TMPL" >"$tmp/agent.sh"
{
    grep -E '^SK_URL=' "$tmp/agent.sh"
    awk '/^api\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$tmp/agent.sh"
} >"$tmp/api.sh"
grep -q '^api()' "$tmp/api.sh" || { echo "[ERR] could not extract api() from $TMPL" >&2; exit 2; }

# shellcheck disable=SC1091
. "$tmp/api.sh"
export TOKEN

if out=$(api navigation/datetime) && [[ "$out" == *'"value": "2026-11-16T20:00:00.000Z"'* ]]; then
    echo "  [OK]   api() follows the HTTPS redirect with the token"
    echo "[PASS] timesync SSL checks"
else
    echo "  [MISS] api() got no datetime through the HTTPS redirect (output: ${out:-<none>})"
    echo "[FAIL] timesync SSL checks"
    exit 1
fi
