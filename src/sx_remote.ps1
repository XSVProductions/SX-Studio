# ShowXpress REMOTE - presses Live buttons in a running ShowXpress (its "External App" network control, TCP 7348,
# official protocol: download.thelightingcontroller.com/software/External_Application/Protocol.pdf). Verified 2026-11-22.
#
#   -Action State                     -> JSON { ok, ready, open, connected, pressed:[{title,page}], titles:[...], error, setup:{...} }
#   -Action Press -Titles "A|B" [-Solo] [-Idle]
#        presses the buttons with those titles. -Solo releases everything else that is playing first.
#        -Idle = only if nothing outside the SETUP page is playing (so a running show is never cut), else
#        { skipped:true, playing:[...] } and nothing is pressed.
#        -Release "C|D" also releases those buttons (if playing and not in -Titles) - the Auto Show tab's "Try".
#   -Action Release -Titles "A|B"     releases those buttons
#   -Action Off                       releases every pressed button
#   -Action Enable                    turns the remote on in the show (ShowXpress must be closed; works from its next start):
#        param.ini [Network] LIVEMOBILEENABLE = yes, live.ini [live] allow_live_mobile = yes + live_mobile_password
#        (kept if set, else random), live_mobile = yes on every page (a page without it can't be reached).
#   -Action AutoGet                   -> JSON { ok, config, buttons:[{title,page,dup,reach}], ready, open }   (Auto Show tab)
#   -Action AutoSave -ConfigFile f    checks + saves the Auto Show settings to <show>/auto_show.json
#   -Action Auto -StatusFile f [-Titles <look id>]   AUTO SHOW player (the Helper starts it and talks to it on stdin):
#        plays the looks from auto_show.json, each for its number of bars at the BPM, and writes its state to f.
#        stdin: next | prev | go <id> | hold | resume | sync | bpm <n> | reload | q (or stdin closed = stop)
#        -Pipe <name> -PlayerStatus <file> (stage 4 of the SX Player, user 2026-11-23): play the looks on the Helper's
#        SX Player instead of ShowXpress - buttons go on/off over the player's pipe (by title, like ShowXpress), what is
#        on comes from the player's state file, and the BPM follows the player's beat clock (tap / VirtualDJ).
# Buttons are found by TITLE; when two buttons share a title ShowXpress only reaches the first one.
# Connections are short (connect, press, close): ShowXpress asks a connected app for beats (BEAT_ON) and we don't
# want to sit on that during a show.
# -TestRoot: no network - "ShowXpress open" = marker file _sx_open, pressed buttons kept in _remote.json,
#            param.ini = <TestRoot>/_param.ini.
param(
  [ValidateSet('State','Press','Release','Off','Enable','AutoGet','AutoSave','Auto')][string]$Action = 'State',
  [string]$Titles = '',
  [string]$Release = '',
  [switch]$Solo,
  [switch]$Idle,
  [string]$ConfigFile = '',
  [string]$StatusFile = '',
  [string]$TestRoot = '',
  [string]$Pipe = '',
  [string]$PlayerStatus = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')
$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$want = @("$Titles" -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$autoF = Join-Path $root 'auto_show.json'
$fakeF = Join-Path $root '_remote.json'

function Get-ParamPath {
  if ($TestRoot) { return (Join-Path $TestRoot '_param.ini') }
  Join-Path (Split-Path (Split-Path $root)) 'param.ini'   # <TheLightingController>/LightShows/<show> -> <TheLightingController>/param.ini
}
function Read-Text($p) {
  $b = [IO.File]::ReadAllBytes($p); $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  $o = if ($bom) { 3 } else { 0 }; $t = [Text.Encoding]::UTF8.GetString($b, $o, $b.Length - $o)
  @{ text = $t; bom = $bom; nl = $(if ($t -match "`r`n") { "`r`n" } else { "`n" }) }
}
function Test-Open { if ($TestRoot) { Test-Path -LiteralPath (Join-Path $TestRoot '_sx_open') } else { Test-SxRunning } }
function Get-Setup {
  $info = Get-LiveInfo $root
  $lv = $info.Live
  $off = @(foreach ($s in $info.Sections) { if ($s[0] -match '^page\d+$' -and "$($s[1]['live_mobile'])" -ne 'yes') { "$($s[1]['name'])" } })
  $pp = Get-ParamPath; $en = $false; $port = 7348; $pfound = Test-Path -LiteralPath $pp
  if ($pfound) {
    $pt = (Read-Text $pp).text
    $en = $pt -match '(?m)^LIVEMOBILEENABLE = yes\s*$'
    if ($pt -match '(?m)^LIVEMOBILEPORT = (\d+)') { $port = [int]$matches[1] }
  }
  $pw = "$($lv['live_mobile_password'])"; $al = "$($lv['allow_live_mobile'])" -eq 'yes'
  [pscustomobject]@{ appOn = $en; paramFound = $pfound; allowed = $al; password = $pw; hasPassword = [bool]$pw
                     pagesOff = $off; port = $port; info = $info; ready = ($en -and $al -and [bool]$pw -and -not $off.Count) }
}
function Get-SetupJson($s) { [ordered]@{ appOn = $s.appOn; allowed = $s.allowed; password = $s.hasPassword; pagesOff = @($s.pagesOff) } }

# ---------------------------------------------------------------- connection
function Send-Sx($o, [string]$line) { $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $o.s.Write($b, 0, $b.Length); $o.s.Flush() }
function Read-Sx($o, [scriptblock]$done, [int]$ms) {
  # reads lines until $done is true for one of them (or $ms passes); returns every line read
  $out = New-Object Collections.Generic.List[string]; $end = (Get-Date).AddMilliseconds($ms); $bytes = New-Object byte[] 65536
  while ((Get-Date) -lt $end) {
    if (-not $o.c.Connected) { break }
    if (-not $o.s.DataAvailable) { Start-Sleep -Milliseconds 15; continue }
    $n = $o.s.Read($bytes, 0, $bytes.Length); if ($n -le 0) { break }
    [void]$o.buf.Append([Text.Encoding]::UTF8.GetString($bytes, 0, $n))
    $t = $o.buf.ToString(); $k = $t.LastIndexOf("`r`n")
    if ($k -ge 0) {
      [void]$o.buf.Clear(); [void]$o.buf.Append($t.Substring($k + 2))
      foreach ($l in ($t.Substring(0, $k) -split "`r`n")) { $out.Add($l); if (& $done $l) { return ,$out } }
    }
  }
  ,$out
}
function Open-Sx($setup) {
  $c = New-Object Net.Sockets.TcpClient
  try { if (-not $c.ConnectAsync('127.0.0.1', $setup.port).Wait(1500)) { throw 'x' } } catch { $c.Close(); return $null }
  $o = [pscustomobject]@{ c = $c; s = $c.GetStream(); buf = (New-Object Text.StringBuilder) }
  Send-Sx $o "HELLO|ShowXpressHelper|$($setup.password)"
  $r = Read-Sx $o { param($l) $l -eq 'HELLO' -or $l -like 'ERROR*' } 2500
  $h = @($r | Where-Object { $_ -eq 'HELLO' -or $_ -like 'ERROR*' }) | Select-Object -First 1
  if ($h -ne 'HELLO') { $c.Close(); if ($h) { throw "ShowXpress refused SX Studio ($h). Turn the remote on again from SX Studio." }; return $null }
  $o
}
function Get-SxList($o) {
  Send-Sx $o 'BUTTON_LIST'
  $r = Read-Sx $o { param($l) $l.StartsWith('BUTTON_LIST|') } 4000
  $x = @($r | Where-Object { $_.StartsWith('BUTTON_LIST|') }) | Select-Object -Last 1
  if (-not $x) { return $null }
  [xml]$d = $x.Substring(12)
  @(foreach ($p in @($d.buttons.page)) { if ($p) { foreach ($b in @($p.button)) { if ($b) {
    [pscustomobject]@{ title = "$($b.InnerText)".Trim(); page = "$($p.name)"; pressed = ("$($b.pressed)" -eq '1') } } } } })
}
function Get-FakeList($setup) {
  $on = @{}; if (Test-Path -LiteralPath $fakeF) { foreach ($t in @(([IO.File]::ReadAllText($fakeF) | ConvertFrom-Json))) { if ($t) { $on["$t"] = $true } } }
  $vis = @{}; foreach ($s in $setup.info.Sections) { if ($s[0] -match '^page(\d+)$' -and "$($s[1]['live_mobile'])" -eq 'yes') { $vis[[int]$matches[1]] = $true } }
  @(foreach ($b in $setup.info.Buttons) { if ($vis[$b.Page] -and $b.Title) { [pscustomobject]@{ title = $b.Title; page = $b.PageName; pressed = [bool]$on[$b.Title] } } })
}
function Connect-Sx($setup) {
  # -> @{ cn; list; error }   (cn = $null in test mode)
  if (-not $setup.ready) { return @{ error = 'The ShowXpress remote is off.' } }
  if (-not (Test-Open)) { return @{ error = 'ShowXpress is closed.' } }
  if ($TestRoot) { return @{ cn = $null; list = (Get-FakeList $setup); error = '' } }
  $cn = Open-Sx $setup
  if (-not $cn) { return @{ error = 'ShowXpress isn''t answering yet (still starting, or it was opened before the remote was turned on - close and open it again).' } }
  $list = Get-SxList $cn
  if ($null -eq $list -or -not @($list).Count) { try { $cn.c.Close() } catch {}; return @{ error = 'ShowXpress hasn''t loaded the show yet.' } }
  @{ cn = $cn; list = $list; error = '' }
}
function Close-Sx($x) { if ($x -and $x.cn) { try { $x.cn.c.Close() } catch {} } }
function Send-Cmds($x, $setup, $cmds) {
  # sends BUTTON_PRESS / BUTTON_RELEASE lines, then reads the button states again
  if (-not @($cmds).Count) { return }
  if ($TestRoot) {
    $on = New-Object Collections.Generic.List[string]; foreach ($b in $x.list) { if ($b.pressed) { $on.Add($b.title) } }
    foreach ($c in $cmds) { $t = $c.Substring($c.IndexOf('|') + 1); if ($c.StartsWith('BUTTON_PRESS')) { if (-not $on.Contains($t)) { $on.Add($t) } } else { [void]$on.Remove($t) } }
    [IO.File]::WriteAllText($fakeF, (ConvertTo-Json @($on.ToArray()) -Compress))
    $x.list = Get-FakeList $setup; return
  }
  foreach ($c in $cmds) { Send-Sx $x.cn $c }
  Start-Sleep -Milliseconds 250
  $l2 = Get-SxList $x.cn; if ($l2) { $x.list = $l2 }
}
function Get-ByTitle($list) { $h = @{}; foreach ($b in $list) { if (-not $h.ContainsKey($b.title)) { $h[$b.title] = $b } }; $h }

# ---------------------------------------------------------------- Auto Show settings
function New-Id { -join (1..8 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }) }
function Get-Clean([string]$s, [int]$max) { $s = ($s -replace '[\x00-\x1f|"]', '').Trim(); if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }; $s }
function ConvertTo-AutoCfg($j) {
  $bpm = 124.0; try { if ($null -ne $j.bpm) { $bpm = [math]::Round([double]$j.bpm, 1) } } catch {}
  $bpm = [math]::Max(40, [math]::Min(220, $bpm))
  $looks = New-Object Collections.Generic.List[object]; $ids = @{}
  foreach ($l in @($j.looks)) {
    if (-not $l -or $looks.Count -ge 60) { continue }
    $ts = New-Object Collections.Generic.List[string]
    foreach ($t in @($l.titles)) { $c = Get-Clean "$t" 80; if ($c -and -not $ts.Contains($c) -and $ts.Count -lt 24) { $ts.Add($c) } }
    $bars = 16; try { if ($null -ne $l.bars) { $bars = [int]$l.bars } } catch {}; $bars = [math]::Max(1, [math]::Min(256, $bars))
    $id = "$($l.id)"; if ($id -notmatch '^[0-9a-f]{8}$' -or $ids[$id]) { $id = New-Id }; $ids[$id] = 1
    $nm = Get-Clean "$($l.name)" 40; if (-not $nm) { $nm = "Look $($looks.Count + 1)" }
    $looks.Add([ordered]@{ id = $id; name = $nm; bars = $bars; on = ($null -eq $l.on -or [bool]$l.on); titles = @($ts.ToArray()) })
  }
  [ordered]@{ bpm = $bpm; order = $(if ("$($j.order)" -eq 'shuffle') { 'shuffle' } else { 'order' })
              stop = $(if ("$($j.stop)" -eq 'off') { 'off' } else { 'keep' }); clean = [bool]$j.clean; looks = @($looks.ToArray()) }
}
function Read-AutoCfg {
  $j = $null
  if (Test-Path -LiteralPath $autoF) { try { $j = [IO.File]::ReadAllText($autoF) | ConvertFrom-Json } catch {} }
  if (-not $j) { $j = [pscustomobject]@{ looks = @() } }
  ConvertTo-AutoCfg $j
}

