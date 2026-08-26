# The wrapper that replaces chrome.exe: it launches the newest private mirror with the
# debug flags injected, waits for it, and returns its exit code.
#
# It carries a REAL FileVersion (the version it launches), which is not cosmetic:
# Chrome's installer only excludes a version directory whose name matches chrome.exe's
# FileVersion, so an unstamped wrapper (0.0.0.0) leaves Chrome's own install purgeable.
# AssemblyFileVersion alone sets that resource; AssemblyVersion is deliberately NOT set,
# as it rejects any component above 65534 and a future build number would fail the
# compile and abort the run.
$wrapperSrc = @'
using System; using System.Diagnostics; using System.IO; using System.Reflection; using System.Text;
__STAMPATTR__
class Wrapper {
  static string StripArgv0(string cmd){
    cmd=cmd.TrimStart();
    if(cmd.StartsWith("\"")){int e=cmd.IndexOf('"',1);return e<0?"":cmd.Substring(e+1).TrimStart();}
    int s=cmd.IndexOfAny(new[]{' ','\t'}); return s<0?"":cmd.Substring(s+1).TrimStart();
  }
  // Split a command line into arguments, honouring quotes.
  static System.Collections.Generic.List<string> Tokens(string cmd){
    var list=new System.Collections.Generic.List<string>(); var sb=new StringBuilder(); bool q=false;
    foreach(char c in cmd){
      if(c=='"'){ q=!q; continue; }
      if(!q && (c==' '||c=='\t')){ if(sb.Length>0){ list.Add(sb.ToString()); sb.Length=0; } continue; }
      sb.Append(c);
    }
    if(sb.Length>0) list.Add(sb.ToString());
    return list;
  }
  // True only if some ARGUMENT starts with `flag`. A plain substring test would let
  // a URL such as https://x/?q=--type=renderer masquerade as a flag and silently
  // suppress the debug port.
  static bool Has(string cmd,string flag){
    foreach(var t in Tokens(cmd)) if(t.StartsWith(flag,StringComparison.OrdinalIgnoreCase)) return true;
    return false;
  }
  static string MirrorRoot(){
    string o=Environment.GetEnvironmentVariable("__MIRRORENV__");
    if(!string.IsNullOrEmpty(o)) return o;
    return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"__MIRRORDIR__");
  }
  // Newest complete mirror. The completion marker matters: without it a
  // half-built mirror (interrupted sync) would look launchable and the browser
  // would start against a version directory that is missing files.
  static string NewestMirror(){
    string root=MirrorRoot();
    if(!Directory.Exists(root)) return null;
    string best=null; Version bv=null;
    foreach(var d in Directory.GetDirectories(root)){
      string name=Path.GetFileName(d); Version v;
      if(!Version.TryParse(name,out v)) continue;
      if(!File.Exists(Path.Combine(d,"__LAUNCHER__"))) continue;
      if(!Directory.Exists(Path.Combine(d,name))) continue;
      if(!File.Exists(Path.Combine(d,"__SENTINEL__"))) continue;
      if(bv==null||v>bv){bv=v;best=Path.Combine(d,"__LAUNCHER__");}
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
        // Without this, CDP Page.captureScreenshot never returns while the window is
        // minimised: the copy request waits for a draw or a newer surface, and a
        // minimised window gives neither. This feature allocates a LocalSurfaceId per
        // capture, the dequeue event. Off by default in Chromium (crbug.com/377715191).
        // Skipped if the caller brings its own --enable-features; Chrome honours one.
        if(!Has(rest,"--enable-features")) sb.Append("--enable-features=CDPScreenshotNewSurface ");
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

# The C# we actually compile: the template with lib/Common.ps1's mirror layout
# substituted in, so the wrapper and Sync-Mirror cannot describe different layouts.
# Everything downstream must hash THIS, not the template - see Get-WrapperFingerprint.
function Get-WrapperSource {
  foreach ($v in $MirrorRootEnv, $MirrorRootName, $MirrorLauncher, $MirrorSentinel) {
    if ([string]::IsNullOrWhiteSpace($v) -or $v.Contains('"') -or $v.Contains('\')) {
      throw "mirror layout value '$v' is not safe to embed in the wrapper source"
    }
  }
  return $wrapperSrc.Replace('__MIRRORENV__', $MirrorRootEnv).
                    Replace('__MIRRORDIR__', $MirrorRootName).
                    Replace('__LAUNCHER__',  $MirrorLauncher).
                    Replace('__SENTINEL__',  $MirrorSentinel)
}
