# SignalK Universal Installer (v2) — Windows (WSL2) bootstrap.
#
# We install WSL2 + Debian, enable systemd inside it, provision a default
# user non-interactively, then hand off to the Linux installer running inside
# WSL. The container stack itself never runs on Windows directly; it runs in
# Linux under WSL2.
#
# Why the extra setup (vs. the macOS wrapper, which just runs the Linux
# installer in a Podman Machine that already has systemd): a fresh
# `wsl --install -d Debian` boots the legacy WSL init, NOT systemd. The whole
# stack is managed by `systemd --user` + `loginctl enable-linger`, so without
# `[boot] systemd=true` in /etc/wsl.conf the Linux installer's
# `loginctl enable-linger` / `systemctl --user` calls fail and the three
# engine containers never start. This script makes WSL satisfy what the Linux
# installer (preflight.sh / install.sh) already assumes.
#
# Requirements:
#   - Windows 11 (or Server 2022). The `[boot]` section of wsl.conf — our
#     systemd opt-in — is Windows 11 only.
#   - Store WSL >= 2.6.0 (2.5.x regressed the systemd user bus and broke
#     rootless podman's user units).
#
# Limitations:
#   - Native Windows (no WSL) is not supported (deferred per design doc).
#   - USB serial passthrough requires usbipd-win — link in docs/installation.md.

param(
    [string]$WslDistro = 'Debian',
    [string]$WslUser = 'signalk',
    [string]$InstallerVersion,
    [string]$InstallerBaseUrl = 'https://dirkwa.github.io/signalk-universal-installer'
)

if (-not $InstallerVersion) { $InstallerVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { '0.0.0-scaffold' } }

$ErrorActionPreference = 'Stop'

function Info($msg)    { Write-Host "[i] $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Warning $msg }
function Section($msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor White }
function Die($msg)     { Write-Error $msg; exit 1 }

# Run a bash snippet inside the WSL distro and return its stdout (trimmed).
# We always go through `bash -lc` so PATH/login setup applies. The snippet is
# passed verbatim — keep every `$` you want bash to see in single-quoted
# PowerShell here-strings so PowerShell doesn't expand it first.
function Invoke-WslBash {
    param(
        [Parameter(Mandatory)] [string]$Script,
        [string]$AsUser  # empty => default user
    )
    $wslArgs = @('-d', $WslDistro)
    if ($AsUser) { $wslArgs += @('--user', $AsUser) }
    $wslArgs += @('--', 'bash', '-lc', $Script)
    $out = & wsl @wslArgs
    return ($out | Out-String).Trim()
}

# True when a Windows feature WSL2 needs (VirtualMachinePlatform, and the WSL
# optional component on older builds) was just enabled but the box hasn't
# rebooted yet. `wsl --install` / `wsl --update` enable these and report that
# changes take effect only after a restart — until then `wsl --version` and any
# `wsl` command can't run, so we must detect this and stop BEFORE probing WSL.
function Test-RebootPending {
    foreach ($f in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'EnablePending') { return $true }
    }
    return $false
}

# Print the reboot-then-re-run guidance and exit cleanly. The installer is
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

Section "SignalK Universal Installer v$InstallerVersion (Windows/WSL2)"

# 1. Admin + Windows 11 check
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "This script must run as Administrator. Right-click PowerShell and 'Run as administrator'."
}
Ok "Running as Administrator"

# Windows 11 is build 22000+. The `[boot] systemd=true` opt-in we depend on is
# documented as Windows 11 / Server 2022 only — on Windows 10 it silently does
# nothing, leaving the stack unable to start. Fail loudly rather than ship a
# non-systemd distro.
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 22000) {
    Die "Windows 11 (build 22000+) is required (current build $build). The systemd opt-in this installer needs (/etc/wsl.conf [boot] systemd=true) is Windows 11 only."
}
Ok "Windows 11 build $build"

# 2. Modern WSL. systemd needs Store WSL; the systemd user bus that rootless
# podman relies on was broken in WSL 2.5.x and fixed in 2.6.0.
Section "WSL version"
function Get-WslVersion {
    # `wsl --version` (Store WSL) prints localized "WSL version: X.Y.Z..." lines.
    # Inbox WSL rejects --version with an error → return $null so the caller updates.
    try {
        $raw = & wsl --version 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $text = ($raw | Out-String)
        $m = [regex]::Match($text, '(\d+)\.(\d+)\.(\d+)')
        if ($m.Success) { return [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) }
        return $null
    } catch { return $null }
}

# If a prior run (or `wsl --update` below) enabled VirtualMachinePlatform but
# we haven't rebooted, `wsl --version` can't run yet — so check for a pending
# reboot first and stop, rather than misreading it as "WSL too old".
if (Test-RebootPending) { Stop-ForReboot }

