# Live Windows CfAPI smoke - the regression net for Phase 2b (Task A4).
# Registers a real sync root, enumerates, hydrates, then exercises the write path
# (new file / edit / delete / rename) and ASSERTS each round-tripped to the server via
# the control plane (`tree_names` example). Run on a self-hosted Windows runner with the
# deployed server reachable; exits non-zero on any failure.
#
# Usage:
#   ./client/test-conformance/cfapi-smoke.ps1 [-Server http://192.168.1.95]
# Requires: rust toolchain, WinFsp + LLVM (sync-engine pulls fs-winfsp), network to $Server
# and to the chunk store (SeaweedFS) for hydration.
param(
  [string]$Server = $(if ($env:SERVER_URL) { $env:SERVER_URL } else { "http://192.168.1.95" })
)
$ErrorActionPreference = "Stop"
$failures = @()
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:failures += $name }
}

$repo   = (Resolve-Path "$PSScriptRoot\..\..").Path
$engine = "$repo\client\sync-engine\Cargo.toml"
$runid  = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
# UNIQUE per-run paths. A CfAPI sync root hard-killed by a prior run stays registered and
# refuses deletion, so we never reuse the same folder (reusing it threw RemoveItemIOError).
$root   = "$env:USERPROFILE\MakerCF-smoke-$runid"
$db     = "$env:TEMP\maker-cf-smoke-$runid.db"
$chunks = "$env:TEMP\maker-cf-smoke-$runid-chunks"
$log    = "$env:TEMP\cfapi-smoke-$runid.log"

Write-Host "== CfAPI smoke == server=$Server root=$root run=$runid"

# Best-effort sweep of leftover sync roots from prior runs. A still-registered root may refuse
# deletion (IOException) - that must NOT abort the smoke, hence SilentlyContinue.
Get-ChildItem "$env:USERPROFILE\MakerCF-smoke-*" -Directory -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "==> Building maker-cfsyncd + examples (mac_host, tree_names)"
& cargo build --manifest-path $engine --bin maker-cfsyncd --example mac_host --example tree_names
if ($LASTEXITCODE -ne 0) { throw "build failed" }
$cfsyncd = "$repo\client\sync-engine\target\debug\maker-cfsyncd.exe"

# --- 1. Seed a library + mint a device token (mac_host runs anywhere) -----------------
Write-Host "==> Seeding library via mac_host"
$env:SERVER_URL = $Server
$env:EMAIL = "smoke-$runid@example.com"
$seed = & cargo run --quiet --manifest-path $engine --example mac_host 2>&1
$seed | Out-Host
$tokenLine = $seed | Select-String -Pattern '^WINDOWS_DEVICE_TOKEN=(.+)$'
if (-not $tokenLine) { throw "could not parse WINDOWS_DEVICE_TOKEN from mac_host output" }
$token = $tokenLine.Matches[0].Groups[1].Value.Trim()
Write-Host "  got device token ($($token.Length) chars)"

function ServerTree { & cargo run --quiet --manifest-path $engine --example tree_names -- $Server $token 2>$null }

# --- 2. Control-plane baseline: the seeded files are on the server ----------------------
$baseline = ServerTree
Write-Host "==> Server tree (baseline):`n$($baseline -join "`n")"
$seededFile = ($baseline | Select-String -Pattern '^file  (.+)$' | Select-Object -First 1).Matches[0].Groups[1].Value
Check "baseline: server has at least one seeded file" ([bool]$seededFile)

# --- 3. Mount the CfAPI sync root (background) -----------------------------------------
Write-Host "==> Mounting CfAPI sync root (maker-cfsyncd) -> $log"
$proc = Start-Process -FilePath $cfsyncd -ArgumentList @($root, $db, $chunks, $Server, $token) `
  -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 6   # let it register + pull the snapshot

