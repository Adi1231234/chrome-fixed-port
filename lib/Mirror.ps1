# The private mirror: a self-contained Chrome install built out of NTFS hardlinks.
#
# Layout, one self-contained install per version:
#   <mirror root>\<version>\chrome.exe          hardlink to the genuine launcher
#   <mirror root>\<version>\<version>\          hardlinks to Chrome's version directory
#   <mirror root>\<version>\.mirror_complete    written ONLY after a fully successful sync
#
# Hardlinks cost only directory entries (measured: 265 links to a 483 MB tree
# consumed 0.1 MB), and a link keeps the file's data alive after Google's
# installer removes its own name for it. That is what makes a running browser
# immune to `setup.exe --delete-old-versions`.

# $MirrorLauncher / $MirrorSentinel come from lib/Common.ps1 - see the note there.

# A version directory is only worth mirroring if it can actually run a browser.
# Google's cleanup strips everything it can and leaves the mapped .dll files
# behind, so a "half-deleted" directory still looks populated - mirroring one
# would faithfully reproduce a browser that dies on every new tab. icudtl.dat is
# the file whose absence was measured to be fatal (STATUS_BREAKPOINT).
$RequiredFiles = @('chrome.dll', 'icudtl.dat')

function Test-VersionUsable($chromeDir, $version) {
  $src = Join-Path $chromeDir $version
  if (-not (Test-Path $src)) { return $false }
  foreach ($f in $RequiredFiles) { if (-not (Test-Path (Join-Path $src $f))) { return $false } }
  return $true
}

# Rebase $path from under $from to under $to. Uses Substring, not .Replace:
# .Replace is case-sensitive, so a case difference between the configured root
# and what Get-ChildItem returns would leave the path UNCHANGED - and an
# unchanged path points at the source file, which Test-Path then reports as
# "already linked", silently skipping it and yielding an incomplete mirror.
function Get-Rebased($path, $from, $to) {
  if (-not $path.StartsWith($from, 'OrdinalIgnoreCase')) { return $null }
  return $to + $path.Substring($from.Length)
}

# One hardlink, falling back to a real copy if the volume/filesystem refuses.
function New-Link($target, $link) {
  try { New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop | Out-Null; return $true }
  catch {
    try { Copy-Item $target $link -Force -ErrorAction Stop; return $true }
    catch { return $false }
  }
}

function Get-MirrorLauncher($version) { Join-Path (Join-Path (Get-MirrorRoot) $version) $MirrorLauncher }

# Build <mirror root>\<version>\ from Chrome's <version>\ plus a genuine launcher.
# Idempotent: existing links are left alone, missing ones are filled in, so an
# interrupted previous run is completed rather than left half-built.
function Sync-Mirror($chromeDir, $version, $launcher) {
  if (-not (Test-VersionUsable $chromeDir $version)) {
    Log "version dir $version is missing $($RequiredFiles -join '/') - refusing to mirror a browser that cannot run" 'WARN'
    return $false
  }
  $srcDir = (Get-Item (Join-Path $chromeDir $version)).FullName   # canonical case, so rebasing is exact
  $root     = Join-Path (Get-MirrorRoot) $version
  $dstDir   = Join-Path $root $version
  $dstExe   = Join-Path $root $MirrorLauncher
  $sentinel = Join-Path $root $MirrorSentinel

  # Drop the completion marker up front: while we are mid-sync the mirror is not
  # usable, and a crash here must not leave a half-built mirror looking complete.
  if (Test-Path $sentinel) { Remove-Item $sentinel -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  foreach ($d in Get-ChildItem $srcDir -Recurse -Directory -ErrorAction SilentlyContinue) {
    $t = Get-Rebased $d.FullName $srcDir $dstDir
    if ($t) { New-Item -ItemType Directory -Force -Path $t | Out-Null }
  }

  $made = 0; $failed = 0
  foreach ($f in Get-ChildItem $srcDir -Recurse -File -ErrorAction SilentlyContinue) {
    $link = Get-Rebased $f.FullName $srcDir $dstDir
    if (-not $link) { $failed++; continue }
    if (Test-Path $link) { continue }
    if (New-Link $f.FullName $link) { $made++ } else { $failed++ }
  }
  if (-not (Test-Path $dstExe)) {
    if (New-Link $launcher $dstExe) { $made++ } else { $failed++ }
  }

  if ($failed) { Log "mirror $version incomplete ($failed link(s) failed) - will retry next run" 'WARN'; return $false }
  # Re-check through the mirror itself: the sentinel must never outrun reality.
  foreach ($f in $RequiredFiles) {
    if (-not (Test-Path (Join-Path $dstDir $f))) { Log "mirror $version still missing $f - not marking complete" 'WARN'; return $false }
  }
  Set-Content -Path $sentinel -Value $version -Encoding ASCII
  if ($made) { Log "mirrored v$version ($made link(s))" 'ACT' }
  return $true
}

# Usable only if the launcher, its version directory, the completion marker AND
# the files a renderer actually needs are all present.
function Test-Mirror($version) {
  $root = Join-Path (Get-MirrorRoot) $version
  if (-not (Test-Path (Join-Path $root $MirrorLauncher)))  { return $false }
  if (-not (Test-Path (Join-Path $root $MirrorSentinel)))  { return $false }
  foreach ($f in $RequiredFiles) { if (-not (Test-Path (Join-Path (Join-Path $root $version) $f))) { return $false } }
  return $true
}

function Get-MirrorVersions { @(Get-VersionDirs (Get-MirrorRoot) | ForEach-Object { $_.Name }) }

# Keep the newest mirror plus any mirror a browser is still running from; drop
# the rest. Deleting a mirror is what actually reclaims the disk, because once
# Google removed its own name the hardlink is the file's last reference.
function Remove-StaleMirror($keepVersions) {
  foreach ($v in Get-MirrorVersions) {
    if ($keepVersions -contains $v) { continue }
    $root = Join-Path (Get-MirrorRoot) $v
    $live = Get-LiveProcessCount $root
    if ($live -gt 0) { Log "mirror v$v still has $live live process(es) - keeping"; continue }
    try { Remove-Item $root -Recurse -Force -ErrorAction Stop; Log "removed stale mirror v$v" }
    catch { Log "could not remove mirror v$v : $($_.Exception.Message)" 'WARN' }
  }
}
