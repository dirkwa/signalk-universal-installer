# SignalK Universal Installer (v2) - Windows (WSL2 + Podman Machine) bootstrap.
#
# We install the WSL2 platform (no user-facing distro), install the Podman CLI,
# and let `podman machine` create and own its own Linux VM - then run the
# regular Linux installer INSIDE that VM via `podman machine ssh`. This mirrors
# the macOS installer exactly. The container stack never runs on Windows
# directly; it runs in the Podman Machine VM.
#
# Why this model (and NOT `wsl --install -d Debian`): podman machine ships a
# Linux VM that already has systemd as PID 1 and rootless podman set up, so
# there is no OOBE username prompt, no /etc/wsl.conf systemd-enablement, and no
# default-user provisioning to manage. The earlier Debian-distro approach had
# to do all of that by hand and was fragile. This is also what the v1 installer
# did on Windows. The Linux installer is distro-portable (apt on Debian, dnf on
# Fedora, pre-baked packages on the podman-machine image), so it runs cleanly
# in the VM.
#
# Requirements:
#   - Windows 11 (or Server 2022) with WSL2.
#   - Hardware virtualization. In a guest VM, nested virtualization must be
#     enabled on the host (see Show-VirtualizationHelp / docs).
#
# Limitations:
#   - Native Windows (no WSL) is not supported (deferred per design doc).
#   - USB serial passthrough requires usbipd-win - link in docs/installation.md.

param(
    [string]$MachineName = 'signalk',
    [int]$MachineMemoryMB = 0,   # 0 = auto-size from host RAM (see below)
    [int]$MachineCpus = 2,
    [switch]$NoPause,            # skip the "press Enter to close" pause at the end
    [switch]$NoPrompt,           # don't ask for vessel identity / admin login
    [string]$InstallerVersion,
    # Release channel, mirroring installer/linux/install.sh. ValidateSet accepts
    # the same three spellings install.sh does and rejects anything else with a
    # native PowerShell error, so the VM never sees a value bash would refuse.
    [ValidateSet('release', 'master', 'dev')]
    [string]$Channel = 'release',
    # UDP ports carrying NMEA data INTO the stack (a Yacht Devices / Actisense
    # gateway streaming to the boat PC, typically 2000 or 10110). Opt-in: the
    # right ports are a property of the boat's gateway, not something the
    # installer can detect, and opening ports nobody uses is not free.
    #   .\install.ps1 -NmeaUdpPorts 2000,10110
    [int[]]$NmeaUdpPorts = @(),
    [string]$InstallerBaseUrl = 'https://dirkwa.github.io/signalk-universal-installer'
)

if (-not $InstallerVersion) { $InstallerVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { '0.0.0-scaffold' } }

# Resolve the channel to a base URL, matching installer/linux/install.sh:51-61:
# the site publishes the latest RELEASE at its root and master under /dev, and
# an explicit base URL beats the channel (the escape hatch for local checkouts,
# mirrors and CI).
#
# $InstallerBaseUrl has a DEFAULT, so it is never empty and `if (-not $x)`
# cannot tell "caller passed one" from "fell back to the default".
# $PSBoundParameters.ContainsKey is the test that can - it is the PowerShell
# analogue of bash's ${VAR:-default} precedence, and without it -Channel would
# silently lose to the default base URL on every run.
#
# Lowercase the channel before it goes anywhere. PowerShell's ValidateSet is
# CASE-INSENSITIVE and passes the caller's original spelling through, so
# `-Channel MASTER` validates here and then matches no branch of install.sh's
# case statement, aborting the install inside the VM with a message about a
# value the operator believed was legal.
$SkSiteRoot = 'https://dirkwa.github.io/signalk-universal-installer'
$Channel = $Channel.ToLowerInvariant()
$SkExplicitBase = $PSBoundParameters.ContainsKey('InstallerBaseUrl')
if (-not $SkExplicitBase) {
    $InstallerBaseUrl = if ($Channel -eq 'release') { $SkSiteRoot } else { "$SkSiteRoot/dev" }
}

$ErrorActionPreference = 'Stop'

# The TCP ports the stack may serve on, in ONE place: 80/443 standard web,
# 3000/3443 the declined-standard fallback, 3003 updater, 3004 doctor. Used both
# to open the firewall at install time and (interpolated into the generated
# signalk-run.ps1) to remove those rules on uninstall, so the two never drift.
$SignalkPorts = @(80, 443, 3000, 3443, 3003, 3004)

# NOTE on output encoding: wsl.exe emits UTF-16LE, so a captured `& wsl ...`
# comes back with a NUL between every character - Get-VersionFrom strips those
# NULs to parse the version. We deliberately do NOT set
# [Console]::OutputEncoding globally: that would make PowerShell decode every
# child process as UTF-16, which mangles the UTF-8 streaming output of
# `podman` (and its progress bars) into garbage. So we only capture+clean wsl's
# output, and let podman write straight to the console.

function Info($msg)    { Write-Host "[i] $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Warning $msg }
function Section($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor White }

# Hold the window open before the script exits, so the user can read the result
# - `iex` runs us in their session, and `exit` would otherwise close the window
# instantly. Only pause when there's an interactive user AND a console to read a
# key from; skip it under -NoPause, when stdin is redirected/piped, or in a
# non-interactive host (CI, scheduled task) where it would hang forever.
function Wait-BeforeExit {
    if ($NoPause) { return }
    if (-not [Environment]::UserInteractive) { return }
    if ([Console]::IsInputRedirected) { return }
    try {
        Write-Host ""
        Write-Host "Press any key to close..." -ForegroundColor DarkGray
        [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        # No usable console (e.g. ISE / redirected host) - don't block.
        $null = $_
    }
}

function Die($msg)     { Write-Error $msg; Wait-BeforeExit; exit 1 }

# Run a native command best-effort: swallow stdout+stderr and NEVER throw, even
# under $ErrorActionPreference='Stop' (where a native command writing to stderr
# can surface as a terminating NativeCommandError). Returns the exit code. Use
# for flaky Store-backed calls like `wsl --install`/`wsl --update`, whose 403
# from the msstore backend must not abort the installer.
function Invoke-BestEffort {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments)
    try {
        & $Exe @Arguments *>$null
        return $LASTEXITCODE
    } catch {
        # native stderr surfaced as an error record under Stop, or the exe
        # wasn't found - either way report failure (don't trust a stale
        # $LASTEXITCODE from an earlier command).
        return 1
    }
}

# Run a native command with its output STREAMING to the console (so progress
# bars show), but without $ErrorActionPreference='Stop' turning the command's
# stderr writes into a terminating NativeCommandError. `podman machine init`
# writes normal progress ("Getting image source signatures", "Copying blob") to
# stderr, which under Stop would abort the script mid-pull. We redirect stderr to
# stdout and force Continue for the call, then return the real exit code so the
# caller decides success/failure.
function Invoke-Streaming {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments)
    # Stream the command's output (stdout+stderr) to the console as PLAIN TEXT,
    # and return ONLY its exit code.
    #
    # Pipeline, stage by stage:
    #   2>&1                      merge stderr into the stream so we see progress
    #                             (podman writes "Getting image source signatures"
    #                             etc. to stderr).
    #   | ForEach-Object {"$_"}   stringify each item. Under Continue, native
    #                             stderr arrives as ErrorRecords, which the host
    #                             would otherwise render as scary red
    #                             "NativeCommandError" blocks - alarming to a user
    #                             even though it's just progress. Stringifying
    #                             renders them as ordinary lines.
    #   | Out-Host                display the lines and emit NOTHING to the
    #                             pipeline, so the function returns only the exit
    #                             code (a bare call would leak podman's text into
    #                             the return, making `$rc -ne 0` wrongly true).
    # PowerShell does not connect stdin to the pipeline, so piping the OUTPUT does
    # not affect podman's stdin/tty - `machine init`'s `wsl --import` runs fine.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
    } finally {
        $ErrorActionPreference = $prev
    }
    return $LASTEXITCODE
}

# Run a bash script inside the podman machine, immune to BOTH hazards on the
# PowerShell -> podman -> WSL path:
#   1. Quote mangling - passing a script as `bash -lc '<script>'` strips its
#      quotes (a `printf '...'` lost its args and wrote an empty file; '('
#      gave "syntax error near unexpected token").
#   2. CRLF injection - Windows PowerShell re-inserts CRLF when piping a string
#      to a native process's stdin, so stripping CR from the string is futile;
#      the `\r` reaches bash and breaks the last token ("$'bash\r': not found").
# Solution: base64-encode the script (one line; only [A-Za-z0-9+/=], no shell
# metacharacters) and pipe THAT via stdin to `base64 -d | bash` in the VM.
# `base64 -d` ignores the trailing CR PowerShell adds, and the decoded bytes are
# the exact original script. The decode command is passed as a single argv
# element via array splat, which podman forwards intact (only inline quotes in a
# typed command get mangled).
function Invoke-VmScript {
    param(
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][string]$Script,
        [string]$AsUser  # empty => default user
    )
    $lf = $Script -replace "`r", ''
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($lf))
    # `podman machine ssh` ignores the trailing argv command on Windows and just
    # runs a login shell reading stdin. So we pipe a SINGLE self-decoding line:
    #   echo <b64> | base64 -d | bash #
    # - base64 is one token, no shell metacharacters -> no quote mangling.
    # - PowerShell appends CRLF to the piped line; the trailing ` #` turns the
    #   stray \r into a comment so it can't corrupt the final `bash` token.
    # - It runs as a real piped `bash`, so the script's exit code propagates.
    $line = "echo $b64 | base64 -d | bash #"
    $sshArgs = @('machine', 'ssh')
    if ($AsUser) { $sshArgs += @('--username', $AsUser) }
    $sshArgs += $Machine
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $line | & podman @sshArgs 2>&1 | ForEach-Object { "$_" } | Out-Host
    } finally {
        $ErrorActionPreference = $prev
    }
    return $LASTEXITCODE
}

# Like Invoke-VmScript but CAPTURES and returns the script's stdout (trimmed),
# for probes whose output we need to read. Same base64-over-stdin transport.
function Get-VmOutput {
    param(
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][string]$Script,
        [string]$AsUser
    )
    $lf = $Script -replace "`r", ''
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($lf))
    $line = "echo $b64 | base64 -d | bash #"
    $sshArgs = @('machine', 'ssh')
    if ($AsUser) { $sshArgs += @('--username', $AsUser) }
    $sshArgs += $Machine
    $out = $line | & podman @sshArgs 2>$null
    return (($out | Out-String) -replace "`0", '').Trim()
}

# True when this run can prompt the user (interactive console, stdin not piped,
# and -NoPrompt not set). Mirrors the Linux installer only prompting on a TTY.
function Test-CanPrompt {
    if ($NoPrompt) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    return $true
}

