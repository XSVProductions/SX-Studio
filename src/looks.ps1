# ONE-CLICK LOOKS (phase 4 of SX Studio's own editor, user 2026-11-24) - makes NEW ShowXpress scenes (.scex) from
# templates (contrast pairs, colour chase, strobe, prism fan). The page works out the steps (so it can show them on the
# lights first); this script only checks them and writes the new file.
#
#   Rules (user): ShowXpress must still open every file written; the live board (live.ini) is never touched - a new look
#   is put on a button in ShowXpress by the user, or on one of the SX Player's own pages. A look is always a NEW file:
#   an existing scene is never overwritten or changed.
#
#   -Action Rig                       -> JSON: the show's heads (from fixtures.ini, in address order) and, for each model,
#                                        its channels (from fixtures/<model>.txt) and what a look can use: colour wheel
#                                        slots, red/green/blue/white/amber/uv, dimmer, shutter open/closed, prisms, gobo
#                                        spin, zoom, focus, frost, and the strobe / effect channels to keep at "off"
#   -Action Make -ChangesFile f.json  -> writes scenes/<name> (must not exist yet)
#        {name:"X.scex", steps:[{len, f:{"<head id>":[[ix, v, fade], ...]}}]}
#        len = 1/100 s; v = 0..255; fade = 0/1. Every step must have the same heads and channels.
param(
  [ValidateSet('Rig', 'Make')][string]$Action = 'Rig',
  [string]$ChangesFile = '',
  [string]$TestRoot = ''   # testing only: run against a copy of the show
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/scenes")) { throw "The show has no scenes folder ($root). NOTHING was changed." }
$maxSteps = 256

function Get-Heads {
  # fixtures.ini, in its own order: one head per [FixtureN] with quantity 1 (a group of several heads has no ids of its own)
  $out = New-Object Collections.Generic.List[object]; $cur = $null
  $p = "$root/fixtures.ini"
  if (-not (Test-Path -LiteralPath $p)) { throw "The show has no fixtures.ini. NOTHING was changed." }
  $add = { if ($cur -and $cur.id -and $cur.model) { $out.Add([pscustomobject]$cur) } }
  foreach ($l in [IO.File]::ReadAllLines($p)) {
    if ($l -match '^\s*\[') { & $add; $cur = [ordered]@{ id = ''; name = ''; model = ''; addr = 0; qty = 1 }; continue }
    if ($null -eq $cur) { continue }
    if ($l -match '^address = (\d+)') { $cur.addr = [int]$matches[1] }
    elseif ($l -match '^id = (\S+)\s*$') { $cur.id = $matches[1] }
    elseif ($l -match '^name = (.*?)\s*$') { $cur.name = $matches[1] }
    elseif ($l -match '^model = (.*?)\s*$') { $cur.model = $matches[1] }
    elseif ($l -match '^quantity = (\d+)') { $cur.qty = [int]$matches[1] }
  }
  & $add
  ,$out
}

$script:defs = @{}
function Get-Def([string]$model) {
  # fixtures/<model>.txt -> the channels in order: name as a scene writes it (a repeated name gets #2, #3..) + its ranges
  if ($script:defs.ContainsKey($model)) { return $script:defs[$model] }
  $p = "$root/fixtures/$model.txt"; $ch = New-Object Collections.Generic.List[object]; $seen = @{}; $cur = $null
  if (Test-Path -LiteralPath $p) {
    foreach ($l in [IO.File]::ReadAllLines($p)) {
      if ($l -match '^Channel = (.+?)\s*$') {
        $n = $matches[1]; $k = $n.ToLower(); $seen[$k] = 1 + [int]$seen[$k]
        $cur = [pscustomobject]@{ ix = $ch.Count; name = $(if ($seen[$k] -gt 1) { "$n#$($seen[$k])" } else { $n }); base = $k; ranges = @() }
        $ch.Add($cur); continue
      }
      if ($cur -and $l.Trim() -and -not $cur.ranges.Count -and $l -match ',\d+,\d+') {
        $cur.ranges = @(foreach ($r in [regex]::Matches($l, '([^,]+?),(\d+),(\d+)')) {
          [pscustomobject]@{ n = $r.Groups[1].Value.Trim().ToLower(); lo = [int]$r.Groups[2].Value; hi = [int]$r.Groups[3].Value } })
      }
    }
  }
  $script:defs[$model] = $ch; $ch
}

function Get-Range($c, [string]$rx) { @($c.ranges | Where-Object { $_.n -match $rx -and $_.hi -ge $_.lo -and $_.hi -gt 0 }) | Select-Object -First 1 }
function Get-Caps([string]$model) {
  # what a look can use on this model (all from the channel names / range names of its definition)
  $d = Get-Def $model
  $first = { param($n) @($d | Where-Object { $_.base -eq $n }) | Select-Object -First 1 }
  $all = { param($n) @($d | Where-Object { $_.base -eq $n } | ForEach-Object { $_.ix }) }
  $c = [ordered]@{ chans = @($d | ForEach-Object { [pscustomobject]@{ ix = $_.ix; name = $_.name } }) }
  $c.pan = [bool](& $first 'pan')
  $col = & $first 'color'
  $c.slots = @(if ($col) { foreach ($r in $col.ranges) { if ($r.n -match 'index|rotate|stop|scroll|random|rainbow') { break }; if ($r.hi -lt $r.lo) { continue }
    [pscustomobject]@{ n = ($r.n -replace '^.*/', ''); v = [int](($r.lo + $r.hi + 1) / 2) } } })
  $c.wheel = if ($col -and $c.slots.Count) { $col.ix } else { -1 }
  $c.rgb = [ordered]@{}; foreach ($k in 'red', 'green', 'blue', 'white', 'amber', 'uv') { $c.rgb[$k] = @(& $all $k) }
  $dm = & $first 'dimmer'; $c.dim = if ($dm) { $dm.ix } else { -1 }
  # the shutter: open = an "open" range (255 if that is open), closed = a "closed" range. One with no open range (a
  # strobe-only channel) is a strobe channel, kept at its "off" value
  $c.shut = $null; $c.kill = @()
  foreach ($x in $d) {
    if ($x.base -match '^(shutter|strobe|strobe_dimmer|strobe_effect|effect_macro|macro|auto_program|virtual color wheel|color temp presets|movement_macro|control)$') {
      $op = @($x.ranges | Where-Object { $_.n -eq 'open' -and $_.hi -ge $_.lo })
      if ($x.base -eq 'shutter' -and $op.Count -and -not $c.shut) {
        $ov = if (@($op | Where-Object { $_.hi -eq 255 }).Count) { 255 } else { $op[0].hi }
        $cl = Get-Range $x '^closed$'; $c.shut = [pscustomobject]@{ ix = $x.ix; open = $ov; closed = $(if ($cl) { $cl.lo } else { 0 }) }
        continue
      }
      if ($x.base -match 'movement_macro|control') { continue }   # leave alone (moves / resets the head)
      $off = Get-Range $x '^(no[ _]?function|no[ _]?effect|off|stop|close|closed)$'
      $c.kill += ,@($x.ix, $(if ($off) { $off.lo } else { 0 }))
    }
  }
  $c.prisms = @(foreach ($x in $d) { if ($x.base -match 'prism') {
    $on = @($x.ranges | Where-Object { $_.n -notmatch 'no[ _]?function|stop|rotate' -and $_.lo -gt 0 } | Select-Object -First 1)
    $rr = Get-Range $x 'right_rotate'; $lr = Get-Range $x 'left_rotate'
    [pscustomobject]@{ ix = $x.ix; name = $x.name; on = $(if ($on.Count) { [int](($on[0].lo + $on[0].hi + 1) / 2) } else { 128 })
      r = $(if ($rr) { @($rr.lo, $rr.hi) } else { $null }); l = $(if ($lr) { @($lr.lo, $lr.hi) } else { $null }) } } })
  $gr = & $first 'gobo_rotate'
  $c.grot = if ($gr) { $rr = Get-Range $gr 'right_rotate'; $lr = Get-Range $gr 'left_rotate'
    [pscustomobject]@{ ix = $gr.ix; r = $(if ($rr) { @($rr.lo, $rr.hi) } else { $null }); l = $(if ($lr) { @($lr.lo, $lr.hi) } else { $null }) } } else { $null }
  $c.gobos = @($d | Where-Object { $_.base -match '^gobo\d*$' } | ForEach-Object { $_.ix })   # set open by the prism fan
  foreach ($k in 'zoom', 'focus', 'frost', 'gobo') { $x = & $first $k; $c[$k] = if ($x) { $x.ix } else { -1 } }
  [pscustomobject]$c
}

if ($Action -eq 'Rig') {
  $heads = Get-Heads; $models = [ordered]@{}
  foreach ($mo in @($heads | ForEach-Object { $_.model } | Select-Object -Unique)) { $models[$mo] = Get-Caps $mo }
  $scenes = @(Get-ChildItem -LiteralPath "$root/scenes" -Filter '*.scex' -File | ForEach-Object { $_.Name })
  [pscustomobject]@{ ok = $true; show = $root; sxOpen = [bool](Test-SxRunning)
    heads = @($heads | Where-Object { $_.qty -eq 1 -and (Get-Def $_.model).Count } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; model = $_.model; addr = $_.addr } })
    skipped = @($heads | Where-Object { $_.qty -ne 1 -or -not (Get-Def $_.model).Count } | ForEach-Object { $_.name })
    models = $models; scenes = $scenes } | ConvertTo-Json -Depth 8 -Compress
  return
}

