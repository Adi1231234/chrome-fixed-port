# One-line bootstrap. Downloads the repo to a temp folder, runs run.ps1 once, cleans up.
#
#   irm https://raw.githubusercontent.com/Adi1231234/chrome-fixed-port/main/install.ps1 | iex
#
# run.ps1 is the tool; it needs the whole lib/ folder beside it. It only applies the
# wrapper - scheduling it to run periodically is up to you. Safe to re-run (idempotent).
#
# We fetch the branch archive rather than a hand-written list of files. That list drifted
# once: lib/Update.ps1 was added to the repo and not to the list, so every scheduled run
# downloaded an incomplete lib/, run.ps1 failed to dot-source it, and the run died after
# installing the wrapper but before finishing the update. An archive cannot drift.
#
# A failing run.ps1 is re-raised as a terminating error, so a scheduled task running
# this one-liner reports failure instead of silently succeeding. It throws rather than
# calling exit because this script is dot-executed into the caller's session by `iex`,
# and `exit` there would tear down an interactive console.
$ErrorActionPreference = 'Stop'
$repo   = 'Adi1231234/chrome-fixed-port'
$branch = 'main'

# TLS 1.2 for stock Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cfp-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    Write-Host "Downloading chrome-fixed-port ($repo@$branch)..." -ForegroundColor Cyan
    $zip = Join-Path $tmp 'src.zip'
    Invoke-WebRequest -Uri "https://codeload.github.com/$repo/zip/refs/heads/$branch" -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

    # GitHub names the archive root <repo>-<branch>; find it rather than assuming.
    $run = Get-ChildItem $tmp -Filter 'run.ps1' -Recurse -File | Select-Object -First 1
    if (-not $run) { throw "chrome-fixed-port: run.ps1 not found in the downloaded archive" }
    $lib = Join-Path $run.DirectoryName 'lib'
    if (-not (Test-Path $lib)) { throw "chrome-fixed-port: lib/ not found beside run.ps1" }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $run.FullName
    $code = $LASTEXITCODE
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($code -ne 0) { throw "chrome-fixed-port: run.ps1 failed with exit code $code" }
