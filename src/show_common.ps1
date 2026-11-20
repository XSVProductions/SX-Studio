# ShowXpress Helper - shared bits, dot-sourced by df_aim.ps1 (aim movers) and skip_flash.ps1 (skip flash heads).
# Runs on Windows (PowerShell 5.1, Boot Camp side) and macOS (PowerShell 7 "pwsh").
$onMac = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
$m140  = 'Intimidator Hybrid 140SR (19ch)'
$m251  = 'IntimidatorHybrid251Sr(19ch)'

# Show folder: 1) path in show_path.txt  (Mac: ~/AwaazTools/show_path.txt, written by "SYNC FROM WINDOWS";
#              Windows: %APPDATA%\ShowXpress Helper\show_path.txt - optional; the old AIM MOVERS folder still works)
#              2) ~/TheLightingController/LightShows/Awaaz Lightshow   3) the only show there that has a CENTER SPOT scene
function Find-Show {
  $pfs = if ($onMac) { @(Join-Path $HOME 'AwaazTools/show_path.txt') }
         else { @((Join-Path $env:APPDATA 'ShowXpress Helper/show_path.txt'), (Join-Path $env:APPDATA 'AIM MOVERS/show_path.txt')) }
  foreach ($pf in $pfs) {
    if (Test-Path -LiteralPath $pf) {
      $p = "$(Get-Content -LiteralPath $pf -TotalCount 1)".Trim()
      if ($p -and (Test-Path -LiteralPath "$p/Live/live.ini")) { return $p }
    }
  }
  $ls = Join-Path $HOME 'TheLightingController/LightShows'
  $def = Join-Path $ls 'Awaaz Lightshow'
  if (Test-Path -LiteralPath "$def/Live/live.ini") { return $def }
  if (Test-Path -LiteralPath $ls) {
    $c = @(Get-ChildItem -LiteralPath $ls -Directory | Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'Live/live.ini')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'scenes/CENTER SPOT.scex')) })
    if ($c.Count -eq 1) { return $c[0].FullName }
  }
  if ($onMac) { throw "Mac show folder not known yet - run SYNC FROM WINDOWS once first. NOTHING was changed." }
  throw "Can't find the show. Write its folder path into $($pfs[0]) and try again. NOTHING was changed."
}

function Test-SxRunning { [bool](Get-Process | Where-Object { $_.ProcessName -match 'TheLightingController|ShowXpress' }) }

function Get-ShowMovers($root) {
  # all 140SR + 251SR in the show, from the CENTER SPOT scene's fixture list (has all 22)
  $cs = "$root/scenes/CENTER SPOT.scex"; if (-not (Test-Path -LiteralPath $cs)) { $cs = "$root/scenes/CENTER SPOT (adjust).scex" }
  if (-not (Test-Path -LiteralPath $cs)) { throw "Scene CENTER SPOT not found in the show - it's used to list the movers. NOTHING was changed." }
  [xml]$x = [IO.File]::ReadAllText($cs)
  $list = foreach ($f in $x.Scene.Fixtures.Fixture) {
    $nm = $f.GetAttribute('name'); $mo = $f.GetAttribute('model')
    if ($mo -ne $m140 -and $mo -ne $m251) { continue }
    $num = 1; $mm = [regex]::Matches($nm, '#(\d+)'); if ($mm.Count) { $num = [int]$mm[$mm.Count-1].Groups[1].Value }
    if ($nm -like '*#4 #2 #2') { $num = 6 } elseif ($nm -like '*#4 #2') { $num = 5 }
    [pscustomobject]@{ Id = $f.GetAttribute('id'); Name = $nm; Model = $mo; Num = $num; Is140 = ($mo -eq $m140) }
  }
  $list | Sort-Object @{e={-[int]$_.Is140}}, Num
}

function Get-Label($m) { if ($m.Is140) { "140 #$($m.Num)" } else { "251 #$($m.Num)" } }