# Thoroughly remove a podman machine, including the orphaned WSL distro podman
# leaves behind when `machine init` fails partway. After a failed init, podman's
# own `machine ls`/`rm` no longer see the machine, but the half-registered WSL
# distro persists and makes the NEXT `machine init` fail instantly (containers/
# podman #27036, #15154). So we also `wsl --unregister` the distro and clear the
# stale machine config dirs. All best-effort - never throws, never aborts.
function Remove-PodmanMachine {
    param([Parameter(Mandatory)][string]$Name)
    Invoke-BestEffort podman @('machine', 'rm', '--force', $Name) | Out-Null
    # podman names its WSL distro after the machine; the default machine is
    # 'podman-machine-default'. Unregister both candidate names.
    foreach ($distro in @($Name, 'podman-machine-default')) {
        Invoke-BestEffort wsl @('--unregister', $distro) | Out-Null
    }
    foreach ($dir in @(
        (Join-Path $env:USERPROFILE '.local\share\containers\podman\machine'),
        (Join-Path $env:USERPROFILE '.config\containers\podman\machine'))) {
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

# True when a WSL distro matching a podman machine exists even though podman's
# own machine list doesn't show it - the orphaned-distro state that deadlocks
# `machine init`. We check `wsl --list` (NUL-stripped) for the candidate names.
function Test-OrphanedMachineDistro {
    param([Parameter(Mandatory)][string]$Name)
    $list = (& wsl --list --quiet 2>$null) -replace "`0", ''
    $names = $list -split "\r?\n" | ForEach-Object { $_.Trim() }
    return (($names -contains $Name) -or ($names -contains 'podman-machine-default'))
}

# The two Windows optional features WSL2 (and podman machine) require.
$WslFeatures = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')

# True when a reboot is required before WSL2's VM platform is live.
#
# The reliable signal is NOT Get-WindowsOptionalFeature's State: enabling a
# feature is a Component Based Servicing (CBS) transaction that flips State to
# 'Enabled' as soon as it's staged - BEFORE the reboot that actually activates
# the VM platform. So State='Enabled' + `wsl --version` working can both be true
# on a fresh box while a reboot is still pending; podman then races ahead and
# fails with HCS_E_SERVICE_NOT_AVAILABLE. The authoritative, locale-independent
# flag is the CBS RebootPending key that DISM sets (mirrors dism exit 3010 /
# Enable-WindowsOptionalFeature's RestartNeeded). We also honour an explicit
# RestartNeeded passed in from the enable call, and a lingering EnablePending.
function Test-RebootPending {
    param([bool]$RestartNeeded = $false)
    if ($RestartNeeded) { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    foreach ($f in $WslFeatures) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'EnablePending') { return $true }
    }
    return $false
}

# Functional probe: is WSL actually usable right now (vs. installed-but-pending)?
# Gate on the exit code, not the (localized) text. A clean exit, with no pending
# reboot, is the real "WSL platform is live" confirmation before handing to podman.
function Test-WslReady {
    & wsl.exe --status > $null 2>&1
    return ($LASTEXITCODE -eq 0)
}

# Print reboot-then-re-run guidance and exit cleanly. This is a NORMAL part of
# enabling WSL2 (Windows requires a reboot to activate the feature), not a
# failure. The installer is idempotent, so re-running after the reboot resumes
# from here.
function Stop-ForReboot {
    Section "Reboot required (this is normal - not an error)"
    Ok "WSL2 has been enabled. Windows needs one reboot to activate it."
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "    1. Reboot Windows."
    Write-Host "    2. Open PowerShell as Administrator again."
    Write-Host "    3. Re-run the same command - it picks up where it left off:"
    # The resume command must carry the parameters THIS run was given. A plain
    # `iwr ... | iex` cannot: iex has nowhere to put arguments, so a
    # `-Channel master` install would resume on the release channel and bake
    # `release` into the shim - silently installing something other than what
    # was asked for, at the one moment the operator is least likely to notice.
    # The same applies to every other parameter: -MachineName nav would resume
    # against the default 'signalk' machine.
    #
    # Read $script:PSBoundParameters rather than listing names here, so a
    # parameter added later is carried without anyone remembering to update
    # this. Switches ($true) are emitted bare; everything else is single-quoted
    # with embedded quotes doubled, so a value containing a space, an ampersand
    # or an apostrophe survives as ONE argument instead of changing the parse.
    $resumeArgs = @()
    foreach ($kv in $script:PSBoundParameters.GetEnumerator() | Sort-Object Key) {
        $v = $kv.Value
        if ($v -is [switch]) {
            if ($v.IsPresent) { $resumeArgs += "-$($kv.Key)" }
        } elseif ($v -is [array]) {
            # An array MUST be emitted element by element. "$v" stringifies it
            # by joining with $OFS (a space by default) INSIDE the quotes, so
            # -NmeaUdpPorts 2000,10110 came out as '200010110' - one nonsense
            # port that binds without error and opens the wrong thing. An empty
            # array contributes no argument at all.
            if ($v.Count -gt 0) {
                $items = ($v | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
                $resumeArgs += "-$($kv.Key) $items"
            }
        } else {
            $resumeArgs += "-$($kv.Key) '$($v -replace "'", "''")'"
        }
    }
    # With nothing to carry the one-liner is still the friendlier form, so only
    # fall back to download-then-invoke when there is something to preserve.
    if ($resumeArgs.Count -gt 0) {
        # A unique filename: -OutFile would silently overwrite an install.ps1
        # already sitting in the operator's working directory.
        $resumeFile = "signalk-install-$(Get-Random).ps1"
        # Escape the URL the same way the arguments above are escaped: it is
        # single-quoted here too, and an apostrophe in a mirror URL would
        # otherwise close the string and break the printed command.
        $resumeUrl = "$InstallerBaseUrl/installer/windows/install.ps1" -replace "'", "''"
        Write-Host "       iwr -useb '$resumeUrl' -OutFile $resumeFile"
        Write-Host "       .\$resumeFile $($resumeArgs -join ' ')"
    } else {
        Write-Host "       iwr -useb $InstallerBaseUrl/installer/windows/install.ps1 | iex"
    }
    Write-Host ""
    Write-Host "  (If WSL still fails after the reboot, confirm hardware virtualization"
    Write-Host "   - VT-x / AMD-V - is enabled in your BIOS/UEFI.)"
    Wait-BeforeExit
    exit 0
}

# --- Headless / always-on support --------------------------------------------
# A boat PC powers on with NO ONE logged in and the stack must be reachable from
# any device on the LAN. Three pieces make that work (all verified live):
#   1. mirrored networking - the VM takes the Windows host's LAN IP, so a browser
#      on any device reaches http://<host-ip> directly (NAT mode hides the VM
#      behind a 172.x address with no inbound path).
#   2. an ~/.ssh/config localhost->IPv4 rule - podman invokes `ssh user@localhost`
#      and Windows resolves localhost to ::1 first; the VM's sshd forward is
#      IPv4-only, so each `podman machine ssh` ate a ~21s IPv6 timeout. Forcing
#      localhost to AddressFamily inet drops it to <1s.
#   3. a boot Scheduled Task (run whether logged on or not) that starts the
#      machine at Windows startup with no sign-in; systemd inside then starts
#      the containers.

# Write networkingMode=mirrored into %USERPROFILE%\.wslconfig. MERGE, never
# clobber: the file is machine-wide (all WSL distros) and the user may have
# their own keys. If a networkingMode is already set we leave it alone (respect
# an explicit choice) and just report it.
function Set-WslConfigMirrored {
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $text = if (Test-Path $path) { Get-Content $path -Raw } else { '' }
    if ($text -match '(?im)^\s*networkingMode\s*=') {
        $current = ([regex]::Match($text, '(?im)^\s*networkingMode\s*=\s*(\S+)')).Groups[1].Value
        if ($current -ieq 'mirrored') {
            Ok ".wslconfig already sets networkingMode=mirrored"
        } else {
            Warn ".wslconfig sets networkingMode=$current (not mirrored). LAN access from other devices may not work; set networkingMode=mirrored to enable it."
        }
        return
    }
    # No networkingMode yet. Append it under a [wsl2] section (add the header
    # only if absent), preserving any existing content.
    if ($text -match '(?im)^\s*\[wsl2\]\s*$') {
        # Insert the key right after the [wsl2] header line.
        $new = [regex]::Replace($text, '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`nnetworkingMode=mirrored", 1)
    } else {
        if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
        $new = $text + "[wsl2]`r`nnetworkingMode=mirrored`r`n"
    }
    [System.IO.File]::WriteAllText($path, $new, [System.Text.Encoding]::ASCII)
    Ok "Enabled mirrored networking in $path (VM shares the host's LAN IP)"
}

# Add a per-user ~/.ssh/config rule forcing `localhost` to IPv4, so podman's
# `ssh user@localhost` doesn't burn ~21s on an IPv6 (::1) connect timeout.
# Scoped to the user, needs no admin, and doesn't touch the hosts file. MERGE:
# append the block only if a `Host localhost` stanza isn't already present.
function Set-SshLocalhostIPv4 {
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    $cfg = Join-Path $sshDir 'config'
    $text = if (Test-Path $cfg) { Get-Content $cfg -Raw } else { '' }
    if ($text -match '(?im)^\s*Host\s+localhost\s*$') {
        Ok "~/.ssh/config already has a 'Host localhost' stanza (leaving it as-is)"
        return
    }
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    $block = "Host localhost`r`n    AddressFamily inet`r`n"
    [System.IO.File]::WriteAllText($cfg, ($text + $block), [System.Text.Encoding]::ASCII)
    Ok "Added a localhost->IPv4 rule to $cfg (keeps 'podman machine ssh' fast under mirrored networking)"
}

# Register a boot Scheduled Task that starts the machine with NO user logged in.
# It must run as the user (WSL2 is per-user) "whether logged on or not", which
# needs the user's password stored with the task. Prompt for it when we can;
# skip cleanly (manual start / re-run) when we can't, since this is an
# enhancement, not a hard requirement - the stack is already up at this point.
function Register-MachineAutostart {
    param(
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][string]$CmdDir
    )
    $taskName = "SignalK Podman Machine ($Machine)"
    try {
        # Hidden launcher so nothing flashes at boot; output discarded.
        $launcher = Join-Path $CmdDir 'signalk-autostart.cmd'
        $launcherBody = @"
@echo off
rem Start the SignalK Podman machine at boot. Installed by signalk-universal-installer.
powershell -NoProfile -WindowStyle Hidden -Command "podman machine start $Machine" >nul 2>&1
"@
        New-Item -ItemType Directory -Force -Path $CmdDir | Out-Null
        [System.IO.File]::WriteAllText($launcher, ($launcherBody -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)

        $action  = New-ScheduledTaskAction -Execute $launcher
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

        # Boot task with an S4U principal = "run whether logged on or not" with
        # NO stored password (the Task Scheduler GUI's "Do not store password").
        # S4U (Service-for-User) starts the task in the account's context via a
        # local logon that needs no password - so it works even for a Windows
        # account LINKED to a Microsoft account, where storing a password fails
        # with 0x8007052E. The action runs as the installing user, so the
        # per-user WSL2 podman machine it starts is the right one and `signalk`
        # keeps working in that user's normal session. RunLevel Highest because
        # `podman machine start` drives the WSL VM. Verified live: an S4U task
        # starts the machine at boot with nobody signed in. No password prompt,
        # no service account, no auto-login needed.
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $set -Principal $principal -Force -ErrorAction Stop | Out-Null
        Ok "Registered boot task '$taskName' - the stack starts at boot with no sign-in (no password stored)."
    } catch {
        Warn "Could not register the boot auto-start task ($($_.Exception.Message)); after a reboot, run 'podman machine start $Machine' (or 'signalk health') to bring the stack back."
    }
}

# Open the Windows firewall for the stack's ports so other LAN devices can reach
# it. Under mirrored networking inbound LAN traffic hits the Windows host's
# firewall first, and the default inbound policy BLOCKS it - so without this the
# consoles are unreachable from a phone/laptop (the operator otherwise has to
# disable the firewall entirely). Needs admin (the installer already runs
# elevated). Best-effort - a failure on one port warns but doesn't abort.
#
# Idempotent via a stable per-port -Name ("SignalK-<port>"): skip ports whose
# rule already exists, so repeated installer runs converge to one rule per port
# instead of accumulating duplicates (DisplayName alone is not unique).
# Scoped to LocalSubnet so the rule only admits same-LAN clients, not arbitrary
# remote hosts. Profile stays Any (a boat's WiFi may be classified Public, and
# we still want LAN access there); LocalSubnet is what bounds the exposure.
# The WSL VMCreatorId. Every WSL2 distro - including the podman machine - sits
# behind this one Hyper-V firewall profile; the GUID is Microsoft's, fixed, and
# the only way to name that profile.
$WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

# Windows filters traffic to WSL at TWO independent layers, and opening one
# does nothing for the other:
#
#   1. the ordinary host firewall (New-NetFirewallRule), which is what most
#      people mean by "the Windows firewall"; and
#   2. the HYPER-V firewall (New-NetFirewallHyperVRule), which sits between the
#      host and the VM.
#
# Traffic must pass BOTH. The Hyper-V layer drops silently: the packet is
# visible in Wireshark on Windows and simply absent inside the VM, with nothing
# logged. That is the difference between "it works" and an afternoon lost.
#
# It is easy to miss because Windows preinstalls `WslCore ... mDNS Default
# Allow Rule` for UDP 5353, so mDNS works out of the box while a custom port on
# the same multicast group receives nothing - which reads as "multicast is
# broken in WSL" when it is really "that port was never allowed".
function Add-HyperVFirewallRules {
    param(
        [Parameter(Mandatory)][int[]]$Ports,
        [Parameter(Mandatory)][ValidateSet('TCP', 'UDP')][string]$Protocol
    )
    # Windows 11 22H2 and later only. On older builds there is no Hyper-V
    # firewall to program - and nothing filtering there either - so absence is
    # not a failure worth warning about.
    if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        return $false
    }
    $ok = $true
    foreach ($p in $Ports) {
        # NOTE -LocalPorts (plural) here; the host cmdlet below takes
        # -LocalPort (singular). Mixing them up is a silent parameter-binding
        # error, not a typo the parser catches.
        $ruleName = "SignalK-HyperV-$Protocol-$p"
        try {
            if (Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue) { continue }
            New-NetFirewallHyperVRule -Name $ruleName -DisplayName "SignalK $Protocol $p (WSL)" `
                -VMCreatorId $WslVmCreatorId -Direction Inbound -Action Allow `
                -Protocol $Protocol -LocalPorts "$p" -ErrorAction Stop | Out-Null
        } catch {
            $ok = $false
            Warn "Could not add a Hyper-V firewall rule for $Protocol/$p ($($_.Exception.Message)); traffic to the VM on that port may be dropped silently."
        }
    }
    return $ok
}

function Add-FirewallRules {
    param(
        [Parameter(Mandatory)][int[]]$Ports,
        [int[]]$UdpPorts = @()
    )
    $opened = @()
    foreach ($p in $Ports) {
        $ruleName = "SignalK-$p"
        try {
            if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
                $opened += $p   # already present (prior run) - count as in place
                continue
            }
            New-NetFirewallRule -Name $ruleName -DisplayName "SignalK $p" -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $p -Profile Any -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
            $opened += $p
        } catch {
            Warn "Could not add a firewall allow rule for port $p ($($_.Exception.Message)); open it manually if other devices can't reach the stack."
        }
    }
    if ($opened.Count -gt 0) {
        Ok "Firewall allows LAN access on ports: $($opened -join ', ')"
    } else {
        Warn "No firewall rules could be added; other devices may not reach the stack until you open the ports."
    }

    # Same ports again at the Hyper-V layer. Without this the consoles are
    # unreachable from the LAN on any box whose Hyper-V default is Block.
    if (Add-HyperVFirewallRules -Ports $Ports -Protocol TCP) {
        Ok "Hyper-V firewall allows traffic into the machine on those ports"
    }

    # UDP is opt-in because the port depends on the boat's gateway. NMEA over
    # UDP is the case the two-layer trap bites hardest: broadcast and multicast
    # both work under mirrored networking, so the feed reaches Windows and then
    # vanishes at the Hyper-V layer with no error anywhere.
    if ($UdpPorts.Count -gt 0) {
        $udpOk = @()
        foreach ($p in $UdpPorts) {
            $ruleName = "SignalK-UDP-$p"
            try {
                if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name $ruleName -DisplayName "SignalK UDP $p" -Direction Inbound -Action Allow `
                        -Protocol UDP -LocalPort $p -Profile Any -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
                }
                $udpOk += $p
            } catch {
                Warn "Could not add a UDP firewall rule for port $p ($($_.Exception.Message))."
            }
        }
        Add-HyperVFirewallRules -Ports $UdpPorts -Protocol UDP | Out-Null
        if ($udpOk.Count -gt 0) {
            Ok "Firewall allows inbound NMEA UDP on: $($udpOk -join ', ')"
        }
    }
}

# The Windows host's LAN IPv4 - the address OTHER devices use to reach the
# stack, since under mirrored networking the VM shares it.
#
# Ask the routing table which source address Windows itself would use to reach
# the internet. Sorting Get-NetIPAddress by InterfaceMetric does not work: on a
# real box that property comes back EMPTY for every address (observed on
# Windows 11 26200), so the sort is a no-op and the first row wins by accident.
# On a host with two addresses on one adapter that printed 172.31.3.54 - a
# second, unroutable address on the same NIC - while the reachable LAN address
# 192.168.0.54 sorted last. The installer then told the operator to open an
# address no device on the network can reach.
#
# Find-NetRoute answers the question directly and needs no metric heuristics.
# Fall back to the old scan only if it is unavailable, and prefer an address
# whose adapter carries the default route.
#
# We deliberately do NOT exclude 172.x by range: 172.16.0.0/12 is a valid
# private LAN, and picking by route makes range guessing unnecessary.
function Get-HostLanIp {
    try {
        # 8.8.8.8 is a routing probe, not a connection - nothing is sent.
        $src = Find-NetRoute -RemoteIPAddress 8.8.8.8 -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($src -and $src -notlike '127.*' -and $src -notlike '169.254.*') { return $src }
    } catch { }
    try {
        # Fallback: the adapters carrying a default route, best route first.
        $ifIdx = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -ExpandProperty ifIndex -Unique
        foreach ($i in $ifIdx) {
            $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $i -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1 -ExpandProperty IPAddress
            if ($ip) { return $ip }
        }
    } catch { }
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1 -ExpandProperty IPAddress
        return $ip
    } catch { return $null }
}

# Best-effort identification of the host hypervisor when running as a guest VM,
# so the virtualization help can name the right per-host toggle.
function Get-HostHypervisor {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $sig = "$($cs.Manufacturer) $($cs.Model)"
    switch -Regex ($sig) {
        'VMware'               { return 'VMware' }
        'VirtualBox|innotek'   { return 'VirtualBox' }
        'QEMU|KVM|Standard PC' { return 'KVM/QEMU/Proxmox' }
        'Microsoft.*Virtual'   { return 'Hyper-V' }
        default                { return '' }
    }
}

# True when this machine can host a WSL2/Hyper-V VM. Two ways to qualify:
#   - a hypervisor is already running (HypervisorPresent), OR
#   - the CPU is virtualization-capable AND the VM Monitor / SLAT / firmware
#     flags are all set (i.e. enabled in BIOS/UEFI, no hypervisor up yet).
# We only HARD-FAIL the installer on a confident negative (neither holds), so a
# VBS-induced HypervisorPresent=True false-positive can't wrongly block a box;
# the post-init Show-VirtualizationHelp backstops the rest.
function Test-VirtualizationCapable {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.HypervisorPresent) { return $true }
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    if ($cpu -and $cpu.VirtualizationFirmwareEnabled `
            -and $cpu.SecondLevelAddressTranslationExtensions `
            -and $cpu.VMMonitorModeExtensions) {
        return $true
    }
    return $false
}

# Print actionable guidance when WSL2/podman-machine can't create a VM because
# virtualization isn't available - the dominant cause on a guest VM is nested
# virtualization not being exposed by the host. $AfterFailure tailors the lead
# line (pre-flight stop vs. post-podman-error).
function Show-VirtualizationHelp {
    param([switch]$AfterFailure)
    $hv = Get-HostHypervisor
    Write-Host ""
    if ($AfterFailure) {
        Write-Host "  If the error above mentions virtualization / HCS_E_HYPERV_NOT_INSTALLED /"
        Write-Host "  0x80370102, the Windows hypervisor can't create the VM. Fixes:"
    } else {
        Write-Host "  Virtualization isn't available on this machine, so WSL2 can't create the"
        Write-Host "  Linux VM the stack runs in. Enable it, then re-run this installer:"
    }
    Write-Host ""
    if ($hv) { Write-Host "  Detected host hypervisor: $hv (this looks like a guest VM)." }
    Write-Host "  If this is a VIRTUAL MACHINE, enable nested virtualization on the HOST"
    Write-Host "  with the VM FULLY POWERED OFF (a reboot from inside the guest is not enough):"
    Write-Host ""
    Write-Host "    Hyper-V host : Stop-VM <VM>; Set-VMProcessor -VMName <VM> -ExposeVirtualizationExtensions `$true"
    Write-Host "                   Set-VMMemory -VMName <VM> -DynamicMemoryEnabled `$false; Start-VM <VM>"
    Write-Host "    VMware       : VM Settings > Processors > 'Virtualize Intel VT-x/EPT or AMD-V/RVI'"
    Write-Host "    VirtualBox   : not supported for WSL2 (Hyper-V can't nest in VirtualBox)"
    Write-Host "    Proxmox/KVM  : VM CPU type 'host' + nested KVM enabled on the host"
    Write-Host ""
    Write-Host "  On BARE METAL, enable VT-x / AMD-V (SVM) in the BIOS/UEFI."
    Write-Host "  Confirm inside Windows (want True): (Get-CimInstance Win32_ComputerSystem).HypervisorPresent"
    Write-Host "  On Windows 11 25H2 (build 26200+), if HypervisorPresent is True but it still"
    Write-Host "  fails, try: bcdedit /set hypervisorlaunchtype Auto  (then reboot)."
    Write-Host "  More: https://aka.ms/enablevirtualization"
}

# Parse a version from CLI output, stripping stray UTF-16 NULs.
function Get-VersionFrom([string[]]$raw) {
    if (-not $raw) { return $null }
    $text = ($raw | Out-String) -replace "`0", ''
    $m = [regex]::Match($text, '(\d+)\.(\d+)\.(\d+)')
    if ($m.Success) { return [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) }
    return $null
}

# Guidance shown when `podman machine` init/start fails. We do NOT try to
# auto-classify the failure: Win32_ComputerSystem.HypervisorPresent can read
# True (e.g. Windows' own VBS hypervisor) while nested virtualization for
# creating a child VM still isn't available, so it gives false negatives. And
# capturing podman's output to grep it would break its live download progress
# bar. Instead we stream podman's real error to the console (the user sees the
# exact code, e.g. HCS_E_HYPERV_NOT_INSTALLED) and always print this guidance on
# failure - it's advice, not a destructive action, and on a guest VM a
# virtualization problem is by far the most common cause.

Section "SignalK Universal Installer v$InstallerVersion (Windows / Podman Machine)"

# 1. Admin + Windows 11 check
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "This script must run as Administrator. Right-click PowerShell and 'Run as administrator'."
}
Ok "Running as Administrator"

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 22000) {
    Die "Windows 11 (build 22000+) is required (current build $build)."
}
Ok "Windows 11 build $build"

# 2. WSL2 platform (no distribution). podman machine provides its own VM, so we
# only need the WSL2 platform installed, not a user-facing distro.
#
# Crucial ordering: we ENABLE the WSL features ourselves (so we get the
# authoritative RestartNeeded bit), then decide reboot from CBS signals, then
# only hand off to podman once WSL is functionally ready. This avoids the trap
# where Get-WindowsOptionalFeature reports State='Enabled' and `wsl --version`
# works on a fresh box, yet a reboot is still pending - in which case podman's
# bundled provider runs its own `wsl --install` and fails creating the VM with
# HCS_E_SERVICE_NOT_AVAILABLE.
Section "WSL2 platform"

# 1) Enable the required Windows features. Enable-WindowsOptionalFeature is
#    idempotent (no-op if already active) and is the ONLY call that returns the
#    authoritative RestartNeeded flag (Get-WindowsOptionalFeature does not).
$restartNeeded = $false
try {
    # Enable-WindowsOptionalFeature -NoRestart emits a localized warning
    # (e.g. German "Der Neustart wird unterdrueckt...", English "The restart
    # was suppressed...") whenever the change needs a reboot. That warning IS
    # the reboot signal, but on its own it reads to the user as a scary error.
    # Capture RestartNeeded and translate it into our own plain line below.
    $r = Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName $WslFeatures -ErrorAction Stop
    if ($r -and $r.RestartNeeded) { $restartNeeded = $true }
} catch {
    Warn "Could not enable WSL features via DISM ($($_.Exception.Message)); falling back to 'wsl --install'."
}

# 2) Reboot gate FIRST, right after the enable. On a fresh box the feature
#    enable needs a reboot to activate the VM platform; the Store-backed
#    `wsl --install`/`--update` calls below can't succeed (and `wsl --status`
#    can hang) until that reboot happens. So if a reboot is pending we stop
#    here - BEFORE those calls and before podman - and tell the user clearly.
#    Doing the wsl Store calls first made the installer sit dead-silent and
#    look frozen when the real situation was "you need to reboot." Re-running
#    after the reboot resumes from here, where no reboot is pending, and falls
#    through to the Store calls.
if (Test-RebootPending -RestartNeeded $restartNeeded) {
    Info "Windows enabled the WSL2 feature but needs a reboot to activate it."
    Stop-ForReboot
}

# 3) No reboot pending (post-reboot re-run, or a box that already had the
#    feature). Install the Store WSL app + kernel (user-mode MSIX; needs no
#    reboot) and keep it current. --no-distribution: platform only, no
#    user-facing distro. Best-effort: these hit the Microsoft Store backend,
#    which can return 403 (region prompt / network, microsoft/WSL #40285); a
#    failure here must NOT abort the installer.
Info "Installing/updating the WSL2 platform (no distribution)"
Write-Host "    This downloads the WSL kernel from the Microsoft Store and can take"
Write-Host "    SEVERAL MINUTES with little or no further output. Do not close this"
Write-Host "    window - it is not frozen. Any 'msstore'/HTTP 403 lines below are"
Write-Host "    harmless."
# Stream wsl's own progress to the console (via Invoke-Streaming, which forces
# ErrorActionPreference=Continue so the Store backend's stderr 403 noise renders
# as plain lines instead of a terminating NativeCommandError, and returns only
# the exit code). We previously suppressed all output with *>$null, which made
# this step look like a hang. Exit code is ignored on purpose - best-effort.
Invoke-Streaming wsl @('--install', '--no-distribution') | Out-Null
Invoke-Streaming wsl @('--update') | Out-Null

# A reboot can also become pending as a result of the Store calls above
# (rare, but the MSIX install can stage one). Re-check before the WSL probe.
if (Test-RebootPending -RestartNeeded $restartNeeded) {
    Info "The WSL install staged a pending reboot."
    Stop-ForReboot
}

# 4) Functional gate: WSL must actually be usable before we hand to podman.
#    We reach here only when NO reboot is pending (step 3 already handled that),
#    so if WSL still isn't answering it's a genuine problem - don't loop the user
#    through another reboot. Give an actionable diagnosis instead.
if (-not (Test-WslReady)) {
    Section "WSL isn't responding"
    Warn "The WSL platform is enabled and no reboot is pending, but 'wsl --status' is failing."
    Write-Host ""
    Write-Host "  This usually means the WSL app/kernel couldn't be fetched from the"
    Write-Host "  Microsoft Store (a 403 from 'wsl --install'/'wsl --update' - common on"
    Write-Host "  restricted networks, VPNs, or where the Store is blocked/region-gated)."
    Write-Host ""
    Write-Host "  Try, then re-run this installer:"
    Write-Host "    wsl --install --no-distribution     # accept any Store agreement prompt"
    Write-Host "    wsl --update"
    Write-Host "    wsl --status                        # should succeed before continuing"
    Write-Host ""
    Write-Host "  If you're behind a proxy/VPN or a restricted network, that's the likely"
    Write-Host "  cause - see https://aka.ms/wslinstall and microsoft/WSL issue #40285."
    Die "WSL is not usable yet; resolve the above and re-run."
}
$wslVer = Get-VersionFrom (& wsl --version 2>$null)
if ($wslVer) { Ok "WSL $wslVer" } else { Ok "WSL ready" }

# 3. Podman CLI (via winget)
Section "Podman"
if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "winget is required to install Podman. Install 'App Installer' from the Microsoft Store, or install Podman manually (https://podman.io), then re-run."
    }
    Info "Installing Podman via winget"
    # winget draws a Unicode (block-character) progress bar. Set the console to
    # UTF-8 just for this call so it renders cleanly instead of mojibake, then
    # restore the previous encoding immediately - leaving it changed would mangle
    # podman's / wsl's later UTF-8 output (a global change caused exactly that).
    $prevOutEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        & winget install -e --id RedHat.Podman --accept-package-agreements --accept-source-agreements --disable-interactivity --silent
    } finally {
        try { [Console]::OutputEncoding = $prevOutEnc } catch { $null = $_ }
    }
    # winget may not refresh PATH in this session; probe common install dirs.
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        $cand = Join-Path $env:ProgramFiles 'RedHat\Podman\podman.exe'
        if (Test-Path $cand) { $env:Path = "$(Split-Path $cand);$env:Path" }
    }
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        Die "Podman was installed but isn't on PATH yet. Open a NEW Administrator PowerShell and re-run this installer."
    }
}
$podmanVer = Get-VersionFrom (& podman --version 2>$null)
Ok "podman $(if ($podmanVer) { $podmanVer } else { 'installed' })"

