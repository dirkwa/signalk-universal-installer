#!/usr/bin/env bash
# The Windows installer writes ~/.local/.../signalk-run.ps1 from a DOUBLE-quoted
# PowerShell here-string (@"..."@). Two things go wrong in there and neither is
# visible in installer/windows/install.ps1's own syntax:
#
#   1. A `$` that should reach the generated file must be written `\$`. Left
#      bare it expands at INSTALL time, baking a value (or an empty string)
#      into the shim. This is the same hazard AGENTS.md records for the bash
#      heredoc in install-signalk-command.sh, in the opposite direction.
#
#   2. A backtick is PowerShell's escape character, so a comment mentioning a
#      command in `backticks` silently turns \`r into a carriage return and
#      \`h, \`n, \`t into their control characters -- splitting the comment and
#      leaving the tail as a stray command in the generated shim. The file's
#      convention is DOUBLED backticks (``signalk``) for exactly this reason.
#
# Both produce a file that still parses; only the generated text is wrong. So
# this checks the source text rather than running PowerShell, and stays useful
# on the Linux CI runner where pwsh may not be present.
set -euo pipefail

PS1=${PS1_INSTALLER:-installer/windows/install.ps1}
fail=0

if [[ ! -f "$PS1" ]]; then
    echo "[ERR] $PS1 not found" >&2
    exit 1
fi

# Extract the generated-shim here-string body: from `$ps1Body = @"` to the
# closing `"@` at column 0.
body=$(awk '/^\$ps1Body = @"/{f=1;next} f&&/^"@/{exit} f' "$PS1")

if [[ -z "$body" ]]; then
    echo "[MISS] could not find the \$ps1Body here-string in $PS1"
    exit 1
fi

# Searches below feed grep from a here-string, never `printf ... | grep -q`.
# That pipe races: grep -q exits at the first match and closes the pipe, printf
# takes SIGPIPE, and `set -o pipefail` turns that into a failed command - so a
# check reports MISS on a body that DOES match, intermittently, depending on
# whether printf finished writing first. Seen in CI on one of two identical
# jobs against the same commit. A here-string is a temp file, so no pipe exists
# to break.

# --- 1. single backticks before an escape-significant letter ----------------
# PowerShell eats `r `n `t `b `a `f `v `0 `e. Doubled backticks are the
# documented way to write a literal one, so only flag a SINGLE backtick. A
# backtick-dollar is the intended escape and is checked separately below.
# Collapse doubled backticks FIRST (they are the literal-backtick escape and are
# always fine), then look for what survives. Filtering whole lines that merely
# contain a `` would hide a real single backtick sitting next to a correct one.
if bad=$(printf '%s\n' "$body" | sed 's/``//g' | grep -nE '`[rntbafve0]'); then
    echo "[MISS] single backtick before an escape letter - it will become a control"
    echo "       character in the generated shim. Double it (\`\`like this\`\`):"
    printf '%s\n' "$bad" | sed 's/^/         /'
    fail=1
else
    echo "  [OK]   no stray backtick escapes in the generated shim"
fi

# --- 2. the shim's own variables must be escaped ----------------------------
# Every variable in the generated file is a RUNTIME variable and must be written
# `$name. Unescaped it expands at install time, usually to nothing - and the
# result still PARSES, so neither the pwsh gate nor a syntax check sees it.
#
# Deny by default rather than listing names to check: an allowlist only covers
# the variables someone remembered to add, so every new one ships unguarded.
# Three names are DELIBERATELY interpolated here (they bake install-time values
# into the shim) and are the only exemptions.
interpolated='MachineName|Channel|SignalkPorts'
if bad=$(printf '%s\n' "$body" \
    | grep -noE '(^|[^`])\$[A-Za-z_][A-Za-z_0-9]*' \
    | sed 's/:[^:]*\$/:$/' \
    | grep -vE ":\\\$(${interpolated})\$"); then
    echo "[MISS] unescaped \$variable in the shim - expands at install time, not run time"
    echo "       (write it as \`\$name; only \$${interpolated//|/, \$} interpolate on purpose)"
    printf '%s\n' "$bad" | sed 's/^/         line /'
    fail=1
else
    echo "  [OK]   shim runtime variables are backtick-escaped"
fi

