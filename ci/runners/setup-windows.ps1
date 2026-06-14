# Set up this Windows box as a self-hosted GitHub Actions runner for chaim354/tinkerex.
# This box runs the WinFsp + CfAPI builds AND the live CfAPI smoke (the regression net).
# Run in an ELEVATED PowerShell (Administrator).
# Usage:  ./ci/runners/setup-windows.ps1 -Token <REGISTRATION_TOKEN>
#   gh api -X POST repos/chaim354/tinkerex/actions/runners/registration-token --jq .token
param(
  [Parameter(Mandatory = $true)][string]$Token,
  # NOT under the user profile: the service runs as NT AUTHORITY\NETWORK SERVICE, which cannot
  # read C:\Users\<you> (the runner validates read/execute up the whole path hierarchy and fails
  # to start with "Access to the path 'C:\Users\<you>' is denied"). A top-level dir is readable.
  [string]$RunnerDir = "C:\actions-runner-tinkerex"
)
$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/chaim354/tinkerex"
$Labels  = "self-hosted,windows,maker-windows"

Write-Host "==> Installing prereqs via Chocolatey (LLVM for winfsp-sys bindgen; WinFsp driver/SDK)"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = 3072
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
# git provides bash — actions like dtolnay/rust-toolchain run `shell: bash` and fail with
# "bash: command not found" otherwise. (A user-scoped Git install isn't on the NETWORK SERVICE
# service PATH; choco installs machine-wide.)
choco install -y --no-progress llvm winfsp jq git

# Ensure Git's bash dir is on the MACHINE PATH (choco's git only adds \cmd, not \bin where
# bash.exe lives). The service re-reads the machine PATH on (re)start, below.
$gitBin = "C:\Program Files\Git\bin"
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$gitBin*") {
  [Environment]::SetEnvironmentVariable("Path", "$machinePath;$gitBin", "Machine")
  $env:Path = "$env:Path;$gitBin"
}

Write-Host "==> Installing Rust (rustup) if missing"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
  Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile "$env:TEMP\rustup-init.exe"
  & "$env:TEMP\rustup-init.exe" -y
  $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
}

Write-Host "==> Downloading the latest GitHub Actions runner (win-x64)"
New-Item -ItemType Directory -Force -Path $RunnerDir | Out-Null
Set-Location $RunnerDir
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest"
$version = $rel.tag_name.TrimStart("v")
$zip = "actions-runner-win-x64-$version.zip"
if (-not (Test-Path $zip)) {
  Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$version/$zip" -OutFile $zip
}
# Extract idempotently. NOTE: ZipFile.ExtractToDirectory's 3-arg overload is
# (src, dest, Encoding) on Windows PowerShell's .NET Framework — the overwrite-bool overload
# is .NET Core only — so use Expand-Archive -Force, which overwrites and works on PS 5.1+.
Expand-Archive -Path $zip -DestinationPath $RunnerDir -Force

Write-Host "==> Configuring the runner (labels: $Labels)"
./config.cmd --unattended --replace `
  --url $RepoUrl --token $Token `
  --name "$env:COMPUTERNAME-maker-windows" --labels $Labels `
  --runasservice

Write-Host "==> Done. The runner installs as a Windows service and starts automatically."
Write-Host "    Verify: gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[].name'"
Write-Host "    NOTE: the live smoke needs the deployed server reachable at http://192.168.1.95"
