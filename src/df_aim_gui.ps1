# ShowXpress Helper (was AIM MOVERS) - small GUI (Windows PowerShell 5.1 + macOS pwsh 7).
# Runs a private web page on this computer only (localhost + random key) and opens it as an app window
# (Edge/Chrome "app" mode, else the normal browser). Each tab is backed by a script that does the work:
#   Tonight's Rig -> rig.ps1   Aim Movers -> df_aim.ps1       Skip Flash -> skip_flash.ps1
#   APC mini -> apc.ps1        Speed Faders -> speed.ps1      Health Check -> health.ps1 (check, fix, revert)
#   Rig Test -> rig_test.ps1   Pre-show Check -> preshow.ps1
#   Auto Show -> sx_remote.ps1 (also presses RIG ID / DF CHECK / ROOM CHECK in a running ShowXpress through its remote)
#   LIVE AIM (Aim Movers tab) -> dmx_out.ps1 drives the DMX interface while ShowXpress is closed; df_aim.ps1 LiveInfo / LiveSave
# Quits by itself a few minutes after its window is closed.
param([string]$TestRoot = '', [int]$Port = 47321, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'df_aim.ps1'
$skipEngine   = Join-Path $here 'skip_flash.ps1'
$rigEngine    = Join-Path $here 'rig.ps1'
$apcEngine    = Join-Path $here 'apc.ps1'
$speedEngine  = Join-Path $here 'speed.ps1'
$healthEngine = Join-Path $here 'health.ps1'
$rtEngine     = Join-Path $here 'rig_test.ps1'
$preEngine    = Join-Path $here 'preshow.ps1'
$colorEngine  = Join-Path $here 'color.ps1'
$gdEngine     = Join-Path $here 'gdrive.ps1'
$liveEngine   = Join-Path $here 'dmx_out.ps1'
$remoteEngine = Join-Path $here 'sx_remote.ps1'
$repo   = 'XSVProductions/showxpress-helper'
$verF   = Join-Path $here 'version.txt'
$appVer = if (Test-Path -LiteralPath $verF) { ([IO.File]::ReadAllText($verF)).Trim() } else { '0.0.0' }
$updInfo = $null
$onMac  = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
$psExe  = (Get-Process -Id $PID).Path
$infoF  = Join-Path ([IO.Path]::GetTempPath()) 'showxpress_helper_gui.json'
$idleMax = 300   # seconds without the window checking in -> quit

function Open-AppWindow($url) {
  if ($NoBrowser) { return }
  if ($onMac) {
    foreach ($b in 'Google Chrome', 'Microsoft Edge', 'Brave Browser') {
      if (Test-Path "/Applications/$b.app") { & open -na "$b" --args "--app=$url" '--window-size=1120,880'; return }
    }
    & open $url; return
  }
  $cands = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
             "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { Start-Process $c -ArgumentList "--app=$url", '--window-size=1120,880'; return } }
  Start-Process $url
}

# ---- one copy only: if it's already running, just bring up its window
#      (an older version still running - e.g. right after an update - is stopped and replaced)
$token = [guid]::NewGuid().ToString('N')
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
try { $l.Start() }
catch {
  $i = $null
  if (Test-Path $infoF) { try { $i = Get-Content $infoF -Raw | ConvertFrom-Json } catch {} }
  $old = $null
  if ($i -and $i.pid -and "$($i.ver)" -ne $appVer) { $old = Get-Process -Id $i.pid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(pwsh|powershell)$' } }
  $up = $false
  if ($old) {
    $old | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($n = 0; $n -lt 20 -and -not $up; $n++) {
      Start-Sleep -Milliseconds 250
      $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$Port/")
      try { $l.Start(); $up = $true } catch {}
    }
  }
  if (-not $up) {
    if ($i) { Open-AppWindow $i.url; return }
    throw "Port $Port is busy and no running ShowXpress Helper was found."
  }
}
$url = "http://localhost:$Port/?t=$token"
[IO.File]::WriteAllText($infoF, (@{ url = $url; pid = $PID; ver = $appVer } | ConvertTo-Json))

function Test-SxOpen {
  if ($TestRoot) { return (Test-Path -LiteralPath (Join-Path $TestRoot '_sx_open')) }   # testing: marker file = "ShowXpress open"
  [bool](Get-Process | Where-Object { $_.ProcessName -match 'TheLightingController|ShowXpress' })
}
function Get-SxExe {
  foreach ($p in "$env:ProgramFiles\ShowXpress\TheLightingController.exe", "${env:ProgramFiles(x86)}\ShowXpress\TheLightingController.exe") { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  $null
}
function Get-Update {
  # newest release on GitHub, asked once per run (generic User-Agent - nothing about this computer is sent)
  if ($script:updInfo) { return $script:updInfo }
  try {
    if (-not $onMac) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'ShowXpress-Helper'; Accept = 'application/vnd.github+json' } -TimeoutSec 10 -UseBasicParsing
    $lat = "$($rel.tag_name)".TrimStart('v')
    $as = @($rel.assets | Where-Object { $_.name -match $(if ($onMac) { '\.pkg$' } else { '\.exe$' }) }) | Select-Object -First 1
    $newer = $false; try { $newer = [version]$lat -gt [version]$appVer } catch {}
    $script:updInfo = @{ ok = $true; mac = $onMac; current = $appVer; latest = $lat; newer = ($newer -and [bool]$as); asset = "$($as.browser_download_url)"; name = "$($as.name)" }
  } catch { return @{ ok = $false; mac = $onMac; current = $appVer; error = 'Could not reach GitHub.' } }
  $script:updInfo
}
function Update-SkipFlash($ids) {
  # SKIP FLASH follows the hung heads too (it needs 2 or more)
  $ids = @($ids | Where-Object { "$_" -match '^\d+$' })
  if ($ids.Count -lt 2) { return "`n  SKIP FLASH not changed (it needs at least 2 heads)" }
  $r = Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $skipEngine
  if (-not $r.ok) { return "`n  SKIP FLASH NOT updated: $($r.error)" }
  if ($r.out -match 'nothing to change') { "`n  SKIP FLASH already flashes these $($ids.Count) heads" } else { "`n  SKIP FLASH now flashes $($ids.Count) heads" }
}
function Send-Png($ctx, [string]$p) {
  $ib = [IO.File]::ReadAllBytes($p); $ctx.Response.ContentType = 'image/png'; $ctx.Response.Headers.Add('Cache-Control', 'no-store')
  $ctx.Response.ContentLength64 = $ib.Length; $ctx.Response.OutputStream.Write($ib, 0, $ib.Length); $ctx.Response.Close()
}

function Invoke-Engine([string]$engineArgs, [string]$script = $engine) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" $engineArgs"
  if ($TestRoot) { $a += " -TestRoot `"$TestRoot`"" }
  $psi.Arguments = $a
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; return @{ ok = $false; out = ''; error = 'Timed out.' } }
  $esc = [string][char]27 + '\[[0-9;]*m'; $out = $o.Result -replace $esc, ''; $err = $e.Result -replace $esc, ''
  $msg = ''
  if ($p.ExitCode -ne 0 -or $err.Trim()) {
    $el = @($err -split "`r?`n")
    $tl = -1; for ($i = 0; $i -lt $el.Count; $i++) { if ($el[$i] -match '^\s*\|\s*~+\s*$') { $tl = $i } }
    if ($tl -ge 0) {
      # PowerShell 7 (Mac) "concise" errors:  Line | ... / | ~~~~ / | the message (may wrap over several | lines)
      $msg = (@($el[($tl + 1)..($el.Count - 1)] | Where-Object { $_ -match '^\s*\|' } | ForEach-Object { ($_ -replace '^\s*\|\s?', '').Trim() }) -join ' ').Trim()
    } else {
      # Windows PowerShell 5.1:  C:\...\df_aim.ps1 : the message  /  At line... / + CategoryInfo ...
      $msg = (($el | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(At |\+ |\+\s|CategoryInfo|FullyQualifiedErrorId|~)' } | Select-Object -First 1))
      $msg = ("$msg" -replace '^.*?\.ps1\s*:\s*', '' -replace '^\w*Exception:\s*', '').Trim()
    }
    if (-not $msg -or $msg -match '^\d+$') { $msg = "Something went wrong (code $($p.ExitCode)) - see Full details." ; $out = "$out`n$err" }
  }
  @{ ok = (-not $msg); out = $out; error = $msg }
}

function Send-Text($ctx, [int]$code, [string]$type, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text); $r = $ctx.Response
  $r.StatusCode = $code; $r.ContentType = $type; $r.Headers.Add('Cache-Control', 'no-store'); $r.ContentLength64 = $b.Length
  $r.OutputStream.Write($b, 0, $b.Length); $r.Close()
}
function Send-Json($ctx, $obj) { Send-Text $ctx 200 'application/json; charset=utf-8' ($obj | ConvertTo-Json -Depth 6 -Compress) }
function Send-EngineJson($ctx, $r) {
  # engine printed one line of JSON (Preview / Check) -> pass it straight on
  if ($r.ok) {
    $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if ($j) { Send-Text $ctx 200 'application/json; charset=utf-8' $j } else { Send-Json $ctx @{ ok = $false; error = 'No answer from the helper script.' } }
  } else { Send-Json $ctx @{ ok = $false; error = $r.error } }
}
function Invoke-WithChanges([string]$script, $items) {
  # list of changes -> temp JSON file -> engine -Action Apply -ChangesFile (no quoting trouble on the command line)
  $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($cf, (ConvertTo-Json -InputObject @($items) -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
  try { Invoke-Engine "-Action Apply -ChangesFile `"$cf`"" $script } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
}

# Mac: TheLightingController.app (ShowXpress) - in Applications, or in a ShowXpress folder there (the download's layout,
# with the interface driver efk_hardware.dylib next to the app)
function Find-SxMacApp {
  $c = @()
  foreach ($r in '/Applications', (Join-Path $HOME 'Applications')) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $c += @(Get-ChildItem -LiteralPath $r -Directory -Filter '*.app' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' })
    foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' -and $_.Name -notlike '*.app' })) {
      $c += @(Get-ChildItem -LiteralPath $d.FullName -Directory -Filter '*.app' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' })
    }
  }
  if (-not $c.Count) {
    $c += @(& mdfind "kMDItemFSName == 'TheLightingController.app'" 2>$null | Where-Object { $_ -and $_ -notmatch '^/Volumes/' } | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
  }
  @($c | Sort-Object { -not (Test-Path -LiteralPath (Join-Path (Split-Path $_.FullName) 'efk_hardware.dylib')) }) | Select-Object -First 1
}
function Start-Sx {
  if ($TestRoot) { [IO.File]::WriteAllText((Join-Path $TestRoot '_sx_open'), 'test'); return @{ ok = $true; out = '  (test) ShowXpress would open now'; error = '' } }
  if (Test-SxOpen) { return @{ ok = $true; out = '  ShowXpress is already open'; error = '' } }
  if ($onMac) {
    $a = Find-SxMacApp
    if (-not $a) { return @{ ok = $false; error = 'ShowXpress was not found in Applications.'; out = '' } }
    & open $a.FullName
  } else {
    $x = Get-SxExe
    if (-not $x) { return @{ ok = $false; error = 'ShowXpress was not found in Program Files\ShowXpress.'; out = '' } }
    Start-Process -FilePath $x -WorkingDirectory (Split-Path $x)
  }
  @{ ok = $true; out = '  ShowXpress is starting'; error = '' }
}

# ---- LIVE AIM (user 2026-11-21): the Helper sends DMX itself (dmx_out.ps1 child process) so the real heads follow the
# mouse. Only one program can use the interface, so ShowXpress must be closed. The child stops by itself (lights out)
# if the Helper stops talking to it for 30 s.
$script:liveP = $null; $script:liveHold = [datetime]::MinValue
function Test-Live { [bool]($script:liveP -and -not $script:liveP.HasExited) }
function Stop-Live {
  $p = $script:liveP; $script:liveP = $null
  if (-not $p) { return }
  try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('q'); if (-not $p.WaitForExit(4000)) { $p.Kill() } } } catch { try { $p.Kill() } catch {} }
}
function Start-Live {
  Stop-Live
  $exe = $psExe; $ea = "-NoProfile -ExecutionPolicy Bypass -File `"$liveEngine`""
  if ($TestRoot) { $ea += " -Fake -FakeLog `"$(Join-Path $TestRoot '_dmx_frame.txt')`"" }
  elseif ($onMac) {
    # Mac: a small tool inside the app (Contents/MacOS/sxh_dmx) drives the interface through ShowXpress's own driver
    $a = Find-SxMacApp
    if (-not $a) { return @{ ok = $false; error = 'ShowXpress was not found in Applications, so its interface driver was not found either.'; out = '' } }
    $exe = Join-Path (Split-Path $here) 'MacOS/sxh_dmx'
    if (-not (Test-Path -LiteralPath $exe)) { return @{ ok = $false; error = 'The live aim part of the Helper is missing - install the Helper again.'; out = '' } }
    $ea = "--dir `"$(Split-Path $a.FullName)`""
  }
  $why = ''
  foreach ($try in 1..3) {   # right after ShowXpress closes the interface can take a moment to be free
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $ea; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.AutoFlush = $true
    $t = $p.StandardOutput.ReadLineAsync()
    if (-not $t.Wait(20000)) { try { $p.Kill() } catch {}; $why = 'The DMX interface did not answer.'; continue }
    $line = "$($t.Result)"
    if ($line -like 'OK *') { $script:liveP = $p; return @{ ok = $true; iface = $line.Substring(3); out = ''; error = '' } }
    try { if (-not $p.WaitForExit(3000)) { $p.Kill() } } catch {}
    if ($line -eq 'ERR none') { $why = 'The DMX interface (D512S) was not found. Check its USB cable - unplug it, plug it back in, wait a few seconds - and try again. ShowXpress must stay closed.' }
    elseif ($line -like 'ERR *') { $why = $line.Substring(4); break }
    else { $why = "The DMX output didn't start: $(($p.StandardError.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1))"; break }
    Start-Sleep -Milliseconds 1500
  }
  @{ ok = $false; error = $why; out = '' }
}

# ---- everything that changes the show. Called straight away, or later from the queue (see below).
function Invoke-Action([string]$path, $body) {
  switch ($path) {
    '/api/aim/install' { return (Invoke-Engine '-Action Install -Mode Room') }
    '/api/color/apply' {
      $hx = "$($body.hex)".Trim().TrimStart('#')
      if ($hx -notmatch '^[0-9a-fA-F]{6}$') { return @{ ok = $false; error = 'Pick a colour first.'; out = '' } }
      $nm = ("$($body.name)" -replace '[^A-Za-z0-9 \-]', '').Trim(); if ($nm.Length -gt 30) { $nm = $nm.Substring(0, 30) }
      $na = if ($nm) { " -Name `"$nm`"" } else { '' }
      return (Invoke-Engine "-Action Apply -Color $hx$na" $colorEngine)
    }
    '/api/gdrive/sync' { return (Invoke-Engine '-Action Sync' $gdEngine) }
    '/api/apply' {
      $w = [int]$body.w; $d = [int]$body.d
      if ($w -lt 20 -or $w -gt 300 -or $d -lt 20 -or $d -gt 300) { return @{ ok = $false; error = 'Size must be 20-300%.'; out = '' } }
      $f = if ($body.force) { ' -Force' } else { '' }
      $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }
      $r = Invoke-Engine "-Action Apply -Size `"$w $d`" -NoPrompt$f$mo"
      # when ShowXpress is (next) open, show the result: DF CHECK 140 + 251 / ROOM CHECK
      if ($r.ok) { if ($mo) { Set-PendingPress @('ROOM CHECK') 'ROOM CHECK' } else { Set-PendingPress @('DF CHECK 140', 'DF CHECK 251') 'DF CHECK 140 + 251' } }
      return $r
    }
    '/api/home' { $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }; return (Invoke-Engine "-Action Home -NoPrompt$mo") }
    '/api/skip/apply' {
      $ids = @($body.heads | ForEach-Object { "$_" })
      if (@($ids | Where-Object { $_ -notmatch '^\d+$' }).Count -or $ids.Count -lt 2) { return @{ ok = $false; error = 'Pick at least 2 heads.'; out = '' } }
      return (Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $skipEngine)
    }
    '/api/rig/apply' {
      $ids = @($body.heads | ForEach-Object { "$_" })
      if (@($ids | Where-Object { $_ -notmatch '^\d+$' }).Count -or $ids.Count -lt 1) { return @{ ok = $false; error = 'Tick at least one head.'; out = '' } }
      $r = Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $rigEngine
      if ($r.ok) { $r.out += Update-SkipFlash $ids }
      return $r
    }
    '/api/apc/apply' {
      $items = @(foreach ($c in @($body.changes)) { if ($c) { $o = [ordered]@{ sec = "$($c.sec)"; title = "$($c.title)"; note = $c.note }; if ($null -ne $c.on) { $o.on = $c.on; $o.off = $c.off }; $o } })
      $badC = @($items | Where-Object { $_.Contains('on') -and (("$($_.on)" -notmatch '^\d+$') -or ("$($_.off)" -notmatch '^\d+$') -or [int]$_.on -gt 127 -or [int]$_.off -gt 127) }).Count
      if ($badC -or -not $items.Count -or @($items | Where-Object { $_.sec -notmatch '^page\d+_button\d+$' -or "$($_.note)" -notmatch '^-?\d+$' -or [int]$_.note -lt -1 -or [int]$_.note -gt 63 }).Count) {
        return @{ ok = $false; error = 'Nothing valid to save.'; out = '' } }
      return (Invoke-WithChanges $apcEngine $items)
    }
    '/api/speed/apply' {
      $items = @(foreach ($c in @($body.changes)) { if ($c) { [ordered]@{ sec = "$($c.sec)"; title = "$($c.title)"; fader = $c.fader } } })
      if (-not $items.Count -or @($items | Where-Object { $_.sec -notmatch '^page\d+_button\d+$' -or "$($_.fader)" -notmatch '^\d+$' -or [int]$_.fader -gt 99 }).Count) {
        return @{ ok = $false; error = 'Nothing valid to save.'; out = '' } }
      return (Invoke-WithChanges $speedEngine $items)
    }
    '/api/health/fix' {
      $k = "$($body.key)"
      if ($k -notmatch '^(speed|midiout|midilight|pad|color|fixtures)\|(page\d+_button\d+|\d+)$') { return @{ ok = $false; error = 'Unknown fix.'; out = '' } }
      return (Invoke-Engine "-Action Fix -FixId `"$k`"" $healthEngine)
    }
    '/api/rt/install' { return (Invoke-Engine '-Action Install' $rtEngine) }
    '/api/remote/enable' { return (Invoke-Engine '-Action Enable' $remoteEngine) }
    '/api/rt/apply' {
      $as = [ordered]@{}
      if ($body.assign) { foreach ($pp in $body.assign.PSObject.Properties) { if ($pp.Name -match '^(tl|tr|tm|bl|br|bm)-(l|r)$' -and "$($pp.Value)" -match '^\d+$') { $as[$pp.Name] = "$($pp.Value)" } } }
      if (-not $as.Count) { return @{ ok = $false; error = 'Put at least one mover on a truss.'; out = '' } }
      $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
      [IO.File]::WriteAllText($cf, (@{ assign = $as; extra = [bool]$body.extra } | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
      try { $r = Invoke-Engine "-Action Apply -ChangesFile `"$cf`"" $rtEngine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
      if ($r.ok -and $body.rig) {
        $hl = ($r.out -split "`r?`n") | Where-Object { $_ -match '^RIGHEADS: [\d,]+$' } | Select-Object -Last 1
        if ($hl) { $r2 = Invoke-Engine "-Action Apply -Heads `"$($hl.Substring(10))`"" $rigEngine
          if ($r2.ok) { $r.out += "`n  Tonight's Rig:`n" + $r2.out } else { $r.out += "`n  Tonight's Rig NOT updated: $($r2.error)" } }
        $sl = ($r.out -split "`r?`n") | Where-Object { $_ -match '^SKIPHEADS: [\d,]+$' } | Select-Object -Last 1
        if ($sl) { $r.out += Update-SkipFlash ($sl.Substring(11) -split ',') }
      }
      return $r
    }
  }
  @{ ok = $false; error = 'Unknown action.'; out = '' }
}

# ---- QUEUE (user 2026-11-21: close ShowXpress only once a night). While ShowXpress is open, Save/Apply in any tab is
# queued; as soon as ShowXpress has been closed for a few seconds (it rewrites live.ini as it closes) the queue runs in
# order (Google Drive sync always last) and ShowXpress is opened again. A later save of the same thing replaces the
# earlier one. The Helper doesn't quit while something is queued.
$queueable = @{
  '/api/apply' = 'Aim Movers'; '/api/home' = 'Aim Movers (reset)'; '/api/aim/install' = 'ROOM buttons on the SETUP page'
  '/api/color/apply' = "Tonight's Color"; '/api/skip/apply' = 'Skip Flash'; '/api/rig/apply' = "Tonight's Rig"
  '/api/apc/apply' = 'APC pads'; '/api/speed/apply' = 'Speed faders'; '/api/health/fix' = 'Health fix'
  '/api/rt/install' = 'RIG ID button'; '/api/rt/apply' = 'Rig Test (2D view)'; '/api/gdrive/sync' = 'Sync to Google Drive'
  '/api/remote/enable' = 'ShowXpress remote control' }
$queue = New-Object Collections.Generic.List[object]
$qReopen = $true; $qDone = $null; $qClosed = 0
function Get-QueueKey([string]$path, $body) {
  if ($path -eq '/api/apply' -or $path -eq '/api/home') { return "aim-$(if ("$($body.mode)" -eq 'room') { 'room' } else { 'floor' })" }
  if ($path -eq '/api/health/fix') { return "fix-$($body.key)" }
  $path
}
function Add-Queue([string]$path, $body) {
  $key = Get-QueueKey $path $body
  $label = $queueable[$path]
  if ($key -like 'aim-*') { $label = "$label - $(if ($key -eq 'aim-room') { 'Room' } else { 'Dance Floor' })" }
  if ($path -eq '/api/color/apply') { $label = "$label (#$("$($body.hex)".TrimStart('#').ToLower()))" }
  $old = @($queue | Where-Object { $_.key -eq $key })
  foreach ($o in $old) { [void]$queue.Remove($o) }
  $queue.Add([pscustomobject]@{ key = $key; label = $label; path = $path; body = ($body | ConvertTo-Json -Depth 6 -Compress) })
  @{ ok = $true; queued = $true; replaced = [bool]$old.Count; label = $label; out = ''; error = '' }
}
function Get-QueueInfo {
  @{ items = @($queue | ForEach-Object { @{ key = $_.key; label = $_.label } }); reopen = $qReopen; done = $qDone }
}
function Step-Queue {
  # called about once a second by the main loop
  if (-not $queue.Count) { $script:qClosed = 0; return }
  if (Test-SxOpen) { $script:qClosed = 0; return }
  # live aim closed ShowXpress / is running: the queue waits for it (it runs when live aim is saved)
  if ((Test-Live) -or ((Get-Date) - $script:liveHold).TotalSeconds -lt 180) { $script:qClosed = 0; return }
  $script:qClosed++
  if ($script:qClosed -lt 4) { return }   # give ShowXpress time to finish writing the show
  Invoke-QueueItems $qReopen
}
function Invoke-QueueItems([bool]$reopen) {
  $items = @($queue | Where-Object { $_.path -ne '/api/gdrive/sync' }) + @($queue | Where-Object { $_.path -eq '/api/gdrive/sync' })
  $queue.Clear(); $script:qClosed = 0
  $res = @(foreach ($it in $items) {
    $b = $it.body | ConvertFrom-Json
    $r = try { Invoke-Action $it.path $b } catch { @{ ok = $false; error = $_.Exception.Message; out = '' } }
    @{ label = $it.label; ok = [bool]$r.ok; error = "$($r.error)"; out = "$($r.out)" }
  })
  $reo = $null
  if ($reopen) { $reo = try { Start-Sx } catch { @{ ok = $false; error = $_.Exception.Message } } }
  $script:qDone = @{ at = (Get-Date).ToString('s'); results = $res; reopened = [bool]($reo -and $reo.ok); reopenError = $(if ($reo -and -not $reo.ok) { "$($reo.error)" } else { '' }) }
}

# ---- SHOWXPRESS REMOTE (user 2026-11-22): the Helper presses Live buttons itself (sx_remote.ps1, ShowXpress "External
# App" TCP remote). Rig Test turns RIG ID on, Aim turns DF AIM / DF CHECK on, and after an aim Apply the CHECK buttons
# come on by themselves as soon as ShowXpress is open again. Automatic presses never cut a running show (-Idle).
$titleRx = '^[^"|\r\n]{1,80}$'
function Invoke-Remote([string]$act, [string[]]$titles = @(), [string]$flags = '') {
  $ta = if (@($titles).Count) { " -Titles `"$(@($titles) -join '|')`"" } else { '' }
  $r = Invoke-Engine "-Action $act$ta $flags" $remoteEngine
  $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
  if ($j) { return ($j | ConvertFrom-Json) }
  [pscustomobject]@{ ok = $false; error = $(if ($r.error) { $r.error } else { 'No answer from the helper script.' }) }
}
$script:pend = $null; $script:pendT = [datetime]::MinValue; $script:remLast = $null
function Set-PendingPress([string[]]$titles, [string]$label, [int]$secs = 1200) { $script:pend = @{ titles = $titles; label = $label; until = (Get-Date).AddSeconds($secs) } }
function Step-Pending {
  $p = $script:pend; if (-not $p) { return }
  if ((Get-Date) -gt $p.until -or (Test-Auto)) { $script:pend = $null; return }
  if (((Get-Date) - $script:pendT).TotalSeconds -lt 3 -or -not (Test-SxOpen) -or (Test-Live)) { return }
  $script:pendT = Get-Date
  $r = Invoke-Remote 'Press' $p.titles '-Solo -Idle'
  if ($r.connected -or ($r.PSObject.Properties['ready'] -and -not $r.ready)) {
    $script:pend = $null
    $script:remLast = @{ at = (Get-Date).ToString('o'); label = $p.label; ok = [bool]($r.connected -and -not $r.skipped); skipped = [bool]$r.skipped
                         playing = @($r.playing); error = "$($r.error)" }
  }
}

# ---- AUTO SHOW (user 2026-11-22): sx_remote.ps1 -Action Auto runs as a child process and plays the looks from
# <show>/auto_show.json; commands go to its stdin, it writes its state to a temp file. The Helper doesn't quit while it plays.
$script:autoP = $null; $autoStat = Join-Path ([IO.Path]::GetTempPath()) "sxh_autoshow_$PID.json"
function Test-Auto { [bool]($script:autoP -and -not $script:autoP.HasExited) }
function Get-AutoStatus {
  $s = $null
  if (Test-Path -LiteralPath $autoStat) { try { $s = [IO.File]::ReadAllText($autoStat) | ConvertFrom-Json } catch {} }
  if ($s -and -not (Test-Auto)) { $s.running = $false }
  $s
}
function Stop-Auto {
  $p = $script:autoP; $script:autoP = $null
  if (-not $p) { return }
  try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('q'); if (-not $p.WaitForExit(6000)) { $p.Kill() } } } catch { try { $p.Kill() } catch {} }
}
function Send-Auto([string]$c) { if (Test-Auto) { try { $script:autoP.StandardInput.WriteLine($c); return $true } catch {} }; $false }
function Start-Auto([string]$look) {
  Stop-Auto
  Remove-Item -LiteralPath $autoStat -ErrorAction SilentlyContinue
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$remoteEngine`" -Action Auto -StatusFile `"$autoStat`""
  if ($look -match '^[0-9a-f]{8}$') { $a += " -Titles $look" }
  if ($TestRoot) { $a += " -TestRoot `"$TestRoot`"" }
  $psi.Arguments = $a; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.AutoFlush = $true
  $script:autoErr = $p.StandardError.ReadToEndAsync(); $script:autoOut = $p.StandardOutput.ReadToEndAsync()
  $script:autoP = $p
  for ($i = 0; $i -lt 60; $i++) {   # wait for its first state (or for it to stop with a reason)
    Start-Sleep -Milliseconds 100
    $s = Get-AutoStatus
    if ($s -and $s.running) { return @{ ok = $true; status = $s } }
    if ($p.HasExited) { break }
  }
  $s = Get-AutoStatus
  if ($s -and $s.error) { return @{ ok = $false; error = "$($s.error)"; status = $s } }
  if ($p.HasExited) { $e = "$($script:autoErr.Result)".Trim(); Stop-Auto; return @{ ok = $false; error = $(if ($e) { ($e -split "`r?`n")[0] } else { 'The Auto Show didn''t start.' }) } }
  @{ ok = $true; status = $s }
}

$html = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>ShowXpress Helper</title>
<meta name="viewport" content="width=device-width, initial-scale=1"><link rel="icon" href="/icon.png?t=__TOKEN__">
<style>
:root{--bg:#0e1014;--card:#171a21;--line:#262b36;--txt:#e9ecf1;--dim:#8b93a3;--amber:#ffb020;--green:#3ddc84;--red:#ff5c5c;--blue:#5aa9ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header{display:flex;align-items:center;gap:12px;padding:16px 22px;border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(14,16,20,.95);backdrop-filter:blur(6px);z-index:5}
.logo{width:36px;height:36px;filter:drop-shadow(0 0 10px rgba(255,176,32,.3))}
h1{font-size:18px;margin:0;font-weight:650;letter-spacing:.3px}h1 span{color:var(--dim);font-weight:400;font-size:13px;margin-left:8px}
.pill{margin-left:auto;padding:6px 12px;border-radius:99px;font-size:12.5px;font-weight:600;border:1px solid}
.pill.ok{color:var(--green);border-color:rgba(61,220,132,.35);background:rgba(61,220,132,.08)}.pill.bad{color:var(--amber);border-color:rgba(255,176,32,.4);background:rgba(255,176,32,.1)}
main{max-width:1080px;margin:0 auto;padding:20px 22px 120px;display:grid;gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px}
.card h2{margin:0 0 4px;font-size:15px;font-weight:650}.sub{color:var(--dim);font-size:13px;margin:0 0 14px}
.how{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}.how div{background:#12151b;border:1px solid var(--line);border-radius:10px;padding:10px 12px;font-size:13px;color:#c7cdd8}.how b:first-child{display:block;color:var(--amber);font-size:12px;letter-spacing:.6px;margin-bottom:2px}.how b:not(:first-child){color:var(--txt)}
.row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.grow{flex:1}
.group{margin-top:10px}.group h3{font-size:12px;letter-spacing:1px;color:var(--dim);margin:12px 0 8px;font-weight:600}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(118px,1fr));gap:8px}
.tile{background:#12151b;border:1px solid var(--line);border-radius:10px;padding:8px 10px;font-size:12.5px}
.tile .n{font-weight:650;font-size:13px;margin-bottom:3px}.tile .l{color:var(--dim)}.tile .v{color:var(--txt)}
.tile.moved{border-color:rgba(90,169,255,.45)}.tile.copied{border-style:dashed}.tile .cf{margin-top:3px;font-size:11px;color:var(--blue)}.tile.sized .sz{color:var(--amber)}.tile.warn{border-color:var(--red);background:rgba(255,92,92,.07)}.tile.warn .n::after{content:" !";color:var(--red)}
.summary{font-size:13px;color:var(--dim)}.summary b{color:var(--txt)}
.warnbox{margin-top:12px;padding:10px 12px;border-radius:10px;background:rgba(255,92,92,.08);border:1px solid rgba(255,92,92,.35);color:#ffc9c9;font-size:13px;display:none}
.sizegrid{display:grid;grid-template-columns:1fr 300px;gap:22px;align-items:center}
.slider{margin:10px 0 16px}.slider .top{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px}.slider label{font-weight:600}
input[type=range]{width:100%;accent-color:var(--amber);height:22px}
.num{width:76px;background:#0f1217;color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font-size:15px;text-align:right}
.chips{display:flex;gap:6px;flex-wrap:wrap}.chip{background:#12151b;border:1px solid var(--line);color:var(--txt);border-radius:99px;padding:5px 12px;font-size:12.5px;cursor:pointer}.chip:hover{border-color:var(--amber)}
.link{display:flex;align-items:center;gap:8px;color:var(--dim);font-size:13px;cursor:pointer;user-select:none}
svg{width:100%;height:auto;background:#101318;border:1px solid var(--line);border-radius:12px}
button{font:inherit;border-radius:10px;border:1px solid var(--line);background:#1d212a;color:var(--txt);padding:9px 16px;cursor:pointer;font-weight:600}
button:hover{border-color:#3a4150}button:disabled{opacity:.45;cursor:not-allowed}
.primary{background:linear-gradient(180deg,#ffbe3d,#ff9d00);color:#1a1200;border:none;padding:12px 26px;font-size:15px;box-shadow:0 4px 18px rgba(255,157,0,.25)}
.bar{position:fixed;left:0;right:0;bottom:0;background:rgba(14,16,20,.96);border-top:1px solid var(--line);padding:14px 22px}
.bar .in{max-width:1080px;margin:0 auto;display:flex;align-items:center;gap:12px}
.bar .hint{color:var(--dim);font-size:13px}
.result{display:none}.result.ok{display:block;border-color:rgba(61,220,132,.4)}.result.err{display:block;border-color:rgba(255,92,92,.5)}
.result h2{display:flex;gap:8px;align-items:center}.result ul{margin:8px 0 0;padding-left:18px;color:#c7cdd8;font-size:13px}
details{margin-top:10px}summary{cursor:pointer;color:var(--dim);font-size:12.5px}pre{white-space:pre-wrap;font:12px/1.4 ui-monospace,Consolas,Menlo,monospace;color:#aeb6c4;background:#101318;border:1px solid var(--line);border-radius:8px;padding:10px;max-height:300px;overflow:auto}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:20}
.modal .box{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:22px;max-width:440px}.modal h2{margin:0 0 8px;font-size:16px}.modal p{color:#c7cdd8;margin:0 0 16px}
.busy{position:fixed;inset:0;background:rgba(14,16,20,.7);display:none;align-items:center;justify-content:center;z-index:30;font-weight:600}
.spin{width:22px;height:22px;border:3px solid #3a3f4b;border-top-color:var(--amber);border-radius:50%;animation:s 0.8s linear infinite;margin-right:10px}@keyframes s{to{transform:rotate(360deg)}}
.foot{color:#5d6574;font-size:12px;text-align:center}
.gone{position:fixed;inset:0;background:var(--bg);display:none;align-items:center;justify-content:center;flex-direction:column;z-index:40;color:var(--dim)}
.tabs{display:flex;gap:3px;background:#12151b;border:1px solid var(--line);border-radius:11px;padding:3px;margin-left:14px}
.tabs button{border:none;background:transparent;color:var(--dim);padding:7px 16px;border-radius:8px;font-size:13.5px}
.tabs button:hover{color:var(--txt)}.tabs button.on{background:#262b36;color:var(--txt);box-shadow:inset 0 -2px 0 var(--amber)}
.view{display:none;gap:18px}.view.on{display:grid}.bar .in{display:none}.bar .in.on{display:flex}
.gh{display:flex;align-items:center;gap:8px;margin:14px 0 8px}.gh h3{margin:0;font-size:12px;letter-spacing:1px;color:var(--dim);font-weight:600}.gh .cnt{color:#5d6574;font-size:12px}
.mini{padding:3px 11px;font-size:12px;border-radius:99px;font-weight:600}
.heads{display:grid;grid-template-columns:repeat(8,1fr);gap:8px}
.hd{position:relative;background:#12151b;border:1px solid var(--line);border-radius:12px;padding:12px 0 10px;text-align:center;cursor:pointer;user-select:none;font-weight:700;font-size:17px;color:#6b7383;transition:background .12s,border-color .12s,color .12s}
.hd small{display:block;font-size:11px;font-weight:500;color:#4f5665;margin-top:2px}
.hd:hover{border-color:#3a4150}
.hd.on{background:rgba(255,176,32,.13);border-color:var(--amber);color:var(--txt)}.hd.on small{color:var(--amber)}
.hd.chg::after{content:"";position:absolute;top:7px;right:8px;width:7px;height:7px;border-radius:50%;background:var(--blue)}
.order{display:flex;flex-wrap:wrap;gap:4px;align-items:center;margin-top:6px}.order span{background:#12151b;border:1px solid var(--line);border-radius:6px;padding:2px 7px;font-size:12px}.order i{color:#4f5665;font-style:normal;font-size:11px}
.state{font-size:12.5px;font-weight:600;padding:4px 10px;border-radius:99px;border:1px solid}.state.ok{color:var(--green);border-color:rgba(61,220,132,.35)}.state.chg{color:var(--blue);border-color:rgba(90,169,255,.45)}
header{flex-wrap:wrap}.tabs{flex-wrap:wrap}.tabs button{padding:7px 12px}
.scenes{display:grid;gap:6px;margin-top:10px}
.sc{display:grid;grid-template-columns:minmax(150px,250px) 1fr auto;gap:12px;align-items:center;background:#12151b;border:1px solid var(--line);border-radius:10px;padding:8px 12px}
.sc.chg{border-color:rgba(90,169,255,.45)}.sc .nm{font-weight:650;font-size:13px}.sc .nm small{display:block;color:var(--dim);font-weight:400;font-size:11.5px}
.dots{display:flex;flex-wrap:wrap;gap:3px}.dots i{width:14px;height:14px;border-radius:3px;background:#262b36;display:inline-block}
.dots i.l{background:var(--amber)}.dots i.o{background:var(--blue)}.dots i.x{background:transparent;border:1px dashed var(--red)}
.sc .st{font-size:12px;color:var(--dim);text-align:right;white-space:nowrap}.sc .st b{color:var(--txt)}
.tag{font-size:11px;padding:1px 7px;border-radius:99px;border:1px solid var(--line);color:var(--dim);margin-left:6px;font-weight:600}
.tag.blue{color:var(--blue);border-color:rgba(90,169,255,.45)}.tag.amber{color:var(--amber);border-color:rgba(255,176,32,.4)}.tag.red{color:var(--red);border-color:rgba(255,92,92,.45)}
.apcwrap{display:grid;grid-template-columns:minmax(0,1fr) 270px;gap:18px;margin-top:14px;align-items:start}
.apc{display:grid;grid-template-columns:repeat(8,1fr);gap:6px;background:#0b0d11;border:1px solid var(--line);border-radius:14px;padding:10px}
.pad{position:relative;aspect-ratio:1/1;border-radius:7px;border:1px solid #2a2f3a;background:#151820;cursor:pointer;overflow:hidden;padding:5px 5px 4px;display:flex;flex-direction:column;justify-content:flex-end;user-select:none}
.pad .t{font-size:10px;line-height:1.15;font-weight:650;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.9);display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;word-break:break-word}
.pad .p{font-size:8.5px;color:rgba(255,255,255,.7);text-shadow:0 1px 2px #000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pad .on{position:absolute;left:0;right:0;top:0;height:5px}
.pad.empty{background:transparent;border-style:dashed;border-color:#262b36}.pad.empty .t{color:#3a4150;text-shadow:none;font-weight:500}
.pad.sel{outline:2px solid var(--amber);outline-offset:1px}.pad.tgt:hover{outline:2px dashed var(--amber);outline-offset:1px}
.pad.mv::after{content:"";position:absolute;top:9px;right:5px;width:7px;height:7px;border-radius:50%;background:var(--blue);box-shadow:0 0 0 2px #0b0d11}
.pad.dup{border-color:var(--red);box-shadow:inset 0 0 0 1px var(--red)}.pad.miss .t{color:#ffb3b3}
.pad .badge{position:absolute;top:8px;left:5px;background:var(--red);color:#fff;font-size:9px;font-weight:700;border-radius:99px;padding:0 5px}
.apside{background:#12151b;border:1px solid var(--line);border-radius:12px;padding:14px;font-size:13px}
.apside h3{margin:0 0 6px;font-size:14px}.kv{display:grid;grid-template-columns:72px 1fr;gap:3px 8px;color:var(--dim);font-size:12.5px;margin:8px 0 12px}.kv b{color:var(--txt);font-weight:500}
.sw{display:inline-block;width:12px;height:12px;border-radius:3px;vertical-align:-2px;margin-right:4px;border:1px solid rgba(255,255,255,.2)}
.faders{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:8px;margin-top:14px}
.fd{background:#12151b;border:1px solid var(--line);border-radius:10px;padding:8px 12px;font-size:12.5px}.fd b{display:block;font-size:13px}.fd span{color:var(--dim)}
.iss{display:flex;gap:10px;align-items:flex-start;padding:9px 0;border-top:1px solid var(--line);font-size:13px}.iss:first-child{border-top:none}
.iss .ic{flex:none;width:20px;height:20px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:800}
.iss.error .ic{background:rgba(255,92,92,.16);color:var(--red)}.iss.warn .ic{background:rgba(255,176,32,.14);color:var(--amber)}.iss.info .ic{background:rgba(90,169,255,.14);color:var(--blue)}
.iss .d{color:var(--dim);font-size:12.5px;margin-top:1px}.iss b{font-weight:650}.iss .act{flex:none;display:flex;gap:6px;align-items:center}
.iss .fx{margin-top:5px;font-size:12.5px;color:var(--txt);background:rgba(61,220,132,.06);border-left:2px solid rgba(61,220,132,.55);padding:4px 9px;border-radius:0 6px 6px 0}.iss .fx b{color:var(--green);font-weight:650}
.iss .act button{white-space:nowrap}.iss.done .ic{background:rgba(61,220,132,.14);color:var(--green)}
.applied{background:#12151b;border:1px solid rgba(61,220,132,.35);border-radius:12px;padding:6px 14px;margin:12px 0 4px}.applied h3{margin:6px 0 2px;font-size:13.5px;color:var(--green)}
.legend{display:flex;gap:8px;flex-wrap:wrap}
.lg{background:#12151b;border:1px solid var(--line);border-radius:10px;padding:7px 12px;font-size:12.5px;cursor:pointer;user-select:none}.lg b{font-size:15px;margin-right:6px}.lg.on{border-color:var(--amber);background:rgba(255,176,32,.08)}
.srch{background:#0f1217;color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:7px 10px;font-size:13px;width:230px}
.spg{margin-top:16px}.spg .gh{margin:0 0 6px}.spg .gh select{width:170px}
.sp{display:grid;grid-template-columns:1fr 210px 170px;gap:10px;align-items:center;padding:5px 10px;border-radius:8px;border:1px solid transparent}
.sp:nth-child(odd){background:#12151b}.sp.chg{border-color:rgba(90,169,255,.45);background:rgba(90,169,255,.06)}
.sp .i{color:var(--dim);font-size:12px}.sp .i.no{color:#5d6574}
select{background:#0f1217;color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font:inherit;font-size:13px;width:100%}
.iss.ok .ic{background:rgba(61,220,132,.14);color:var(--green)}
.rtmap{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;background:#0b0d11;border:1px solid var(--line);border-radius:14px;padding:14px;margin-top:14px}
.tw{background:#12151b;border:1px solid var(--line);border-radius:12px;padding:8px 10px 10px}.tw h4{margin:0 0 6px;font-size:11.5px;letter-spacing:.8px;color:var(--dim);font-weight:600;text-transform:uppercase}
.tw .pr{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.slot{background:#0f1217;border:1px dashed #3a4150;border-radius:10px;padding:8px 6px;text-align:center;cursor:pointer;min-height:66px;user-select:none}
.slot:hover{border-color:var(--amber)}.slot.set{border-style:solid;border-color:#3a4150}.slot.chg{box-shadow:inset 0 0 0 1px var(--blue)}
.slot .sd{font-size:10.5px;color:#5d6574;display:block}.slot b{font-size:15px}.slot small{color:var(--dim);font-size:11px}
.dot{display:inline-block;width:18px;height:18px;border-radius:50%;border:2px solid rgba(255,255,255,.25);vertical-align:-4px;margin-right:5px}
.dot.fl{animation:bl .7s linear infinite}@keyframes bl{0%{opacity:1}100%{opacity:.1}}
.mid{grid-row:2;grid-column:1/4;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;color:var(--dim);font-size:12px;text-align:center;border:1px dashed #262b36;border-radius:12px;padding:10px}
.mid .sp2{display:flex;flex-wrap:wrap;gap:4px;justify-content:center}.mid .sp2 span{background:#12151b;border:1px solid var(--line);border-radius:6px;padding:2px 7px;font-size:12px;color:var(--txt)}
.dj{grid-row:4;grid-column:1/4;align-self:end;text-align:center;color:var(--amber);font-size:12px;font-weight:600;letter-spacing:1px;border-top:2px solid rgba(255,176,32,.5);padding-top:6px}
.tw.off{visibility:hidden}
.pick{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin:6px 0 12px}.pick div{background:#12151b;border:1px solid var(--line);border-radius:9px;padding:7px 6px;cursor:pointer;font-size:12px;text-align:center}
.pick div:hover{border-color:var(--amber)}.pick div small{display:block;color:#5d6574;font-size:10.5px}.pick div.cur{border-color:var(--amber);background:rgba(255,176,32,.08)}
.legend2{display:grid;grid-template-columns:repeat(8,1fr);gap:6px;margin-top:12px}.legend2 div{background:#12151b;border:1px solid var(--line);border-radius:8px;padding:5px 4px;text-align:center;font-size:11.5px}.legend2 div b{display:block;font-size:13px}
.pgrp h3{font-size:12px;letter-spacing:1px;color:var(--dim);margin:14px 0 4px;font-weight:600}
.hero{display:flex;align-items:center;gap:18px}.hlogo{width:84px;height:84px;filter:drop-shadow(0 0 22px rgba(255,176,32,.35))}.hname{font-size:26px;font-weight:700}.hver{color:var(--dim);font-size:13px}
.brand img{max-height:96px;max-width:320px;display:block}.brandtxt{font-weight:800;font-size:32px;letter-spacing:7px;color:#fff;text-align:right;line-height:1}.brandtxt span{display:block;font-size:11px;letter-spacing:7.6px;color:var(--amber);font-weight:600;margin-top:5px}
.htiles{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:18px}.ht{text-align:left;background:#12151b;padding:12px 14px;border-radius:12px}.ht b{display:block;font-size:14px;margin-bottom:2px}.ht span{color:var(--dim);font-size:12.5px;font-weight:400}.ht:hover{border-color:var(--amber)}
.seg{display:flex;gap:3px;background:#12151b;border:1px solid var(--line);border-radius:11px;padding:3px;width:max-content}.seg button{border:none;background:transparent;color:var(--dim);padding:8px 24px;border-radius:8px}.seg button:hover{color:var(--txt)}.seg button.on{background:#262b36;color:var(--txt);box-shadow:inset 0 -2px 0 var(--amber)}
.hright{margin-left:auto;display:flex;gap:8px;align-items:center}.hright .pill{margin-left:0}
.psw{display:inline-block;width:17px;height:17px;border-radius:4px;margin:0 3px 3px 0;cursor:pointer;border:1px solid rgba(255,255,255,.15)}.psw.cur{outline:2px solid var(--amber);outline-offset:1px}.pcl{font-size:12px;color:var(--dim);margin:2px 0 10px}.pcl .pals{margin:3px 0 7px;line-height:0}
.clwrap{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:22px;margin-top:6px;align-items:start}
.clpal{display:grid;grid-template-columns:repeat(auto-fill,minmax(104px,1fr));gap:6px}
.cp{display:flex;align-items:center;gap:7px;background:#12151b;border:1px solid var(--line);border-radius:9px;padding:6px 8px;font-size:12.5px;cursor:pointer;user-select:none}.cp:hover{border-color:#3a4150}.cp.cur{border-color:var(--amber);background:rgba(255,176,32,.08)}
.cp i{flex:none;width:18px;height:18px;border-radius:50%;border:1px solid rgba(255,255,255,.25)}
.wheel{position:relative;flex:none;width:200px;height:200px;border-radius:50%;background:radial-gradient(circle closest-side,#fff,rgba(255,255,255,0)),conic-gradient(red,yellow,lime,cyan,blue,magenta,red);cursor:crosshair;touch-action:none}
.wheel i{position:absolute;width:20px;height:20px;border-radius:50%;border:3px solid #fff;box-shadow:0 0 0 1px #000,0 2px 6px rgba(0,0,0,.6);transform:translate(-50%,-50%);pointer-events:none;display:none}
.clbig{height:120px;border-radius:12px;border:1px solid var(--line);display:flex;align-items:flex-end;padding:10px 12px;margin-bottom:10px}.clbig span{background:rgba(0,0,0,.55);padding:2px 8px;border-radius:6px;font:12px ui-monospace,Consolas,monospace}
input[type=color]{width:46px;height:34px;border:1px solid var(--line);border-radius:8px;background:#0f1217;padding:2px;cursor:pointer}
.qbar{display:none;margin:14px 22px 0;padding:12px 16px;border-radius:12px;background:rgba(255,176,32,.08);border:1px solid rgba(255,176,32,.45);font-size:13px}
.qbar.on{display:block}.qbar.done{background:rgba(61,220,132,.07);border-color:rgba(61,220,132,.4)}.qbar.bad{background:rgba(255,92,92,.07);border-color:rgba(255,92,92,.45)}
.qbar h3{margin:0 0 6px;font-size:14px}.qbar .qi{display:inline-flex;align-items:center;gap:6px;background:#12151b;border:1px solid var(--line);border-radius:99px;padding:3px 6px 3px 11px;margin:0 6px 6px 0}
.qbar .qi button{border:none;background:transparent;color:var(--dim);padding:0 4px;font-size:13px;cursor:pointer}.qbar .qi button:hover{color:var(--red)}
.qbar ul{margin:4px 0 6px;padding-left:18px}.qbar li.no{color:#ffb3b3}
.lvcall{display:flex;align-items:center;gap:14px;margin:0 0 14px;padding:12px 14px;border-radius:12px;background:rgba(90,169,255,.07);border:1px solid rgba(90,169,255,.4);font-size:13px;color:#c7cdd8}.lvcall b{color:var(--txt)}
.live{position:fixed;inset:0;background:var(--bg);z-index:15;display:none;flex-direction:column}.live.on{display:flex}
.lvtop{display:flex;align-items:center;gap:12px;padding:12px 18px;border-bottom:1px solid var(--line)}.lvt{color:var(--amber);letter-spacing:1px;font-size:15px}
.lvgone{display:none;margin:10px 18px 0;padding:10px 14px;border-radius:10px;background:rgba(255,92,92,.08);border:1px solid rgba(255,92,92,.45);color:#ffc9c9;font-size:13px}.lvgone.on{display:flex;align-items:center;gap:12px}
.lvbody{flex:1;display:grid;grid-template-columns:220px minmax(0,1fr) 280px;min-height:0}
.lvlist{overflow:auto;border-right:1px solid var(--line);padding:4px 10px 20px}
.lvlist h4{margin:12px 0 5px;font-size:11px;letter-spacing:.8px;color:var(--dim);font-weight:600;text-transform:uppercase}
.lvh{display:flex;align-items:center;gap:6px;padding:6px 9px;border-radius:8px;cursor:pointer;border:1px solid transparent;font-size:13px;font-weight:600;user-select:none}
.lvh:hover{background:#171a21}.lvh.on{border-color:var(--amber);background:rgba(255,176,32,.1)}.lvh.dim{color:#5d6574}
.lvh small{margin-left:auto;font-weight:500;font-size:11px;color:#5d6574;white-space:nowrap}.lvh small.a{color:var(--blue)}.lvh small.cp{color:#9aa3b5}.lvh small.b{color:var(--dim)}
.lvh .sd{font-size:10px;color:#5d6574;width:10px}
.lvmain{display:flex;flex-direction:column;gap:12px;padding:14px 18px;min-height:0}
.seg button small{font-size:10.5px;color:#5d6574;font-weight:500}
.lvpad{flex:1;min-height:220px;border:2px dashed #3a4150;border-radius:16px;background:radial-gradient(circle at 50% 50%,rgba(255,176,32,.07),transparent 60%),#0b0d11;display:flex;align-items:center;justify-content:center;text-align:center;cursor:grab;user-select:none;color:var(--dim);padding:20px}
.lvpad:hover{border-color:#566070}.lvpad.drag{cursor:none;border-color:var(--amber);border-style:solid}
.lvbig{font-size:30px;font-weight:700;color:var(--txt);margin-bottom:6px}.lvbig span{color:var(--amber)}
.lvkeys{color:var(--dim);font-size:12.5px}.lvkeys b{color:var(--txt);font-weight:600}
.lvside{border-left:1px solid var(--line);padding:14px 16px;overflow:auto}.lvside h3{margin:0;font-size:17px}.lvside .sub{margin:2px 0 6px}
.lvside .kv{grid-template-columns:40px 1fr;margin:6px 0 8px}.lvside .kv small{color:var(--dim)}
.lvflip{display:grid;gap:4px;margin:10px 0}
.lvbtns{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:6px}.lvbtns button{padding:8px 10px;font-size:13px}.lvbtns .w2{grid-column:span 2}
.remrow{display:none;align-items:center;gap:8px;flex-wrap:wrap;margin:0 0 14px;padding:10px 14px;border-radius:12px;background:rgba(61,220,132,.05);border:1px solid rgba(61,220,132,.3);font-size:13px;color:#c7cdd8}.remrow.on{display:flex}.remrow b{color:var(--txt)}
.mini.son{border-color:var(--green);color:var(--green);background:rgba(61,220,132,.1)}
.aulook{background:#12151b;border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-top:8px}.aulook.off{opacity:.55}.aulook.cur{border-color:var(--green);box-shadow:0 0 0 1px rgba(61,220,132,.4)}
.aun{flex:none;width:24px;height:24px;border-radius:50%;background:#262b36;display:inline-flex;align-items:center;justify-content:center;font-size:12px;font-weight:700}.aulook.cur .aun{background:var(--green);color:#06210f}
.auchips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;align-items:center}.auchips .none{color:#5d6574;font-size:12.5px}
.auchip{display:inline-flex;align-items:center;gap:2px;background:#0f1217;border:1px solid #3a4150;border-radius:99px;padding:3px 4px 3px 11px;font-size:12.5px}.auchip.bad{border-color:var(--red);color:#ffb3b3}
.auchip button{border:none;background:transparent;color:var(--dim);padding:0 5px;font-size:12px}.auchip button:hover{color:var(--red)}
.auplay{background:#0b0d11;border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin-top:14px}.auplay.on{border-color:rgba(61,220,132,.5)}
.aubig{font-size:28px;font-weight:700;line-height:1.15}.aubig small{font-size:14px;color:var(--amber);font-weight:600;margin-left:6px}
.auprog{height:8px;border-radius:99px;background:#1d212a;margin:12px 0;overflow:hidden}.auprog i{display:block;height:100%;background:linear-gradient(90deg,#3ddc84,#ffb020);width:0;transition:width .25s linear}
.aubeats{display:flex;gap:8px}.aubeats i{width:18px;height:18px;border-radius:50%;background:#262b36}.aubeats i.on{background:var(--amber);box-shadow:0 0 12px rgba(255,176,32,.6)}.aubeats i.on.one{background:var(--green);box-shadow:0 0 12px rgba(61,220,132,.6)}
.pkl{max-height:52vh;overflow:auto;margin:8px 0 12px}.pkl h4{margin:10px 0 5px;font-size:11px;letter-spacing:.8px;color:var(--dim);font-weight:600;text-transform:uppercase}
.pks{display:flex;flex-wrap:wrap;gap:5px}.pkb{background:#12151b;border:1px solid var(--line);border-radius:8px;padding:5px 9px;font-size:12.5px;cursor:pointer;user-select:none}.pkb:hover{border-color:var(--amber)}.pkb.on{border-color:var(--amber);background:rgba(255,176,32,.12)}.pkb.no{opacity:.4;cursor:not-allowed}
#aupill{background:rgba(61,220,132,.1);border-color:rgba(61,220,132,.45);color:var(--green)}
@media (max-width:860px){.clwrap{grid-template-columns:1fr}.htiles{grid-template-columns:1fr 1fr}}
@media (max-width:860px){.apcwrap{grid-template-columns:1fr}.sc{grid-template-columns:1fr}.sc .st{text-align:left}.sp{grid-template-columns:1fr 1fr}}
@media (max-width:760px){.how{grid-template-columns:1fr}.sizegrid{grid-template-columns:1fr}.heads{grid-template-columns:repeat(4,1fr)}}
</style></head><body>
<header><img class="logo" id="logo" src="/icon.png?t=__TOKEN__" alt="" style="cursor:pointer" title="Home"><h1 id="ttl" style="cursor:pointer" title="Home">ShowXpress Helper</h1>
  <nav class="tabs"><button data-tab="rt">Rig Test</button><button data-tab="rig">Tonight's Rig</button><button data-tab="aim">Aim Movers</button><button data-tab="skip">Skip Flash</button><button data-tab="color">Tonight's Color</button><button data-tab="apc">APC mini</button><button data-tab="speed">Speed Faders</button><button data-tab="health">Health Check</button><button data-tab="pre">Pre-show Check</button><button data-tab="auto">Auto Show</button></nav>
  <div class="hright"><button id="aupill" class="mini" style="display:none" title="Auto Show is playing"></button><div id="sx" class="pill ok">Checking ShowXpress&hellip;</div><button id="sxgo" class="mini" style="display:none">&#9654; Launch ShowXpress</button><button id="sxstop" class="mini" style="display:none">&#9632; Close ShowXpress</button><button id="upd" class="mini primary" style="display:none"></button></div></header>
<div id="qbar" class="qbar"></div>
<main>
 <div class="view" id="v-home">
  <section class="card">
   <div class="hero"><img class="hlogo" src="/icon.png?t=__TOKEN__" alt=""><div><div class="hname">ShowXpress Helper</div><div class="hver" id="hver">&nbsp;</div></div><div class="grow"></div>
    <div id="brand" class="brand"><div class="brandtxt">XSV<span>PRODUCTIONS</span></div></div></div>
   <div class="htiles">
    <button class="ht" data-go="rt"><b>1 &middot; Rig Test</b><span>Which mover hangs where &rarr; 2D view, Tonight&rsquo;s Rig and Skip Flash</span></button>
    <button class="ht" data-go="aim"><b>2 &middot; Aim Movers</b><span>Fit the dance floor and AROUND ROOM to tonight&rsquo;s venue</span></button>
    <button class="ht" data-go="color"><b>3 &middot; Tonight&rsquo;s Color</b><span>The decor colour on the movers and uplights</span></button>
    <button class="ht" data-go="pre"><b>4 &middot; Pre-show Check</b><span>One look before the guests arrive</span></button>
    <button class="ht" data-go="rig"><b>Tonight&rsquo;s Rig</b><span>Which heads are hung tonight</span></button>
    <button class="ht" data-go="skip"><b>Skip Flash</b><span>The heads SKIP FLASH uses</span></button>
    <button class="ht" data-go="apc"><b>APC mini</b><span>Move pads and pick their colours</span></button>
    <button class="ht" data-go="speed"><b>Speed Faders</b><span>Which fader drives which button</span></button>
    <button class="ht" data-go="health"><b>Health Check</b><span>Find and fix problems in the show</span></button>
    <button class="ht" data-go="auto"><b>Auto Show</b><span>The Helper changes your looks every few bars while you mix</span></button>
   </div>
  </section>
  <section class="card"><div class="row"><div class="grow"><h2>Google Drive backup</h2><p class="sub" id="gdsub" style="margin:0">Looking for Google Drive&hellip;</p><div id="gdhint" class="summary"></div></div><button id="gdsync" class="primary" disabled>Sync to Google Drive</button></div></section>
 </div>

 <div class="view" id="v-aim">
  <div class="seg"><button data-am="floor" class="on">Dance Floor</button><button data-am="room">Room</button></div>
  <section class="card">
    <h2 id="aimttl">Dance floor &mdash; tonight's aims</h2>
    <p class="sub">Read from the scene <b id="aimsc">DF AIM (ADJUST)</b> in ShowXpress.</p>
    <div class="how" id="aimhow">
      <div><b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight's dancefloor &mdash; or just <b>one head per T-bar</b>: the head next to it gets the same aim (unless you aim that one too).</div>
      <div><b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size. A copied head gets this too.</div>
      <div><b>THEN</b>Save, close ShowXpress, press Refresh below, check the heads and Apply &mdash; <b>DF CHECK</b> comes on by itself when ShowXpress opens again.</div>
    </div>
    <div id="aimrem" class="remrow"></div>
    <div class="lvcall" id="lvcall"><div class="grow"><b>&#9678; Aim live</b> &mdash; aim from here instead of ShowXpress: slow, fine mouse control, and the real head follows as you drag. ShowXpress closes while you aim and opens again when you finish.</div><button id="lvgo" class="primary" style="padding:9px 20px;font-size:14px;white-space:nowrap">&#9678; Aim live</button></div>
    <div class="row"><div id="summary" class="summary grow">Loading&hellip;</div><button id="refresh">&#8635; Refresh</button></div>
    <div id="heads"></div>
    <div id="warnbox" class="warnbox"></div>
    <div id="aiminst" class="warnbox"></div>
  </section>

  <section class="card">
    <h2>Overall pattern size</h2>
    <p class="sub" id="sizesub">100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.</p>
    <div class="sizegrid">
      <div>
        <div class="slider"><div class="top"><label>Width</label><input id="wn" class="num" type="number" min="20" max="300"></div><input id="w" type="range" min="20" max="300" step="1"></div>
        <div class="slider"><div class="top"><label id="dlab">Depth</label><input id="dn" class="num" type="number" min="20" max="300"></div><input id="d" type="range" min="20" max="300" step="1"></div>
        <div class="row"><label class="link"><input id="lnk" type="checkbox" checked> Same both ways</label><div class="grow"></div>
          <div class="chips"><span class="chip" data-v="80">80</span><span class="chip" data-v="90">90</span><span class="chip" data-v="100">100</span><span class="chip" data-v="110">110</span><span class="chip" data-v="120">120</span></div></div>
      </div>
      <svg viewBox="0 0 300 210" aria-label="size preview">
        <text x="150" y="16" fill="#5d6574" font-size="10" text-anchor="middle">DJ / front</text>
        <rect id="floor" x="60" y="45" width="180" height="120" fill="none" stroke="#5d6574" stroke-dasharray="5 4" rx="4"/>
        <rect id="pat" x="60" y="45" width="180" height="120" fill="rgba(255,176,32,.16)" stroke="#ffb020" stroke-width="2" rx="6"/>
        <circle cx="150" cy="105" r="4" fill="#ffb020"/>
        <text id="svgl" x="150" y="200" fill="#5d6574" font-size="10" text-anchor="middle">dashed = dancefloor &middot; amber = patterns</text>
      </svg>
    </div>
  </section>
 </div>

 <div class="view" id="v-rt">
  <section class="card">
    <div class="row"><div class="grow"><h2>Rig test &mdash; which mover is where</h2>
      <p class="sub" style="margin-bottom:0"><b>1.</b> <b>RIG ID</b> comes on in ShowXpress by itself (green bar below &mdash; or press it on the SETUP page): every 140 lights in its own look (key below). <b>2.</b> Tap each truss spot and pick the look you see on that head. <b>3.</b> Close ShowXpress (save first) and press <b>Save to 2D view</b>.</p></div>
      <span id="rtstate" class="state ok" style="display:none"></span><button id="rtrefresh">&#8635; Refresh</button></div>
    <div id="rtrem" class="remrow" style="margin:12px 0 0"></div>
    <div id="rterr" class="warnbox"></div>
    <div id="rtinst" class="warnbox"></div>
    <div id="rtlegend" class="legend2"></div>
    <div id="rtmap" class="rtmap"></div>
    <div class="row" style="margin-top:12px"><label class="link"><input id="rtextra" type="checkbox"> Bigger event: 2 extra towers (top middle and bottom middle)</label><div class="grow"></div>
      <label class="link"><input id="rtrig" type="checkbox" checked> Also update Tonight's Rig and Skip Flash (heads not on a truss = not hung)</label></div>
  </section>
 </div>

 <div class="view" id="v-pre">
  <section class="card">
    <h2>Pre-show check</h2>
    <p class="sub">One look before the guests arrive: the show, your gear and the laptop. Checking changes nothing.</p>
    <div id="presum" class="summary"></div>
    <div id="prelist"></div>
  </section>
 </div>

 <div class="view" id="v-color">
  <section class="card">
    <div class="row"><div class="grow"><h2>Tonight's color</h2>
      <p class="sub" style="margin-bottom:0">The decor colour for tonight. Saving makes two ShowXpress buttons called <b>TONIGHTS COLOR</b>: on the MOVER COLORS page (every mover on the nearest colour of its wheel, colour only &mdash; it goes on top of any movement) and on the UPLIGHTS page (the uplights in exactly this colour).</p></div>
      <span id="clstate" class="state ok" style="display:none"></span><button id="clrefresh">&#8635; Refresh</button></div>
    <div id="clerr" class="warnbox"></div>
    <div class="clwrap">
      <div>
        <div class="gh"><h3>QUICK PICKS</h3></div><div id="clpal" class="clpal"></div>
        <div class="gh" style="margin-top:18px"><h3>ANY COLOUR</h3></div>
        <div class="row" style="align-items:flex-start;gap:22px"><div id="clwheel" class="wheel"><i id="clknob"></i></div>
          <div><div class="row"><input id="clpick" type="color" title="Colour picker"><input id="clhex" class="srch" style="width:110px" maxlength="7" placeholder="#RRGGBB"></div>
            <div class="slider" style="width:230px"><div class="top"><label>Brightness</label></div><input id="clval" type="range" min="10" max="100" step="1"></div>
            <p class="sub" style="margin:0;max-width:240px">Tap or drag on the wheel. The uplights get exactly this colour; the movers only have their wheel colours.</p></div></div>
      </div>
      <div><div id="clbig" class="clbig"></div>
        <input id="clname" class="srch" style="width:100%" maxlength="30" placeholder="Name (optional), e.g. Blush">
        <div id="clmap" class="kv" style="grid-template-columns:86px 1fr"></div></div>
    </div>
  </section>
 </div>

 <div class="view" id="v-skip">
  <section class="card">
    <div class="row"><div class="grow"><h2>Skip Flash heads</h2>
      <p class="sub" style="margin-bottom:0">Tap the movers that are set up tonight. <b>SKIP FLASH</b> will only flash those, so the chase has no dark gaps.</p></div>
      <span id="skstate" class="state ok" style="display:none"></span><button id="skrefresh">&#8635; Refresh</button></div>
    <div id="skerr" class="warnbox"></div>
    <div id="skgroups"></div>
  </section>
  <section class="card">
    <div class="row"><h2 class="grow" style="margin:0">Flash order</h2><div id="sksum" class="summary"></div></div>
    <div id="skorder" class="order"></div>
    <p class="sub" style="margin:10px 0 0">The order and the step time come from your scene &mdash; only the list of heads changes.</p>
  </section>
 </div>

 <div class="view" id="v-rig">
  <section class="card">
    <div class="row"><div class="grow"><h2>Tonight's rig</h2>
      <p class="sub" style="margin-bottom:0">Tap the movers that are hung tonight. Every chase scene (CHASE, SKIP AROUND, the BEAT scenes, SKIP FLASH&hellip;) drops the steps that would be dark without them, so nothing stutters. Tick them all again to put every scene back.</p></div>
      <span id="rgstate" class="state ok" style="display:none"></span><button id="rgrefresh">&#8635; Refresh</button></div>
    <div id="rgerr" class="warnbox"></div>
    <div id="rggroups"></div>
  </section>
  <section class="card">
    <div class="row"><h2 class="grow" style="margin:0">Chase scenes</h2><div id="rgsum" class="summary"></div></div>
    <div id="rgscenes" class="scenes"></div>
    <p class="sub" style="margin:10px 0 0"><i class="sw" style="background:var(--amber)"></i>movers lit &nbsp; <i class="sw" style="background:var(--blue)"></i>blinder / uplight only &nbsp; <i class="sw" style="background:#262b36"></i>dark &nbsp; <i class="sw" style="border:1px dashed var(--red)"></i>taken out tonight.
      Only whole steps are taken out &mdash; colours and timing stay as they are. A step that also lights a blinder or uplight is always kept.</p>
  </section>
 </div>

 <div class="view" id="v-apc">
  <section class="card">
    <div class="row"><div class="grow"><h2>APC mini pads</h2>
      <p class="sub" style="margin-bottom:0">The 8&times;8 grid as it sits on the controller (top row first), in each pad's own colours. Tap a pad, then tap where it should go &mdash; or pick its colours.</p></div>
      <span id="apstate" class="state ok" style="display:none"></span><button id="aprefresh">&#8635; Refresh</button></div>
    <div id="aperr" class="warnbox"></div>
    <div class="apcwrap"><div id="apgrid" class="apc"></div><div id="apside" class="apside"></div></div>
    <div id="apfaders" class="faders"></div>
  </section>
  <section class="card"><h2>Pad problems</h2><div id="apissues"></div></section>
 </div>

 <div class="view" id="v-speed">
  <section class="card">
    <div class="row"><div class="grow"><h2>Speed faders</h2>
      <p class="sub" style="margin-bottom:0">Which master speed fader each button follows. Faders only change step timing, so 1-step scenes don't react.</p></div>
      <span id="spstate" class="state ok" style="display:none"></span><button id="sprefresh">&#8635; Refresh</button></div>
    <div id="sperr" class="warnbox"></div>
    <div class="row" style="margin-top:14px"><div id="splegend" class="legend grow"></div><input id="spq" class="srch" type="search" placeholder="Find a button&hellip;"></div>
    <div id="splist"></div>
  </section>
 </div>

 <div class="view" id="v-auto">
  <section class="card">
   <div class="row"><div class="grow"><h2>Auto Show</h2><p class="sub" style="margin:0">The Helper presses your <b>looks</b> in ShowXpress one after another, each for a number of bars &mdash; for the stretches when you&rsquo;re busy mixing. A look is a few buttons that play together (a movement, a colour, uplights&hellip;). Whatever you press yourself on the APC still works on top. Tap the BPM to the music and press <b>Bar 1 now</b> on a downbeat to line the changes up.</p></div><span id="austate" class="state ok" style="display:none"></span></div>
   <div id="auerr" class="warnbox"></div><div id="aurem" class="warnbox"></div>
   <div id="auplay" class="auplay"></div>
  </section>
  <section class="card">
   <div class="row"><div class="grow"><h2>Looks</h2><p class="sub" style="margin:0" id="ausum"></p></div><button id="aunew">+ New look</button><button id="augrab">&#8681; New look from what&rsquo;s playing</button></div>
   <div id="aulooks"></div>
   <div class="row" style="margin-top:16px;gap:14px">
    <span class="sub" style="margin:0">Order</span><div class="seg"><button data-ao="order">In order</button><button data-ao="shuffle">Shuffle</button></div>
    <span class="sub" style="margin:0">When I stop</span><select id="austop" style="width:auto"><option value="keep">Leave the last look playing</option><option value="off">Turn the look off</option></select>
    <label class="link"><input type="checkbox" id="auclean"> At start, turn off everything else that&rsquo;s playing</label></div>
   <div id="aumsg" class="sub" style="margin:10px 0 0"></div>
  </section>
 </div>

 <div class="view" id="v-health">
  <section class="card">
    <h2>Show health check</h2>
    <p class="sub">Looks through the whole show for things that have caused trouble before: missing scenes, broken beat settings, APC pads that fire two buttons, colour chases that spin the wheel&hellip; Checking changes nothing. Each problem shows a recommended fix; where the helper can do it for you there's a button, and every fix can be reverted.</p>
    <div id="hlapplied"></div>
    <div id="hlsum" class="summary"></div>
    <div id="hllist" style="margin-top:10px"></div>
  </section>
 </div>

  <section id="result" class="card result"><h2 id="rtitle"></h2><div id="rbody"></div><details><summary>Full details</summary><pre id="rlog"></pre></details></section>
  <div class="foot" id="foot"></div>
</main>
<div class="bar"><div class="in" data-for="home"><div class="hint grow">Pick a tab above to start. Nothing in the show changes until you save in a tab.</div></div>
  <div class="in" data-for="color"><button id="clsave" class="primary">Save tonight's color</button><button id="clundo">Undo changes</button><div class="hint grow" id="clhint"></div></div>
  <div class="in" data-for="rt"><button id="rtsave" class="primary">Save to 2D view</button><button id="rtclear">New event (clear spots)</button><button id="rtundo">Undo changes</button><div class="hint grow" id="rthint"></div></div>
  <div class="in" data-for="pre"><button id="prerun" class="primary">Check again</button><button id="pregd">Sync to Google Drive</button><div class="hint grow" id="prehint"></div></div>
  <div class="in" data-for="aim"><button id="apply" class="primary">Apply to show</button><button id="home">Reset to normal</button><div class="hint grow" id="hint"></div></div>
  <div class="in" data-for="skip"><button id="sksave" class="primary">Save to SKIP FLASH</button><button id="skundo">Undo changes</button><div class="hint grow" id="skhint"></div></div>
  <div class="in" data-for="rig"><button id="rgsave" class="primary">Save tonight's rig</button><button id="rgall">All heads (put back)</button><button id="rgundo">Undo changes</button><div class="hint grow" id="rghint"></div></div>
  <div class="in" data-for="apc"><button id="apsave" class="primary">Save pads</button><button id="apundo">Undo changes</button><div class="hint grow" id="aphint"></div></div>
  <div class="in" data-for="speed"><button id="spsave" class="primary">Save speed faders</button><button id="spundo">Undo changes</button><div class="hint grow" id="sphint"></div></div>
  <div class="in" data-for="auto"><button id="ausave" class="primary">Save Auto Show</button><button id="auundo">Undo changes</button><div class="hint grow" id="auhint"></div></div>
  <div class="in" data-for="health"><button id="hlrun" class="primary">Check again</button><div class="hint grow" id="hlhint"></div></div></div>
<div class="live" id="live">
 <div class="lvtop"><b class="lvt">&#9678; LIVE AIM</b><span id="lvmode" class="sub" style="margin:0"></span><span id="lvif" class="tag amber"></span><div class="grow"></div>
  <label class="link"><input type="checkbox" id="lvreo"> Open ShowXpress again after</label><button id="lvcancel">Cancel</button><button id="lvsave" class="primary" style="padding:9px 20px;font-size:14px">Save &amp; finish</button></div>
 <div id="lvgone" class="lvgone"></div>
 <div class="lvbody">
  <div class="lvlist" id="lvlist"></div>
  <div class="lvmain">
   <div class="row"><div class="seg"><button data-st="c" class="on">1 &middot; CENTER</button><button data-st="k">2 &middot; CORNER <small>optional</small></button></div><div class="grow"></div><span class="sub" style="margin:0">Speed</span><div class="seg"><button data-sp="0.4">Fine</button><button data-sp="1">Normal</button><button data-sp="3">Fast</button></div></div>
   <div class="lvpad" id="lvpad"><div><div class="lvbig" id="lvbig"></div><div id="lvtip"></div></div></div>
   <div class="lvkeys">Hold the mouse button down in the box and drag &middot; <b>Shift</b> = finer &middot; <b>Ctrl</b> = faster &middot; <b>arrow keys</b> nudge &middot; <b>N</b> / <b>P</b> or <b>Tab</b> = next / previous head &middot; <b>1</b> / <b>2</b> = step</div>
  </div>
  <div class="lvside">
   <h3 id="lvname"></h3><div id="lvst" class="sub"></div>
   <div class="kv" id="lvread"></div>
   <svg id="lvmap" viewBox="0 0 240 180"></svg>
   <div class="sub" style="font-size:11.5px">dashed = normal floor &middot; amber = tonight &middot; ring = where it points now</div>
   <div class="lvflip"><label class="link"><input type="checkbox" id="lvfx"> Flip left / right for this head</label><label class="link"><input type="checkbox" id="lvfy"> Flip up / down for this head</label></div>
   <div class="lvbtns"><button id="lvprev">&larr; Previous</button><button id="lvnext" class="primary" style="padding:8px 10px;font-size:13px">Next head &rarr;</button>
    <button id="lvpart" class="w2"></button><button id="lvundo">Undo this head</button><button id="lvhome">Back to normal</button></div>
   <label class="link" style="margin-top:12px"><input type="checkbox" id="lvall"> Light all hung heads (not just this one)</label>
  </div>
 </div>
</div>
<div class="modal" id="rtpick"><div class="box" style="max-width:540px"><h2 id="rtpt"></h2><p class="sub" style="margin:0 0 4px">Pick the look you see on this head.</p><div id="rtpb"></div><div class="row" style="justify-content:flex-end"><button id="rtpnone">Nothing hung here</button><button id="rtpcancel">Cancel</button></div></div></div>
<div class="modal" id="aupk"><div class="box" style="max-width:660px;width:92vw"><h2 id="aupkt"></h2><input id="aupks" class="srch" placeholder="Search buttons&hellip;" style="width:100%"><div id="aupkl" class="pkl"></div><div class="row" style="justify-content:flex-end"><button id="aupkd" class="primary" style="padding:9px 18px;font-size:14px">Done</button></div></div></div>
<div class="modal" id="modal"><div class="box"><h2 id="mt"></h2><p id="mp"></p><div class="row" style="justify-content:flex-end"><button id="mno">Cancel</button><button id="myes" class="primary" style="padding:9px 18px;font-size:14px"></button></div></div></div>
<div class="busy" id="busy"><div class="spin"></div><span id="busyt">Working&hellip;</span></div>
<div class="gone" id="gone"><h2 style="color:var(--txt)">ShowXpress Helper has closed</h2><p>Open it again from its icon.</p></div>
<script>
const T='__TOKEN__';const $=id=>document.getElementById(id);
let P=null,sxOpen=false,linked=true;
function wq(b){return sxOpen?Object.assign({},b||{},{queue:true}):b;}
async function api(p,body){const r=await fetch(p+(p.includes('?')?'&':'?')+'t='+T,body?{method:'POST',headers:{'Content-Type':'text/plain'},body:JSON.stringify(body)}:{});return r.json();}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function sign(v){return (v>0?'+':'')+v;}
function tile(h){const moved=h.op||h.ot,cls=['tile',moved?'moved':'',h.sized?'sized':'',h.warn?'warn':'',h.copyFrom?'copied':''].join(' ');
 return `<div class="${cls}" title="${esc(h.warn||(h.copyFrom?'Not aimed by you - gets the same aim as '+h.copyFrom+' on its T-bar. Aim it yourself and it keeps its own.':''))}"><div class="n">${esc(h.label)}</div>
 <div><span class="l">center </span><span class="v">${moved?sign(h.op)+' / '+sign(h.ot):'normal'}</span></div>
 <div><span class="l">size </span><span class="v sz">${h.sized?h.kp+'% &times; '+h.kt+'%':'normal'}</span></div>`+
 (h.copyFrom?`<div class="cf">&#8644; same as ${esc(h.copyFrom)}</div>`:'')+`</div>`;}
function render(){if(!P)return;
 if(!P.ok){$('summary').innerHTML='<span style="color:var(--red)">'+esc(P.error)+'</span>';$('heads').innerHTML='';$('warnbox').style.display='none';updBar();return;}
 const hs=P.heads,a=hs.filter(h=>h.is140),b=hs.filter(h=>!h.is140),moved=hs.filter(h=>h.op||h.ot).length,sized=hs.filter(h=>h.sized).length,w=hs.filter(h=>h.warn),cp=hs.filter(h=>h.copyFrom).length;
 $('summary').innerHTML=`<b>${a.length}</b> &times; 140SR${b.length?` &middot; <b>${b.length}</b> &times; 251SR`:''} &nbsp;&mdash;&nbsp; <b>${moved}</b> re-aimed${cp?` (<b>${cp}</b> copied from the head next to it on the T-bar)`:''} &middot; <b>${sized}</b> with a corner set`+(w.length?` &middot; <b style="color:var(--red)">${w.length} look wrong</b>`:'');
 $('heads').innerHTML=`<div class="group"><h3>140SR</h3><div class="tiles">${a.map(tile).join('')}</div></div>`+(b.length?`<div class="group"><h3>251SR</h3><div class="tiles">${b.map(tile).join('')}</div></div>`:'');
 const ins=P.install,ib=$('aiminst');
 if(aimMode==='room'&&ins&&(!ins.aim||!ins.check)){ib.style.display='block';ib.innerHTML='<b>ROOM AIM (ADJUST)</b> and <b>ROOM CHECK</b> aren&rsquo;t on the SETUP page yet. <button id="aiminstb" class="mini primary" style="margin-left:8px"'+'>Add them to the SETUP page</button>';
  $('aiminstb').onclick=()=>saveTo('/api/aim/install',{},'Adding the ROOM buttons…',async()=>{LD.room=0;await load();},'roominstall');}else ib.style.display='none';
 const wb=$('warnbox');if(w.length){wb.style.display='block';wb.innerHTML='<b>Check these heads:</b> '+w.map(h=>esc(h.label)+' &ndash; '+esc(h.warn)).join('<br>');}else wb.style.display='none';
 $('foot').textContent='Show: '+P.show;updBar();}
function updBar(){const bad=!P||!P.ok;$('apply').disabled=bad;$('home').disabled=bad;
 $('hint').innerHTML=sxOpen&&!bad?QH:(bad?'':(aimMode==='room'?'Writes to '+esc((P.targets||[]).filter(t=>!/CHECK/.test(t)).join(', ')||'AROUND ROOM'):'Writes to all dancefloor movement scenes')+' + CENTER SPOT (step 1 aims). Nothing is changed until you press Apply.');}
let aimMode='floor';const PM={floor:null,room:null},LD={};
const aimT=()=>(P&&P.aimTitle)||(aimMode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)');
async function load(){const m=aimMode;$('summary').textContent='Loading…';let p;try{p=await api('/api/preview'+(m==='room'?'?mode=room':''));}catch(e){p={ok:false,error:'Could not read the show.'}}
 PM[m]=p;if(aimMode!==m)return;P=p;
 if(P.ok&&!LD[m]){setW(P.lastW);setD(P.lastD);$('lnk').checked=linked=(P.lastW===P.lastD);LD[m]=1;}render();}
function clamp(v){v=Math.round(+v||100);return Math.max(20,Math.min(300,v));}
function setW(v){v=clamp(v);$('w').value=$('wn').value=v;if(linked){$('d').value=$('dn').value=v;}draw();}
function setD(v){v=clamp(v);$('d').value=$('dn').value=v;if(linked){$('w').value=$('wn').value=v;}draw();}
function draw(){const w=+$('w').value/100,d=+$('d').value/100,W=180*w,H=120*d;const r=$('pat');r.setAttribute('x',150-W/2);r.setAttribute('y',105-H/2);r.setAttribute('width',W);r.setAttribute('height',H);}
$('w').oninput=e=>setW(e.target.value);$('d').oninput=e=>setD(e.target.value);$('wn').onchange=e=>setW(e.target.value);$('dn').onchange=e=>setD(e.target.value);
$('lnk').onchange=e=>{linked=e.target.checked;if(linked)setW($('w').value);};
document.querySelectorAll('.chip').forEach(c=>c.onclick=()=>{if(linked)setW(c.dataset.v);else{setW(c.dataset.v);setD(c.dataset.v);}});
$('refresh').onclick=load;
function ask(t,p,yes){return new Promise(res=>{$('mt').textContent=t;$('mp').innerHTML=p;$('myes').textContent=yes;$('modal').style.display='flex';
 $('myes').onclick=()=>{$('modal').style.display='none';res(true)};$('mno').onclick=()=>{$('modal').style.display='none';res(false)};});}
function busy(on,t){$('busy').style.display=on?'flex':'none';if(t)$('busyt').textContent=t;}
function showResult(r,what){const box=$('result');box.className='card result '+(r.ok?'ok':'err');
 if(r.ok&&r.queued){$('rlog').textContent='';$('rtitle').innerHTML='<span style="color:var(--amber)">&#9203;</span> Queued: '+esc(r.label);
  $('rbody').innerHTML='<p class="sub" style="margin:4px 0 0">'+(r.replaced?'Replaces what was queued for it before. ':'')+'Nothing is changed yet. Keep setting up; when you&rsquo;re done, <b>save and close ShowXpress</b> &mdash; the Helper does everything in the list at the top'+(Q&&Q.reopen?' and opens ShowXpress again':'')+'.</p>';
  qPoll();box.scrollIntoView({behavior:'smooth'});return;}
 const lines=(r.out||'').split(/\r?\n/);$('rlog').textContent=r.out||'';
 const SV=['skip','rig','apc','speed','fix','revert','keep','rt','install','color','gsync','prefix','roominstall','sx','update','remote','auto'];
 if(!r.ok){$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> '+(what==='gsync'?'Not copied':what==='live'?'Live aim didn&rsquo;t start':what==='sx'||what==='update'||what==='prefix'?'Didn&rsquo;t work':SV.includes(what)?'Not saved':'Not applied');$('rbody').innerHTML='<p>'+esc(r.error)+'</p><p class="sub">Nothing was changed.</p>';}
 else if(SV.includes(what)&&what!=='skip'){const same=lines.some(l=>/nothing to change/.test(l))&&!lines.some(l=>/SKIP FLASH now/.test(l));
  const ls=lines.filter(l=>/^ {2}\S/.test(l)).map(l=>l.trim()).filter(l=>!/^(same\s|live\.ini saved|nothing to change|2D view saved|RIGHEADS|SKIPHEADS)/.test(l)).map(l=>l.replace(/^CHANGED\s+/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(same?'Nothing needed changing':{rt:'Saved to the 2D view',install:'RIG ID added',rig:"Tonight's rig saved",apc:'APC pads saved',speed:'Speed faders saved',fix:'Fix applied',revert:'Fix reverted',keep:'Fix kept',color:"Tonight's color saved",gsync:'Copied to Google Drive',prefix:'Done',roominstall:'ROOM buttons added to the SETUP page',sx:'Done',update:'Installer opened',remote:'ShowXpress remote control turned on',auto:'Auto Show saved'}[what]);
  const use=['rig','apc','speed','rt','install','color','roominstall','remote'].includes(what),chk=['fix','revert'].includes(what);
  $('rbody').innerHTML=(ls.length?'<ul>'+ls.map(l=>'<li>'+esc(l)+'</li>').join('')+'</ul>':'')+(use||chk?'<p class="sub" style="margin:8px 0 0">Open ShowXpress to '+(use?'use':'check')+' it.</p>':'');}
 else if(what==='skip'){const same=lines.some(l=>/nothing to change/.test(l));const ls=lines.map(l=>l.trim()).filter(l=>/^(heads|loop):/.test(l));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(same?'SKIP FLASH already uses these heads':'Saved to SKIP FLASH');
  $('rbody').innerHTML='<ul>'+ls.map(l=>'<li>'+esc(l)+'</li>').join('')+'</ul><p class="sub" style="margin:8px 0 0">Open ShowXpress and press <b>SKIP FLASH</b> to check it.</p>';}
 else{const tot=lines.find(l=>/movement scenes checked/.test(l))||'';const ch=lines.filter(l=>/\s[1-9]\d* values changed/.test(l)).map(l=>l.trim().replace(/\s{2,}/g,' — '));
  const wr=lines.filter(l=>/WARNING/.test(l)).map(l=>l.replace(/^\s*WARNING:\s*/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(what==='home'?'Everything is back to normal':'Applied to the show');
  $('rbody').innerHTML='<p class="sub" style="margin:4px 0 0">'+esc(tot.replace(/^\s*->\s*/,''))+'. '+(what==='home'?'':aimMode==='room'?'When ShowXpress opens, <b>ROOM CHECK</b> comes on by itself (with the remote on) &mdash; the beams should trace the edge you aimed.':'When ShowXpress opens, <b>DF CHECK 140</b> + <b>DF CHECK 251</b> come on by themselves (with the remote on) &mdash; the beams should trace the floor corners.')+'</p>'+
   (ch.length?'<ul>'+ch.map(c=>'<li>'+esc(c)+'</li>').join('')+'</ul>':'')+(wr.length?'<div class="warnbox" style="display:block">'+wr.map(esc).join('<br>')+'</div>':'');}
 box.scrollIntoView({behavior:'smooth'});}
$('apply').onclick=async()=>{let force=false;const w=P.heads.filter(h=>h.warn);
 if(w.length){if(!await ask(w.length+' head(s) look wrong','Their aims in '+esc(aimT())+' look far off the floor &mdash; usually step 1 / step 2 not aimed yet.<br><br>Apply anyway?','Apply anyway'))return;force=true;}
 busy(true,'Applying to the show…');try{const r=await api('/api/apply',wq({w:+$('w').value,d:+$('d').value,force,mode:aimMode}));showResult(r,'apply');}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load();};
$('home').onclick=async()=>{if(!await ask('Reset to normal?','All heads go back to the normal center, size 100%, and the '+esc(aimT())+' scene is reset. Your shapes are kept.','Reset'))return;
 busy(true,'Resetting…');try{const r=await api('/api/home',wq({mode:aimMode}));showResult(r,'home');if(!r.queued)LD[aimMode]=0;}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load();};
let Q=null,QSEEN='';const NL=String.fromCharCode(10);
function renderQ(){const b=$('qbar');if(!Q){b.className='qbar';return;}const d=Q.done;
 if(d&&d.at!==QSEEN){const bad=d.results.filter(x=>!x.ok);b.className='qbar on '+(bad.length?'bad':'done');
  b.innerHTML='<h3>'+(bad.length?'&#9888; Done after ShowXpress closed &mdash; '+bad.length+' didn&rsquo;t work':'&#10003; Done after ShowXpress closed')+'</h3><ul>'+
   d.results.map(x=>'<li class="'+(x.ok?'':'no')+'">'+esc(x.label)+(x.ok?' &mdash; done':' &mdash; NOT done: '+esc(x.error))+'</li>').join('')+'</ul>'+
   (d.reopened?'<span class="sub">ShowXpress is opening again.</span> ':d.reopenError?'<span style="color:var(--red)">ShowXpress didn&rsquo;t open: '+esc(d.reopenError)+'</span> ':'')+
   '<details style="display:inline-block;margin-left:8px"><summary class="sub" style="cursor:pointer">Full details</summary><pre>'+esc(d.results.map(x=>'== '+x.label+NL+(x.out||x.error)).join(NL))+'</pre></details> <button class="mini" id="qok">OK</button>';
  $('qok').onclick=async()=>{QSEEN=d.at;try{await api('/api/queue/seen',{});}catch(e){}renderQ();};return;}
 if(!Q.items.length){b.className='qbar';return;}
 b.className='qbar on';b.innerHTML='<h3>&#9203; Waiting for ShowXpress to close &mdash; '+Q.items.length+' thing'+(Q.items.length>1?'s':'')+' to do</h3>'+
  Q.items.map(x=>'<span class="qi">'+esc(x.label)+'<button data-qk="'+esc(x.key)+'" title="Take it off the list">&#10005;</button></span>').join('')+
  '<div class="row" style="margin-top:4px"><label class="link"><input type="checkbox" id="qreo"'+(Q.reopen?' checked':'')+'> Open ShowXpress again afterwards</label><div class="grow"></div>'+
  (sxOpen?'<span class="sub">Save your show, then close ShowXpress.</span><button class="mini primary" id="qclose">Close ShowXpress now</button>':'<span class="sub">ShowXpress is closed &mdash; doing it now&hellip;</span>')+'</div>';
 b.querySelectorAll('[data-qk]').forEach(x=>x.onclick=async()=>{const r=await api('/api/queue/cancel',{key:x.dataset.qk});Q=r.q;renderQ();});
 $('qreo').onchange=async e=>{const r=await api('/api/queue/reopen',{on:e.target.checked});Q=r.q;};
 const qc=$('qclose');if(qc)qc.onclick=sxClose;}
async function qPoll(){try{const r=await api('/api/sx');Q=r.q;renderQ();}catch(e){}}
function reloadAll(){// the queue just changed the show: read everything again (unsaved edits are now saved)
 LD.floor=0;LD.room=0;load();S=null;R=null;A=null;SP=null;H=null;RT=null;CL=null;const b=document.querySelector('.tabs button.on');setTab(b?b.dataset.tab:'home');loadGd();}
async function poll(){try{const r=await api('/api/sx');const was=sxOpen;sxOpen=r.open;const pd=Q&&Q.done?Q.done.at:'';Q=r.q;
 remPoll(r,was);
 if(Q&&Q.done&&Q.done.at!==pd&&Q.done.at!==QSEEN)reloadAll();renderQ();const p=$('sx');p.className='pill '+(sxOpen?'bad':'ok');
 p.textContent=sxOpen?'ShowXpress open'+(Q&&Q.items.length?' · '+Q.items.length+' waiting':''):'ShowXpress closed ✓';$('sxgo').style.display=sxOpen?'none':'';$('sxstop').style.display=sxOpen?'':'none';
 updBar();updSkip();updRig();updApc();updSpeed();updHealth();updRt();updColor();updGd();updPre();
 if(was&&!sxOpen){load();if(S&&!dirty())loadSkip();if(R&&!rgDirty())loadRig();if(A&&!apDirty())loadApc();if(SP&&!spDirty())loadSpeed();if(H)loadHealth();if(RT&&!rtDirty())loadRt();if(CL&&!clDirty())loadColor();loadGd();}}
 catch(e){if(UPD){$('busyt').textContent='Update installed — this window can be closed.';return;}$('gone').style.display='flex';return;}setTimeout(poll,2000);}

// ---------------- tabs
const TABS=['home','rt','rig','aim','skip','color','apc','speed','health','pre','auto'];
let lastTab='';
function setTab(t){if(!TABS.includes(t))t='home';window.scrollTo(0,0);const fresh=t!==lastTab;lastTab=t;
 document.querySelectorAll('.tabs button').forEach(b=>b.classList.toggle('on',b.dataset.tab===t));
 document.querySelectorAll('.view').forEach(v=>v.classList.toggle('on',v.id==='v-'+t));
 document.querySelectorAll('.bar .in').forEach(v=>v.classList.toggle('on',v.dataset.for===t));
 $('result').className='card result';if(t==='skip'&&!S)loadSkip();if(t==='rig'&&!R)loadRig();if(t==='apc'&&!A)loadApc();if(t==='speed'&&!SP)loadSpeed();if(t==='health'&&!H)loadHealth();if(t==='rt'&&!RT)loadRt();if(t==='pre')loadPre();if(t==='color'&&!CL)loadColor();if(t==='home')loadGd();
 if(t==='auto'&&(!AU||!auDirty()))loadAuto();if(REMBOX[t]&&fresh)remRefresh(t,sxOpen&&!remRecent());}
document.querySelectorAll('.tabs button').forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
$('logo').onclick=$('ttl').onclick=()=>setTab('home');document.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>setTab(b.dataset.go));

// ---------------- Skip Flash heads
let S=null,sel=new Set();
const saved=()=>new Set(S&&S.ok?S.heads.filter(h=>h.on).map(h=>h.id):[]);
function dirty(){if(!S||!S.ok)return false;const s=saved();return s.size!==sel.size||[...sel].some(i=>!s.has(i));}
async function loadSkip(){$('sksum').textContent='Loading…';try{S=await api('/api/skip');}catch(e){S={ok:false,error:'Could not read the show.'}}
 sel=saved();renderSkip();}
function flashOrder(){ // same rule as skip_flash.ps1: 140s in the skip order, 251s spread evenly in between
 const hs=S.heads.filter(h=>sel.has(h.id)),pick=(is140,ord)=>{const g=hs.filter(h=>h.is140===is140);return ord.map(n=>g.find(h=>h.num===n)).filter(Boolean).concat(g.filter(h=>!ord.includes(h.num)));};
 const a=pick(true,S.order140),b=pick(false,S.order251),out=[];let i=0,j=0;
 while(i<a.length||j<b.length){const takeA=j>=b.length||(i<a.length&&(i+.5)/a.length<=(j+.5)/b.length);out.push(takeA?a[i++]:b[j++]);}return out;}
function headTile(h,s){const on=sel.has(h.id),chg=on!==s.has(h.id);
 return `<div class="hd${on?' on':''}${chg?' chg':''}" data-id="${esc(h.id)}" title="${chg?'changed - not saved yet':''}">#${h.num}<small>${on?'in use':'not here'}</small></div>`;}
function renderSkip(){if(!S)return;const er=$('skerr');
 if(!S.ok){er.style.display='block';er.innerHTML=esc(S.error);$('skgroups').innerHTML='';$('skorder').innerHTML='';$('sksum').textContent='';$('skstate').style.display='none';updSkip();return;}
 er.style.display='none';const s=saved();
 const grp=(is140,name)=>{const hs=S.heads.filter(h=>h.is140===is140);if(!hs.length)return'';const n=hs.filter(h=>sel.has(h.id)).length;
  return `<div class="gh"><h3>${name}</h3><span class="cnt">${n} of ${hs.length}</span><div class="grow"></div><button class="mini" data-all="${is140?1:0}">All</button><button class="mini" data-none="${is140?1:0}">None</button></div><div class="heads">${hs.map(h=>headTile(h,s)).join('')}</div>`;};
 $('skgroups').innerHTML=grp(true,'140SR')+grp(false,'251SR');
 document.querySelectorAll('.hd').forEach(t=>t.onclick=()=>{const id=t.dataset.id;sel.has(id)?sel.delete(id):sel.add(id);renderSkip();});
 const setG=(is140,on)=>{S.heads.filter(h=>h.is140===is140).forEach(h=>on?sel.add(h.id):sel.delete(h.id));renderSkip();};
 document.querySelectorAll('[data-all]').forEach(b=>b.onclick=()=>setG(b.dataset.all==='1',true));
 document.querySelectorAll('[data-none]').forEach(b=>b.onclick=()=>setG(b.dataset.none==='1',false));
 const o=flashOrder();$('skorder').innerHTML=o.length?o.map(h=>`<span>${esc(h.label)}</span>`).join('<i>&rsaquo;</i>'):'<span style="color:var(--dim)">no heads picked</span>';
 $('sksum').innerHTML=`<b>${o.length}</b> heads &middot; ${S.stepCs/100} s each &middot; one loop <b>${(o.length*S.stepCs/100).toFixed(2)} s</b>`;
 const st=$('skstate');st.style.display='inline-block';const d=dirty();st.className='state '+(d?'chg':'ok');st.textContent=d?'● Not saved yet':'✓ Matches the show';
 $('foot').textContent='Show: '+S.show;updSkip();}
function updSkip(){const ok=S&&S.ok,d=dirty(),n=sel.size;$('sksave').disabled=!ok||!d||n<2;$('skundo').disabled=!ok||!d;
 $('skhint').innerHTML=!ok?'':sxOpen?QH:
  n<2?'<span style="color:var(--amber)">Pick at least 2 heads.</span>':d?'Only the SKIP FLASH scene is changed. Heads you turn off are taken out of it.':'SKIP FLASH already uses exactly these heads.';}
$('skrefresh').onclick=loadSkip;
$('skundo').onclick=()=>{sel=saved();renderSkip();};
$('sksave').onclick=async()=>{busy(true,'Saving SKIP FLASH…');let r;try{r=await api('/api/skip/apply',wq({heads:[...sel]}));}catch(e){r={ok:false,error:'Lost connection.'}}
 busy(false);if(r.ok&&!r.queued){await loadSkip();R=null;H=null;}showResult(r,'skip');};

// ---------------- shared bits for the newer tabs
function stateTag(id,d){const st=$(id);st.style.display='inline-block';st.className='state '+(d?'chg':'ok');st.textContent=d?'● Not saved yet':'✓ Matches the show';}
const QH='<span style="color:var(--amber)">ShowXpress is open &mdash; this is <b>queued</b> and done as soon as you save and close ShowXpress.</span>';
function sxHint(what){return sxOpen?QH:null;}
async function getJ(p){try{return await api(p);}catch(e){return {ok:false,error:'Could not read the show.'};}}
async function saveTo(p,body,label,after,what){busy(true,sxOpen?'Queueing…':label);let r;try{r=await api(p,wq(body));}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);if(r.ok&&!r.queued)await after();showResult(r,what);}
function showErr(id,obj){const er=$(id);if(obj&&!obj.ok){er.style.display='block';er.innerHTML=esc(obj.error);return true;}er.style.display='none';return false;}

// ---------------- Tonight's rig (same step rule as rig.ps1)
let R=null,rsel=new Set();
const rSaved=()=>new Set(R&&R.ok?R.heads.filter(h=>h.on).map(h=>h.id):[]);
function rgDirty(){if(!R||!R.ok)return false;const s=rSaved();return s.size!==rsel.size||[...rsel].some(i=>!s.has(i));}
async function loadRig(){$('rgsum').textContent='Loading…';R=await getJ('/api/rig');rsel=rSaved();renderRig();}
function rigDrop(sc,hung){const gs=sc.groups||[];let drop=[],kept=0;
 for(const g of gs){const s=sc.steps[g[0]];if(!s.other&&s.lit.length&&!s.lit.some(i=>hung.has(i)))drop.push(...g);else kept++;}
 return gs.length&&!kept?null:new Set(drop);}
function renderRig(){if(!R)return;
 if(showErr('rgerr',R)){$('rggroups').innerHTML=$('rgscenes').innerHTML=$('rgsum').innerHTML='';$('rgstate').style.display='none';updRig();return;}
 const s=rSaved();
 const grp=(is140,name)=>{const hs=R.heads.filter(h=>h.is140===is140);if(!hs.length)return'';const n=hs.filter(h=>rsel.has(h.id)).length;
  return `<div class="gh"><h3>${name}</h3><span class="cnt">${n} of ${hs.length} hung</span><div class="grow"></div><button class="mini" data-rall="${is140?1:0}">All</button><button class="mini" data-rnone="${is140?1:0}">None</button></div><div class="heads">`+
   hs.map(h=>{const on=rsel.has(h.id),chg=on!==s.has(h.id);return `<div class="hd${on?' on':''}${chg?' chg':''}" data-rid="${esc(h.id)}" title="${chg?'changed - not saved yet':''}">#${h.num}<small>${on?'hung':'not here'}</small></div>`;}).join('')+'</div>';};
 $('rggroups').innerHTML=grp(true,'140SR')+grp(false,'251SR');
 document.querySelectorAll('[data-rid]').forEach(t=>t.onclick=()=>{const id=t.dataset.rid;rsel.has(id)?rsel.delete(id):rsel.add(id);renderRig();});
 const setG=(is140,on)=>{R.heads.filter(h=>h.is140===is140).forEach(h=>on?rsel.add(h.id):rsel.delete(h.id));renderRig();};
 document.querySelectorAll('[data-rall]').forEach(b=>b.onclick=()=>setG(b.dataset.rall==='1',true));
 document.querySelectorAll('[data-rnone]').forEach(b=>b.onclick=()=>setG(b.dataset.rnone==='1',false));
 let nTrim=0;const scs=R.scenes||[];
 $('rgscenes').innerHTML=scs.map(sc=>{const d=rigDrop(sc,rsel),drop=d||new Set(),n=sc.steps.length;if(drop.size)nTrim++;
  const dots=sc.steps.map((st,i)=>{const c=drop.has(i)?'x':st.lit.length?'l':st.other?'o':'';
   return `<i class="${c}" title="step ${i+1}: ${drop.has(i)?'taken out tonight':st.lit.length?st.lit.length+' mover(s) lit':st.other?'blinder / uplight only':'dark'}"></i>`;}).join('');
  const ti=(sc.titles||[]).filter(t=>t!==sc.name);
  const st=d===null?'<span style="color:var(--amber)">none of its heads hung &mdash; kept complete</span>':drop.size?`<b>${n-drop.size}</b> of ${n} steps`:`all ${n} steps`;
  const tags=(sc.trimmed?'<span class="tag amber" title="trimmed for the rig saved last time">trimmed now</span>':'')+(sc.edited?'<span class="tag red" title="Changed in ShowXpress while it was trimmed - that version now counts as the full scene">edited</span>':'');
  return `<div class="sc${drop.size?' chg':''}"><div class="nm">${esc(sc.name)}${tags}${ti.length?'<small>button: '+esc(ti.join(', '))+'</small>':''}</div><div class="dots">${dots}</div><div class="st">${st}</div></div>`;}).join('')||'<p class="sub">No chase scenes found on your live buttons.</p>';
 $('rgsum').innerHTML=`<b>${scs.length}</b> chase scenes &middot; <b>${nTrim}</b> trimmed for this rig`;
 stateTag('rgstate',rgDirty());$('foot').textContent='Show: '+R.show;updRig();}
function updRig(){const ok=!!(R&&R.ok),d=rgDirty(),n=rsel.size;$('rgsave').disabled=!ok||!d||!n;$('rgundo').disabled=!ok||!d;$('rgall').disabled=!ok||R.heads.every(h=>rsel.has(h.id));
 $('rghint').innerHTML=!ok?'':sxHint('save')??(!n?'<span style="color:var(--amber)">Tick at least one head.</span>':d?'Only chase scenes change. The full scenes are kept, so ticking every head puts them back.':'The show already matches these heads.');}
$('rgrefresh').onclick=loadRig;$('rgundo').onclick=()=>{rsel=rSaved();renderRig();};
$('rgall').onclick=()=>{R.heads.forEach(h=>rsel.add(h.id));renderRig();};
$('rgsave').onclick=()=>saveTo('/api/rig/apply',{heads:[...rsel]},'Saving tonight\'s rig…',async()=>{await loadRig();S=null;H=null;},'rig');

// ---------------- APC mini (pad colours = APC mini mk2 velocity palette)
const PAL='000000 1E1E1E 7F7F7F FFFFFF FF4C4C FF0000 590000 190000 FFBD6C FF5400 591D00 271B00 FFFF4C FFFF00 595900 191900 88FF4C 54FF00 1D5900 142B00 4CFF4C 00FF00 005900 001900 4CFF5E 00FF19 00590D 001902 4CFF88 00FF55 00591D 001F12 4CFFB7 00FF99 005935 001912 4CC3FF 00A9FF 004152 001019 4C88FF 0055FF 001D59 000819 4C4CFF 0000FF 000059 000019 874CFF 5400FF 190064 0F0030 FF4CFF FF00FF 590059 190019 FF4C87 FF0054 59001D 220013 FF1500 993500 795100 436400 033900 005735 00547F 0000FF 00454F 2500CC 7F7F7F 202020 FF0000 BDFF2D AFED06 64FF09 108B00 00FF87 00A9FF 002AFF 3F00FF 7A00FF B21A7D 402100 FF4A00 88E106 72FF15 00FF00 3BFF26 59FF71 38FFCC 5B8AFF 3151C6 877FE9 D31DFF FF005D FF7F00 B9B000 90FF00 835D07 392B00 144C10 0D5038 15152A 16205A 693C1C A8000A DE513D D86A1C FFE126 9EE12F 67B50F 1E1E30 DCFF6B 80FFBD 9A99FF 8E66FF 404040 757575 E0FFFF A00000 350000 1AD000 074200 B9B000 3F3100 B35F00 4B1502'.split(' ');
let A=null,apN={},apC={},apSel=null,apMsg='';
const apOn=p=>(apC[p.sec]||p).on,apOff=p=>(apC[p.sec]||p).off,colChg=p=>!!apC[p.sec]&&(apC[p.sec].on!==p.on||apC[p.sec].off!==p.off);
const SWB=[5,9,13,17,21,29,33,37,41,45,49,53,57,3],SWD=[6,10,14,18,22,30,34,38,42,46,50,54,58,1];
function swRow(k,cur){return [...SWB,...SWD,0].map(v=>`<i class="psw${v===cur?' cur':''}" data-sw="${k}" data-v="${v}" style="background:#${PAL[v]}" title="${v?'colour '+v:'off'}"></i>`).join('');}
const rc=n=>'row '+(8-Math.floor(n/8))+', column '+(n%8+1);
const onGrid=p=>p.type===0&&apN[p.sec]>=0&&apN[p.sec]<=63;
function apDirty(){return !!(A&&A.ok&&A.pads.some(p=>apN[p.sec]!==p.note||colChg(p)));}
async function loadApc(){A=await getJ('/api/apc');apN={};apC={};apSel=null;apMsg='';if(A.ok)A.pads.forEach(p=>apN[p.sec]=p.note);renderApc();}
function padsAt(n){return A.pads.filter(p=>onGrid(p)&&apN[p.sec]===n);}
function padClick(n){const here=padsAt(n);
 if(apSel){const sp=A.pads.find(p=>p.sec===apSel),from=apN[apSel];
  if(onGrid(sp)&&from===n){if(here.length>1){const i=here.findIndex(p=>p.sec===apSel);apSel=here[(i+1)%here.length].sec;}else{apSel=null;apMsg='';}renderApc();return;}
  if(here.length>1){apMsg='That pad already has '+here.length+' buttons on it &mdash; move those apart first.';renderApc();return;}
  if(here.length===1){if(!onGrid(sp)){apMsg='That pad is taken &mdash; pick an empty pad.';renderApc();return;}apN[here[0].sec]=from;}
  apN[apSel]=n;apSel=null;apMsg='';renderApc();return;}
 if(here.length){apSel=here[0].sec;apMsg='';renderApc();}}
function renderApc(){if(!A)return;
 if(showErr('aperr',A)){['apgrid','apside','apfaders','apissues'].forEach(i=>$(i).innerHTML='');$('apstate').style.display='none';updApc();return;}
 let h='',used=0;const free=[];
 for(let r=1;r<=8;r++)for(let c=1;c<=8;c++){const n=(8-r)*8+(c-1),ps=padsAt(n),p=ps.find(x=>x.sec===apSel)||ps[0];
  if(!p){free.push('row '+r+' col '+c);h+=`<div class="pad empty${apSel?' tgt':''}" data-n="${n}" title="${rc(n)} - free"><div class="t">free</div></div>`;continue;}
  used++;const mv=ps.some(x=>apN[x.sec]!==x.note||colChg(x)),bg=PAL[apOff(p)]||'151820',on=PAL[apOn(p)]||'444444';
  h+=`<div class="pad${ps.some(x=>x.sec===apSel)?' sel':''}${apSel?' tgt':''}${mv?' mv':''}${ps.length>1?' dup':''}${p.sceneOk?'':' miss'}" data-n="${n}" style="background:linear-gradient(180deg,rgba(0,0,0,0) 35%,rgba(0,0,0,.6)),#${bg}" title="${esc(ps.map(x=>x.title+' ('+x.pageName+')').join(' + '))} - ${rc(n)}">`+
   `<div class="on" style="background:#${on}"></div>${ps.length>1?`<span class="badge">${ps.length}</span>`:''}<div class="t">${esc(p.title)}</div><div class="p">${esc(p.pageName)}</div></div>`;}
 $('apgrid').innerHTML=h;document.querySelectorAll('.pad').forEach(e=>e.onclick=()=>padClick(+e.dataset.n));
 const sp=apSel&&A.pads.find(p=>p.sec===apSel);
 if(sp){const n=apN[sp.sec],where=n<0?'none &mdash; will be taken off':onGrid(sp)?rc(n):'note '+n+' (not a pad)';
  $('apside').innerHTML=`<h3>${esc(sp.title)}</h3><div class="kv"><span>Page</span><b>${esc(sp.pageName)}</b><span>Scene</span><b>${sp.sceneOk?esc(sp.scene):'<span style="color:var(--red)">'+esc(sp.scene)+' &mdash; missing!</span>'}</b>`+
   `<span>Pad</span><b>${where}${n!==sp.note?' <span class="tag blue">moved</span>':''}</b><span>Light</span><b><span class="sw" style="background:#${PAL[apOn(sp)]||'000000'}"></span>playing &nbsp; <span class="sw" style="background:#${PAL[apOff(sp)]||'000000'}"></span>idle${colChg(sp)?' <span class="tag blue">changed</span>':''}</b>${sp.key?`<span>Key</span><b>${esc(sp.key)}</b>`:''}</div>`+
   (onGrid(sp)&&apN[sp.sec]>=0?`<div class="pcl"><span>Colour while playing</span><div class="pals">${swRow('on',apOn(sp))}</div><span>Colour when idle</span><div class="pals">${swRow('off',apOff(sp))}</div></div>`:'')+
   `<p class="sub" style="margin:0 0 10px">${apMsg||'Tap a colour to change it, or tap the pad it should go to. Tapping a used pad swaps the two.'}</p><div class="row"><button id="apdel">Take off the pads</button><button id="apcancel">Done</button></div>`;
  $('apdel').onclick=()=>{apN[sp.sec]=-1;apSel=null;apMsg='';renderApc();};
  document.querySelectorAll('[data-sw]').forEach(e=>e.onclick=()=>{const c=apC[sp.sec]||{on:sp.on??21,off:sp.off??0};c[e.dataset.sw]=+e.dataset.v;apC[sp.sec]=c;renderApc();});$('apcancel').onclick=()=>{apSel=null;apMsg='';renderApc();};}
 else $('apside').innerHTML=`<h3>Move a pad</h3><p class="sub" style="margin:0 0 8px">Tap a pad to see what it plays, then tap where it should go. A blue dot = moved, not saved yet.</p>${apMsg?'<p class="sub" style="color:var(--amber)">'+apMsg+'</p>':''}<div class="kv"><span>Pads used</span><b>${used} of 64</b><span>Free</span><b>${free.join(', ')||'none'}</b></div>`;
 $('apfaders').innerHTML=(A.faders||[]).map(f=>`<div class="fd"><b>Fader ${f.n}</b><span>CC ${f.cc} &rarr; </span>${esc(f.caption||'?')} speed</div>`).join('');
 const iss=[];
 for(let n=0;n<64;n++){const ps=padsAt(n);if(ps.length>1)iss.push(['error',rc(n)+' plays '+ps.length+' buttons',ps.map(p=>p.title+' ('+p.pageName+')').join(', ')+' &mdash; one press fires all of them. Tap the pad (again to pick the next one) and move one away.','']);}
 A.pads.filter(p=>!p.sceneOk&&apN[p.sec]>=0).forEach(p=>iss.push(['error',p.title+': scene file missing','Plays '+p.scene+', which isn\'t in the show any more.','']));
 A.pads.filter(p=>!onGrid(p)&&apN[p.sec]!==-1).forEach(p=>iss.push(['warn',p.title+' ('+p.pageName+') is mapped outside the pads',(p.type===0?'Note ':'MIDI type '+p.type+', number ')+apN[p.sec]+' &mdash; a round button or track button.',p.type===0?`<button class="mini" data-pick="${esc(p.sec)}">Move to a pad</button> <button class="mini" data-del="${esc(p.sec)}">Take off</button>`:`<button class="mini" data-del="${esc(p.sec)}">Take off</button>`]));
 A.pads.filter(p=>apN[p.sec]===-1).forEach(p=>iss.push(['info',p.title+' ('+p.pageName+') will be taken off the pads','Not saved yet.',`<button class="mini" data-back="${esc(p.sec)}">Put back</button>`]));
 $('apissues').innerHTML=iss.length?iss.map(i=>`<div class="iss ${i[0]}"><div class="ic">${i[0]==='error'?'!':i[0]==='warn'?'?':'i'}</div><div class="grow"><b>${esc(i[1])}</b><div class="d">${i[2]}</div></div><div class="act">${i[3]}</div></div>`).join(''):'<p style="color:var(--green);margin:4px 0">&#10003; Every pad plays one button and every scene exists.</p>';
 document.querySelectorAll('[data-del]').forEach(b=>b.onclick=()=>{apN[b.dataset.del]=-1;apSel=null;renderApc();});
 document.querySelectorAll('[data-back]').forEach(b=>b.onclick=()=>{const p=A.pads.find(x=>x.sec===b.dataset.back);apN[p.sec]=p.note;renderApc();});
 document.querySelectorAll('[data-pick]').forEach(b=>b.onclick=()=>{apSel=b.dataset.pick;apMsg='Tap a free pad to put it there.';renderApc();window.scrollTo({top:0,behavior:'smooth'});});
 stateTag('apstate',apDirty());$('foot').textContent='Show: '+A.show;updApc();}
function updApc(){const ok=!!(A&&A.ok),d=apDirty();$('apsave').disabled=!ok||!d;$('apundo').disabled=!ok||!d;
 $('aphint').innerHTML=!ok?'':sxHint('save')??(d?A.pads.filter(p=>apN[p.sec]!==p.note||colChg(p)).length+' button(s) changed. Only the pad notes and pad colours in live.ini change.':'Pads match the show.');}
$('aprefresh').onclick=loadApc;$('apundo').onclick=()=>{A.pads.forEach(p=>apN[p.sec]=p.note);apC={};apSel=null;apMsg='';renderApc();};
$('apsave').onclick=()=>saveTo('/api/apc/apply',{changes:A.pads.filter(p=>apN[p.sec]!==p.note||colChg(p)).map(p=>{const c={sec:p.sec,title:p.title,note:apN[p.sec]};if(colChg(p)&&apN[p.sec]>=0){c.on=apC[p.sec].on;c.off=apC[p.sec].off;}return c;})},'Saving pads…',async()=>{await loadApc();SP=null;H=null;},'apc');

// ---------------- Speed faders
let SP=null,spF={},spOnly=-1;
function spDirty(){return !!(SP&&SP.ok&&SP.buttons.some(b=>spF[b.sec]!==b.fader));}
async function loadSpeed(){SP=await getJ('/api/speed');spF={};if(SP.ok)SP.buttons.forEach(b=>spF[b.sec]=b.fader);renderSpeed();}
function bInfo(b){if(b.missing)return['scene file missing','no'];if(b.gen)return['Generator movement'+(b.beat?' &middot; beat sync':''),''];
 if(b.steps>1)return[b.steps+' steps'+(b.beat?' &middot; beat sync':''),''];return['1 step &mdash; speed does nothing','no'];}
function fOpts(sel,first){return (first?`<option value="">${first}</option>`:'')+SP.faders.map(f=>`<option value="${f.k}"${f.k===sel?' selected':''}>${esc(f.caption||('Fader '+(f.k+1)))}</option>`).join('');}
function renderSpeed(){if(!SP)return;
 if(showErr('sperr',SP)){$('splegend').innerHTML=$('splist').innerHTML='';$('spstate').style.display='none';updSpeed();return;}
 $('splegend').innerHTML=SP.faders.map(f=>{const n=SP.buttons.filter(b=>spF[b.sec]===f.k).length;return `<div class="lg${spOnly===f.k?' on':''}" data-f="${f.k}" title="show only these"><b>${n}</b>${esc(f.caption||('Fader '+(f.k+1)))}</div>`;}).join('');
 document.querySelectorAll('.lg').forEach(e=>e.onclick=()=>{spOnly=spOnly===+e.dataset.f?-1:+e.dataset.f;renderSpeed();});
 const q=$('spq').value.trim().toLowerCase(),pages=[];
 SP.buttons.forEach(b=>{if(spOnly>=0&&spF[b.sec]!==spOnly)return;if(q&&!(b.title+' '+b.scene+' '+b.pageName).toLowerCase().includes(q))return;
  let g=pages.find(x=>x.page===b.page);if(!g)pages.push(g={page:b.page,name:b.pageName,bs:[]});g.bs.push(b);});
 $('splist').innerHTML=pages.map(g=>`<div class="spg"><div class="gh"><h3>${esc(g.name.toUpperCase())}</h3><span class="cnt">${g.bs.length}</span><div class="grow"></div><select data-pg="${g.page}">${fOpts(-1,'Set all on this page&hellip;')}</select></div>`+
  g.bs.map(b=>{const [t,c]=bInfo(b),chg=spF[b.sec]!==b.fader;return `<div class="sp${chg?' chg':''}"><div><b>${esc(b.title||b.scene)}</b>${chg?' <span class="tag blue">changed</span>':''}</div><div class="i ${c}">${t}</div><select data-sec="${esc(b.sec)}">${fOpts(spF[b.sec])}</select></div>`;}).join('')+'</div>').join('')||'<p class="sub" style="margin-top:14px">No buttons match.</p>';
 document.querySelectorAll('[data-sec]').forEach(s=>s.onchange=()=>{spF[s.dataset.sec]=+s.value;renderSpeed();});
 document.querySelectorAll('[data-pg]').forEach(s=>s.onchange=()=>{if(s.value==='')return;const k=+s.value,g=pages.find(x=>x.page===+s.dataset.pg);
  if(g)g.bs.forEach(b=>spF[b.sec]=k);renderSpeed();});
 stateTag('spstate',spDirty());$('foot').textContent='Show: '+SP.show;updSpeed();}
function updSpeed(){const ok=!!(SP&&SP.ok),d=spDirty();$('spsave').disabled=!ok||!d;$('spundo').disabled=!ok||!d;
 $('sphint').innerHTML=!ok?'':sxHint('save')??(d?SP.buttons.filter(b=>spF[b.sec]!==b.fader).length+' button(s) changed. Only the speed fader setting in live.ini changes.':'Every button matches the show.');}
$('spq').oninput=renderSpeed;$('sprefresh').onclick=loadSpeed;$('spundo').onclick=()=>{SP.buttons.forEach(b=>spF[b.sec]=b.fader);renderSpeed();};
$('spsave').onclick=()=>saveTo('/api/speed/apply',{changes:SP.buttons.filter(b=>spF[b.sec]!==b.fader).map(b=>({sec:b.sec,title:b.title,fader:spF[b.sec]}))},'Saving speed faders…',async()=>{await loadSpeed();A=null;H=null;},'speed');

// ---------------- Health check (check / fix / revert / keep)
let H=null;
async function loadHealth(){$('hlsum').innerHTML='Checking the show&hellip;';$('hllist').innerHTML='';$('hlapplied').innerHTML='';H=await getJ('/api/health');renderHealth();}
function renderHealth(){if(!H)return;if(!H.ok){$('hlsum').innerHTML='<span style="color:var(--red)">'+esc(H.error)+'</span>';$('hllist').innerHTML='';$('hlapplied').innerHTML='';updHealth();return;}
 const is=H.issues||[],ap=H.applied||[],c=l=>is.filter(i=>i.level===l).length;
 const row=i=>`<div class="iss ${i.level}"><div class="ic">${i.level==='error'?'!':i.level==='warn'?'?':'i'}</div><div class="grow"><b>${esc(i.title)}</b><div class="d">${esc(i.detail)}</div>${i.advice?`<div class="fx"><b>Fix:</b> ${esc(i.advice)}</div>`:''}</div>${i.fix?`<div class="act"><button class="mini primary hfix" data-k="${esc(i.fix.key)}">${esc(i.fix.label)}</button></div>`:''}</div>`;
 $('hlapplied').innerHTML=ap.length?`<div class="applied"><h3>&#10003; Fixes you applied (${ap.length})</h3>${ap.map(a=>`<div class="iss done"><div class="ic">&#10003;</div><div class="grow"><b>${esc(a.title)}</b><div class="d">${esc(a.label)} &middot; ${esc(a.time)} &mdash; <b>Revert</b> puts it back as it was, <b>Keep</b> forgets the backup.</div></div><div class="act"><button class="mini hrev" data-i="${esc(a.id)}">&#8630; Revert</button><button class="mini hkeep" data-i="${esc(a.id)}">Keep</button></div></div>`).join('')}</div>`:'';
 const nf=is.filter(i=>i.fix).length;
 $('hlsum').innerHTML=`Checked <b>${H.buttons}</b> buttons and <b>${H.scenes}</b> scenes &mdash; <b style="color:var(--red)">${c('error')}</b> problem(s) &middot; <b style="color:var(--amber)">${c('warn')}</b> warning(s) &middot; <b style="color:var(--blue)">${c('info')}</b> note(s)`+(nf?` &middot; <b style="color:var(--green)">${nf}</b> can be fixed here`:'');
 const main=is.filter(i=>i.level!=='info'),info=is.filter(i=>i.level==='info');
 $('hllist').innerHTML=(main.length?main.map(row).join(''):'<p style="color:var(--green);margin:6px 0">&#10003; No problems found.</p>')+(info.length?`<details><summary>${info.length} note(s) &mdash; probably fine</summary>${info.map(row).join('')}</details>`:'');
 document.querySelectorAll('.hfix').forEach(b=>b.onclick=()=>hlFix(b.dataset.k));
 document.querySelectorAll('.hrev').forEach(b=>b.onclick=()=>hlRev(b.dataset.i,false));
 document.querySelectorAll('.hkeep').forEach(b=>b.onclick=()=>hlKeep(b.dataset.i));
 $('foot').textContent='Show: '+H.show;updHealth();}
function updHealth(){const ok=!!(H&&H.ok);document.querySelectorAll('.hfix').forEach(b=>b.disabled=!ok);document.querySelectorAll('.hrev').forEach(b=>b.disabled=sxOpen||!ok);
 $('hlhint').innerHTML=sxHint('apply or revert a fix')??'Checking changes nothing. A fix changes only what it says, and can be reverted at the top of this tab.';}
async function hlAfter(){if(!dirty())S=null;if(!rgDirty())R=null;if(!apDirty())A=null;if(!spDirty())SP=null;await loadHealth();}
async function hlFix(k){const i=(H.issues||[]).find(x=>x.fix&&x.fix.key===k);if(!i)return;
 if(!await ask('Apply this fix?','<b>'+esc(i.title)+'</b><br><br>'+esc(i.advice)+'<br><br>You can revert it afterwards at the top of this tab.',i.fix.label))return;
 await saveTo('/api/health/fix',{key:k},'Applying the fix…',hlAfter,'fix');}
async function hlRev(id,force){const a=(H.applied||[]).find(x=>x.id===id);if(!a)return;
 if(!force&&!await ask('Revert this fix?','<b>'+esc(a.title)+'</b><br><br>Puts back what &ldquo;'+esc(a.label)+'&rdquo; changed, exactly as it was before.','Revert'))return;
 busy(true,'Reverting…');let r;try{r=await api('/api/health/revert',{id,force:!!force});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 if(r.ok&&r.conflict){if(await ask('Changed since the fix','<ul>'+r.conflict.map(x=>'<li>'+esc(x)+'</li>').join('')+'</ul>Reverting puts back the version from before the fix, so those later changes are lost too.','Revert anyway'))return hlRev(id,true);return;}
 if(r.ok)await hlAfter();showResult(r,'revert');}
async function hlKeep(id){const a=(H.applied||[]).find(x=>x.id===id);if(!a)return;
 if(!await ask('Keep this fix?','The backup of <b>'+esc(a.title)+'</b> is deleted, so it can&rsquo;t be reverted any more. The fix itself stays.','Keep it'))return;
 await saveTo('/api/health/keep',{id},'Saving…',loadHealth,'keep');}
$('hlrun').onclick=loadHealth;

// ---------------- Rig Test (rig_test.ps1)
let RT=null,rtA={},rtX=false,rtSlot=null;
const rtHead=id=>RT.heads.find(h=>h.id===id);
const rtUsed=k=>rtX||!RT.slots.find(s=>s.key===k).extra;
function rtDirty(){if(!RT||!RT.ok)return false;const a=RT.assign||{},ks=new Set([...Object.keys(a),...Object.keys(rtA)]);return rtX!==!!RT.extra||[...ks].some(k=>(a[k]||'')!==(rtA[k]||''));}
async function loadRt(){RT=await getJ('/api/rt');rtA={};rtX=false;if(RT.ok){Object.assign(rtA,RT.assign||{});rtX=!!RT.extra;}renderRt();}
function lookHtml(h){return `<span class="dot${h.flash?' fl':''}" style="background:#${h.hex}"></span>`;}
function renderRt(){if(!RT)return;
 if(showErr('rterr',RT)){['rtmap','rtlegend'].forEach(i=>$(i).innerHTML='');$('rtinst').style.display='none';$('rtstate').style.display='none';updRt();return;}
 const ins=RT.install||{},ib=$('rtinst');
 if(!ins.scene||!ins.button){ib.style.display='block';ib.innerHTML='The <b>RIG ID</b> button isn&rsquo;t in the show yet. <button id="rtinstb" class="mini primary" style="margin-left:8px">Add RIG ID to the SETUP page</button>';
  $('rtinstb').onclick=()=>saveTo('/api/rt/install',{},'Adding RIG ID…',loadRt,'install');}
 else if(ins.old){ib.style.display='block';ib.innerHTML='The <b>RIG ID</b> scene in the show is the old one (amber instead of light green, no visible flash). <button id="rtinstb" class="mini primary" style="margin-left:8px">Update RIG ID</button>';
  $('rtinstb').onclick=()=>saveTo('/api/rt/install',{},'Updating RIG ID…',loadRt,'install');}else ib.style.display='none';
 $('rtlegend').innerHTML=RT.heads.map(h=>`<div>${lookHtml(h)}<b>#${h.num}</b>${esc(h.look)}${h.flash?' flashing':''}</div>`).join('');
 $('rtextra').checked=rtX;
 const a0=RT.assign||{},placed=new Set(Object.entries(rtA).filter(([k,v])=>v&&rtUsed(k)).map(([k,v])=>v));
 const tower=t=>{const ss=RT.slots.filter(s=>s.tower===t),ex=ss[0].extra;
  return `<div class="tw${ex&&!rtX?' off':''}" style="grid-column:${t[1]==='l'?1:t[1]==='m'?2:3};grid-row:${t[0]==='t'?1:3}"><h4>${esc(ss[0].towerName)} tower</h4><div class="pr">`+ss.map(s=>{const id=rtA[s.key],h=id&&rtHead(id),chg=(a0[s.key]||'')!==(id||'');
   return `<div class="slot${h?' set':''}${chg?' chg':''}" data-slot="${s.key}"><span class="sd">${s.side} mover</span>${h?`${lookHtml(h)}<b>#${h.num}</b><br><small>${esc(h.look)}${h.flash?' flashing':''}</small>`:'<small>tap to set</small>'}</div>`;}).join('')+'</div></div>';};
 const spare=RT.heads.filter(h=>!placed.has(h.id));
 $('rtmap').innerHTML=['tl','tm','tr','bl','bm','br'].map(tower).join('')+
  `<div class="mid">${spare.length?`<div>Not on a truss &mdash; grouped in the middle of the 2D page</div><div class="sp2">${spare.map(h=>`<span>#${h.num}</span>`).join('')}</div>`:'Every 140 is on a truss'}</div><div class="dj">&#9650; DJ BOOTH (you) &#9650;</div>`;
 document.querySelectorAll('[data-slot]').forEach(e=>e.onclick=()=>rtOpen(e.dataset.slot));
 stateTag('rtstate',rtDirty());$('foot').textContent='Show: '+RT.show+(RT.saved?' · Rig Test last saved '+RT.saved.replace('T',' '):'');updRt();}
function rtOpen(k){rtSlot=k;const s=RT.slots.find(x=>x.key===k),cur=rtA[k];$('rtpt').textContent=s.towerName+' tower — '+s.side+' mover';
 const where=id=>{const e=Object.entries(rtA).find(([kk,v])=>v===id&&kk!==k&&rtUsed(kk));if(!e)return'';const o=RT.slots.find(x=>x.key===e[0]);return 'now '+o.towerName.toLowerCase()+' '+o.side;};
 const grid=fl=>`<div class="pick">${RT.heads.filter(h=>h.flash===fl).map(h=>`<div data-pk="${h.id}" class="${h.id===cur?'cur':''}">${lookHtml(h)}#${h.num}<small>${esc(h.look)}</small><small>${esc(where(h.id))||'&nbsp;'}</small></div>`).join('')}</div>`;
 $('rtpb').innerHTML='<div class="gh"><h3>SOLID</h3></div>'+grid(false)+'<div class="gh"><h3>FLASHING</h3></div>'+grid(true);
 document.querySelectorAll('[data-pk]').forEach(e=>e.onclick=()=>{const id=e.dataset.pk;for(const kk of Object.keys(rtA))if(rtA[kk]===id)delete rtA[kk];rtA[k]=id;$('rtpick').style.display='none';renderRt();});
 $('rtpick').style.display='flex';}
$('rtpnone').onclick=()=>{delete rtA[rtSlot];$('rtpick').style.display='none';renderRt();};
$('rtpcancel').onclick=()=>{$('rtpick').style.display='none';};
$('rtextra').onchange=e=>{rtX=e.target.checked;renderRt();};
function rtCount(){return Object.entries(rtA).filter(([k,v])=>v&&rtUsed(k)).length;}
function updRt(){const ok=!!(RT&&RT.ok),d=rtDirty(),n=ok?rtCount():0;$('rtsave').disabled=!ok||!n;$('rtundo').disabled=!ok||!d;$('rtclear').disabled=!ok||!Object.keys(rtA).length;
 $('rthint').innerHTML=!ok?'':sxHint('save (it rewrites the 2D view when it closes)')??(!n?'<span style="color:var(--amber)">Put at least one mover on a truss.</span>':n+' mover(s) on trusses. Only the 140 positions in the 2D view change'+($('rtrig').checked?', plus Tonight\'s Rig and SKIP FLASH.':'.'));}
$('rtrig').onchange=updRt;$('rtrefresh').onclick=loadRt;
$('rtundo').onclick=()=>{rtA=Object.assign({},RT.assign||{});rtX=!!RT.extra;renderRt();};
$('rtclear').onclick=()=>{rtA={};renderRt();};
$('rtsave').onclick=()=>{const a={};for(const [k,v] of Object.entries(rtA))if(v&&rtUsed(k))a[k]=v;
 saveTo('/api/rt/apply',{assign:a,extra:rtX,rig:$('rtrig').checked},'Saving the 2D view…',async()=>{await loadRt();R=null;S=null;H=null;},'rt');};

// ---------------- Pre-show check (preshow.ps1 + the health check)
let PRE=[];
async function loadPre(){$('presum').innerHTML='Checking&hellip;';$('prelist').innerHTML='';const [p,h,gd]=await Promise.all([getJ('/api/pre'),H?Promise.resolve(H):getJ('/api/health'),getJ('/api/gdrive')]);
 if(h&&h.ok)H=h;if(gd&&gd.ok){G=gd;updGd();}if(!p.ok){$('presum').innerHTML='<span style="color:var(--red)">'+esc(p.error)+'</span>';return;}
 const it=[...p.items];
 if(h&&h.ok){const e=(h.issues||[]).filter(i=>i.level==='error').length,w=(h.issues||[]).filter(i=>i.level==='warn').length,fx={key:'tab:health',label:'Open Health Check'};
  it.splice(2,0,e?{group:'Show',level:'error',title:'Health Check: '+e+' problem(s) in the show',detail:w?w+' warning(s) too.':'',advice:'Open the Health Check tab and look at the red ones.',fix:fx}:
   w?{group:'Show',level:'warn',title:'Health Check: '+w+' warning(s)',detail:'No real problems.',advice:'Have a look in the Health Check tab if you have time.',fix:fx}:{group:'Show',level:'ok',title:'Health Check: no problems in the show',detail:'',advice:''});}
 if(gd&&gd.ok){const today=gd.last&&new Date(gd.last).toDateString()===new Date().toDateString();
  it.push(!gd.found?{group:'Show',level:'info',title:'Google Drive not found on this laptop',detail:'The show can&rsquo;t be backed up to Google Drive > AWAAZ > Lighting.',advice:'Install Google Drive for desktop and sign in.'}:
   today?{group:'Show',level:'ok',title:'Backed up to Google Drive '+fmtT(gd.last),detail:'',advice:''}:
   {group:'Show',level:'warn',title:gd.last?'Last backed up to Google Drive '+fmtT(gd.last):'Show not backed up to Google Drive yet',detail:'A copy in Google Drive > AWAAZ > Lighting saves the night if this laptop dies.',advice:'Close ShowXpress (save first), sync, then open it again.',fix:{key:'gsync',label:'Sync now'}});}
 PRE=it;
 const c=l=>it.filter(i=>i.level===l).length;
 $('presum').innerHTML=c('error')?`<b style="color:var(--red)">${c('error')} thing(s) to fix</b> before the show &middot; ${c('warn')} to check`:c('warn')?`<b style="color:var(--amber)">${c('warn')} thing(s) to check</b> &mdash; nothing broken`:'<b style="color:var(--green)">&#10003; All good &mdash; ready for the show</b>';
 const groups=[...new Set(it.map(i=>i.group))];
 $('prelist').innerHTML=groups.map(g=>`<div class="pgrp"><h3>${esc(g.toUpperCase())}</h3>`+it.filter(i=>i.group===g).map(i=>`<div class="iss ${i.level}"><div class="ic">${i.level==='ok'?'&#10003;':i.level==='error'?'!':i.level==='warn'?'?':'i'}</div><div class="grow"><b>${esc(i.title)}</b>${i.detail?`<div class="d">${esc(i.detail)}</div>`:''}${i.advice&&i.level!=='ok'?`<div class="fx"><b>Fix:</b> ${esc(i.advice)}</div>`:''}</div>${i.fix&&i.level!=='ok'?`<div class="act"><button class="mini primary pfix" data-k="${esc(i.fix.key)}">${esc(i.fix.label)}</button></div>`:''}</div>`).join('')+'</div>').join('');
 document.querySelectorAll('.pfix').forEach(b=>b.onclick=()=>preFix(b.dataset.k));updPre();
 $('prehint').textContent='Checked at '+new Date().toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})+'. Checking changes nothing; a fix button changes only what it says.';$('foot').textContent='Show: '+p.show;}
function updPre(){document.querySelectorAll('.pfix').forEach(b=>{const k=b.dataset.k;b.disabled=sxOpen&&(k==='gsync'||k==='launch');b.title=b.disabled&&k==='gsync'?'Close ShowXpress first (save first)':'';});
 $('pregd').disabled=!(G&&G.ok&&G.found);}
async function preFix(k){const i=PRE.find(x=>x.fix&&x.fix.key===k);if(!i)return;
 if(k.startsWith('tab:'))return setTab(k.slice(4));if(k==='launch')return sxLaunch();if(k==='gsync')return gdSync();
 const msg={sleep:'Sets <b>When plugged in, PC goes to sleep after</b> to <b>Never</b>.',usb:'Turns <b>USB selective suspend</b> off when plugged in, so Windows never powers down the APC mini or the DMX interface.',restart:'<b>Windows restarts in 1 minute</b> to finish its updates. Save and close ShowXpress first. (Changed your mind? Run <b>shutdown /a</b>.)'}[k];
 if(!await ask(i.title,msg||'',i.fix.label))return;
 await saveTo('/api/pre/fix',{key:k},'Applying the fix…',loadPre,'prefix');}
$('prerun').onclick=()=>{H=null;loadPre();};$('pregd').onclick=()=>gdSync();

// ---------------- Aim Movers: Dance Floor / Room
const AIMTXT={floor:{t:'Dance floor &mdash; tonight\'s aims',how:['<b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight\'s dancefloor &mdash; or just <b>one head per T-bar</b>: the head next to it gets the same aim (unless you aim that one too).','<b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size. A copied head gets this too.','<b>THEN</b>Save, close ShowXpress, press Refresh below, check the heads and Apply &mdash; <b>DF CHECK</b> comes on by itself when ShowXpress opens again.'],
  depth:'Depth',size:'100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.',svg:'dashed = dancefloor · amber = patterns'},
 room:{t:'Room &mdash; AROUND ROOM for tonight',how:['<b>STEP 1 &middot; CENTER</b>Aim every head at the middle of where AROUND ROOM should sweep (the walls around the room).','<b>STEP 2 &middot; CORNER</b>Optional: aim a head at the front-left edge of that sweep (from the DJ) to set its size.','<b>THEN</b>Save, close ShowXpress, press Refresh below and Apply &mdash; <b>ROOM CHECK</b> comes on by itself when ShowXpress opens again.'],
  depth:'Height',size:'100% = AROUND ROOM reaches the edge you aimed. Width = across the room, Height = up and down the walls.',svg:'dashed = what you aimed · amber = AROUND ROOM'}};
function aimTxt(){const x=AIMTXT[aimMode];$('aimttl').innerHTML=x.t;$('aimhow').innerHTML=x.how.map(h=>'<div>'+h+'</div>').join('');$('dlab').textContent=x.depth;$('sizesub').textContent=x.size;$('svgl').textContent=x.svg;$('aimsc').textContent=aimMode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)';}
document.querySelectorAll('[data-am]').forEach(b=>b.onclick=()=>{if(aimMode===b.dataset.am)return;aimMode=b.dataset.am;document.querySelectorAll('[data-am]').forEach(x=>x.classList.toggle('on',x===b));
 aimTxt();remRefresh('aim',sxOpen&&!remRecent());$('aiminst').style.display='none';$('heads').innerHTML='';$('warnbox').style.display='none';$('result').className='card result';P=PM[aimMode];LD[aimMode]=0;render();load();});

// ---------------- ShowXpress remote (sx_remote.ps1): the Helper presses buttons in ShowXpress itself
let PEND=false,REMSEEN=null,REMAT=0,remWait=0,remBusy=false;const REMR={},REMBOX={rt:'rtrem',aim:'aimrem'};
function remSets(t){if(t==='rt')return [{label:'RIG ID',titles:['RIG ID']}];
 return aimMode==='room'?[{label:'ROOM AIM (ADJUST)',titles:['ROOM AIM (ADJUST)']},{label:'ROOM CHECK',titles:['ROOM CHECK']}]
  :[{label:'DF AIM (ADJUST)',titles:['DF AIM (ADJUST)']},{label:'DF CHECK 140 + 251',titles:['DF CHECK 140','DF CHECK 251']}];}
function curTab(){const b=document.querySelector('.tabs button.on');return b?b.dataset.tab:'home';}
const isSetup=p=>/^\s*setup\s*$/i.test(p||'');
function remRecent(){return PEND||(REMAT&&Date.now()-REMAT<60000);}
async function remGet(p,b){try{return await api(p,b);}catch(e){return {ok:false,error:'Lost connection.'};}}
async function remRefresh(t,auto){if(!REMBOX[t])return null;const sets=remSets(t),box=$(REMBOX[t]);
 if(!REMR[t]){box.className='remrow on';box.innerHTML='<span>Checking ShowXpress&hellip;</span>';}
 const doAuto=auto&&sxOpen&&!(AUS&&AUS.running)&&!PEND;
 const r=doAuto?await remGet('/api/remote/press',{titles:sets[0].titles,solo:true,idle:true}):await remGet('/api/remote');
 r.auto=doAuto;if(doAuto&&r.connected&&!r.skipped&&(r.pressedNow||[]).length)r.note='&#10003; Turned on by the Helper.';
 REMR[t]=r;if(curTab()===t)remDraw(t);return r;}
function remDraw(t){const box=$(REMBOX[t]),r=REMR[t],sets=remSets(t);box.className='remrow on';if(!r){box.innerHTML='';return;}let h;
 if(r.ok===false&&!r.setup)h='<div class="grow">'+esc(r.error||'')+'</div><button class="mini" data-rem="retry">Try again</button>';
 else if(!r.ready)h='<div class="grow"><b>Let the Helper press '+esc(sets.map(s=>s.label).join(' / '))+' for you.</b> Turn on ShowXpress remote control once &mdash; it&rsquo;s saved in the show'+(sxOpen?' (done when ShowXpress next closes).':'.')+'</div><button class="mini primary" data-rem="enable">Turn on remote control</button>';
 else if(!r.open)h='<div class="grow">ShowXpress is closed. Open it and the Helper turns on <b>'+esc(sets[0].label)+'</b> by itself.</div><button class="mini" data-rem="launch">&#9654; Launch ShowXpress</button>';
 else if(!r.connected)h='<div class="grow">'+esc(r.error||'')+'</div><button class="mini" data-rem="retry">Try again</button>';
 else{const on=new Set((r.pressed||[]).map(p=>p.title)),have=new Set(r.titles||[]),cur=sets.find(s=>s.titles.every(x=>on.has(x)));
  h='<div class="grow">'+(r.note?r.note+' ':'')+(r.skipped?'<b style="color:var(--amber)">Your show is playing</b> ('+esc((r.playing||[]).slice(0,4).join(', '))+((r.playing||[]).length>4?'&hellip;':'')+') &mdash; the Helper didn&rsquo;t press anything, so it isn&rsquo;t cut. ':'')+
   (cur?'<b style="color:var(--green)">&#9679; '+esc(cur.label)+'</b> is on in ShowXpress.':on.size?'Playing: '+esc([...on].slice(0,5).join(', '))+(on.size>5?'&hellip;':''):'Nothing is playing in ShowXpress.')+'</div>'+
   sets.map((s,i)=>{const miss=s.titles.some(x=>!have.has(x));return '<button class="mini'+(cur===s?' son':'')+'" data-rem="set" data-i="'+i+'"'+(miss?' disabled title="Not in the show yet"':'')+'>'+esc(s.label)+'</button>';}).join('')+
   (on.size?'<button class="mini" data-rem="off">All off</button>':'');}
 box.innerHTML=h;box.querySelectorAll('[data-rem]').forEach(b=>b.onclick=()=>remAct(t,b.dataset.rem,+b.dataset.i));}
async function remEnable(after){if(!await ask('Turn on ShowXpress remote control?','Lets the Helper press buttons in ShowXpress (RIG ID, DF CHECK, ROOM CHECK, Auto Show). It switches on <b>External App</b> in ShowXpress and remote access for every Live page, with a password only the Helper uses. Only this computer connects to it.'+(sxOpen?'<br><br>ShowXpress is open, so it&rsquo;s done when you next close it.':''),'Turn it on'))return;
 await saveTo('/api/remote/enable',{},'Turning on the remote…',after,'remote');}
async function remAct(t,k,i){const sets=remSets(t),r=REMR[t];
 if(k==='retry')return remRefresh(t,false);
 if(k==='launch')return sxLaunch();
 if(k==='enable')return remEnable(async()=>{await remRefresh(t,false);});
 if(k==='off'){if(!await ask('Turn everything off?','Releases every button that is playing in ShowXpress.'+(AUS&&AUS.running?' The Auto Show keeps playing &mdash; stop it in its tab.':''),'All off'))return;
  REMR[t]=await remGet('/api/remote/off',{});remDraw(t);return;}
 if(k==='set'){const s=sets[i],pl=((r&&r.pressed)||[]).filter(p=>!isSetup(p.page)&&!s.titles.includes(p.title)).map(p=>p.title);
  if(pl.length&&!await ask('Turn off what is playing?','<b>'+esc(pl.slice(0,6).join(', '))+(pl.length>6?'&hellip;':'')+'</b> '+(pl.length>1?'are':'is')+' playing. Turning on '+esc(s.label)+' turns '+(pl.length>1?'them':'it')+' off.','Turn on '+s.label))return;
  REMR[t]=await remGet('/api/remote/press',{titles:s.titles,solo:true});remDraw(t);}}
function remPoll(r,was){PEND=!!r.pend;const a=AUS;AUS=r.auto||null;auPill();if(curTab()==='auto'&&(!!(a&&a.running)!==!!(AUS&&AUS.running)))auPlay();
 if(r.rem){REMAT=Date.parse(r.rem.at)||0;if(REMSEEN!==null&&r.rem.at!==REMSEEN){const t=curTab(),m=r.rem;
   const msg=m.ok?'&#10003; The Helper turned on <b>'+esc(m.label)+'</b> &mdash; check the beams.':m.skipped?'Your show was playing, so <b>'+esc(m.label)+'</b> wasn&rsquo;t turned on.':'';
   if(REMBOX[t])remRefresh(t,false).then(x=>{if(x&&msg){x.note=msg;remDraw(t);}});}
  REMSEEN=r.rem.at;}else if(REMSEEN===null)REMSEEN='';
 if(!was&&r.open)remWait=Date.now();
 if(was&&!r.open){for(const k in REMBOX)if(REMR[k]){REMR[k]=null;if(curTab()===k)remRefresh(k,false);}}
 const t=curTab();
 if(remWait&&REMBOX[t]&&r.open&&!remBusy){if(Date.now()-remWait>90000)remWait=0;
  else if(!REMR[t]||!REMR[t].connected||(!REMR[t].auto&&!remRecent())){remBusy=true;remRefresh(t,!remRecent()).then(x=>{remBusy=false;if(x&&(x.connected||x.ready===false))remWait=0;});}}}

// ---------------- Auto Show (sx_remote.ps1 -Action Auto, settings in <show>/auto_show.json)
let AU=null,auC=null,AUS=null,auTried=[],auTaps=[],auPk=-1,auStF=false,auLastId='',auBpmT=0;
const AUBARS=[1,2,4,8,12,16,24,32,48,64];
const rid=()=>Array.from({length:8},()=>'0123456789abcdef'[Math.random()*16|0]).join('');
const clone=o=>JSON.parse(JSON.stringify(o));
function auDirty(){return !!(AU&&AU.ok&&auC&&JSON.stringify(auC)!==JSON.stringify(AU.config));}
async function loadAuto(){$('ausum').textContent='Loading…';AU=await getJ('/api/auto');if(AU.ok){auC=clone(AU.config);if(AU.status)AUS=AU.status;}renderAuto();}
function auBtn(t){return AU.buttons.find(b=>b.title===t&&!b.dup);}
function auSec(l){return l.bars*4*60/auC.bpm;}
// ShowXpress "swap" page (MOVEMENTS): one button at a time - several of them in one look can't play together
function auClash(l){const g={};for(const x of l.titles){const b=auBtn(x);if(b&&b.swap)(g[b.page]=g[b.page]||[]).push(x);}return Object.entries(g).filter(e=>e[1].length>1);}
function auSplit(i){const l=auC.looks[i],cl=auClash(l);if(!cl.length)return 0;const[pg,many]=cl.sort((a,b)=>b[1].length-a[1].length)[0];
 const rest=l.titles.filter(x=>!many.includes(x)),one=new Set(many);
 const nl=many.map((m,k)=>({id:k?rid():l.id,name:(many.length>1?m:l.name).slice(0,40),bars:l.bars,on:l.on,titles:rest.filter(x=>!(auBtn(x)&&auBtn(x).swap&&auBtn(x).page===pg)).concat([m])}));
 auC.looks.splice(i,1,...nl);return nl.length;}
async function auAskSplit(i){const l=auC.looks[i],cl=auClash(l);if(!cl.length)return;const[pg,many]=cl.sort((a,b)=>b[1].length-a[1].length)[0];
 if(!await ask('Make each one its own look?','<b>'+esc(pg)+'</b> plays one button at a time in ShowXpress, so <b>'+many.length+'</b> of them in one look can&rsquo;t play together &mdash; only the last would stay on.<br><br>Split it into <b>'+many.length+' looks</b> ('+esc(many.join(', '))+')'+(l.titles.length>many.length?', each keeping the other buttons of this look':'')+', so the Auto Show cycles through them?','Split into '+many.length+' looks'))return;
 const n=auSplit(i);auMsg('&#10003; Split into '+n+' looks of '+l.bars+' bars. Save to keep it.');auLooks();auPlay();updAuto();}
function fmtS(s){s=Math.max(0,Math.round(s));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0');}
function auMsg(h){$('aumsg').innerHTML=h||'';}
function renderAuto(){if(!AU)return;
 if(showErr('auerr',AU)){['aulooks','auplay'].forEach(i=>$(i).innerHTML='');$('ausum').textContent='';updAuto();return;}
 const rb=$('aurem');
 if(!AU.ready){rb.style.display='block';rb.innerHTML='The ShowXpress remote is off, so the Auto Show can&rsquo;t press anything yet. <button class="mini primary" id="auen" style="margin-left:8px">Turn on remote control</button>';$('auen').onclick=()=>remEnable(loadAuto);}
 else rb.style.display='none';
 document.querySelectorAll('[data-ao]').forEach(b=>b.classList.toggle('on',b.dataset.ao===auC.order));$('austop').value=auC.stop;$('auclean').checked=!!auC.clean;
 auLooks();auPlay();$('foot').textContent='Show: '+AU.show+' · Auto Show settings are kept in the show folder (auto_show.json)';updAuto();}
function auLooks(){const L=auC.looks,run=!!(AUS&&AUS.running);
 const act=L.filter(l=>l.on&&l.titles.length);
 $('ausum').innerHTML=L.length?'<b>'+act.length+'</b> of '+L.length+' look'+(L.length>1?'s':'')+' in the show &middot; one round &asymp; <b>'+fmtS(act.reduce((a,l)=>a+auSec(l),0))+'</b> at '+auC.bpm+' BPM':'';
 if(!L.length){$('aulooks').innerHTML='<p class="sub" style="margin:12px 0 0">No looks yet. A look is what plays at the same time &mdash; e.g. one movement + a colour + the uplights. To cycle through movements, make one look per movement. Build one in ShowXpress, then press <b>New look from what&rsquo;s playing</b> &mdash; or press <b>+ New look</b> and pick the buttons.</p>';return;}
 $('aulooks').innerHTML=L.map((l,i)=>{const cur=run&&AUS.lookId===l.id,bars=AUBARS.includes(l.bars)?AUBARS:[...AUBARS,l.bars].sort((a,b)=>a-b);
  const chips=l.titles.map((x,j)=>{const b=auBtn(x),bad=!b?'Not in the show (renamed or deleted?)':!b.reach?'Its page can’t be reached by the remote - turn the remote on again':'';
   return '<span class="auchip'+(bad?' bad':'')+'" title="'+esc(bad||b.page)+'">'+esc(x)+'<button data-ad="'+i+'" data-j="'+j+'" title="Take it out of this look">&#10005;</button></span>';}).join('');
  return '<div class="aulook'+(l.on?'':' off')+(cur?' cur':'')+'"><div class="row"><span class="aun">'+(i+1)+'</span><input class="srch" data-ln="'+i+'" value="'+esc(l.name)+'" maxlength="40" style="width:190px">'+
   '<select data-lb="'+i+'" style="width:auto">'+bars.map(b=>'<option value="'+b+'"'+(b===l.bars?' selected':'')+'>'+b+' bar'+(b>1?'s':'')+'</option>').join('')+'</select><span class="sub" style="margin:0" data-ls="'+i+'">&asymp; '+fmtS(auSec(l))+'</span><div class="grow"></div>'+
   '<label class="link"><input type="checkbox" data-lo="'+i+'"'+(l.on?' checked':'')+'> In the show</label>'+
   '<button class="mini" data-la="try" data-i="'+i+'"'+(l.titles.length?'':' disabled')+'>&#9654; '+(run?'Play now':'Try')+'</button><button class="mini" data-la="up" data-i="'+i+'"'+(i?'':' disabled')+' title="Move up">&uarr;</button><button class="mini" data-la="down" data-i="'+i+'"'+(i<L.length-1?'':' disabled')+' title="Move down">&darr;</button><button class="mini" data-la="copy" data-i="'+i+'">Copy</button><button class="mini" data-la="del" data-i="'+i+'">Delete</button></div>'+
   (auClash(l).length?'<div class="row" style="margin-top:8px;color:var(--amber);font-size:13px"><div class="grow">&#9888; '+auClash(l).map(c=>'<b>'+esc(c[0])+'</b> plays one button at a time &mdash; only <b>'+esc(c[1][c[1].length-1])+'</b> of these '+c[1].length+' would play.').join(' ')+'</div><button class="mini primary" data-la="split" data-i="'+i+'">Split into one look each</button></div>':'')+
   '<div class="auchips">'+(chips||'<span class="none">No buttons yet &mdash;</span>')+'<button class="mini" data-la="add" data-i="'+i+'">+ Button</button><button class="mini" data-la="grab" data-i="'+i+'" title="Use the buttons playing in ShowXpress now">&#8681; What&rsquo;s playing</button></div></div>';}).join('');
 const q=s=>$('aulooks').querySelectorAll(s);
 q('[data-ln]').forEach(e=>e.oninput=()=>{auC.looks[+e.dataset.ln].name=e.value;updAuto();});
 q('[data-lb]').forEach(e=>e.onchange=()=>{auC.looks[+e.dataset.lb].bars=+e.value;auLooks();updAuto();});
 q('[data-lo]').forEach(e=>e.onchange=()=>{auC.looks[+e.dataset.lo].on=e.checked;auLooks();auPlay();updAuto();});
 q('[data-ad]').forEach(e=>e.onclick=()=>{auC.looks[+e.dataset.ad].titles.splice(+e.dataset.j,1);auLooks();updAuto();});
 q('[data-la]').forEach(e=>e.onclick=()=>auLookAct(e.dataset.la,+e.dataset.i));}
async function auGrab(){const r=await remGet('/api/remote');
 if(!r.connected){auMsg('<span style="color:var(--amber)">'+esc(!r.ready&&r.setup?'The ShowXpress remote is off.':r.error||'ShowXpress isn’t answering.')+'</span>');return null;}
 const ts=[...new Set((r.pressed||[]).filter(p=>!isSetup(p.page)).map(p=>p.title))];
 if(!ts.length){auMsg('<span style="color:var(--amber)">Nothing is playing in ShowXpress (SETUP page buttons don&rsquo;t count). Press the buttons for the look there first.</span>');return null;}
 auMsg('');return ts.slice(0,24);}
async function auLookAct(k,i){const L=auC.looks,l=L[i];
 if(k==='up'&&i>0){[L[i-1],L[i]]=[L[i],L[i-1]];}
 else if(k==='down'&&i<L.length-1){[L[i+1],L[i]]=[L[i],L[i+1]];}
 else if(k==='copy'){const c=clone(l);c.id=rid();c.name=(l.name+' copy').slice(0,40);L.splice(i+1,0,c);}
 else if(k==='del'){if(!await ask('Delete '+l.name+'?','The look is taken out of the Auto Show (nothing in ShowXpress changes). Undo changes brings it back until you save.','Delete'))return;L.splice(i,1);}
 else if(k==='add'){auPick(i);return;}
 else if(k==='split'){await auAskSplit(i);return;}
 else if(k==='grab'){const ts=await auGrab();if(!ts)return;l.titles=ts;auMsg('&#10003; <b>'+esc(l.name)+'</b> now uses what&rsquo;s playing: '+esc(ts.join(', ')));}
 else if(k==='try'){await auTry(l);return;}
 auLooks();auPlay();updAuto();}
async function auTry(l){
 if(AUS&&AUS.running){if(auDirty()&&!(await auSave(true)))return;const r=await remGet('/api/auto/cmd',{cmd:'go',v:l.id});if(r.status){AUS=r.status;auPlay();auLooks();}if(!r.ok)auMsg('<span style="color:var(--red)">'+esc(r.error)+'</span>');return;}
 const r=await remGet('/api/remote/press',{titles:l.titles,release:auTried.filter(x=>!l.titles.includes(x))});
 if(!r.connected){auMsg('<span style="color:var(--amber)">'+esc(!r.ready&&r.setup?'The ShowXpress remote is off.':r.error||'ShowXpress isn’t answering.')+'</span>');return;}
 auTried=l.titles.slice();auMsg('&#9654; Trying <b>'+esc(l.name)+'</b> in ShowXpress'+((r.missing||[]).length?' &mdash; <span style="color:var(--red)">not in the show: '+esc(r.missing.join(', '))+'</span>':'')+'. Press Try on another look to switch.');}
function auPick(i){auPk=i;$('aupkt').textContent='Buttons in '+auC.looks[i].name;$('aupks').value='';auPickDraw();$('aupk').style.display='flex';setTimeout(()=>$('aupks').focus(),50);}
function auPickDraw(){const l=auC.looks[auPk],q=$('aupks').value.trim().toLowerCase(),on=new Set(l.titles),pages=[];
 for(const b of AU.buttons){if(isSetup(b.page))continue;if(q&&!b.title.toLowerCase().includes(q)&&!b.page.toLowerCase().includes(q))continue;let g=pages.find(x=>x.p===b.page);if(!g){g={p:b.page,bs:[]};pages.push(g);}g.bs.push(b);}
 $('aupkl').innerHTML=pages.length?pages.map(g=>'<h4>'+esc(g.p)+(g.bs[0].swap?' &middot; one at a time':'')+'</h4><div class="pks">'+g.bs.map(b=>{const no=b.dup?'Same name as another button - ShowXpress can only press the first one. Rename one in ShowXpress.':!b.reach?'This page can’t be reached by the remote yet':'';
  return '<span class="pkb'+(on.has(b.title)&&!b.dup?' on':'')+(no?' no':'')+'"'+(no?' title="'+esc(no)+'"':' data-pk2="'+esc(b.title)+'"')+'>'+esc(b.title)+'</span>';}).join('')+'</div>').join(''):'<p class="sub">No button matches.</p>';
 $('aupkl').querySelectorAll('[data-pk2]').forEach(e=>e.onclick=()=>{const x=e.dataset.pk2,ts=l.titles,j=ts.indexOf(x);if(j>=0)ts.splice(j,1);else if(ts.length<24)ts.push(x);e.classList.toggle('on',ts.includes(x));});}
$('aupks').oninput=auPickDraw;$('aupkd').onclick=async()=>{$('aupk').style.display='none';auLooks();auPlay();updAuto();if(auPk>=0&&auC.looks[auPk])await auAskSplit(auPk);};
$('aunew').onclick=()=>{if(!auC)return;auC.looks.push({id:rid(),name:'Look '+(auC.looks.length+1),bars:16,on:true,titles:[]});auLooks();updAuto();auPick(auC.looks.length-1);};
$('augrab').onclick=async()=>{if(!auC)return;const ts=await auGrab();if(!ts)return;auC.looks.push({id:rid(),name:'Look '+(auC.looks.length+1),bars:16,on:true,titles:ts});auLooks();auPlay();updAuto();
 auMsg('&#10003; New look <b>Look '+auC.looks.length+'</b>: '+esc(ts.join(', '))+'. Give it a name and save.');};
document.querySelectorAll('[data-ao]').forEach(b=>b.onclick=()=>{if(!auC)return;auC.order=b.dataset.ao;document.querySelectorAll('[data-ao]').forEach(x=>x.classList.toggle('on',x===b));updAuto();});
$('austop').onchange=e=>{if(auC){auC.stop=e.target.value;updAuto();}};$('auclean').onchange=e=>{if(auC){auC.clean=e.target.checked;updAuto();}};
function auSetBpm(v,live){v=Math.round(Math.max(40,Math.min(220,+v||124))*10)/10;auC.bpm=v;const e=$('aubpm');if(e&&document.activeElement!==e)e.value=v;auLooks();updAuto();
 if(live&&AUS&&AUS.running){clearTimeout(auBpmT);auBpmT=setTimeout(async()=>{const r=await remGet('/api/auto/cmd',{cmd:'bpm',v:String(v)});if(r.status)AUS=r.status;},350);}}
function auTap(){const n=Date.now();if(auTaps.length&&n-auTaps[auTaps.length-1]>2000)auTaps=[];auTaps.push(n);if(auTaps.length>9)auTaps.shift();
 if(auTaps.length>=3){const d=(auTaps[auTaps.length-1]-auTaps[0])/(auTaps.length-1);auSetBpm(Math.round(60000/d),true);}
 const b=$('autap');if(b)b.textContent='Tap'+(auTaps.length<3?' ('+(3-auTaps.length)+' more)':' ✓');}
function auPlay(){const el=$('auplay');if(!AU||!AU.ok||!auC){el.innerHTML='';return;}const s=AUS,run=!!(s&&s.running);el.className='auplay'+(run?' on':'');
 const act=auC.looks.filter(l=>l.on&&l.titles.length);
 const bpm='<span class="sub" style="margin:0">BPM</span><input id="aubpm" class="num" type="number" min="40" max="220" step="1" value="'+auC.bpm+'"><button class="mini" id="autap" title="Tap along with the beat (3 taps or more)">Tap</button>';
 if(!run){el.innerHTML='<div class="row"><div class="grow"><div class="aubig">Not playing</div><div class="sub" style="margin:2px 0 0">'+(act.length?act.length+' look'+(act.length>1?'s':'')+' ready &middot; '+(auC.order==='shuffle'?'shuffled':'in order'):'Add a look below to start.')+'</div>'+
   (s&&s.error?'<div style="color:var(--red);margin-top:4px">'+esc(s.error)+'</div>':'')+'</div>'+bpm+
   (act.length?'<select id="aufirst" style="width:auto">'+act.map(l=>'<option value="'+l.id+'">Start with '+esc(l.name)+'</option>').join('')+'</select>':'')+
   '<button class="primary" id="austart"'+(act.length&&AU.ready?'':' disabled')+'>&#9654; Start Auto Show</button></div>';
  $('austart').onclick=auStart;}
 else{el.innerHTML='<div class="row"><div class="grow"><div class="sub" style="margin:0;letter-spacing:1px;font-size:11.5px">NOW PLAYING</div><div class="aubig" id="auname"></div><div class="sub" id="aunext" style="margin:2px 0 0"></div><div id="auwarn" style="color:var(--amber);font-size:13px"></div></div><div class="aubeats" id="aubeats"><i></i><i></i><i></i><i></i></div></div>'+
   '<div class="auprog"><i id="aupr"></i></div><div class="row"><button id="auprev" title="The look before">&#9198; Back</button><button id="aunextb" class="primary" style="padding:9px 18px;font-size:14px">&#9197; Next look</button><button id="auhold"></button><button id="ausync" title="Press on the first beat of a bar: the bar count starts again from here">Bar 1 now</button><div class="grow"></div>'+bpm+'<button id="austopb">&#9632; Stop</button></div>';
  const c=(id,cmd)=>$(id).onclick=async()=>{const r=await remGet('/api/auto/cmd',{cmd:typeof cmd==='function'?cmd():cmd});if(r.status){AUS=r.status;auDraw();auLooks();}if(!r.ok)auMsg('<span style="color:var(--red)">'+esc(r.error)+'</span>');};
  c('auprev','prev');c('aunextb','next');c('ausync','sync');c('auhold',()=>AUS&&AUS.held?'resume':'hold');
  $('austopb').onclick=async()=>{busy(true,'Stopping the Auto Show…');const r=await remGet('/api/auto/stop',{});busy(false);AUS=r.status||null;if(AUS)AUS.error='';auPlay();auLooks();auPill();};}
 $('aubpm').onchange=e=>auSetBpm(e.target.value,true);$('autap').onclick=auTap;auDraw();}
function auDraw(){const s=AUS;if(!s||!s.running||!$('auname'))return;
 const beatMs=60000/s.bpm,tot=s.bars*4*beatMs,dt=Math.max(0,Date.now()-(Date.parse(s.at)||Date.now()));
 const left=s.held?null:Math.max(0,s.msLeft-dt),el=left===null?null:tot-left;
 const bar=el===null?s.bar:Math.min(s.bars,Math.floor(el/(beatMs*4))+1),beat=el===null?s.beat:Math.floor(el/beatMs)%4+1;
 $('auname').innerHTML=esc(s.name||'')+(s.held?'<small>HELD</small>':'');
 $('aunext').innerHTML='bar <b>'+bar+'</b> of '+s.bars+' &middot; '+(s.held?'held &mdash; stays on this look until you resume':'next: <b>'+esc(s.next||s.name)+'</b> in '+fmtS(left/1000));
 $('aupr').style.width=(el===null?(s.bar-1)/s.bars*100:Math.min(100,el/tot*100))+'%';
 $('aubeats').querySelectorAll('i').forEach((x,k)=>{x.className=k<beat?'on'+(k===0?' one':''):'';});
 $('auwarn').textContent=s.error||((s.missing||[]).length?'Not in the show: '+s.missing.join(', '):'');
 $('auhold').innerHTML=s.held?'&#9654; Resume':'&#9208; Hold';
 if(s.lookId!==auLastId){auLastId=s.lookId;auLooks();}}
async function auSave(quiet){busy(true,'Saving the Auto Show…');let r;try{r=await api('/api/auto/save',{config:auC});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 if(r.ok&&r.config){AU.config=r.config;auC=clone(r.config);renderAuto();}
 if(!quiet||!r.ok)showResult(r,'auto');return r.ok;}
async function auStart(){if(auDirty()&&!(await auSave(true)))return;busy(true,'Starting the Auto Show…');const f=$('aufirst');
 let r;try{r=await api('/api/auto/start',{look:f?f.value:''});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 AUS=r.status||null;if(!r.ok){showResult(r,'sx');$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> The Auto Show didn&rsquo;t start';}auTried=[];auPlay();auLooks();auPill();}
function updAuto(){const ok=!!(AU&&AU.ok),d=auDirty();$('ausave').disabled=!ok||!d;$('auundo').disabled=!ok||!d;if(ok)stateTag('austate',d);
 $('auhint').innerHTML=!ok?'':d?'Not saved yet'+(AUS&&AUS.running?' &mdash; the Auto Show picks the changes up when you save':'')+'.':'Saved. Starting, stopping and BPM taps work any time &mdash; ShowXpress stays open.';}
function auPill(){const b=$('aupill'),on=!!(AUS&&AUS.running);b.style.display=on?'':'none';if(on)b.innerHTML='&#9679; AUTO &middot; '+esc(AUS.name||'');}
$('aupill').onclick=()=>setTab('auto');
$('ausave').onclick=()=>auSave(false);$('auundo').onclick=()=>{auC=clone(AU.config);renderAuto();};
setInterval(async()=>{if(curTab()!=='auto'||!AUS||!AUS.running)return;auDraw();
 if(!auStF&&Date.now()%1000<260){auStF=true;try{const r=await api('/api/auto/status');AUS=r.status;if(!AUS||!AUS.running){auPlay();auLooks();}auPill();}catch(e){}auStF=false;}},250);

// ---------------- Tonight's Color (color.ps1)
const CPRE=[['Red','ff0000'],['Wine','8b0a2a'],['Rose','ff2a6d'],['Blush','f4a6b8'],['Hot pink','ff3fa4'],['Magenta','ff00ff'],['Purple','8a2be2'],['Lavender','b48cff'],['Royal blue','1f3fff'],['Navy','0a1a6e'],['Sky blue','6ec8ff'],
 ['Teal','00a8a8'],['Mint','7dffc4'],['Emerald','00b050'],['Lime','9aff00'],['Gold','ffb000'],['Yellow','ffee00'],['Peach','ffb38a'],['Orange','ff6a00'],['Warm white','ffd9a8'],['Cold white','e6f2ff']];
let CL=null,clHex='',clV=100,clDrag=false;
function hsv2hex(h,s,v){const f=n=>{const k=(n+h/60)%6;return v-v*s*Math.max(0,Math.min(k,4-k,1));};return [f(5),f(3),f(1)].map(x=>Math.round(x*255).toString(16).padStart(2,'0')).join('');}
function hex2hsv(hx){const r=parseInt(hx.slice(0,2),16)/255,g=parseInt(hx.slice(2,4),16)/255,b=parseInt(hx.slice(4,6),16)/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn;let h=0;
 if(d){h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h=(h*60+360)%360;}return [h,mx?d/mx:0,mx];}
function nearest(w,hx){let c=[0,2,4].map(i=>parseInt(hx.substr(i,2),16));const mx=Math.max(1,...c);c=c.map(x=>x*255/mx);let best=null,bd=1e12;  // same rule as color.ps1
 for(const e of w||[]){const r=[0,2,4].map(i=>parseInt(e.hex.substr(i,2),16)),d=.3*(c[0]-r[0])**2+.59*(c[1]-r[1])**2+.11*(c[2]-r[2])**2;if(d<bd){bd=d;best=e;}}return best;}
function clDirty(){return !!(CL&&CL.ok&&clHex&&(clHex!==CL.hex||$('clname').value.trim()!==(CL.name||'')));}
async function loadColor(){CL=await getJ('/api/color');if(CL.ok){clHex=CL.hex||'';$('clname').value=CL.name||'';clV=clHex?Math.max(10,Math.round(hex2hsv(clHex)[2]*100)):100;}renderColor();}
function setColor(hx,name){clHex=hx.toLowerCase();if(name!==undefined)$('clname').value=name;clV=Math.max(10,Math.round(hex2hsv(clHex)[2]*100));renderColor();}
function renderColor(){if(!CL)return;if(showErr('clerr',CL)){$('clstate').style.display='none';updColor();return;}
 $('clpal').innerHTML=CPRE.map(([n,h])=>`<div class="cp${h===clHex?' cur':''}" data-ch="${h}" data-cn="${esc(n)}"><i style="background:#${h}"></i>${esc(n)}</div>`).join('');
 document.querySelectorAll('[data-ch]').forEach(e=>e.onclick=()=>setColor(e.dataset.ch,e.dataset.cn));
 const k=$('clknob');if(clHex){const [h,s]=hex2hsv(clHex),a=h*Math.PI/180;k.style.display='block';k.style.left=(100+Math.sin(a)*s*100)+'px';k.style.top=(100-Math.cos(a)*s*100)+'px';k.style.background='#'+clHex;}else k.style.display='none';
 $('clval').value=clV;$('clwheel').style.filter='brightness('+Math.max(.25,clV/100)+')';
 if(document.activeElement!==$('clhex'))$('clhex').value=clHex?'#'+clHex:'';$('clpick').value='#'+(clHex||'ffffff');
 const big=$('clbig');big.style.background=clHex?'#'+clHex:'repeating-linear-gradient(45deg,#1d212a 0 10px,#171a21 10px 20px)';big.innerHTML='<span>'+(clHex?'#'+clHex:'pick a colour')+'</span>';
 const n1=clHex&&nearest(CL.wheel140,clHex),n2=clHex&&nearest(CL.wheel251,clHex),sw=e=>e?`<span class="sw" style="background:#${e.hex}"></span>${esc(e.name)}`:'&mdash;',wa=CL.washes||[];
 $('clmap').innerHTML=`<span>140 movers</span><b>${sw(n1)}</b><span>251 movers</span><b>${sw(n2)}</b><span>Uplights</span><b>${clHex?'<span class="sw" style="background:#'+clHex+'"></span>exact colour':'&mdash;'}${wa.length?'<br><small style="color:var(--dim)">'+esc(wa.join(', '))+'</small>':' &middot; <span style="color:var(--amber)">none found</span>'}</b>`+
  (CL.hex?`<span>Saved</span><b><span class="sw" style="background:#${CL.hex}"></span>#${CL.hex}${CL.name?' '+esc(CL.name):''}${CL.saved?' &middot; '+fmtT(CL.saved):''}</b>`:'');
 stateTag('clstate',clDirty());if(!CL.hex&&!clHex)$('clstate').style.display='none';$('foot').textContent='Show: '+CL.show;updColor();}
function updColor(){const ok=!!(CL&&CL.ok),d=clDirty();$('clsave').disabled=!ok||!d;$('clundo').disabled=!ok||!d;
 const miss=ok?(CL.buttons||[]).filter(b=>!b.there).map(b=>b.page):[];
 $('clhint').innerHTML=!ok?'':sxHint('save')??(!clHex?'Pick a colour.':d?'Writes the two TONIGHTS COLOR scenes'+(miss.length?' and adds the button to the '+esc(miss.join(' and '))+' page'+(miss.length>1?'s':''):'')+'.':'This is tonight\'s colour already.');}
function wheelAt(e){const r=$('clwheel').getBoundingClientRect(),x=e.clientX-r.left-r.width/2,y=e.clientY-r.top-r.height/2,s=Math.min(1,Math.hypot(x,y)/(r.width/2)),h=(Math.atan2(x,-y)*180/Math.PI+360)%360;
 clHex=hsv2hex(h,s,clV/100);$('clname').value='';renderColor();}
$('clwheel').onpointerdown=e=>{if(!CL||!CL.ok)return;clDrag=true;$('clwheel').setPointerCapture(e.pointerId);wheelAt(e);};
$('clwheel').onpointermove=e=>{if(clDrag)wheelAt(e);};$('clwheel').onpointerup=()=>{clDrag=false;};
$('clval').oninput=e=>{clV=+e.target.value;if(clHex){const [h,s]=hex2hsv(clHex);clHex=hsv2hex(h,s,clV/100);}renderColor();};
$('clpick').oninput=e=>setColor(e.target.value.slice(1),'');
$('clhex').onchange=e=>{const v=e.target.value.trim().replace(/^#/,'');if(/^[0-9a-f]{6}$/i.test(v))setColor(v,'');else renderColor();};
$('clname').oninput=()=>{stateTag('clstate',clDirty());updColor();};
$('clrefresh').onclick=loadColor;$('clundo').onclick=()=>{clHex=CL.hex||'';$('clname').value=CL.name||'';renderColor();};
$('clsave').onclick=()=>saveTo('/api/color/apply',{hex:clHex,name:$('clname').value.trim()},'Saving tonight\'s color…',async()=>{await loadColor();H=null;},'color');

// ---------------- Home: Google Drive, ShowXpress launch / close, updates, brand
let G=null,UPD=0;
function fmtT(s){const d=new Date(s);if(isNaN(d))return esc(s);const t=d.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
 return d.toDateString()===new Date().toDateString()?'today at '+t:d.toLocaleDateString([],{weekday:'short',month:'short',day:'numeric'})+' '+t;}
async function loadGd(){G=await getJ('/api/gdrive');updGd();}
function updGd(){if(!G)return;
 $('gdsub').innerHTML=!G.ok?'<span style="color:var(--red)">'+esc(G.error)+'</span>':!G.found?'Google Drive isn&rsquo;t on this computer &mdash; install <b>Google Drive for desktop</b> and sign in.':
  'Copies the show to <b>'+esc(G.target)+'</b> &mdash; only new and changed files, nothing is deleted. '+(G.last?'Last sync: <b>'+fmtT(G.last)+'</b>.':'Not synced yet.');
 $('gdsync').disabled=!G.ok||!G.found;$('gdhint').innerHTML=G.ok&&G.found&&sxOpen?QH:'';}
async function gdSync(){await saveTo('/api/gdrive/sync',{},'Copying the show to Google Drive…',async()=>{await loadGd();if($('v-pre').classList.contains('on'))loadPre();},'gsync');}
$('gdsync').onclick=()=>gdSync();
async function sxLaunch(){busy(true,'Starting ShowXpress…');let r;try{r=await api('/api/sx/launch',{});}catch(e){r={ok:false,error:'Lost connection.'}}setTimeout(()=>busy(false),r.ok?3000:0);if(!r.ok)showResult(r,'sx');}
async function sxClose(){if(!await ask('Close ShowXpress?','ShowXpress is asked to close the normal way. If it asks whether to save the show, answer it in ShowXpress.','Close ShowXpress'))return;
 let r;try{r=await api('/api/sx/close',{});}catch(e){r={ok:false,error:'Lost connection.'}}if(!r.ok)showResult(r,'sx');}
$('sxgo').onclick=sxLaunch;$('sxstop').onclick=sxClose;
async function chkUpd(){const u=await getJ('/api/update');$('hver').textContent='Version '+(u.current||'?')+(u.ok?(u.newer?' · version '+u.latest+' is available':' · up to date'):'');
 if(u.ok&&u.newer){const b=$('upd');b.style.display='';b.className='mini primary';b.textContent='⬆ Update to '+u.latest;b.onclick=()=>doUpd(u);}}
async function doUpd(u){if(!await ask('Update to version '+esc(u.latest)+'?','Downloads it from GitHub and installs it. '+(u.mac?'The Helper closes and the Mac installer opens &mdash; follow it, and the Helper opens again when it&rsquo;s done.':'The Helper closes and opens again by itself in a few seconds.')+' Your show isn&rsquo;t touched.','Update'))return;
 busy(true,'Downloading the update…');let r;try{r=await api('/api/update/install',{});}catch(e){r={ok:false,error:'Lost connection.'}}
 if(r.ok&&r.restarting){UPD=1;busy(true,u.mac?'Opening the installer — follow it, the Helper opens again when it’s done…':'Installing the update — the Helper opens again by itself…');return;}busy(false);showResult(r,'update');}
{const bi=new Image();bi.onload=()=>{const b=$('brand');b.innerHTML='';bi.alt='XSV Productions';b.appendChild(bi);};bi.src='/brand.png?t='+T;}

// ---------------- LIVE AIM: the Helper drives the DMX interface itself (dmx_out.ps1) while ShowXpress is closed
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let LV=null;const LVB=10;   // 16-bit pan steps per mouse pixel at Normal speed (tilt gets more: same angle)
function lvFlip(id){try{return JSON.parse(localStorage.getItem('sxh_flip_'+id))||{x:false,y:false};}catch(e){return {x:false,y:false};}}
const lvCl=v=>Math.max(0,Math.min(65535,v));
function lvAimed(h){const w=LV.W[h.id];return w.tc||w.tk||!h.free;}
function lvCopies(h){const w=LV.W[h.id],p=h.partner&&LV.byId[h.partner];return !!(p&&!w.tc&&!w.tk&&h.free&&lvAimed(p));}
function lvCorner(h){const w=LV.W[h.id];return w.k||[lvCl(w.c[0]+h.dk[0]-h.home[0]),lvCl(w.c[1]+h.dk[1]-h.home[1])];}
function lvPos(h,st){if(lvCopies(h))return lvPos(LV.byId[h.partner],st);return st==='k'?lvCorner(h):LV.W[h.id].c;}
function lvLit(h){return h===LV.sel||(LV.all&&(!LV.towers||h.order<99||h.hung));}
// ---- output: only changed channels, one request at a time, at most ~30 a second
function lvPair(c,v,snap){v=Math.round(v);const k='p'+c;if(!snap&&LV.sent[k]===v)return;LV.sent[k]=v;const o=LV.pend.get(k);LV.pend.set(k,((snap||(o&&o[0]==='s'))?'s':'p')+':'+c+':'+(c+1)+':'+v);}
function lvByte(ch,v){const k='b'+ch;if(LV.sent[k]===v)return;LV.sent[k]=v;LV.pend.set(k,'b:'+ch+':'+v);}
function lvPush(snap){if(!LV)return;for(const h of LV.heads){const p=lvPos(h,LV.step),lit=lvLit(h);lvPair(h.addr,p[0],snap);lvPair(h.addr+2,p[1],snap);
 for(const [i,v] of h.look)lvByte(h.addr+i,(!lit&&(i===h.dimI||i===h.shutI))?0:v);}lvKick();}
function lvKick(){if(!LV||LV.tm||LV.fl)return;const d=30-(Date.now()-LV.last);if(d>0)LV.tm=setTimeout(()=>{if(LV){LV.tm=0;lvFlush();}},d);else lvFlush();}
async function lvFlush(){if(!LV||!LV.on||LV.gone||LV.fl)return;let l=((LV.z?'z ':'')+[...LV.pend.values()].join(' ')).trim();if(!l){if(!LV.ka)return;l='k';}
 const me=LV;LV.z=false;LV.ka=false;LV.pend.clear();LV.fl=true;LV.last=Date.now();let r;try{r=await api('/api/live/out',{l});}catch(e){r={ok:false,gone:true,error:'Lost connection to the Helper.'};}
 if(LV!==me||!LV.on)return;LV.fl=false;if(!r.ok){lvGone(r.error);return;}if(LV.pend.size)lvKick();}
function lvGone(msg){LV.gone=true;if(/^The DMX output stopped/.test(msg||''))msg='Unplugged, or the Helper lost it.';const g=$('lvgone');g.className='lvgone on';
 g.innerHTML='<b>&#9888; The DMX output stopped.</b><span>'+esc(msg||'')+' Your aims so far are kept.</span><div class="grow"></div><button id="lvre" class="mini primary">Reconnect</button>';$('lvre').onclick=lvReconnect;}
async function lvStart(mode){busy(true,'Connecting to the DMX interface…');let r;try{r=await api('/api/live/start',{mode});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);
 if(!r.ok&&r.nova&&await ask('NovaStar is using the DMX interface','The NovaStar LED-screen software (NovaLCT) has a USB scanner that grabs the DMX interface. Pause it while you aim? NovaLCT starts it again by itself &mdash; your LED screens are not touched.','Pause it and continue')){
  busy(true,'Pausing NovaStar and connecting…');try{r=await api('/api/live/start',{mode,stopNova:true});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);}
 return r;}
async function lvReconnect(){const r=await lvStart(LV.mode);
 if(!LV)return;if(!r.ok){lvGone(r.error);return;}LV.gone=false;LV.fl=false;$('lvgone').className='lvgone';lvIf(r);LV.sent={};LV.pend.clear();LV.z=true;lvPush(true);}
function lvIf(r){const t=$('lvif');t.className='tag '+(r.test?'red':'blue');t.textContent=r.test?'TEST - no real output':'Output: '+r.iface;}
// ---- moving
function lvTake(h){// a head that shows its T-bar partner's aim starts from there when you aim it yourself
 if(!lvCopies(h))return;const p=LV.byId[h.partner],w=LV.W[h.id],pw=LV.W[p.id];w.c=lvPos(p,'c').slice();w.k=pw.k?pw.k.slice():null;w.tc=true;}
function lvMove(dx,dy,sh,ct){if(!LV||!LV.sel||LV.gone)return;const h=LV.sel,w=LV.W[h.id],f=LV.flip,m=LV.spd*(sh?0.25:1)*(ct?4:1);
 const dp=dx*LVB*m*(f.x?-1:1),dt=-dy*LVB*m*(h.deg[0]/h.deg[1])*(f.y?-1:1);if(!dp&&!dt)return;
 lvTake(h);
 if(LV.step==='k'){if(!w.k)w.k=lvCorner(h).slice();w.k=[lvCl(w.k[0]+dp),lvCl(w.k[1]+dt)];w.tk=true;}
 else{w.c=[lvCl(w.c[0]+dp),lvCl(w.c[1]+dt)];w.tc=true;}
 lvPush(false);lvDirty();}
function lvDirty(){if(LV&&!LV.raf)LV.raf=requestAnimationFrame(lvSide);}
function lvNav(){return LV.order.filter(h=>h===LV.sel||(!lvCopies(h)&&(!LV.towers||h.order<99)));}
function lvSelect(h,quiet){if(!h)return;LV.sel=h;LV.flip=lvFlip(h.id);$('lvfx').checked=LV.flip.x;$('lvfy').checked=LV.flip.y;if(!quiet)lvPush(false);lvSide();
 const e=$('lvlist').querySelector('.lvh.on');if(e)e.scrollIntoView({block:'nearest'});}
function lvSetStep(s){LV.step=s;document.querySelectorAll('[data-st]').forEach(b=>b.classList.toggle('on',b.dataset.st===s));lvPush(false);lvDirty();}
function lvStepTo(dir){const n=lvNav(),j=n.indexOf(LV.sel)+dir;if(j>=0&&j<n.length){lvSelect(n[j]);return;}
 if(dir>0&&LV.step==='c'){LV.step='k';const m=LV.order.filter(h=>!lvCopies(h)&&(!LV.towers||h.order<99));lvSetStep('k');lvSelect(m[0]||LV.sel);}}
// ---- drawing
function lvList(){const g=[];let cur=null;
 for(const h of LV.order){const t=h.order<99?h.tower:(LV.towers?'Other heads (not on a truss)':'Heads');if(t!==cur){g.push('<h4>'+esc(t)+'</h4>');cur=t;}
  const w=LV.W[h.id],cp=lvCopies(h);
  const st=(w.tc||w.tk)?'<small class="a">aimed'+(w.tk?' + corner':'')+'</small>':cp?'<small class="cp">&#8644; '+esc(LV.byId[h.partner].label)+'</small>':!h.free?'<small class="b">aimed before</small>':'<small>normal</small>';
  g.push('<div class="lvh'+(h===LV.sel?' on':'')+(LV.towers&&h.order>=99?' dim':'')+'" data-lv="'+esc(h.id)+'"><span class="sd">'+esc(h.side||'')+'</span>'+esc(h.label)+st+'</div>');}
 $('lvlist').innerHTML=g.join('');$('lvlist').querySelectorAll('[data-lv]').forEach(e=>e.onclick=()=>lvSelect(LV.byId[e.dataset.lv]));}
function lvSide(){if(!LV)return;LV.raf=0;const h=LV.sel;if(!h)return;lvList();const w=LV.W[h.id],cp=lvCopies(h),st=LV.step,p=lvPos(h,st),pt=h.partner&&LV.byId[h.partner],room=LV.mode==='room';
 $('lvname').textContent=h.label+(h.tower?' · '+h.tower+(h.side?(h.side==='L'?' left':' right'):''):'');
 $('lvst').innerHTML=cp?'Not aimed &mdash; gets the same aim as <b>'+esc(pt.label)+'</b> next to it. Drag to aim it yourself.':(w.tc||w.tk)?'Aimed now'+(w.tk?' (center + corner)':' (center)'):!h.free?'Aimed before &mdash; drag to change it.':'Normal aim &mdash; drag to aim it.';
 $('lvbig').innerHTML=esc(h.label)+' &mdash; <span>'+(st==='k'?'CORNER':'CENTER')+'</span>';
 $('lvtip').innerHTML=(st==='k'?'Aim it at the front-left '+(room?'edge of the AROUND ROOM sweep':'corner of the floor (from the DJ)')+(w.tk||(h.kSet&&!cp)?'':' &mdash; <i>until you do, it follows the center</i>'):
  'Aim it at the '+(room?'middle of where AROUND ROOM should sweep':'center of tonight&rsquo;s dance floor'))+'<br><span style="font-size:12px;color:#5d6574">Hold the mouse button down here and drag</span>';
 const dg=(v,i)=>(v-h.home[i])*h.deg[i]/65536,f1=x=>(x>=0?'+':'&minus;')+Math.abs(x).toFixed(1)+'&deg;';
 $('lvread').innerHTML='<span>Pan</span><b>'+Math.round(p[0])+' &nbsp;<small>'+f1(dg(p[0],0))+' from normal</small></b><span>Tilt</span><b>'+Math.round(p[1])+' &nbsp;<small>'+f1(dg(p[1],1))+' from normal</small></b>';
 // minimap in degrees around the normal center, turned like the mouse moves
 const c=lvPos(h,'c'),k=lvPos(h,'k'),fx=LV.flip.x?-1:1,fy=LV.flip.y?-1:1,X=v=>dg(v,0)*fx,Y=v=>-dg(v,1)*fy;
 const bx=Math.abs(dg(h.dk[0],0)),by=Math.abs(dg(h.dk[1],1)),kx=Math.abs(X(k[0])-X(c[0])),ky=Math.abs(Y(k[1])-Y(c[1]));
 const R=Math.max(bx*2.2,by*2.2,10,Math.abs(X(c[0]))+kx+2,Math.abs(Y(c[1]))+ky+2,Math.abs(X(p[0]))+2,Math.abs(Y(p[1]))+2),sc=82/R,px=v=>(120+v*sc).toFixed(1),py=v=>(90+v*sc).toFixed(1);
 const rc=(x,y,hw,hh,a)=>'<rect x="'+px(x-hw)+'" y="'+py(y-hh)+'" width="'+(2*hw*sc).toFixed(1)+'" height="'+(2*hh*sc).toFixed(1)+'" '+a+'/>';
 $('lvmap').innerHTML='<line x1="120" y1="0" x2="120" y2="180" stroke="#1d212a"/><line x1="0" y1="90" x2="240" y2="90" stroke="#1d212a"/>'+
  rc(0,0,bx,by,'fill="none" stroke="#5d6574" stroke-dasharray="4 3" rx="3"')+rc(X(c[0]),Y(c[1]),kx,ky,'fill="rgba(255,176,32,.12)" stroke="#ffb020" stroke-width="1.5" rx="3"')+
  '<circle cx="'+px(X(c[0]))+'" cy="'+py(Y(c[1]))+'" r="4" fill="#ffb020"/><circle cx="'+px(X(k[0]))+'" cy="'+py(Y(k[1]))+'" r="4" fill="#5aa9ff"/>'+
  '<circle cx="'+px(X(p[0]))+'" cy="'+py(Y(p[1]))+'" r="8" fill="none" stroke="#fff" stroke-width="2"/>';
 const b=$('lvpart');b.style.display=pt?'':'none';if(pt)b.innerHTML='&#8644; Same as '+esc(pt.label)+' (next to it)';
 $('lvundo').disabled=JSON.stringify(w)===LV.I0[h.id];
 const n=lvNav(),i=n.indexOf(h),nx=$('lvnext');$('lvprev').disabled=i<=0;
 if(i<n.length-1){nx.disabled=false;nx.innerHTML='Next head &rarr;';}else if(st==='c'){nx.disabled=false;nx.innerHTML='Corners &rarr;';}else{nx.disabled=true;nx.innerHTML='Last head';}}
// ---- open / close
async function lvGo(){if(LV)return;let reo=false;
 if(sxOpen){if(!await ask('Close ShowXpress to aim live?','Only one program can use the DMX interface, so ShowXpress closes while you aim. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.<br><br>It opens again when you finish.','Close and aim live'))return;
  let r;try{r=await api('/api/sx/close',{live:true});}catch(e){r={ok:false,error:'Lost connection.'};}if(!r.ok){showResult(r,'live');return;}
  busy(true,'Waiting for ShowXpress to close… (save it if it asks)');const t0=Date.now();let open=true;
  while(Date.now()-t0<120000){await sleep(1000);try{open=(await api('/api/sx')).open;}catch(e){}if(!open)break;}
  if(open){busy(false);try{await api('/api/live/stop',{});}catch(e){}showResult({ok:false,error:'ShowXpress is still open. Close it (save if it asks), then press Aim live again.'},'live');return;}
  busy(true,'ShowXpress closed - waiting for it to let go of the interface…');await sleep(2500);reo=true;}
 const r=await lvStart(aimMode);
 if(!r.ok){try{await api('/api/live/stop',{});}catch(e){}if(reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'live');return;}
 lvOpen(r,reo);}
function lvOpen(r,reo){const I=r.info;
 LV={on:true,mode:aimMode,heads:I.heads,byId:{},W:{},I0:{},sent:{},pend:new Map(),z:true,ka:false,fl:false,tm:0,last:0,step:'c',all:false,spd:+(localStorage.getItem('sxh_lvspd')||1)||1,drag:false,raf:0,gone:false};
 for(const h of LV.heads){LV.byId[h.id]=h;const w={c:h.c.slice(),k:h.kSet?h.k.slice():null,tc:false,tk:false};LV.W[h.id]=w;LV.I0[h.id]=JSON.stringify(w);}
 LV.towers=LV.heads.some(h=>h.order<99);LV.order=LV.heads.slice().sort((a,b)=>a.order-b.order);
 $('lvmode').textContent=(LV.mode==='room'?'Room':'Dance floor')+' · '+I.aimTitle;lvIf(r);$('lvreo').checked=!!reo;$('lvall').checked=false;$('lvgone').className='lvgone';
 document.querySelectorAll('[data-sp]').forEach(b=>b.classList.toggle('on',+b.dataset.sp===LV.spd));document.querySelectorAll('[data-st]').forEach(b=>b.classList.toggle('on',b.dataset.st==='c'));
 $('live').classList.add('on');document.body.style.overflow='hidden';
 LV.kat=setInterval(()=>{if(LV&&LV.on&&Date.now()-LV.last>2000){LV.ka=true;lvKick();}},1000);
 lvSelect(LV.order.find(h=>!LV.towers||h.order<99)||LV.order[0],true);lvPush(true);}
function lvClose(){if(!LV)return;clearInterval(LV.kat);if(LV.tm)clearTimeout(LV.tm);LV.on=false;LV=null;$('live').classList.remove('on');document.body.style.overflow='';
 if(document.pointerLockElement)document.exitPointerLock();}
function lvEdits(){return LV.heads.some(h=>JSON.stringify(LV.W[h.id])!==LV.I0[h.id]);}
async function lvStop(reo){lvClose();busy(true,'Stopping the DMX output…');try{await api('/api/live/stop',{});}catch(e){}busy(false);if(reo)sxLaunch();}
function lvResult(r,mode){const reo=r.reopened?'<p class="sub" style="margin:8px 0 0">ShowXpress is opening again.</p>':r.reopenError?'<p style="color:var(--red)">ShowXpress didn&rsquo;t open: '+esc(r.reopenError)+'</p>':'';
 const at=mode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)';
 if(r.ok&&r.applied){showResult({ok:true,out:r.out},'apply');$('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> Live aims saved and applied';$('rbody').insertAdjacentHTML('beforeend',reo);return;}
 const box=$('result');box.className='card result err';$('rlog').textContent=r.out||'';
 if(r.ok){$('rtitle').innerHTML='<span style="color:var(--amber)">&#9888;</span> Aims saved, not applied yet';$('rbody').innerHTML='<p>The aims are saved in <b>'+at+'</b>, but applying them to the show didn&rsquo;t work: '+esc(r.applyError||'unknown error')+'</p><p class="sub">Check the heads above, then press <b>Apply to show</b>.</p>'+reo;}
 else{$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> Live aims not saved';$('rbody').innerHTML='<p>'+esc(r.error||'Unknown error.')+'</p><p class="sub">Nothing was changed.</p>'+reo;}
 box.scrollIntoView({behavior:'smooth'});}
$('lvgo').onclick=lvGo;
$('lvcancel').onclick=async()=>{if(!LV)return;if(lvEdits()&&!await ask('Stop without saving?','The aims you set here are not saved. The heads go dark and the show keeps the aims it had.','Stop without saving'))return;lvStop($('lvreo').checked);};
$('lvsave').onclick=async()=>{if(!LV)return;const aims={};let n=0;
 for(const h of LV.heads){const w=LV.W[h.id];if(!w.tc&&!w.tk)continue;aims[h.id]={c:w.c.map(Math.round),k:w.tk?(w.k?w.k.map(Math.round):h.dk.slice()):null};n++;}
 const reo=$('lvreo').checked,mode=LV.mode;
 if(!n){if(await ask('Nothing was aimed','No head was moved, so there is nothing to save. Stop live aim?','Stop'))lvStop(reo);return;}
 lvClose();busy(true,'Saving '+n+' aim'+(n>1?'s':'')+' and applying them to the show…');
 let r;try{r=await api('/api/live/save',{mode,aims,apply:true,w:clamp($('w').value),d:clamp($('d').value),force:false,reopen:reo});}catch(e){r={ok:false,error:'Lost connection.'};}
 busy(false);lvResult(r,mode);load();};
$('lvnext').onclick=()=>lvStepTo(1);$('lvprev').onclick=()=>lvStepTo(-1);
$('lvundo').onclick=()=>{const h=LV.sel;LV.W[h.id]=JSON.parse(LV.I0[h.id]);lvPush(false);lvDirty();};
$('lvhome').onclick=()=>{const h=LV.sel;if(h.free&&!h.kSet)LV.W[h.id]=JSON.parse(LV.I0[h.id]);else LV.W[h.id]={c:h.home.slice(),k:null,tc:true,tk:true};lvPush(false);lvDirty();};
$('lvpart').onclick=()=>{const h=LV.sel,p=LV.byId[h.partner];if(!p)return;const pw=LV.W[p.id];LV.W[h.id]={c:lvPos(p,'c').slice(),k:pw.k?pw.k.slice():null,tc:true,tk:!!pw.k};lvPush(false);lvDirty();};
$('lvall').onchange=e=>{LV.all=e.target.checked;lvPush(false);};
function lvSetFlip(){const h=LV.sel;LV.flip={x:$('lvfx').checked,y:$('lvfy').checked};localStorage.setItem('sxh_flip_'+h.id,JSON.stringify(LV.flip));
 if(h.partner&&localStorage.getItem('sxh_flip_'+h.partner)===null)localStorage.setItem('sxh_flip_'+h.partner,JSON.stringify(LV.flip));lvDirty();}
$('lvfx').onchange=lvSetFlip;$('lvfy').onchange=lvSetFlip;
document.querySelectorAll('[data-st]').forEach(b=>b.onclick=()=>lvSetStep(b.dataset.st));
document.querySelectorAll('[data-sp]').forEach(b=>b.onclick=()=>{LV.spd=+b.dataset.sp;localStorage.setItem('sxh_lvspd',b.dataset.sp);document.querySelectorAll('[data-sp]').forEach(x=>x.classList.toggle('on',x===b));});
{const pad=$('lvpad');
 pad.onmousedown=e=>{if(!LV||e.button!==0)return;e.preventDefault();LV.drag=true;pad.classList.add('drag');try{const pr=pad.requestPointerLock();if(pr&&pr.catch)pr.catch(()=>{});}catch(x){}};
 const end=()=>{if(!LV||!LV.drag)return;LV.drag=false;pad.classList.remove('drag');if(document.pointerLockElement)document.exitPointerLock();};
 document.addEventListener('mousemove',e=>{if(LV&&LV.drag)lvMove(e.movementX,e.movementY,e.shiftKey,e.ctrlKey);});
 document.addEventListener('mouseup',end);document.addEventListener('pointerlockchange',()=>{if(!document.pointerLockElement)end();});}
document.addEventListener('keydown',e=>{if(!LV||!LV.on||$('modal').style.display==='flex'||$('busy').style.display==='flex')return;
 const k=e.key,A={ArrowLeft:[-4,0],ArrowRight:[4,0],ArrowUp:[0,-4],ArrowDown:[0,4]}[k];
 if(A){e.preventDefault();lvMove(A[0],A[1],e.shiftKey,e.ctrlKey);return;}
 if(k==='Tab'){e.preventDefault();lvStepTo(e.shiftKey?-1:1);return;}
 if(e.ctrlKey||e.altKey)return;
 if(k==='n'||k==='N')lvStepTo(1);else if(k==='p'||k==='P')lvStepTo(-1);else if(k==='1')lvSetStep('c');else if(k==='2')lvSetStep('k');});
window.addEventListener('beforeunload',()=>{if(LV)navigator.sendBeacon('/api/live/stop?t='+T,'{}');});

setTab(location.hash.slice(1)||'home');draw();load();poll();loadGd();chkUpd();
</script></body></html>
'@

if (-not $NoBrowser) { Open-AppWindow $url }
$last = Get-Date
try {
  while ($l.IsListening) {
    $task = $l.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(1000)) {
      try { Step-Queue } catch {}
      try { Step-Pending } catch {}
      if (((Get-Date) - $last).TotalSeconds -gt $idleMax -and -not $queue.Count -and -not (Test-Auto)) { $l.Stop(); break }
    }
    if (-not $l.IsListening) { break }
    $ctx = $task.Result; $req = $ctx.Request
    try {
      if ($req.QueryString['t'] -ne $token) { Send-Text $ctx 403 'text/plain' 'Open ShowXpress Helper from its icon.'; continue }
      $last = Get-Date
      $path = $req.Url.AbsolutePath
      $body = $null
      if ($req.HttpMethod -eq 'POST') { $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); if ($raw) { $body = $raw | ConvertFrom-Json } }
      if ($req.HttpMethod -eq 'POST' -and $queueable.ContainsKey($path)) {
        # ShowXpress open + the page asked to queue -> do it when ShowXpress closes; else now
        if ($body -and $body.queue -and (Test-SxOpen)) { Send-Json $ctx (Add-Queue $path $body) } else { Send-Json $ctx (Invoke-Action $path $body) }
        continue
      }
      switch ($path) {
        '/'            { Send-Text $ctx 200 'text/html; charset=utf-8' ($html.Replace('__TOKEN__', $token)) }
        '/brand.png'   {
          $bp = @((Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ShowXpress Helper/brand.png'), (Join-Path $HOME 'AwaazTools/brand.png'), (Join-Path $here 'brand.png')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
          if ($bp) { Send-Png $ctx $bp } else { Send-Text $ctx 404 'text/plain' 'no brand image' }
        }
        '/icon.png'    { $ip = Join-Path $here 'aim_movers_1024.png'; if (-not (Test-Path $ip)) { $ip = Join-Path $here '../assets/aim_movers_1024.png' } if (Test-Path $ip) { $ib = [IO.File]::ReadAllBytes($ip); $ctx.Response.ContentType = 'image/png'; $ctx.Response.ContentLength64 = $ib.Length; $ctx.Response.OutputStream.Write($ib, 0, $ib.Length); $ctx.Response.Close() } else { Send-Text $ctx 404 'text/plain' 'no icon' } }
        '/api/sx'      { Send-Json $ctx @{ open = (Test-SxOpen); q = (Get-QueueInfo); live = (Test-Live); auto = (Get-AutoStatus); pend = [bool]$script:pend; rem = $script:remLast } }
        '/api/remote'  { Send-Json $ctx (Invoke-Remote 'State') }
        '/api/remote/press' {
          $ts = @($body.titles | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
          $rs = @($body.release | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
          if (-not $ts.Count -or $ts.Count -gt 30 -or $rs.Count -gt 30 -or @($ts + $rs | Where-Object { $_ -notmatch $titleRx }).Count) { Send-Json $ctx @{ ok = $false; error = 'Unknown button.' }; break }
          $fl = ''
          if ($body.solo) { $fl += '-Solo ' }
          if ($body.idle) { $fl += '-Idle ' }
          if ($rs.Count) { $fl += '-Release "' + ($rs -join '|') + '"' }
          Send-Json $ctx (Invoke-Remote 'Press' $ts $fl)
        }
        '/api/remote/off' { Send-Json $ctx (Invoke-Remote 'Off') }
        '/api/auto' {
          $r = Invoke-Engine '-Action AutoGet' $remoteEngine
          $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
          if (-not $j) { Send-Json $ctx @{ ok = $false; error = $(if ($r.error) { $r.error } else { 'Could not read the show.' }) }; break }
          $st = Get-AutoStatus; Send-Text $ctx 200 'application/json; charset=utf-8' ($j.Substring(0, $j.Length - 1) + ',"status":' + $(if ($st) { $st | ConvertTo-Json -Depth 4 -Compress } else { 'null' }) + '}')
        }
        '/api/auto/status' { Send-Json $ctx @{ ok = $true; status = (Get-AutoStatus) } }
        '/api/auto/save' {
          if (-not $body -or -not $body.config) { Send-Json $ctx @{ ok = $false; error = 'Nothing to save.'; out = '' }; break }
          $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
          [IO.File]::WriteAllText($cf, ($body.config | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
          try { $r = Invoke-Engine "-Action AutoSave -ConfigFile `"$cf`"" $remoteEngine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
          if ($r.ok) { [void](Send-Auto 'reload'); $j = ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1; if ($j) { $r.config = ($j | ConvertFrom-Json) } }
          Send-Json $ctx $r
        }
        '/api/auto/start' { Send-Json $ctx (Start-Auto "$($body.look)") }
        '/api/auto/stop'  { Stop-Auto; Start-Sleep -Milliseconds 100; Send-Json $ctx @{ ok = $true; status = (Get-AutoStatus) } }
        '/api/auto/cmd' {
          $c = "$($body.cmd)"; $v = "$($body.v)"
          if ($c -notin 'next', 'prev', 'hold', 'resume', 'sync', 'bpm', 'go' -or ($c -eq 'bpm' -and $v -notmatch '^\d{2,3}(\.\d)?$') -or ($c -eq 'go' -and $v -notmatch '^[0-9a-f]{8}$')) { Send-Json $ctx @{ ok = $false; error = 'Unknown command.' }; break }
          $ok = Send-Auto $(if ($c -eq 'bpm' -or $c -eq 'go') { "$c $v" } else { $c })
          Start-Sleep -Milliseconds 350
          Send-Json $ctx @{ ok = $ok; error = $(if ($ok) { '' } else { 'The Auto Show isn''t playing.' }); status = (Get-AutoStatus) }
        }
        '/api/live/start' {
          if (Test-SxOpen) { Send-Json $ctx @{ ok = $false; sxopen = $true; error = 'ShowXpress is open - it has to be closed while you aim live (only one program can use the DMX interface).'; out = '' }; break }
          $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }
          $r = Invoke-Engine "-Action LiveInfo$mo"
          $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
          if (-not $j) { Send-Json $ctx @{ ok = $false; error = $(if ($r.error) { $r.error } else { 'Could not read the show.' }); out = '' }; break }
          $script:liveHold = Get-Date
          # NovaStar NovaLCT (LED screens) has a USB scanner that grabs the D512S (found 2026-11-21). Paused only when the user says so.
          if ($body.stopNova -and -not $onMac) { Get-Process MarsServerProvider -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }
          $s = Start-Live
          if (-not $s.ok -and -not $onMac -and "$($s.error)" -like '*was not found*' -and (Get-Process MarsServerProvider -ErrorAction SilentlyContinue)) {
            $s.nova = $true; $s.error = 'The NovaStar LED-screen software (NovaLCT) is holding the DMX interface. Its USB scanner can be paused while you aim - NovaLCT starts it again by itself.'
          }
          if (-not $s.ok) { Send-Json $ctx $s; break }
          Send-Text $ctx 200 'application/json; charset=utf-8' ('{"ok":true,"iface":' + (ConvertTo-Json $s.iface -Compress) + ',"test":' + $(if ($TestRoot) { 'true' } else { 'false' }) + ',"info":' + $j + '}')
        }
        '/api/live/out' {
          $ln = "$($body.l)"
          if ($ln.Length -gt 60000 -or @($ln -split ' ' | Where-Object { $_ -and $_ -notmatch '^(z|k|b:\d{1,4}:\d{1,3}|[ps]:\d{1,4}:\d{1,4}:\d{1,5})$' }).Count) { Send-Json $ctx @{ ok = $false; error = 'Bad output command.' }; break }
          if (-not (Test-Live)) { Send-Json $ctx @{ ok = $false; gone = $true; error = 'The DMX output stopped.' }; break }
          try { $script:liveP.StandardInput.WriteLine($ln); Send-Json $ctx @{ ok = $true } } catch { Send-Json $ctx @{ ok = $false; gone = $true; error = 'The DMX output stopped.' } }
        }
        '/api/live/stop' { Stop-Live; $script:liveHold = [datetime]::MinValue; Send-Json $ctx @{ ok = $true } }
        '/api/live/save' {
          # stop the output, write the aims into the aim scene, Apply (size from the Aim tab), run anything queued, reopen ShowXpress
          Stop-Live
          $mo = if ("$($body.mode)" -eq 'room') { 'room' } else { 'floor' }
          $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
          [IO.File]::WriteAllText($cf, (@{ aims = $body.aims } | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
          try { $r = Invoke-Engine "-Action LiveSave$(if ($mo -eq 'room') { ' -Mode Room' }) -ChangesFile `"$cf`"" } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
          $res = @{ ok = $r.ok; saved = $r.ok; applied = $false; error = "$($r.error)"; out = "$($r.out)"; applyError = '' }
          if ($r.ok -and $body.apply) {
            $r2 = Invoke-Action '/api/apply' ([pscustomobject]@{ w = $body.w; d = $body.d; force = [bool]$body.force; mode = $mo })
            $res.out += "`n" + "$($r2.out)"; $res.applied = [bool]$r2.ok; $res.applyError = "$($r2.error)"
          }
          $script:liveHold = [datetime]::MinValue
          if ($queue.Count) { Invoke-QueueItems $false }
          if ($body.reopen) { $reo = try { Start-Sx } catch { @{ ok = $false; error = $_.Exception.Message } }; $res.reopened = [bool]$reo.ok; $res.reopenError = "$($reo.error)" }
          Send-Json $ctx $res
        }
        '/api/queue/cancel' { $k = "$($body.key)"; foreach ($o in @($queue | Where-Object { $_.key -eq $k -or $k -eq '*' })) { [void]$queue.Remove($o) }; Send-Json $ctx @{ ok = $true; q = (Get-QueueInfo) } }
        '/api/queue/reopen' { $script:qReopen = [bool]$body.on; Send-Json $ctx @{ ok = $true; q = (Get-QueueInfo) } }
        '/api/queue/seen'   { $script:qDone = $null; Send-Json $ctx @{ ok = $true } }
        '/api/sx/launch' { Send-Json $ctx (Start-Sx) }
        '/api/sx/close' {
          if ($body -and $body.live) { $script:liveHold = Get-Date }   # live aim asked: the queue must not reopen ShowXpress now
          $ps = @(Get-Process | Where-Object { $_.ProcessName -match 'TheLightingController|ShowXpress' })
          if ($onMac) { foreach ($p in $ps) { & osascript -e "quit app `"$($p.ProcessName)`"" 2>$null } } else { foreach ($p in $ps) { [void]$p.CloseMainWindow() } }
          Send-Json $ctx @{ ok = $true; out = '  ShowXpress was asked to close'; error = '' }
        }
        '/api/update'  { Send-Json $ctx (Get-Update) }
        '/api/update/install' {
          $u = Get-Update
          if (-not $u.ok -or -not $u.newer -or $u.asset -notmatch '^https://github\.com/') { Send-Json $ctx @{ ok = $false; error = 'No newer version found on GitHub.'; out = '' }; break }
          $dl = Join-Path ([IO.Path]::GetTempPath()) ($u.name -replace '[^\w\.-]', '_')
          try { Invoke-WebRequest -Uri $u.asset -OutFile $dl -UseBasicParsing -Headers @{ 'User-Agent' = 'ShowXpress-Helper' } -TimeoutSec 300 }
          catch { Send-Json $ctx @{ ok = $false; error = "Download failed: $($_.Exception.Message)"; out = '' }; break }
          if ($onMac) {
            # this server stops and the app quits (it sees the flag); a small script opens the installer, waits for it, then opens the new version
            $tmp = [IO.Path]::GetTempPath()
            $flag = Join-Path $tmp 'sxh_updating'; $us = Join-Path $tmp 'sxh_update.sh'
            [IO.File]::WriteAllText($flag, "$($u.latest)")
            [IO.File]::WriteAllText($us, "sleep 2`nopen -W '$dl'`nsleep 1`nrm -f '$flag'`nopen '/Applications/ShowXpress Helper.app'`n")
            & /bin/bash -c "nohup /bin/bash '$us' >/dev/null 2>&1 &"
            Send-Json $ctx @{ ok = $true; restarting = $true; out = ''; error = '' }
            $l.Stop(); break
          }
          # the installer closes this window server itself; a small script waits for it and opens the new version
          $us = Join-Path ([IO.Path]::GetTempPath()) 'sxh_update.ps1'
          $vbs = Join-Path $here 'showxpress_helper.vbs'
          [IO.File]::WriteAllText($us, "Start-Sleep 2`r`nStart-Process -Wait -FilePath '$dl' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART'`r`nStart-Process -FilePath `"`$env:SystemRoot\System32\wscript.exe`" -ArgumentList '`"$vbs`"'`r`n")
          Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$us`"" -WindowStyle Hidden
          Send-Json $ctx @{ ok = $true; restarting = $true; out = ''; error = '' }
          $l.Stop()
        }
        '/api/preview' {
          $mo = if ($req.QueryString['mode'] -eq 'room') { ' -Mode Room' } else { '' }
          Send-EngineJson $ctx (Invoke-Engine "-Action Preview$mo")
        }
        '/api/color'   { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $colorEngine) }
        '/api/gdrive'  { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $gdEngine) }
        '/api/pre/fix' {
          $k = "$($body.key)"
          if ($k -notmatch '^(sleep|usb|restart)$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Fix -FixId $k" $preEngine)
        }
        '/api/skip'    {
          $r = Invoke-Engine '-Action Preview' $skipEngine
          if ($r.ok) { $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1); Send-Text $ctx 200 'application/json; charset=utf-8' $j }
          else { Send-Json $ctx @{ ok = $false; error = $r.error } }
        }
        '/api/rig'     { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $rigEngine) }
        '/api/apc'     { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $apcEngine) }
        '/api/speed'   { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $speedEngine) }
        '/api/health'  { Send-EngineJson $ctx (Invoke-Engine '-Action Check' $healthEngine) }
        '/api/health/revert' {
          $i = "$($body.id)"
          if ($i -notmatch '^[0-9a-f]{8}$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          $r = Invoke-Engine "-Action Revert -FixId $i$(if ($body.force) { ' -Force' })" $healthEngine
          $cj = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{"conflict"' } | Select-Object -Last 1 }
          if ($cj) { Send-Json $ctx @{ ok = $true; conflict = @(($cj | ConvertFrom-Json).conflict); out = '' } } else { Send-Json $ctx $r }
        }
        '/api/health/keep' {
          $i = "$($body.id)"
          if ($i -notmatch '^[0-9a-f]{8}$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Keep -FixId $i" $healthEngine)
        }
        '/api/rt'      { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $rtEngine) }
        '/api/pre'     { Send-EngineJson $ctx (Invoke-Engine '-Action Check' $preEngine) }
        default        { Send-Text $ctx 404 'text/plain' 'not found' }
      }
    } catch {
      try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message; out = '' } } catch {}
    }
  }
} finally {
  Stop-Live
  Stop-Auto
  Remove-Item -LiteralPath $autoStat -ErrorAction SilentlyContinue
  try { $l.Close() } catch {}
  if (Test-Path $infoF) { try { $i = Get-Content $infoF -Raw | ConvertFrom-Json; if ($i.pid -eq $PID) { Remove-Item $infoF } } catch {} }
}
