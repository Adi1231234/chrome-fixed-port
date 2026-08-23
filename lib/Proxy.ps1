# Keeps chrome_proxy.exe pointing at a version directory that still exists.
#
# chrome_proxy.exe is what every PWA / app shortcut launches, and its embedded
# manifest declares a hard side-by-side dependency on an assembly named after its
# own FileVersion, resolved from <version>\<version>.manifest beside it. Lose that
# directory and Windows refuses to start the process at all - "the side-by-side
# configuration is incorrect" - before a line of Chrome code runs.
#
# Chrome swaps new_chrome_proxy.exe into place in its rename step, but that step
# never runs for us. upgrade_util::IsUpdatePendingRestart() looks for new_chrome.exe
# next to the RUNNING binary (base::DIR_EXE), which under this design is our mirror,
# and the mirror never contains one. So the browser never asks the installer to
# rename anything, chrome_proxy.exe freezes at whatever version it had when we were
# installed, and it dies the moment Google prunes that version directory.
#
# We therefore perform Chrome's own swap ourselves. We only ever COPY Google's
# staged binary onto its intended name; we never invent or patch a Chrome file, and
# we refuse any candidate that is not signed by Google or whose version directory
# is not actually present.

function Sync-ChromeProxy($dir) {
  $proxy  = [IO.Path]::Combine($dir, 'chrome_proxy.exe')
  $staged = [IO.Path]::Combine($dir, 'new_chrome_proxy.exe')

  # A proxy is only usable while the version directory it names is still there.
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