try {
  # --- 4. Enumerate (FETCH_PLACEHOLDERS) ---------------------------------------------
  $listed = Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
  Write-Host "==> Explorer enumeration: $($listed -join ', ')"
  Check "enumerate: sync root lists files" ($listed.Count -gt 0)

  # --- 5. Hydrate (FETCH_DATA) on the first seeded file ------------------------------
  $leaf = Split-Path $seededFile -Leaf
  $onDisk = Join-Path $root $leaf
  $content = if (Test-Path $onDisk) { Get-Content -Raw -Path $onDisk -ErrorAction SilentlyContinue } else { $null }
  Check "hydrate: first file opens with non-empty content" ([bool]$content)

  # --- 6. Write path: new / edit / delete / rename ----------------------------------
  # -EA SilentlyContinue so a failed op records a Check FAIL instead of aborting before the
  # verdict + daemon-log dump (the diagnostics live in the finally block).
  $newFile = Join-Path $root "smoke-new-$runid.txt"
  Set-Content -Path $newFile -Value "created by smoke $runid" -ErrorAction SilentlyContinue   # NEW FILE (B1)
  if (Test-Path $onDisk) { Add-Content -Path $onDisk -Value "edit-$runid" -ErrorAction SilentlyContinue }  # EDIT
  $toDelete = $listed | Where-Object { $_ -ne $leaf } | Select-Object -First 1
  if ($toDelete) { Remove-Item -Path (Join-Path $root $toDelete) -Force -ErrorAction SilentlyContinue }    # DELETE (B2)
  $renameSrc = $listed | Where-Object { $_ -ne $leaf -and $_ -ne $toDelete } | Select-Object -First 1
  $renamedTo = "smoke-renamed-$runid.txt"
  if ($renameSrc) { Rename-Item -Path (Join-Path $root $renameSrc) -NewName $renamedTo -ErrorAction SilentlyContinue }  # RENAME (B3)

  Write-Host "==> Local ops done (new=$(Split-Path $newFile -Leaf) edit=$leaf delete=$toDelete rename=$renameSrc->$renamedTo); waiting for push"
  Start-Sleep -Seconds 10   # let the sync loop drain the outbox + push
}
finally {
  # --- 7. Stop the daemon (Drop disconnects; hydrated files persist) -----------------
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  Start-Sleep -Seconds 2
  # Always surface the daemon's own logs - they say whether the sync root registered and what
  # the CfAPI callbacks did (or why the mount produced an empty enumeration).
  Write-Host "==> maker-cfsyncd stdout ($log):"
  if (Test-Path $log) { Get-Content $log | Out-Host } else { Write-Host "  (no stdout captured)" }
  if ((Test-Path "$log.err") -and (Get-Item "$log.err").Length -gt 0) {
    Write-Host "==> maker-cfsyncd stderr:"; Get-Content "$log.err" | Out-Host
  }
}

# --- 8. Assert the write path reached the server --------------------------------------
$after = ServerTree
Write-Host "==> Server tree (after):`n$($after -join "`n")"
$names = $after | ForEach-Object { ($_ -replace '^\w+\s+', '') } | ForEach-Object { Split-Path $_ -Leaf }

Check "new file pushed (B1): smoke-new-$runid.txt on server" ($names -contains "smoke-new-$runid.txt")
if ($toDelete)  { Check "delete pushed (B2): $toDelete gone from server" (-not ($names -contains $toDelete)) }
if ($renameSrc) {
  Check "rename pushed (B3): $renamedTo on server"      ($names -contains $renamedTo)
  Check "rename pushed (B3): old name $renameSrc gone"  (-not ($names -contains $renameSrc))
}

# --- Verdict --------------------------------------------------------------------------
if ($failures.Count -gt 0) {
  Write-Host "`nSMOKE FAILED: $($failures -join '; ')" -ForegroundColor Red
  Write-Host "daemon log: $log (+ .err)"
  if (Test-Path $log) { Write-Host "---- tail ----"; Get-Content -Tail 40 $log }
  exit 1
}
Write-Host "`nSMOKE PASSED - register + enumerate + hydrate + new/edit/delete/rename round-tripped" -ForegroundColor Green
exit 0
