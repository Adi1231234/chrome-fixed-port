# Behavioural test for Sync-PendingRename: is Chrome's own rename armed exactly when
# an update is staged, disarmed once it is finished, and harmless to the mirror?
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\lib\Common.ps1"
. "$repo\lib\Mirror.ps1"
. "$repo\lib\Update.ps1"

$ver    = '151.0.7922.173'
$root   = Join-Path $env:TEMP ('trigtest_' + [guid]::NewGuid().ToString('N'))
$App    = Join-Path $root 'Application'
$Mir    = Join-Path $root 'mirror'
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

# A mirror shaped exactly like Sync-Mirror leaves one.
New-Item -ItemType Directory -Force -Path $App, (Join-Path $Mir "$ver\$ver") | Out-Null
$env:CHROME_FIXED_PORT_MIRROR = $Mir
Set-Content -Path (Join-Path $Mir "$ver\chrome.exe")        -Value 'launcher' -Encoding ASCII
Set-Content -Path (Join-Path $Mir "$ver\.mirror_complete")  -Value $ver       -Encoding ASCII
foreach ($f in 'chrome.dll', 'icudtl.dat') {
  Set-Content -Path (Join-Path $Mir "$ver\$ver\$f") -Value 'x' -Encoding ASCII
}
$trigger = Join-Path $Mir "$ver\new_chrome.exe"
$staged  = Join-Path $App 'new_chrome.exe'

Check 'the mirror starts out valid' (Test-Mirror $ver)

# 1. nothing staged -> nothing armed
Sync-PendingRename $App $ver
Check 'no staged update leaves the mirror untouched' (-not (Test-Path $trigger))

# 2. an update staged -> armed, at the exact path Chrome tests
Set-Content -Path $staged -Value 'genuine-new-chrome' -Encoding ASCII
Sync-PendingRename $App $ver
Check 'a staged update arms new_chrome.exe in the mirror' (Test-Path $trigger)
Check 'the trigger carries the staged binary, not a placeholder' `
  ((Get-Content $trigger -Raw).Trim() -eq 'genuine-new-chrome') "got: $((Get-Content $trigger -Raw).Trim())"

# 3. arming must not invalidate the mirror
Check 'the mirror is still valid once armed' (Test-Mirror $ver)

# 4. idempotent
$before = (Get-Item $trigger).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
Sync-PendingRename $App $ver
Check 'a second run does not re-arm' ((Get-Item $trigger).LastWriteTimeUtc -eq $before)

# 5. Chrome finished the rename (staged file consumed) -> disarm
Remove-Item $staged -Force
Sync-PendingRename $App $ver
Check 'the trigger is removed once the update is finished' (-not (Test-Path $trigger))
Check 'disarming leaves the mirror valid' (Test-Mirror $ver)

# 6. a mirror version that does not exist must not throw or create stray trees
Set-Content -Path $staged -Value 'genuine-new-chrome' -Encoding ASCII
try { Sync-PendingRename $App '99.0.0.1'; $ok = $true } catch { $ok = $false }
Check 'an unknown mirror version fails soft' $ok
Check 'no stray mirror directory was created' (-not (Test-Path (Join-Path $Mir '99.0.0.1')))

Remove-Item Env:\CHROME_FIXED_PORT_MIRROR -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall rename trigger tests passed"
