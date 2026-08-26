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
. (Join-Path $repo 'lib\Common.ps1')   # the mirror layout the wrapper is generated against
. (Join-Path $repo 'lib\Wrapper.ps1')
. (Join-Path $repo 'lib\Build.ps1')
$a = Get-WrapperFingerprint
$b = Get-WrapperFingerprint
Check 'the fingerprint is stable for unchanged source' ($a -eq $b) "$a vs $b"
Check 'the fingerprint looks like a short hash' ($a -match '^[0-9a-f]{8}$') "got: $a"

# The compiled source is the template with the mirror layout substituted in, and the
# fingerprint must cover THAT. Hashing the bare template would let a change to
# $MirrorSentinel produce an identical marker, so the installed wrapper would keep the
# old layout compiled in while Mirror.ps1 wrote the new one.
Check 'no placeholder survives substitution' ((Get-WrapperSource) -notmatch '__LAUNCHER__|__SENTINEL__')
Check 'the compiled source carries the real sentinel' ((Get-WrapperSource) -match [regex]::Escape($MirrorSentinel))
# Every value the wrapper is generated from must move the fingerprint, or a change to
# it compiles into a wrapper the marker calls already installed. The mirror's location
# counts as much as its layout: the C# resolves the root itself.
$layoutBase = Get-WrapperFingerprint
foreach ($n in 'MirrorRootEnv', 'MirrorRootName', 'MirrorLauncher', 'MirrorSentinel') {
  $keep = (Get-Variable $n).Value
  Set-Variable $n -Value ($keep + 'X')
  Check "changing `$$n moves the fingerprint" ((Get-WrapperFingerprint) -ne $layoutBase)
  Check "and `$$n reaches the compiled source" ((Get-WrapperSource) -match [regex]::Escape($keep + 'X'))
  Set-Variable $n -Value $keep
}
Check 'restoring every constant restores the fingerprint' ((Get-WrapperFingerprint) -eq $layoutBase)
$MirrorSentinel = '.mirror_moved'
Check 'changing the mirror layout moves the fingerprint' ((Get-WrapperFingerprint) -ne $layoutBase)
Check 'and the compiled source follows it' ((Get-WrapperSource) -match '\.mirror_moved')
$MirrorSentinel = '.mirror_complete'
Check 'restoring the layout restores the fingerprint' ((Get-WrapperFingerprint) -eq $layoutBase)
$MirrorSentinel = 'bad"name'
$rejected = $false
try { Get-WrapperSource | Out-Null } catch { $rejected = $true }
Check 'a value unsafe to embed in C# is rejected' $rejected
$MirrorSentinel = '.mirror_complete'

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
