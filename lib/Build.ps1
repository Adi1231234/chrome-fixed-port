# Building the wrapper: what its identity is, how it gets compiled, and where it goes.
# Split from lib/Wrapper.ps1, which owns the source itself.

# Identity of the wrapper, derived from the source it compiles. It is stored beside the
# installed wrapper, so any change to that source reinstalls it by itself. It must hash
# the SUBSTITUTED text: hashing the template would let a mirror-layout change produce an
# identical marker, and the old layout would stay compiled in.
function Get-WrapperFingerprint { Get-ShortHash (Get-WrapperSource) }

function Get-WrapperMarker { (Get-WrapperPath) + '.ver' }

function Test-WrapperCurrent($fingerprint) {
  $m = Get-WrapperMarker
  if (-not (Test-Path (Get-WrapperPath)) -or -not (Test-Path $m)) { return $false }
  return (((Get-Content $m -Raw -ErrorAction SilentlyContinue) + '').Trim() -eq $fingerprint)
}

# Compile the wrapper in a throwaway temp dir; returns @{Exe; Tmp}. Caller removes Tmp.
# A windowless exe (winexe), so launching Chrome never flashes a console.
function New-Wrapper {
  $tmp = Join-Path $env:TEMP ('cw_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $cs = Join-Path $tmp 'w.cs'
  Set-Content -Path $cs -Value (Get-WrapperSource) -Encoding UTF8
  $we  = Join-Path $tmp 'w.exe'
  $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  & $csc -nologo -target:winexe -out:$we $cs | Out-Null
  if (-not (Test-Path $we)) { throw 'wrapper compile failed (is .NET Framework csc present?)' }
  return @{ Exe = $we; Tmp = $tmp }
}

# Put a freshly built wrapper in place. Every open browser keeps one wrapper running,
# and a running exe cannot be deleted, but NTFS does let it be renamed. So a busy one is
# moved aside and swept up by Remove-RetiredWrapper once nothing runs it any more.
function Install-Wrapper($builtExe, $fingerprint) {
  $dst = Get-WrapperPath
  if (Test-Path $dst) {
    if (Test-Locked $dst) { Move-Item $dst ("$dst." + [guid]::NewGuid().ToString('N') + '.old') -ErrorAction Stop }
    else { Remove-Item $dst -Force -ErrorAction Stop }
  }
  Copy-Item $builtExe $dst -ErrorAction Stop
  Set-Content -Path (Get-WrapperMarker) -Value $fingerprint -Encoding ASCII
}

function Remove-RetiredWrapper {
  Get-ChildItem (Get-MirrorRoot) -Filter "$WrapperName.*.old" -File -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Locked $_.FullName) } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}
