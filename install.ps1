# One-line bootstrap. Downloads run.ps1, registers a per-user scheduled task that
# keeps the wrapper in place across Chrome updates, and runs it once now.
#
#   irm https://raw.githubusercontent.com/Adi1231234/chrome-fixed-port/main/install.ps1 | iex
#
# run.ps1 is the whole tool (one self-contained script), so we fetch just that file.
# Safe to re-run: the task is re-registered in place and run.ps1 is idempotent.
$ErrorActionPreference = 'Stop'
$repo    = 'Adi1231234/chrome-fixed-port'
$branch  = 'main'
$task    = 'ChromeFixedPort'
$everyMin = 30

# TLS 1.2 for stock Windows PowerShell 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Stable install location so the scheduled task always points at the same file.
$appDir = Join-Path $env:LOCALAPPDATA 'chrome-fixed-port'
New-Item -ItemType Directory -Force $appDir | Out-Null
$runPs1 = Join-Path $appDir 'run.ps1'

Write-Host "Downloading chrome-fixed-port ($repo@$branch)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/$branch/run.ps1" -OutFile $runPs1 -UseBasicParsing

# Register (or update) a task that runs ONLY in this user's own session: an
# Interactive current-user principal (no stored password, no admin) plus a
# logon trigger scoped to this user. An unscoped -AtLogOn means "any user" and
# needs elevation - that is what fails with Access denied from a normal shell.
$me = "$env:USERDOMAIN\$env:USERNAME"
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runPs1`""
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
$repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $everyMin)
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $action -Trigger @($atLogon, $repeat) `
    -Principal $principal -Settings $settings `
    -Description 'Keep every Chrome launch on a fixed remote-debugging port' -Force | Out-Null
Write-Host "Registered scheduled task '$task' (every $everyMin min + at logon)." -ForegroundColor Green

# Run once now so the wrapper is applied immediately.
Write-Host "Running once now..." -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runPs1
Write-Host "Done. Close and reopen Chrome once so Google's swap promotes the wrapper." -ForegroundColor Green
