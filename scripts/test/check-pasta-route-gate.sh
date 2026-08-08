#!/usr/bin/env bash
# Verifies the pasta boot-race route gate in the engine Quadlet templates
# (issue #250).
#
# pasta reads the host's routes ONCE at container create. A container that
# wins the race against the host NIC gets the link-local 169.254.2.1
# fallback, and host.containers.internal then points at an address nothing
# listens on for the container's LIFETIME — connections black-hole rather
# than fail, so no app-level retry recovers. The engine templates gate on a
# default route before podman creates the container.
#
# The race itself needs a real boot to reproduce, so CI checks what CAN be
# verified host-independently:
#   1. Each pasta-networked engine template carries exactly one ExecStartPre,
#      and it is a BOUNDED wait over /proc/net/route that always exits 0 (an
#      offline boat must still get its consoles).
#   2. That line contains no `$` and no single `%` — systemd collapses `$$`
#      to `$` and treats `%` as a specifier, so either would corrupt the
#      predicate silently, with no failed unit to notice.
#   3. THE INVARIANT: any template that suppresses the network-wait shim AND
#      publishes a port AND is not Network=host must carry the gate. This is
#      what catches the next engine Quadlet someone adds.
#   4. The predicate actually matches a default route and rejects a
#      subnet-only route and the /proc/net/route header.
#   5. The disproved shim folklore stays deleted.
#
# Run from the repo root.

set -euo pipefail

QUADLET_DIR="${QUADLET_DIR:-quadlets}"
if [[ ! -d "$QUADLET_DIR" ]]; then
    echo "[ERR] $QUADLET_DIR not found (run from repo root)" >&2
    exit 2
fi

# The pasta-networked engine units. signalk-server is Network=host (no netns
# address for pasta to latch) and signalk-dbus-proxy never sends an IP packet;
# both are deliberately ungated — check 3 enforces that this list stays honest.
GATED_TEMPLATES=(
    "$QUADLET_DIR/signalk-doctor-server.container.template"
    "$QUADLET_DIR/signalk-updater-server.container.template"
)

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  [OK]   $1"; }
miss() { echo "  [MISS] $1"; fail=1; }

# ── 1+2. Each gated template: one bounded, fail-safe, sigil-free gate ───────

for tmpl in "${GATED_TEMPLATES[@]}"; do
    name=$(basename "$tmpl")
    if [[ ! -f "$tmpl" ]]; then
        miss "$name not found"
        continue
    fi

    count=$(grep -c '^ExecStartPre=' "$tmpl" || true)
    line=$(grep '^ExecStartPre=' "$tmpl" || true)

    # Bounded: a finite `for` list, not `while`/`until`. Fail-safe: ends in
    # `exit 0`, so a host that never gets a route still starts the container.
    if [[ "$count" == "1" ]] \
        && printf '%s' "$line" | grep -Eq \
            'for _ in [0-9 ]+; do grep -qE .*/proc/net/route && break; sleep 1; done; exit 0'; then
        ok "$name: single bounded route gate, always exits 0"
    else
        miss "$name: route gate missing, duplicated, unbounded, or not fail-safe"
        printf '         count=%s %s\n' "$count" "$line"
    fi

    # `$` would be eaten or halved by systemd's variable expansion ($$ -> $);
    # a lone `%` is a unit specifier. Either corrupts the predicate with no
    # failed unit to notice, which is why the predicate avoids both entirely.
    # For %, strip the legitimate escaped %% pairs first; anything left is a
    # bare specifier. Matching '%[^%]' instead would both miss a trailing %
    # and wrongly flag a correctly-escaped %%.
    if printf '%s' "$line" | grep -q '[$]'; then
        miss "$name: route gate contains a literal \$ (systemd expands/halves it)"
    elif printf '%s' "$line" | sed 's/%%//g' | grep -q '%'; then
        miss "$name: route gate contains a bare % (systemd specifier)"
    else
        ok "$name: route gate free of \$ and bare %"
    fi
done

# ── 3. The invariant: shim suppressed + published port + not host-net ───────

for tmpl in "$QUADLET_DIR"/*.container.template; do
    name=$(basename "$tmpl")
    grep -q '^DefaultDependencies=false' "$tmpl" || continue
    grep -q '^PublishPort=' "$tmpl"             || continue
    grep -qi '^Network=host' "$tmpl"            && continue

    if grep -q '^ExecStartPre=.*proc/net/route' "$tmpl"; then
        ok "$name: pasta-networked with a published port, and gated"
    else
        miss "$name: suppresses the network-wait shim and publishes a port on pasta, but has no route gate (#250)"
    fi
done

# ── 4. The predicate matches a default route and nothing else ──────────────

# Extract the live predicate from each template rather than restating it, so
# this check tracks the real lines instead of drifting from them. Every gated
# template is exercised: checking only the first would let a divergent
# predicate in the second ship untested.

# Field 2 is the destination, field 3 the gateway; both hex, little-endian.
printf 'eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n' >"$tmp/route-default"
printf 'eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n' >"$tmp/route-subnet"
printf 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\n'  >"$tmp/route-header"
# VLANs, bridges and aliases are ordinary on a boat LAN. An interface-name
# class of [a-z0-9]+ silently rejects all three, so a host with a perfectly
# good default route would burn the full wait on every boot.
printf 'eth0.100\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n' >"$tmp/route-vlan"
printf 'br-lan\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'   >"$tmp/route-bridge"

check_predicate() {
    local file="$1" want="$2" label="$3" got=no
    # shellcheck disable=SC2086 # predicate is a command line, must word-split
    if ( eval "${predicate//\/proc\/net\/route/$file}" ) 2>/dev/null; then got=yes; fi
    if [[ "$got" == "$want" ]]; then
        ok "predicate $label -> $got"
    else
        miss "predicate $label -> $got (want $want)"
    fi
}

for tmpl in "${GATED_TEMPLATES[@]}"; do
    [[ -f "$tmpl" ]] || continue
    name=$(basename "$tmpl" .container.template)
    predicate=$(grep -h '^ExecStartPre=' "$tmpl" \
        | sed -e 's/.*do //' -e 's/ && break.*//')

    check_predicate "$tmp/route-default" yes "$name: matches a default route"
    check_predicate "$tmp/route-vlan"    yes "$name: matches a VLAN interface (eth0.100)"
    check_predicate "$tmp/route-bridge"  yes "$name: matches a bridge interface (br-lan)"
    check_predicate "$tmp/route-subnet"  no  "$name: rejects a subnet-only route"
    check_predicate "$tmp/route-header"  no  "$name: rejects the /proc/net/route header"
done

# ── 5. Disproved folklore stays gone ───────────────────────────────────────

# The generator keys on the DefaultDependencies value, NOT on the source
# text: naming the shim service in a comment does not re-inject anything.
# Verified against podman 5.4.2's generator; the claim must not creep back.
if grep -rqi 'scans the source text\|do NOT name the shim' "$QUADLET_DIR"/; then
    miss "disproved 'generator scans the source text' folklore is back in $QUADLET_DIR/"
else
    ok "disproved shim folklore absent"
fi

if [[ "$fail" == 0 ]]; then
    echo "[PASS] pasta route gate checks"
else
    echo "[FAIL] pasta route gate checks" >&2
    exit 1
fi
