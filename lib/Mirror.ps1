# The private mirror: a self-contained Chrome install built out of NTFS hardlinks.
#
# Layout, one self-contained install per version:
#   <mirror root>\<version>\chrome.exe    hardlink to the genuine launcher
#   <mirror root>\<version>\<version>\    hardlinks to Chrome's version directory
#
# Hardlinks cost only directory entries (measured: 265 links to a 483 MB tree
# consumed 0.1 MB), and a link keeps the file's data alive after Google's
# installer removes its own name for it. That is what makes a running browser
# immune to `setup.exe --delete-old-versions`.

# One hardlink, falling back to a real copy if the volume/filesystem refuses.
function New-Link($target, $link) {
  try { New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop | Out-Null; return $true }
  catch {
    try { Copy-Item $target $link -Force -ErrorAction Stop; return $true }
    catch { return $false }
  }
}

# Build <mirror root>\<version>\ from Chrome's <version>\ plus a genuine launcher.
# Idempotent: an existing complete mirror is left alone. A partial mirror (an
# interrupted previous run) is completed link by link.
function Sync-Mirror($chromeDir, $version, $launcher) {
  $srcDir  = Join-Path $chromeDir $version
  $root    = Join-Path (Get-MirrorRoot) $version
  $dstDir  = Join-Path $root $version
  $dstExe  = Join-Path $root 'chrome.exe'

  if (-not (Test-Path $srcDir)) { Log "no version dir $version in Chrome's install - cannot mirror" 'WARN'; return $false }

  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  foreach ($d in Get-ChildItem $srcDir -Recurse -Directory -ErrorAction SilentlyContinue) {
    New-Item -ItemType Directory -Force -Path $d.FullName.Replace($srcDir, $dstDir) | Out-Null
  }

  $made = 0; $failed = 0
  foreach ($f in Get-ChildItem $srcDir -Recurse -File -ErrorAction SilentlyContinue) {
    $link = $f.FullName.Replace($srcDir, $dstDir)
    if (Test-Path $link) { continue }
    if (New-Link $f.FullName $link) { $made++ } else { $failed++ }
  }
  if (-not (Test-Path $dstExe)) {
    if (New-Link $launcher $dstExe) { $made++ } else { $failed++ }
  }

  if ($failed) { Log "mirror $version incomplete ($failed link(s) failed)" 'WARN'; return $false }
  if ($made)   { Log "mirrored v$version ($made link(s))" 'ACT' }
  return $true
}

# A mirror is usable only if it has a launcher and that launcher's version dir.
function Test-Mirror($version) {
  $root = Join-Path (Get-MirrorRoot) $version
  return ((Test-Path (Join-Path $root 'chrome.exe')) -and (Test-Path (Join-Path $root $version)))
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
    if ($live -gt 0) { Log "mirror v$v still has $live live process(es) - keeping" ; continue }
    try { Remove-Item $root -Recurse -Force -ErrorAction Stop; Log "removed stale mirror v$v" }
    catch { Log "could not remove mirror v$v : $($_.Exception.Message)" 'WARN' }
  }
}
