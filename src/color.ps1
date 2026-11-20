# TONIGHT'S COLOR - one colour for the night (the couple's decor colour) -> two ShowXpress buttons.
#
#   TONIGHTS COLOR (MOVER COLORS page)  scene "TONIGHTS COLOR MOVERS": every 140SR / 251SR on the nearest colour of
#                                       its colour wheel. Colour channel only, so it goes on top of any movement scene.
#   TONIGHTS COLOR (UPLIGHTS page)      scene "TONIGHTS COLOR UPLIGHT": every uplight (+ the Ovation) in the exact colour.
#
#   -Action Preview                  -> JSON for the Helper window (writes nothing)
#   -Action Apply -Color RRGGBB      -> writes both scenes (and adds the 2 buttons the first time)
#   The last colour is kept in <show>/tonights_color.json.
param(
  [ValidateSet('Preview','Apply')][string]$Action = 'Preview',
  [string]$Color = '',
  [string]$Name = '',
  [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/Live/live.ini")) { throw "Show not found at '$root'. NOTHING was changed." }
$statePath = "$root/tonights_color.json"
$moverScene = 'TONIGHTS COLOR MOVERS.scex'; $upScene = 'TONIGHTS COLOR UPLIGHT.scex'
$buttons = @(@{ page = 'MOVER COLORS'; scene = $moverScene }, @{ page = 'UPLIGHTS'; scene = $upScene })

# colour wheels: name, DMX value (middle of its range), how it looks
$wheel = @{
  $m140 = @(@('White',1,'ffffff'), @('Red',5,'ff0000'), @('Yellow',9,'ffee00'), @('Green',13,'00ff00'), @('Pastel sky blue',17,'7fd4ff'),
            @('Purple',21,'8a2be2'), @('Dark yellow',26,'ffb000'), @('Blue',31,'0030ff'), @('Magenta',36,'ff00ff'), @('Light green',41,'90ff90'),
            @('Natural white',46,'fff1dc'), @('Cold white',51,'e6f2ff'), @('UV',56,'5a00ff'))
  $m251 = @(@('White',1,'ffffff'), @('Red',5,'ff0000'), @('Orange',9,'ff7a00'), @('Yellow',13,'ffee00'), @('Green',17,'00ff00'),
            @('Blue',21,'0030ff'), @('CTO (warm)',26,'ffc27a'), @('Cyan',31,'00ffff'), @('Magenta',36,'ff00ff'), @('Green 2',41,'40ff70'),
            @('Pink',46,'ff7ab8'), @('Lavender',51,'b48cff'), @('UV',56,'5a00ff'))
}
function Get-Rgb([string]$h) { @([Convert]::ToInt32($h.Substring(0,2),16), [Convert]::ToInt32($h.Substring(2,2),16), [Convert]::ToInt32($h.Substring(4,2),16)) }
function Get-Nearest($model, [string]$hex) {
  # compare the colours at full brightness (a dark navy should still pick blue, not "nothing")
  $c = Get-Rgb $hex; $mx = [Math]::Max(1, ($c | Measure-Object -Maximum).Maximum); $c = @($c | ForEach-Object { $_ * 255.0 / $mx })
  $best = $null; $bd = [double]::MaxValue
  foreach ($w in $wheel[$model]) {
    $r = Get-Rgb $w[2]; $d = 0.30 * [Math]::Pow($c[0] - $r[0], 2) + 0.59 * [Math]::Pow($c[1] - $r[1], 2) + 0.11 * [Math]::Pow($c[2] - $r[2], 2)
    if ($d -lt $bd) { $bd = $d; $best = $w }
  }
  [pscustomobject]@{ name = $best[0]; value = $best[1]; hex = $best[2] }
}

# all fixtures in the show (from every scene's fixture list) -> uplights / Ovation
function Get-ShowFixtures {
  $seen = @{}
  foreach ($f in Get-ChildItem -LiteralPath "$root/scenes" -Filter *.scex) {
    $t = [IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($t, '<Fixture id="(\d+)" name="([^"]*)" model="([^"]*)"')) {
      $id = $m.Groups[1].Value; if (-not $seen.ContainsKey($id)) { $seen[$id] = [pscustomobject]@{ Id = $id; Name = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value); Model = [Net.WebUtility]::HtmlDecode($m.Groups[3].Value) } }
    }
  }
  @($seen.Values | Sort-Object Name)
}
function Get-Washes {
  # RGB fixtures with red/green/blue channels, not movers / blinders: uplights, Ovation...
  @(foreach ($f in Get-ShowFixtures) {
    if ($f.Model -eq $m140 -or $f.Model -eq $m251 -or $f.Model -match 'blinder|OPPSK|350W') { continue }
    $p = "$root/fixtures/$($f.Model).txt"; if (-not (Test-Path -LiteralPath $p)) { continue }
    $chs = @(foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l -match '^Channel = (.+?)\s*$') { $matches[1].ToLower() } })
    if ($chs -contains 'red' -and $chs -contains 'green' -and $chs -contains 'blue') { $f | Add-Member -NotePropertyName Chs -NotePropertyValue $chs -PassThru }
  })
}
function Get-WashValues([string]$hex, $chs) {
  # exact colour: white = the common part of R/G/B (cleaner pastels), the rest on R/G/B; dimmer full
  $c = Get-Rgb $hex; $hasW = $chs -contains 'white'
  $w = if ($hasW) { ($c | Measure-Object -Minimum).Minimum } else { 0 }
  $v = @{ dimmer = 255; red = $c[0] - $w; green = $c[1] - $w; blue = $c[2] - $w; white = $w }
  @(for ($i = 0; $i -lt $chs.Count; $i++) { if ($v.ContainsKey($chs[$i])) { ,@($i, $chs[$i], [int]$v[$chs[$i]]) } elseif ($chs[$i] -match '^(amber|uv|strobe.*|.*macro.*|.*effect.*)$') { ,@($i, $chs[$i], 0) } })
}

