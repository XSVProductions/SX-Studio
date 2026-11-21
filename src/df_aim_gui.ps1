# ShowXpress Helper (was AIM MOVERS) - small GUI (Windows PowerShell 5.1 + macOS pwsh 7).
# Runs a private web page on this computer only (localhost + random key) and opens it as an app window
# (Edge/Chrome "app" mode, else the normal browser). Each tab is backed by a script that does the work:
#   Tonight's Rig -> rig.ps1   Aim Movers -> df_aim.ps1       Skip Flash -> skip_flash.ps1
#   APC mini -> apc.ps1        Speed Faders -> speed.ps1      Health Check -> health.ps1 (check, fix, revert)
#   Rig Test -> rig_test.ps1   Pre-show Check -> preshow.ps1
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
$token = [guid]::NewGuid().ToString('N')
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
try { $l.Start() }
catch {
  if (Test-Path $infoF) { $i = Get-Content $infoF -Raw | ConvertFrom-Json; Open-AppWindow $i.url; return }
  throw "Port $Port is busy and no running ShowXpress Helper was found."
}
$url = "http://localhost:$Port/?t=$token"
[IO.File]::WriteAllText($infoF, (@{ url = $url; pid = $PID } | ConvertTo-Json))

function Test-SxOpen { [bool](Get-Process | Where-Object { $_.ProcessName -match 'TheLightingController|ShowXpress' }) }
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
.how{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}.how div{background:#12151b;border:1px solid var(--line);border-radius:10px;padding:10px 12px;font-size:13px;color:#c7cdd8}.how b{display:block;color:var(--amber);font-size:12px;letter-spacing:.6px;margin-bottom:2px}
.row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.grow{flex:1}
.group{margin-top:10px}.group h3{font-size:12px;letter-spacing:1px;color:var(--dim);margin:12px 0 8px;font-weight:600}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(118px,1fr));gap:8px}
.tile{background:#12151b;border:1px solid var(--line);border-radius:10px;padding:8px 10px;font-size:12.5px}
.tile .n{font-weight:650;font-size:13px;margin-bottom:3px}.tile .l{color:var(--dim)}.tile .v{color:var(--txt)}
.tile.moved{border-color:rgba(90,169,255,.45)}.tile.sized .sz{color:var(--amber)}.tile.warn{border-color:var(--red);background:rgba(255,92,92,.07)}.tile.warn .n::after{content:" !";color:var(--red)}
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
.dot.fl{animation:bl .5s steps(1) infinite}@keyframes bl{50%{opacity:.12}}
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
@media (max-width:860px){.clwrap{grid-template-columns:1fr}.htiles{grid-template-columns:1fr 1fr}}
@media (max-width:860px){.apcwrap{grid-template-columns:1fr}.sc{grid-template-columns:1fr}.sc .st{text-align:left}.sp{grid-template-columns:1fr 1fr}}
@media (max-width:760px){.how{grid-template-columns:1fr}.sizegrid{grid-template-columns:1fr}.heads{grid-template-columns:repeat(4,1fr)}}
</style></head><body>
<header><img class="logo" id="logo" src="/icon.png?t=__TOKEN__" alt="" style="cursor:pointer" title="Home"><h1 id="ttl" style="cursor:pointer" title="Home">ShowXpress Helper</h1>
  <nav class="tabs"><button data-tab="rt">Rig Test</button><button data-tab="rig">Tonight's Rig</button><button data-tab="aim">Aim Movers</button><button data-tab="skip">Skip Flash</button><button data-tab="color">Tonight's Color</button><button data-tab="apc">APC mini</button><button data-tab="speed">Speed Faders</button><button data-tab="health">Health Check</button><button data-tab="pre">Pre-show Check</button></nav>
  <div class="hright"><div id="sx" class="pill ok">Checking ShowXpress&hellip;</div><button id="sxgo" class="mini" style="display:none">&#9654; Launch ShowXpress</button><button id="sxstop" class="mini" style="display:none">&#9632; Close ShowXpress</button><button id="upd" class="mini primary" style="display:none"></button></div></header>
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
      <div><b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight's dancefloor.</div>
      <div><b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size.</div>
      <div><b>THEN</b>Save, close ShowXpress, press Refresh below and check the heads.</div>
    </div>
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
      <p class="sub" style="margin-bottom:0"><b>1.</b> In ShowXpress press <b>RIG ID</b> on the SETUP page &mdash; every 140 lights in its own look (key below). <b>2.</b> Tap each truss spot and pick the look you see on that head. <b>3.</b> Close ShowXpress (save first) and press <b>Save to 2D view</b>.</p></div>
      <span id="rtstate" class="state ok" style="display:none"></span><button id="rtrefresh">&#8635; Refresh</button></div>
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
  <div class="in" data-for="health"><button id="hlrun" class="primary">Check again</button><div class="hint grow" id="hlhint"></div></div></div>
<div class="modal" id="rtpick"><div class="box" style="max-width:540px"><h2 id="rtpt"></h2><p class="sub" style="margin:0 0 4px">Pick the look you see on this head.</p><div id="rtpb"></div><div class="row" style="justify-content:flex-end"><button id="rtpnone">Nothing hung here</button><button id="rtpcancel">Cancel</button></div></div></div>
<div class="modal" id="modal"><div class="box"><h2 id="mt"></h2><p id="mp"></p><div class="row" style="justify-content:flex-end"><button id="mno">Cancel</button><button id="myes" class="primary" style="padding:9px 18px;font-size:14px"></button></div></div></div>
<div class="busy" id="busy"><div class="spin"></div><span id="busyt">Working&hellip;</span></div>
<div class="gone" id="gone"><h2 style="color:var(--txt)">ShowXpress Helper has closed</h2><p>Open it again from its icon.</p></div>
<script>
const T='__TOKEN__';const $=id=>document.getElementById(id);
let P=null,sxOpen=false,linked=true;
async function api(p,body){const r=await fetch(p+(p.includes('?')?'&':'?')+'t='+T,body?{method:'POST',headers:{'Content-Type':'text/plain'},body:JSON.stringify(body)}:{});return r.json();}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function sign(v){return (v>0?'+':'')+v;}
function tile(h){const moved=h.op||h.ot,cls=['tile',moved?'moved':'',h.sized?'sized':'',h.warn?'warn':''].join(' ');
 return `<div class="${cls}" title="${esc(h.warn||'')}"><div class="n">${esc(h.label)}</div>
 <div><span class="l">center </span><span class="v">${moved?sign(h.op)+' / '+sign(h.ot):'normal'}</span></div>
 <div><span class="l">size </span><span class="v sz">${h.sized?h.kp+'% &times; '+h.kt+'%':'normal'}</span></div></div>`;}
function render(){if(!P)return;
 if(!P.ok){$('summary').innerHTML='<span style="color:var(--red)">'+esc(P.error)+'</span>';$('heads').innerHTML='';$('warnbox').style.display='none';updBar();return;}
 const hs=P.heads,a=hs.filter(h=>h.is140),b=hs.filter(h=>!h.is140),moved=hs.filter(h=>h.op||h.ot).length,sized=hs.filter(h=>h.sized).length,w=hs.filter(h=>h.warn);
 $('summary').innerHTML=`<b>${a.length}</b> &times; 140SR${b.length?` &middot; <b>${b.length}</b> &times; 251SR`:''} &nbsp;&mdash;&nbsp; <b>${moved}</b> re-aimed &middot; <b>${sized}</b> with a corner set`+(w.length?` &middot; <b style="color:var(--red)">${w.length} look wrong</b>`:'');
 $('heads').innerHTML=`<div class="group"><h3>140SR</h3><div class="tiles">${a.map(tile).join('')}</div></div>`+(b.length?`<div class="group"><h3>251SR</h3><div class="tiles">${b.map(tile).join('')}</div></div>`:'');
 const ins=P.install,ib=$('aiminst');
 if(aimMode==='room'&&ins&&(!ins.aim||!ins.check)){ib.style.display='block';ib.innerHTML='<b>ROOM AIM (ADJUST)</b> and <b>ROOM CHECK</b> aren&rsquo;t on the SETUP page yet. <button id="aiminstb" class="mini primary" style="margin-left:8px"'+(sxOpen?' disabled':'')+'>Add them to the SETUP page</button>';
  $('aiminstb').onclick=()=>saveTo('/api/aim/install',{},'Adding the ROOM buttons…',async()=>{LD.room=0;await load();},'roominstall');}else ib.style.display='none';
 const wb=$('warnbox');if(w.length){wb.style.display='block';wb.innerHTML='<b>Check these heads:</b> '+w.map(h=>esc(h.label)+' &ndash; '+esc(h.warn)).join('<br>');}else wb.style.display='none';
 $('foot').textContent='Show: '+P.show;updBar();}
function updBar(){const bad=!P||!P.ok;$('apply').disabled=sxOpen||bad;$('home').disabled=sxOpen||bad;
 $('hint').innerHTML=sxOpen?'<span style="color:var(--amber)">ShowXpress is open &mdash; close it (save first) to apply.</span>':(bad?'':(aimMode==='room'?'Writes to '+esc((P.targets||[]).filter(t=>!/CHECK/.test(t)).join(', ')||'AROUND ROOM'):'Writes to all dancefloor movement scenes')+' + CENTER SPOT (step 1 aims). Nothing is changed until you press Apply.');}
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
 const lines=(r.out||'').split(/\r?\n/);$('rlog').textContent=r.out||'';
 const SV=['skip','rig','apc','speed','fix','revert','keep','rt','install','color','gsync','prefix','roominstall','sx','update'];
 if(!r.ok){$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> '+(what==='gsync'?'Not copied':what==='sx'||what==='update'||what==='prefix'?'Didn&rsquo;t work':SV.includes(what)?'Not saved':'Not applied');$('rbody').innerHTML='<p>'+esc(r.error)+'</p><p class="sub">Nothing was changed.</p>';}
 else if(SV.includes(what)&&what!=='skip'){const same=lines.some(l=>/nothing to change/.test(l))&&!lines.some(l=>/SKIP FLASH now/.test(l));
  const ls=lines.filter(l=>/^ {2}\S/.test(l)).map(l=>l.trim()).filter(l=>!/^(same\s|live\.ini saved|nothing to change|2D view saved|RIGHEADS|SKIPHEADS)/.test(l)).map(l=>l.replace(/^CHANGED\s+/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(same?'Nothing needed changing':{rt:'Saved to the 2D view',install:'RIG ID added',rig:"Tonight's rig saved",apc:'APC pads saved',speed:'Speed faders saved',fix:'Fix applied',revert:'Fix reverted',keep:'Fix kept',color:"Tonight's color saved",gsync:'Copied to Google Drive',prefix:'Done',roominstall:'ROOM buttons added to the SETUP page',sx:'Done',update:'Installer opened'}[what]);
  const use=['rig','apc','speed','rt','install','color','roominstall'].includes(what),chk=['fix','revert'].includes(what);
  $('rbody').innerHTML=(ls.length?'<ul>'+ls.map(l=>'<li>'+esc(l)+'</li>').join('')+'</ul>':'')+(use||chk?'<p class="sub" style="margin:8px 0 0">Open ShowXpress to '+(use?'use':'check')+' it.</p>':'');}
 else if(what==='skip'){const same=lines.some(l=>/nothing to change/.test(l));const ls=lines.map(l=>l.trim()).filter(l=>/^(heads|loop):/.test(l));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(same?'SKIP FLASH already uses these heads':'Saved to SKIP FLASH');
  $('rbody').innerHTML='<ul>'+ls.map(l=>'<li>'+esc(l)+'</li>').join('')+'</ul><p class="sub" style="margin:8px 0 0">Open ShowXpress and press <b>SKIP FLASH</b> to check it.</p>';}
 else{const tot=lines.find(l=>/movement scenes checked/.test(l))||'';const ch=lines.filter(l=>/\s[1-9]\d* values changed/.test(l)).map(l=>l.trim().replace(/\s{2,}/g,' — '));
  const wr=lines.filter(l=>/WARNING/.test(l)).map(l=>l.replace(/^\s*WARNING:\s*/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(what==='home'?'Everything is back to normal':'Applied to the show');
  $('rbody').innerHTML='<p class="sub" style="margin:4px 0 0">'+esc(tot.replace(/^\s*->\s*/,''))+'. '+(what==='home'?'':aimMode==='room'?'Open ShowXpress and check <b>ROOM CHECK</b> &mdash; the beams should trace the edge you aimed.':'Open ShowXpress and check <b>DF CHECK 140</b> / <b>DF CHECK 251</b> &mdash; the beams should trace the floor corners.')+'</p>'+
   (ch.length?'<ul>'+ch.map(c=>'<li>'+esc(c)+'</li>').join('')+'</ul>':'')+(wr.length?'<div class="warnbox" style="display:block">'+wr.map(esc).join('<br>')+'</div>':'');}
 box.scrollIntoView({behavior:'smooth'});}
$('apply').onclick=async()=>{let force=false;const w=P.heads.filter(h=>h.warn);
 if(w.length){if(!await ask(w.length+' head(s) look wrong','Their aims in '+esc(aimT())+' look far off the floor &mdash; usually step 1 / step 2 not aimed yet.<br><br>Apply anyway?','Apply anyway'))return;force=true;}
 busy(true,'Applying to the show…');try{const r=await api('/api/apply',{w:+$('w').value,d:+$('d').value,force,mode:aimMode});showResult(r,'apply');}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load();};
$('home').onclick=async()=>{if(!await ask('Reset to normal?','All heads go back to the normal center, size 100%, and the '+esc(aimT())+' scene is reset. Your shapes are kept.','Reset'))return;
 busy(true,'Resetting…');try{const r=await api('/api/home',{mode:aimMode});showResult(r,'home');}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);LD[aimMode]=0;load();};
async function poll(){try{const r=await api('/api/sx');const was=sxOpen;sxOpen=r.open;const p=$('sx');p.className='pill '+(sxOpen?'bad':'ok');
 p.textContent=sxOpen?'ShowXpress open — close to apply':'ShowXpress closed ✓';$('sxgo').style.display=sxOpen?'none':'';$('sxstop').style.display=sxOpen?'':'none';
 updBar();updSkip();updRig();updApc();updSpeed();updHealth();updRt();updColor();updGd();updPre();const ib=$('aiminstb');if(ib)ib.disabled=sxOpen;
 if(was&&!sxOpen){load();if(S&&!dirty())loadSkip();if(R&&!rgDirty())loadRig();if(A&&!apDirty())loadApc();if(SP&&!spDirty())loadSpeed();if(H)loadHealth();if(RT&&!rtDirty())loadRt();if(CL&&!clDirty())loadColor();loadGd();}}
 catch(e){if(UPD){$('busyt').textContent='Update installed — this window can be closed.';return;}$('gone').style.display='flex';return;}setTimeout(poll,2000);}

// ---------------- tabs
const TABS=['home','rt','rig','aim','skip','color','apc','speed','health','pre'];
function setTab(t){if(!TABS.includes(t))t='home';window.scrollTo(0,0);
 document.querySelectorAll('.tabs button').forEach(b=>b.classList.toggle('on',b.dataset.tab===t));
 document.querySelectorAll('.view').forEach(v=>v.classList.toggle('on',v.id==='v-'+t));
 document.querySelectorAll('.bar .in').forEach(v=>v.classList.toggle('on',v.dataset.for===t));
 $('result').className='card result';if(t==='skip'&&!S)loadSkip();if(t==='rig'&&!R)loadRig();if(t==='apc'&&!A)loadApc();if(t==='speed'&&!SP)loadSpeed();if(t==='health'&&!H)loadHealth();if(t==='rt'&&!RT)loadRt();if(t==='pre')loadPre();if(t==='color'&&!CL)loadColor();if(t==='home')loadGd();}
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
function updSkip(){const ok=S&&S.ok,d=dirty(),n=sel.size;$('sksave').disabled=sxOpen||!ok||!d||n<2;$('skundo').disabled=!ok||!d;
 $('skhint').innerHTML=!ok?'':sxOpen?'<span style="color:var(--amber)">ShowXpress is open &mdash; close it (save first) to save.</span>':
  n<2?'<span style="color:var(--amber)">Pick at least 2 heads.</span>':d?'Only the SKIP FLASH scene is changed. Heads you turn off are taken out of it.':'SKIP FLASH already uses exactly these heads.';}
$('skrefresh').onclick=loadSkip;
$('skundo').onclick=()=>{sel=saved();renderSkip();};
$('sksave').onclick=async()=>{busy(true,'Saving SKIP FLASH…');let r;try{r=await api('/api/skip/apply',{heads:[...sel]});}catch(e){r={ok:false,error:'Lost connection.'}}
 busy(false);if(r.ok){await loadSkip();R=null;H=null;}showResult(r,'skip');};

// ---------------- shared bits for the newer tabs
function stateTag(id,d){const st=$(id);st.style.display='inline-block';st.className='state '+(d?'chg':'ok');st.textContent=d?'● Not saved yet':'✓ Matches the show';}
function sxHint(what){return sxOpen?'<span style="color:var(--amber)">ShowXpress is open &mdash; close it (save first) to '+what+'.</span>':null;}
async function getJ(p){try{return await api(p);}catch(e){return {ok:false,error:'Could not read the show.'};}}
async function saveTo(p,body,label,after,what){busy(true,label);let r;try{r=await api(p,body);}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);if(r.ok)await after();showResult(r,what);}
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
function updRig(){const ok=!!(R&&R.ok),d=rgDirty(),n=rsel.size;$('rgsave').disabled=sxOpen||!ok||!d||!n;$('rgundo').disabled=!ok||!d;$('rgall').disabled=!ok||R.heads.every(h=>rsel.has(h.id));
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
function updApc(){const ok=!!(A&&A.ok),d=apDirty();$('apsave').disabled=sxOpen||!ok||!d;$('apundo').disabled=!ok||!d;
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
function updSpeed(){const ok=!!(SP&&SP.ok),d=spDirty();$('spsave').disabled=sxOpen||!ok||!d;$('spundo').disabled=!ok||!d;
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
function updHealth(){const ok=!!(H&&H.ok);document.querySelectorAll('.hfix,.hrev').forEach(b=>b.disabled=sxOpen||!ok);
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
  $('rtinstb').onclick=()=>saveTo('/api/rt/install',{},'Adding RIG ID…',loadRt,'install');}else ib.style.display='none';
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
function updRt(){const ok=!!(RT&&RT.ok),d=rtDirty(),n=ok?rtCount():0;$('rtsave').disabled=sxOpen||!ok||!n;$('rtundo').disabled=!ok||!d;$('rtclear').disabled=!ok||!Object.keys(rtA).length;
 const ib=$('rtinstb');if(ib)ib.disabled=sxOpen;
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
 $('pregd').disabled=sxOpen||!(G&&G.ok&&G.found);}
async function preFix(k){const i=PRE.find(x=>x.fix&&x.fix.key===k);if(!i)return;
 if(k.startsWith('tab:'))return setTab(k.slice(4));if(k==='launch')return sxLaunch();if(k==='gsync')return gdSync();
 const msg={sleep:'Sets <b>When plugged in, PC goes to sleep after</b> to <b>Never</b>.',usb:'Turns <b>USB selective suspend</b> off when plugged in, so Windows never powers down the APC mini or the DMX interface.',restart:'<b>Windows restarts in 1 minute</b> to finish its updates. Save and close ShowXpress first. (Changed your mind? Run <b>shutdown /a</b>.)'}[k];
 if(!await ask(i.title,msg||'',i.fix.label))return;
 await saveTo('/api/pre/fix',{key:k},'Applying the fix…',loadPre,'prefix');}
$('prerun').onclick=()=>{H=null;loadPre();};$('pregd').onclick=()=>gdSync();

// ---------------- Aim Movers: Dance Floor / Room
const AIMTXT={floor:{t:'Dance floor &mdash; tonight\'s aims',how:['<b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight\'s dancefloor.','<b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size.','<b>THEN</b>Save, close ShowXpress, press Refresh below and check the heads.'],
  depth:'Depth',size:'100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.',svg:'dashed = dancefloor · amber = patterns'},
 room:{t:'Room &mdash; AROUND ROOM for tonight',how:['<b>STEP 1 &middot; CENTER</b>Aim every head at the middle of where AROUND ROOM should sweep (the walls around the room).','<b>STEP 2 &middot; CORNER</b>Optional: aim a head at the front-left edge of that sweep (from the DJ) to set its size.','<b>THEN</b>Save, close ShowXpress, press Refresh below, Apply, and check with <b>ROOM CHECK</b>.'],
  depth:'Height',size:'100% = AROUND ROOM reaches the edge you aimed. Width = across the room, Height = up and down the walls.',svg:'dashed = what you aimed · amber = AROUND ROOM'}};
function aimTxt(){const x=AIMTXT[aimMode];$('aimttl').innerHTML=x.t;$('aimhow').innerHTML=x.how.map(h=>'<div>'+h+'</div>').join('');$('dlab').textContent=x.depth;$('sizesub').textContent=x.size;$('svgl').textContent=x.svg;$('aimsc').textContent=aimMode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)';}
document.querySelectorAll('[data-am]').forEach(b=>b.onclick=()=>{if(aimMode===b.dataset.am)return;aimMode=b.dataset.am;document.querySelectorAll('[data-am]').forEach(x=>x.classList.toggle('on',x===b));
 aimTxt();$('aiminst').style.display='none';$('heads').innerHTML='';$('warnbox').style.display='none';$('result').className='card result';P=PM[aimMode];LD[aimMode]=0;render();load();});

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
function updColor(){const ok=!!(CL&&CL.ok),d=clDirty();$('clsave').disabled=sxOpen||!ok||!d;$('clundo').disabled=!ok||!d;
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
 $('gdsync').disabled=sxOpen||!G.ok||!G.found;$('gdhint').innerHTML=G.ok&&G.found&&sxOpen?sxHint('sync, so the newest show is copied'):'';}
async function gdSync(){await saveTo('/api/gdrive/sync',{},'Copying the show to Google Drive…',async()=>{await loadGd();if($('v-pre').classList.contains('on'))loadPre();},'gsync');}
$('gdsync').onclick=()=>gdSync();
async function sxLaunch(){busy(true,'Starting ShowXpress…');let r;try{r=await api('/api/sx/launch',{});}catch(e){r={ok:false,error:'Lost connection.'}}setTimeout(()=>busy(false),r.ok?3000:0);if(!r.ok)showResult(r,'sx');}
async function sxClose(){if(!await ask('Close ShowXpress?','ShowXpress is asked to close the normal way. If it asks whether to save the show, answer it in ShowXpress.','Close ShowXpress'))return;
 let r;try{r=await api('/api/sx/close',{});}catch(e){r={ok:false,error:'Lost connection.'}}if(!r.ok)showResult(r,'sx');}
$('sxgo').onclick=sxLaunch;$('sxstop').onclick=sxClose;
async function chkUpd(){const u=await getJ('/api/update');$('hver').textContent='Version '+(u.current||'?')+(u.ok?(u.newer?' · version '+u.latest+' is available':' · up to date'):'');
 if(u.ok&&u.newer){const b=$('upd');b.style.display='';b.className='mini primary';b.textContent='⬆ Update to '+u.latest;b.onclick=()=>doUpd(u);}}
async function doUpd(u){if(!await ask('Update to version '+esc(u.latest)+'?','Downloads it from GitHub and installs it. '+(u.mac?'The Mac installer opens &mdash; follow it.':'The Helper closes and opens again by itself in a few seconds.')+' Your show isn&rsquo;t touched.','Update'))return;
 busy(true,'Downloading the update…');let r;try{r=await api('/api/update/install',{});}catch(e){r={ok:false,error:'Lost connection.'}}
 if(r.ok&&r.restarting){UPD=1;busy(true,'Installing the update — the Helper opens again by itself…');return;}busy(false);showResult(r,'update');}
{const bi=new Image();bi.onload=()=>{const b=$('brand');b.innerHTML='';bi.alt='XSV Productions';b.appendChild(bi);};bi.src='/brand.png?t='+T;}

setTab(location.hash.slice(1)||'home');draw();load();poll();loadGd();chkUpd();
</script></body></html>
'@

if (-not $NoBrowser) { Open-AppWindow $url }
$last = Get-Date
try {
  while ($l.IsListening) {
    $task = $l.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(1000)) {
      if (((Get-Date) - $last).TotalSeconds -gt $idleMax) { $l.Stop(); break }
    }
    if (-not $l.IsListening) { break }
    $ctx = $task.Result; $req = $ctx.Request
    try {
      if ($req.QueryString['t'] -ne $token) { Send-Text $ctx 403 'text/plain' 'Open ShowXpress Helper from its icon.'; continue }
      $last = Get-Date
      $path = $req.Url.AbsolutePath
      $body = $null
      if ($req.HttpMethod -eq 'POST') { $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); if ($raw) { $body = $raw | ConvertFrom-Json } }
      switch ($path) {
        '/'            { Send-Text $ctx 200 'text/html; charset=utf-8' ($html.Replace('__TOKEN__', $token)) }
        '/brand.png'   {
          $bp = @((Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ShowXpress Helper/brand.png'), (Join-Path $HOME 'AwaazTools/brand.png'), (Join-Path $here 'brand.png')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
          if ($bp) { Send-Png $ctx $bp } else { Send-Text $ctx 404 'text/plain' 'no brand image' }
        }
        '/icon.png'    { $ip = Join-Path $here 'aim_movers_1024.png'; if (-not (Test-Path $ip)) { $ip = Join-Path $here '../assets/aim_movers_1024.png' } if (Test-Path $ip) { $ib = [IO.File]::ReadAllBytes($ip); $ctx.Response.ContentType = 'image/png'; $ctx.Response.ContentLength64 = $ib.Length; $ctx.Response.OutputStream.Write($ib, 0, $ib.Length); $ctx.Response.Close() } else { Send-Text $ctx 404 'text/plain' 'no icon' } }
        '/api/sx'      { Send-Json $ctx @{ open = (Test-SxOpen) } }
        '/api/sx/launch' {
          if (Test-SxOpen) { Send-Json $ctx @{ ok = $true; out = '  ShowXpress is already open'; error = '' }; break }
          if ($onMac) {
            $a = @(Get-ChildItem -LiteralPath '/Applications' -Directory -Filter '*.app' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' }) | Select-Object -First 1
            if (-not $a) { Send-Json $ctx @{ ok = $false; error = 'ShowXpress was not found in Applications.'; out = '' }; break }
            & open $a.FullName
          } else {
            $x = Get-SxExe
            if (-not $x) { Send-Json $ctx @{ ok = $false; error = 'ShowXpress was not found in Program Files\ShowXpress.'; out = '' }; break }
            Start-Process -FilePath $x -WorkingDirectory (Split-Path $x)
          }
          Send-Json $ctx @{ ok = $true; out = '  ShowXpress is starting'; error = '' }
        }
        '/api/sx/close' {
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
          if ($onMac) { & open $dl; Send-Json $ctx @{ ok = $true; out = "  The installer for version $($u.latest) is open - follow it, then open ShowXpress Helper again."; error = '' }; break }
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
        '/api/aim/install' { Send-Json $ctx (Invoke-Engine '-Action Install -Mode Room') }
        '/api/color'   { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $colorEngine) }
        '/api/color/apply' {
          $hx = "$($body.hex)".Trim().TrimStart('#')
          if ($hx -notmatch '^[0-9a-fA-F]{6}$') { Send-Json $ctx @{ ok = $false; error = 'Pick a colour first.'; out = '' }; break }
          $nm = ("$($body.name)" -replace '[^A-Za-z0-9 \-]', '').Trim(); if ($nm.Length -gt 30) { $nm = $nm.Substring(0, 30) }
          $na = if ($nm) { " -Name `"$nm`"" } else { '' }
          Send-Json $ctx (Invoke-Engine "-Action Apply -Color $hx$na" $colorEngine)
        }
        '/api/gdrive'  { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $gdEngine) }
        '/api/gdrive/sync' { Send-Json $ctx (Invoke-Engine '-Action Sync' $gdEngine) }
        '/api/pre/fix' {
          $k = "$($body.key)"
          if ($k -notmatch '^(sleep|usb|restart)$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Fix -FixId $k" $preEngine)
        }
        '/api/apply' {
          $w = [int]$body.w; $d = [int]$body.d
          if ($w -lt 20 -or $w -gt 300 -or $d -lt 20 -or $d -gt 300) { Send-Json $ctx @{ ok = $false; error = 'Size must be 20-300%.'; out = '' }; break }
          $f = if ($body.force) { ' -Force' } else { '' }
          $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }
          Send-Json $ctx (Invoke-Engine "-Action Apply -Size `"$w $d`" -NoPrompt$f$mo")
        }
        '/api/home'    { $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }; Send-Json $ctx (Invoke-Engine "-Action Home -NoPrompt$mo") }
        '/api/skip'    {
          $r = Invoke-Engine '-Action Preview' $skipEngine
          if ($r.ok) { $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1); Send-Text $ctx 200 'application/json; charset=utf-8' $j }
          else { Send-Json $ctx @{ ok = $false; error = $r.error } }
        }
        '/api/skip/apply' {
          $ids = @($body.heads | ForEach-Object { "$_" })
          if (@($ids | Where-Object { $_ -notmatch '^\d+$' }).Count -or $ids.Count -lt 2) { Send-Json $ctx @{ ok = $false; error = 'Pick at least 2 heads.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $skipEngine)
        }
        '/api/rig'     { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $rigEngine) }
        '/api/rig/apply' {
          $ids = @($body.heads | ForEach-Object { "$_" })
          if (@($ids | Where-Object { $_ -notmatch '^\d+$' }).Count -or $ids.Count -lt 1) { Send-Json $ctx @{ ok = $false; error = 'Tick at least one head.'; out = '' }; break }
          $r = Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $rigEngine
          if ($r.ok) { $r.out += Update-SkipFlash $ids }
          Send-Json $ctx $r
        }
        '/api/apc'     { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $apcEngine) }
        '/api/apc/apply' {
          $items = @(foreach ($c in @($body.changes)) { if ($c) { $o = [ordered]@{ sec = "$($c.sec)"; title = "$($c.title)"; note = $c.note }; if ($null -ne $c.on) { $o.on = $c.on; $o.off = $c.off }; $o } })
          $badC = @($items | Where-Object { $_.Contains('on') -and (("$($_.on)" -notmatch '^\d+$') -or ("$($_.off)" -notmatch '^\d+$') -or [int]$_.on -gt 127 -or [int]$_.off -gt 127) }).Count
          if ($badC -or -not $items.Count -or @($items | Where-Object { $_.sec -notmatch '^page\d+_button\d+$' -or "$($_.note)" -notmatch '^-?\d+$' -or [int]$_.note -lt -1 -or [int]$_.note -gt 63 }).Count) {
            Send-Json $ctx @{ ok = $false; error = 'Nothing valid to save.'; out = '' }; break }
          Send-Json $ctx (Invoke-WithChanges $apcEngine $items)
        }
        '/api/speed'   { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $speedEngine) }
        '/api/speed/apply' {
          $items = @(foreach ($c in @($body.changes)) { if ($c) { [ordered]@{ sec = "$($c.sec)"; title = "$($c.title)"; fader = $c.fader } } })
          if (-not $items.Count -or @($items | Where-Object { $_.sec -notmatch '^page\d+_button\d+$' -or "$($_.fader)" -notmatch '^\d+$' -or [int]$_.fader -gt 99 }).Count) {
            Send-Json $ctx @{ ok = $false; error = 'Nothing valid to save.'; out = '' }; break }
          Send-Json $ctx (Invoke-WithChanges $speedEngine $items)
        }
        '/api/health'  { Send-EngineJson $ctx (Invoke-Engine '-Action Check' $healthEngine) }
        '/api/health/fix' {
          $k = "$($body.key)"
          if ($k -notmatch '^(speed|midiout|midilight|pad|color|fixtures)\|(page\d+_button\d+|\d+)$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Fix -FixId `"$k`"" $healthEngine)
        }
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
        '/api/rt/install' { Send-Json $ctx (Invoke-Engine '-Action Install' $rtEngine) }
        '/api/rt/apply' {
          $as = [ordered]@{}
          if ($body.assign) { foreach ($pp in $body.assign.PSObject.Properties) { if ($pp.Name -match '^(tl|tr|tm|bl|br|bm)-(l|r)$' -and "$($pp.Value)" -match '^\d+$') { $as[$pp.Name] = "$($pp.Value)" } } }
          if (-not $as.Count) { Send-Json $ctx @{ ok = $false; error = 'Put at least one mover on a truss.'; out = '' }; break }
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
          Send-Json $ctx $r
        }
        '/api/pre'     { Send-EngineJson $ctx (Invoke-Engine '-Action Check' $preEngine) }
        default        { Send-Text $ctx 404 'text/plain' 'not found' }
      }
    } catch {
      try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message; out = '' } } catch {}
    }
  }
} finally {
  try { $l.Close() } catch {}
  if (Test-Path $infoF) { try { $i = Get-Content $infoF -Raw | ConvertFrom-Json; if ($i.pid -eq $PID) { Remove-Item $infoF } } catch {} }
}
