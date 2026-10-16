# Behavioural test for Remove-LegacyState: the old design's leftovers go, Google's own
# files stay, chrome.exe comes back genuine, and nothing in use is touched.
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\lib\Common.ps1"
. "$repo\lib\Mirror.ps1"
. "$repo\lib\Legacy.ps1"
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

# Seed from whatever genuine launcher this machine has. Never pin a version: a pinned
# one stops existing at the next Chrome update and the suite would silently skip.
$genuine = @(
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  Get-ChildItem "$env:LOCALAPPDATA\ChromeFixedPort" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'chrome.exe' }
) | Where-Object { (Test-Path $_) -and (Test-Google $_) } | Select-Object -First 1
if (-not $genuine) { Write-Host 'SKIP: no Google-signed launcher on this machine to seed from'; exit 0 }
$ver = Get-FileVersion $genuine

$root = Join-Path $env:TEMP ('legacytest_' + [guid]::NewGuid().ToString('N'))
$app  = Join-Path $root 'Application'
$env:CHROME_FIXED_PORT_MIRROR = Join-Path $root 'mirror'
function New-Fixture {
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force (Join-Path $app $ver), (Join-Path $env:CHROME_FIXED_PORT_MIRROR $ver) | Out-Null
  foreach ($f in $RequiredFiles) { Set-Content (Join-Path (Join-Path $app $ver) $f) 'x' }
  Set-Content (Join-Path $app 'chrome.exe') 'old wrapper'
  Set-Content (Join-Path $app 'new_chrome.exe') 'primed wrapper'
  Set-Content (Join-Path $app '.wrapper_ver') 'abcd1234|1.2.3.4'
  Copy-Item $genuine (Join-Path $app "chrome_real_$ver.exe")
  Set-Content (Join-Path (Join-Path $env:CHROME_FIXED_PORT_MIRROR $ver) 'new_chrome.exe') 'trigger'
}
$seeds = { @{ $ver = (Join-Path $app "chrome_real_$ver.exe") } }

try {
  New-Fixture
  Remove-LegacyState $app (& $seeds) | Out-Null
  $exe = Join-Path $app 'chrome.exe'
  Check 'chrome.exe is Google-signed again' (Test-Google $exe)
  Check 'and is the version whose directory is present' ((Get-FileVersion $exe) -eq $ver) (Get-FileVersion $exe)
  Check 'the wrapper primed as new_chrome.exe is gone' (-not (Test-Path (Join-Path $app 'new_chrome.exe')))
  Check 'the old .wrapper_ver marker is gone' (-not (Test-Path (Join-Path $app '.wrapper_ver')))
  Check 'the old rebuild seed is gone' (-not (Test-Path (Join-Path $app "chrome_real_$ver.exe")))
  Check 'the rename trigger in the mirror is gone' (-not (Test-Path (Join-Path (Join-Path $env:CHROME_FIXED_PORT_MIRROR $ver) 'new_chrome.exe')))
  Check "Chrome's version directory is untouched" (Test-VersionUsable $app $ver)

  # Google's own staged update is not ours to delete.
  New-Fixture
  Copy-Item $genuine (Join-Path $app 'new_chrome.exe') -Force
  Remove-LegacyState $app (& $seeds) | Out-Null
  Check "a Google-signed new_chrome.exe is left alone" (Test-Google (Join-Path $app 'new_chrome.exe'))

  # An old wrapper still running a browser must be left for the next run, not broken.
  New-Fixture
  $hold = [IO.File]::Open((Join-Path $app 'chrome.exe'), 'Open', 'Read', 'Read')
  try { Remove-LegacyState $app (& $seeds) | Out-Null } finally { $hold.Close() }
  Check 'a chrome.exe in use is left as it was' (-not (Test-Google (Join-Path $app 'chrome.exe')))

  # No genuine launcher for any version present: never guess one in.
  New-Fixture
  Remove-LegacyState $app @{ '9.9.9.9' = $genuine } | Out-Null
  Check 'with no launcher for a present version, chrome.exe is not replaced' (-not (Test-Google (Join-Path $app 'chrome.exe')))
}
catch { Check 'the legacy test ran to completion' $false $_.Exception.Message }
finally {
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\CHROME_FIXED_PORT_MIRROR -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall legacy cleanup tests passed"
