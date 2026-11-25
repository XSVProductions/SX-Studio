# Builds a release of SX Studio for Windows and prints the files to upload to GitHub Releases.
#   powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Version 2.0.1
# Needs Flutter on PATH and Inno Setup 6 (jrsoftware.org). Writes, in build\windows at the top of the repository:
#   SX-Studio-windows-setup-<version>.exe   the installer, what the app's Update button downloads
#   SHA256SUMS.txt                          its checksum; the app refuses a download that does not match
param([string]$Version = '2.0.0')
$ErrorActionPreference = 'Stop'
$ui = Split-Path $PSScriptRoot
$root = Split-Path $ui
$release = Join-Path $ui 'build\windows\x64\runner\Release'
$out = Join-Path $root 'build\windows'

$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it from jrsoftware.org, then run this again.' }

Push-Location $ui
try {
  # no CDN: a phone on a venue network must get every file from the laptop
  flutter build web --release --no-web-resources-cdn
  if ($LASTEXITCODE) { throw 'The web build failed.' }
  # windows\CMakeLists.txt copies the web build into Release\web
  flutter build windows --release "--build-name=$Version" "--dart-define=SX_VERSION=$Version"
  if ($LASTEXITCODE) { throw 'The Windows build failed.' }
} finally { Pop-Location }
if (-not (Test-Path -LiteralPath (Join-Path $release 'web\index.html'))) { throw 'The phone page is missing from the Windows build (Release\web).' }

# The Visual C++ runtime the app needs, next to it, for a laptop that has none installed.
# The 64-bit files: a 32-bit PowerShell sees them under Sysnative.
$sys = Join-Path $env:SystemRoot $(if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' })
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  Copy-Item -LiteralPath (Join-Path $sys $dll) -Destination $release
}

$env:SX_VERSION = $Version
& $iscc (Join-Path $ui 'windows\installer\sx_studio.iss')
if ($LASTEXITCODE) { throw 'Inno Setup failed.' }

$setup = Get-Item -LiteralPath (Join-Path $out "SX-Studio-windows-setup-$Version.exe")
$sums = Join-Path $out 'SHA256SUMS.txt'
# the format of sha256sum: hash, two spaces, file name
$line = '{0}  {1}' -f (Get-FileHash -LiteralPath $setup.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $setup.Name
[IO.File]::WriteAllText($sums, "$line`n", [Text.UTF8Encoding]::new($false))

''
"Upload to the GitHub release v$Version of XSVProductions/SX-Studio:"
"  $($setup.FullName)"
"  $sums"
'A release with a Mac .pkg too needs one SHA256SUMS.txt listing both (the build workflow writes that).'