# 4. Podman Machine - podman creates and owns its own Linux VM (Fedora), the
# same way the macOS installer does. No user-facing distro, no OOBE.
Section "Podman Machine"

# Pre-flight: WSL2 needs hardware virtualization to create the VM. Check it up
# front and stop with clear guidance, rather than letting `podman machine init`
# pull the image and then fail with a cryptic HCS_E_HYPERV_NOT_INSTALLED. We
# only block on a confident negative (no hypervisor AND no capable+enabled CPU).
if (-not (Test-VirtualizationCapable)) {
    Section "Virtualization not available"
    Show-VirtualizationHelp
    Die "Virtualization is not available on this machine; enable it (see above) and re-run."
}

# Headless networking, applied BEFORE the machine is created/started so it comes
# up with the right config:
#   - mirrored networking (.wslconfig) so the VM shares the host LAN IP and the
#     stack is reachable from other devices' browsers.
#   - localhost->IPv4 in ~/.ssh/config so `podman machine ssh` stays fast.
# .wslconfig is read when WSL (re)starts a distro; if WSL is already up from an
# earlier step a shutdown is needed for mirrored to take effect. We only shut
# down when we actually changed .wslconfig AND the machine isn't created yet
# (nothing to disrupt) - a no-op on re-runs where mirrored is already set.
$wslconfigBefore = if (Test-Path (Join-Path $env:USERPROFILE '.wslconfig')) { Get-Content (Join-Path $env:USERPROFILE '.wslconfig') -Raw } else { '' }
Set-WslConfigMirrored
Set-SshLocalhostIPv4
$wslconfigAfter = Get-Content (Join-Path $env:USERPROFILE '.wslconfig') -Raw
if ($wslconfigBefore -ne $wslconfigAfter) {
    Info "Applying the WSL networking change (wsl --shutdown)"
    Invoke-BestEffort wsl @('--shutdown') | Out-Null
}

