# Scheduled runner - point your scheduled task at this file, and keep the sibling
# lib/ folder next to it.
#
# Makes every Chrome launch open --remote-debugging-port=9225, and keeps the
# running browser immune to Chrome's own updater. Google's setup.exe deletes any
# version directory it does not recognise as current, WITHOUT a working in-use
# check, so we never let a browser depend on a directory Google owns: it runs
# from a private hardlink mirror instead. Root cause and proof: README.md.

$WRAPPER_VER = '4'   # bump when $wrapperSrc changes, to force a reinstall

$here = if ($PSScriptRoot) { $PSScriptRoot } else { '.' }
foreach ($m in 'Common', 'Wrapper', 'Mirror') { . (Join-Path $here "lib\$m.ps1") }
$optionalIcon = Join-Path $here 'lib\Get-ExeIcon.ps1'
if (Test-Path $optionalIcon) { . $optionalIcon }

$dir       = Get-ChromeDir
$exe       = Join-Path $dir 'chrome.exe'
$newChrome = Join-Path $dir 'new_chrome.exe'
$marker    = Join-Path $dir '.wrapper_ver'

# Replace $dst by REMOVING it first. Overwriting in place would write through any
# hardlink we already made to it and corrupt the mirror; unlinking leaves the
# mirror's link as the file's sole owner, untouched.
function Set-FileFresh($src, $dst) {
  if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction Stop }
  Copy-Item $src $dst -Force -ErrorAction Stop
}

# Every genuine Chrome launcher we can currently see, as version -> path.
# chrome_real_*.exe is the previous design's name, still honoured so an existing
# install migrates into the mirror instead of losing its launcher.
function Get-GenuineLaunchers($dir, $exe, $newChrome) {
  $found = @{}
  $cands = @($exe, $newChrome) + @(Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
                                   ForEach-Object { $_.FullName })
  foreach ($p in $cands) {
    if (-not (Test-Path $p)) { continue }
    if (-not (Test-Google $p)) { continue }
    $v = Get-FileVersion $p
    if ($v -and -not $found.ContainsKey($v)) { $found[$v] = $p }
  }
  return $found
}

Log "=== apply start (chrome fixed-port, mirror design) user=$env:USERNAME dir=$dir ==="
$code = 0; $wrap = $null
try {
  if (-not (Test-Path $dir)) { throw "Application dir not found: $dir" }
  New-Item -ItemType Directory -Force -Path (Get-MirrorRoot) | Out-Null

  # STEP 1: mirror every genuine launcher we can see, before anything overwrites it.
  foreach ($kv in (Get-GenuineLaunchers $dir $exe $newChrome).GetEnumerator()) {
    if (Test-Mirror $kv.Key) { continue }
    Sync-Mirror $dir $kv.Key $kv.Value | Out-Null
  }

  $mirrors = @(Get-MirrorVersions | Where-Object { Test-Mirror $_ })
  if ($mirrors.Count -eq 0) { throw 'no usable mirror and no genuine launcher to build one from' }
  $newest    = $mirrors[-1]
  $newestExe = Join-Path (Join-Path (Get-MirrorRoot) $newest) 'chrome.exe'

  # STEP 2: build the wrapper, stamped with the version it will launch.
  $wrap = New-Wrapper $newest $newestExe

  # STEP 3: ensure chrome.exe is our current wrapper.
  $want = "$WRAPPER_VER|$newest"
  $needInstall = $false
  if (-not (Test-Path $exe)) { $needInstall = $true }
  elseif (Test-Google $exe)  { $needInstall = $true; Log 'chrome.exe is genuine (Chrome updated) - reinstalling wrapper' 'ACT' }
  elseif ((-not (Test-Path $marker)) -or ((Get-Content $marker -ErrorAction SilentlyContinue) -ne $want)) { $needInstall = $true }
  if ($needInstall) {
    if ((Test-Path $exe) -and (Test-Locked $exe)) { Log 'chrome.exe locked by a running browser - deferring to next run' 'WARN' }
    else {
      Set-FileFresh $wrap.Exe $exe
      Set-Content -Path $marker -Value $want -Encoding ASCII
      Log "installed wrapper v$WRAPPER_VER stamped $newest at chrome.exe" 'OK'
    }
  }

  # STEP 4: if Google staged an update, hand its swap our wrapper too, so the
  # promoted chrome.exe is never a genuine binary without the debug port.
  if ((Test-Path $newChrome) -and (Test-Google $newChrome)) {
    try { Set-FileFresh $wrap.Exe $newChrome; Log "primed new_chrome.exe with wrapper (rides Google's next swap)" 'ACT' }
    catch { Log "could not prime new_chrome.exe: $($_.Exception.Message)" 'WARN' }
  }

  # STEP 5: drop mirrors nothing runs from any more. This is what reclaims disk:
  # once Google removed its own name, our hardlink is the data's last reference.
  Remove-StaleMirror $newest

  # STEP 6: retire the previous design's launchers once they are safely mirrored.
  Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
    Where-Object { $v = Get-FileVersion $_.FullName; $v -and (Test-Mirror $v) -and -not (Test-Locked $_.FullName) } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Log "retired legacy $($_.Name)" }

  Log "state OK: wrapper at chrome.exe, mirror(s)=$((Get-MirrorVersions) -join ','), launching $newest" 'OK'
}
catch { Log "FAILED: $($_.Exception.Message)" 'ERR'; $code = 1 }
finally { if ($wrap) { Remove-Item $wrap.Tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Log "=== apply done (exit=$code) ==="
exit $code