# ================================================================ actions
if ($Action -eq 'Enable') {
  if (Test-Open) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
  $setup = Get-Setup
  $pp = Get-ParamPath
  if (-not (Test-Path -LiteralPath $pp)) { throw "ShowXpress settings file not found ($pp). Turn it on in ShowXpress: Preferences > Network > External App, then Live > Live settings > External control. NOTHING was changed." }
  $out = @()
  $pr = Read-Text $pp; $pt = $pr.text
  if ($pt -notmatch '(?m)^LIVEMOBILEENABLE = yes\s*$') {
    if ($pt -match '(?m)^LIVEMOBILEENABLE = .*$') { $pt = [regex]::Replace($pt, '(?m)^LIVEMOBILEENABLE = [^\r\n]*', 'LIVEMOBILEENABLE = yes') }
    elseif ($pt -match '(?m)^\[Network\]') { $pt = ([regex]'(?m)^\[Network\][ \t]*(?=\r?$)').Replace($pt, "[Network]$($pr.nl)LIVEMOBILEENABLE = yes", 1) }
    else { $pt = $pt.TrimEnd("`r", "`n") + "$($pr.nl)[Network]$($pr.nl)LIVEMOBILEENABLE = yes$($pr.nl)" }
    $out += '  ShowXpress settings: External App turned on'
  }
  $ini = $setup.info.Ini
  if (-not $setup.allowed) { Set-IniKey $ini 'live' 'allow_live_mobile' 'yes'; $out += '  Live: external control turned on' }
  if (-not $setup.hasPassword) {
    $pw = -join (1..10 | ForEach-Object { 'abcdefghjkmnpqrstuvwxyz23456789'[(Get-Random -Maximum 31)] })
    Set-IniKey $ini 'live' 'live_mobile_password' $pw @('allow_live_mobile'); $out += '  Live: password set (SX Studio reads it from the show)'
  }
  foreach ($s in $setup.info.Sections) {
    if ($s[0] -match '^page\d+$' -and "$($s[1]['live_mobile'])" -ne 'yes') { Set-IniKey $ini $s[0] 'live_mobile' 'yes' @('name', 'swap', 'nb_buttons'); $out += "  Page $($s[1]['name']): can be reached" }
  }
  if (-not $out.Count) { '  The remote was already on - nothing to change.'; return }
  [void](Save-LiveIni $ini)
  if ($pt -ne $pr.text) { [IO.File]::WriteAllText($pp, $pt, (New-Object Text.UTF8Encoding($pr.bom))) }
  '  ShowXpress remote control turned on (works from the next time ShowXpress opens):'
  $out
  return
}