# Size the VM's memory to fit the host. podman rejects a machine larger than
# total system RAM, and the stack's preflight needs >= 2048 MB inside the VM.
# Target 4096 MB but never more than (host RAM - 1024 headroom for Windows),
# floored at 2048. Auto-sizes unless -MachineMemoryMB was given.
if ($MachineMemoryMB -le 0) {
    $totalMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    $MachineMemoryMB = [Math]::Min(4096, $totalMB - 1024)
    if ($MachineMemoryMB -lt 2048) {
        Die "Not enough RAM: this host has ${totalMB} MB. The SignalK stack needs a VM with >= 2048 MB plus ~1024 MB headroom for Windows (>= ~3072 MB total). Add RAM (if a VM, raise its memory) and re-run."
    }
}
# Enforce the floor for explicit overrides too - a too-low -MachineMemoryMB
# would otherwise fail later at init or trip the stack's preflight.
if ($MachineMemoryMB -lt 2048) {
    Die "-MachineMemoryMB must be >= 2048 (got $MachineMemoryMB); the SignalK stack needs at least 2048 MB inside the VM."
}
Info "VM size: ${MachineCpus} CPUs / ${MachineMemoryMB} MB / 30 GB disk"

$machines = (& podman machine list --format '{{.Name}}' 2>$null) -replace "`0", ''
$hasMachine = $machines -and ($machines -split "\r?\n" | Where-Object { $_.Trim().TrimEnd('*') -eq $MachineName })
if (-not $hasMachine) {
    # A prior failed init can leave an orphaned WSL distro that podman no longer
    # sees but that makes the next init fail instantly. Clear it up front.
    if (Test-OrphanedMachineDistro -Name $MachineName) {
        Info "Cleaning up a leftover podman-machine WSL distro from a prior attempt"
        Remove-PodmanMachine -Name $MachineName
    }
    Info "Creating Podman machine '$MachineName' (this downloads the VM image; takes a few minutes)"
    # Stream podman's output live, but via Invoke-Streaming so its progress on
    # stderr ("Getting image source signatures", "Copying blob") doesn't trip
    # the Stop-on-native-stderr behaviour and abort the script mid-pull.
    $rc = Invoke-Streaming podman @('machine', 'init', '--cpus', "$MachineCpus", '--memory', "$MachineMemoryMB", '--disk-size', '30', $MachineName)
    if ($rc -ne 0) {
        # Thoroughly clean up (incl. the orphaned WSL distro) so a re-run is fresh.
        Remove-PodmanMachine -Name $MachineName
        # If podman enabled a WSL feature mid-init, that needs a reboot first.
        if (Test-RebootPending) { Stop-ForReboot }
        Show-VirtualizationHelp -AfterFailure
        Die "podman machine init failed (exit $rc). See the podman output above."
    }
}

