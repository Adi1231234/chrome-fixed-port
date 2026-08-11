# The wrapper that replaces chrome.exe: it launches the newest private mirror
# with the debug flags injected, waits for it, and returns its exit code.
#
# It is compiled carrying a REAL FileVersion (the version it launches). That is
# not cosmetic: Chrome's installer excludes a version directory from deletion
# only when its name matches chrome.exe's FileVersion, so an unstamped wrapper
# (0.0.0.0) leaves Chrome's own install classified as stray and purgeable.

$wrapperSrc = @'
using System; using System.Diagnostics; using System.IO; using System.Reflection; using System.Text;
[assembly: AssemblyFileVersion("__STAMP__")]
[assembly: AssemblyVersion("__STAMP__")]
class Wrapper {
  static string StripArgv0(string cmd){
    cmd=cmd.TrimStart();
    if(cmd.StartsWith("\"")){int e=cmd.IndexOf('"',1);return e<0?"":cmd.Substring(e+1).TrimStart();}
    int s=cmd.IndexOfAny(new[]{' ','\t'}); return s<0?"":cmd.Substring(s+1).TrimStart();
  }
  static bool Has(string h,string n){return h.IndexOf(n,StringComparison.OrdinalIgnoreCase)>=0;}
  static string MirrorRoot(){
    string o=Environment.GetEnvironmentVariable("CHROME_FIXED_PORT_MIRROR");
    if(!string.IsNullOrEmpty(o)) return o;
    return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ChromeFixedPort");
  }
  // Newest <root>\<ver>\chrome.exe that still has its matching <ver>\ beside it.
  static string NewestMirror(){
    string root=MirrorRoot();
    if(!Directory.Exists(root)) return null;
    string best=null; Version bv=null;
    foreach(var d in Directory.GetDirectories(root)){
      string name=Path.GetFileName(d); Version v;
      if(!Version.TryParse(name,out v)) continue;
      if(!File.Exists(Path.Combine(d,"chrome.exe"))) continue;
      if(!Directory.Exists(Path.Combine(d,name))) continue;
      if(bv==null||v>bv){bv=v;best=Path.Combine(d,"chrome.exe");}
    }
    return best;
  }
  static int Main(){
    string real=NewestMirror();
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
    // Stay alive for the browser's lifetime so chrome.exe is held open while a
    // browser runs, and so callers that wait on chrome.exe (Playwright, Selenium,
    // `start /wait`) observe the real lifetime and the real exit code.
    try{
      var p=Process.Start(new ProcessStartInfo{FileName=real,Arguments=args,UseShellExecute=false});
      p.WaitForExit();
      return p.ExitCode;
    }catch{ return 1; }
  }
}
'@

# Compile the wrapper in a throwaway temp dir; returns @{Exe; Tmp}. Caller removes Tmp.
# $stamp is the version to embed. If lib/Get-ExeIcon.ps1 is loaded, Chrome's icon is
# embedded too. Fail-safe: if embedding fails, retry the compile icon-less.
function New-Wrapper($stamp, $iconSourceExe) {
  if (-not $stamp) { throw 'New-Wrapper needs a version to stamp' }
  $tmp = Join-Path $env:TEMP ('cw_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $cs = Join-Path $tmp 'w.cs'
  Set-Content -Path $cs -Value $wrapperSrc.Replace('__STAMP__', $stamp) -Encoding UTF8
  $we  = Join-Path $tmp 'w.exe'
  $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

  $icoArg = @()
  if ($iconSourceExe -and (Get-Command Resolve-WrapperIcon -ErrorAction SilentlyContinue)) {
    $ico = Resolve-WrapperIcon $iconSourceExe $tmp
    if ($ico) { $icoArg = @("-win32icon:$ico") }
  }
  & $csc -nologo -target:winexe @icoArg -out:$we $cs | Out-Null
  if ((-not (Test-Path $we)) -and $icoArg.Count) {
    Log 'compile with embedded icon failed - retrying without icon' 'WARN'
    & $csc -nologo -target:winexe -out:$we $cs | Out-Null
  }
  if (-not (Test-Path $we)) { throw 'wrapper compile failed (is .NET Framework csc present?)' }
  return @{ Exe = $we; Tmp = $tmp }
}