function Get-State { if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } else { $null } }
function Get-ButtonState {
  $info = Get-LiveInfo $root
  @(foreach ($b in $buttons) { [pscustomobject]@{ page = $b.page; scene = ($b.scene -replace '\.scex$', ''); there = [bool]@($info.Buttons | Where-Object { $_.Name -eq $b.scene }).Count } })
}

if ($Action -eq 'Preview') {
  $st = Get-State
  [pscustomobject]@{
    ok = $true; show = $root; hex = $(if ($st) { "$($st.hex)" } else { '' }); name = $(if ($st) { "$($st.name)" } else { '' }); saved = $(if ($st) { "$($st.saved)" } else { '' })
    wheel140 = @($wheel[$m140] | ForEach-Object { [pscustomobject]@{ name = $_[0]; hex = $_[2] } })
    wheel251 = @($wheel[$m251] | ForEach-Object { [pscustomobject]@{ name = $_[0]; hex = $_[2] } })
    washes = @(Get-Washes | ForEach-Object { $_.Name }); buttons = Get-ButtonState
  } | ConvertTo-Json -Depth 4 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
$hex = $Color.Trim().TrimStart('#').ToLower()
if ($hex -notmatch '^[0-9a-f]{6}$') { throw "Not a colour: '$Color'. NOTHING was changed." }
$movers = @(Get-ShowMovers $root); $washes = @(Get-Washes)
$n140 = Get-Nearest $m140 $hex; $n251 = Get-Nearest $m251 $hex

function New-SceneText($fixtures, $chanOf) {
  $nl = "`n"; $sb = New-Object Text.StringBuilder; $E = { param($s) [Security.SecurityElement]::Escape($s) }
  [void]$sb.Append("<?xml version=`"1.0`" encoding=`"UTF-8`"?>$nl$nl<Scene>$nl  <Fixtures>$nl")
  foreach ($f in $fixtures) { [void]$sb.Append("    <Fixture id=`"$($f.Id)`" name=`"$(& $E $f.Name)`" model=`"$(& $E $f.Model)`"/>$nl") }
  [void]$sb.Append("  </Fixtures>$nl  <Steps>$nl    <Step length=`"300`">$nl")
  foreach ($f in $fixtures) {
    [void]$sb.Append("      <Fixture id=`"$($f.Id)`">$nl")
    foreach ($c in (& $chanOf $f)) { [void]$sb.Append("        <Channel index=`"$($c[0])`" name=`"$(& $E $c[1])`" value=`"$($c[2])`" fade=`"1`"/>$nl") }
    [void]$sb.Append("      </Fixture>$nl")
  }
  [void]$sb.Append("    </Step>$nl  </Steps>$nl</Scene>$nl"); $sb.ToString()
}
$out = @()
$utf8 = New-Object Text.UTF8Encoding($false)
$mt = New-SceneText $movers { param($f) ,@(,@(5, 'color', $(if ($f.Model -eq $m140) { $n140.value } else { $n251.value }))) }
[IO.File]::WriteAllText("$root/scenes/$moverScene", $mt, $utf8)
$out += "  CHANGED  TONIGHTS COLOR MOVERS: 140s on $($n140.name), 251s on $($n251.name)"
if ($washes.Count) {
  $ut = New-SceneText $washes { param($f) Get-WashValues $hex $f.Chs }
  [IO.File]::WriteAllText("$root/scenes/$upScene", $ut, $utf8)
  $out += "  CHANGED  TONIGHTS COLOR UPLIGHT: #$hex on $(($washes | ForEach-Object Name) -join ', ')"
} else { $out += "  no uplights found - only the movers scene was made" }

# buttons, the first time: first free cell on the MOVER COLORS / UPLIGHTS page
$ini = Read-LiveIni $root; $info = Get-LiveInfo $root $ini
foreach ($b in $buttons) {
  if ($b.scene -eq $upScene -and -not $washes.Count) { continue }
  if (@($info.Buttons | Where-Object { $_.Name -eq $b.scene }).Count) { continue }
  $pg = $null; foreach ($k in $info.Pages.Keys) { if ("$($info.Pages[$k])".Trim() -eq $b.page) { $pg = $k } }
  if ($null -eq $pg) { $out += "  no live page called $($b.page) - add a button for $($b.scene -replace '\.scex$', '') yourself"; continue }
  $cell = Add-LiveButton $ini $info $pg $b.scene 'TONIGHTS COLOR'
  $info = Get-LiveInfo $root $ini
  $out += "  CHANGED  added the TONIGHTS COLOR button to the $($b.page) page (line $($cell[0]), column $($cell[1]))"
}
[void](Save-LiveIni $ini)
[IO.File]::WriteAllText($statePath, ([ordered]@{ hex = $hex; name = $Name; saved = (Get-Date).ToString('s'); mover140 = $n140.name; mover251 = $n251.name } | ConvertTo-Json), $utf8)
$out
