# Behavioural test for lib/Redirect.ps1, against Windows itself: does a start of the
# filtered path really run the wrapper, does the same name elsewhere run untouched, and
# does the redirect survive the file being replaced the way a Chrome update replaces it?
# Uses a throwaway image name, never chrome.exe, so a real Chrome is never affected.
# Needs admin for HKLM (elevates the same way run.ps1 does) and removes what it wrote.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\lib\Common.ps1"
. "$repo\lib\Redirect.ps1"
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

$image = 'cfpredirtest.exe'
$root  = Join-Path $env:TEMP ('redirtest_' + [guid]::NewGuid().ToString('N'))
$app   = Join-Path $root 'app'; $other = Join-Path $root 'mirror'
New-Item -ItemType Directory -Force $app, $other | Out-Null
$target = Join-Path $app $image; $wrapper = Join-Path $root 'wrapper.exe'

# One recorder serves as target, look-alike and wrapper: it logs which file ran and how.
$src = 'using System; using System.IO; class R { static void Main(){ File.AppendAllText(' +
       'Environment.GetEnvironmentVariable("CFP_REDIR_LOG"), System.Reflection.Assembly.' +
       'GetEntryAssembly().Location + "|" + Environment.CommandLine + "\n"); } }'
$rec = Join-Path $root 'rec.exe'
Set-Content (Join-Path $root 'r.cs') $src -Encoding ASCII
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -out:$rec (Join-Path $root 'r.cs') | Out-Null
foreach ($p in $target, (Join-Path $other $image), $wrapper) { Copy-Item $rec $p }

$env:CFP_REDIR_LOG = Join-Path $root 'log.txt'
function Start-AndRead($exe, $arg) {
  Set-Content $env:CFP_REDIR_LOG '' -NoNewline
  Start-Process $exe -ArgumentList $arg -Wait
  return ((Get-Content $env:CFP_REDIR_LOG -Raw) + '').Trim()
}
$mainKey = Join-Path $IfeoRoot $image
try {
  Check 'Set-LaunchRedirect reports the redirect in place' (Set-LaunchRedirect $image $target $wrapper)
  $l = Start-AndRead $target 'first'
  Check 'starting the filtered path runs the wrapper' ($l -like "$wrapper|*") $l
  Check 'and hands it the original image path and arguments' ($l -match [regex]::Escape($target) -and $l -match 'first') $l
  $l = Start-AndRead (Join-Path $other $image) 'elsewhere'
  Check 'the same name at another path runs untouched' ($l -like "$(Join-Path $other $image)|*") $l

  # What Google's installer does: move the old file out, move a new one in.
  Move-Item $target (Join-Path $root 'old.exe'); Copy-Item $rec $target
  $l = Start-AndRead $target 'after-update'
  Check 'the redirect survives the file being replaced' ($l -like "$wrapper|*") $l

  Remove-LaunchRedirect $image $target
  Check 'Remove-LaunchRedirect leaves no trace when nothing else was there' (-not (Test-Path $mainKey))

  # Someone else's options under the same image name must survive us, both ways.
  Invoke-Elevated "New-Item '$mainKey' | Out-Null; New-ItemProperty '$mainKey' -Name CfpKeep -Value 1 | Out-Null"
  Set-LaunchRedirect $image $target $wrapper | Out-Null
  Check "an existing image key's values survive writing the redirect" ($null -ne (Get-ItemProperty $mainKey).CfpKeep)
  Remove-LaunchRedirect $image $target
  Check 'and removing it keeps that key, minus our filter' ((Test-Path $mainKey) -and
        -not (Test-Path (Get-RedirectKey $image $target)) -and $null -ne (Get-ItemProperty $mainKey).CfpKeep)
}
catch { Check 'the redirect test ran to completion' $false $_.Exception.Message }
finally {
  if (Test-Path $mainKey) { Invoke-Elevated "Remove-Item '$mainKey' -Recurse -Force" }
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Env:\CFP_REDIR_LOG -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall launch redirect tests passed"
