# Leftovers of the design that overwrote chrome.exe with the wrapper. Every file named
# here is one this tool wrote, except chrome.exe itself, which is given back to Google:
# it is replaced only by a Google-signed launcher whose version directory is present.
# Anything still running is left for the next run.

function Remove-IfIdle($path, $why) {
  if (-not (Test-Path $path)) { return }
  if (Test-Locked $path) { Log "$why is still in use - leaving it for the next run" 'WARN'; return }
  try { Remove-Item $path -Force -ErrorAction Stop; Log "removed $why" 'ACT' }
  catch { Log "could not remove ${why}: $($_.Exception.Message)" 'WARN' }
}

# chrome.exe must be Google's again: the redirect needs nothing from it, and Google's
# cleanup keeps the version directory named by its FileVersion.
function Restore-GenuineChrome($dir, $launchers) {
  $exe = [IO.Path]::Combine($dir, $ChromeImage)
  if ((Test-Path $exe) -and (Test-Google $exe)) { return }
  $v = @($launchers.Keys | Where-Object { Test-VersionUsable $dir $_ } | Sort-Object { [version]$_ })[-1]
  if (-not $v) { Log "no genuine launcher for a version present in $dir - chrome.exe left as is" 'WARN'; return }
  if ((Test-Path $exe) -and (Test-Locked $exe)) { Log 'the old wrapper at chrome.exe is still running - restoring it next run' 'WARN'; return }
  try { Set-FileFresh $launchers[$v] $exe; Log "restored Google's chrome.exe v$v" 'ACT' }
  catch { Log "could not restore chrome.exe: $($_.Exception.Message)" 'WARN' }
}

function Remove-LegacyState($dir, $launchers) {
  Restore-GenuineChrome $dir $launchers
  # The old STEP 5 primed new_chrome.exe with the wrapper so Chrome's rename carried it.
  $staged = [IO.Path]::Combine($dir, 'new_chrome.exe')
  if ((Test-Path $staged) -and -not (Test-Google $staged)) { Remove-IfIdle $staged 'the wrapper primed as new_chrome.exe' }
  Remove-IfIdle ([IO.Path]::Combine($dir, '.wrapper_ver')) 'the old .wrapper_ver marker'
  # Rebuild seeds, no longer needed: chrome.exe itself is now the genuine launcher.
  Get-ChildItem $dir -Filter 'chrome_real_*.exe' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-IfIdle $_.FullName "the old rebuild seed $($_.Name)" }
  # Triggers the old design linked into mirrors to make Chrome run its own rename.
  foreach ($v in Get-MirrorVersions) {
    Remove-IfIdle (Join-Path (Join-Path (Get-MirrorRoot) $v) 'new_chrome.exe') "the rename trigger in mirror v$v"
  }
}
