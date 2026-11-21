# DF AIM - weekly mover placement + per-head sizing for the dancefloor movement scenes.
#
#   ShowXpress Editor -> scene "DF AIM (ADJUST)" (every 140SR / 251SR = tight white beam):
#     STEP 1 = CENTER : aim every head at the center of tonight's dancefloor.
#     STEP 2 = CORNER : (optional per head) aim the head at the SAME corner of the floor every time
#                       (front-left as seen from the DJ). Heads left untouched in step 2 keep normal size.
#   Close ShowXpress, open ShowXpress Helper (df_aim_gui.ps1 = the window; this file does the work), set size, Apply.
#   (Run on its own = old text menu: pick 1, type overall size, Enter = 100.)
#     - center  -> per head OffsetPan/OffsetTilt   (aim - home)
#     - corner  -> per head ZoomPan/ZoomTilt so that head's patterns reach the corner you showed it
#                  (MEASURED 2026-11-18: ShowXpress size factor = (1 + Zoom/100)^2  =>  Zoom = 100*(sqrt(k)-1))
#     - size %  -> scales every shared pattern shape around its center, from the ORIGINAL shapes
#                  (kept in df_aim_state.json) so it never stacks. 100 = patterns fill to the corners.
#   AUTO-SYMMETRY: a shape changed in Generator since the last run (dragged / points moved / new scene) is
#                  re-made symmetrical (size averaged from its points) and centered on home - see $autoSym.
#   Targets: every live page named "...MOVEMENT..." (MOVEMENTS + 251s movement) + DF CHECK 140/251.
#   Never touched: 251 Ceiling, Around Room* (room coverage).  DF CHECK* = aim + zoom, never resized:
#   each head traces the 4 corners of the floor it was given -> quick visual check.
#
#   CENTER SPOT: Apply (Floor or Room) also copies each head's step-1 CENTER aim into the CENTER SPOT scene
#                (pan/tilt only; heads still on home are left alone). Home doesn't touch CENTER SPOT.
#
#   -Action Apply [-Size "100" | "120 90"]   -Action Home (all corrections off, size 100)
#
#   -Mode Room = the same thing for the AROUND ROOM movements (walls / ceiling): scene "ROOM AIM (ADJUST)" (step 1 = center
#   of the area to cover, step 2 = the same corner of it), check "ROOM CHECK" (Generator), state room_aim_state.json.
#   "Normal" for the room = the middle and size of the original AROUND ROOM shape.  -Action Install = ROOM AIM (ADJUST) +
#   ROOM CHECK made and put on the SETUP page (under DF AIM / DF CHECK).
param(
  [ValidateSet('Apply','Home','Menu','Preview','Install')][string]$Action = 'Menu',   # Preview = JSON for the GUI, writes nothing
  [ValidateSet('Floor','Room')][string]$Mode = 'Floor',
  [string]$Size = '',
  [switch]$NoPrompt,
  [switch]$Force,          # apply even if some aims look wrong (GUI "apply anyway")
  [string]$TestRoot = ""   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
# Show folder lookup, mover list and the 140/251 model names are shared with skip_flash.ps1:
. (Join-Path $PSScriptRoot 'show_common.ps1')   # Find-Show, Test-SxRunning, Get-ShowMovers, Get-Label, $m140, $m251
$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/Live/live.ini")) { throw "Show not found at '$root'. NOTHING was changed." }
$gdir    = "$root/Editor/Generator/projects"
$scene   = "$root/scenes/DF AIM (ADJUST).scex"
# state (original pattern shapes) lives in the show folder so it travels with the show to the Mac
$stateF  = "$root/df_aim_state.json"
# Home = where the shapes are centered when offsets are 0 (16-bit pan,tilt).
$homePos = @{ $m140 = @(22600, 49700); $m251 = @(34200, 10000) }
# Reference half-size of the dancefloor at home (16-bit pan,tilt from center to corner) = typical
# half-extent of the user's dancefloor patterns. A corner aimed exactly this far away = zoom 0.
$refHalf = @{ $m140 = @(3600, 3400); $m251 = @(4500, 5000) }
$pageRx  = '(?i)movement'          # live pages found BY NAME (MOVEMENTS + 251s movement) - page numbers move
$skip    = @('251 Ceiling', 'Around Room')  # never touch: not dancefloor looks (Around Room = room
                                           # coverage from the physically crossed pairs; user 2026-11-18)
$noScale = @('DF CHECK*')          # shared shape never resized
$noZoom  = @()                     # per-head zoom stays 0
$checks  = @{ 'DF CHECK 140.gpj' = $m140; 'DF CHECK 251.gpj' = $m251 }
# AUTO-SYMMETRY (user 2026-11-18): any shape that was changed in Generator since the last run (dragged,
# points moved, new scene) is re-made symmetrical left/right + up/down (size kept) and centered on home.
# Placement comes only from the DF AIM center aims, never from the shapes.
$autoSym  = $true
$moveOnly = @('*GALAXY SPIRAL*')   # not mirror-symmetrical by design -> only moved back to its center
$symTol   = 0.5                       # a side may be off by up to 50% of the half-size and still be "meant symmetrical"
$kMin = 0.3; $kMax = 3.0
$aimTitle = 'DF AIM (ADJUST)'; $checkTitle = 'DF CHECK 140 / DF CHECK 251'
if ($Mode -eq 'Room') {
  $aimTitle = 'ROOM AIM (ADJUST)'; $checkTitle = 'ROOM CHECK'
  $scene  = "$root/scenes/ROOM AIM (ADJUST).scex"
  $stateF = "$root/room_aim_state.json"
  $roomFiles = @(Get-ChildItem -LiteralPath $gdir -Filter '*.gpj' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AROUND ROOM*' } | Sort-Object Name | ForEach-Object Name)
  if (-not $roomFiles.Count) { throw "No AROUND ROOM movement found in Generator. NOTHING was changed." }
  $roomMain = if ($roomFiles -contains 'AROUND ROOM.gpj') { 'AROUND ROOM.gpj' } else { $roomFiles[0] }
  # normal = middle + half-size of the ORIGINAL AROUND ROOM shape (from the state if it was already resized)
  $rt = [IO.File]::ReadAllText("$gdir/$roomMain"); $ptsS = ''
  if (Test-Path -LiteralPath $stateF) { $sj = [IO.File]::ReadAllText($stateF) | ConvertFrom-Json; if ($sj.files.$roomMain) { $ptsS = "$($sj.files.$roomMain.base)" } }
  if (-not $ptsS) {
    $ptSec = (($rt -split '\[Pan/Tilt/uPan/uTilt\]')[1] -split '\r?\n\[')[0]
    $ptsS = (@([regex]::Matches($ptSec, 'Point_\d+ = (-?\d+),(-?\d+)') | ForEach-Object { "$($_.Groups[1].Value),$($_.Groups[2].Value)" }) -join ';')
  }
  $rp = @($ptsS -split ';' | ForEach-Object { $xy = $_ -split ','; ,@([double]$xy[0], [double]$xy[1]) })
  $mx = $rp | ForEach-Object { $_[0] } | Measure-Object -Minimum -Maximum; $my = $rp | ForEach-Object { $_[1] } | Measure-Object -Minimum -Maximum
  $rh = @([int](($mx.Minimum + $mx.Maximum) / 2), [int](($my.Minimum + $my.Maximum) / 2))
  $rr = @([int][math]::Max(500, ($mx.Maximum - $mx.Minimum) / 2), [int][math]::Max(500, ($my.Maximum - $my.Minimum) / 2))
  $homePos = @{ $m140 = $rh; $m251 = $rh }; $refHalf = @{ $m140 = $rr; $m251 = $rr }
  $roomIds = @([regex]::Matches($rt, '(?m)^ID = (\d+)') | ForEach-Object { $_.Groups[1].Value })
  $checks = @{ 'ROOM CHECK.gpj' = $m140 }
  $noScale = @('ROOM CHECK*'); $autoSym = $false
}

function Test-SxClosed {
  if ($TestRoot) { return }
  if (Test-SxRunning) {
    throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and run this again."
  }
}

function Test-Like($name, $patterns) { [bool]($patterns | Where-Object { $name -like $_ }) }

function Get-Movers { if ($Mode -eq 'Room') { Get-ShowMovers $root | Where-Object { $roomIds -contains $_.Id } } else { Get-ShowMovers $root } }

function Get-DefaultCorner($m) { $h = $homePos[$m.Model]; $r = $refHalf[$m.Model]; @(($h[0] - $r[0]), ($h[1] + $r[1])) }

function Write-AimScene($movers, $center, $corner) {
  # $center / $corner: hashtable id -> @(pan16, tilt16).  Step 1 = center, step 2 = corner.
  $L = New-Object Collections.Generic.List[string]
  $L.Add('<?xml version="1.0" encoding="UTF-8"?>'); $L.Add(''); $L.Add('<Scene>'); $L.Add('  <Fixtures>')
  foreach ($m in $movers) { $L.Add("    <Fixture id=`"$($m.Id)`" name=`"$($m.Name)`" model=`"$($m.Model)`"/>") }
  $L.Add('  </Fixtures>'); $L.Add('  <Steps>')
  foreach ($pos in @($center, $corner)) {
    $L.Add('    <Step length="300">')
    foreach ($m in $movers) {
      $p = [int]$pos[$m.Id][0]; $t = [int]$pos[$m.Id][1]
      $ch = @(
        @(0,'pan',[math]::Floor($p/256),1), @(1,'upan',($p%256),1), @(2,'tilt',[math]::Floor($t/256),1), @(3,'utilt',($t%256),1),
        @(4,'pantilt_speed',0,0), @(5,'color',0,0))
      if ($m.Is140) {
        $ch += ,@(6,'gobo',0,0); $ch += ,@(7,'gobo#2',0,0); $ch += ,@(8,'gobo_rotate',0,0)
        $ch += ,@(9,'8 facet prism',0,0); $ch += ,@(10,'linear prism',0,0); $ch += ,@(13,'zoom',243,0); $ch += ,@(14,'frost',0,0)
      } else {
        $ch += ,@(6,'gobo',0,0); $ch += ,@(7,'gobo2',0,0); $ch += ,@(8,'gobo_rotate',0,0)
        $ch += ,@(9,'prism',0,0); $ch += ,@(10,'prism2',0,0); $ch += ,@(11,'focus',38,0); $ch += ,@(13,'zoom',255,0); $ch += ,@(14,'frost',0,0)
      }
      $ch += ,@(15,'dimmer',255,0); $ch += ,@(16,'shutter',255,0)
      $L.Add("      <Fixture id=`"$($m.Id)`">")
      foreach ($c in $ch) {
        $fade = if ($c[3]) { ' fade="1"' } else { '' }
        $L.Add("        <Channel index=`"$($c[0])`" name=`"$($c[1])`" value=`"$($c[2])`"$fade/>")
      }
      $L.Add('      </Fixture>')
    }
    $L.Add('    </Step>')
  }
  $L.Add('  </Steps>'); $L.Add('</Scene>')
  [IO.File]::WriteAllText($scene, (($L -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Read-Step($step, $m, $default) {
  $v = @{ pan = [math]::Floor($default[0]/256); upan = $default[0]%256; tilt = [math]::Floor($default[1]/256); utilt = $default[1]%256 }
  if ($step) {
    $fx = @($step.Fixture | Where-Object { $_.GetAttribute('id') -eq $m.Id })
    if ($fx.Count) { foreach ($c in $fx[0].Channel) { $cn = $c.GetAttribute('name'); if ($v.ContainsKey($cn)) { $v[$cn] = [int]$c.GetAttribute('value') } } }
  }
  @(($v.pan*256 + $v.upan), ($v.tilt*256 + $v.utilt))
}

function Read-AimScene($movers) {
  if (-not (Test-Path $scene)) { throw "Aim scene not found: $scene" }
  [xml]$x = [IO.File]::ReadAllText($scene)
  $steps = @($x.Scene.Steps.Step)
  $r = @{ center = @{}; corner = @{}; steps = $steps.Count }
  foreach ($m in $movers) {
    $r.center[$m.Id] = Read-Step $steps[0] $m $homePos[$m.Model]
    $s2 = if ($steps.Count -ge 2) { $steps[1] } else { $null }
    $r.corner[$m.Id] = Read-Step $s2 $m (Get-DefaultCorner $m)
  }
  $r
}

function Get-HeadFix($movers, $center, $corner, [switch]$Reset) {
  # id -> @{ op; ot; zp; zt; kp; kt; sized; warn }
  $out = @{}
  foreach ($m in $movers) {
    $h = $homePos[$m.Model]; $r = $refHalf[$m.Model]; $c = $center[$m.Id]; $k = $corner[$m.Id]
    $o = @{ op = 0; ot = 0; zp = 0; zt = 0; kp = 1.0; kt = 1.0; sized = $false; warn = '' }
    if (-not $Reset) {
      $o.op = [int][math]::Max(-32767, [math]::Min(32767, $c[0] - $h[0]))
      $o.ot = [int][math]::Max(-32767, [math]::Min(32767, $c[1] - $h[1]))
      if ([math]::Abs($c[0] - $h[0]) -gt 32767 -or [math]::Abs($c[1] - $h[1]) -gt 32767) { $o.warn = 'CENTER TOO FAR from normal - check this head''s step 1 aim' }
      $dc = Get-DefaultCorner $m
      if ($k[0] -ne $dc[0] -or $k[1] -ne $dc[1]) {
        $o.sized = $true
        $kp = [math]::Abs($k[0] - $c[0]) / $r[0]; $kt = [math]::Abs($k[1] - $c[1]) / $r[1]
        if ($kp -lt $kMin -or $kp -gt $kMax -or $kt -lt $kMin -or $kt -gt $kMax) { $o.warn = 'corner very close/far - size limited, check this head' }
        $o.kp = [math]::Max($kMin, [math]::Min($kMax, $kp)); $o.kt = [math]::Max($kMin, [math]::Min($kMax, $kt))
        $o.zp = [int][math]::Round(100 * ([math]::Sqrt($o.kp) - 1)); $o.zt = [int][math]::Round(100 * ([math]::Sqrt($o.kt) - 1))
      }
    }
    $out[$m.Id] = $o
  }
  $out
}

function Get-TargetGpjs {
  if ($Mode -eq 'Room') { return @($roomFiles + @($checks.Keys) | Select-Object -Unique) }
  $lt = Get-Content "$root/Live/live.ini" -Encoding UTF8
  $pages = @(); $pg = $null
  foreach ($l in $lt) {
    if ($l -match '^\[(page\d+)\]$') { $pg = $matches[1]; continue }
    if ($l -match '^\[') { $pg = $null; continue }
    if ($pg -and $l -match '^name = (.*)$' -and $matches[1] -match $pageRx) { $pages += $pg; $pg = $null }
  }
  if (-not $pages.Count) { throw "No MOVEMENTS page found in live.ini. NOTHING was changed." }
  $files = @(); $on = $false
  $rx = '^\[(' + ($pages -join '|') + ')_button\d+\]$'
  foreach ($l in $lt) {
    if ($l -match '^\[') { $on = $l -match $rx; continue }
    if ($on -and $l -match '^name = (.+\.gpj)$') { $files += $matches[1] }
  }
  $files += @($checks.Keys | Sort-Object)
  @($files | Select-Object -Unique | Where-Object { -not (Test-Like $_ ($skip | ForEach-Object { "$_*" })) })
}

function Get-FixtureSections($file) {
  # returns list of fixture sections (each = list of lines) from a gpj
  $res = New-Object Collections.Generic.List[object]; $buf = $null
  foreach ($l in ([IO.File]::ReadAllText($file) -split "`r?`n")) {
    if ($l -match '^\[') { if ($buf) { $res.Add($buf) }; $buf = $null; if ($l -match '^\[Fixture_\d+\]$') { $buf = New-Object Collections.Generic.List[string]; $buf.Add($l) }; continue }
    if ($buf -and $l) { $buf.Add($l) }
  }
  if ($buf) { $res.Add($buf) }
  $res
}

function New-CheckGpj($name, $model, $movers) {
  # 4-corner trace of the reference floor for every head of one model (points mode, 1 s per corner)
  $path = "$gdir/$name"; if (Test-Path $path) { return }
  $ids = @($movers | Where-Object { $_.Model -eq $model } | ForEach-Object { $_.Id })
  $secs = @{}
  foreach ($f in (Get-ChildItem $gdir -Filter *.gpj)) {
    foreach ($s in (Get-FixtureSections $f.FullName)) { $id = ($s | Where-Object { $_ -match '^ID = ' }) -replace '^ID = ', ''; if ($id -and -not $secs.ContainsKey($id)) { $secs[$id] = $s } }
  }
  $out = New-Object Collections.Generic.List[string]
  'PanTiltShift = 0.0','ExplodePanTilt = 0','GroupRGB = 0','FanPanOffset = 0','FanTiltOffset = 0' | ForEach-Object -Begin { $out.Add('[Params]') } -Process { $out.Add($_) }
  $k = 0; $chList = $null
  foreach ($m in ($movers | Where-Object { $_.Model -eq $model })) {
    $s = $secs[$m.Id]; if (-not $s) { throw "No generator template found for $($m.Name)" }
    foreach ($l in $s) {
      if ($l -match '^\[Fixture_') { $l = "[Fixture_$k]" }
      elseif ($l -match '^(Offset|Zoom|Reverse)(Pan|Tilt) = ') { $l = ($l -replace '= .*$', '= 0') }
      elseif ($l -match '^Channels = (.*)$' -and -not $chList) { $chList = $matches[1] -split ',' }
      $out.Add($l)
    }
    $k++
  }
  $h = $homePos[$model]; $r = $refHalf[$model]
  $pts = @(@(($h[0]-$r[0]), ($h[1]+$r[1])), @(($h[0]+$r[0]), ($h[1]+$r[1])), @(($h[0]+$r[0]), ($h[1]-$r[1])), @(($h[0]-$r[0]), ($h[1]-$r[1])))
  $out.Add('[Pan/Tilt/uPan/uTilt]'); 'Selected = 1','CurveName = Default Curve','Transition = 0','Duration = 40','Shift = 0.0' | ForEach-Object { $out.Add($_) }
  for ($i = 0; $i -lt 4; $i++) { $out.Add("Point_$i = $($pts[$i][0]),$($pts[$i][1])") }
  $fixed = @{ 'pantilt_speed' = 0; 'color' = 0; 'gobo' = 0; 'gobo#2' = 0; 'gobo2' = 0; 'gobo_rotate' = 0; '8 facet prism' = 0; 'linear prism' = 0; 'prism' = 0; 'prism2' = 0; 'frost' = 0; 'dimmer' = 65535; 'shutter' = 65535 }
  if ($model -eq $m140) { $fixed['zoom'] = 62451 } else { $fixed['zoom'] = 65535; $fixed['focus'] = 9766 }
  foreach ($c in ($chList | Where-Object { $_ -notin @('pan','upan','tilt','utilt') })) {
    $out.Add("[$c]")
    if ($fixed.ContainsKey($c)) { $v = $fixed[$c]; 'Selected = 1','CurveName = Default Curve','Transition = 0','Duration = 50','Shift = 0.0',"Point_0 = 0,$v","Point_1 = 65535,$v" | ForEach-Object { $out.Add($_) } }
    else { 'Selected = 0','CurveName = Default Curve','Transition = 0','Duration = 50','Shift = 0.0','Point_0 = 0,65535','Point_1 = 65535,65535' | ForEach-Object { $out.Add($_) } }
  }
  [IO.File]::WriteAllText($path, (($out -join "`n") + "`n"), (New-Object Text.UTF8Encoding($true)))
  "  created $name ($k heads)"
}

function Load-State {
  $st = @{ sx = 1.0; sy = 1.0; files = @{} }
  if (Test-Path $stateF) {
    $j = [IO.File]::ReadAllText($stateF) | ConvertFrom-Json
    $st.sx = [double]$j.sx; $st.sy = [double]$j.sy
    foreach ($p in $j.files.PSObject.Properties) {
      $st.files[$p.Name] = @{ base = [string]$p.Value.base; written = [string]$p.Value.written; sx = [double]$p.Value.sx; sy = [double]$p.Value.sy }
    }
  }
  $st
}

function Save-State($st) {
  $files = [ordered]@{}
  foreach ($k in ($st.files.Keys | Sort-Object)) { $files[$k] = [pscustomobject]$st.files[$k] }
  $o = [pscustomobject]@{ sx = $st.sx; sy = $st.sy; files = [pscustomobject]$files }
  [IO.File]::WriteAllText($stateF, ($o | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-Pts([string]$s) { ,@($s -split ';' | ForEach-Object { $xy = $_ -split ','; ,@([double]$xy[0], [double]$xy[1]) }) }
function ConvertFrom-Pts($pts) { ($pts | ForEach-Object { "{0},{1}" -f [int][math]::Round($_[0]), [int][math]::Round($_[1]) }) -join ';' }

function Scale-Pts($pts, [double]$sx, [double]$sy) {
  $xs = $pts | ForEach-Object { $_[0] }; $ys = $pts | ForEach-Object { $_[1] }
  $mx = $xs | Measure-Object -Minimum -Maximum; $my = $ys | Measure-Object -Minimum -Maximum
  $cx = ($mx.Minimum + $mx.Maximum) / 2; $cy = ($my.Minimum + $my.Maximum) / 2
  ,@($pts | ForEach-Object { ,@(($cx + ($_[0] - $cx) * $sx), ($cy + ($_[1] - $cy) * $sy)) })
}

function Get-Mirror($pts, [int]$a) {
  # mirror-average a shape across its center on axis $a (0 = left/right, 1 = up/down).
  # Pairs each point with the point nearest its mirror image (greedy, closest pairs first).
  $o = 1 - $a; $v = @($pts | ForEach-Object { $_[$a] })
  $mm = $v | Measure-Object -Minimum -Maximum; $c = ($mm.Minimum + $mm.Maximum) / 2; $half = ($mm.Maximum - $mm.Minimum) / 2
  if ($half -lt 50) { return @{ ok = $true; pts = @($pts | ForEach-Object { $q = @([double]$_[0], [double]$_[1]); $q[$a] = $c; ,$q }) } }
  $n = $pts.Count; $pairs = New-Object Collections.Generic.List[object]
  for ($i = 0; $i -lt $n; $i++) { for ($j = $i; $j -lt $n; $j++) {
    $da = (2 * $c - $pts[$i][$a]) - $pts[$j][$a]; $do = $pts[$i][$o] - $pts[$j][$o]
    $pairs.Add([pscustomobject]@{ d = [math]::Sqrt($da * $da + $do * $do); i = $i; j = $j }) } }
  $part = @(-1) * $n; $maxd = 0
  foreach ($p in ($pairs | Sort-Object d, i, j)) {
    if ($part[$p.i] -eq -1 -and $part[$p.j] -eq -1) { $part[$p.i] = $p.j; $part[$p.j] = $p.i; if ($p.d -gt $maxd) { $maxd = $p.d } }
  }
  if ($maxd -gt $symTol * $half) { return @{ ok = $false } }
  $new = @(for ($i = 0; $i -lt $n; $i++) { $j = $part[$i]; $q = @(0.0, 0.0)
    $q[$a] = ($pts[$i][$a] + 2 * $c - $pts[$j][$a]) / 2; $q[$o] = ($pts[$i][$o] + $pts[$j][$o]) / 2; ,$q })
  @{ ok = $true; pts = $new }
}

function Get-SymShape($pts, $hm, $master, [bool]$onlyMove) {
  # symmetrical + centered version of a changed shape. Axis that isn't meant symmetrical -> only moved
  # back to where the last clean shape had its center (or home for a new scene).
  $out = $pts; $done = @($false, $false)
  if (-not $onlyMove) { foreach ($a in 0, 1) { $r = Get-Mirror $out $a; if ($r.ok) { $out = $r.pts; $done[$a] = $true } } }
  $shift = @(0.0, 0.0)
  foreach ($a in 0, 1) {
    $mm = $out | ForEach-Object { $_[$a] } | Measure-Object -Minimum -Maximum; $c = ($mm.Minimum + $mm.Maximum) / 2
    $t = $hm[$a]
    if (-not $done[$a] -and $master) { $m2 = $master | ForEach-Object { $_[$a] } | Measure-Object -Minimum -Maximum; $t = ($m2.Minimum + $m2.Maximum) / 2 }
    $shift[$a] = $t - $c
  }
  $out = @($out | ForEach-Object { ,@(($_[0] + $shift[0]), ($_[1] + $shift[1])) })
  $note = if ($done[0] -and $done[1]) { ' (changed in Generator -> made symmetrical + centered)' }
          elseif ($done[0]) { ' (changed in Generator -> made symmetrical left/right + centered)' }
          elseif ($done[1]) { ' (changed in Generator -> made symmetrical up/down + centered)' }
          else { ' (changed in Generator -> moved back to center, shape kept)' }
  @{ pts = $out; note = $note }
}

function Update-Gpjs($fix, [double]$sx, [double]$sy, $st) {
  # $fix: id -> head fix (offsets + zooms); sx/sy = overall shape size (1 = original)
  $files = Get-TargetGpjs; $total = 0; $warn = @()
  foreach ($f in $files) {
    $path = "$gdir/$f"; if (-not (Test-Path $path)) { $warn += "missing: $f"; continue }
    $useZoom = -not (Test-Like $f $noZoom); $scaleThis = -not (Test-Like $f $noScale)
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [IO.File]::ReadAllText($path)
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = $text -split "`r?`n"; $id = $null; $firstId = $null; $sec = ''; $n = 0; $ptIdx = @(); $ptNames = @(); $cur = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $ln = $lines[$i]
      if ($ln -match '^\[(.*)\]$') { $sec = $matches[1]; $id = $null; continue }
      if ($sec -eq 'Pan/Tilt/uPan/uTilt' -and $ln -match '^(Point_\d+) = (-?\d+),(-?\d+)$') {
        $ptIdx += $i; $ptNames += $matches[1]; $cur += ,@([double]$matches[2], [double]$matches[3]); continue
      }
      if ($ln -match '^ID = (\d+)$') { $id = $matches[1]; if (-not $firstId) { $firstId = $id }; continue }
      if ($id -and $fix.ContainsKey($id)) {
        $hf = $fix[$id]; $new = $null
        if ($ln -match '^Reverse(Pan|Tilt) = 1$') { $warn += "$f : fixture $id has Reverse$($matches[1]) on - check that head by eye" }
        if ($ln -match '^OffsetPan = ')  { $new = "OffsetPan = $($hf.op)" }
        if ($ln -match '^OffsetTilt = ') { $new = "OffsetTilt = $($hf.ot)" }
        if ($ln -match '^ZoomPan = ')    { $new = "ZoomPan = $(if ($useZoom) { $hf.zp } else { 0 })" }
        if ($ln -match '^ZoomTilt = ')   { $new = "ZoomTilt = $(if ($useZoom) { $hf.zt } else { 0 })" }
        if ($new -and $ln -ne $new) { $lines[$i] = $new; $n++ }
      }
    }
    # ---- overall size of the shared shape
    $note = ''
    if ($cur.Count -ge 2) {
      $curS = ConvertFrom-Pts $cur
      $rec = $st.files[$f]
      if ($rec -and $rec.written -eq $curS) { $base = ConvertTo-Pts $rec.base }
      else {
        # shape changed in Generator since the last run (or a scene the tool hasn't seen yet)
        $base = if ($rec -and ($rec.sx -ne 1 -or $rec.sy -ne 1)) { Scale-Pts $cur (1 / $rec.sx) (1 / $rec.sy) } else { $cur }
        $mv = @($movers | Where-Object { $_.Id -eq $firstId }); $model = if ($mv.Count) { $mv[0].Model } else { $null }
        if ($checks.ContainsKey($f)) {
          if ($cur.Count -eq 4) {   # DF CHECK = always the exact reference floor
            $h = $homePos[$checks[$f]]; $r = $refHalf[$checks[$f]]
            $base = @(@(($h[0]-$r[0]), ($h[1]+$r[1])), @(($h[0]+$r[0]), ($h[1]+$r[1])), @(($h[0]+$r[0]), ($h[1]-$r[1])), @(($h[0]-$r[0]), ($h[1]-$r[1])))
            if ($rec) { $note = ' (changed in Generator -> reset)' }
          }
        }
        elseif ($autoSym -and $model) {
          $master = if ($rec) { ConvertTo-Pts $rec.base } else { $null }
          $sym = Get-SymShape $base $homePos[$model] $master (Test-Like $f $moveOnly)
          $base = $sym.pts; $note = $sym.note
        }
        elseif ($rec) { $note = ' (your shape edit kept)' }
        if (-not $rec -and -not $note) { $note = ' (new scene)' }
      }
      $fx = if ($scaleThis) { $sx } else { 1.0 }; $fy = if ($scaleThis) { $sy } else { 1.0 }
      $newPts = if ($fx -eq 1 -and $fy -eq 1) { $base } else { Scale-Pts $base $fx $fy }
      $clip = $false
      $newPts = @($newPts | ForEach-Object {
        $x = [math]::Round($_[0]); $y = [math]::Round($_[1])
        if ($x -lt 0 -or $x -gt 65535 -or $y -lt 0 -or $y -gt 65535) { $clip = $true }
        ,@([math]::Max(0, [math]::Min(65535, $x)), [math]::Max(0, [math]::Min(65535, $y))) })
      if ($clip) { $warn += "$f : pattern hit the pan/tilt limit at this size - edges flattened" }
      for ($k = 0; $k -lt $ptIdx.Count; $k++) {
        $new = "{0} = {1},{2}" -f $ptNames[$k], [int]$newPts[$k][0], [int]$newPts[$k][1]
        if ($lines[$ptIdx[$k]] -ne $new) { $lines[$ptIdx[$k]] = $new; $n++ }
      }
      $st.files[$f] = @{ base = (ConvertFrom-Pts $base); written = (ConvertFrom-Pts $newPts); sx = $fx; sy = $fy }
    }
    if (-not $useZoom) { $note += ' (aim only)' } elseif (-not $scaleThis) { $note += ' (aim + per-head size)' }
    if ($n) { [IO.File]::WriteAllText($path, ($lines -join $nl), (New-Object Text.UTF8Encoding($bom))) }
    $total += $n
    "  {0,-46} {1,3} values changed{2}" -f $f, $n, $note
  }
  "  -> $($files.Count) movement scenes checked, $total values written"
  $warn | Select-Object -Unique | ForEach-Object { "  WARNING: $_" }
}

function Update-CenterSpot($movers, $center) {
  # CENTER SPOT scene: every head that was aimed in step 1 tonight (aim != home) gets that step-1 aim as its
  # pan/tilt, so the spot lands on tonight's center without setting it up by hand. Only pan/upan/tilt/utilt
  # are touched (colour, dimmer, zoom ... kept); a missing channel is added. Heads still on home = left as they are.
  $cs = "$root/scenes/CENTER SPOT.scex"; if (-not (Test-Path -LiteralPath $cs)) { $cs = "$root/scenes/CENTER SPOT (adjust).scex" }
  if (-not (Test-Path -LiteralPath $cs)) { return "  WARNING: scene CENTER SPOT not found - not updated" }
  $want = @{}
  foreach ($m in $movers) {
    $c = $center[$m.Id]; $h = $homePos[$m.Model]
    if ($c[0] -eq $h[0] -and $c[1] -eq $h[1]) { continue }   # not aimed in step 1
    $p = [int]$c[0]; $t = [int]$c[1]
    $want[$m.Id] = @{ 0 = @('pan', [int][math]::Floor($p/256)); 1 = @('upan', ($p%256)); 2 = @('tilt', [int][math]::Floor($t/256)); 3 = @('utilt', ($t%256)) }
  }
  $bytes = [IO.File]::ReadAllBytes($cs)
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $text = [IO.File]::ReadAllText($cs)
  $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $src = $text -split "`r?`n"; $out = New-Object Collections.Generic.List[string]
  $inSteps = $false; $blk = $null; $bid = $null; $n = 0; $heads = @{}
  foreach ($ln in $src) {
    if ($ln -match '^\s*<Steps>') { $inSteps = $true }
    if ($inSteps -and -not $blk -and $ln -match '^\s*<Fixture id="(\d+)">\s*$') {
      $bid = $matches[1]; $blk = New-Object Collections.Generic.List[string]; $blk.Add($ln); continue
    }
    if ($blk) {
      if ($ln -notmatch '^\s*</Fixture>') { $blk.Add($ln); continue }
      if ($want.ContainsKey($bid)) {
        $w = $want[$bid]; $seen = @{}; $ind = '        '
        for ($i = 1; $i -lt $blk.Count; $i++) {
          if ($blk[$i] -match '^(\s*)<Channel index="(\d+)"') {
            $ind = $matches[1]; $ix = [int]$matches[2]
            if ($w.ContainsKey($ix)) {
              $seen[$ix] = $true
              $new = $blk[$i] -replace 'value="\d+"', "value=`"$($w[$ix][1])`""
              if ($new -ne $blk[$i]) { $blk[$i] = $new; $n++; $heads[$bid] = $true }
            }
          }
        }
        foreach ($ix in 0, 1, 2, 3) {
          if ($seen[$ix]) { continue }
          # insert in index order
          $at = $blk.Count
          for ($i = 1; $i -lt $blk.Count; $i++) { if ($blk[$i] -match '<Channel index="(\d+)"' -and [int]$matches[1] -gt $ix) { $at = $i; break } }
          $blk.Insert($at, "$ind<Channel index=`"$ix`" name=`"$($w[$ix][0])`" value=`"$($w[$ix][1])`" fade=`"1`"/>"); $n++; $heads[$bid] = $true
        }
      }
      foreach ($b in $blk) { $out.Add($b) }; $out.Add($ln); $blk = $null; continue
    }
    if ($ln -match '^\s*</Steps>') { $inSteps = $false }
    $out.Add($ln)
  }
  if ($n) { [IO.File]::WriteAllText($cs, ($out -join $nl), (New-Object Text.UTF8Encoding($bom))) }
  $note = if (-not $want.Count) { ' (no head aimed in step 1 - left as it was)' } elseif (-not $n) { " (already on tonight's step-1 center)" } else { " ($($heads.Count) of $($want.Count) aimed heads moved to tonight's step-1 center)" }
  "  {0,-46} {1,3} values changed{2}" -f 'CENTER SPOT (spot scene)', $n, $note
}

function Show-Table($movers, $fix) {
  ""
  "  HEAD      CENTER correction      SIZE from corner (width x depth)"
  foreach ($m in $movers) {
    $o = $fix[$m.Id]
    $cen = if ($o.op -eq 0 -and $o.ot -eq 0) { '(home)' } else { "{0,6} / {1,6}" -f $o.op, $o.ot }
    $sz = if ($o.sized) { "{0,4:0}% x {1,4:0}%   zoom {2}/{3}" -f ($o.kp*100), ($o.kt*100), $o.zp, $o.zt } else { 'normal (no corner set)' }
    "  {0,-8}  {1,-20}   {2}  {3}" -f (Get-Label $m), $cen, $sz, $o.warn
  }
  ""
}

function Read-Size($st) {
  $lastW = [int][math]::Round($st.sx * 100); $lastD = [int][math]::Round($st.sy * 100)
  $last = if ($lastW -eq $lastD) { "$lastW" } else { "$lastW $lastD" }
  # Write-Host: these lines must be SHOWN, not returned (they used to end up inside the size answer)
  Write-Host ""
  Write-Host "  OVERALL PATTERN SIZE in %   (100 = patterns fill out to the corners, 80 = stay a bit inside)"
  Write-Host "  One number = both ways.  Two numbers = WIDTH DEPTH, e.g.  110 90"
  $in = Read-Host "  Size (press Enter for last used: $last)"
  if (-not $in.Trim()) { $in = $last }
  $in
}

function ConvertTo-Size([string]$in) {
  $parts = @($in.Trim() -split '[\s,x/]+' | Where-Object { $_ })
  if ($parts.Count -lt 1 -or $parts.Count -gt 2 -or ($parts | Where-Object { $_ -notmatch '^\d+(\.\d+)?%?$' })) { throw "Size '$in' not understood - use e.g. 100 or 120 90. NOTHING was changed." }
  $w = [double]($parts[0] -replace '%'); $dd = if ($parts.Count -eq 2) { [double]($parts[1] -replace '%') } else { $w }
  foreach ($v in $w, $dd) { if ($v -lt 20 -or $v -gt 300) { throw "Size $v% is outside 20-300. NOTHING was changed." } }
  @(($w / 100), ($dd / 100))
}

function Get-HomeAims($movers) {
  $c = @{}; $k = @{}
  foreach ($m in $movers) { $c[$m.Id] = $homePos[$m.Model]; $k[$m.Id] = Get-DefaultCorner $m }
  @{ center = $c; corner = $k }
}

# ---- Room: ROOM AIM (ADJUST) + ROOM CHECK buttons on the SETUP page (aims in column 1, checks in column 2, like DF)
function Get-RoomSetup {
  $info = Get-LiveInfo $root
  [pscustomobject]@{ aim = [bool]@($info.Buttons | Where-Object { $_.Name -eq 'ROOM AIM (ADJUST).scex' }).Count; check = [bool]@($info.Buttons | Where-Object { $_.Name -eq 'ROOM CHECK.gpj' }).Count }
}
function Install-RoomButtons {
  $ini = Read-LiveIni $root; $info = Get-LiveInfo $root $ini
  $pg = $null; foreach ($k in $info.Pages.Keys) { if ("$($info.Pages[$k])".Trim() -eq 'SETUP') { $pg = $k } }
  if ($null -eq $pg) { throw "No live page called SETUP found. NOTHING was changed." }
  foreach ($b in @(@('ROOM AIM (ADJUST).scex', 'ROOM AIM (ADJUST)', 1), @('ROOM CHECK.gpj', 'ROOM CHECK', 2))) {
    if (@($info.Buttons | Where-Object { $_.Name -eq $b[0] }).Count) { continue }
    $cell = Add-LiveButton $ini $info $pg $b[0] $b[1] (@($b[2]) + @(4..10)) -Down; $info = Get-LiveInfo $root $ini
    "  CHANGED  added $($b[1]) to the SETUP page (line $($cell[0]), column $($cell[1]))"
  }
  [void](Save-LiveIni $ini)
}

# ---------------------------------------------------------------- main
$movers = @(Get-Movers)
if ($movers.Count -eq 0) { throw "No 140SR/251SR fixtures found." }
$st = Load-State

if ($Action -eq 'Preview') {
  # read-only summary for the GUI
  $a = if (Test-Path -LiteralPath $scene) { Read-AimScene $movers } else { Get-HomeAims $movers }
  $fix = Get-HeadFix $movers $a.center $a.corner
  $heads = @(foreach ($m in $movers) { $o = $fix[$m.Id]
    [pscustomobject]@{ label = (Get-Label $m); is140 = $m.Is140; op = $o.op; ot = $o.ot; sized = $o.sized
      kp = [math]::Round($o.kp * 100); kt = [math]::Round($o.kt * 100); zp = $o.zp; zt = $o.zt; warn = $o.warn } })
  [pscustomobject]@{ ok = $true; show = $root; lastW = [math]::Round($st.sx * 100); lastD = [math]::Round($st.sy * 100)
    sceneExists = [bool](Test-Path -LiteralPath $scene); heads = $heads; mode = $Mode; aimTitle = $aimTitle; checkTitle = $checkTitle
    install = $(if ($Mode -eq 'Room') { Get-RoomSetup } else { $null }); targets = @(Get-TargetGpjs | ForEach-Object { $_ -replace '\.gpj$', '' }) } | ConvertTo-Json -Depth 4 -Compress
  return
}

if ($Action -eq 'Menu') {
  Test-SxClosed
  ""
  "  AIM MOVERS TO DANCEFLOOR"
  "  ------------------------"
  "  1  Apply  - use tonight's CENTER + CORNER aims from 'DF AIM (ADJUST)' and set the overall size"
  "  2  Home   - everything back to normal (no corrections, size 100)"
  ""
  $c = Read-Host "  Pick 1 or 2"
  switch ($c) { '1' { $Action = 'Apply' } '2' { $Action = 'Home' } default { "  nothing done."; return } }
}

Test-SxClosed
# aim scene: create, or upgrade an old 1-step scene to center + corner (keeps your center aims)
if (-not (Test-Path $scene)) {
  $h = Get-HomeAims $movers; Write-AimScene $movers $h.center $h.corner
  "  CHANGED  created aim scene ${aimTitle}: step 1 = CENTER, step 2 = CORNER"
} else {
  $a = Read-AimScene $movers
  if ($a.steps -lt 2) { Write-AimScene $movers $a.center $a.corner; "  $aimTitle upgraded: step 2 = CORNER added (your center aims kept)" }
}
foreach ($k in $checks.Keys) { New-CheckGpj $k $checks[$k] $movers }
if ($Mode -eq 'Room') { Install-RoomButtons }
if ($Action -eq 'Install') { "  DONE - ROOM AIM (ADJUST) and ROOM CHECK are on the SETUP page."; return }

if ($Action -eq 'Home') {
  $h = Get-HomeAims $movers; Write-AimScene $movers $h.center $h.corner
  "  aim scene reset to home"
  $fix = Get-HeadFix $movers $h.center $h.corner -Reset
  $sz = @(1.0, 1.0)
} else {
  $a = Read-AimScene $movers
  $fix = Get-HeadFix $movers $a.center $a.corner
  Show-Table $movers $fix
  $nWarn = @($movers | Where-Object { $fix[$_.Id].warn }).Count
  if ($nWarn -and -not $Force) {
    Write-Host "  !! $nWarn head(s) have an aim that looks wrong (see the right-hand column)." -ForegroundColor Yellow
    Write-Host "     Usually: step 1 / step 2 of $aimTitle not aimed for tonight yet, or the wrong step edited." -ForegroundColor Yellow
    if ($NoPrompt) { throw "Aims look wrong for $nWarn head(s). NOTHING was changed." }
    $ok = Read-Host "  Type y to apply anyway, or just Enter to stop and fix the aims"
    if ($ok -notmatch '^[yY]') { "  stopped. NOTHING was changed."; return }
  }
  if (-not $Size) { if ($NoPrompt) { $Size = '100' } else { $Size = Read-Size $st } }
  $sz = ConvertTo-Size $Size
  "  OVERALL SIZE: width {0}%  depth {1}%" -f ($sz[0]*100), ($sz[1]*100); ""
}
Update-Gpjs $fix $sz[0] $sz[1] $st
if ($Action -eq 'Apply') { Update-CenterSpot $movers $a.center }   # user 2026-11-21: CENTER SPOT follows step 1
$st.sx = $sz[0]; $st.sy = $sz[1]
Save-State $st
if ($Action -eq 'Home') { "  DONE - all movement scenes back to normal." }
else { "  DONE - open ShowXpress. Check: $checkTitle (beams trace the corners)." }
