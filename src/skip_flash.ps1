# SKIP FLASH heads - picks which movers the ShowXpress button SKIP FLASH uses tonight.
#
#   The SKIP FLASH scene flashes ONE head per step (white), skipping around the rig. A head that's in the scene but
#   not set up at the venue still gets its step, so the chase has a dark gap and looks like it stutters. So the scene
#   should only contain the heads that are actually hung tonight.
#
#   -Action Preview                  -> JSON for the ShowXpress Helper window (writes nothing)
#   -Action Apply -Heads "id,id,..." -> rebuilds the SKIP FLASH scene with just those heads
#
#   What's kept from the current scene: the step time and the lit / dark channel values per model (so a colour or
#   speed change made in ShowXpress survives). Heads flash in the original 16-head "skip" order (from the first
#   version of the scene); 251s, if picked, are spread evenly in between.
#   Heads that aren't picked are left out of the scene completely (not held dark).
param(
  [ValidateSet('Preview','Apply')][string]$Action = 'Preview',
  [string]$Heads = '',
  [string]$TestRoot = ''   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')   # Find-Show, Test-SxRunning, Get-ShowMovers, Get-Label, $m140, $m251

# flash order by head number (140 order = the user's original 16-head SKIP FLASH scene)
$order140 = @(2, 12, 14, 7, 9, 6, 16, 3, 1, 13, 11, 8, 10, 4, 5, 15)
$order251 = @(1, 4, 2, 5, 3, 6)
$buttonTitle = 'SKIP FLASH'
$defaultCs = 2

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/Live/live.ini")) { throw "Show not found at '$root'. NOTHING was changed." }

function Find-SkipScene {
  # the scene behind the live button titled SKIP FLASH (any page); else scenes/SKIP FLASH.scex
  $on = $false; $isBtn = $false; $name = $null; $title = $null
  foreach ($l in (Get-Content -LiteralPath "$root/Live/live.ini" -Encoding UTF8)) {
    if ($l -match '^\[') {
      if ($isBtn -and $title -eq $buttonTitle -and $name) { break }
      $isBtn = $l -match '^\[page\d+_button\d+\]$'; $name = $null; $title = $null; continue
    }
    if ($isBtn -and $l -match '^name = (.+\.scex)\s*$') { $name = $matches[1] }
    if ($isBtn -and $l -match '^title = (.*?)\s*$') { $title = $matches[1] }
  }
  $file = if ($isBtn -and $title -eq $buttonTitle -and $name) { $name } else { "$buttonTitle.scex" }
  $p = "$root/scenes/$file"
  if (-not (Test-Path -LiteralPath $p)) { throw "Scene for the SKIP FLASH button not found ($file). NOTHING was changed." }
  $p
}

$movers = @(Get-ShowMovers $root)
if ($movers.Count -eq 0) { throw "No 140SR/251SR fixtures found in the show. NOTHING was changed." }
$scenePath = Find-SkipScene
$text = [IO.File]::ReadAllText($scenePath)
[xml]$x = $text

# ---- what's in the scene now
$inScene = @{}; foreach ($f in @($x.Scene.Fixtures.Fixture)) { if ($f) { $inScene[$f.GetAttribute('id')] = $true } }
$steps = @($x.Scene.Steps.Step | Where-Object { $_ })
$stepCs = $defaultCs
if ($steps.Count -and $steps[0].GetAttribute('length') -match '^\d+$') { $stepCs = [int]$steps[0].GetAttribute('length') }

# lit / dark channel templates per model, taken from the scene (fallback = white flash, everything else 0)
function New-Tpl($names, [int]$on) {
  ,@(foreach ($c in $names) { $v = if ($on -and ($c[1] -eq 'dimmer' -or $c[1] -eq 'shutter')) { 255 } else { 0 }; @{ index = $c[0]; name = $c[1]; value = $v; fade = $null } })
}
$chans = @{ $m140 = @(@(5,'color'), @(15,'dimmer'), @(16,'shutter'), @(17,'mode'), @(18,'movement_macro'))
            $m251 = @(@(5,'color'), @(15,'dimmer'), @(16,'shutter'), @(17,'control'), @(18,'movement_macro')) }
$tpl = @{}
foreach ($mo in $m140, $m251) { $tpl[$mo] = @{ lit = (New-Tpl $chans[$mo] 1); dark = (New-Tpl $chans[$mo] 0); fromScene = @{} } }
$modelOf = @{}; foreach ($m in $movers) { $modelOf[$m.Id] = $m.Model }
foreach ($s in $steps) {
  foreach ($fx in @($s.Fixture | Where-Object { $_ })) {
    $mo = $modelOf[$fx.GetAttribute('id')]; if (-not $mo) { continue }
    $ch = @(foreach ($c in @($fx.Channel | Where-Object { $_ })) {
      @{ index = [int]$c.GetAttribute('index'); name = $c.GetAttribute('name'); value = [int]$c.GetAttribute('value'); fade = $(if ($c.HasAttribute('fade')) { $c.GetAttribute('fade') } else { $null }) } })
    $dim = @($ch | Where-Object { $_.name -eq 'dimmer' })
    $kind = if ($dim.Count -and $dim[0].value -gt 0) { 'lit' } else { 'dark' }
    if (-not $tpl[$mo].fromScene[$kind] -and $ch.Count) { $tpl[$mo][$kind] = $ch; $tpl[$mo].fromScene[$kind] = $true }
  }
}

function Get-FlashOrder($picked) {
  # picked movers -> flash order: 140s in the skip order, 251s spread evenly in between
  $a = @(foreach ($n in $order140) { $picked | Where-Object { $_.Is140 -and $_.Num -eq $n } })
  $a += @($picked | Where-Object { $_.Is140 -and $order140 -notcontains $_.Num })
  $b = @(foreach ($n in $order251) { $picked | Where-Object { -not $_.Is140 -and $_.Num -eq $n } })
  $b += @($picked | Where-Object { -not $_.Is140 -and $order251 -notcontains $_.Num })
  $out = @(); $i = 0; $j = 0
  while ($i -lt $a.Count -or $j -lt $b.Count) {
    $takeA = ($j -ge $b.Count) -or ($i -lt $a.Count -and (($i + 0.5) / $a.Count) -le (($j + 0.5) / $b.Count))
    if ($takeA) { $out += $a[$i]; $i++ } else { $out += $b[$j]; $j++ }
  }
  ,$out
}

if ($Action -eq 'Preview') {
  $picked = @($movers | Where-Object { $inScene[$_.Id] })
  $order = Get-FlashOrder $picked
  $unknown = @($inScene.Keys | Where-Object { -not $modelOf[$_] }).Count
  [pscustomobject]@{
    ok = $true; show = $root; scene = [IO.Path]::GetFileNameWithoutExtension($scenePath); stepCs = $stepCs; unknown = $unknown
    heads = @(foreach ($m in $movers) { [pscustomobject]@{ id = $m.Id; label = (Get-Label $m); num = $m.Num; is140 = $m.Is140; on = [bool]$inScene[$m.Id] } })
    order = @($order | ForEach-Object { Get-Label $_ })
    order140 = $order140; order251 = $order251
  } | ConvertTo-Json -Depth 4 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
$ids = @($Heads -split '[,;\s]+' | Where-Object { $_ })
$bad = @($ids | Where-Object { -not $modelOf[$_] })
if ($bad.Count) { throw "Unknown head(s): $($bad -join ', '). NOTHING was changed." }
$picked = @($movers | Where-Object { $ids -contains $_.Id })
if ($picked.Count -lt 2) { throw "Pick at least 2 heads - with 1 head SKIP FLASH would just stay on. NOTHING was changed." }
$order = Get-FlashOrder $picked

$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
$bytes = [IO.File]::ReadAllBytes($scenePath)
$bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }
function Add-Block($L, $m, $chs) {
  $L.Add("      <Fixture id=`"$($m.Id)`">")
  foreach ($c in $chs) {
    $fade = if ($null -ne $c.fade) { " fade=`"$($c.fade)`"" } else { '' }
    $L.Add("        <Channel index=`"$($c.index)`" name=`"$(Esc $c.name)`" value=`"$($c.value)`"$fade/>")
  }
  $L.Add('      </Fixture>')
}
$L = New-Object Collections.Generic.List[string]
$L.Add('  <Fixtures>')
foreach ($m in $picked) { $L.Add("    <Fixture id=`"$($m.Id)`" name=`"$(Esc $m.Name)`" model=`"$(Esc $m.Model)`"/>") }
$L.Add('  </Fixtures>'); $L.Add('  <Steps>')
foreach ($lit in $order) {
  $L.Add("    <Step length=`"$stepCs`">")
  foreach ($m in $picked) { Add-Block $L $m $(if ($m.Id -eq $lit.Id) { $tpl[$m.Model].lit } else { $tpl[$m.Model].dark }) }
  $L.Add('    </Step>')
}
$L.Add('  </Steps>')
# keep everything before <Fixtures> and after </Steps> exactly as it was
$i1 = $text.IndexOf('<Fixtures>'); $i2 = $text.LastIndexOf('</Steps>')
if ($i1 -lt 0 -or $i2 -lt 0) { throw "SKIP FLASH scene doesn't look like a normal scene file. NOTHING was changed." }
$pre = $text.Substring(0, $text.LastIndexOf("`n", $i1) + 1)
$post = $text.Substring($i2 + '</Steps>'.Length)
$new = $pre + ($L -join $nl) + $post
if ($new -eq $text) { "  SKIP FLASH already uses exactly these heads - nothing to change." }
else {
  [IO.File]::WriteAllText($scenePath, $new, (New-Object Text.UTF8Encoding($bom)))
  "  SKIP FLASH scene rebuilt: $([IO.Path]::GetFileName($scenePath))"
}
"  heads: $($picked.Count)  ($(@($picked | Where-Object Is140).Count) x 140SR, $(@($picked | Where-Object { -not $_.Is140 }).Count) x 251SR)"
"  flash order: $(($order | ForEach-Object { Get-Label $_ }) -join ' > ')"
"  loop: {0:0.00} s  ({1} steps x {2} cs)" -f ($order.Count * $stepCs / 100), $order.Count, $stepCs