if ($Action -eq 'AutoSave') {
  if (-not $ConfigFile -or -not (Test-Path -LiteralPath $ConfigFile)) { throw 'No settings were sent. NOTHING was changed.' }
  $cfg = ConvertTo-AutoCfg ([IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json)
  [IO.File]::WriteAllText($autoF, ($cfg | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  "  Auto Show saved: $(@($cfg.looks).Count) look(s), $($cfg.bpm) BPM"
  ($cfg | ConvertTo-Json -Depth 6 -Compress)
  return
}

if ($Action -eq 'AutoGet') {
  $setup = Get-Setup
  $vis = @{}; $swp = @{}
  foreach ($s in $setup.info.Sections) { if ($s[0] -match '^page(\d+)$') { $vis[[int]$matches[1]] = "$($s[1]['live_mobile'])" -eq 'yes'; $swp[[int]$matches[1]] = "$($s[1]['swap'])" -eq 'yes' } }
  $seen = @{}
  $bt = @(foreach ($b in ($setup.info.Buttons | Sort-Object Page, Btn)) {
    if (-not $b.Title) { continue }
    $dup = [bool]$seen[$b.Title]; $seen[$b.Title] = 1
    [ordered]@{ title = $b.Title; page = $b.PageName; dup = $dup; reach = [bool]$vis[$b.Page]; swap = [bool]$swp[$b.Page] }
  })
  [ordered]@{ ok = $true; show = (Split-Path $root -Leaf); config = (Read-AutoCfg); buttons = $bt; ready = $setup.ready; open = (Test-Open); setup = (Get-SetupJson $setup) } | ConvertTo-Json -Depth 7 -Compress
  return
}

if ($Action -eq 'Auto') {
  # ---------------------------------------------------------------- AUTO SHOW player
  $cfg = Read-AutoCfg
  $setup = Get-Setup
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $S = [ordered]@{ running = $true; pid = $PID; lookId = ''; name = ''; next = ''; nextId = ''; bars = 0; bar = 0; beat = 0; msLeft = 0; bpm = $cfg.bpm
                   held = $false; applied = $false; error = ''; missing = @(); at = ''; changes = 0; startedAt = (Get-Date).ToString('s') }
  $mine = New-Object Collections.Generic.List[string]   # titles this player turned on and still owns
  $curId = ''; $lookStart = 0.0; $need = $true; $first = $true; $lastTry = -99999.0; $sxPid = 0; $lastOpen = -99999.0
  $hist = New-Object Collections.Generic.List[string]; $bag = New-Object Collections.Generic.List[string]; $nextId = ''
  $swapPg = @{}; $swapOf = @{}
  $usePl = [bool]$Pipe; $S.target = $(if ($usePl) { 'player' } else { 'showxpress' }); $S.src = ''
  $script:plW = $null; $script:plC = $null; $lastPl = -99999.0
  if ($usePl) {
    # the SX Player instead of ShowXpress: the same Invoke-Look / Stop-Player code, other plumbing
    function Get-PlStatus { if (-not $PlayerStatus -or -not (Test-Path -LiteralPath $PlayerStatus)) { return $null }; try { [IO.File]::ReadAllText($PlayerStatus) | ConvertFrom-Json } catch { $null } }
    function Send-PlLine([string]$l) {
      for ($try = 0; $try -lt 2; $try++) {
        try {
          if (-not $script:plW) {
            $c = New-Object IO.Pipes.NamedPipeClientStream('.', $Pipe, [IO.Pipes.PipeDirection]::Out); $c.Connect(2000)
            $w = New-Object IO.StreamWriter($c, (New-Object Text.UTF8Encoding($false))); $w.AutoFlush = $true; $script:plC = $c; $script:plW = $w
          }
          $script:plW.WriteLine($l); return
        } catch { try { if ($script:plC) { $script:plC.Dispose() } } catch {}; $script:plW = $null; $script:plC = $null }
      }
      throw 'The SX Player isn''t answering.'
    }
    function Connect-Sx($setup) {
      $st = Get-PlStatus; if (-not $st) { return @{ error = 'The SX Player stopped - start it again on the Lab tab.' } }
      $on = @{}; foreach ($o in @($st.on)) { if ($o) { $on["$($o.slot)"] = 1 } }
      $seen = @{}
      $list = @(foreach ($b in $setup.info.Buttons) { if ($b.Title -and -not $seen[$b.Title]) { $seen[$b.Title] = 1; [pscustomobject]@{ title = $b.Title; page = $b.PageName; pressed = [bool]$on[$b.Sec] } } })
      @{ cn = 'player'; list = $list; error = '' }
    }
    function Send-Cmds($x, $setup, $cmds) {
      foreach ($c in @($cmds)) {
        $t = $c.Substring($c.IndexOf('|') + 1); $on = $c.StartsWith('BUTTON_PRESS')
        Send-PlLine $(if ($on) { "ton $t" } else { "toff $t" })
        foreach ($b in $x.list) { if ($b.title -eq $t) { $b.pressed = $on } }
      }
    }
    function Close-Sx($x) { }
  }
  foreach ($sec in $setup.info.Sections) { if ($sec[0] -match '^page(\d+)$' -and "$($sec[1]['swap'])" -eq 'yes') { $swapPg[[int]$matches[1]] = $true } }
  foreach ($b in $setup.info.Buttons) { if ($b.Title -and -not $swapOf.ContainsKey($b.Title)) { $swapOf[$b.Title] = $(if ($swapPg[$b.Page]) { [int]$b.Page } else { 0 }) } }
  function Get-Eff($l) {
    # ShowXpress "swap" pages play one button at a time: pressing several leaves only the last one on, so press only that one
    $last = @{}; foreach ($x in $l.titles) { $pg = $swapOf[$x]; if ($pg) { $last[$pg] = $x } }
    @($l.titles | Where-Object { -not $swapOf[$_] -or $last[$swapOf[$_]] -eq $_ })
  }
  function Get-Active { @($cfg.looks | Where-Object { $_.on -and @($_.titles).Count }) }
  function Get-Look([string]$id) { if (-not $id) { return $null }; @($cfg.looks | Where-Object { $_.id -eq $id }) | Select-Object -First 1 }
  function Get-Ms($l) { [double]$l.bars * 4 * 60000 / [double]$cfg.bpm }
  function Get-NextId([string]$from) {
    $a = @(Get-Active); if (-not $a.Count) { return '' }
    if ($cfg.order -eq 'shuffle' -and $a.Count -gt 2) {
      $ok = @{}; foreach ($l in $a) { $ok[$l.id] = 1 }
      foreach ($b in @($script:bag)) { if (-not $ok[$b]) { [void]$script:bag.Remove($b) } }
      # a new round: every look once, in a random order (not the one playing now - it was just played)
      if (-not @($script:bag | Where-Object { $_ -ne $from }).Count) { $script:bag.Clear(); foreach ($l in $a) { if ($l.id -ne $from) { $script:bag.Add($l.id) } } }
      $cand = @($script:bag | Where-Object { $_ -ne $from })
      return $cand[(Get-Random -Maximum $cand.Count)]
    }
    $i = -1; for ($k = 0; $k -lt $a.Count; $k++) { if ($a[$k].id -eq $from) { $i = $k } }
    if ($i -lt 0) {   # look switched off / removed: carry on from where it was in the full list
      $all = @($cfg.looks); $j = -1; for ($k = 0; $k -lt $all.Count; $k++) { if ($all[$k].id -eq $from) { $j = $k } }
      if ($j -ge 0) { for ($k = 1; $k -le $all.Count; $k++) { $c = $all[($j + $k) % $all.Count]; if ($c.on -and @($c.titles).Count) { return $c.id } } }
      return $a[0].id
    }
    $a[($i + 1) % $a.Count].id
  }
  function Set-Cur([string]$id, [bool]$remember = $true) {
    if ($remember -and $script:curId -and $script:curId -ne $id) { $script:hist.Add($script:curId); if ($script:hist.Count -gt 50) { $script:hist.RemoveAt(0) } }
    $script:curId = $id; [void]$script:bag.Remove($id); $script:lookStart = $sw.Elapsed.TotalMilliseconds; $script:need = $true; $script:lastTry = -99999.0
    $script:nextId = Get-NextId $id
  }
  function Write-Status {
    if (-not $StatusFile) { return }
    $l = Get-Look $curId; $n = Get-Look $nextId
    $S.lookId = $curId; $S.name = $(if ($l) { $l.name } else { '' }); $S.nextId = $nextId; $S.next = $(if ($n) { $n.name } else { '' }); $S.bpm = $cfg.bpm
    if ($l) {
      $el = $sw.Elapsed.TotalMilliseconds - $lookStart; $beatMs = 60000 / [double]$cfg.bpm
      $S.bars = $l.bars; $S.bar = [math]::Min($l.bars, [int][math]::Floor($el / ($beatMs * 4)) + 1); $S.beat = [int]([math]::Floor($el / $beatMs) % 4) + 1
      $S.msLeft = $(if ($S.held) { -1 } else { [int][math]::Max(0, (Get-Ms $l) - $el) })
    }
    $S.at = (Get-Date).ToString('o')
    $tmp = "$StatusFile.tmp"
    try { [IO.File]::WriteAllText($tmp, ($S | ConvertTo-Json -Depth 4 -Compress)); Move-Item -LiteralPath $tmp -Destination $StatusFile -Force } catch {}
  }
  function Invoke-Look {
    # release what the last look turned on (unless the new look uses it too), then press the new look's buttons
    $l = Get-Look $curId; if (-not $l) { $script:need = $false; return }
    $x = $null
    try {
      $x = Connect-Sx $setup
      if ($x.error) { $S.error = $x.error; $S.applied = $false; return }
      $by = Get-ByTitle $x.list; $cmds = New-Object Collections.Generic.List[string]
      $eff = @(Get-Eff $l)
      $rel = @($mine | Where-Object { $_ -notin $eff })
      if ($script:first -and $cfg.clean) { $rel = @($x.list | Where-Object { $_.pressed -and $_.title -notin $eff -and $_.page -notmatch '^\s*setup\s*$' } | ForEach-Object { $_.title }) + $rel }
      foreach ($t in @($rel | Select-Object -Unique)) { if ($by.ContainsKey($t) -and $by[$t].pressed) { $cmds.Add("BUTTON_RELEASE|$t") } }
      foreach ($t in $eff) { if ($by.ContainsKey($t) -and -not $by[$t].pressed) { $cmds.Add("BUTTON_PRESS|$t") } }
      Send-Cmds $x $setup $cmds
      $script:mine.Clear(); foreach ($t in $eff) { if ($by.ContainsKey($t)) { $script:mine.Add($t) } }
      $S.missing = @($l.titles | Where-Object { -not $by.ContainsKey($_) })
      $S.error = ''; $S.applied = $true; $S.changes++; $script:need = $false; $script:first = $false
    } catch { $S.error = $_.Exception.Message; $S.applied = $false }
    finally { Close-Sx $x }
  }
  function Stop-Player {
    if ($cfg.stop -eq 'off' -and $mine.Count) {
      $x = $null
      try { $x = Connect-Sx $setup; if (-not $x.error) { $by = Get-ByTitle $x.list; Send-Cmds $x $setup @($mine | Where-Object { $by.ContainsKey($_) -and $by[$_].pressed } | ForEach-Object { "BUTTON_RELEASE|$_" }) } } catch {} finally { Close-Sx $x }
    }
    $S.running = $false; Write-Status
  }

  if (-not $usePl -and -not $setup.ready) { $S.running = $false; $S.error = 'The ShowXpress remote is off - turn it on first.'; Write-Status; return }
  if ($usePl) { $ps0 = Get-PlStatus; if ($ps0 -and $ps0.bpm -ge 40) { $cfg.bpm = [math]::Round([double]$ps0.bpm, 1) } }   # the player's tempo wins
  $a0 = @(Get-Active)
  if (-not $a0.Count) { $S.running = $false; $S.error = 'No look to play - add a look with at least one button and switch it on.'; Write-Status; return }
  $startId = "$Titles"   # -Titles <look id> = start with that look
  Set-Cur $(if ($startId -and (Get-Look $startId)) { $startId } else { $a0[0].id }) $false
  # a StreamReader of our own: [Console]::In.ReadLineAsync() blocks on Windows PowerShell
  $rd = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false))); $rl = $rd.ReadLineAsync(); $lastW = -99999.0
  try {
    while ($true) {
      $now = $sw.Elapsed.TotalMilliseconds
      # ---- commands from the Helper
      while ($rl.IsCompleted) {
        $cmd = $rl.Result; if ($null -eq $cmd) { Stop-Player; return }
        $cmd = "$cmd".Trim(); $rl = $rd.ReadLineAsync()
        $w1 = ($cmd -split ' ', 2)[0]; $arg = if ($cmd.Contains(' ')) { $cmd.Substring($cmd.IndexOf(' ') + 1) } else { '' }
        switch ($w1) {
          'q'      { Stop-Player; return }
          'next'   { Set-Cur $(if ($nextId) { $nextId } else { $curId }) }
          'prev'   { if ($hist.Count) { $p = $hist[$hist.Count - 1]; $hist.RemoveAt($hist.Count - 1); if (Get-Look $p) { Set-Cur $p $false } } }
          'go'     { if (Get-Look $arg) { Set-Cur $arg } }
          'hold'   { $S.held = $true }
          'resume' { $S.held = $false; $lookStart = $now }
          'sync'   { $lookStart = $now; if ($usePl) { try { Send-PlLine 'sync' } catch {} } }
          'bpm'    { $b = 0.0; if ([double]::TryParse($arg, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$b) -and $b -ge 40 -and $b -le 220) {
                       $el = ($now - $lookStart) * $cfg.bpm / $b; $cfg.bpm = [math]::Round($b, 1); $lookStart = $now - $el
                       if ($usePl) { try { Send-PlLine ('bpm ' + $b.ToString([Globalization.CultureInfo]::InvariantCulture)) } catch {} } } }
          'reload' { $old = $cfg.bpm; $cfg = Read-AutoCfg; $setup = Get-Setup; if ($usePl) { $cfg.bpm = $old }   # on the player its beat clock keeps the tempo
                     if (-not (Get-Look $curId)) { $a = @(Get-Active); if ($a.Count) { Set-Cur $a[0].id } }
                     else { $need = $true; $lastTry = -99999.0; $nextId = Get-NextId $curId; if ($cfg.bpm -ne $old) { $lookStart = $now - ($now - $lookStart) * $old / $cfg.bpm } } }
        }
      }
      # ---- time for the next look?
      $l = Get-Look $curId
      if ($l -and -not $S.held -and ($now - $lookStart) -ge (Get-Ms $l)) {
        $over = ($now - $lookStart) - (Get-Ms $l)
        Set-Cur $(if ($nextId) { $nextId } else { $curId })
        if ($over -lt 2000) { $lookStart = $now - $over }   # keep counting on the beat (no drift)
      }
      # ---- ShowXpress opened again (a fresh start has nothing pressed): play the current look again
      if ($now - $lastOpen -gt 2000) {
        $lastOpen = $now; $sp = 0
        if ($usePl) { if (Test-Path -LiteralPath $PlayerStatus) { $sp = 1 } }
        elseif ($TestRoot) { if (Test-Open) { $sp = 1 } } else { $pr = @(Get-SxProcess) | Select-Object -First 1; if ($pr) { $sp = $pr.Id } }
        if ($sp -ne $sxPid) {
          if ($sp) { $need = $true; $lastTry = -99999.0; $mine.Clear() }
          else { $S.applied = $false; $S.error = $(if ($usePl) { 'The SX Player stopped - waiting for it (the looks keep counting).' } else { 'ShowXpress is closed - waiting for it (the looks keep counting).' }) }
          $sxPid = $sp
        }
      }
      # ---- on the player: follow its tempo (tap / VirtualDJ / the Lab)
      if ($usePl -and $now - $lastPl -ge 500) {
        $lastPl = $now; $ps = Get-PlStatus
        if ($ps -and $ps.bpm -ge 40) {
          $S.src = "$($ps.src)"; $b = [math]::Round([double]$ps.bpm, 1)
          if ([math]::Abs($b - $cfg.bpm) -ge 0.1) { $lookStart = $now - ($now - $lookStart) * $cfg.bpm / $b; $cfg.bpm = $b }
        }
      }
      if ($need -and $sxPid -and ($now - $lastTry) -gt 3000) { $lastTry = $now; Invoke-Look; $lastW = -99999.0 }
      if ($now - $lastW -ge 250) { $lastW = $now; Write-Status }
      Start-Sleep -Milliseconds 40
    }
  } catch { $S.running = $false; $S.error = "Auto Show stopped: $($_.Exception.Message)"; Write-Status; throw }
}

