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

$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it from jrsoftware.org.' }
$env:SX_VERSION = $Version
& $iscc (Join-Path $PSScriptRoot 'sx_studio.iss')
if ($LASTEXITCODE) { throw 'Inno Setup failed.' }
