# SignalK Universal Installer (v2) — Windows (WSL2) scaffold
$InstallerVersion = if ($env:INSTALLER_VERSION) { $env:INSTALLER_VERSION } else { 'cae291e' }

$ErrorActionPreference = 'Stop'

@"
SignalK Universal Installer v$InstallerVersion (Windows/WSL2) - SCAFFOLD ONLY.

This release of the script does not install anything yet. The real flow
(WSL2 + Debian inside WSL + Linux installer handoff) is being built in
the signalk-universal-installer repo.

Status: https://github.com/dirkwa/signalk-universal-installer
"@ | Write-Host

exit 0