# ---------------------------------------------------------------- Make
if (-not $ChangesFile -or -not (Test-Path -LiteralPath $ChangesFile)) { throw "No look was sent. NOTHING was changed." }
$j = [IO.File]::ReadAllText($ChangesFile) | ConvertFrom-Json
$name = "$($j.name)".Trim()
if ($name -notmatch '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$' -or $name -match '^\.' -or $name -match '\s\.scex$') { throw "'$name' can't be a scene name. NOTHING was changed." }
$path = Join-Path "$root/scenes" $name
if (Test-Path -LiteralPath $path) { throw "A scene called '$($name -replace '\.scex$', '')' is already in the show. Pick another name - NOTHING was changed." }
$heads = Get-Heads; $byId = @{}; foreach ($h in $heads) { if ($h.qty -eq 1) { $byId[$h.id] = $h } }
$steps = @($j.steps | Where-Object { $null -ne $_ })
if (-not $steps.Count) { throw "The look has no steps. NOTHING was changed." }
if ($steps.Count -gt $maxSteps) { throw "A look can have at most $maxSteps steps. NOTHING was changed." }

# every step: the same heads, each with the same channels
$plan = New-Object Collections.Generic.List[object]; $shape = $null
foreach ($s in $steps) {
  $len = 0; if (-not [int]::TryParse("$($s.len)", [ref]$len) -or $len -lt 1 -or $len -gt 360000) { throw "A step's time must be 0.01 s to 1 hour. NOTHING was changed." }
  $fx = [ordered]@{}
  if ($s.f) { foreach ($p in $s.f.PSObject.Properties) {
    if (-not $byId.ContainsKey($p.Name)) { throw "Head $($p.Name) isn't in the show's fixtures. NOTHING was changed." }
    $d = Get-Def $byId[$p.Name].model; $chs = @{}   # (a hashtable: [ordered] would read an int key as a position)
    foreach ($c in @($p.Value)) {
      $c = @($c); if ($c.Count -lt 2) { throw "Bad channel for head $($p.Name). NOTHING was changed." }
      $ix = [int]$c[0]; $v = [int]$c[1]; $fd = ($c.Count -gt 2 -and [int]$c[2] -eq 1)
      if ($ix -lt 0 -or $ix -ge $d.Count) { throw "Head $($byId[$p.Name].name) has no channel $ix. NOTHING was changed." }
      if ($v -lt 0 -or $v -gt 255) { throw "A channel value must be 0-255. NOTHING was changed." }
      if ($chs.ContainsKey($ix)) { throw "Channel $ix of $($byId[$p.Name].name) is in a step twice. NOTHING was changed." }
      $chs[$ix] = @($v, $fd)
    }
    if ($chs.Count) { $fx[$p.Name] = $chs }
  } }
  if (-not $fx.Count) { throw "A step of the look has no channels. NOTHING was changed." }
  $sh = (@($fx.Keys | Sort-Object | ForEach-Object { "$_=" + ((@($fx[$_].Keys) | Sort-Object) -join ',') }) -join ';')
  if ($null -eq $shape) { $shape = $sh } elseif ($sh -ne $shape) { throw "Every step of a look must set the same heads and channels. NOTHING was changed." }
  $plan.Add([pscustomobject]@{ len = $len; fx = $fx })
}

