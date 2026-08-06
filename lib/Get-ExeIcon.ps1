# Icon extraction, split out of run.ps1 (its own responsibility). Dot-sourced by
# run.ps1 from ./lib. Rebuilds a real multi-resolution .ico from a PE's FIRST icon
# group - what a "chrome.exe,0" shortcut asks for - by copying the RT_GROUP_ICON
# directory and its RT_ICON images verbatim, so the wrapper shows Chrome's own icon.
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
  } catch {
    $m = "icon extract failed ($(Split-Path $srcExe -Leaf)): $($_.Exception.Message)"
    if (Get-Command Log -ErrorAction SilentlyContinue) { Log $m 'WARN' } else { Write-Warning $m }
    return $false
  }
}

# Pick a genuine Chrome exe (newest chrome_real_<ver>.exe, else a staged genuine
# new_chrome.exe, else a genuine chrome.exe) and extract its icon to $tmp\chrome.ico.
# Returns the .ico path, or $null if there is no source / extraction failed.
# Uses Test-Google, resolved from run.ps1's scope via dot-sourcing.
function Resolve-WrapperIcon($dir, $realRe, $newChrome, $exe, $tmp) {
  $reals = @(Get-ChildItem $dir -Filter 'chrome_real_*.exe' -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -match $realRe } |
             Sort-Object { [version]($_.BaseName -replace '^chrome_real_', '') })
  $src = if ($reals.Count) { $reals[-1].FullName }
         elseif ((Test-Path $newChrome) -and (Test-Google $newChrome)) { $newChrome }
         elseif ((Test-Path $exe) -and (Test-Google $exe)) { $exe }
         else { $null }
  if (-not $src) { return $null }
  $ico = Join-Path $tmp 'chrome.ico'
  if (Export-ExeIcon $src $ico) { return $ico } else { return $null }
}
