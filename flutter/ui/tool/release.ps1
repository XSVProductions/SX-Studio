# Builds build\windows\SX-Studio-windows-setup-<version>.exe. Needs Flutter on PATH and Inno Setup 6.
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build.ps1 -Version 2.0.0
param([string]$Version = '2.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)

Push-Location (Join-Path $root 'ui')
try {
  # no CDN: a phone on a venue network must get every file from the laptop
  flutter build web --release --no-web-resources-cdn
  if ($LASTEXITCODE) { throw 'The web build failed.' }
  flutter build windows --release "--build-name=$Version" "--dart-define=SX_VERSION=$Version"
  if ($LASTEXITCODE) { throw 'The Windows build failed.' }
} finally { Pop-Location }

# The Visual C++ runtime the app needs, next to it, for a laptop that has none installed.
# The 64-bit files: a 32-bit PowerShell sees them under Sysnative.
$sys = Join-Path $env:SystemRoot $(if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' })
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  Copy-Item -LiteralPath (Join-Path $sys $dll) -Destination (Join-Path $root 'ui\build\windows\x64\runner\Release')
}

$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it from jrsoftware.org.' }
$env:SX_VERSION = $Version
& $iscc (Join-Path $PSScriptRoot 'sx_studio.iss')
if ($LASTEXITCODE) { throw 'Inno Setup failed.' }
