#!/usr/bin/env bash
# Source me. wait_for_http URL TIMEOUT_SEC — poll until 2xx/3xx response.
# Used to gate startup on container health endpoints.

wait_for_http() {
    local url=$1
    local timeout=${2:-60}
    local start=$SECONDS
    while (( SECONDS - start < timeout )); do
        if curl -fsS -o /dev/null -m 5 "$url"; then
            return 0
        fi
        sleep 2
    done
    return 1
}
