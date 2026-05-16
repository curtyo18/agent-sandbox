<#
.SYNOPSIS
  Bootstrap script for the Claude Code sandbox. Run from an elevated PowerShell.
.DESCRIPTION
  Idempotent. Enables WSL2 features if needed, installs Ubuntu 24.04 if missing,
  invokes bootstrap.sh inside WSL to install Docker, build the image, and run the
  container.
.NOTES
  Re-run this script as many times as you like; it only mutates what's necessary.
#>

param([switch]$SkipReboot)

$ErrorActionPreference = 'Stop'
function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "WARN $msg" -ForegroundColor Yellow }
function Die ($msg) { Write-Host "ERR  $msg" -ForegroundColor Red; exit 1 }

$build = [Environment]::OSVersion.Version.Build
Info "Windows build: $build"
if ($build -lt 19041) { Die "Need Windows 10 build 19041+ for WSL2. Upgrade Windows first." }

# 1. Enable features.
$wsl = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State
$vmp = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State
$needReboot = $false
if ($wsl -ne 'Enabled') {
  Info "Enabling WSL feature"
  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart | Out-Null
  $needReboot = $true
}
if ($vmp -ne 'Enabled') {
  Info "Enabling VirtualMachinePlatform"
  Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null
  $needReboot = $true
}
if ($needReboot -and -not $SkipReboot) {
  Warn "Reboot required. Reboot then re-run this script."
  Read-Host "Press Enter to reboot now, Ctrl-C to abort"
  Restart-Computer
  exit 0
}

# 2. Default WSL version 2 + verify.
& wsl --set-default-version 2 | Out-Null
if (-not (wsl -l -q 2>$null | Select-String 'Ubuntu-24.04')) {
  Info "Installing Ubuntu-24.04 (this may take several minutes)"
  & wsl --install -d Ubuntu-24.04 --no-launch
  Warn "First-time Ubuntu launch: open 'Ubuntu-24.04' from Start once, set username/password, then re-run this script."
  exit 0
}

# 3. Hand off to inside-WSL bootstrap. Assume the user's WSL home has access to git/curl.
Info "Running bootstrap.sh inside WSL Ubuntu-24.04"
$sh = @"
set -e
if [ ! -d "`$HOME/code/agent-sandbox" ]; then
  mkdir -p "`$HOME/code"
  git clone https://github.com/curtyo18/agent-sandbox.git "`$HOME/code/agent-sandbox"
fi
cd "`$HOME/code/agent-sandbox" && git pull --ff-only || true
bash "`$HOME/code/agent-sandbox/bootstrap.sh"
"@

& wsl -d Ubuntu-24.04 -- bash -lc $sh

Info "Bootstrap complete."
Info "Next: docker exec -it claude-box bash -lc 'claude login'  (run inside WSL once)"