# ---------------------------------------------------------------- State / Press / Release / Off
$setup = Get-Setup
$st = [ordered]@{ ok = $true; ready = $setup.ready; open = (Test-Open); connected = $false; pressed = @(); titles = @(); error = ''; setup = (Get-SetupJson $setup)
                  pressedNow = @(); released = @(); missing = @(); skipped = $false; playing = @() }
$x = Connect-Sx $setup
try {
  if ($x.error) { $st.error = $x.error; $st | ConvertTo-Json -Depth 5 -Compress; return }
  $st.connected = $true
  $list = $x.list; $by = Get-ByTitle $list
  $cmds = New-Object Collections.Generic.List[string]
  if ($Action -eq 'Press') {
    $st.missing = @($want | Where-Object { -not $by.ContainsKey($_) })
    $other = @($list | Where-Object { $_.pressed -and $_.title -notin $want })
    if ($Idle) {
      $st.playing = @($other | Where-Object { $_.page -notmatch '^\s*setup\s*$' } | ForEach-Object { $_.title } | Select-Object -Unique)
      if ($st.playing.Count) { $st.skipped = $true }
    }
    if (-not $st.skipped) {
      if ($Solo) { foreach ($b in $other) { $cmds.Add("BUTTON_RELEASE|$($b.title)"); $st.released += $b.title } }
      else { foreach ($t in @("$Release" -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notin $want } | Select-Object -Unique)) {
               if ($by.ContainsKey($t) -and $by[$t].pressed) { $cmds.Add("BUTTON_RELEASE|$t"); $st.released += $t } } }
      foreach ($t in $want) { if ($by.ContainsKey($t) -and -not $by[$t].pressed) { $cmds.Add("BUTTON_PRESS|$t"); $st.pressedNow += $t } }
    }
  } elseif ($Action -eq 'Release') {
    foreach ($t in $want) { if ($by.ContainsKey($t) -and $by[$t].pressed) { $cmds.Add("BUTTON_RELEASE|$t"); $st.released += $t } }
  } elseif ($Action -eq 'Off') {
    foreach ($b in @($list | Where-Object { $_.pressed })) { $cmds.Add("BUTTON_RELEASE|$($b.title)"); $st.released += $b.title }
  }
  Send-Cmds $x $setup $cmds
  $st.pressed = @($x.list | Where-Object { $_.pressed } | ForEach-Object { [ordered]@{ title = $_.title; page = $_.page } })
  $st.titles = @($x.list | ForEach-Object { $_.title } | Select-Object -Unique)
  $st | ConvertTo-Json -Depth 5 -Compress
} finally { Close-Sx $x }
