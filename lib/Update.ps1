# Everything Chrome's rename step would do, and never gets to do here.
#
# Chrome finishes a deferred update in one step, setup.exe --rename-chrome-exe: it
# moves new_chrome.exe -> chrome.exe AND new_chrome_proxy.exe -> chrome_proxy.exe,
# re-registers chrome_wer.dll, cleans up its own registry state and prunes old
# versions. It decides whether to run that step with exactly one test, measured
# against the shipping binary:
#
#     PathExists(base::DIR_EXE + "new_chrome.exe")
#
# DIR_EXE is the directory of the RUNNING binary, which under this design is our
# mirror, and Sync-Mirror only ever links chrome.exe plus the version directory. So
# the test is false forever and the whole step is skipped - which strands
# chrome_proxy.exe until Google prunes the version directory its manifest names, at
# which point Windows refuses to start it and every PWA shortcut dies.
#
# Two complementary repairs, cheapest first:
#   Sync-PendingRename  restores the precondition, so Chrome runs its OWN rename and
#                       everything it finalises stays correct, including parts we do
#                       not model. Takes effect at the next browser start.
#   Sync-ChromeProxy    performs the proxy half ourselves, immediately, so a machine
#                       is never left exposed while waiting for that restart.

# Arm (or disarm) Chrome's own rename by mirroring the staged new_chrome.exe.
# We link the staged binary itself rather than a placeholder: the test happens to be a
# bare existence check today, but a link to a real, version-stamped executable keeps
# working if that ever tightens.
#
# Arming is only safe once STEP 5 has primed new_chrome.exe with the wrapper. The
# rename MOVES that file onto chrome.exe, so arming while it is still Google's genuine
# launcher would hand Chrome's own binary the wrapper's job and silently drop
# --remote-debugging-port until the next run. STEP 5 deliberately leaves it genuine
# whenever its version is not mirrored yet, so this is a state that really occurs.
function Sync-PendingRename($dir, $mirrorVersion) {
  $staged  = [IO.Path]::Combine($dir, 'new_chrome.exe')
  $trigger = Join-Path (Join-Path (Get-MirrorRoot) $mirrorVersion) 'new_chrome.exe'

  $armable = (Test-Path $staged) -and -not (Test-Google $staged)

  if (-not $armable) {
    if (Test-Path $trigger) {
      try {
        Remove-Item $trigger -Force -ErrorAction Stop
        Log 'removed the pending-rename trigger from the mirror' 'ACT'
      }
      catch { Log "could not remove the pending-rename trigger: $($_.Exception.Message)" 'WARN' }
    }
    if ((Test-Path $staged) -and (Test-Google $staged)) {
      Log 'new_chrome.exe is still genuine - not arming the rename, it would evict the wrapper' 'WARN'
    }
    return
  }
  if (Test-Path $trigger) { return }   # already armed
  if (New-Link $staged $trigger) { Log 'armed Chrome to finish its own rename at the next browser start' 'ACT' }
  else { Log 'could not arm the pending-rename trigger - Sync-ChromeProxy still covers the proxy' 'WARN' }
}

# Keep chrome_proxy.exe naming a version directory that still exists. Only ever
# copies Google's own staged binary onto its intended name, and refuses a candidate
# that is not Google-signed or whose version directory is not actually present.
function Sync-ChromeProxy($dir) {
  $proxy  = [IO.Path]::Combine($dir, 'chrome_proxy.exe')
  $staged = [IO.Path]::Combine($dir, 'new_chrome_proxy.exe')

  $cur   = Get-FileVersion $proxy
  $curOk = $cur -and (Test-Path ([IO.Path]::Combine($dir, $cur)))

  $newVer = $null
  if ((Test-Path $staged) -and (Test-Google $staged)) {
    $v = Get-FileVersion $staged
    if ($v -and (Test-Path ([IO.Path]::Combine($dir, $v)))) { $newVer = $v }
  }

  if (-not $newVer) {
    if ((Test-Path $proxy) -and -not $curOk) {
      $what = if ($cur) { "v$cur" } else { 'with no version stamp' }
      Log "chrome_proxy.exe ($what) has no version directory beside it and no usable replacement is staged - PWA shortcuts will fail until Chrome stages one" 'WARN'
    }
    return
  }
  if ($curOk -and $cur -eq $newVer) { return }   # already current - nothing to do

  if ((Test-Path $proxy) -and (Test-Locked $proxy)) {
    Log 'chrome_proxy.exe is in use - deferring its swap to the next run' 'WARN'
    return
  }
  try {
    Set-FileFresh $staged $proxy
    $from = if ($cur) { "v$cur -> " } else { '' }
    Log "swapped chrome_proxy.exe ${from}v$newVer (Chrome's own rename never runs under the mirror design)" 'OK'
  }
  catch { Log "could not swap chrome_proxy.exe: $($_.Exception.Message)" 'WARN' }
}

function Complete-ChromeUpdate($dir, $mirrorVersion) {
  Sync-PendingRename $dir $mirrorVersion
  Sync-ChromeProxy $dir
}
