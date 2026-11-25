# Installs the built installer silently, opens the app and checks it answers, then uninstalls it while it runs. Used by the build workflow.
#   powershell -ExecutionPolicy Bypass -File ui\windows\installer\smoke.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot))
$setup = Get-ChildItem (Join-Path $root 'build\windows\SX-Studio-windows-setup-*.exe') | Select-Object -First 1
if (-not $setup) { throw 'No installer in build\windows. Run ui\tool\release.ps1 first.' }
$silent = '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
if (Get-Process explorer -ErrorAction SilentlyContinue) {
  # as the PowerShell app's updater does: Start-Process -Wait also waits for all the installer started. The app the
  # installer opens must not count, or that updater opens the app again when it quits.
  $job = Start-Job { param($f, $a) Start-Process -Wait -FilePath $f -ArgumentList $a } -ArgumentList $setup.FullName, $silent
  if (-not (Wait-Job $job -Timeout 300)) { throw 'The installer did not come back: the app it opened counts as part of it.' }
} else {
  # no desktop (Explorer) to open the app through: wait for the installer alone
  (Start-Process -FilePath $setup.FullName -ArgumentList $silent -PassThru).WaitForExit()
}
$app = Join-Path $env:LOCALAPPDATA 'Programs\ShowXpress Helper'
foreach ($f in 'sx_studio.exe', 'flutter_windows.dll', 'data\app.so', 'web\index.html', 'vcruntime140_1.dll', 'showxpress_helper.vbs') {
  if (-not (Test-Path -LiteralPath (Join-Path $app $f))) { throw "Not installed: $f" }
}
$env:SX_PORT = '47390'
$p = Start-Process -FilePath (Join-Path $app 'sx_studio.exe') -PassThru
try {
  $code = 0
  for ($i = 0; $i -lt 30 -and $code -ne 403; $i++) {
    Start-Sleep 1
    try { $code = (Invoke-WebRequest 'http://127.0.0.1:47390/api/sx' -UseBasicParsing).StatusCode } catch { $code = [int]$_.Exception.Response.StatusCode }
  }
  # no key, so the engine must refuse: that proves it is up and guarded
  if ($code -ne 403) { throw "The app's engine did not answer (got $code)." }
  if ((Invoke-WebRequest 'http://127.0.0.1:47390/' -UseBasicParsing).Content -notmatch 'flutter') { throw 'The phone page is not served.' }
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
# uninstall while the app runs, as from Windows' app list: nothing of the app may stay behind
$p = Start-Process -FilePath (Join-Path $app 'sx_studio.exe') -PassThru
Start-Sleep 5
Start-Process -Wait -FilePath (Join-Path $app 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $app); $i++) { Start-Sleep 1 }
if (Test-Path -LiteralPath $app) { throw "Uninstalling left files behind: $((Get-ChildItem -LiteralPath $app -Recurse -Name) -join ', ')" }
'Installer OK'