# --- 2b. bash-style escaping does not work here -----------------------------
# This file also generates a bash heredoc elsewhere, where `\$` is the escape.
# Inside a PowerShell here-string `\$` is a literal backslash followed by a LIVE
# `$` - so it both expands at install time and leaves a stray backslash. The
# escape here is a backtick.
if bad=$(printf '%s\n' "$body" | grep -nE '\\\$[A-Za-z_]'); then
    echo "[MISS] bash-style \\\$ escape inside a PowerShell here-string - use a backtick:"
    printf '%s\n' "$bad" | sed 's/^/         /'
    fail=1
else
    echo "  [OK]   no bash-style \\\$ escapes in the shim"
fi

# --- 2c. the channel must reach bash lowercased -----------------------------
# PowerShell compares case-INSENSITIVELY: ValidateSet accepts `-Channel MASTER`
# and passes the original spelling through, and `-notmatch` accepts it too. But
# install.sh's `case` is case-SENSITIVE, so an uppercase spelling matches no
# branch and aborts the install inside the VM - over a value the operator was
# told was legal. Both the installer and the generated shim must fold the case
# before the value crosses into bash.
# shellcheck disable=SC2016  # grep pattern is literal PowerShell source text
if grep -qF 'Channel = $Channel.ToLowerInvariant()' "$PS1"; then
    echo "  [OK]   installer lowercases the channel before the VM handoff"
else
    echo "[MISS] installer does not lowercase \$Channel - '-Channel MASTER' would"
    echo "       pass ValidateSet and then match no branch of install.sh's case"
    fail=1
fi
if grep -q 'SIGNALK_CHANNEL\.ToLowerInvariant()' <<<"$body"; then
    echo "  [OK]   shim lowercases \$env:SIGNALK_CHANNEL before the VM handoff"
else
    echo "[MISS] shim does not lowercase \$env:SIGNALK_CHANNEL - an uppercase"
    echo "       override would pass -notmatch and then be rejected by bash"
    fail=1
fi

# --- 2d. both firewall layers must be programmed -----------------------------
# Windows filters traffic to WSL at two independent layers: the ordinary host
# firewall and the Hyper-V firewall between host and VM. Opening only the host
# layer leaves traffic dropped SILENTLY inside the Hyper-V layer - no log, no
# error, packets visible in Wireshark on Windows and absent in the VM. So the
# installer must call both cmdlets, and the uninstall must remove both.
# Assert the CALL SITES, not just that the cmdlet name appears somewhere: a
# defined-but-never-called helper would satisfy a bare name grep while leaving
# the Hyper-V layer shut.
fw_ok=1
# shellcheck disable=SC2016  # grep patterns are literal PowerShell source text
if ! grep -qE 'Add-HyperVFirewallRules -Ports \$Ports -Protocol TCP' "$PS1"; then
    echo "[MISS] the console ports are not opened at the Hyper-V layer"; fw_ok=0
fi
# shellcheck disable=SC2016  # grep patterns are literal PowerShell source text
if ! grep -qE 'Add-HyperVFirewallRules -Ports \$UdpPorts -Protocol UDP' "$PS1"; then
    echo "[MISS] the opt-in UDP ports are not opened at the Hyper-V layer"; fw_ok=0
fi
# shellcheck disable=SC2016  # grep patterns are literal PowerShell source text
if ! grep -qE 'Add-FirewallRules -Ports \$SignalkPorts -UdpPorts \$NmeaUdpPorts' "$PS1"; then
    echo "[MISS] Add-FirewallRules is not called with the UDP port list"; fw_ok=0
fi
if [[ $fw_ok -eq 1 ]]; then
    echo "  [OK]   both firewall layers are programmed, TCP and opt-in UDP"
else
    echo "       (traffic to the VM would be dropped silently at the unopened layer)"
    fail=1
fi

# The Hyper-V cmdlets exist only on Windows 11 22H2+. Calling a missing cmdlet
# throws CommandNotFoundException BEFORE -ErrorAction is consulted, so the
# uninstall path must guard on the command itself. Check that BOTH removals sit
# INSIDE that guard, not merely that the guard exists somewhere: awk prints the
# guarded block only, and the removals must be found within it.
guarded=$(printf '%s\n' "$body" | awk '
    /Get-Command Remove-NetFirewallHyperVRule/ { inblock = 1 }
    inblock { print }
    inblock && /^    \}$/ { inblock = 0 }
