# The wrapper Windows runs in place of Chrome's chrome.exe (see lib/Redirect.ps1): it
# launches the newest private mirror with the debug flags injected, waits for it, and
# returns its exit code.
#
# Under the redirect, Windows starts it as `wrapper "<path>\chrome.exe" <original args>`,
# so the first argument after its own name is the redirected image, not a flag.
$wrapperSrc = @'
using System; using System.Diagnostics; using System.IO; using System.Text;
class Wrapper {
  // Returns cmd without its first argument; `first` receives that argument, unquoted.
  static string SplitFirst(string cmd,out string first){
    cmd=cmd.TrimStart(); first="";
    if(cmd.StartsWith("\"")){int e=cmd.IndexOf('"',1); if(e<0) return "";
      first=cmd.Substring(1,e-1); return cmd.Substring(e+1).TrimStart();}
    int s=cmd.IndexOfAny(new[]{' ','\t'}); first=s<0?cmd:cmd.Substring(0,s);
    return s<0?"":cmd.Substring(s+1).TrimStart();
  }
  // The caller's arguments: our own name dropped, and the redirected image Windows
  // passes next dropped too. Matched by file name only, so a caller that omitted
  // argv0 keeps its first real argument.
  static string CallerArgs(){
    string first; string rest=SplitFirst(Environment.CommandLine,out first);
    string after=SplitFirst(rest,out first);
    string name=Path.GetFileName(first.Trim());
    bool image=name.Equals("__IMAGE__",StringComparison.OrdinalIgnoreCase) ||
               name.Equals(Path.GetFileNameWithoutExtension("__IMAGE__"),StringComparison.OrdinalIgnoreCase);
    return image?after:rest;
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
    string rest=CallerArgs();
    string args;
    // A child process (--type=) belongs to a browser that already has its flags. A
    // headless launch is a script's own browser: given the debug port, a --screenshot
    // run no longer exits when it is done (measured) and holds the port from then on,
    // on ::1 when the real browser already has 127.0.0.1 (Chromium falls back to ::1).
    if(Has(rest,"--type=") || Has(rest,"--headless")){ args=rest; }
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
    // Stay alive for the browser's lifetime, so callers that wait on chrome.exe
    // (Playwright, Selenium, `start /wait`) observe the real lifetime and exit code.
    try{
      var p=Process.Start(new ProcessStartInfo{FileName=real,Arguments=args,UseShellExecute=false});
      p.WaitForExit();
      return p.ExitCode;
    }catch{ return 1; }
  }
}
'@

# The C# we actually compile: the template with lib/Common.ps1's mirror layout and
# redirected image substituted in, so the wrapper and the PowerShell side cannot
# describe different things.
# Everything downstream must hash THIS, not the template - see Get-WrapperFingerprint.
function Get-WrapperSource {
  foreach ($v in $MirrorRootEnv, $MirrorRootName, $MirrorLauncher, $MirrorSentinel, $ChromeImage) {
    if ([string]::IsNullOrWhiteSpace($v) -or $v.Contains('"') -or $v.Contains('\')) {
      throw "mirror layout value '$v' is not safe to embed in the wrapper source"
    }
  }
  return $wrapperSrc.Replace('__MIRRORENV__', $MirrorRootEnv).
                    Replace('__MIRRORDIR__', $MirrorRootName).
                    Replace('__LAUNCHER__',  $MirrorLauncher).
                    Replace('__SENTINEL__',  $MirrorSentinel).
                    Replace('__IMAGE__',     $ChromeImage)
}