$running = (& podman machine list --format '{{.Name}} {{.Running}}' 2>$null) -replace "`0", ''
$isRunning = $running -split "\r?\n" | Where-Object {
    $parts = $_.Trim() -split '\s+'
    $parts.Count -ge 2 -and $parts[0].TrimEnd('*') -eq $MachineName -and $parts[1] -eq 'true'
}
if (-not $isRunning) {
    Info "Starting Podman machine '$MachineName'"
    $rc = Invoke-Streaming podman @('machine', 'start', $MachineName)
    if ($rc -ne 0) {
        if (Test-RebootPending) { Stop-ForReboot }
        Show-VirtualizationHelp -AfterFailure
        Die "podman machine start failed (exit $rc). See the podman output above."
    }
}
& podman system connection default $MachineName 2>$null | Out-Null
Ok "Podman machine '$MachineName' running"

# 5. Run the Linux installer inside the machine (exactly like macOS).
Section "Bootstrapping inside the Podman machine"

# The Linux installer runs as the machine's regular user and sudo's for its few
# system steps. `podman machine ssh` has no TTY, so if that user's sudo wants a
# password the install dies ("a terminal is required to read the password").
# Grant the default user passwordless sudo first, via the root connection. The
# default user is whoever `podman machine ssh` lands as (resolved, not hardcoded
# - it's `user` on the WSL Fedora image, `core` on Fedora CoreOS).
Info "Ensuring the machine's user can sudo non-interactively"
# Do the whole thing in root bash on the VM: resolve the default uid-1000 user
# there (robust - no fragile PowerShell whoami capture), write the drop-in, and
# VALIDATE it with `visudo -c`. An invalid or empty-username file makes sudo
# ignore the ENTIRE /etc/sudoers.d, so we remove a bad file rather than leave it.
$sudoersScript = @'
set -euo pipefail
u="$(getent passwd 1000 | cut -d: -f1)"
if [ -z "$u" ]; then echo "ERR: no uid-1000 user in VM" >&2; exit 1; fi
f="/etc/sudoers.d/90-signalk-nopasswd"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > "$f"
chmod 0440 "$f"
if ! visudo -cf "$f"; then
    echo "ERR: sudoers drop-in for $u failed validation; removing it" >&2
    rm -f "$f"
    exit 1
fi
echo "granted NOPASSWD sudo to $u"
'@
$rc = Invoke-VmScript -Machine $MachineName -AsUser 'root' -Script $sudoersScript
if ($rc -ne 0) {
    Die "Could not grant passwordless sudo to the machine's user (exit $rc). The in-VM installer needs it. See the output above."
}

# Vessel identity + admin login. The in-VM install has no TTY, so the Linux
# installer can't prompt - we ask here (PowerShell has a real console) and
# forward the answers as SIGNALK_* env vars it reads. Like the Linux installer,
# only ask when the info doesn't already exist: probe the VM for an existing
# vessel-identity file and for users in security.json, and prompt only for the
# missing piece. Skipped entirely under -NoPrompt or a non-interactive run.
$skEnvVars = @{}
if (Test-CanPrompt) {
    Section "SignalK setup"
    # Probe existing state inside the VM (~/.signalk lives in the server's data
    # dir, mounted from the user's home). Echo a token per item that exists.
    $probe = @'
v=no; a=no
[ -f "$HOME/.signalk/baseDeltas.json" ] || [ -f "$HOME/.signalk/defaults.json" ] && v=yes
if [ -f "$HOME/.signalk/security.json" ] && grep -q '"users"' "$HOME/.signalk/security.json" 2>/dev/null; then a=yes; fi
echo "vessel=$v admin=$a"
'@
    $state = Get-VmOutput -Machine $MachineName -Script $probe
    $haveVessel = $state -match 'vessel=yes'
    $haveAdmin  = $state -match 'admin=yes'

    if ($haveVessel) {
        Info "Vessel identity already configured - leaving it as-is."
    } else {
        Write-Host "Vessel identity (pre-fills the admin UI; press Enter to skip any field):"
        $vn = (Read-Host "  Boat name").Trim()
        if ($vn) { $skEnvVars['SIGNALK_VESSEL_NAME'] = $vn }
        $vm = (Read-Host "  MMSI (9 digits)").Trim()
        if ($vm) {
            if ($vm -match '^\d{9}$') { $skEnvVars['SIGNALK_VESSEL_MMSI'] = $vm }
            else { Warn "MMSI must be exactly 9 digits - skipping it." }
        }
        $vc = (Read-Host "  VHF call sign").Trim()
        if ($vc) { $skEnvVars['SIGNALK_VESSEL_CALLSIGN'] = $vc }
    }

    if ($haveAdmin) {
        Info "Server security already configured - leaving it as-is."
    } else {
        Write-Host "Admin login (secures the server before it goes on the network; Enter to skip):"
        $au = (Read-Host "  Admin username [admin]").Trim()
        if (-not $au) { $au = 'admin' }
        $ap1 = Read-Host "  Admin password" -AsSecureString
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ap1))
        if ($p1) {
            $ap2 = Read-Host "  Confirm password" -AsSecureString
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ap2))
            if ($p1 -ne $p2) {
                Warn "Passwords did not match - skipping admin setup (server starts UNSECURED; set it up in the admin UI)."
            } else {
                $skEnvVars['SIGNALK_ADMIN_USER'] = $au
                $skEnvVars['SIGNALK_ADMIN_PASSWORD'] = $p1
            }
        } else {
            Info "No password entered - server will start unsecured (set it up in the admin UI later)."
        }
    }
}

$linuxUrl = "$InstallerBaseUrl/installer/linux/install.sh"
Info "Fetching $linuxUrl and running it in the machine"

# Single-quoted here-string: every $ is for bash. The two installer values are
# spliced in after escaping single quotes (they're URLs/versions, low risk, but
# be safe).
#
# PIPE install.sh into bash (curl ... | bash) rather than saving to a file and
# running it. The Linux installer fetches its lib/ helpers + Quadlet templates
# itself ONLY when invoked from stdin (BASH_SOURCE empty); run from a saved file
# it assumes the siblings are on disk and dies with
# "/tmp/lib/colors.sh: No such file or directory". Piping is exactly how the
# documented Linux one-liner runs, and what the self-fetch logic expects.
$ver = $InstallerVersion -replace "'", "'\''"
$base = $InstallerBaseUrl -replace "'", "'\''"
# Build the SIGNALK_* env assignments the in-VM installer reads, each value
# bash-single-quote-escaped. They go inside the base64'd script, so the password
# never appears on a command line (no `ps` exposure).
$skEnv = ''
foreach ($k in $skEnvVars.Keys) {
    $esc = $skEnvVars[$k] -replace "'", "'\''"
    $skEnv += "$k='$esc' "
}
# Pass the channel through so the in-VM installer resolves the SAME tree this
# script fetched install.sh from. Skipped when the caller gave an explicit
# -InstallerBaseUrl: install.sh:61 lets an explicit base win over the channel,
# and sending both would describe two different trees in one command line.
#
# This rides in $skEnv, which is spliced in AFTER the pipe, so the assignment
# lands on bash and not on curl - the distinction README.md:46-48 calls out,
# where a channel set on curl is read by nothing and silently ignored.
if (-not $SkExplicitBase) {
    $skEnv += "SIGNALK_CHANNEL='" + ($Channel -replace "'", "'\''") + "' "
}
# Keep the curl|bash on ONE line - no backslash line-continuation. A `\` at end
# of line followed by CRLF makes bash continue the line and swallow the `\r`
# into the next token (seen as `$'bash\r': command not found`). One line has no
# internal newline to carry a CR into the middle of a command. Invoke-VmScript
# also strips CR, but a single line removes the failure mode entirely.
$remote = @'
set -euo pipefail
cd "$HOME"
curl -fsSL '__BASE__/installer/linux/install.sh' | __SKENV__INSTALLER_VERSION='__VER__' INSTALLER_BASE_URL='__BASE__' bash
'@
$remote = $remote.Replace('__SKENV__', $skEnv).Replace('__VER__', $ver).Replace('__BASE__', $base)

# Feed the script via stdin (Invoke-VmScript) so its quotes survive the
# PowerShell -> podman -> WSL path; output streams live. The bash side is
# `set -euo pipefail`, so a real failure still yields a non-zero exit below.
$rc = Invoke-VmScript -Machine $MachineName -Script $remote
if ($rc -ne 0) {
    Die "The Linux installer exited with code $rc inside the Podman machine."
}

