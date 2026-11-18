# AIM MOVERS - small GUI for df_aim.ps1 (Windows PowerShell 5.1 + macOS pwsh 7).
# Runs a private web page on this computer only (localhost + random key) and opens it as an app window
# (Edge/Chrome "app" mode, else the normal browser). The page talks to df_aim.ps1, which does all the work.
# Quits by itself a few minutes after its window is closed.
param([string]$TestRoot = '', [int]$Port = 47321, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'df_aim.ps1'
$onMac  = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
$psExe  = (Get-Process -Id $PID).Path
$infoF  = Join-Path ([IO.Path]::GetTempPath()) 'aim_movers_gui.json'
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
  throw "Port $Port is busy and no running AIM MOVERS was found."
}
$url = "http://localhost:$Port/?t=$token"
[IO.File]::WriteAllText($infoF, (@{ url = $url; pid = $PID } | ConvertTo-Json))

function Test-SxOpen { [bool](Get-Process | Where-Object { $_.ProcessName -match 'TheLightingController|ShowXpress' }) }

function Invoke-Engine([string]$engineArgs) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$engine`" $engineArgs"
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
    $msg = (($err -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(At |\+ |\+\s|CategoryInfo|FullyQualifiedErrorId|~)' } | Select-Object -First 1)
    $msg = ($msg -replace '^.*?\.ps1\s*:\s*', '').Trim()
    if (-not $msg) { $msg = "Something went wrong (code $($p.ExitCode))." }
  }
  @{ ok = (-not $msg); out = $out; error = $msg }
}

function Send-Text($ctx, [int]$code, [string]$type, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text); $r = $ctx.Response
  $r.StatusCode = $code; $r.ContentType = $type; $r.Headers.Add('Cache-Control', 'no-store'); $r.ContentLength64 = $b.Length
  $r.OutputStream.Write($b, 0, $b.Length); $r.Close()
}
function Send-Json($ctx, $obj) { Send-Text $ctx 200 'application/json; charset=utf-8' ($obj | ConvertTo-Json -Depth 6 -Compress) }

$html = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Aim Movers</title>
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
@media (max-width:760px){.how{grid-template-columns:1fr}.sizegrid{grid-template-columns:1fr}}
</style></head><body>
<header><img class="logo" src="/icon.png?t=__TOKEN__" alt=""><h1>Aim Movers<span>dancefloor setup</span></h1><div id="sx" class="pill ok">Checking ShowXpress&hellip;</div></header>
<main>
  <section class="card">
    <h2>Tonight's aims</h2>
    <p class="sub">Read from the scene <b>DF AIM (ADJUST)</b> in ShowXpress.</p>
    <div class="how">
      <div><b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight's dancefloor.</div>
      <div><b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size.</div>
      <div><b>THEN</b>Save, close ShowXpress, press Refresh below and check the heads.</div>
    </div>
    <div class="row"><div id="summary" class="summary grow">Loading&hellip;</div><button id="refresh">&#8635; Refresh</button></div>
    <div id="heads"></div>
    <div id="warnbox" class="warnbox"></div>
  </section>

  <section class="card">
    <h2>Overall pattern size</h2>
    <p class="sub">100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.</p>
    <div class="sizegrid">
      <div>
        <div class="slider"><div class="top"><label>Width</label><input id="wn" class="num" type="number" min="20" max="300"></div><input id="w" type="range" min="20" max="300" step="1"></div>
        <div class="slider"><div class="top"><label>Depth</label><input id="dn" class="num" type="number" min="20" max="300"></div><input id="d" type="range" min="20" max="300" step="1"></div>
        <div class="row"><label class="link"><input id="lnk" type="checkbox" checked> Same both ways</label><div class="grow"></div>
          <div class="chips"><span class="chip" data-v="80">80</span><span class="chip" data-v="90">90</span><span class="chip" data-v="100">100</span><span class="chip" data-v="110">110</span><span class="chip" data-v="120">120</span></div></div>
      </div>
      <svg viewBox="0 0 300 210" aria-label="size preview">
        <text x="150" y="16" fill="#5d6574" font-size="10" text-anchor="middle">DJ / front</text>
        <rect id="floor" x="60" y="45" width="180" height="120" fill="none" stroke="#5d6574" stroke-dasharray="5 4" rx="4"/>
        <rect id="pat" x="60" y="45" width="180" height="120" fill="rgba(255,176,32,.16)" stroke="#ffb020" stroke-width="2" rx="6"/>
        <circle cx="150" cy="105" r="4" fill="#ffb020"/>
        <text x="150" y="200" fill="#5d6574" font-size="10" text-anchor="middle">dashed = dancefloor &middot; amber = patterns</text>
      </svg>
    </div>
  </section>

  <section id="result" class="card result"><h2 id="rtitle"></h2><div id="rbody"></div><details><summary>Full details</summary><pre id="rlog"></pre></details></section>
  <div class="foot" id="foot"></div>
</main>
<div class="bar"><div class="in"><button id="apply" class="primary">Apply to show</button><button id="home">Reset to normal</button><div class="hint grow" id="hint"></div></div></div>
<div class="modal" id="modal"><div class="box"><h2 id="mt"></h2><p id="mp"></p><div class="row" style="justify-content:flex-end"><button id="mno">Cancel</button><button id="myes" class="primary" style="padding:9px 18px;font-size:14px"></button></div></div></div>
<div class="busy" id="busy"><div class="spin"></div><span id="busyt">Working&hellip;</span></div>
<div class="gone" id="gone"><h2 style="color:var(--txt)">Aim Movers has closed</h2><p>Open it again from its icon.</p></div>
<script>
const T='__TOKEN__';const $=id=>document.getElementById(id);
let P=null,sxOpen=false,linked=true;
async function api(p,body){const r=await fetch(p+'?t='+T,body?{method:'POST',headers:{'Content-Type':'text/plain'},body:JSON.stringify(body)}:{});return r.json();}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function sign(v){return (v>0?'+':'')+v;}
function tile(h){const moved=h.op||h.ot,cls=['tile',moved?'moved':'',h.sized?'sized':'',h.warn?'warn':''].join(' ');
 return `<div class="${cls}" title="${esc(h.warn||'')}"><div class="n">${esc(h.label)}</div>
 <div><span class="l">center </span><span class="v">${moved?sign(h.op)+' / '+sign(h.ot):'normal'}</span></div>
 <div><span class="l">size </span><span class="v sz">${h.sized?h.kp+'% &times; '+h.kt+'%':'normal'}</span></div></div>`;}
function render(){if(!P)return;
 if(!P.ok){$('summary').innerHTML='<span style="color:var(--red)">'+esc(P.error)+'</span>';$('heads').innerHTML='';$('warnbox').style.display='none';updBar();return;}
 const hs=P.heads,a=hs.filter(h=>h.is140),b=hs.filter(h=>!h.is140),moved=hs.filter(h=>h.op||h.ot).length,sized=hs.filter(h=>h.sized).length,w=hs.filter(h=>h.warn);
 $('summary').innerHTML=`<b>${a.length}</b> &times; 140SR &middot; <b>${b.length}</b> &times; 251SR &nbsp;&mdash;&nbsp; <b>${moved}</b> re-aimed &middot; <b>${sized}</b> with a corner set`+(w.length?` &middot; <b style="color:var(--red)">${w.length} look wrong</b>`:'');
 $('heads').innerHTML=`<div class="group"><h3>140SR</h3><div class="tiles">${a.map(tile).join('')}</div></div><div class="group"><h3>251SR</h3><div class="tiles">${b.map(tile).join('')}</div></div>`;
 const wb=$('warnbox');if(w.length){wb.style.display='block';wb.innerHTML='<b>Check these heads:</b> '+w.map(h=>esc(h.label)+' &ndash; '+esc(h.warn)).join('<br>');}else wb.style.display='none';
 $('foot').textContent='Show: '+P.show;updBar();}
function updBar(){const bad=!P||!P.ok;$('apply').disabled=sxOpen||bad;$('home').disabled=sxOpen||bad;
 $('hint').innerHTML=sxOpen?'<span style="color:var(--amber)">ShowXpress is open &mdash; close it (save first) to apply.</span>':(bad?'':'Writes to all dancefloor movement scenes. Nothing is changed until you press Apply.');}
async function load(){$('summary').textContent='Loading…';try{P=await api('/api/preview');}catch(e){P={ok:false,error:'Could not read the show.'}}
 if(P.ok&&!load.done){setW(P.lastW);setD(P.lastD);$('lnk').checked=linked=(P.lastW===P.lastD);load.done=1;}render();}
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
 if(!r.ok){$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> Not applied';$('rbody').innerHTML='<p>'+esc(r.error)+'</p><p class="sub">Nothing was changed.</p>';}
 else{const tot=lines.find(l=>/movement scenes checked/.test(l))||'';const ch=lines.filter(l=>/\s[1-9]\d* values changed/.test(l)).map(l=>l.trim().replace(/\s{2,}/g,' — '));
  const wr=lines.filter(l=>/WARNING/.test(l)).map(l=>l.replace(/^\s*WARNING:\s*/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(what==='home'?'Everything is back to normal':'Applied to the show');
  $('rbody').innerHTML='<p class="sub" style="margin:4px 0 0">'+esc(tot.replace(/^\s*->\s*/,''))+'. '+(what==='home'?'':'Open ShowXpress and check <b>DF CHECK 140</b> / <b>DF CHECK 251</b> &mdash; the beams should trace the floor corners.')+'</p>'+
   (ch.length?'<ul>'+ch.map(c=>'<li>'+esc(c)+'</li>').join('')+'</ul>':'')+(wr.length?'<div class="warnbox" style="display:block">'+wr.map(esc).join('<br>')+'</div>':'');}
 box.scrollIntoView({behavior:'smooth'});}
$('apply').onclick=async()=>{let force=false;const w=P.heads.filter(h=>h.warn);
 if(w.length){if(!await ask(w.length+' head(s) look wrong','Their aims in DF AIM (ADJUST) look far off the floor &mdash; usually step 1 / step 2 not aimed yet.<br><br>Apply anyway?','Apply anyway'))return;force=true;}
 busy(true,'Applying to the show…');try{const r=await api('/api/apply',{w:+$('w').value,d:+$('d').value,force});showResult(r,'apply');}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load();};
$('home').onclick=async()=>{if(!await ask('Reset to normal?','All heads go back to the normal center, size 100%, and the DF AIM (ADJUST) scene is reset. Your shapes are kept.','Reset'))return;
 busy(true,'Resetting…');try{const r=await api('/api/home',{});showResult(r,'home');}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load.done=0;load();};
async function poll(){try{const r=await api('/api/sx');const was=sxOpen;sxOpen=r.open;const p=$('sx');p.className='pill '+(sxOpen?'bad':'ok');
 p.textContent=sxOpen?'ShowXpress open — close to apply':'ShowXpress closed ✓';updBar();if(was&&!sxOpen)load();}catch(e){$('gone').style.display='flex';return;}setTimeout(poll,2000);}
draw();load();poll();
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
      if ($req.QueryString['t'] -ne $token) { Send-Text $ctx 403 'text/plain' 'Open Aim Movers from its icon.'; continue }
      $last = Get-Date
      $path = $req.Url.AbsolutePath
      $body = $null
      if ($req.HttpMethod -eq 'POST') { $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); if ($raw) { $body = $raw | ConvertFrom-Json } }
      switch ($path) {
        '/'            { Send-Text $ctx 200 'text/html; charset=utf-8' ($html.Replace('__TOKEN__', $token)) }
        '/icon.png'    { $ip = Join-Path $here 'aim_movers_1024.png'; if (Test-Path $ip) { $ib = [IO.File]::ReadAllBytes($ip); $ctx.Response.ContentType = 'image/png'; $ctx.Response.ContentLength64 = $ib.Length; $ctx.Response.OutputStream.Write($ib, 0, $ib.Length); $ctx.Response.Close() } else { Send-Text $ctx 404 'text/plain' 'no icon' } }
        '/api/sx'      { Send-Json $ctx @{ open = (Test-SxOpen) } }
        '/api/preview' {
          $r = Invoke-Engine '-Action Preview'
          if ($r.ok) { $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1); Send-Text $ctx 200 'application/json; charset=utf-8' $j }
          else { Send-Json $ctx @{ ok = $false; error = $r.error } }
        }
        '/api/apply' {
          $w = [int]$body.w; $d = [int]$body.d
          if ($w -lt 20 -or $w -gt 300 -or $d -lt 20 -or $d -gt 300) { Send-Json $ctx @{ ok = $false; error = 'Size must be 20-300%.'; out = '' }; break }
          $f = if ($body.force) { ' -Force' } else { '' }
          Send-Json $ctx (Invoke-Engine "-Action Apply -Size `"$w $d`" -NoPrompt$f")
        }
        '/api/home'    { Send-Json $ctx (Invoke-Engine '-Action Home -NoPrompt') }
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
