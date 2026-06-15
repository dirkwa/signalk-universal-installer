# SignalK Universal Installer (v2) — Windows (WSL2 + Podman Machine) bootstrap.
#
# We install the WSL2 platform (no user-facing distro), install the Podman CLI,
# and let `podman machine` create and own its own Linux VM — then run the
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
#   - USB serial passthrough requires usbipd-win — link in docs/installation.md.

param(
    [string]$MachineName = 'signalk',
    [int]$MachineMemoryMB = 0,   # 0 = auto-size from host RAM (see below)
    [int]$MachineCpus = 2,
    [string]$InstallerVersion,
    [string]$InstallerBaseUrl = 'https://dirkwa.github.io/signalk-universal-installer'
)

if (-not $InstallerVersion) { $InstallerVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { '0.0.0-scaffold' } }

$ErrorActionPreference = 'Stop'

# NOTE on output encoding: wsl.exe emits UTF-16LE, so a captured `& wsl ...`
# comes back with a NUL between every character — Get-VersionFrom strips those
# NULs to parse the version. We deliberately do NOT set
# [Console]::OutputEncoding globally: that would make PowerShell decode every
# child process as UTF-16, which mangles the UTF-8 streaming output of
# `podman` (and its progress bars) into garbage. So we only capture+clean wsl's
# output, and let podman write straight to the console.

function Info($msg)    { Write-Host "[i] $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Warning $msg }
function Section($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor White }
function Die($msg)     { Write-Error $msg; exit 1 }

# The two Windows optional features WSL2 (and podman machine) require.
$WslFeatures = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')

# True when one of the WSL features was just enabled but the box hasn't rebooted
# yet — until then WSL2 can't run. Detect this and stop with clear guidance.
function Test-RebootPending {
    foreach ($f in $WslFeatures) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'EnablePending') { return $true }
    }
    return $false
}

# True only when BOTH WSL features are fully Enabled. `wsl --version` working is
# NOT sufficient — the features can report not-fully-enabled while wsl.exe still
# runs, which is exactly when podman machine's bundled provider re-runs
# `wsl --install` mid-init and trips the reboot race (HCS_E_SERVICE_NOT_AVAILABLE).
# We check the feature state directly so we can enable + reboot up front instead.
function Test-WslFeaturesEnabled {
    foreach ($f in $WslFeatures) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if (-not $feat -or $feat.State -ne 'Enabled') { return $false }
    }
    return $true
}

