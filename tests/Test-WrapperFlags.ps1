# Behavioural test for the flags the wrapper injects.
# Builds a throwaway mirror whose chrome.exe only records the command line it was
# handed, compiles the real wrapper against it, and asserts what came through.
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path $env:TEMP ('cwtest_' + [guid]::NewGuid().ToString('N'))
$ver  = '151.0.0.0'
$mir  = Join-Path $root 'mirror'
$vd   = Join-Path $mir $ver
New-Item -ItemType Directory -Force -Path (Join-Path $vd $ver) | Out-Null

$fakeSrc = @'
using System; using System.IO;
class Fake { static int Main(){
  File.AppendAllText(Environment.GetEnvironmentVariable("CW_TEST_OUT"), Environment.CommandLine);
  return 0; } }
'@
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$fcs = Join-Path $root 'fake.cs'
Set-Content -Path $fcs -Value $fakeSrc -Encoding UTF8
& $csc -nologo -target:exe -out:(Join-Path $vd 'chrome.exe') $fcs | Out-Null
New-Item -ItemType File -Path (Join-Path $vd '.mirror_complete') -Force | Out-Null

. "$repo\lib\Common.ps1"
. "$repo\lib\Wrapper.ps1"
$built = New-Wrapper $ver $null

$out = Join-Path $root 'out.txt'
$env:CHROME_FIXED_PORT_MIRROR = $mir
$env:CW_TEST_OUT = $out

# Run the wrapper and return the command line the fake chrome.exe saw.
function Get-LaunchLine([string[]]$WrapperArgs, [string]$Override) {
  Set-Content -Path $out -Value '' -NoNewline
  if ($Override) { $env:CHROME_WRAP_OVERRIDE = $Override }
  if ($WrapperArgs) { & $built.Exe @WrapperArgs | Out-Null } else { & $built.Exe | Out-Null }
  if ($Override) { Remove-Item Env:\CHROME_WRAP_OVERRIDE }
  return (Get-Content $out -Raw).Trim()
}

$cases = @(
  @{ Name = 'default launch injects the screenshot feature flag'
     Line = (Get-LaunchLine)
     Test = { param($l) $l -match '--enable-features=CDPScreenshotNewSurface' -and
                        $l -match '--remote-debugging-port=9225' } }
  @{ Name = "caller's own --enable-features is left alone, not duplicated"
     Line = (Get-LaunchLine @('--enable-features=FooBar'))
     Test = { param($l) ($l -split '--enable-features=').Count -eq 2 -and $l -match 'FooBar' } }
  @{ Name = 'child processes (--type=) pass through untouched'
     Line = (Get-LaunchLine @('--type=renderer'))
     Test = { param($l) $l -notmatch 'CDPScreenshotNewSurface' -and $l -match '--type=renderer' } }
  @{ Name = 'CHROME_WRAP_OVERRIDE still replaces the whole flag set'
     Line = (Get-LaunchLine @() '--remote-debugging-port=9999')
     Test = { param($l) $l -match '--remote-debugging-port=9999' -and
                        $l -notmatch 'CDPScreenshotNewSurface' } }
)

# Sync-PendingRename parks a new_chrome.exe in the mirror to make Chrome finish its own
# rename. The wrapper resolves the mirror by scanning that same directory, so prove the
# extra file does not confuse it into refusing to launch.
Set-Content -Path (Join-Path $vd 'new_chrome.exe') -Value 'trigger' -Encoding ASCII
$cases += @{ Name = 'a pending-rename trigger in the mirror does not break resolution'
             Line = (Get-LaunchLine)
             Test = { param($l) $l -match '--remote-debugging-port=9225' } }

$failed = 0
foreach ($c in $cases) {
  $ok = & $c.Test $c.Line
  Write-Host ("[{0}] {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.Name)
  if (-not $ok) { Write-Host "       got: $($c.Line)"; $failed++ }
}

Remove-Item -Recurse -Force $root, $built.Tmp -ErrorAction SilentlyContinue
Remove-Item Env:\CHROME_FIXED_PORT_MIRROR, Env:\CW_TEST_OUT -ErrorAction SilentlyContinue
if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall wrapper flag tests passed"
