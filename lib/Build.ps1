# Building the wrapper: what its identity is, and how it gets compiled.
# Split from lib/Wrapper.ps1, which owns the source itself.

# Identity of the wrapper, derived from the source it compiles. run.ps1 stores it in
# .wrapper_ver, so any change to that source reinstalls the wrapper by itself. It must
# hash the SUBSTITUTED text: hashing the template would let a mirror-layout change
# produce an identical marker, and the old layout would stay compiled in.
function Get-WrapperFingerprint {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-WrapperSource)))
    return -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
  }
  finally { $sha.Dispose() }
}

# Compile the wrapper in a throwaway temp dir; returns @{Exe; Tmp}. Caller removes Tmp.
# $stamp is the version to embed. Chrome's icon is embedded if lib/Get-ExeIcon.ps1 is
# loaded; if that fails, the compile is retried icon-less.
function New-Wrapper($stamp, $iconSourceExe) {
  $tmp = Join-Path $env:TEMP ('cw_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null

  # A malformed version must not fail the whole run: the mirror already protects the
  # browser and the stamp only keeps Chrome's own install excluded. Carry on without it.
  $attr = ''
  if ($stamp -match '^\d+(\.\d+){3}$') { $attr = "[assembly: AssemblyFileVersion(`"$stamp`")]" }
  else { Log "version '$stamp' is not a 4-part number - building wrapper without a version stamp" 'WARN' }

  $cs = Join-Path $tmp 'w.cs'
  Set-Content -Path $cs -Value (Get-WrapperSource).Replace('__STAMPATTR__', $attr) -Encoding UTF8
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
