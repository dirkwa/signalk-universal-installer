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

# --- 3. the one deliberate interpolation is still deliberate ----------------
# $Channel and $MachineName are MEANT to interpolate at generation time (they
# bake the install-time choice into the shim). Assert they are still spelled
# bare, so a well-meaning "fix" that escapes them gets caught.
if printf '%s\n' "$body" | grep -qE "else \{ '\\\$Channel' \}"; then
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
    if printf '%s\n' "$body" | grep -qE "^  '${verb}' \{"; then
        echo "[MISS] '${verb}' is intercepted by the shim - it must pass through to the VM"
        fail=1
    fi
done
if printf '%s\n' "$body" | grep -qE "^  'machine' \{"; then
    echo "  [OK]   VM-level control lives under 'machine', stop/start pass through"
else
    echo "[MISS] no 'machine' case - VM-level stop/start has no home"
    fail=1
fi

# --- 5. the Windows-only verb must be discoverable --------------------------
# `signalk help` renders from the in-VM CLI, which knows nothing about the
# verbs this shim adds. Without a help case, `machine` exists but appears in no
# help output on the only platform that has it.
if printf '%s\n' "$body" | grep -qE "^  'help' \{" \
    && printf '%s\n' "$body" | grep -q 'signalk machine stop|start'; then
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
