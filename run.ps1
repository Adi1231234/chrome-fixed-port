# SELF-CONTAINED + SELF-CLEANING. Paste into your scheduled runner.
# Makes every Chrome launch open --remote-debugging-port=9225 on the real profile
# (chrome.exe -> wrapper -> chrome_real.exe). Idempotent, self-healing, leaves NO folders.

$dir  = "$env:LOCALAPPDATA\Google\Chrome\Application"
$exe  = Join-Path $dir 'chrome.exe'
$real = Join-Path $dir 'chrome_real.exe'

function Log($msg, $level = 'INFO') {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $c = switch ($level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} 'ACT' {'Cyan'} default {'Gray'} }
  Write-Host "[$ts] [$level] $msg" -ForegroundColor $c
}
function Test-Google($p) {
  if (-not (Test-Path $p)) { return $false }
  $s = Get-AuthenticodeSignature $p
  return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'Google')
}

$wrapperSrc = @'
using System; using System.Diagnostics; using System.IO; using System.Text;
class Wrapper {
  static string StripArgv0(string cmd){
    cmd=cmd.TrimStart();
    if(cmd.StartsWith("\"")){int e=cmd.IndexOf('"',1);return e<0?"":cmd.Substring(e+1).TrimStart();}
    int s=cmd.IndexOfAny(new[]{' ','\t'}); return s<0?"":cmd.Substring(s+1).TrimStart();
  }
  static bool Has(string h,string n){return h.IndexOf(n,StringComparison.OrdinalIgnoreCase)>=0;}
  static int Main(){
    string wp=Process.GetCurrentProcess().MainModule.FileName;
    string real=Path.Combine(Path.GetDirectoryName(wp),"chrome_real.exe");
    string rest=StripArgv0(Environment.CommandLine);
    string args;
    if(Has(rest,"--type=")){ args=rest; }
    else{
      string ov=Environment.GetEnvironmentVariable("CHROME_WRAP_OVERRIDE"); string flags;
      if(!string.IsNullOrEmpty(ov)){ flags=ov+" "; }
      else{
        var sb=new StringBuilder();
        if(!Has(rest,"--remote-debugging-port")) sb.Append("--remote-debugging-port=9225 --remote-allow-origins=* ");
        if(!Has(rest,"--user-data-dir")){
          string udd=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Google\\ChromeDebug");
          sb.Append("--user-data-dir=\""+udd+"\" ");
        }
        flags=sb.ToString();
      }
      args=(flags+rest).Trim();
    }
    try{ Process.Start(new ProcessStartInfo{FileName=real,Arguments=args,UseShellExecute=false}); }catch{ return 1; }
    return 0;
  }
}
'@

# Compile the wrapper in a throwaway temp dir, install it as $target, then delete the temp dir.
function Install-Wrapper($target) {
  $tmp = Join-Path $env:TEMP ("chromewrap_" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $cs = Join-Path $tmp 'wrapper.cs'; Set-Content -Path $cs -Value $wrapperSrc -Encoding UTF8
    $we = Join-Path $tmp 'wrapper.exe'
    $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /target:winexe /out:$we $cs | Out-Null
    if (-not (Test-Path $we)) { throw "wrapper compile failed (is .NET Framework csc present?)" }
    Copy-Item $we $target -Force
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Log "=== apply start (chrome debug wrapper) user=$env:USERNAME ==="
$code = 0
try {
  if (-not (Test-Path $exe)) { throw "chrome.exe not found at $exe - is Chrome installed for this user?" }

  $stale = @(Get-ChildItem $dir -Filter 'chrome_real_old_*.exe' -ErrorAction SilentlyContinue)
  if ($stale.Count) {
    $removed = 0
    foreach ($f in $stale) { try { Remove-Item $f.FullName -Force -ErrorAction Stop; $removed++ } catch {} }
    Log "cleaned $removed of $($stale.Count) stale copies (any left are locked by a running Chrome)"
  }

  $exeGoogle  = Test-Google $exe
  $realExists = Test-Path $real
  $realGoogle = Test-Google $real
  Log "state: chrome.exe genuine=$exeGoogle  chrome_real.exe exists=$realExists genuine=$realGoogle"

  if (Test-Path (Join-Path $dir 'new_chrome.exe')) {
    Log "a Chrome update is mid-swap (new_chrome.exe present) - skipping, will fix next run" 'WARN'
  }
  elseif ((-not $exeGoogle) -and $realGoogle) {
    Log "already applied - wrapper in place and genuine chrome_real.exe present. Nothing to do." 'OK'
  }
  elseif ($exeGoogle) {
    Log "chrome.exe is genuine (v$((Get-Item $exe).VersionInfo.FileVersion)) - a Chrome update reverted the wrapper. Re-applying." 'ACT'
    if ($realExists) {
      $aside = Join-Path $dir ("chrome_real_old_{0}.exe" -f (Get-Random))
      Move-Item $real $aside -Force
      Log "moved existing chrome_real.exe aside -> $(Split-Path $aside -Leaf)"
    }
    Move-Item $exe $real -Force
    Install-Wrapper $exe
    Log "APPLIED: chrome.exe = wrapper, chrome_real.exe = genuine v$((Get-Item $real).VersionInfo.FileVersion)" 'OK'
  }
  else {
    Log "UNEXPECTED: chrome.exe not genuine and no genuine chrome_real.exe. Restore chrome.exe manually." 'ERR'
    $code = 2
  }
}
catch {
  Log "FAILED: $($_.Exception.Message)" 'ERR'
  $code = 1
}
Log "=== apply done (exit=$code) ==="
exit $code