# Print reboot-then-re-run guidance and exit cleanly. This is a NORMAL part of
# enabling WSL2 (Windows requires a reboot to activate the feature), not a
# failure. The installer is idempotent, so re-running after the reboot resumes
# from here.
function Stop-ForReboot {
    Section "Reboot required (this is normal — not an error)"
    Ok "WSL2 has been enabled. Windows needs one reboot to activate it."
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "    1. Reboot Windows."
    Write-Host "    2. Open PowerShell as Administrator again."
    Write-Host "    3. Re-run the same command — it picks up where it left off:"
    Write-Host "       iwr -useb $InstallerBaseUrl/installer/windows/install.ps1 | iex"
    Write-Host ""
    Write-Host "  (If WSL still fails after the reboot, confirm hardware virtualization"
    Write-Host "   — VT-x / AMD-V — is enabled in your BIOS/UEFI.)"
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

# Print actionable guidance when WSL2/podman-machine can't create a VM because
# virtualization isn't available — the dominant cause on a guest VM is nested
# virtualization not being exposed by the host.
function Show-VirtualizationHelp {
    $hv = Get-HostHypervisor
    Write-Host ""
    Write-Host "  If the error above mentions virtualization / HCS_E_HYPERV_NOT_INSTALLED /"
    Write-Host "  0x80370102, the Windows hypervisor can't create the VM. Fixes:"
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
# failure — it's advice, not a destructive action, and on a guest VM a
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
# We gate on the FEATURE STATE, not on `wsl --version`: podman machine's bundled
# WSL provider re-runs `wsl --install` itself if the features aren't fully
# enabled, which enables a feature mid-init and then fails the VM creation with
# a reboot-pending error that looks like a crash. By enabling the features here
# and telling the user up front that one reboot is expected, podman finds WSL
# ready and never trips that race.
Section "WSL2 platform"
if (Test-WslFeaturesEnabled) {
    $wslVer = Get-VersionFrom (& wsl --version 2>$null)
    if ($wslVer) { Ok "WSL $wslVer" } else { Ok "WSL features enabled" }
    # Keep WSL current (helps the systemd/user-bus story); a no-op if already latest.
    & wsl --update 2>$null | Out-Null
    if (Test-RebootPending) { Stop-ForReboot }
} else {
    Warn "WSL2 isn't fully enabled yet. Enabling it now — this needs ONE Windows reboot."
    Info "After the reboot, re-run the same command and it continues automatically."
    Info "Installing the WSL2 platform (no distribution)"
    & wsl --install --no-distribution
    # `wsl --install` enables VirtualMachinePlatform + the WSL component, which
    # take effect only after a reboot. Expect one here — this is normal setup,
    # not an error.
    if (Test-RebootPending -or -not (Test-WslFeaturesEnabled)) { Stop-ForReboot }
    $wslVer = Get-VersionFrom (& wsl --version 2>$null)
    if ($wslVer) { Ok "WSL $wslVer" } else { Ok "WSL features enabled" }
}

# 3. Podman CLI (via winget)
Section "Podman"
if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "winget is required to install Podman. Install 'App Installer' from the Microsoft Store, or install Podman manually (https://podman.io), then re-run."
    }
    Info "Installing Podman via winget"
    & winget install -e --id RedHat.Podman --accept-package-agreements --accept-source-agreements --silent
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

# 4. Podman Machine — podman creates and owns its own Linux VM (Fedora), the
# same way the macOS installer does. No user-facing distro, no OOBE.
Section "Podman Machine"

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
# Enforce the floor for explicit overrides too — a too-low -MachineMemoryMB
# would otherwise fail later at init or trip the stack's preflight.
if ($MachineMemoryMB -lt 2048) {
    Die "-MachineMemoryMB must be >= 2048 (got $MachineMemoryMB); the SignalK stack needs at least 2048 MB inside the VM."
}
Info "VM size: ${MachineCpus} CPUs / ${MachineMemoryMB} MB / 30 GB disk"

$machines = (& podman machine list --format '{{.Name}}' 2>$null) -replace "`0", ''
$hasMachine = $machines -and ($machines -split "\r?\n" | Where-Object { $_.Trim().TrimEnd('*') -eq $MachineName })
if (-not $hasMachine) {
    Info "Creating Podman machine '$MachineName' (this downloads the VM image; takes a few minutes)"
    # Stream podman's output straight to the console so its download progress
    # bar shows and UTF-8 text isn't mangled (do NOT capture it).
    & podman machine init --cpus $MachineCpus --memory $MachineMemoryMB --disk-size 30 $MachineName
    if ($LASTEXITCODE -ne 0) {
        # Clean up the half-created machine so a re-run starts fresh.
        & podman machine rm --force $MachineName 2>$null | Out-Null
        # If podman enabled a WSL feature mid-init, that needs a reboot first.
        if (Test-RebootPending) { Stop-ForReboot }
        Show-VirtualizationHelp
        Die "podman machine init failed (exit $LASTEXITCODE). See the podman output above."
    }
}

$running = (& podman machine list --format '{{.Name}} {{.Running}}' 2>$null) -replace "`0", ''
$isRunning = $running -split "\r?\n" | Where-Object {
    $parts = $_.Trim() -split '\s+'
    $parts.Count -ge 2 -and $parts[0].TrimEnd('*') -eq $MachineName -and $parts[1] -eq 'true'
}
if (-not $isRunning) {
    Info "Starting Podman machine '$MachineName'"
    & podman machine start $MachineName
    if ($LASTEXITCODE -ne 0) {
        if (Test-RebootPending) { Stop-ForReboot }
        Show-VirtualizationHelp
        Die "podman machine start failed (exit $LASTEXITCODE). See the podman output above."
    }
}
& podman system connection default $MachineName 2>$null | Out-Null
Ok "Podman machine '$MachineName' running"

# 5. Run the Linux installer inside the machine (exactly like macOS).
Section "Bootstrapping inside the Podman machine"
$linuxUrl = "$InstallerBaseUrl/installer/linux/install.sh"
Info "Fetching $linuxUrl and running it in the machine"

# Single-quoted here-string: every $ is for bash. The two installer values are
# spliced in after escaping single quotes (they're URLs/versions, low risk, but
# be safe).
$ver = $InstallerVersion -replace "'", "'\''"
$base = $InstallerBaseUrl -replace "'", "'\''"
$remote = @'
set -euo pipefail
cd "$HOME"
curl -fsSL '__BASE__/installer/linux/install.sh' -o /tmp/sk-install.sh
chmod +x /tmp/sk-install.sh
INSTALLER_VERSION='__VER__' INSTALLER_BASE_URL='__BASE__' bash /tmp/sk-install.sh
'@
$remote = $remote.Replace('__VER__', $ver).Replace('__BASE__', $base)

& podman machine ssh $MachineName -- bash -lc $remote
if ($LASTEXITCODE -ne 0) {
    Die "The Linux installer exited with code $LASTEXITCODE inside the Podman machine."
}

# 6. Done
@"

OK - SignalK is up inside Podman Machine '$MachineName'.

  SignalK admin UI : http://localhost  (or :3000 if you declined standard ports)
  Updater Console  : http://localhost:3003
  Doctor Console   : http://localhost:3004

Podman Machine forwards published container ports to Windows localhost.

To open a shell in the machine for diagnostics:
  podman machine ssh $MachineName
  ~/.local/bin/signalk-recovery status

USB serial passthrough requires usbipd-win on the Windows side; see
docs/installation.md (section "Windows USB").
"@ | Write-Host