$minWsl = [version]'2.6.0'
$wslVer = Get-WslVersion
if (-not $wslVer -or $wslVer -lt $minWsl) {
    Info "Updating WSL (need >= $minWsl; found $(if ($wslVer) { $wslVer } else { 'inbox/older' }))"
    & wsl --update
    # `wsl --update` can enable VirtualMachinePlatform, which needs a reboot
    # before WSL can report a version. Re-check for a pending reboot here so we
    # send the user to reboot instead of dying on the now-unavailable
    # `wsl --version`.
    if (Test-RebootPending) { Stop-ForReboot }
    $wslVer = Get-WslVersion
    if (-not $wslVer -or $wslVer -lt $minWsl) {
        Die "WSL >= $minWsl is required but is still $(if ($wslVer) { $wslVer } else { 'not detected' }) after 'wsl --update'. Install WSL from the Microsoft Store, then re-run."
    }
}
Ok "WSL $wslVer"

# 3. WSL2 default + distro install
Section "WSL2 distro"
& wsl --set-default-version 2 2>$null | Out-Null  # defensive; never converts an existing distro
$wslList = & wsl --list --quiet 2>$null
$hasDistro = $wslList -and ($wslList -match "(?i)^$WslDistro$")
if (-not $hasDistro) {
    Info "Installing WSL distro '$WslDistro' (a reboot may be required)"
    # Plain `wsl --install -d` (NOT --no-launch): --no-launch suppresses the
    # per-distro launcher that actually REGISTERS the distro, so the distro
    # would never appear in `wsl -l -v` and every later `wsl -d $WslDistro …`
    # call would fail "distro not found". With a plain install the distro is
    # registered; in a non-interactive context (iwr|iex, no console) the OOBE
    # username/password prompt can't run, so the distro ends up root-only with
    # no default user — which is fine here: step 6 provisions the user as root
    # idempotently and sets [user] default=.
    & wsl --install -d $WslDistro
    if ($LASTEXITCODE -ne 0) {
        Die "wsl --install failed (exit $LASTEXITCODE). Reboot and re-run."
    }
} else {
    Ok "WSL distro '$WslDistro' already installed"
}

# 4. Reboot detection — instruct re-run (idempotent), don't auto-reboot.
# `wsl --install` enables the VirtualMachinePlatform Windows feature; that
# needs a reboot before WSL2 can run. There's no dedicated WSL exit code, so
# gate on the feature's pending state.
if (Test-RebootPending) { Stop-ForReboot }

# 5. Assert the distro is Debian trixie (or newer). An existing WSL Debian is
# never auto-upgraded, so a long-lived box could be on bookworm — which ships
# podman 4.3.1 with no Quadlet support and is hard-blocked by the Linux
# installer's preflight. Fresh installs are trixie and pass.
Section "Distro release"
$codename = Invoke-WslBash -AsUser 'root' -Script @'
. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-unknown}"
'@
if ($codename -eq 'bookworm') {
    Die @"
The '$WslDistro' WSL distro is Debian 12 (bookworm), which ships podman 4.3.1 with no Quadlet support — the SignalK stack cannot run on it.

Upgrade the distro to Debian 13 (trixie) inside WSL, or unregister and reinstall it:
  wsl --unregister $WslDistro
  (then re-run this installer to get a fresh trixie image)
"@
}
Ok "Distro release: $codename"

# 6. Enable systemd + provision the default user, all as root (no interactive
# sudo: WSL Debian's default user has password-prompting sudo, which hangs in
# a non-interactive `bash -lc`). root always resolves, needs no sudo.
Section "Enabling systemd in WSL"

# We interpolate the username into a single-quoted bash assignment, so validate
# it first to keep the interpolation from injecting shell.
if ($WslUser -notmatch '^[a-z_][a-z0-9_-]*$') {
    Die "Invalid -WslUser '$WslUser' (must be a valid Linux username: lowercase, starts with a letter/underscore)."
}

# NOTE: this here-string is single-quoted (@' ... '@) so PowerShell does NOT
# expand $-variables — every $ below is for bash. The one value we inject is
# the validated username, spliced in as a literal after the here-string.
$rootSetup = @'
set -euo pipefail
SK_USER="__SK_USER__"

# Ensure systemd + uidmap (rootless podman needs newuidmap/newgidmap).
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y systemd systemd-sysv uidmap

# Decide the default user. Plain `wsl --install` may have run the OOBE and
# created its own uid-1000 user (whatever the operator typed); a non-interactive
# install leaves the distro root-only. Prefer an existing uid-1000 user so the
# [user] default= and sudoers drop-in target a real account; otherwise create
# SK_USER.
existing="$(getent passwd 1000 | cut -d: -f1)"
if [ -n "$existing" ]; then
    SK_USER="$existing"
elif ! id "$SK_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos '' "$SK_USER"
    # Known password so interactive `wsl -d Debian` logins and a real-terminal
    # sudo work. The installer itself doesn't use it (privileged steps run as
    # root; the Linux installer's own sudo is covered by the sudoers drop-in).
    echo "${SK_USER}:signalk" | chpasswd
fi
usermod -aG sudo "$SK_USER"

