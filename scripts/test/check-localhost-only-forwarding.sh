#!/usr/bin/env bash
# SIGNALK_LOCALHOST_ONLY must reach the Linux installer on every platform.
#
# The bind host is decided inside install.sh: PUBLISH_HOST defaults to 0.0.0.0
# and only SIGNALK_LOCALHOST_ONLY moves it to 127.0.0.1. On macOS and Windows
# that installer runs inside the podman machine, so a variable set on the HOST
# reaches nothing unless the wrapper forwards it across the VM boundary.
#
# This failed silently in both wrappers: the operator sets the flag, the run
# succeeds, and the updater and doctor consoles bind 0.0.0.0 anyway -- the one
# failure mode where the user believes they are more restricted than they are.
# A silent security regression has no symptom to notice, so it is asserted here.
#
# Run from repo root.

set -euo pipefail

fail=0
VAR=SIGNALK_LOCALHOST_ONLY

# Linux is the reference: it reads the variable directly, no forwarding needed.
echo "-- linux --"
if grep -qE "^case \"\\\$\{$VAR:-\}\"" installer/linux/install.sh; then
    echo "  [OK]   linux installer reads $VAR"
else
    echo "  [MISS] linux installer no longer reads $VAR"; fail=1
fi

# The wrappers must place the assignment AFTER the pipe. Before it, the variable
# is handed to curl -- which does not read it -- and bash never sees it. Same
# distinction the channel forwarding already carries a scar from.
echo "-- wrappers --"
for spec in "macos:installer/macos/install.sh" "windows:installer/windows/install.ps1"; do
    plat=${spec%%:*}
    f=${spec#*:}

    if ! grep -q "$VAR" "$f"; then
        echo "  [MISS] $plat wrapper never mentions $VAR (set on the host, dropped at the VM)"
        fail=1
        continue
    fi

    # Join backslash continuations so macOS's multi-line handoff and Windows's
    # deliberately single-line one compare alike.
    line=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f" \
        | grep -E "curl -fsSL .*\|.* bash" | head -1)
    if [[ -z "$line" ]]; then
        echo "  [MISS] $plat wrapper: no curl|bash handoff line found"; fail=1
        continue
    fi

    # The wrappers splice via a placeholder (${_SK_LOCAL_ENV}, __SKENV__), so
    # the literal name will not appear on the handoff line. Assert the splice
    # point is after the pipe, then that the variable feeds that placeholder.
    after=${line#*|}
    # shellcheck disable=SC2016  # literal placeholder text, not an expansion
    case $plat in
        macos) token='${_SK_LOCAL_ENV}' ;;
        windows) token='__SKENV__' ;;
        *) token='' ;;
    esac
    if [[ "$after" != *"$token"* ]]; then
        echo "  [MISS] $plat wrapper does not splice $token after the pipe"; fail=1
    else
        echo "  [OK]   $plat wrapper splices $token onto the bash side"
    fi
done

# macOS builds the fragment only when the operator set the variable, so an
# unset run must not export an empty assignment into the VM.
echo "-- conditional --"
if grep -qE 'if \[\[ -n "\$\{'"$VAR"':-\}" \]\]' installer/macos/install.sh; then
    echo "  [OK]   macos forwards $VAR only when it is set"
else
    echo "  [MISS] macos does not gate $VAR on being set"; fail=1
fi
# shellcheck disable=SC2016  # PowerShell's $env:, matched literally
if grep -qE 'if \(\$env:'"$VAR"'\)' installer/windows/install.ps1; then
    echo "  [OK]   windows forwards $VAR only when it is set"
else
    echo "  [MISS] windows does not gate $VAR on being set"; fail=1
fi

# The value is interpolated into a command a shell in the VM runs, so an
# apostrophe would close the generated quote and leave the rest as syntax.
echo "-- quoting --"
if grep -q "SIGNALK_LOCALHOST_ONLY//" installer/macos/install.sh; then
    echo "  [OK]   macos escapes the value before interpolating it"
else
    echo "  [MISS] macos interpolates $VAR unescaped"; fail=1
fi
if grep -qE "env:$VAR -replace" installer/windows/install.ps1; then
    echo "  [OK]   windows escapes the value before interpolating it"
else
    echo "  [MISS] windows interpolates $VAR unescaped"; fail=1
fi

# A fresh Windows box reboots to enable WSL2 and re-runs the installer. The
# resume command is rebuilt from $PSBoundParameters, which holds parameters
# only -- an env var set for the first process is gone by the second, so the
# resumed run would bind 0.0.0.0 after the operator asked for localhost.
echo "-- reboot resume --"
if grep -q 'resumeEnv' installer/windows/install.ps1; then
    # shellcheck disable=SC2016  # PowerShell's $resumeEnv, matched literally
    resume_lines=$(grep -c 'Write-Host "       \$resumeEnv' installer/windows/install.ps1)
    if [[ "$resume_lines" -eq 2 ]]; then
        echo "  [OK]   both resume commands carry $VAR across the reboot"
    else
        echo "  [MISS] only $resume_lines of 2 resume commands carry $VAR"; fail=1
    fi
else
    echo "  [MISS] the reboot resume command drops $VAR"; fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] localhost-only forwarding"
    exit 1
fi
echo "[PASS] localhost-only forwarding"
