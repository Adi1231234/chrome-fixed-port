# Runs every suite and prints one summary. Exists because a suite that quietly SKIPs
# looks exactly like a suite that passed: Test-RenameSafety pinned a Chrome version,
# started printing SKIP the moment Chrome moved on, and protected nothing for days
# without anyone noticing. A skip is reported here as loudly as a failure, and the exit
# code is non-zero if anything failed.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$rows = @()

foreach ($f in Get-ChildItem $here -Filter 'Test-*.ps1' | Sort-Object Name) {
  $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName 2>&1
  $code = $LASTEXITCODE
  $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
  $status = if ($code -ne 0)          { 'FAIL' }
            elseif ($text -match 'SKIP:') { 'SKIPPED' }
            else                       { 'pass' }
  $passes = ([regex]::Matches($text, '\[PASS\]')).Count
  $rows += [pscustomobject]@{
    Suite = $f.BaseName; Status = $status; Checks = $passes
    Note  = if ($status -eq 'SKIPPED') { ([regex]::Match($text, 'SKIP:.*')).Value }
            elseif ($status -eq 'FAIL') { ($out | Where-Object { $_ -match '\[FAIL\]|test\(s\) failed' } |
                                          Select-Object -First 1) -replace '\s+', ' ' }
            else { '' }
  }
}

$w = ($rows | ForEach-Object { $_.Suite.Length } | Measure-Object -Maximum).Maximum
foreach ($r in $rows) {
  $c = switch ($r.Status) { 'FAIL' {'Red'} 'SKIPPED' {'Yellow'} default {'Green'} }
  Write-Host ("  {0,-$w}  {1,-7}  {2,3} checks  {3}" -f $r.Suite, $r.Status, $r.Checks, $r.Note) -ForegroundColor $c
}

$failed  = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count
$skipped = @($rows | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$checks  = ($rows | Measure-Object -Property Checks -Sum).Sum
Write-Host ""
Write-Host "$($rows.Count) suite(s), $checks checks, $failed failed, $skipped skipped"
if ($skipped) {
  Write-Host "a SKIPPED suite is asserting nothing - find out why before trusting this run" -ForegroundColor Yellow
}
if ($failed) { exit 1 }
