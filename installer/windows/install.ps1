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
    [string]$InstallerBaseUrl = 'https://dirkwa.github.io/signalk-universal-installer'
)

if (-not $InstallerVersion) { $InstallerVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { '0.0.0-scaffold' } }

$ErrorActionPreference = 'Stop'

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
    Write-Host "       iwr -useb $InstallerBaseUrl/installer/windows/install.ps1 | iex"
    Write-Host ""
    Write-Host "  (If WSL still fails after the reboot, confirm hardware virtualization"
    Write-Host "   - VT-x / AMD-V - is enabled in your BIOS/UEFI.)"
    Wait-BeforeExit
    exit 0
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
    $r = Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName $WslFeatures -ErrorAction Stop
    if ($r -and $r.RestartNeeded) { $restartNeeded = $true }
} catch {
    Warn "Could not enable WSL features via DISM ($($_.Exception.Message)); falling back to 'wsl --install'."
}

# 2) Install the Store WSL app + kernel (user-mode MSIX; needs no reboot) and
#    keep it current. --no-distribution: platform only, no user-facing distro.
#    Best-effort: these hit the Microsoft Store backend, which can return 403
#    (region prompt / network / not-ready-until-reboot, microsoft/WSL #40285).
#    A failure here must NOT abort the installer - the DISM enable above already
#    did the reboot-requiring work, and on the post-reboot re-run this succeeds.
Info "Installing/updating the WSL2 platform (no distribution)"
Invoke-BestEffort wsl @('--install', '--no-distribution') | Out-Null
Invoke-BestEffort wsl @('--update') | Out-Null

# 3) If a reboot is pending (from the feature enable or the CBS flag), stop here
#    - BEFORE podman - and tell the user it's expected. Re-run resumes after.
#    This fires on a fresh box right after the DISM enable, so the flaky
#    Store-backed wsl calls above are irrelevant: we reboot, then re-run.
if (Test-RebootPending -RestartNeeded $restartNeeded) { Stop-ForReboot }

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
# SignalK CLI shim - forwards to `signalk` inside Podman machine '$MachineName'.
# Single-quote EACH arg for bash before joining (wrap in '...', and turn any
# embedded ' into the '\'' idiom). Without this, '`$args -join " "' would let an
# arg with spaces split into several (e.g. --to "/x/with space") and let shell
# metacharacters inject commands into the VM (e.g. 'health; rm -rf ...').
`$q = `$args | ForEach-Object { "'" + (`$_ -replace "'", "'\''") + "'" }
`$cmd = 'signalk ' + (`$q -join ' ')
`$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(`$cmd))
# Pipe via stdin: base64 -d ignores the CR PowerShell appends inside the b64, and
# the trailing ` #` turns the CR after `bash -l` into a comment (without it bash
# sees `-l<CR>` = invalid option). `-l` = login shell so ~/.local/bin (signalk)
# is on PATH.
"echo `$b64 | base64 -d | bash -l #" | podman machine ssh $MachineName
exit `$LASTEXITCODE
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

# 6. Done
@"

OK - SignalK is up inside Podman Machine '$MachineName'.

  SignalK admin UI : http://localhost  (or :3000 if you declined standard ports)
  Updater Console  : http://localhost:3003
  Doctor Console   : http://localhost:3004

Podman Machine forwards published container ports to Windows localhost.

Manage it from a NEW terminal with the 'signalk' command, e.g.:
  signalk health
  signalk version
  signalk bug-report
(or open a shell in the machine: podman machine ssh $MachineName)

USB serial passthrough requires usbipd-win on the Windows side; see
docs/installation.md (section "Windows USB").
"@ | Write-Host

Wait-BeforeExit
