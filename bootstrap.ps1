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

param(
  [switch]$SkipReboot,
  # WSL username whose home holds the clone. Defaults to the WSL default user
  # (resolved below once WSL is confirmed installed); falls back to $env:USERNAME.
  [string]$WslUser,
  # WSL path (not a Windows path) that holds projects; defaults to the user's home.
  [string]$ProjectsPath,
  [string]$AgentSandboxUrl = "https://github.com/your-username/agent-sandbox.git"
)

$ErrorActionPreference = 'Stop'
# wsl.exe emits UTF-16LE by default; under Windows PowerShell 5.1 that arrives
# NUL-interleaved and breaks string matching (e.g. distro detection). WSL_UTF8=1
# makes wsl.exe emit UTF-8 for all invocations below.
$env:WSL_UTF8 = '1'
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
if ($LASTEXITCODE -ne 0) { Die "wsl --set-default-version 2 failed (exit $LASTEXITCODE)." }
# Strip any stray NULs defensively in case WSL_UTF8 isn't honored on older builds.
$distros = (wsl -l -q 2>$null) -replace "`0", ''
if (-not ($distros | Select-String 'Ubuntu-24.04')) {
  Info "Installing Ubuntu-24.04 (this may take several minutes)"
  & wsl --install -d Ubuntu-24.04 --no-launch
  Warn "First-time Ubuntu launch: open 'Ubuntu-24.04' from Start once, set username/password, then re-run this script."
  exit 0
}

# 3. Hand off to inside-WSL bootstrap. Assume the user's WSL home has access to git/curl.
Info "Running bootstrap.sh inside WSL Ubuntu-24.04"

# Resolve the WSL user / projects path (WSL paths, not Windows paths). Defaults
# follow bootstrap.sh's env-driven philosophy: derive from the WSL default user,
# falling back to $env:USERNAME, and default ProjectsPath to ~/projects in WSL.
if (-not $WslUser) {
  $WslUser = ((wsl -d Ubuntu-24.04 -- sh -c 'echo "$USER"' 2>$null) -replace "`0", '').Trim()
  if ($LASTEXITCODE -ne 0 -or -not $WslUser) { $WslUser = $env:USERNAME }
}
if (-not $ProjectsPath) { $ProjectsPath = "/home/$WslUser/projects" }
$RepoDir = "$ProjectsPath/agent-sandbox"

$sh = @"
set -e
REPO_DIR=$RepoDir
if [ ! -d "`$REPO_DIR" ]; then
  mkdir -p $ProjectsPath
  git clone $AgentSandboxUrl "`$REPO_DIR"
fi
cd "`$REPO_DIR" && git pull --ff-only || true
bash "`$REPO_DIR/bootstrap.sh"
"@

& wsl -d Ubuntu-24.04 -- bash -lc $sh
# $ErrorActionPreference='Stop' does NOT catch native command failures, so check
# the real exit status explicitly rather than printing "Bootstrap complete."
if ($LASTEXITCODE -ne 0) { Die "bootstrap.sh inside WSL failed (exit $LASTEXITCODE)." }

Info "Bootstrap complete."
Info "Next: open WSL, run: docker exec -it <container-name> bash -lc 'claude login'"
