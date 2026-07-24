# One-line bootstrap. Downloads run.ps1 to a temp folder, runs it once, cleans up.
#
#   irm https://raw.githubusercontent.com/Adi1231234/chrome-fixed-port/main/install.ps1 | iex
#
# run.ps1 is the whole tool (one self-contained script). It only applies the wrapper -
# scheduling it to run periodically is up to you. Safe to re-run: run.ps1 is idempotent.
$ErrorActionPreference = 'Stop'
$repo   = 'Adi1231234/chrome-fixed-port'
$branch = 'main'

# TLS 1.2 for stock Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cfp-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $runPs1 = Join-Path $tmp 'run.ps1'
    Write-Host "Downloading chrome-fixed-port ($repo@$branch)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/$branch/run.ps1" -OutFile $runPs1 -UseBasicParsing
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runPs1
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
