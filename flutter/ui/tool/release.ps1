# Builds a release of SX Studio for Windows, signs its release.json and prints the files to upload.
#   powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Version 2.0.1 [-MacPkg <path to SX-Studio-mac-2.0.1.pkg>]
#   powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Stub        (the setup program, SX-Studio-Setup.exe)
# Needs Flutter on PATH and Inno Setup 6 (jrsoftware.org). Signs with the release key in SX_RELEASE_KEY, otherwise
# %USERPROFILE%\.sx-release\release_key. Never needs the code-signing certificate. -NoSign builds only (the build workflow).
# Writes, in build\windows in the flutter folder:
#   SX-Studio-windows-setup-<version>.exe   the installer
#   release.json, release.json.sig          what the app's Update and the setup program trust
#   SHA256SUMS.txt                          checksums, for people
param([string]$Version = '2.0.0', [string]$MacPkg = '', [switch]$NoSign, [switch]$Stub)
$ErrorActionPreference = 'Stop'
$ui = Split-Path $PSScriptRoot
$root = Split-Path $ui
$tool = Join-Path $root 'packages\sx_release'

if ($Stub) {
  $out = Join-Path $root 'build\setup'
  New-Item -ItemType Directory -Force $out | Out-Null
  $exe = Join-Path $out 'SX-Studio-Setup.exe'
  Push-Location $tool
  try {
    dart pub get | Out-Null
    dart compile exe bin\setup_stub.dart -o $exe
    if ($LASTEXITCODE) { throw 'The setup program did not build.' }
  } finally { Pop-Location }
  ''
  "Built $exe"
  'Sign it (once, by hand), then upload it to the GitHub release tagged "setup" (a pre-release, never Latest):'
  "  signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 <certificate options> `"$exe`""
  '  gh release create setup --prerelease --latest=false --title "SX Studio setup" --notes "Installs the newest SX Studio." "<signed exe>"'
  'Never put it in a normal release: the PowerShell SX Studio installs the first .exe of the newest release.'
  return
}

$release = Join-Path $ui 'build\windows\x64\runner\Release'
$out = Join-Path $root 'build\windows'
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it from jrsoftware.org, then run this again.' }
if ($MacPkg -and -not (Test-Path -LiteralPath $MacPkg)) { throw "No file $MacPkg." }

Push-Location $ui
try {
  # a checkout that gained a package since its last build needs this first
  flutter pub get
  if ($LASTEXITCODE) { throw 'flutter pub get failed.' }
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

# only this version's installer in the folder: the release must hold exactly one .exe
Get-ChildItem -LiteralPath $out -Filter '*.exe' -ErrorAction SilentlyContinue | Remove-Item -Force
$env:SX_VERSION = $Version
& $iscc (Join-Path $ui 'windows\installer\sx_studio.iss')
if ($LASTEXITCODE) { throw 'Inno Setup failed.' }
$setup = Join-Path $out "SX-Studio-windows-setup-$Version.exe"
if ($NoSign) { "Built $setup (not signed: -NoSign)"; return }

$sign = @('run', 'sx_release:release_tool', 'manifest', '--version', $Version, '--out', $out, '--windows', $setup)
if ($MacPkg) { $sign += @('--mac', (Resolve-Path -LiteralPath $MacPkg).Path) }
Push-Location $tool
try {
  dart pub get | Out-Null
  dart @sign
  if ($LASTEXITCODE) { throw 'release.json was not signed.' }
} finally { Pop-Location }

$files = @($setup, (Join-Path $out 'release.json'), (Join-Path $out 'release.json.sig'), (Join-Path $out 'SHA256SUMS.txt'))
if ($MacPkg) { $files += (Resolve-Path -LiteralPath $MacPkg).Path }
$exes = @($files | Where-Object { $_ -match '\.exe$' })
if ($exes.Count -ne 1) { throw 'A release must hold exactly one .exe, the installer: the PowerShell SX Studio installs the first one it finds.' }
''
"Upload to a new GitHub release of XSVProductions/SX-Studio tagged v${Version}:"
$files | ForEach-Object { "  $_" }
'  gh release create v' + $Version + ' --title "SX Studio ' + $Version + '" ' + (($files | ForEach-Object { "`"$_`"" }) -join ' ')
if (-not $MacPkg) { 'No Mac .pkg in this release: Macs see no update until a release has one (-MacPkg).' }
