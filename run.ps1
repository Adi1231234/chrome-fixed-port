# SELF-CONTAINED scheduled runner. Paste into your scheduled task.
# Makes every Chrome launch open --remote-debugging-port=9225 via a wrapper,
# WITHOUT ever overwriting the binary a running browser uses - so a Chrome
# self-update can never cause the version-skew that crashes new tabs.
# Mechanism (full write-up in README.md):
#   chrome.exe                = our tiny wrapper (launches the newest genuine binary + the flag)
#   chrome_real_<version>.exe = genuine Chrome launcher, one immutable copy per version
#   On update we ride Google's own swap: prime new_chrome.exe with the wrapper so
#   Google promotes it to chrome.exe for us (no window, no re-apply race).

$WRAPPER_VER = '3'  # bump when $wrapperSrc OR the embedded-icon logic changes, to force a reinstall
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

# Rebuilds a real multi-resolution .ico from a PE's FIRST icon group (what a
# "chrome.exe,0" shortcut asks for), by copying the RT_GROUP_ICON directory and
# its RT_ICON images verbatim - so the wrapper shows Chrome's own icon.
$icoRipSrc = @'
using System; using System.IO; using System.Runtime.InteropServices;
public static class IcoRip {
  const int RT_ICON=3, RT_GROUP_ICON=14; const uint AS_DATAFILE=0x2;
  delegate bool EnumProc(IntPtr h, IntPtr t, IntPtr n, IntPtr p);
  [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryEx(string f, IntPtr h, uint fl);
  [DllImport("kernel32",SetLastError=true)] static extern bool FreeLibrary(IntPtr h);
  [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="EnumResourceNamesW")] static extern bool EnumResourceNames(IntPtr h, IntPtr t, EnumProc cb, IntPtr p);
  [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="FindResourceW")] static extern IntPtr FindById(IntPtr h, IntPtr n, IntPtr t);
  [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true,EntryPoint="FindResourceW")] static extern IntPtr FindByName(IntPtr h, string n, IntPtr t);
  [DllImport("kernel32",SetLastError=true)] static extern IntPtr LoadResource(IntPtr h, IntPtr r);
  [DllImport("kernel32")] static extern IntPtr LockResource(IntPtr d);
  [DllImport("kernel32",SetLastError=true)] static extern uint SizeofResource(IntPtr h, IntPtr r);
  static string _gName; static IntPtr _gId; static readonly EnumProc _cb = Grab;
  // First group name. Chrome's groups are STRING names (e.g. IDR_MAINFRAME), so copy
  // the string out during the callback - the pointer is only valid until it returns.
  static bool Grab(IntPtr h, IntPtr t, IntPtr n, IntPtr p){
    if((long)n < 0x10000) { _gId=n; } else { _gName=Marshal.PtrToStringUni(n); } return false;
  }
  static byte[] Bytes(IntPtr h, IntPtr r){
    if(r==IntPtr.Zero) throw new Exception("resource missing");
    uint sz=SizeofResource(h,r); byte[] b=new byte[sz]; Marshal.Copy(LockResource(LoadResource(h,r)),b,0,(int)sz); return b;
  }
  public static void Save(string exe, string ico){
    IntPtr h=LoadLibraryEx(exe,IntPtr.Zero,AS_DATAFILE); if(h==IntPtr.Zero) throw new Exception("LoadLibraryEx failed");
    try{
      _gName=null; _gId=(IntPtr)(-1); EnumResourceNames(h,(IntPtr)RT_GROUP_ICON,_cb,IntPtr.Zero);
      if(_gName==null && _gId==(IntPtr)(-1)) throw new Exception("no icon group");
      IntPtr gr = _gName!=null ? FindByName(h,_gName,(IntPtr)RT_GROUP_ICON) : FindById(h,_gId,(IntPtr)RT_GROUP_ICON);
      byte[] g=Bytes(h,gr); int n=BitConverter.ToUInt16(g,4);
      using(var ms=new MemoryStream()){ var w=new BinaryWriter(ms);
        w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)n);   // ICONDIR
        int off=6+16*n; var imgs=new byte[n][];
        for(int i=0;i<n;i++){ int e=6+14*i;
          w.Write(g,e,12);                                            // bWidth..dwBytesInRes
          imgs[i]=Bytes(h,FindById(h,(IntPtr)BitConverter.ToUInt16(g,e+12),(IntPtr)RT_ICON));
          w.Write(off); off+=imgs[i].Length;                          // dwImageOffset
        }
        for(int i=0;i<n;i++) w.Write(imgs[i]);
        File.WriteAllBytes(ico, ms.ToArray());
      }
    } finally { FreeLibrary(h); }
  }
}
'@

