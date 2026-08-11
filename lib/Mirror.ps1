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

$MirrorSentinel = '.mirror_complete'

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

# Build <mirror root>\<version>\ from Chrome's <version>\ plus a genuine launcher.
# Idempotent: existing links are left alone, missing ones are filled in, so an
# interrupted previous run is completed rather than left half-built.
function Sync-Mirror($chromeDir, $version, $launcher) {
  $srcDir = Join-Path $chromeDir $version
  if (-not (Test-Path $srcDir)) { Log "no version dir $version in Chrome's install - cannot mirror" 'WARN'; return $false }
  $srcDir = (Get-Item $srcDir).FullName            # canonical case, so rebasing is exact

  $root     = Join-Path (Get-MirrorRoot) $version
  $dstDir   = Join-Path $root $version
  $dstExe   = Join-Path $root 'chrome.exe'
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
  Set-Content -Path $sentinel -Value $version -Encoding ASCII
  if ($made) { Log "mirrored v$version ($made link(s))" 'ACT' }
  return $true
}

# Usable only if the launcher, its version directory, AND the completion marker
# are all present. The marker is what stops a partially built mirror from being
# treated as done and skipped forever.
function Test-Mirror($version) {
  $root = Join-Path (Get-MirrorRoot) $version
  return ((Test-Path (Join-Path $root 'chrome.exe')) -and
          (Test-Path (Join-Path $root $version)) -and
          (Test-Path (Join-Path $root $MirrorSentinel)))
}

function Get-MirrorVersions {
  return @(Get-VersionDirs (Get-MirrorRoot) | ForEach-Object { $_.Name })
}

# Keep the newest mirror plus any mirror a browser is still running from; drop
# the rest. Deleting a mirror is what actually reclaims the disk, because once
# Google removed its own name the hardlink is the file's last reference.
function Remove-StaleMirror($keepVersion) {
  foreach ($v in Get-MirrorVersions) {
    if ($v -eq $keepVersion) { continue }
    $root = Join-Path (Get-MirrorRoot) $v
    $live = Get-LiveProcessCount $root
    if ($live -gt 0) { Log "mirror v$v still has $live live process(es) - keeping"; continue }
    try { Remove-Item $root -Recurse -Force -ErrorAction Stop; Log "removed stale mirror v$v" }
    catch { Log "could not remove mirror v$v : $($_.Exception.Message)" 'WARN' }
  }
}
