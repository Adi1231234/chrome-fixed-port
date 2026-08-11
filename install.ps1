# One-line bootstrap. Downloads run.ps1 (+ lib/) to a temp folder, runs it once, cleans up.
#
#   irm https://raw.githubusercontent.com/Adi1231234/chrome-fixed-port/main/install.ps1 | iex
#
# run.ps1 is the tool; lib/Get-ExeIcon.ps1 gives it Chrome's icon. It only applies the
# wrapper - scheduling it to run periodically is up to you. Safe to re-run (idempotent).
#
# A failing run.ps1 is re-raised as a terminating error, so a scheduled task running
# this one-liner reports failure instead of silently succeeding. It throws rather than
# calling exit because this script is dot-executed into the caller's session by `iex`,
# and `exit` there would tear down an interactive console.
$ErrorActionPreference = 'Stop'
$repo   = 'Adi1231234/chrome-fixed-port'
$branch = 'main'
# keep run.ps1 and its lib/ together; Get-ExeIcon.ps1 is the only optional one
$files  = 'run.ps1', 'lib/Common.ps1', 'lib/Mirror.ps1', 'lib/Wrapper.ps1', 'lib/Get-ExeIcon.ps1'

# TLS 1.2 for stock Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cfp-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    Write-Host "Downloading chrome-fixed-port ($repo@$branch)..." -ForegroundColor Cyan
    foreach ($f in $files) {
        $dest = Join-Path $tmp ($f -replace '/', '\')
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/$branch/$f" -OutFile $dest -UseBasicParsing
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'run.ps1')
    $code = $LASTEXITCODE
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($code -ne 0) { throw "chrome-fixed-port: run.ps1 failed with exit code $code" }