# 5b. Install a Windows-side `signalk` command that forwards into the VM.
# On Linux the installer puts `signalk` on PATH; on Windows the CLI lives inside
# the machine. We drop two files on the user's PATH: signalk-run.ps1 (does the
# work) and signalk.cmd (the entry point - the only thing named `signalk`).
#
# Transport (the load-bearing bit, learned the hard way): you CANNOT reliably
# pass `signalk <args>` to the VM as `podman machine ssh -- bash -lc '<script>'`
# - on Windows that path drops trailing positional args AND mangles quotes, so
# the subcommand never reaches the CLI (it just prints help). The robust method,
# same as the install handoff: base64-encode the command and pipe it via STDIN
# to `base64 -d | bash`. base64 has no shell metacharacters and `base64 -d`
# ignores the CR PowerShell appends, so it's immune to both failure modes. The
# .ps1 joins the user's args, prefixes `signalk `, base64s it, and pipes it in.
Section "Windows CLI"
$skCmdDir = Join-Path $env:LOCALAPPDATA 'Programs\signalk'
# The PS1 forwards its args to the in-VM `signalk` over the base64-stdin
# transport. `bash -l` gives the login-shell PATH that has ~/.local/bin/signalk.
$ps1Body = @"
# SignalK CLI shim - forwards to ``signalk`` inside Podman machine '$MachineName'.
#
# Most subcommands are forwarded verbatim over a base64-over-stdin transport
# (the only reliable way to run a command in the VM from Windows: podman
# machine ssh -- bash -lc drops trailing args AND mangles quotes).
# Three subcommands need host-side handling because their UX assumes the CLI
# runs on the machine the operator sits at:
#   resetadmin  - reads a password from the TTY; there is no PTY over ssh and
#                 stdin is the transport, so we prompt HERE and pass the
#                 password into the VM through the (base64'd) payload.
#   bug-report  - writes a tarball to a VM path Windows can't reach; we run it
#                 into a known VM dir, then copy the tarball out to the Desktop.
#   uninstall   - the in-VM teardown removes the stack only; on Windows we also
#                 offer to remove the Podman machine + this CLI wrapper + PATH.
`$ErrorActionPreference = 'Stop'
`$Machine = '$MachineName'
# Prepended to every in-VM ``signalk`` call. Two distinct flags:
#  - SIGNALK_PUBLIC_HOST=localhost: tells the CLI to print URLs the operator can
#    open from Windows (the stack is reached over Podman Machine's localhost
#    port-forward; 127.0.0.1 - the VM's loopback the CLI probes - is not what the
#    user should click). This is genuinely a "display host" knob.
#  - SIGNALK_WINDOWS_SHIM=1: a dedicated "this CLI is being driven by the Windows
#    shim" sentinel for Windows-context behavior (hide the Pi-only socketcan
#    line, suppress the VM-internal-path uninstall block). Kept separate from
#    SIGNALK_PUBLIC_HOST so a Linux/macOS user who sets a public host for URL
#    display doesn't accidentally trigger the Windows-only behavior.
#  - SIGNALK_CHANNEL: the channel this box was installed from, so ``signalk
#    update`` re-fetches the tree it came from instead of silently reverting a
#    master install to release. `$env:SIGNALK_CHANNEL overrides it at call time,
#    matching the documented Linux ``SIGNALK_CHANNEL=master signalk update``.
#
# NOTE the bare `$Channel below: it interpolates HERE, at install time, baking
# the chosen channel into the generated shim. That is deliberate and is the one
# intentional unescaped expansion in this here-string - every other `$ in this
# block is escaped so it survives into the generated file.
`$SkChannel = if (`$env:SIGNALK_CHANNEL) { `$env:SIGNALK_CHANNEL.ToLowerInvariant() } else { '$Channel' }
# `$SkChannel lands inside single quotes in a bash command line, and the env-var
# branch is whatever the caller exported - so a value containing a quote would
# close that string and inject. install.sh accepts exactly three spellings, so
# validate rather than escape: anything else is a typo the VM would reject with
# a worse message, and there is no legitimate value this rejects.
if (`$SkChannel -notmatch '^(release|master|dev)`$') {
    Write-Host "[ERR] SIGNALK_CHANNEL must be 'release', 'master' or 'dev' (got '`$SkChannel')"
    exit 1
}
`$SkEnv = "SIGNALK_PUBLIC_HOST=localhost SIGNALK_WINDOWS_SHIM=1 SIGNALK_CHANNEL='`$SkChannel' "

# Base64-encode a bash command and run it in the VM. base64 is one token with no
# shell metacharacters (immune to quote mangling) and ``base64 -d`` ignores the
# CR PowerShell appends; the trailing `` #`` turns the CR after ``bash -l`` into a
# comment. ``-l`` = login shell so ~/.local/bin (signalk) is on PATH. Returns the
# VM command's exit code in `$LASTEXITCODE.
function Send-Vm {
    param([string]`$BashCommand)
    `$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(`$BashCommand))
    "echo `$b64 | base64 -d | bash -l #" | podman machine ssh `$Machine
}
# Like Send-Vm but captures the VM command's stdout as text. Two hazards this
# has to defeat:
#   1. `podman machine ssh` prints a "Connecting to vm ... use ``~.`` or exit"
#      banner (and a login shell may print an MOTD) on STDOUT, ahead of the real
#      output. Capturing raw would prepend that junk - which silently broke
#      bug-report (the banner got treated as the tarball filename).
#   2. Out-String wraps long lines at the console width, corrupting a long
#      single line such as base64 -w0 of a tarball - so we -join instead.
# Fix for (1): wrap the real output between two unique sentinels the banner/MOTD
# can't contain, then return only what's strictly between them.
function Get-Vm {
    param([string]`$BashCommand)
    `$wrapped = "printf '<<<SKO>>>\n'; { " + `$BashCommand + "; }; printf '<<<SKE>>>\n'"
    `$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(`$wrapped))
    `$out = "echo `$b64 | base64 -d | bash -l #" | podman machine ssh `$Machine 2>`$null
    if (`$null -eq `$out) { return '' }
    `$text = ((`$out -join "``n") -replace "``0", '')
    `$m = [regex]::Match(`$text, '<<<SKO>>>\s*(.*?)\s*<<<SKE>>>', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (`$m.Success) { return `$m.Groups[1].Value.Trim() }
    # Sentinels missing (command died before printing them) - return nothing
    # rather than the banner so callers fail cleanly instead of on junk.
    return ''
}
# Single-quote one arg for bash: wrap in '...' and turn embedded ' into '\''.
function Quote-Bash {
    param([string]`$s)
    return "'" + (`$s -replace "'", "'\''") + "'"
}

`$sub = if (`$args.Count -gt 0) { `$args[0] } else { '' }

switch (`$sub) {

  'machine' {
    # VM-level power control: the Podman MACHINE plus its S4U boot task.
    #
    # This is a level ABOVE `signalk stop`. `signalk stop` pauses the data plane
    # (signalk-server) and deliberately leaves the updater and doctor consoles
    # running - they are recovery tiers 1 and 2, and taking them down with the
    # server would remove the surface you recover FROM. `signalk machine stop`
    # takes the whole VM down, consoles included, and frees its RAM.
    #
    # Use machine stop when you want SignalK gone until you say otherwise (the
    # boat is laid up, the laptop needs the memory); use plain stop when you
    # want the server down but the consoles reachable.
    `$act = if (`$args.Count -gt 1) { `$args[1] } else { '' }
    if (`$act -ne 'stop' -and `$act -ne 'start') {
        Write-Host 'Usage: signalk machine stop | signalk machine start'
        Write-Host ''
        Write-Host '  machine stop   stop the whole Podman machine (VM) and disable auto-start'
        Write-Host '                 at boot. Takes the updater and doctor consoles down too.'
        Write-Host '  machine start  start the machine again and re-enable auto-start at boot.'
        Write-Host ''
        Write-Host 'To stop only signalk-server and keep the consoles up, use: signalk stop'
        exit 1
    }
    `$taskName = "SignalK Podman Machine (`$Machine)"

    if (`$act -eq 'stop') {
        Write-Host '[i] Stopping the machine and disabling auto-start at boot...'
        # Surface a task-toggle failure: this shim runs non-elevated but the task
        # was registered elevated, so Disable can be denied - if so, the stack
        # would still come back at boot and we must NOT claim it won't.
        `$taskOff = `$true
        try { Disable-ScheduledTask -TaskName `$taskName -ErrorAction Stop | Out-Null }
        catch { `$taskOff = `$false; Write-Host "[WARN] Could not disable the boot task (`$(`$_.Exception.Message)). It may still start at boot; disable 'SignalK Podman Machine' in Task Scheduler manually." }
        # `podman machine stop` exits 125 if already stopped - treat that as
        # success. A real stop failure is a HARD error: the machine is still
        # running, so we must NOT report '[OK] stopped'. (The boot task is
        # already disabled above, which is fine - auto-start is off even though
        # the machine is still up.)
        `$stopOut = (& podman machine stop `$Machine 2>&1) | Out-String
        if (`$LASTEXITCODE -ne 0 -and `$stopOut -notmatch 'already stopped|not running') {
            Write-Host "[ERR] 'podman machine stop' failed: `$(`$stopOut.Trim())"
            if (`$taskOff) {
                Write-Host '      The machine is still running. Auto-start at boot was disabled; re-run after fixing the error.'
            } else {
                Write-Host '      The machine is still running, and auto-start at boot may still be enabled; disable the task manually after fixing the error.'
            }
            exit 1
        }
        if (`$taskOff) {
            Write-Host '[OK] Machine stopped and will NOT start at boot. Resume with: signalk machine start'
        } else {
            Write-Host '[OK] Machine stopped now, but auto-start at boot could NOT be disabled (see warning).'
        }
        Write-Host '     Nothing was removed - data, config and plugins are preserved.'
        exit 0
    }

    # act -eq 'start': resume after `signalk machine stop`. Inside the VM,
    # systemd brings the containers up on machine start (their Quadlets are
    # never touched on the Windows path).
    Write-Host '[i] Enabling auto-start and starting the machine...'
    `$taskOn = `$true
    try { Enable-ScheduledTask -TaskName `$taskName -ErrorAction Stop | Out-Null }
    catch { `$taskOn = `$false; Write-Host "[WARN] Could not re-enable the boot task (`$(`$_.Exception.Message)); enable 'SignalK Podman Machine' in Task Scheduler manually for start-at-boot." }
    # `podman machine start` exits 125 if already running - treat as success.
    `$startOut = (& podman machine start `$Machine 2>&1) | Out-String
    if (`$LASTEXITCODE -ne 0 -and `$startOut -notmatch 'already running') {
        Write-Host "[ERR] 'podman machine start' failed: `$(`$startOut.Trim())"; exit 1
    }
    if (`$taskOn) {
        Write-Host '[OK] Machine started and set to auto-start at boot. Check it with: signalk health'
    } else {
        Write-Host '[OK] Machine started now, but auto-start at boot could NOT be enabled (see warning). Check it with: signalk health'
    }
    exit 0
  }

  'help' {
    # The help text comes from the in-VM CLI, which knows nothing about the
    # Windows-only verbs this shim adds - so `signalk machine` would be
    # invisible to the one audience that needs it. Forward, then append.
    Send-Vm (`$SkEnv + 'signalk help')
    Write-Host ''
    Write-Host 'Windows-only:'
    Write-Host '  signalk machine stop|start'
    Write-Host '                         stop or start the Podman machine (the VM) itself and'
    Write-Host '                         its auto-start-at-boot task. One level above'
    Write-Host "                         'signalk stop', which pauses only signalk-server and"
    Write-Host '                         leaves the updater + doctor consoles reachable.'
    exit 0
  }

  'hardware' {
    # Wrapper, NOT a rejection: the in-VM rescan is correct and must still run.
    # What is missing on Windows is the precondition. A USB device plugged into
    # the PC is invisible to the Podman machine until usbipd-win attaches it to
    # WSL, so ``signalk hardware rescan`` finds no serial device and reports
    # nothing attached - true from inside the VM, and useless to someone
    # looking at the adapter in their hand.
    #
    # Only ``rescan`` gets this treatment. ``hardware status`` just reads
    # hardware.json and is correct unmodified, and a bare ``signalk hardware``
    # defaults to status on the Linux side.
    `$hwAct = if (`$args.Count -gt 1) { `$args[1] } else { 'status' }
    if (`$hwAct -eq 'rescan') {
        `$usbipd = Get-Command usbipd -ErrorAction SilentlyContinue
        if (-not `$usbipd) {
            Write-Host '[i] usbipd-win is not installed. USB devices (NMEA gateways, GPS pucks)'
            Write-Host '    cannot reach the SignalK machine without it:'
            Write-Host '      winget install --id dorssel.usbipd-win'
            Write-Host '    See docs/installation.md for the full USB serial walkthrough.'
            Write-Host ''
        } else {
            # ``usbipd list`` is a human-readable table whose columns have moved
            # between releases, so don't parse it for state - just show it and
            # let the operator read it. Printing the recipe whenever we cannot
            # positively confirm an attachment is honest and never wrong.
            Write-Host '[i] USB devices known to usbipd-win:'
            & usbipd list 2>&1 | ForEach-Object { Write-Host "    `$_" }
            Write-Host ''
            Write-Host '    A device must be BOUND and ATTACHED to WSL before the machine sees it:'
            Write-Host '      usbipd bind   --busid <BUSID>     (once per device, needs an admin shell)'
            Write-Host '      usbipd attach --wsl --busid <BUSID>'
            Write-Host ''
        }
    }
    # Forward verbatim either way - including any --no-render the caller passed.
    `$q = `$args | ForEach-Object { Quote-Bash `$_ }
    Send-Vm (`$SkEnv + 'signalk ' + (`$q -join ' '))
    exit `$LASTEXITCODE
  }

  'bluetooth' {
    # BLE passthrough needs a bluez stack on the machine running the
    # containers, and the Podman machine VM has none: no bluetoothd, no
    # bluetoothctl, nothing under /sys/class/bluetooth. WSL2 also has no path
    # to the Windows host's Bluetooth radio - only a USB dongle detached from
    # Windows via usbipd could reach it, and the VM still has no bluez to
    # drive it. Forwarding would install a proxy Quadlet that can never work.
    Write-Host "'signalk bluetooth' is not available on Windows - BLE passthrough"
    Write-Host 'needs a bluez stack on the machine running the containers, and the'
    Write-Host 'Podman machine VM has none. WSL2 cannot reach the Windows Bluetooth'
    Write-Host 'radio either. Use a USB or network gateway for that sensor instead.'
    exit 1
  }

  'timesync' {
    # Sets the HOST clock and timezone from SignalK's GPS, for boats with no
    # NTP. On Windows the host is Windows - the VM's clock is slaved to it by
    # WSL - so running this in the machine would set a clock nothing reads,
    # and the root agent it execs is not installed there anyway.
    Write-Host "'signalk timesync' is not available on Windows - it steps the HOST"
    Write-Host 'clock from GPS on boats with no NTP, and here the host is Windows.'
    Write-Host 'The VM takes its time from Windows, so set the Windows clock (or'
    Write-Host 'let it sync) and the stack follows.'
    exit 1
  }

  'socketcan' {
    # Pi CAN-HAT (GPIO/SPI socketcan) setup. Meaningless on Windows: the stack
    # runs in the Podman machine's VM, which has no CAN hardware, no SPI bus,
    # and no Pi device-tree. Don't forward it (inside the VM it would just run
    # the helper and find nothing - confusing). Reject with a clear note.
    Write-Host "'signalk socketcan' is not available on Windows - it sets up a"
    Write-Host 'Raspberry Pi CAN HAT (SPI/socketcan), which the Podman machine VM'
    Write-Host 'has no access to. Use a USB or network NMEA 2000 gateway instead.'
    exit 1
  }

  'halpi2' {
    # Hat Labs HALPI2 carrier-board setup (Raspberry Pi CM5: I2C controller,
    # config.txt device tree, apt packages). None of that exists in the Podman
    # machine VM. Reject with a clear note, same as socketcan.
    Write-Host "'signalk halpi2' is not available on Windows - it configures a"
    Write-Host 'Hat Labs HALPI2 (Raspberry Pi CM5) carrier board, which the Podman'
    Write-Host 'machine VM has no access to.'
    exit 1
  }

  'resetadmin' {
    # The VM CLI can't prompt (no PTY, stdin busy). Prompt on Windows, confirm
    # the match here, then hand the password to the VM via the env var
    # SIGNALK_RESETADMIN_PASSWORD - embedded inside the base64 payload so the
    # plaintext never appears on podman's argv or the VM's process list.
    `$user = if (`$args.Count -gt 1) { `$args[1] } else { 'admin' }
    `$p1 = Read-Host "New password for '`$user'" -AsSecureString
    `$p2 = Read-Host "Confirm password" -AsSecureString
    `$b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(`$p1)
    `$b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(`$p2)
    try {
        `$pw  = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(`$b1)
        `$pwc = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(`$b2)
        if ([string]::IsNullOrEmpty(`$pw)) { Write-Host '[ERR] Password must not be empty.'; exit 1 }
        if (`$pw -ne `$pwc)                { Write-Host '[ERR] Passwords do not match.';   exit 1 }
        `$cmd = 'SIGNALK_RESETADMIN_PASSWORD=' + (Quote-Bash `$pw) + ' ' + `$SkEnv + 'signalk resetadmin ' + (Quote-Bash `$user)
        Send-Vm `$cmd
        `$rc = `$LASTEXITCODE
    } finally {
        # Zero the plaintext + the unmanaged BSTRs so the password doesn't linger.
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(`$b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(`$b2)
        `$pw = `$null; `$pwc = `$null; `$cmd = `$null
    }
    exit `$rc
  }

  'bug-report' {
    # Run the bundler into a known on-disk VM dir (NOT /tmp - tmpfs), then copy
    # the tarball out to the Windows Desktop. The bundle is gzip (binary): pull
    # it base64-encoded so ssh's text/CRLF handling can't corrupt it.
    #
    # The VM dir is written in BASH form: "`$HOME" is double-quoted so bash
    # expands it, and the suffix is a bare literal (no spaces/metacharacters).
    # Do NOT single-quote the whole thing - that would stop `$HOME expanding and
    # create a literal '`$HOME' directory.
    `$vmDir = '"`$HOME"/.signalk-updater/bug-reports'
    Write-Host '[i] Generating the bug report inside the Podman machine...'
    Send-Vm (`$SkEnv + "signalk bug-report --to " + `$vmDir)
    if (`$LASTEXITCODE -ne 0) { Write-Host '[ERR] bug-report failed inside the VM.'; exit `$LASTEXITCODE }
    # Newest tarball in that dir. The glob must stay UNQUOTED so the shell
    # expands *; the dir prefix carries its own quoting (see above).
    `$vmPath = Get-Vm ("ls -1t " + `$vmDir + "/signalk-bug-report-*.tar.gz 2>/dev/null | head -1")
    if ([string]::IsNullOrWhiteSpace(`$vmPath)) {
        Write-Host '[ERR] Could not locate the generated bundle inside the VM.'; exit 1
    }
    `$name = Split-Path -Leaf `$vmPath
    `$dest = Join-Path ([Environment]::GetFolderPath('Desktop')) `$name
    Write-Host "[i] Copying `$name to the Desktop..."
    `$b64 = Get-Vm ("base64 -w0 " + (Quote-Bash `$vmPath))
    if ([string]::IsNullOrWhiteSpace(`$b64)) { Write-Host '[ERR] Failed to read the bundle from the VM.'; exit 1 }
    try {
        [System.IO.File]::WriteAllBytes(`$dest, [Convert]::FromBase64String(`$b64))
    } catch {
        Write-Host "[ERR] Could not write the bundle to `$dest (`$(`$_.Exception.Message))."; exit 1
    }
    # Remove the VM-side copy now that it's safely on Windows.
    Send-Vm ("rm -f " + (Quote-Bash `$vmPath)) | Out-Null
    Write-Host ''
    Write-Host '[OK] Bug report bundle saved to:'
    Write-Host "  `$dest"

    # Optional filebin upload + issue-page open, on the WINDOWS side. The in-VM
    # CLI skips these (no TTY/browser in the VM); here we have both. Same flow,
    # endpoints, and default-Y prompts as the Linux cmd_bug_report.
    `$issueBase = 'https://github.com/SignalK/signalk-server/issues/new'
    # Stamp from the filename: signalk-bug-report-<stamp>.tar.gz
    `$stamp = `$name -replace '^signalk-bug-report-', '' -replace '\.tar\.gz`$', ''
    `$tarballUrl = ''

    Write-Host ''
    Write-Host 'Upload the bundle to filebin.net so it can be linked from the issue?'
    Write-Host '  - filebin.net is PUBLIC: anyone with the bin URL can download it.'
    Write-Host '  - The bundle has tokens and pipedProviders options redacted, but'
    Write-Host '    still contains settings.json, hardware.json, plugin versions,'
    Write-Host '    and 24 hours of journal output. Review the tarball first if'
    Write-Host '    you are on a shared boat or run custom plugins.'
    Write-Host '  - filebin auto-expires bins after ~6 days.'
    `$ansUp = Read-Host 'Upload now? [Y/n]'
    if ([string]::IsNullOrWhiteSpace(`$ansUp)) { `$ansUp = 'Y' }
    if (`$ansUp -match '^[Yy]') {
        # Bin name mixes timestamp + a random suffix so the URL is infeasible to
        # guess; that is the only access control filebin offers.
        `$bin = 'signalk-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + (Get-Random)
        `$url = 'https://filebin.net/' + `$bin + '/' + `$name
        Write-Host "[i] Uploading `$name ..."
        try {
            # -InFile streams the file's raw bytes (no transcoding) on both
            # Windows PowerShell 5.1 and PS7 - safe for the gzip.
            Invoke-RestMethod -Uri `$url -Method Post -InFile `$dest ``
                -ContentType 'application/gzip' -TimeoutSec 120 | Out-Null
            `$tarballUrl = `$url
            Write-Host '[OK] Uploaded:'
            Write-Host "  `$tarballUrl"
        } catch {
            Write-Host "[WARN] Upload failed (`$(`$_.Exception.Message)). Attach the file from your Desktop manually."
        }
    }

    Write-Host ''
    `$ansIssue = Read-Host 'Open the GitHub issue page in your browser? [Y/n]'
    if ([string]::IsNullOrWhiteSpace(`$ansIssue)) { `$ansIssue = 'Y' }
    if (`$ansIssue -match '^[Yy]') {
        if (`$tarballUrl) {
            `$body = "**Bug report bundle:** `$tarballUrl``n_(filebin link, auto-expires in ~6 days - please download soon)_"
        } else {
            `$body = "**Bug report bundle:** attach the file '`$name' from your Desktop"
        }
        `$body += "``n``n**What happened:**``n``n**Expected:**``n``n**Steps to reproduce:**``n"
        `$issueUrl = `$issueBase + '?title=' + [uri]::EscapeDataString("Bug report `$stamp") + '&body=' + [uri]::EscapeDataString(`$body)
        Write-Host '[i] Opening:'
        Write-Host "  `$issueUrl"
        try { Start-Process `$issueUrl } catch {
            Write-Host '(could not open a browser - copy the URL above)'
        }
    } else {
        Write-Host 'Open this when you are ready:'
        Write-Host "  `$issueBase"
    }
    exit 0
  }

  'uninstall' {
    # First the in-VM teardown (stack + preserved-data summary), then the
    # Windows-side teardown the in-VM CLI can't do: the Podman machine itself
    # (where ALL SignalK data lives), this CLI wrapper, and the PATH entry.
    Send-Vm (`$SkEnv + 'signalk uninstall')
    `$vmRc = `$LASTEXITCODE
    Write-Host ''
    if (`$vmRc -eq 0) {
        Write-Host 'The command above removed the SignalK stack INSIDE the Podman machine.'
    } else {
        # Don't claim a success the VM didn't report. Removing the machine below
        # wipes everything regardless, so still offer to continue - but be honest
        # that the in-VM teardown failed if the user declines.
        Write-Host "[WARN] The in-VM 'signalk uninstall' exited with code `$vmRc - the stack may NOT be fully removed inside the machine."
    }
    Write-Host "On Windows, the SignalK data lives entirely in the Podman machine '`$Machine'."
    Write-Host ''
    `$ans = Read-Host "Remove the Podman machine '`$Machine' and ALL its data, plus this 'signalk' command? [y/N]"
    if (`$ans -notmatch '^[Yy]') {
        if (`$vmRc -ne 0) {
            Write-Host "[WARN] The in-VM teardown FAILED (code `$vmRc) and you declined machine removal - the stack may still be running. Re-run 'signalk uninstall', or remove the machine with: podman machine rm -f `$Machine"
        } else {
            Write-Host 'Left the Podman machine and the signalk command in place.'
            Write-Host "To finish later: podman machine rm -f `$Machine"
        }
        exit `$vmRc
    }
    Write-Host "[i] Stopping and removing Podman machine '`$Machine'..."
    & podman machine stop `$Machine 2>`$null | Out-Null
    & podman machine rm -f `$Machine
    if (`$LASTEXITCODE -ne 0) { Write-Host "[WARN] 'podman machine rm' reported an error; check 'podman machine list'." }
    # Remove the boot auto-start task the installer registered (name must match
    # Register-MachineAutostart). Best-effort - absent on installs from before it.
    Unregister-ScheduledTask -TaskName "SignalK Podman Machine (`$Machine)" -Confirm:`$false -ErrorAction SilentlyContinue
    # Remove the firewall allow rules (names must match Add-FirewallRules). The
    # port list is interpolated from `$SignalkPorts at generation time so it
    # can't drift from the install-side Add-FirewallRules call.
    foreach (`$p in $($SignalkPorts -join ',')) {
        Remove-NetFirewallRule -Name "SignalK-`$p" -ErrorAction SilentlyContinue
    }
    # UDP rules are opt-in at install time, so the port list is not known here.
    # Match on the name prefix instead - a no-op when no UDP ports were opened.
    Get-NetFirewallRule -Name 'SignalK-UDP-*' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    # The Hyper-V layer exists only on Windows 11 22H2+. Calling a cmdlet that
    # does not exist throws CommandNotFoundException BEFORE -ErrorAction is
    # consulted, so guard on the command itself, not on the error action.
    if (Get-Command Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        foreach (`$p in $($SignalkPorts -join ',')) {
            Remove-NetFirewallHyperVRule -Name "SignalK-HyperV-TCP-`$p" -ErrorAction SilentlyContinue
        }
        Get-NetFirewallHyperVRule -Name 'SignalK-HyperV-UDP-*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue
    }
    # Strip our dir from the user PATH.
    `$dir = Split-Path -Parent `$MyInvocation.MyCommand.Path
    `$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (`$userPath) {
        # -ine: explicit case-insensitive match. PowerShell's -ne is already
        # case-insensitive by default, but Windows paths are case-insensitive
        # and `$dir (from `$MyInvocation) may differ in case from the stored PATH
        # entry, so spell out the intent.
        `$kept = (`$userPath -split ';') | Where-Object { `$_ -and (`$_ -ine `$dir) }
        [Environment]::SetEnvironmentVariable('Path', (`$kept -join ';'), 'User')
    }
    Write-Host '[OK] Removed the Podman machine and the PATH entry.'
    Write-Host '(WSL and the Podman app are left installed - remove them via Windows Settings if you want.)'
    # Remove the wrapper dir, but NOT from inside this process: we are running as
    # %LOCALAPPDATA%\Programs\signalk\signalk.cmd -> signalk-run.ps1, both living
    # in `$dir. Deleting `$dir while signalk.cmd is mid-execution makes cmd.exe
    # print "The system cannot find the path specified." when PowerShell returns
    # and cmd tries to read the next batch line from the now-deleted file. So we
    # hand the delete to a DETACHED cmd that waits for this window to release the
    # files, then removes the dir - nothing deletes the running script out from
    # under itself. Output is discarded (>nul 2>&1) so no stray error surfaces.
    `$rmCmd = '/c ping -n 3 127.0.0.1 >nul 2>&1 & rmdir /s /q "' + `$dir + '" >nul 2>&1'
    Start-Process -FilePath 'cmd.exe' -ArgumentList `$rmCmd -WindowStyle Hidden | Out-Null
    Write-Host "[OK] Scheduled removal of the 'signalk' command files (`$dir)."
    exit 0
  }

  default {
    # Everything else: forward verbatim. Single-quote EACH arg so spaces don't
    # split and shell metacharacters can't inject (e.g. 'health; rm -rf ...').
    `$q = `$args | ForEach-Object { Quote-Bash `$_ }
    Send-Vm (`$SkEnv + 'signalk ' + (`$q -join ' '))
    exit `$LASTEXITCODE
  }
}
"@
# .cmd shim so `signalk ...` works from cmd.exe and PowerShell alike. The worker
# is named signalk-RUN.ps1 (not signalk.ps1) ON PURPOSE: if it were signalk.ps1,
# typing `signalk` in PowerShell would resolve to that .ps1 directly and fail
# under a restricted execution policy ("running scripts is disabled"). With only
# `signalk.cmd` named `signalk` on PATH, both cmd and PowerShell run the .cmd,
# which re-launches PowerShell with -ExecutionPolicy Bypass for the worker.
$cmdBody = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0signalk-run.ps1" %*
"@
try {
    New-Item -ItemType Directory -Force -Path $skCmdDir | Out-Null
    # Remove a stale signalk.ps1 from an earlier installer version - if left, a
    # bare `signalk` in PowerShell would still resolve to it (PowerShell prefers
    # .ps1 over .cmd) and fail under a restricted execution policy. Warn if it
    # can't be removed (e.g. locked), since silently leaving it keeps the bug.
    $staleP1 = Join-Path $skCmdDir 'signalk.ps1'
    if (Test-Path $staleP1) {
        Remove-Item -Force $staleP1 -ErrorAction SilentlyContinue
        if (Test-Path $staleP1) {
            Warn "Could not remove the old $staleP1 - if 'signalk' fails with an execution-policy error, delete that file manually."
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $skCmdDir 'signalk-run.ps1'), ($ps1Body -replace "`r?`n", "`r`n"), [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $skCmdDir 'signalk.cmd'), ($cmdBody -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
    # Add the dir to the USER PATH (no admin needed) if not already there.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $skCmdDir) {
        $newPath = if ($userPath) { "$userPath;$skCmdDir" } else { $skCmdDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Ok "Installed 'signalk' command to $skCmdDir (added to PATH - open a NEW terminal to use it)"
    } else {
        Ok "Installed 'signalk' command to $skCmdDir"
    }
} catch {
    Warn "Could not install the Windows 'signalk' command ($($_.Exception.Message)); use 'podman machine ssh $MachineName' then 'signalk ...' instead."
}

# 5c. Open the firewall so other LAN devices can reach the stack (under mirrored
# networking the host firewall gates inbound, default-block). Cover both the
# standard ports (80/443) and the declined-standard fallback (3000/3443), plus
# the two consoles - opening a couple unused ports is harmless.
Section "Firewall"
Add-FirewallRules -Ports $SignalkPorts -UdpPorts $NmeaUdpPorts

# 5d. Start the machine automatically after a reboot (a podman machine doesn't
# start on boot on its own). Registered last, once the stack is confirmed up.
Section "Auto-start on reboot"
Register-MachineAutostart -Machine $MachineName -CmdDir $skCmdDir

# 6. Done. Two different addresses, because the Windows host and the rest of
# the LAN do not share a working one:
#   - other devices use the host's LAN IP (verified: a phone loads it on :80);
#   - the Windows box itself must use 127.0.0.1. Its own mirrored LAN address
#     is refused at the TCP layer from the host, and `localhost` resolves to
#     ::1 first while the stack listens on IPv4, stalling ~21s per connection
#     (measured 21.1s vs 0.01s over 127.0.0.1).
$lanIp = Get-HostLanIp
$accessHost = if ($lanIp) { $lanIp } else { '<this-pc-ip>' }
@"

OK - SignalK is up inside Podman Machine '$MachineName'.

From ANY OTHER DEVICE on the network (phone, tablet, laptop):

  SignalK admin UI : http://$accessHost        (or :3000 if you declined standard ports)
  Updater Console  : http://${accessHost}:3003
  Doctor Console   : http://${accessHost}:3004

From THIS PC use 127.0.0.1 instead - http://127.0.0.1, :3003, :3004.

Under mirrored networking the machine shares this PC's LAN address, and the
host cannot reach itself through it: the addresses above answer from every
other device but are refused here. 'localhost' does answer, but Windows tries
IPv6 (::1) first while the stack listens on IPv4, so each new connection
stalls ~21s before falling back (measured 21.1s, against 0.01s over
127.0.0.1). 127.0.0.1 has neither problem.

Manage it from a NEW terminal with the 'signalk' command, e.g.:
  signalk health
  signalk version
  signalk bug-report
(or open a shell in the machine: podman machine ssh $MachineName)

USB serial passthrough requires usbipd-win on the Windows side; see
docs/installation.md (section "Windows USB").
"@ | Write-Host

Wait-BeforeExit
