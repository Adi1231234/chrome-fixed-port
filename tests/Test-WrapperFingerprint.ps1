# The wrapper's identity must follow its source with no human in the loop.
# It used to be a literal to bump by hand on every $wrapperSrc change - the same
# two-places-in-sync rule that broke the bootstrap when a lib/ module was added to the
# repo but not to install.ps1. Forget the bump and the edit silently never ships.
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

# run.ps1 must not carry a literal version for this.
$runText = Get-Content (Join-Path $repo 'run.ps1') -Raw
Check 'run.ps1 does not hard-code $WRAPPER_VER' `
  ($runText -notmatch "WRAPPER_VER\s*=\s*'[^']*'") 'a literal is a rule nothing enforces'
Check 'run.ps1 derives it from the wrapper source' ($runText -match 'Get-WrapperFingerprint')

# Same source in, same fingerprint out; different source in, different fingerprint out.
. (Join-Path $repo 'lib\Wrapper.ps1')
$a = Get-WrapperFingerprint
$b = Get-WrapperFingerprint
Check 'the fingerprint is stable for unchanged source' ($a -eq $b) "$a vs $b"
Check 'the fingerprint looks like a short hash' ($a -match '^[0-9a-f]{8}$') "got: $a"

$original = $wrapperSrc
try {
  $wrapperSrc = $original.Replace('--remote-allow-origins=* ', '--remote-allow-origins=* --canary ')
  Check 'the source really changed' ($wrapperSrc -ne $original)
  $c = Get-WrapperFingerprint
  Check 'an edited wrapper source yields a different fingerprint' ($c -ne $a) "$a vs $c"

  # and the marker run.ps1 writes must change with it, which is what forces a reinstall
  $markerBefore = "$a|151.0.7922.174"
  $markerAfter  = "$c|151.0.7922.174"
  Check 'the .wrapper_ver marker changes, forcing a reinstall' ($markerBefore -ne $markerAfter)
}
finally { $wrapperSrc = $original }
Check 'the fingerprint returns to its original value' ((Get-WrapperFingerprint) -eq $a)

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall wrapper fingerprint tests passed"