# the text, the way ShowXpress writes a scene (UTF-8, no BOM, LF)
$used = @($heads | Where-Object { $plan[0].fx.Contains($_.id) })
$esc = { param($t) [Security.SecurityElement]::Escape("$t") }
$sb = New-Object Text.StringBuilder
[void]$sb.Append("<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n`n<Scene>`n  <Fixtures>`n")
foreach ($h in $used) { [void]$sb.Append("    <Fixture id=`"$(& $esc $h.id)`" name=`"$(& $esc $h.name)`" model=`"$(& $esc $h.model)`"/>`n") }
[void]$sb.Append("  </Fixtures>`n  <Steps>`n")
foreach ($s in $plan) {
  [void]$sb.Append("    <Step length=`"$($s.len)`">`n")
  foreach ($h in $used) {
    $d = Get-Def $h.model; $chs = $s.fx[$h.id]
    [void]$sb.Append("      <Fixture id=`"$(& $esc $h.id)`">`n")
    foreach ($ix in @($chs.Keys | Sort-Object)) {
      $c = $chs[$ix]; [void]$sb.Append("        <Channel index=`"$ix`" name=`"$(& $esc $d[$ix].name)`" value=`"$($c[0])`"$(if ($c[1]) { ' fade="1"' })/>`n")
    }
    [void]$sb.Append("      </Fixture>`n")
  }
  [void]$sb.Append("    </Step>`n")
}
[void]$sb.Append("  </Steps>`n</Scene>`n")
$text = $sb.ToString()

# check it reads back as the same look before it is written
$x = New-Object Xml.XmlDocument; $x.LoadXml($text)
$rs = @($x.Scene.Steps.Step)
if ($rs.Count -ne $plan.Count -or @($x.Scene.Fixtures.Fixture).Count -ne $used.Count) { throw "The new scene didn't check out. NOTHING was written." }
for ($i = 0; $i -lt $plan.Count; $i++) {
  if ([int]$rs[$i].length -ne $plan[$i].len) { throw "The new scene didn't check out. NOTHING was written." }
  foreach ($f in @($rs[$i].Fixture)) { foreach ($c in @($f.Channel)) {
    if ([int]$c.value -ne $plan[$i].fx[$f.id][[int]$c.index][0]) { throw "The new scene didn't check out. NOTHING was written." } } }
}
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
$fs = $null
try { $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $fs.Write($bytes, 0, $bytes.Length) }
catch [IO.IOException] { if (Test-Path -LiteralPath $path) { throw "A scene called '$($name -replace '\.scex$', '')' is already in the show. NOTHING was changed." }; throw }
finally { if ($fs) { $fs.Dispose() } }
$sec = ($plan | Measure-Object -Property len -Sum).Sum / 100
"  Made the scene $($name -replace '\.scex$', ''): $($plan.Count) step$(if ($plan.Count -ne 1) { 's' }), $($used.Count) head$(if ($used.Count -ne 1) { 's' }), $sec s."
"  It's a new file in the show's scenes folder - no other scene and no live button was changed."
'{"made":' + (ConvertTo-Json $name -Compress) + '}'