')
# The UDP case is a two-stage pipeline; assert BOTH stages. Matching only the
# Get- query passes even if the Remove- stage is deleted, which would leave the
# UDP rules behind on uninstall while the test stayed green.
if grep -qF 'Remove-NetFirewallHyperVRule -Name "SignalK-HyperV-TCP-' <<<"$guarded" \
    && grep -qF "Get-NetFirewallHyperVRule -Name 'SignalK-HyperV-UDP-" <<<"$guarded" \
    && grep -qE '^[[:space:]]*Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue[[:space:]]*$' <<<"$guarded"; then
    echo "  [OK]   both Hyper-V removals sit inside the capability guard"
else
    echo "[MISS] a Hyper-V firewall removal is outside the Get-Command guard - it"
    echo "       throws CommandNotFoundException on Windows 10 / pre-22H2"
    fail=1
fi

# --- 2e. the documented port list must match the installer -------------------
# install.ps1's $SignalkPorts is the single source of truth; docs/installation.md
# spells the same six ports out in prose twice. Prose cannot import a variable,
# so the only thing keeping them honest is this check.
# Fail closed: an unreadable input means the check did not run, which must not
# read as a pass. (The `-f "$PS1"` case is already fatal at the top of the file.)
DOCS=${DOCS_INSTALL:-docs/installation.md}
if [[ ! -f "$DOCS" ]]; then
    echo "[MISS] $DOCS not found - the documented port list could not be checked"
    fail=1
else
    # `if ! ports=$(...)` rather than a bare assignment: under `set -e` a failed
    # assignment exits the script immediately, so the empty-value branch below
    # would be dead code and a broken extraction would abort rather than report.
    # shellcheck disable=SC2016  # literal PowerShell source text
    if ! ports=$(grep -oE '^\$SignalkPorts = @\([0-9, ]+\)' "$PS1" \
        | grep -oE '[0-9]+' | sort -n | tr '\n' ' '); then
        ports=""
    fi
    if [[ -z "$ports" ]]; then
        echo "[MISS] could not read \$SignalkPorts from $PS1"
        fail=1
    else
        # Split the extracted list into an array once, then iterate it quoted,
        # rather than relying on an unquoted expansion to word-split each time.
        read -r -a port_list <<<"$ports"
        missing=""
        for p in "${port_list[@]}"; do
            grep -qF "$p" "$DOCS" || missing="$missing $p"
        done
        if [[ -n "$missing" ]]; then
            echo "[MISS] ports not mentioned in $DOCS:$missing"
            echo "       the installer opens them; the docs promise a different set"
            fail=1
        else
            echo "  [OK]   documented firewall ports match \$SignalkPorts"
        fi
    fi
fi

# --- 3. the one deliberate interpolation is still deliberate ----------------
# $Channel and $MachineName are MEANT to interpolate at generation time (they
# bake the install-time choice into the shim). Assert they are still spelled
# bare, so a well-meaning "fix" that escapes them gets caught.
if grep -qE "else \{ '\\\$Channel' \}" <<<"$body"; then
    echo "  [OK]   \$Channel still bakes the install-time channel into the shim"
else
    echo "[MISS] \$Channel is no longer interpolated into the shim - 'signalk update'"
    echo "       would lose the channel this box was installed from"
    fail=1
fi

# --- 4. stop/start must NOT be intercepted ---------------------------------
# They mean the same thing as on Linux now; the VM-level operation is
# `signalk machine`. An intercepting case here would silently re-diverge them.
for verb in stop start restart; do
    if grep -qE "^  '${verb}' \{" <<<"$body"; then
        echo "[MISS] '${verb}' is intercepted by the shim - it must pass through to the VM"
        fail=1
    fi
done
if grep -qE "^  'machine' \{" <<<"$body"; then
    echo "  [OK]   VM-level control lives under 'machine', stop/start pass through"
else
    echo "[MISS] no 'machine' case - VM-level stop/start has no home"
    fail=1
fi

# --- 5. the Windows-only verb must be discoverable --------------------------
# `signalk help` renders from the in-VM CLI, which knows nothing about the
# verbs this shim adds. Without a help case, `machine` exists but appears in no
# help output on the only platform that has it.
if grep -qE "^  'help' \{" <<<"$body" \
    && grep -q 'signalk machine stop|start' <<<"$body"; then
    echo "  [OK]   'signalk help' advertises the Windows-only machine verb"
else
    echo "[MISS] 'machine' is not mentioned in 'signalk help' - undiscoverable"
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo "[FAIL] windows shim"
    exit 1
fi
echo "[PASS] windows shim"
