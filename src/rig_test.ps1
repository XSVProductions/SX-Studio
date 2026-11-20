# RIG TEST - which 140 is hanging where tonight, without wiggling dimmers.
#
#   The RIG ID button (SETUP page) lights every 140SR in its own look: #1-#8 solid colours, #9-#16 the same colours
#   flashing. In the ShowXpress Helper you tap each truss spot and pick the look you see there. Save moves every head
#   to its spot in the Editor 2D view (Editor/2DView/fixtures.ini); heads that aren't hung go in a neat block in the middle.
#
#   2D page = the room seen from the DJ booth (bottom of the page). The 4 corners are the 4 towers, 2 heads per T-bar:
#   the left head on the page is that truss's left mover. Bigger events: 2 extra towers, top middle and bottom middle -
#   their 2 heads sit either side of the blinder (top) / uplight (bottom), which are put in the middle of the page.
#
#   -Action Preview                     -> JSON for the Helper window (writes nothing)
#   -Action Apply -ChangesFile <json>   -> {"assign":{"tl-l":"<fixture id>",...},"extra":false}; writes the 2D view
#   -Action Install                     -> creates scenes/RIG ID.scex + the RIG ID button on the SETUP page if missing
param(
  [ValidateSet('Preview','Apply','Install')][string]$Action = 'Preview',
  [string]$ChangesFile = '',
  [string]$TestRoot = ''   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/Live/live.ini")) { throw "Show not found at '$root'. NOTHING was changed." }
$twoD      = "$root/Editor/2DView/fixtures.ini"
$statePath = "$root/rig_test.json"
$sceneName = 'RIG ID.scex'
$scenePath = "$root/scenes/$sceneName"

# ---- the looks: 140 #1-#8 solid, #9-#16 the same colours flashing (140SR colour wheel values / shutter strobe)
$looks = @(
  @{ n = 'White';    v = 1;  hex = 'ffffff' }, @{ n = 'Red';      v = 5;  hex = 'ff2a2a' },
  @{ n = 'Orange';   v = 26; hex = 'ff8c1a' }, @{ n = 'Yellow';   v = 9;  hex = 'ffe600' },
  @{ n = 'Green';    v = 13; hex = '22dd44' }, @{ n = 'Sky blue'; v = 17; hex = '6fd3ff' },
  @{ n = 'Blue';     v = 31; hex = '2f5bff' }, @{ n = 'Pink';     v = 36; hex = 'ff3fd2' })
$flashShutter = 40   # 140SR shutter 16-131 = strobe slow -> fast

# ---- 2D view spots (top-left corner of the fixture icon, pixels). Pairs are [left head, right head].
$spots = @(
  @{ key = 'tl'; name = 'Top left';     x = 0;   y = 0;   extra = $false }, @{ key = 'tr'; name = 'Top right';    x = 786; y = 0;   extra = $false },
  @{ key = 'tm'; name = 'Top middle';    x = 329; y = 0;   extra = $true;  gap = 266 },
  @{ key = 'bl'; name = 'Bottom left';  x = 0;   y = 592; extra = $false }, @{ key = 'br'; name = 'Bottom right'; x = 786; y = 592; extra = $false },
  @{ key = 'bm'; name = 'Bottom middle'; x = 329; y = 592; extra = $true;  gap = 266 })
$pairGap = 110
# blinder top center, uplight bottom center (their 2D pictures are 128 px wide; page center = 503)
$centerX = 439; $centerFix = @(@{ rx = 'blinder'; y = 0 }, @{ rx = 'uplight'; y = 640 })
$slots = foreach ($s in $spots) { foreach ($side in 'l', 'r') {
  [pscustomobject]@{ key = "$($s.key)-$side"; tower = $s.key; towerName = $s.name; side = $(if ($side -eq 'l') { 'left' } else { 'right' })
                     x = $s.x + $(if ($side -eq 'r') { $(if ($s.gap) { $s.gap } else { $pairGap }) } else { 0 }); y = $s.y; extra = $s.extra } } }

$heads = @(Get-ShowMovers $root | Where-Object { $_.Is140 } | Sort-Object Num)
if (-not $heads.Count) { throw "No 140SR fixtures found in the show. NOTHING was changed." }
function Get-Look($h) { $i = ($h.Num - 1) % 8; @{ look = $looks[$i]; flash = ($h.Num -gt 8) } }

# ---- 2D view file (UTF-8 BOM, LF - kept as found)
function Read-TwoD {
  if (-not (Test-Path -LiteralPath $twoD)) { throw "Editor/2DView/fixtures.ini not found - open the 2D view in ShowXpress once, then try again. NOTHING was changed." }
  $b = [IO.File]::ReadAllBytes($twoD)
  $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  $o = if ($bom) { 3 } else { 0 }
  $t = [Text.Encoding]::UTF8.GetString($b, $o, $b.Length - $o)
  $L = New-Object Collections.Generic.List[string]; foreach ($x in ($t -split "`r?`n")) { $L.Add($x) }
  [pscustomobject]@{ Path = $twoD; Bom = $bom; Nl = $(if ($t -match "`r`n") { "`r`n" } else { "`n" }); Lines = $L; Text = $t }
}
function Get-Pos($ini, [string]$name) {
  $se = Find-IniSection $ini $name; if (-not $se) { return $null }
  for ($i = $se[0] + 1; $i -lt $se[1]; $i++) { if ($ini.Lines[$i] -match '^Position = (-?\d+),(-?\d+)') { return @([int]$matches[1], [int]$matches[2]) } }
  $null
}

$state = @{ saved = $null; extra = $false }
if (Test-Path -LiteralPath $statePath) { $j = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json; $state.saved = "$($j.saved)"; $state.extra = [bool]$j.extra }

# ---- RIG ID scene + button
function Get-SetupPage($info) { foreach ($k in $info.Pages.Keys) { if ("$($info.Pages[$k])".Trim() -eq 'SETUP') { return $k } }; $null }
function Get-InstallState {
  $info = Get-LiveInfo $root; $pg = Get-SetupPage $info
  $btn = @($info.Buttons | Where-Object { $_.Name -eq $sceneName })
  [pscustomobject]@{ scene = (Test-Path -LiteralPath $scenePath); button = [bool]$btn.Count; setupPage = $pg
                     where = $(if ($btn.Count) { "$($btn[0].PageName), line $($btn[0].Keys['line']), column $($btn[0].Keys['column'])" } else { '' }) }
}
function New-IdSceneText {
  $nl = "`n"; $sb = New-Object Text.StringBuilder
  [void]$sb.Append("<?xml version=`"1.0`" encoding=`"UTF-8`"?>$nl$nl<Scene>$nl  <Fixtures>$nl")
  foreach ($h in $heads) { [void]$sb.Append("    <Fixture id=`"$($h.Id)`" name=`"$($h.Name)`" model=`"$($h.Model)`"/>$nl") }
  [void]$sb.Append("  </Fixtures>$nl  <Steps>$nl    <Step length=`"300`">$nl")
  foreach ($h in $heads) {
    $lk = Get-Look $h
    $ch = @(@(0,'pan',88,1), @(1,'upan',72,1), @(2,'tilt',194,1), @(3,'utilt',36,1), @(4,'pantilt_speed',0,0), @(5,'color',$lk.look.v,0),
            @(6,'gobo',0,0), @(7,'gobo#2',0,0), @(8,'gobo_rotate',0,0), @(9,'8 facet prism',0,0), @(10,'linear prism',0,0),
            @(13,'zoom',243,0), @(14,'frost',0,0), @(15,'dimmer',255,0), @(16,'shutter',$(if ($lk.flash) { $flashShutter } else { 255 }),0))
    [void]$sb.Append("      <Fixture id=`"$($h.Id)`">$nl")
    foreach ($c in $ch) { [void]$sb.Append("        <Channel index=`"$($c[0])`" name=`"$($c[1])`" value=`"$($c[2])`"$(if ($c[3]) { ' fade="1"' })/>$nl") }
    [void]$sb.Append("      </Fixture>$nl")
  }
  [void]$sb.Append("    </Step>$nl  </Steps>$nl</Scene>$nl"); $sb.ToString()
}

if ($Action -eq 'Install') {
  if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
  $out = @()
  if (-not (Test-Path -LiteralPath $scenePath)) { [IO.File]::WriteAllText($scenePath, (New-IdSceneText), (New-Object Text.UTF8Encoding($false))); $out += "  CHANGED  made the scene RIG ID (140 #1-#8 solid, #9-#16 flashing)" }
  $ini = Read-LiveIni $root; $info = Get-LiveInfo $root $ini
  if (-not @($info.Buttons | Where-Object { $_.Name -eq $sceneName }).Count) {
    $pg = Get-SetupPage $info; if ($null -eq $pg) { throw "No live page called SETUP found. NOTHING was changed." }
    $mine = @($info.Buttons | Where-Object { $_.Page -eq $pg })
    $used = @{}; foreach ($b in $mine) { $used["$($b.Keys['line'])/$($b.Keys['column'])"] = 1 }
    $cell = $null; foreach ($ln in 1..8) { foreach ($co in (@(3..10) + @(1..2))) { if (-not $cell -and -not $used.ContainsKey("$ln/$co")) { $cell = @($ln, $co) } } }
    $n = 1; while (Find-IniSection $ini "page${pg}_button$n") { $n++ }
    $last = if ($mine.Count) { Find-IniSection $ini (($mine | Sort-Object Btn | Select-Object -Last 1).Sec) } else { Find-IniSection $ini "page$pg" }
    $new = @("[page${pg}_button$n]", "line = $($cell[0])", "column = $($cell[1])", "name = $sceneName", 'title = RIG ID', 'masterspeedfader = 0')
    $ini.Lines.InsertRange($last[1], [string[]]$new)
    Set-IniKey $ini "page$pg" 'nb_buttons' "$($mine.Count + 1)" @('name')
    [void](Save-LiveIni $ini)
    $out += "  CHANGED  added the RIG ID button to the SETUP page (line $($cell[0]), column $($cell[1]))"
  }
  if (-not $out.Count) { $out += '  nothing to change - RIG ID is already there' }
  $out; return
}

# ---- current spots, read back from the 2D view
$ini2 = Read-TwoD
$assign = [ordered]@{}; $posOf = @{}
foreach ($h in $heads) {
  $p = Get-Pos $ini2 $h.Name; $posOf[$h.Id] = $p
  if (-not $p) { continue }
  foreach ($s in $slots) { if (-not $assign.Contains($s.key) -and [Math]::Abs($p[0] - $s.x) -le 40 -and [Math]::Abs($p[1] - $s.y) -le 40) { $assign[$s.key] = $h.Id; break } }
}

if ($Action -eq 'Preview') {
  $extraUsed = [bool]@($slots | Where-Object { $_.extra -and $assign.Contains($_.key) }).Count
  $st = Get-InstallState
  [pscustomobject]@{
    ok = $true; show = $root; saved = $state.saved; extra = ($state.extra -or $extraUsed)
    install = $st
    heads = @(foreach ($h in $heads) { $lk = Get-Look $h; [pscustomobject]@{ id = $h.Id; num = $h.Num; label = (Get-Label $h); look = $lk.look.n; hex = $lk.look.hex; flash = $lk.flash } })
    slots = @($slots); assign = $assign
  } | ConvertTo-Json -Depth 6 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again. (ShowXpress rewrites the 2D view when it closes.)" }
if (-not $ChangesFile -or -not (Test-Path -LiteralPath $ChangesFile)) { throw "No changes were sent. NOTHING was changed." }
$ch = [IO.File]::ReadAllText($ChangesFile) | ConvertFrom-Json
$extra = [bool]$ch.extra
$byId = @{}; foreach ($h in $heads) { $byId[$h.Id] = $h }
$slotOf = @{}; $want = @{}
if ($ch.assign) {
  foreach ($p in $ch.assign.PSObject.Properties) {
    $s = @($slots | Where-Object { $_.key -eq $p.Name }); $id = "$($p.Value)"
    if (-not $s.Count) { throw "Unknown truss spot '$($p.Name)'. NOTHING was changed." }
    if (-not $id) { continue }
    if (-not $byId.ContainsKey($id)) { throw "Unknown head '$id'. NOTHING was changed." }
    if ($s[0].extra -and -not $extra) { continue }
    if ($slotOf.ContainsKey($id)) { throw "$(Get-Label $byId[$id]) is in two spots. NOTHING was changed." }
    $slotOf[$id] = $s[0]; $want[$id] = @($s[0].x, $s[0].y)
  }
}
if (-not $slotOf.Count) { throw "Put at least one mover on a truss. NOTHING was changed." }

# heads not hung -> a neat block in the middle of the page, 4 across, in number order
$spare = @($heads | Where-Object { -not $slotOf.ContainsKey($_.Id) })
$cols = [Math]::Min(4, [Math]::Max(1, $spare.Count)); $rows = [Math]::Ceiling($spare.Count / 4)
$x0 = [int](503 - $cols * 110 / 2); $y0 = [int](346 - $rows * 105 / 2)
for ($i = 0; $i -lt $spare.Count; $i++) { $want[$spare[$i].Id] = @(($x0 + ($i % 4) * 110), ($y0 + [Math]::Floor($i / 4) * 105)) }

$lines = @()
foreach ($h in $heads) {
  $xy = "$($want[$h.Id][0]),$($want[$h.Id][1])"
  if (Find-IniSection $ini2 $h.Name) { Set-IniKey $ini2 $h.Name 'Position' $xy }
  else { $ix = $ini2.Lines.Count; while ($ix -gt 0 -and -not $ini2.Lines[$ix - 1].Trim()) { $ix-- }; $ini2.Lines.InsertRange($ix, [string[]]@("[$($h.Name)]", "Position = $xy")) }
  if ($slotOf.ContainsKey($h.Id)) { $s = $slotOf[$h.Id]; $lines += "  $(Get-Label $h): $($s.towerName) tower, $($s.side) mover" }
}
# blinder / uplight -> top / bottom center of the page (their own sections, found by name)
foreach ($cf in $centerFix) {
  foreach ($ln in @($ini2.Lines)) {
    if ($ln -notmatch '^\[(.+)\]\s*$') { continue }
    $nm = $matches[1]
    if ($nm -match $cf.rx) {
      $old = Get-Pos $ini2 $nm; $xy = "$centerX,$($cf.y)"
      if (-not $old -or "$($old[0]),$($old[1])" -ne $xy) { Set-IniKey $ini2 $nm 'Position' $xy; $lines += "  ${nm}: moved to the $(if ($cf.y) { 'bottom' } else { 'top' }) center" }
    }
  }
}
if ($spare.Count) { $lines += "  not hung (middle of the page): $(($spare | ForEach-Object { '#' + $_.Num }) -join ', ')" }
$newText = $ini2.Lines -join $ini2.Nl
if ($newText -ne $ini2.Text) { [IO.File]::WriteAllText($twoD, $newText, (New-Object Text.UTF8Encoding($ini2.Bom))); "  2D view saved" } else { "  nothing to change in the 2D view" }
[IO.File]::WriteAllText($statePath, ([ordered]@{ saved = (Get-Date).ToString('s'); extra = $extra; hung = @($slotOf.Keys) } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
$lines

# full hung list for Tonight's Rig: these 140s + whichever 251s are ticked there now (all if nothing saved)
$rigHung = @(); $r = "$root/rig_state.json"
$all251 = @(Get-ShowMovers $root | Where-Object { -not $_.Is140 } | ForEach-Object Id)
$h251 = $all251
if (Test-Path -LiteralPath $r) { $rj = [IO.File]::ReadAllText($r) | ConvertFrom-Json; if ($rj.hung) { $h251 = @($all251 | Where-Object { @($rj.hung) -contains $_ }) } }
"RIGHEADS: $((@($slotOf.Keys) + $h251) -join ',')"
# SKIP FLASH: these 140s + only the 251s ticked as hung in Tonight's Rig (none if nothing saved there)
$s251 = @(); if ($rj -and $rj.hung) { $s251 = $h251 }
"SKIPHEADS: $((@($slotOf.Keys) + $s251) -join ',')"
