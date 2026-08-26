# Adversarial tests for Sync-PendingRename. Arming makes Chrome MOVE
# new_chrome.exe onto chrome.exe, so arming at the wrong moment hands Chrome's own
# genuine launcher the wrapper's job and silently drops the fixed debug port until
# the next run. These assert we only ever arm when that move is safe.
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\lib\Common.ps1"
. "$repo\lib\Mirror.ps1"
. "$repo\lib\Update.ps1"

# Seed from whatever genuine launcher this machine actually has. Never pin a version:
# a pinned one stops existing at the next Chrome update and the suite silently skips,
# which is how a test quietly stops protecting anything.
$genuine = @(
  Get-ChildItem "$env:LOCALAPPDATA\ChromeFixedPort" -Directory -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0.0' } } |
    ForEach-Object { Join-Path $_.FullName 'chrome.exe' }
  Get-ChildItem "$env:LOCALAPPDATA\Google\Chrome\Application" -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName }
) | Where-Object { (Test-Path $_) -and (Test-Google $_) } | Select-Object -Last 1
if (-not $genuine) {
  Write-Host 'SKIP: no Google-signed launcher on this machine to seed from'
  exit 0
}
$ver = Get-FileVersion $genuine
Write-Host "seeding from $genuine (v$ver)"
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

function New-Fixture {
  $root = Join-Path $env:TEMP ('safety_' + [guid]::NewGuid().ToString('N'))
  $App  = Join-Path $root 'Application'
  $Mir  = Join-Path $root 'mirror'
  New-Item -ItemType Directory -Force -Path $App, (Join-Path $Mir "$ver\$ver") | Out-Null
  Set-Content -Path (Join-Path $Mir "$ver\chrome.exe")       -Value 'launcher' -Encoding ASCII
  Set-Content -Path (Join-Path $Mir "$ver\.mirror_complete") -Value $ver       -Encoding ASCII
  foreach ($f in 'chrome.dll', 'icudtl.dat') {
    Set-Content -Path (Join-Path $Mir "$ver\$ver\$f") -Value 'x' -Encoding ASCII
  }
  $env:CHROME_FIXED_PORT_MIRROR = $Mir
  return @{ Root = $root; App = $App; Mir = $Mir; Trigger = (Join-Path $Mir "$ver\new_chrome.exe") }
}
function Remove-Fixture($f) {
  Remove-Item Env:\CHROME_FIXED_PORT_MIRROR -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $f.Root -ErrorAction SilentlyContinue
}

# 1. THE DANGEROUS CASE. run.ps1 leaves new_chrome.exe genuine whenever that version
#    is not mirrored yet. Arming then would let Chrome move Google's own launcher
#    onto chrome.exe, replacing the wrapper and dropping --remote-debugging-port.
$f = New-Fixture
Copy-Item $genuine (Join-Path $f.App 'new_chrome.exe')
Sync-PendingRename $f.App $ver
Check 'a GENUINE new_chrome.exe is never armed (would evict the wrapper)' `
  (-not (Test-Path $f.Trigger))
Remove-Fixture $f

# 2. Once run.ps1 has primed it with the wrapper, arming is safe and must happen.
$f = New-Fixture
Set-Content -Path (Join-Path $f.App 'new_chrome.exe') -Value 'wrapper' -Encoding ASCII
Sync-PendingRename $f.App $ver
Check 'a wrapper-primed new_chrome.exe IS armed' (Test-Path $f.Trigger)
Remove-Fixture $f

# 3. Replacing the staged file afterwards must not write through to the mirror.
#    A hardlink shares data; only unlink-then-copy keeps the two independent.
$f = New-Fixture
Set-Content -Path (Join-Path $f.App 'new_chrome.exe') -Value 'wrapper-v1' -Encoding ASCII
Sync-PendingRename $f.App $ver
Set-Content -Path (Join-Path $f.App 'chrome.exe') -Value 'wrapper-v2' -Encoding ASCII
Set-FileFresh (Join-Path $f.App 'chrome.exe') (Join-Path $f.App 'new_chrome.exe')
Check 'replacing the staged file does not write through the mirror trigger' `
  ((Get-Content $f.Trigger -Raw).Trim() -eq 'wrapper-v1') "trigger now: $((Get-Content $f.Trigger -Raw).Trim())"
Remove-Fixture $f

# 4. Chrome consumed the staged file (it became chrome.exe). Disarm, do not re-arm.
$f = New-Fixture
Set-Content -Path (Join-Path $f.App 'new_chrome.exe') -Value 'wrapper' -Encoding ASCII
Sync-PendingRename $f.App $ver
Move-Item (Join-Path $f.App 'new_chrome.exe') (Join-Path $f.App 'chrome.exe')
Sync-PendingRename $f.App $ver
Check 'the trigger is disarmed after Chrome consumes the staged file' (-not (Test-Path $f.Trigger))
Sync-PendingRename $f.App $ver
Check 'a disarmed trigger stays disarmed on the next run' (-not (Test-Path $f.Trigger))
Remove-Fixture $f

# 5. Arming must never invalidate the mirror the wrapper resolves against.
$f = New-Fixture
Set-Content -Path (Join-Path $f.App 'new_chrome.exe') -Value 'wrapper' -Encoding ASCII
Sync-PendingRename $f.App $ver
Check 'the mirror is still complete and launchable while armed' `
  ((Test-Mirror $ver) -and (Test-Path (Join-Path $f.Mir "$ver\chrome.exe")))
Remove-Fixture $f

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall rename safety tests passed"
