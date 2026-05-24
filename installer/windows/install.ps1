# SignalK Universal Installer (v2) — Windows (WSL2) bootstrap.
#
# We install WSL2 + Debian if not present, then hand off to the Linux
# installer running inside WSL. The container stack itself never runs on
# Windows directly; it runs in Linux under WSL2.
#
# Limitations:
#   - Native Windows (no WSL) is not supported (deferred per design doc).
#   - USB serial passthrough requires usbipd-win — link in docs/installation.md.

param(
    [string]$WslDistro = 'Debian',
    [string]$InstallerVersion,
    [string]$InstallerBaseUrl = 'https://dirkwa.github.io/signalk-universal-installer'
)

if (-not $InstallerVersion) { $InstallerVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { 'v0.1.0-15-gf53d015' } }

$ErrorActionPreference = 'Stop'

function Info($msg)    { Write-Host "[i] $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Warning $msg }
function Section($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor White }
function Die($msg)     { Write-Error $msg; exit 1 }

Section "SignalK Universal Installer v$InstallerVersion (Windows/WSL2)"

# 1. Admin check
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "This script must run as Administrator. Right-click PowerShell and 'Run as administrator'."
}
Ok "Running as Administrator"

# 2. Windows version + virtualization
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 19041) {
    Die "Windows 10 build 19041+ or Windows 11 required (current build $build)."
}
Ok "Windows build $build supports WSL2"

# 3. WSL2 install / verify
Section "WSL2"
$wslList = & wsl --list --quiet 2>$null
$hasDistro = $wslList -and ($wslList -match "(?i)^$WslDistro$")
if (-not $hasDistro) {
    Info "Installing WSL with $WslDistro (a reboot may be required)"
    & wsl --install -d $WslDistro
    if ($LASTEXITCODE -ne 0) {
        Die "wsl --install failed (exit $LASTEXITCODE). Reboot and re-run."
    }
    Warn "If this is your first WSL install, reboot now, then re-run this script."
} else {
    Ok "WSL distro '$WslDistro' already installed"
}

# 4. Hand off to the Linux installer inside WSL
Section "Bootstrapping inside WSL ($WslDistro)"
$linuxUrl = "$InstallerBaseUrl/installer/linux/install.sh"
Info "Running: $linuxUrl inside WSL"

# Note: we run as the default WSL user, not root. The Linux installer
# uses sudo where needed; the user must have sudo NOPASSWD or be ready
# to type their password.
$cmd = @"
set -euo pipefail
curl -fsSL '$linuxUrl' -o /tmp/sk-install.sh
chmod +x /tmp/sk-install.sh
INSTALLER_VERSION='$InstallerVersion' INSTALLER_BASE_URL='$InstallerBaseUrl' bash /tmp/sk-install.sh
"@

& wsl -d $WslDistro -- bash -lc "$cmd"

if ($LASTEXITCODE -ne 0) {
    Die "Linux installer exited with code $LASTEXITCODE inside WSL."
}

# 5. Done
@"

OK - SignalK is up inside WSL2 ($WslDistro).

  SignalK admin UI : http://localhost:3000
  Updater Console  : http://localhost:3003
  Doctor Console   : http://localhost:3004

WSL2 forwards localhost ports to the host automatically.

To SSH into WSL for diagnostics:
  wsl -d $WslDistro
  ~/.local/bin/signalk-recovery status

USB serial passthrough requires usbipd-win on the Windows side; see
docs/installation.md (section "Windows USB").
"@ | Write-Host
