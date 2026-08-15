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
if grep -rq '0\.0\.0-scaffold' "$TMP/dist" 2>/dev/null; then
    echo "  [MISS] the scaffold placeholder survived into a published tree"; fail=1
else
    echo "  [OK]   no scaffold placeholder left in either tree"
fi

# --- the consumer side ------------------------------------------------------
# install.sh must default to the release root and only opt in to /dev.
probe_base() {
    local ch=$1
    # Always pass the variable: install.sh maps an empty value to `release`
    # via ${VAR:-release}, so there is no need for a conditional expansion.
    # shellcheck disable=SC2016  # the inner script is evaluated by the child
    env SIGNALK_CHANNEL="$ch" bash -c '
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

# --- the label must come from the tree it describes -------------------------
# THE TAG-RUN TRAP. On a tag-triggered deploy the triggering ref is the release
# tag, so a label derived from it would be stamped onto BOTH trees -- publishing
# master's code under the release's version number whenever master has moved on
# past the tag. `signalk version` would then report a release that is not what
# is installed, which is the same class of bug installer-version.sh already
# carries a scar from, multiplied by two channels.
#
# Driven through a real repo and the real helper rather than a mock, because the
# property under test is exactly what the helper computes.
VER=${VER:-scripts/installer-version.sh}
REPO="$TMP/repo"
mkdir -p "$REPO"
(
    cd "$REPO"
    git init -q .
    # Set the identity on the repo, not per command: `git tag -a` needs a
    # committer too, and a host with no global git config (CI images, this
    # one) fails the annotated tag while the commits succeed -- leaving the
    # test describing an untagged history and quietly proving nothing.
    git config user.name test
    git config user.email test@example.invalid
    mkdir -p scripts
    cp "$OLDPWD/$VER" scripts/installer-version.sh
    git add -A
    git commit -qm "release commit"
    git tag -a v1.0.0 -m v1.0.0
    # master moves on after the tag — the case that breaks a shared label.
    echo x > extra.txt
    git add -A
    git commit -qm "post-release commit"
) >/dev/null 2>&1

rel_label=$(cd "$REPO" && git worktree add --detach "$TMP/wt-rel" v1.0.0 >/dev/null 2>&1     && cd "$TMP/wt-rel" && bash scripts/installer-version.sh 2>/dev/null)
dev_label=$(cd "$REPO" && git worktree add --detach "$TMP/wt-dev" HEAD >/dev/null 2>&1     && cd "$TMP/wt-dev" && bash scripts/installer-version.sh 2>/dev/null)

check "release worktree labels as the bare tag" "1.0.0" "$rel_label"
if [[ -n "$dev_label" && "$dev_label" != "$rel_label" ]]; then
    echo "  [OK]   master-ahead-of-tag gets its own label ($dev_label)"
else
    echo "  [MISS] master would publish under the release label [$dev_label]"
    fail=1
fi

# The workflow must derive the /dev label from the master worktree, not from
# the triggering ref. Structural, because the workflow itself cannot run here.
WF=${WF:-.github/workflows/pages.yml}
if grep -q 'cd .site-dev && bash scripts/installer-version.sh' "$WF"; then
    echo "  [OK]   workflow computes the /dev label from the master worktree"
else
    echo "  [MISS] workflow may label /dev from the triggering ref"; fail=1
fi

# --- the master bootstrap must not report success after a failed fetch ------
CLI=${CLI:-installer/linux/signalk.tmpl}
if grep -q "set -o pipefail" "$CLI"; then
    echo "  [OK]   master bootstrap sets pipefail in the child shell"
else
    echo "  [MISS] a failed curl would leave cmd_update reporting success"; fail=1
fi
# The variable is read by the DOWNLOADED script, so it must sit on the bash
# that runs it. On the curl it is silently ignored and the run mixes channels.
if grep -qE '\| *SIGNALK_CHANNEL=' "$CLI" && ! grep -qE 'SIGNALK_CHANNEL=[^ ]* *curl' "$CLI"; then
    echo "  [OK]   SIGNALK_CHANNEL is passed to bash, not to curl"
else
    echo "  [MISS] SIGNALK_CHANNEL is on the wrong side of the pipe"; fail=1
fi

# --- the VM-based installers must reach both channels too -------------------
# Windows and macOS run the Linux installer inside a VM. Both used to hardcode
# INSTALLER_BASE_URL and pass it explicitly into that VM, which beats the
# channel (install.sh lets an explicit base win) and pinned them to the release
# tree with no way to reach /dev.
LINUX=${LINUX_INSTALLER:-installer/linux/install.sh}
PS1=${PS1_INSTALLER:-installer/windows/install.ps1}
MACOS=${MACOS_INSTALLER:-installer/macos/install.sh}

# The site root must be spelled identically everywhere. Drift here silently
# sends one platform to a tree that does not exist.
# Label by platform, not basename: linux and macos are both "install.sh" and a
# collided label would hide which one failed.
root_re='https://dirkwa\.github\.io/signalk-universal-installer'
for pair in "linux:$LINUX" "windows:$PS1" "macos:$MACOS"; do
    plat=${pair%%:*}; f=${pair#*:}
    if grep -qE "$root_re" "$f"; then
        echo "  [OK]   $plat installer uses the canonical site root"
    else
        echo "  [MISS] $plat installer does not name the canonical site root"; fail=1
    fi
done

if grep -qE "ValidateSet\('release', *'master', *'dev'\)" "$PS1"; then
    echo "  [OK]   install.ps1 accepts the same channels as install.sh"
else
    echo "  [MISS] install.ps1 -Channel does not match install.sh's channels"; fail=1
fi

# ContainsKey is the only way to tell an explicitly-passed -InstallerBaseUrl
# from the parameter default; without it -Channel loses to the default base URL
# on every run and the flag does nothing.
if grep -q "PSBoundParameters.ContainsKey('InstallerBaseUrl')" "$PS1"; then
    echo "  [OK]   install.ps1 detects an explicit -InstallerBaseUrl"
else
    echo "  [MISS] install.ps1 cannot tell an explicit base URL from the default"; fail=1
fi

# Same bash-not-curl rule as above, on both VM handoffs. Neither installer
# writes SIGNALK_CHANNEL next to curl literally - both build the assignments in
# a variable and splice it in ($skEnv on Windows, $_SK_CHAN_ENV on macOS), so
# grepping for the literal next to `curl` can never fail and proves nothing.
# Check the SPLICE POINT instead: on the handoff line, whatever carries the
# channel must appear after the pipe, never before curl.
for triple in "windows:$PS1:__SKENV__" "macos:$MACOS:\${_SK_CHAN_ENV}"; do
    plat=${triple%%:*}; rest=${triple#*:}; f=${rest%:*}; splice=${rest##*:}
    # Join backslash continuations first: macOS wraps the handoff across two
    # physical lines, Windows keeps it on one (a `\` + CRLF there would make
    # bash swallow the CR). Both must be compared as one logical line.
    #
    # Anchor on `curl … | … bash`, not on the install.sh path: macOS reaches the
    # URL through ${LINUX_URL}, so the literal path never appears on the line
    # that actually pipes into bash.
    line=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f" \
        | grep -E "curl -fsSL .*\|.* bash" | head -1)
    if [[ -z "$line" ]]; then
        echo "  [MISS] $plat installer: could not find the curl|bash handoff line"; fail=1
        continue
    fi
    before=${line%%|*}
    if [[ "$before" == *"$splice"* ]]; then
        echo "  [MISS] $plat installer splices the channel before the pipe (curl reads it, bash never does)"; fail=1
    elif [[ "$line" != *"$splice"* ]]; then
        echo "  [MISS] $plat installer no longer passes the channel into the VM at all"; fail=1
    else
        echo "  [OK]   $plat installer splices the channel after the pipe"
    fi
done

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] site channels"
    exit 1
fi
echo "[PASS] site channels"
