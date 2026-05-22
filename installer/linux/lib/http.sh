#!/usr/bin/env bash
# Source me. wait_for_http URL TIMEOUT_SEC — poll until 2xx/3xx response.
# Used to gate startup on container health endpoints.

wait_for_http() {
    local url=$1
    local timeout=${2:-60}
    local start=$SECONDS
    # Silence curl error chatter during the warm-up window (Recv failure /
    # connection refused while a container is starting). We retry on every
    # exit code; the caller only cares about eventual success/timeout.
    while (( SECONDS - start < timeout )); do
        if curl -fsS -o /dev/null -m 5 "$url" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}
