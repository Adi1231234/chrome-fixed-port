# Shared plumbing: logging, path resolution, version parsing, and the two guards
# every destructive step consults. Dot-sourced by run.ps1 before anything else.

$script:VersionRe = '^\d+(\.\d+){3}$'   # Chrome version dirs are always 4 components

function Log($msg, $lvl = 'INFO') {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $c = switch ($lvl) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} 'ACT' {'Cyan'} default {'Gray'} }
  Write-Host "[$ts] [$lvl] $msg" -ForegroundColor $c
}

# Chrome's own Application directory - the one Google's installer owns and purges.
function Get-ChromeDir {
  if ($env:CHROME_FIXED_PORT_DIR) { return $env:CHROME_FIXED_PORT_DIR }
  return "$env:LOCALAPPDATA\Google\Chrome\Application"
}

# Our private mirror root. Google's installer has no idea this exists, which is
# the entire point: nothing in here can be classified as a stray version.
function Get-MirrorRoot {
  if ($env:CHROME_FIXED_PORT_MIRROR) { return $env:CHROME_FIXED_PORT_MIRROR }
  return "$env:LOCALAPPDATA\ChromeFixedPort"
}

function Test-Google($p) {
  if (-not (Test-Path $p)) { return $false }
  $s = Get-AuthenticodeSignature $p
  return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'Google')
}

# Asks for WRITE access on purpose. A mapped image (a running .exe or a loaded
# .dll) denies write, so this reliably reports "a browser is still using it".
# Chrome's own installer check asks only for read, which a mapped image permits -
# that is precisely why it deletes version directories that are still in use.
function Test-Locked($p) {
  try { $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
}

function Get-FileVersion($p) {
  if (-not (Test-Path $p)) { return $null }
  $v = (Get-Item $p).VersionInfo.FileVersion
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return $v.Trim()
}

# Version-named subdirectories of $dir, oldest first. Sorted numerically, not
# alphabetically - "7922.109" must sort after "7922.76".
function Get-VersionDirs($dir) {
  return @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match $script:VersionRe } |
           Sort-Object { [version]$_.Name })
}

# Any process currently executing out of $dir (or below it).
function Get-LiveProcessCount($dir) {
  $d = $dir.TrimEnd('\') + '\'
  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
           Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($d, 'OrdinalIgnoreCase') }).Count
}
