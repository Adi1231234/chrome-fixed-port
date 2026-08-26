# Guards the bootstrap against the failure that hit a scheduled run: run.ps1 gained a
# lib/ module that install.ps1 never shipped, so the download was incomplete and the run
# died mid-way, after installing the wrapper but before finishing the update.
# Touches nothing outside $env:TEMP.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$failed = 0
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name"; if ($detail) { Write-Host "       $detail" }; $script:failed++ }
}

# Every module run.ps1 dot-sources must exist in lib/.
$runText  = Get-Content (Join-Path $repo 'run.ps1') -Raw
$required = ([regex]::Match($runText, 'foreach \(\$m in ([^\)]+)\)').Groups[1].Value -split ',') |
            ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ }
Check 'run.ps1 declares a module list' ($required.Count -gt 0) "parsed: $($required -join ',')"
foreach ($m in $required) {
  Check "lib/$m.ps1 exists in the repo" (Test-Path (Join-Path $repo "lib\$m.ps1"))
}

# install.ps1 must not carry a hand-written manifest of files to fetch - that is exactly
# what drifted. It should pull the whole tree instead.
$instText = Get-Content (Join-Path $repo 'install.ps1') -Raw
Check 'install.ps1 has no hand-written per-file download list' `
  ($instText -notmatch "\$files\s*=") 'a literal file list will drift again the next time lib/ grows'
Check 'install.ps1 fetches the whole repository archive' `
  ($instText -match 'codeload|archive/refs/heads|\.zip')

# And what it fetches must actually contain every module, checked against a real archive.
$tmp = Join-Path $env:TEMP ('bootstrap_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $zip = Join-Path $tmp 'src.zip'
  Invoke-WebRequest -Uri 'https://codeload.github.com/Adi1231234/chrome-fixed-port/zip/refs/heads/main' `
                    -OutFile $zip -UseBasicParsing
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $run = Get-ChildItem $tmp -Filter 'run.ps1' -Recurse -File | Select-Object -First 1
  Check 'the published archive contains run.ps1' ($null -ne $run)
  if ($run) {
    foreach ($m in $required) {
      Check "the published archive ships lib/$m.ps1" (Test-Path (Join-Path $run.DirectoryName "lib\$m.ps1"))
    }
  }
}
catch { Check 'could reach the published archive' $false $_.Exception.Message }
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($failed) { Write-Host "`n$failed test(s) failed"; exit 1 }
Write-Host "`nall bootstrap tests passed"
