# A browser running from the mirror must leave Chrome's own chrome.exe free. Google's
# installer replaces chrome.exe in place only when it can open it for write; if it
# cannot, it stages new_chrome.exe for a rename step that never runs from the mirror,
# and chrome_proxy.exe freezes until every PWA shortcut dies. A hardlinked launcher is
# the same file, so running it is enough to block that write.
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\lib\Common.ps1"
. "$repo\lib\Mirror.ps1"
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

$ver  = '151.0.0.0'
$root = Join-Path $env:TEMP ('mltest_' + [guid]::NewGuid().ToString('N'))
$app  = Join-Path $root 'Application'
$env:CHROME_FIXED_PORT_MIRROR = Join-Path $root 'mirror'
New-Item -ItemType Directory -Force (Join-Path $app $ver) | Out-Null
foreach ($f in $RequiredFiles) { Set-Content (Join-Path (Join-Path $app $ver) $f) 'x' }
# A stand-in launcher that just stays alive, so its image is mapped like a browser's.
$cs = Join-Path $root 's.cs'
Set-Content $cs 'class S { static void Main(){ System.Threading.Thread.Sleep(30000); } }' -Encoding ASCII
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -out:(Join-Path $app $ChromeImage) $cs | Out-Null

$proc = $null
try {
  Check 'the mirror builds' (Sync-Mirror $app $ver (Join-Path $app $ChromeImage))
  $launcher = Get-MirrorLauncher $ver
  Check "the mirror's launcher is its own file, not a link" ((Get-Item $launcher).LinkType -ne 'HardLink') (Get-Item $launcher).LinkType
  $dll = Join-Path (Join-Path (Split-Path $launcher) $ver) $RequiredFiles[0]
  Check 'the version directory is still hardlinked (costs no disk)' ((Get-Item $dll).LinkType -eq 'HardLink')

  $proc = Start-Process $launcher -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 500
  Check 'control: the running launcher itself reads as in use' (Test-Locked $launcher)
  Check "while it runs, Chrome's chrome.exe stays free for Google's installer" (-not (Test-Locked (Join-Path $app $ChromeImage)))
}
catch { Check 'the mirror launcher test ran to completion' $false $_.Exception.Message }
finally {
  if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; $proc.WaitForExit() }
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\CHROME_FIXED_PORT_MIRROR -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall mirror launcher tests passed"
