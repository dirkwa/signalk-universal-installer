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

# wsl.exe / some CLIs write console output as UTF-16LE. Without this, a piped
# capture (`$x = & wsl ...`) comes back with a NUL between every character, so
# parsing silently fails. Set the console to Unicode for this one-shot process;
# we also strip stray NULs at parse sites (older PowerShell ignores this).
try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode } catch { <# Non-fatal; NUL stripping at parse sites handles the fallback #> }

function Info($msg)    { Write-Host "[i] $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Warning $msg }
function Section($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor White }
function Die($msg)     { Write-Error $msg; exit 1 }

# True when a Windows feature WSL2 needs (VirtualMachinePlatform / the WSL
# optional component) was just enabled but the box hasn't rebooted yet — until
# then WSL2 can't run. Detect this and stop with clear guidance.
function Test-RebootPending {
    foreach ($f in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'EnablePending') { return $true }
    }
    return $false
}

# Print reboot-then-re-run guidance and exit cleanly. The installer is
# idempotent, so re-running after the reboot resumes from here.
function Stop-ForReboot {
    Section "Reboot required"
    Warn "A Windows reboot is needed to finish enabling WSL2 (a required Windows feature is pending)."
    Write-Host ""
    Write-Host "  Reboot Windows, then re-run this installer:"
    Write-Host "    iwr -useb $InstallerBaseUrl/installer/windows/install.ps1 | iex"
    Write-Host ""
    Write-Host "  If WSL still fails to start after the reboot, confirm hardware"
    Write-Host "  virtualization (VT-x / AMD-V) is enabled in your BIOS/UEFI."
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
    Warn "Could not start a Linux VM — the Windows hypervisor isn't available (virtualization not enabled)."
    Write-Host ""
    if ($hv) { Write-Host "  Detected host hypervisor: $hv (this looks like a guest VM)." }
    Write-Host "  If this is a VIRTUAL MACHINE, enable nested virtualization on the HOST"
    Write-Host "  (the VM must be powered OFF when you change it):"
    Write-Host ""
    Write-Host "    Hyper-V host : Set-VMProcessor -VMName <VM> -ExposeVirtualizationExtensions `$true"
    Write-Host "    VMware       : VM Settings > Processors > 'Virtualize Intel VT-x/EPT or AMD-V/RVI'"
    Write-Host "    VirtualBox   : not supported for WSL2 (Hyper-V can't nest in VirtualBox)"
    Write-Host "    Proxmox/KVM  : VM CPU type 'host' + nested KVM enabled on the host"
    Write-Host ""
    Write-Host "  On BARE METAL, enable VT-x / AMD-V (SVM) in the BIOS/UEFI."
    Write-Host "  Confirm inside Windows (want True): (Get-CimInstance Win32_ComputerSystem).HypervisorPresent"
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
Section "WSL2 platform"
try {
    $wslVer = Get-VersionFrom (& wsl --version 2>$null)
} catch { $wslVer = $null }
if (-not $wslVer) {
    Info "Installing the WSL2 platform (no distribution)"
    & wsl --install --no-distribution
    # `wsl --install` enables VirtualMachinePlatform, which needs a reboot.
    if (Test-RebootPending) { Stop-ForReboot }
    try { $wslVer = Get-VersionFrom (& wsl --version 2>$null) } catch { $wslVer = $null }
    if (-not $wslVer) {
        Info "Updating WSL"
        & wsl --update
        if (Test-RebootPending) { Stop-ForReboot }
        try { $wslVer = Get-VersionFrom (& wsl --version 2>$null) } catch { $wslVer = $null }
    }
}
if (Test-RebootPending) { Stop-ForReboot }
if ($wslVer) { Ok "WSL $wslVer" } else { Warn "WSL version not detected; continuing (podman machine will report if WSL2 is unusable)." }

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
    $out = & podman machine init --cpus $MachineCpus --memory $MachineMemoryMB --disk-size 30 $MachineName 2>&1
    $out | Write-Host
    if ($LASTEXITCODE -ne 0) {
        # Only steer to the virtualization fix when the failure is actually a
        # hypervisor problem — not a memory/disk/other config error.
        if ($out -match 'HCS_|hypervisor|virtualiz') { Show-VirtualizationHelp }
        Die "podman machine init failed (exit $LASTEXITCODE)."
    }
}

$running = (& podman machine list --format '{{.Name}} {{.Running}}' 2>$null) -replace "`0", ''
$isRunning = $running -split "\r?\n" | Where-Object {
    $parts = $_.Trim() -split '\s+'
    $parts.Count -ge 2 -and $parts[0].TrimEnd('*') -eq $MachineName -and $parts[1] -eq 'true'
}
if (-not $isRunning) {
    Info "Starting Podman machine '$MachineName'"
    $out = & podman machine start $MachineName 2>&1
    $out | Write-Host
    if ($LASTEXITCODE -ne 0) {
        if ($out -match 'HCS_|hypervisor|virtualiz') { Show-VirtualizationHelp }
        Die "podman machine start failed (exit $LASTEXITCODE)."
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
