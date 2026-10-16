# The launch redirect: every start of Chrome's own chrome.exe runs the wrapper instead.
#
# Windows' Image File Execution Options let a "Debugger" value stand in for an image:
# CreateProcess runs it with the original command line appended. UseFilter=1 plus a
# subkey holding FilterFullPath narrows that to ONE path, so only Chrome's Application
# chrome.exe is redirected. The mirror's chrome.exe has the same name and a different
# path, so the browser and every child it spawns from there run untouched.
#
# This replaces overwriting chrome.exe with the wrapper. Google's installer replaces
# that file on every update, and the wrapper was gone until the next run. The redirect
# lives in the registry, keyed by path, and an update has no reason to touch it.
# Measured: still redirected after the target file was replaced.
#
# Writing it needs admin, once. A run that cannot elevate WARNs and retries next time.

$IfeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# One subkey per redirected path, so another user's install, or a test, never
# overwrites this install's filter.
function Get-RedirectKey($image, $target) {
  Join-Path (Join-Path $IfeoRoot $image) ('ChromeFixedPort-' + (Get-ShortHash $target.ToLowerInvariant()))
}

function Test-LaunchRedirect($image, $target, $wrapper) {
  $m = Get-ItemProperty (Join-Path $IfeoRoot $image) -ErrorAction SilentlyContinue
  $s = Get-ItemProperty (Get-RedirectKey $image $target) -ErrorAction SilentlyContinue
  return [bool]($m -and $m.UseFilter -eq 1 -and $s -and
                $s.FilterFullPath -eq $target -and $s.Debugger -eq "`"$wrapper`"")
}

function ConvertTo-Literal([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# Runs $script as admin: inline when already elevated, otherwise in a hidden elevated
# PowerShell. Throws if elevation is refused.
function Invoke-Elevated([string]$script) {
  $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if ($id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { & ([scriptblock]::Create($script)); return }
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop `
         -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc
  $p.WaitForExit()
}

# Never New-Item -Force an existing registry key: that recreates it, wiping the values
# and subkeys someone else may keep under chrome.exe.
function Set-LaunchRedirect($image, $target, $wrapper) {
  if (Test-LaunchRedirect $image $target $wrapper) { return $true }
  $main = ConvertTo-Literal (Join-Path $IfeoRoot $image)
  $key  = ConvertTo-Literal (Get-RedirectKey $image $target)
  $script = @"
foreach (`$k in $main, $key) { if (-not (Test-Path `$k)) { New-Item `$k | Out-Null } }
New-ItemProperty $main -Name UseFilter -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty $key -Name FilterFullPath -Value $(ConvertTo-Literal $target) -Force | Out-Null
New-ItemProperty $key -Name Debugger -Value $(ConvertTo-Literal "`"$wrapper`"") -Force | Out-Null
"@
  try { Invoke-Elevated $script } catch { Log "could not elevate to write the launch redirect: $($_.Exception.Message)" 'WARN' }
  return (Test-LaunchRedirect $image $target $wrapper)
}

# Drops this path's redirect. The image key itself goes only if nothing else is left in
# it, since other software may keep its own options there.
function Remove-LaunchRedirect($image, $target) {
  $mainPath = Join-Path $IfeoRoot $image
  $main = ConvertTo-Literal $mainPath
  $key  = ConvertTo-Literal (Get-RedirectKey $image $target)
  $script = @"
if (Test-Path $key) { Remove-Item $key -Recurse -Force }
`$m = Get-Item $main -ErrorAction SilentlyContinue
if (`$m -and `$m.SubKeyCount -eq 0 -and ((@(`$m.GetValueNames()) -join ',') -in @('', 'UseFilter'))) { Remove-Item $main -Force }
"@
  Invoke-Elevated $script
}