# The Linux installer runs `sudo` for its few system steps (apt, sysctl,
# journald, cgroup-delegation override). We invoke it non-interactively over
# `bash -lc`, where a password prompt would hang — so grant passwordless sudo.
install -d -m 0755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SK_USER" > "/etc/sudoers.d/90-${SK_USER}-nopasswd"
chmod 0440 "/etc/sudoers.d/90-${SK_USER}-nopasswd"

# Enable systemd and make / a shared mount (required for rootless podman bind
# propagation), and set the WSL default user. Only (re)write the [boot] block
# if systemd isn't already enabled, to preserve any hand edits.
if ! grep -qs '^systemd=true' /etc/wsl.conf; then
    cat > /etc/wsl.conf <<EOF
[boot]
systemd=true
command="mount --make-rshared /"

[user]
default=${SK_USER}
EOF
fi
printf 'resolved default user: %s\n' "$SK_USER"
printf 'wsl.conf:\n'
cat /etc/wsl.conf
'@
$rootSetup = $rootSetup.Replace('__SK_USER__', $WslUser)

Invoke-WslBash -AsUser 'root' -Script $rootSetup | Write-Host
if ($LASTEXITCODE -ne 0) { Die "Failed to configure systemd / user inside WSL (exit $LASTEXITCODE)." }
Ok "Wrote /etc/wsl.conf (systemd=true) and ensured a default sudo user"

# 7. Apply (terminate so wsl.conf is re-read) and verify systemd is PID 1.
Section "Applying systemd"
& wsl --terminate $WslDistro 2>$null | Out-Null
$pid1 = Invoke-WslBash -Script 'ps -p 1 -o comm='
if ($pid1 -ne 'systemd') {
    $conf = Invoke-WslBash -AsUser 'root' -Script 'cat /etc/wsl.conf 2>/dev/null || echo "(no wsl.conf)"'
    Die @"
systemd did not come up as PID 1 after enabling it (ps -p 1 -o comm= = '$pid1', expected 'systemd').

Current /etc/wsl.conf:
$conf

Try 'wsl --shutdown' from PowerShell, then re-run this installer. If it persists, confirm WSL >= 2.6.0 and that this is Windows 11.
"@
}
Ok "systemd is PID 1"

# 8. Verify linger + the user session bus before handing off. The Linux
# installer's `loginctl enable-linger` / `systemctl --user` calls need a live
# per-user systemd manager. WSL has historically created /run/user/<uid>
# root-owned or torn down the user bus — catch that here with a clear message
# instead of letting the Linux installer trip on it.
Section "Verifying user session"
$busCheck = Invoke-WslBash -Script @'
set -euo pipefail
uid=$(id -u)
loginctl enable-linger "$USER" >/dev/null 2>&1 || true
linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo "")
runtime="/run/user/${uid}"
owner=$(stat -c '%U' "$runtime" 2>/dev/null || echo "?")
bus="absent"; [ -S "${runtime}/bus" ] && bus="present"
printf 'linger=%s runtime_owner=%s user=%s bus=%s' "${linger:-no}" "$owner" "$USER" "$bus"
'@
Info $busCheck
if ($busCheck -notmatch 'linger=yes' -or $busCheck -notmatch 'bus=present') {
    Die @"
The WSL user session isn't fully up ($busCheck). The Linux installer needs a working 'systemd --user' bus and lingering enabled.

Try 'wsl --shutdown' from PowerShell and re-run. If /run/user/<uid> is owned by root, this is a known WSL bug — see docs/installation.md (Windows troubleshooting).
"@
}
Ok "linger enabled and user bus present"

# 9. Hand off to the Linux installer (as the provisioned default user).
Section "Bootstrapping inside WSL ($WslDistro)"
$linuxUrl = "$InstallerBaseUrl/installer/linux/install.sh"
Info "Running: $linuxUrl inside WSL"

# Single-quoted here-string: $-vars are for bash. The two installer values are
# forwarded via WSLENV (below) so we never have to escape them into the string.
$handoff = @'
set -euo pipefail
curl -fsSL "$INSTALLER_BASE_URL/installer/linux/install.sh" -o /tmp/sk-install.sh
chmod +x /tmp/sk-install.sh
bash /tmp/sk-install.sh
'@
$env:INSTALLER_VERSION = $InstallerVersion
$env:INSTALLER_BASE_URL = $InstallerBaseUrl
$env:WSLENV = 'INSTALLER_VERSION/u:INSTALLER_BASE_URL/u'
$handoffArgs = @('-d', $WslDistro, '--', 'bash', '-lc', $handoff)
& wsl @handoffArgs

if ($LASTEXITCODE -ne 0) {
    Die "Linux installer exited with code $LASTEXITCODE inside WSL."
}

# Done
@"

OK - SignalK is up inside WSL2 ($WslDistro).

  SignalK admin UI : http://localhost:3000
  Updater Console  : http://localhost:3003
  Doctor Console   : http://localhost:3004

WSL2 forwards localhost ports to the host automatically.

To open a shell in WSL for diagnostics:
  wsl -d $WslDistro
  ~/.local/bin/signalk-recovery status

USB serial passthrough requires usbipd-win on the Windows side; see
docs/installation.md (section "Windows USB").
"@ | Write-Host