# Extract $srcExe's icon into $icoPath. Fail-safe: returns $false (never throws) so a
# bad extraction just yields an icon-less wrapper instead of failing the whole run.
function Export-ExeIcon($srcExe, $icoPath) {
  try {
    if (-not ('IcoRip' -as [type])) { Add-Type -TypeDefinition $icoRipSrc -ErrorAction Stop }
    [IcoRip]::Save($srcExe, $icoPath)
    return (Test-Path $icoPath)
  } catch { Log "icon extract failed ($(Split-Path $srcExe -Leaf)): $($_.Exception.Message)" 'WARN'; return $false }
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
# When $IconSrc is a genuine Chrome exe, embed its icon so the wrapper shows Chrome's
# icon (shortcuts read "chrome.exe,0"). Fail-safe: if embedding fails, retry icon-less.
function New-Wrapper($IconSrc) {
  $tmp = Join-Path $env:TEMP ('cw_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $cs = Join-Path $tmp 'w.cs'; Set-Content -Path $cs -Value $wrapperSrc -Encoding UTF8
  $we = Join-Path $tmp 'w.exe'
  $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  $icoArg = @()
  if ($IconSrc) {
    $ico = Join-Path $tmp 'chrome.ico'
    if (Export-ExeIcon $IconSrc $ico) { $icoArg = @("-win32icon:$ico") }
  }
  & $csc -nologo -target:winexe @icoArg -out:$we $cs | Out-Null
  if ((-not (Test-Path $we)) -and $icoArg.Count) {
    Log 'compile with embedded icon failed - retrying without icon' 'WARN'
    & $csc -nologo -target:winexe -out:$we $cs | Out-Null
  }
  if (-not (Test-Path $we)) { throw 'wrapper compile failed (is .NET Framework csc present?)' }
  return @{ Exe = $we; Tmp = $tmp }
}

# Move a genuine launcher at $path into chrome_real_<ver>.exe (immutable per version),
# or just drop $path if that version is already stored. Never overwrites an existing copy.
function Save-Genuine($path) {
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

  # Pick a genuine Chrome exe to lift the icon from: newest chrome_real_<ver>.exe,
  # else a staged genuine new_chrome.exe, else a genuine chrome.exe (pre-first-install).
  $realsForIcon = @(Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -match $realRe } |
                    Sort-Object { [version]($_.BaseName -replace '^chrome_real_', '') })
  $iconSrc = if ($realsForIcon.Count) { $realsForIcon[-1].FullName }
             elseif ((Test-Path $newChrome) -and (Test-Google $newChrome)) { $newChrome }
             elseif ((Test-Path $exe) -and (Test-Google $exe)) { $exe }
             else { $null }
  $wrap = New-Wrapper $iconSrc

  # STEP 1: ride Google's swap - prime new_chrome.exe with our wrapper so Google promotes it
  if ((Test-Path $newChrome) -and (Test-Google $newChrome)) {
    Save-Genuine $newChrome
    Copy-Item $wrap.Exe $newChrome -Force
    Log "primed new_chrome.exe with wrapper (rides Google's next swap)" 'ACT'
  }

  # STEP 2: ensure chrome.exe is our current wrapper
  $needInstall = $false
  if (-not (Test-Path $exe)) { $needInstall = $true }
  elseif (Test-Google $exe) {                                   # missed the window: Google put genuine here
    if (Test-Locked $exe) { Log "chrome.exe is genuine but locked by a running browser - deferring to next run" 'WARN' }
    else { Save-Genuine $exe; $needInstall = $true; Log "chrome.exe was genuine (missed swap window) - reinstalling wrapper" 'ACT' }
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
