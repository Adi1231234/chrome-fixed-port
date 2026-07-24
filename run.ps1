# SELF-CONTAINED scheduled runner. Paste into your scheduled task.
# Makes every Chrome launch open --remote-debugging-port=9225 via a wrapper,
# WITHOUT ever overwriting the binary a running browser uses - so a Chrome
# self-update can never cause the version-skew that crashes new tabs.
# Mechanism (full write-up in README.md):
#   chrome.exe                = our tiny wrapper (launches the newest genuine binary + the flag)
#   chrome_real_<version>.exe = genuine Chrome launcher, one immutable copy per version
#   On update we ride Google's own swap: prime new_chrome.exe with the wrapper so
#   Google promotes it to chrome.exe for us (no window, no re-apply race).

$WRAPPER_VER = '2'  # bump whenever $wrapperSrc changes, to force a reinstall
$dir = if ($env:CHROME_FIXED_PORT_DIR) { $env:CHROME_FIXED_PORT_DIR } else { "$env:LOCALAPPDATA\Google\Chrome\Application" }
$exe       = Join-Path $dir 'chrome.exe'
$newChrome = Join-Path $dir 'new_chrome.exe'
$marker    = Join-Path $dir '.wrapper_ver'
$realRe    = '^chrome_real_\d+(\.\d+){1,3}$'   # matches chrome_real_150.0.7871.184, not chrome_real_old_*

function Log($msg, $lvl = 'INFO') {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $c = switch ($lvl) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} 'ACT' {'Cyan'} default {'Gray'} }
  Write-Host "[$ts] [$lvl] $msg" -ForegroundColor $c
}
function Test-Google($p) {
  if (-not (Test-Path $p)) { return $false }
  $s = Get-AuthenticodeSignature $p
  return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'Google')
}
function Test-Locked($p) {
  try { $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
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
  static string NewestReal(string dir){
    string best=null; Version bv=null;
    foreach(var f in Directory.GetFiles(dir,"chrome_real_*.exe")){
      var s=Path.GetFileNameWithoutExtension(f).Substring("chrome_real_".Length);
      Version v; if(Version.TryParse(s,out v)){ if(bv==null||v>bv){bv=v;best=f;} }
    }
    return best;
  }
  static int Main(){
    string wp=Process.GetCurrentProcess().MainModule.FileName;
    string real=NewestReal(Path.GetDirectoryName(wp));
    if(real==null) return 1;
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

# Compile the wrapper in a throwaway temp dir; returns @{Exe; Tmp}. Caller removes Tmp.
function Build-Wrapper {
  $tmp = Join-Path $env:TEMP ('cw_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $cs = Join-Path $tmp 'w.cs'; Set-Content -Path $cs -Value $wrapperSrc -Encoding UTF8
  $we = Join-Path $tmp 'w.exe'
  $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  & $csc -nologo -target:winexe -out:$we $cs | Out-Null
  if (-not (Test-Path $we)) { throw 'wrapper compile failed (is .NET Framework csc present?)' }
  return @{ Exe = $we; Tmp = $tmp }
}

# Move a genuine launcher at $path into chrome_real_<ver>.exe (immutable per version),
# or just drop $path if that version is already stored. Never overwrites an existing copy.
function Stash-Genuine($path) {
  $v = (Get-Item $path).VersionInfo.FileVersion
  $target = Join-Path $dir "chrome_real_$v.exe"
  try {
    if (Test-Path $target) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    else { Move-Item $path $target -Force; Log "stashed genuine v$v -> $(Split-Path $target -Leaf)" 'ACT' }
  } catch { Log "could not stash $(Split-Path $path -Leaf): $($_.Exception.Message)" 'WARN' }
}

Log "=== apply start (chrome fixed-port wrapper) user=$env:USERNAME dir=$dir ==="
$code = 0; $wrap = $null
try {
  if (-not (Test-Path $dir)) { throw "Application dir not found: $dir" }
  $wrap = Build-Wrapper

  # STEP 0: migrate a legacy fixed-name chrome_real.exe into the versioned scheme
  $legacy = Join-Path $dir 'chrome_real.exe'
  if ((Test-Path $legacy) -and (Test-Google $legacy) -and -not (Test-Locked $legacy)) { Stash-Genuine $legacy }

  # STEP 1: ride Google's swap - prime new_chrome.exe with our wrapper so Google promotes it
  if ((Test-Path $newChrome) -and (Test-Google $newChrome)) {
    Stash-Genuine $newChrome
    Copy-Item $wrap.Exe $newChrome -Force
    Log "primed new_chrome.exe with wrapper (rides Google's next swap)" 'ACT'
  }

  # STEP 2: ensure chrome.exe is our current wrapper
  $needInstall = $false
  if (-not (Test-Path $exe)) { $needInstall = $true }
  elseif (Test-Google $exe) {                                   # missed the window: Google put genuine here
    if (Test-Locked $exe) { Log "chrome.exe is genuine but locked by a running browser - deferring to next run" 'WARN' }
    else { Stash-Genuine $exe; $needInstall = $true; Log "chrome.exe was genuine (missed swap window) - reinstalling wrapper" 'ACT' }
  }
  elseif ((-not (Test-Path $marker)) -or ((Get-Content $marker -ErrorAction SilentlyContinue) -ne $WRAPPER_VER)) { $needInstall = $true }
  if ($needInstall) {
    if ((Test-Path $exe) -and (Test-Locked $exe)) { Log "chrome.exe locked - cannot reinstall wrapper this run" 'WARN' }
    else { Copy-Item $wrap.Exe $exe -Force; Set-Content -Path $marker -Value $WRAPPER_VER -Encoding ASCII; Log "installed wrapper v$WRAPPER_VER at chrome.exe" 'OK' }
  }

  # STEP 3: cleanup - keep newest chrome_real_<ver>.exe + any locked; delete the rest
  $reals = @(Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -match $realRe } |
             Sort-Object { [version]($_.BaseName -replace '^chrome_real_', '') })
  if ($reals.Count -gt 1) {
    $newest = $reals[-1].FullName
    foreach ($f in $reals) {
      if ($f.FullName -eq $newest) { continue }
      if (Test-Locked $f.FullName) { continue }
      Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; Log "removed stale $($f.Name)"
    }
  }
  # sweep old random-suffix leftovers from the previous design, once unlocked
  Get-ChildItem $dir -Filter 'chrome_real_old_*.exe' -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Locked $_.FullName) } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; Log "removed legacy leftover $($_.Name)" }

  $have = @(Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match $realRe })
  if ($have.Count -eq 0) { Log "no genuine chrome_real_<ver>.exe present - wrapper has nothing to launch" 'WARN' }
  else { Log "state OK: wrapper at chrome.exe, $($have.Count) versioned genuine binary(ies), newest=$($have[-1].Name)" 'OK' }
}
catch { Log "FAILED: $($_.Exception.Message)" 'ERR'; $code = 1 }
finally { if ($wrap) { Remove-Item $wrap.Tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Log "=== apply done (exit=$code) ==="
exit $code
