#!/usr/bin/env bash
# Verifies the two-channel site layout and the version label each tree carries.
#
# The site publishes the latest RELEASE at its root and master under /dev. Both
# the bash one-liner and the doctor's /api/installer/refresh read the root, so
# getting this wrong does not fail loudly -- it silently ships master to every
# boat, which is the behaviour this change exists to stop.
#
# The labels are the fragile half. scripts/installer-version.sh already carries
# a warning about a release that shipped correct code labelled
# `0.3.0-46-g2663942` because two runs disagreed about the version. With two
# trees there are now two labels per deploy, and mixing them up would put a
# release label on master's code -- worse than the original incident, because
# `signalk version` would then lie about what is installed.
#
# Run from repo root.

set -euo pipefail

STAGE=${STAGE:-scripts/stage-site.sh}

if [[ ! -f "$STAGE" ]]; then
    echo "[ERR] $STAGE not found (run from repo root)" >&2
    exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

# A minimal checkout: just enough shape for stage-site.sh to work on.
mk_src() {
    local d=$1 marker=$2
    mkdir -p "$d/installer/linux" "$d/quadlets"
    cat > "$d/installer/linux/install.sh" <<EOF
#!/usr/bin/env bash
INSTALLER_VERSION="\${INSTALLER_VERSION:-0.0.0-scaffold}"
MARKER=$marker
EOF
    cat > "$d/installer/linux/signalk.tmpl" <<'EOF'
#!/usr/bin/env bash
SK_VERSION="__SK_VERSION__"
EOF
    echo "# readme" > "$d/README.md"
    echo "Image=x" > "$d/quadlets/a.container.template"
}

mk_src "$TMP/rel" RELEASE
mk_src "$TMP/dev" MASTER

bash "$STAGE" "$TMP/rel" "$TMP/dist"     "0.5.1"          >/dev/null
bash "$STAGE" "$TMP/dev" "$TMP/dist/dev" "0.5.1-7-gabc123" >/dev/null

check() {
    local label=$1 expected=$2 got=$3
    if [[ "$got" == "$expected" ]]; then
        echo "  [OK]   $label"
    else
        echo "  [MISS] $label"
        echo "         expected: [$expected]"
        echo "         got:      [$got]"
        fail=1
    fi
}

root_ver=$(sed -n 's/.*INSTALLER_VERSION:-\([^}]*\)}.*/\1/p' "$TMP/dist/installer/linux/install.sh")
dev_ver=$(sed -n 's/.*INSTALLER_VERSION:-\([^}]*\)}.*/\1/p' "$TMP/dist/dev/installer/linux/install.sh")
check "site root carries the release version" "0.5.1" "$root_ver"
check "/dev carries the master describe label" "0.5.1-7-gabc123" "$dev_ver"

root_marker=$(sed -n 's/^MARKER=//p' "$TMP/dist/installer/linux/install.sh")
dev_marker=$(sed -n 's/^MARKER=//p' "$TMP/dist/dev/installer/linux/install.sh")
check "site root serves the RELEASE tree" "RELEASE" "$root_marker"
check "/dev serves the MASTER tree" "MASTER" "$dev_marker"

# .tmpl dispatchers are fetched verbatim by the doctor's refresh, so their
# placeholder must be substituted too or `signalk version` reports the literal.
root_sk=$(sed -n 's/^SK_VERSION="\(.*\)"/\1/p' "$TMP/dist/installer/linux/signalk.tmpl")
check "the .tmpl dispatcher placeholder is substituted" "0.5.1" "$root_sk"

# Nesting /dev INSIDE the root tree is what lets one Pages deploy serve both.
# If the root tree ever stopped containing dev/, the dev channel 404s.
if [[ -f "$TMP/dist/dev/installer/linux/install.sh" ]]; then
    echo "  [OK]   /dev nests inside the published root"
else
    echo "  [MISS] /dev is not inside the published tree"; fail=1
fi

# The scaffold placeholder must not survive into either tree: it is what
# `signalk version` falls back to, and shipping it means the version is a lie.
if grep -rq '0\.0\.0-scaffold' "$TMP/dist/installer" 2>/dev/null; then
    echo "  [MISS] the scaffold placeholder survived into a published tree"; fail=1
else
    echo "  [OK]   no scaffold placeholder left in either tree"
fi

# --- the consumer side ------------------------------------------------------
# install.sh must default to the release root and only opt in to /dev.
probe_base() {
    local ch=$1
    # shellcheck disable=SC2016  # the inner script is evaluated by the child
    env ${ch:+SIGNALK_CHANNEL="$ch"} bash -c '
        eval "$(sed -n "/^SIGNALK_CHANNEL=/,/^INSTALLER_BASE_URL=/p" installer/linux/install.sh)"
        printf "%s" "$INSTALLER_BASE_URL"' 2>/dev/null
}
SITE=https://dirkwa.github.io/signalk-universal-installer
check "default channel resolves to the release root" "$SITE"      "$(probe_base '')"
check "SIGNALK_CHANNEL=release resolves to the root"  "$SITE"      "$(probe_base release)"
check "SIGNALK_CHANNEL=master resolves to /dev"       "$SITE/dev"  "$(probe_base master)"

# An explicit base URL is the escape hatch for mirrors, CI and local checkouts.
# The channel must not quietly override it.
got=$(SIGNALK_CHANNEL=master INSTALLER_BASE_URL=http://example/x bash -c '
    eval "$(sed -n "/^SIGNALK_CHANNEL=/,/^INSTALLER_BASE_URL=/p" installer/linux/install.sh)"
    printf "%s" "$INSTALLER_BASE_URL"' 2>/dev/null)
check "explicit INSTALLER_BASE_URL still wins" "http://example/x" "$got"

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] site channels"
    exit 1
fi
echo "[PASS] site channels"
