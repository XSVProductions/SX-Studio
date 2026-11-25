# Installs the built installer silently, opens the app and checks it answers. Used by the build workflow.
#   powershell -ExecutionPolicy Bypass -File ui\windows\installer\smoke.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot))
$setup = Get-ChildItem (Join-Path $root 'build\windows\SX-Studio-windows-setup-*.exe') | Select-Object -First 1
if (-not $setup) { throw 'No installer in build\windows. Run ui	oolelease.ps1 first.' }
Start-Process -Wait -FilePath $setup.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
$app = Join-Path $env:LOCALAPPDATA 'Programs\ShowXpress Helper'
foreach ($f in 'sx_studio.exe', 'flutter_windows.dll', 'data\app.so', 'web\index.html', 'vcruntime140_1.dll', 'showxpress_helper.vbs') {
  if (-not (Test-Path -LiteralPath (Join-Path $app $f))) { throw "Not installed: $f" }
}
$env:SX_PORT = '47390'
$p = Start-Process -FilePath (Join-Path $app 'sx_studio.exe') -PassThru
try {
  $code = 0
  for ($i = 0; $i -lt 30 -and $code -ne 401; $i++) {
    Start-Sleep 1
    try { $code = (Invoke-WebRequest 'http://127.0.0.1:47390/api/sx' -UseBasicParsing).StatusCode } catch { $code = [int]$_.Exception.Response.StatusCode }
  }
  # no key, so the engine must refuse: that proves it is up and guarded
  if ($code -ne 401) { throw "The app's engine did not answer (got $code)." }
  if ((Invoke-WebRequest 'http://127.0.0.1:47390/' -UseBasicParsing).Content -notmatch 'flutter') { throw 'The phone page is not served.' }
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
'Installer OK'
