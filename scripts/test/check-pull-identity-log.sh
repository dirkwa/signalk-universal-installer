#!/usr/bin/env bash
# `podman pull` exiting 0 does not say WHICH build the tag resolved to,
# and the rolling tags (:dirkwa, :latest, :master) move every few hours.
# Without the digest in the install log there is no way to tell, after the
# fact, whether a box pulled the then-current build or kept an older local
# tag — the two are indistinguishable from a successful exit code, and a
# boat is usually off-network by the time anyone reads the log.
#
# This check pins the behaviours that make the log line trustworthy: the
# digest is recorded, the build identity beside it comes from labels baked
# into the image (so it survives a clean-store pull, which stores only the
# requested ref), and an image or podman that cannot answer never aborts
# the install.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/installer/linux/install.sh"

fail=0

# Extract the helper verbatim from install.sh so this tests the shipped
# code, not a copy that can drift away from it.
helper=$(sed -n '/^log_pulled_identity() {/,/^}/p' "$INSTALL_SH")
if [[ -z "$helper" ]]; then
    echo "  [MISS] log_pulled_identity not found in install.sh"
    exit 1
fi

# The helper must run only after a pull actually succeeded. Grepping for
# the call site would pass with it moved above the failure branches, which
# would log an identity for a pull that failed. Run the real loop instead,
# against a podman whose `pull` fails, and require that no identity is
# logged — the loop exits non-zero there, so the assertion is on output.
# SC2016: `$SK_IMAGE` is literal text being matched in install.sh, not a
# shell expansion here.
# shellcheck disable=SC2016
loop=$(sed -n '/^for img in "\$SK_IMAGE"/,/^done$/p' "$INSTALL_SH")
if [[ -z "$loop" ]]; then
    echo "  [MISS] could not extract the pull loop from install.sh"
    fail=1
else
    LOOP_STUB=$(mktemp -d)
    cat >"$LOOP_STUB/podman" <<'STUB'
#!/usr/bin/env bash
# `pull` fails; any inspect would succeed — so an identity line in the
# output can only mean the helper ran on a failed pull.
[[ "$1" == "pull" ]] && exit 1
case "$5" in
    *Digest*)   echo "sha256:ffff" ;;
    *revision*) echo "0123456789abcdef0123456789abcdef01234567" ;;
    *version*)  echo "9.9.9" ;;
esac
STUB
    chmod +x "$LOOP_STUB/podman"
    out=$(PATH="$LOOP_STUB:$PATH" bash -c "
        set -uo pipefail
        info() { printf '[i] %s\n' \"\$*\"; }
        err()  { printf '[E] %s\n' \"\$*\"; }
        sk_staging_cleanup() { :; }
        SK_IMAGE=img-a; UPDATER_IMAGE=img-b; DOCTOR_IMAGE=img-c
        SK_STAGING_DIR=$LOOP_STUB
        $helper
        $loop
    " 2>&1 || true)
    rm -rf "$LOOP_STUB"
    if grep -qE 'sha256:ffff|9\.9\.9|rev 0123456' <<<"$out"; then
        echo "  [MISS] identity logged for a FAILED pull: $out"
        fail=1
    else
        echo "  [OK]   a failed pull logs no identity"
    fi
fi

# Identity must come from image labels, not from RepoTags. After a plain
# `podman pull repo:tag` the local store holds only the ref that was asked
# for — verified against podman 5.4.2 with a tag never pulled on the host
# — so a RepoTags-derived alias is absent on exactly the clean-store
# install this log line exists to document.
if grep -q 'RepoTags' <<<"$helper"; then
    echo "  [MISS] helper reads RepoTags — absent on a clean-store pull"
    fail=1
else
    echo "  [OK]   identity is read from image labels, not RepoTags"
fi

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub podman: these cases must not depend on a real image store or a
# network path. `podman image inspect <img> --format <fmt>` is the only
# call shape the helper makes.
write_stub() {
    cat >"$STUB_DIR/podman" <<STUB
#!/usr/bin/env bash
case "\$5" in
    *Digest*)   printf '%s\n' '$1' ;;
    *revision*) printf '%s\n' '$2' ;;
    *version*)  printf '%s\n' '$3' ;;
esac
STUB
    chmod +x "$STUB_DIR/podman"
}

run_helper() {
    PATH="$STUB_DIR:$PATH" bash -c "
        set -euo pipefail
        info() { printf '[i] %s\n' \"\$*\"; }
        $helper
        log_pulled_identity '$1'
        echo '__SURVIVED__'
    " 2>&1
}

# 1. Digest plus both labels: the version and a short revision.
write_stub 'sha256:aaaa' '41c63156516151600bd4354ed4a189d1d99c944f' '2.31.1'
out=$(run_helper ghcr.io/x/img:dirkwa)
if grep -q 'sha256:aaaa' <<<"$out" && grep -q '2\.31\.1' <<<"$out" && grep -q '41c6315' <<<"$out"; then
    echo "  [OK]   digest + version + revision logged"
else
    echo "  [MISS] expected digest, version and revision, got: $out"
    fail=1
fi

# The revision is short-sha'd: a full 40-char hash crowds the line, and the
# first 7 are what the build's own tags and the GitHub UI use.
if grep -q '41c63156516151600bd4354ed4a189d1d99c944f' <<<"$out"; then
    echo "  [MISS] revision was not shortened: $out"
    fail=1
else
    echo "  [OK]   revision is shortened to a short sha"
fi

# 2. A missing label prints "<no value>" via Go's `index`. That must never
#    reach the log as though it were an identity.
write_stub 'sha256:bbbb' '<no value>' '<no value>'
out=$(run_helper docker.io/library/busybox:1.36)
if grep -q 'sha256:bbbb' <<<"$out" && ! grep -q 'no value' <<<"$out" \
    && ! grep -q '(' <<<"$out"; then
    echo "  [OK]   unlabelled image logs the digest alone"
else
    echo "  [MISS] unlabelled image produced: $out"
    fail=1
fi

# 3. Only one of the two labels present — still useful, still clean.
write_stub 'sha256:cccc' 'abcdef1234567890abcdef1234567890abcdef12' '<no value>'
out=$(run_helper ghcr.io/x/img:tag)
if grep -q 'rev abcdef1' <<<"$out" && ! grep -q 'no value' <<<"$out"; then
    echo "  [OK]   revision-only image logs the revision"
else
    echo "  [MISS] revision-only image produced: $out"
    fail=1
fi

# 4. Diagnostics must never abort the install. The caller runs under
#    `set -euo pipefail`, so an unguarded podman failure here would kill a
#    pull that actually succeeded.
cat >"$STUB_DIR/podman" <<'STUB'
#!/usr/bin/env bash
exit 125
STUB
chmod +x "$STUB_DIR/podman"
out=$(run_helper ghcr.io/x/img:absent)
if grep -q '__SURVIVED__' <<<"$out"; then
    echo "  [OK]   podman failure does not abort under set -e"
else
    echo "  [MISS] helper aborted the caller when podman failed: $out"
    fail=1
fi

if (( fail )); then
    echo "[ERR] pull-identity logging check failed." >&2
    exit 1
fi
echo "[OK] pull identity is recorded in the install log."
