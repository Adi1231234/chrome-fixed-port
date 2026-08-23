# Behavioural test for Sync-ChromeProxy: does chrome_proxy.exe end up pointing at a
# version directory that exists, without ever clobbering a good one?
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\lib\Common.ps1"
. "$repo\lib\Update.ps1"

# A real, Google-signed proxy to seed cases with. Skip cleanly if this machine has none.
$realProxy = "$env:LOCALAPPDATA\Google\Chrome\Application\chrome_proxy.exe"
if (-not (Test-Path $realProxy) -or -not (Test-Google $realProxy)) {
  Write-Host 'SKIP: no Google-signed chrome_proxy.exe on this machine to seed from'
  exit 0
}
$realVer = Get-FileVersion $realProxy
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

# Build a fake Application dir. $staged/$proxy say which of the two exes to place,
# $dirs lists the version directories that exist.
function New-Case($proxyVer, $stagedVer, $dirs) {
  $d = Join-Path $env:TEMP ('proxytest_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  foreach ($v in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $d $v) | Out-Null }
  if ($proxyVer)  { Copy-Item $realProxy (Join-Path $d 'chrome_proxy.exe') }
  if ($stagedVer) { Copy-Item $realProxy (Join-Path $d 'new_chrome_proxy.exe') }
  return $d
}
function Get-ProxyVer($d) { Get-FileVersion (Join-Path $d 'chrome_proxy.exe') }

# 1. Stranded proxy + staged replacement whose directory exists -> swapped in.
#    Both binaries are the same real file, so we detect the swap by content length
#    after making the stale one distinguishable.
$d = New-Case $realVer $realVer @($realVer)
Remove-Item (Join-Path $d 'chrome_proxy.exe')
# a stale proxy: not Google-signed, and no directory named after it
Set-Content -Path (Join-Path $d 'chrome_proxy.exe') -Value 'stale' -Encoding ASCII
Sync-ChromeProxy $d
Check 'a stranded chrome_proxy.exe is replaced by the staged one' `
  ((Get-ProxyVer $d) -eq $realVer) "version=$(Get-ProxyVer $d)"
Remove-Item -Recurse -Force $d

# 2. Already current -> no-op (file must not be rewritten).
$d = New-Case $realVer $realVer @($realVer)
$before = (Get-Item (Join-Path $d 'chrome_proxy.exe')).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
Sync-ChromeProxy $d
Check 'an already-current chrome_proxy.exe is left untouched' `
  ((Get-Item (Join-Path $d 'chrome_proxy.exe')).LastWriteTimeUtc -eq $before)
Remove-Item -Recurse -Force $d

# 3. Staged binary whose version directory is absent -> refuse to install it.
$d = New-Case $realVer $realVer @()
Remove-Item (Join-Path $d 'chrome_proxy.exe')
Set-Content -Path (Join-Path $d 'chrome_proxy.exe') -Value 'stale' -Encoding ASCII
Sync-ChromeProxy $d
Check 'a staged proxy with no version directory is refused' `
  ((Get-Content (Join-Path $d 'chrome_proxy.exe') -Raw).Trim() -eq 'stale')
Remove-Item -Recurse -Force $d

# 4. Staged binary that is not Google-signed -> refuse to install it.
$d = New-Case $realVer $null @($realVer)
Set-Content -Path (Join-Path $d 'new_chrome_proxy.exe') -Value 'not google' -Encoding ASCII
$before = (Get-Item (Join-Path $d 'chrome_proxy.exe')).LastWriteTimeUtc
Start-Sleep -Milliseconds 1100
Sync-ChromeProxy $d
Check 'an unsigned new_chrome_proxy.exe is refused' `
  ((Get-Item (Join-Path $d 'chrome_proxy.exe')).LastWriteTimeUtc -eq $before)
Remove-Item -Recurse -Force $d

# 5. No proxy at all (Chrome installs that predate it) -> stay silent, do nothing.
$d = New-Case $null $null @($realVer)
Sync-ChromeProxy $d
Check 'a directory with no proxy at all is left alone' `
  (-not (Test-Path (Join-Path $d 'chrome_proxy.exe')))
Remove-Item -Recurse -Force $d

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall proxy sync tests passed"
