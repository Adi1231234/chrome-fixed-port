# Scheduled runner - point your scheduled task at this file, and keep the sibling
# lib/ folder next to it.
#
# Makes every Chrome launch open --remote-debugging-port=9225, and keeps the
# running browser immune to Chrome's own updater. Google's setup.exe deletes any
# version directory it does not recognise as current, WITHOUT a working in-use
# check, so we never let a browser depend on a directory Google owns: it runs
# from a private hardlink mirror instead. Root cause and proof: README.md.

$WRAPPER_VER = '6'   # bump when $wrapperSrc changes, to force a reinstall

$here = if ($PSScriptRoot) { $PSScriptRoot } else { '.' }
foreach ($m in 'Common', 'Wrapper', 'Mirror', 'Update') { . (Join-Path $here "lib\$m.ps1") }
$optionalIcon = Join-Path $here 'lib\Get-ExeIcon.ps1'
if (Test-Path $optionalIcon) { . $optionalIcon }

$dir = Get-ChromeDir
# [IO.Path]::Combine, not Join-Path: Join-Path resolves through the PowerShell
# provider and emits a noisy "Cannot find drive" error per call when the configured
# directory is bad - three of them ahead of the one clean message that says why.
$exe       = [IO.Path]::Combine($dir, 'chrome.exe')
$newChrome = [IO.Path]::Combine($dir, 'new_chrome.exe')
$marker    = [IO.Path]::Combine($dir, '.wrapper_ver')

# Every genuine Chrome launcher we can currently see, as version -> path.
# chrome_real_*.exe is both the previous design's name and our rebuild seed.
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

  # STEP 1: work out what we can serve. Candidates are the genuine launchers still
  # in Chrome's directory PLUS any mirror we already have - in steady state Chrome's
  # directory holds only our wrapper, so a damaged mirror is repaired from its own
  # (genuine) launcher.
  $targets = @{}
  foreach ($kv in (Get-GenuineLaunchers $dir $exe $newChrome).GetEnumerator()) { $targets[$kv.Key] = $kv.Value }
  foreach ($v in Get-MirrorVersions) {
    if ($targets.ContainsKey($v)) { continue }
    $ml = Get-MirrorLauncher $v
    if (Test-Path $ml) { $targets[$v] = $ml }
  }
  # Servable = already mirrored and validated, or a source directory that can
  # actually run a browser. A gutted or empty version directory is neither.
  $servable = @($targets.Keys | Where-Object { (Test-Mirror $_) -or (Test-VersionUsable $dir $_) })
  if ($servable.Count -eq 0) { throw 'no runnable Chrome version found (no complete mirror, no viable version directory)' }
  $newest = @($servable | Sort-Object { [version]$_ })[-1]

  # Keep the newest, plus anything a browser is still running from.
  $keep = @($newest)
  foreach ($v in Get-MirrorVersions) {
    if ($keep -notcontains $v -and (Get-LiveProcessCount (Join-Path (Get-MirrorRoot) $v)) -gt 0) { $keep += $v }
  }

  # STEP 2: build only what we keep - never build something we are about to prune.
  foreach ($v in $keep) {
    if (Test-Mirror $v) { continue }
    if (-not $targets.ContainsKey($v)) { Log "no genuine launcher for v$v - cannot build its mirror" 'WARN'; continue }
    Log "mirror v$v missing or incomplete - (re)building" 'ACT'
    Sync-Mirror $dir $v $targets[$v] | Out-Null
  }
  if (-not (Test-Mirror $newest)) { throw "could not produce a usable mirror for $newest" }
  $newestExe = Get-MirrorLauncher $newest

  # STEP 3: build the wrapper, stamped with the version it will launch.
  $wrap = New-Wrapper $newest $newestExe

  # STEP 4: ensure chrome.exe is our current wrapper.
  $want = "$WRAPPER_VER|$newest"
  $needInstall = $false
  if (-not (Test-Path $exe)) { $needInstall = $true }
  elseif (Test-Google $exe)  { $needInstall = $true; Log 'chrome.exe is genuine (Chrome updated) - reinstalling wrapper' 'ACT' }
  elseif ((-not (Test-Path $marker)) -or (((Get-Content $marker -Raw -ErrorAction SilentlyContinue) + '').Trim() -ne $want)) { $needInstall = $true }
  if ($needInstall) {
    if ((Test-Path $exe) -and (Test-Locked $exe)) { Log 'chrome.exe locked by a running browser - deferring to next run' 'WARN' }
    else {
      # A browser can still grab chrome.exe between the check and the copy. That
      # must defer to the next run, not abort the cleanup steps below.
      try {
        Set-FileFresh $wrap.Exe $exe
        Set-Content -Path $marker -Value $want -Encoding ASCII
        Log "installed wrapper v$WRAPPER_VER stamped $newest at chrome.exe" 'OK'
      }
      catch { Log "could not install wrapper this run: $($_.Exception.Message)" 'WARN' }
    }
  }

  # STEP 5: if Google staged an update, hand its swap our wrapper too, but only
  # once that version is safely mirrored - otherwise this would destroy the only
  # copy of a genuine launcher we had not captured yet.
  if ((Test-Path $newChrome) -and (Test-Google $newChrome)) {
    $ncv = Get-FileVersion $newChrome
    if ($ncv -and (Test-Mirror $ncv)) {
      try { Set-FileFresh $wrap.Exe $newChrome; Log "primed new_chrome.exe with wrapper (rides Google's next swap)" 'ACT' }
      catch { Log "could not prime new_chrome.exe: $($_.Exception.Message)" 'WARN' }
    }
    else { Log "new_chrome.exe v$ncv is not mirrored yet - leaving it genuine this run" 'WARN' }
  }

  # STEP 6: finish the update Chrome cannot finish for itself. Its rename step is
  # gated on new_chrome.exe existing beside the RUNNING binary, which is our mirror,
  # so it never runs - and chrome_proxy.exe rots until a PWA shortcut dies with a
  # side-by-side error. See lib/Update.ps1.
  Complete-ChromeUpdate $dir $newest

  # STEP 7: drop mirrors nothing runs from any more. This is what reclaims disk:
  # once Google removed its own name, our hardlink is the data's last reference.
  Remove-StaleMirror $keep

  # STEP 8: keep exactly one genuine launcher beside Chrome as a rebuild seed,
  # hardlinked from the mirror so it costs nothing. Without it the mirror's own
  # chrome.exe is the ONLY genuine launcher on the machine, and losing it leaves
  # the tool with nothing to rebuild from.
  $seedName = "chrome_real_$newest.exe"
  $seed     = Join-Path $dir $seedName
  if (-not (Test-Path $seed)) {
    if (New-Link $newestExe $seed) { Log "kept rebuild seed $seedName" 'ACT' }
    else { Log "could not create rebuild seed $seedName" 'WARN' }
  }
  Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $seedName -and -not (Test-Locked $_.FullName) } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Log "retired stale launcher $($_.Name)" }

  Log "state OK: wrapper at chrome.exe, mirror(s)=$((Get-MirrorVersions) -join ','), launching $newest" 'OK'
}
catch { Log "FAILED: $($_.Exception.Message)" 'ERR'; $code = 1 }
finally { if ($wrap) { Remove-Item $wrap.Tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Log "=== apply done (exit=$code) ==="
exit $code
