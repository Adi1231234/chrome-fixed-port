# Scheduled runner - point your scheduled task at this file, and keep the sibling
# lib/ folder next to it.
#
# Makes every Chrome launch open --remote-debugging-port=9225, and keeps the
# running browser immune to Chrome's own updater. Google's setup.exe deletes any
# version directory it does not recognise as current, WITHOUT a working in-use
# check, so we never let a browser depend on a directory Google owns: it runs
# from a private hardlink mirror instead. Root cause and proof: README.md.
#
# chrome.exe stays Google's. Windows redirects every start of it to our wrapper
# (lib/Redirect.ps1), and that redirect needs no run after a Chrome update.

$here = if ($PSScriptRoot) { $PSScriptRoot } else { '.' }
foreach ($m in 'Common', 'Wrapper', 'Build', 'Mirror', 'Redirect', 'Legacy') { . (Join-Path $here "lib\$m.ps1") }

# Identity of the wrapper build, computed from lib/Wrapper.ps1's source. Never a literal:
# a number someone has to remember to bump is a rule with no enforcement behind it.
$WRAPPER_VER = Get-WrapperFingerprint

$dir = Get-ChromeDir
# [IO.Path]::Combine, not Join-Path: Join-Path resolves through the PowerShell
# provider and emits a noisy "Cannot find drive" error per call when the configured
# directory is bad - three of them ahead of the one clean message that says why.
$exe       = [IO.Path]::Combine($dir, $ChromeImage)
$newChrome = [IO.Path]::Combine($dir, 'new_chrome.exe')

# Every genuine Chrome launcher we can currently see, as version -> path.
# chrome_real_*.exe are the old design's rebuild seeds, used until they are retired.
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

Log "=== apply start (chrome fixed-port, launch redirect) user=$env:USERNAME dir=$dir ==="
$code = 0; $wrap = $null
try {
  if (-not (Test-Path $dir)) { throw "Application dir not found: $dir" }
  New-Item -ItemType Directory -Force -Path (Get-MirrorRoot) | Out-Null

  # STEP 1: work out what we can serve: the genuine launchers in Chrome's directory
  # PLUS any mirror we already have, so a damaged mirror is repaired from its own
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

  # STEP 3: the wrapper, in our own directory. Rebuilt only when its source changed.
  $wrapper = Get-WrapperPath
  if (-not (Test-WrapperCurrent $WRAPPER_VER)) {
    $wrap = New-Wrapper
    Install-Wrapper $wrap.Exe $WRAPPER_VER
    Log "installed wrapper v$WRAPPER_VER at $wrapper" 'OK'
  }
  Remove-RetiredWrapper

  # STEP 4: send every start of Chrome's chrome.exe to it.
  if (-not (Set-LaunchRedirect $ChromeImage $exe $wrapper)) { throw 'the launch redirect is not in place - will retry next run' }

  # STEP 5: undo what the old design left behind, chrome.exe included.
  Remove-LegacyState $dir $targets

  # STEP 6: drop mirrors nothing runs from any more. This is what reclaims disk:
  # once Google removed its own name, our hardlink is the data's last reference.
  Remove-StaleMirror $keep

  Log "state OK: redirect -> $wrapper, mirror(s)=$((Get-MirrorVersions) -join ','), launching $newest" 'OK'
}
catch { Log "FAILED: $($_.Exception.Message)" 'ERR'; $code = 1 }
finally { if ($wrap) { Remove-Item $wrap.Tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Log "=== apply done (exit=$code) ==="
exit $code
