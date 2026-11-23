# TONIGHT'S RIG - tick the movers that are hung tonight; every chase scene drops the steps that would be dark without them.
#
#   A chase (CHASE, SKIP AROUND, BEAT LEFT RIGHT, SKIP FLASH...) lights different heads on different steps. If all the
#   heads of a step aren't hung at the venue, that step is a dark gap and the chase stutters. This takes those steps
#   out (plus any all-dark "gap" steps that follow them, so the rhythm stays the same) and puts them back later.
#
#   -Action Preview                   -> JSON for the SX Helper window (writes nothing)
#   -Action Apply -Heads "id,id,..."  -> trims / restores every chase scene on a live button
#
#   The full scenes are kept in <show>/rig_state.json while they are trimmed, so ticking every head puts them back
#   exactly. If a trimmed scene was changed in ShowXpress since, the changed version counts as the full scene from then on.
#   Only steps are removed - nothing else in a scene is touched. A step that also lights a blinder/uplight is never removed.
param(
  [ValidateSet('Preview','Apply')][string]$Action = 'Preview',
  [string]$Heads = '',
  [string]$TestRoot = ''   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/Live/live.ini")) { throw "Show not found at '$root'. NOTHING was changed." }
$statePath = "$root/rig_state.json"

$movers = @(Get-ShowMovers $root)
if ($movers.Count -eq 0) { throw "No 140SR/251SR fixtures found in the show. NOTHING was changed." }
$modelOf = @{}; foreach ($m in $movers) { $modelOf[$m.Id] = $m.Model }
$labelOf = @{}; foreach ($m in $movers) { $labelOf[$m.Id] = Get-Label $m }

# ---- state
$state = @{ hung = $null; scenes = @{} }
if (Test-Path -LiteralPath $statePath) {
  $j = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
  if ($j.hung) { $state.hung = @($j.hung | ForEach-Object { "$_" }) }
  if ($j.scenes) { foreach ($p in $j.scenes.PSObject.Properties) { $state.scenes[$p.Name] = @{ original = "$($p.Value.original)"; written = "$($p.Value.written)" } } }
}

# ---- chase scenes: every .scex on a live button whose lit steps don't all light the same movers (+ any still trimmed)
$info = Get-LiveInfo $root
$byFile = [ordered]@{}
# SKIP FLASH is rebuilt with just the hung heads by skip_flash.ps1 (the Helper runs it together with this) - not trimmed here
$skipFile = @($info.Buttons | Where-Object { $_.Title -eq 'SKIP FLASH' -and $_.Name -like '*.scex' } | ForEach-Object Name)
foreach ($f in $skipFile) { $state.scenes.Remove($f) }
foreach ($b in $info.Buttons) {
  if ($b.Name -notlike '*.scex' -or $skipFile -contains $b.Name) { continue }
  if (-not $byFile.Contains($b.Name)) { $byFile[$b.Name] = New-Object Collections.Generic.List[string] }
  $t = if ($b.Title) { $b.Title } else { $b.Name -replace '\.scex$', '' }
  if (-not $byFile[$b.Name].Contains($t)) { $byFile[$b.Name].Add($t) }
}
foreach ($f in $state.scenes.Keys) { if (-not $byFile.Contains($f)) { $byFile[$f] = New-Object Collections.Generic.List[string] } }

$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "sxh_rig_$PID"
function Get-StepsOfText([string]$text) {
  if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory $tmpDir | Out-Null }
  $p = Join-Path $tmpDir 'scene.scex'; [IO.File]::WriteAllText($p, $text)
  Get-SceneSteps $root $p $modelOf
}

function Get-Groups($steps) {
  # lit step + the all-dark steps after it (leading dark steps belong to the last group, the scene loops)
  $li = @(for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i].lit.Count -or $steps[$i].other) { $i } })
  if ($li.Count -lt 2) { return ,@() }
  ,@(for ($k = 0; $k -lt $li.Count; $k++) {
    $end = if ($k + 1 -lt $li.Count) { $li[$k + 1] - 1 } else { $steps.Count - 1 }
    $idx = @($li[$k]..$end); if ($k + 1 -eq $li.Count -and $li[0] -gt 0) { $idx += @(0..($li[0] - 1)) }
    ,@($idx)
  })
}
function Get-DropSteps($steps, $hung) {
  # -> step indexes to remove for this set of hung heads; $null = every step would go (leave the scene alone)
  $groups = Get-Groups $steps; $drop = @(); $kept = 0
  foreach ($g in $groups) {
    $s = $steps[$g[0]]
    $gone = (-not $s.other) -and $s.lit.Count -and -not @($s.lit | Where-Object { $hung.Contains($_) }).Count
    if ($gone) { $drop += $g } else { $kept++ }
  }
  if ($groups.Count -and $kept -eq 0) { return $null }
  ,@($drop | Sort-Object)
}
function Test-Chase($steps) {
  $sets = @(foreach ($s in $steps) { if ($s.lit.Count -or $s.other) { ((@($s.lit) | Sort-Object) -join ',') + "|$($s.other)" } })
  @($sets | Select-Object -Unique).Count -gt 1 -and @($steps | Where-Object { $_.lit.Count }).Count -gt 0
}
function Remove-Steps([string]$text, $drop) {
  $rx = [regex]'(?s)\r?\n[ \t]*<Step\b(?:[^>]*/>|[^>]*>.*?</Step>)'
  $ms = $rx.Matches($text)
  $sb = New-Object Text.StringBuilder; $pos = 0
  for ($i = 0; $i -lt $ms.Count; $i++) {
    if ($drop -contains $i) { [void]$sb.Append($text.Substring($pos, $ms[$i].Index - $pos)); $pos = $ms[$i].Index + $ms[$i].Length }
  }
  [void]$sb.Append($text.Substring($pos)); $sb.ToString()
}

$scenes = New-Object Collections.Generic.List[object]
foreach ($f in $byFile.Keys) {
  $p = "$root/scenes/$f"
  if (-not (Test-Path -LiteralPath $p)) { continue }
  $cur = [IO.File]::ReadAllText($p)
  $st = $state.scenes[$f]; $trimmed = $false; $edited = $false
  if ($st -and (Get-TextSha $cur) -eq $st.written) { $base = $st.original; $trimmed = $true }
  else { $base = $cur; if ($st) { $edited = $true } }
  $steps = if ($trimmed) { Get-StepsOfText $base } else { Get-SceneSteps $root $p $modelOf }
  if (-not $st -and -not (Test-Chase $steps)) { continue }
  $rxCount = ([regex]'(?s)\r?\n[ \t]*<Step\b(?:[^>]*/>|[^>]*>.*?</Step>)').Matches($base).Count
  if ($rxCount -ne $steps.Count) { continue }   # unusual file layout - never touch it
  $scenes.Add([pscustomobject]@{ File = $f; Path = $p; Cur = $cur; Base = $base; Steps = $steps; Trimmed = $trimmed; Edited = $edited; Titles = @($byFile[$f]) })
}
if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }

if ($Action -eq 'Preview') {
  $hung = if ($state.hung) { $state.hung } else { @($movers | ForEach-Object Id) }
  [pscustomobject]@{
    ok = $true; show = $root
    heads = @(foreach ($m in $movers) { [pscustomobject]@{ id = $m.Id; label = (Get-Label $m); num = $m.Num; is140 = $m.Is140; on = ($hung -contains $m.Id) } })
    scenes = @(foreach ($s in $scenes) {
      [pscustomobject]@{
        file = $s.File; name = ($s.File -replace '\.scex$', ''); titles = $s.Titles; trimmed = $s.Trimmed; edited = $s.Edited
        groups = (Get-Groups $s.Steps)
        steps = @(foreach ($x in $s.Steps) { [pscustomobject]@{ cs = $x.cs; lit = @($x.lit); other = $x.other } })
      } })
  } | ConvertTo-Json -Depth 6 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
$ids = @($Heads -split '[,;\s]+' | Where-Object { $_ })
$bad = @($ids | Where-Object { -not $modelOf.ContainsKey($_) })
if ($bad.Count) { throw "Unknown head(s): $($bad -join ', '). NOTHING was changed." }
if (-not $ids.Count) { throw "Tick at least one head. NOTHING was changed." }
$hungSet = New-Object 'Collections.Generic.HashSet[string]'; foreach ($i in $ids) { [void]$hungSet.Add($i) }

$writes = @(); $lines = @(); $newState = @{}
foreach ($s in $scenes) {
  $drop = Get-DropSteps $s.Steps $hungSet
  $note = ''
  if ($null -eq $drop) { $drop = @(); $note = ' (none of its heads are hung - left complete)' }
  $new = if ($drop.Count) { Remove-Steps $s.Base $drop } else { $s.Base }
  if ($drop.Count) { $newState[$s.File] = @{ original = $s.Base; written = (Get-TextSha $new) } }
  $kept = $s.Steps.Count - $drop.Count
  $what = if ($drop.Count) { "$kept of $($s.Steps.Count) steps" } else { "all $($s.Steps.Count) steps" }
  if ($s.Edited) { $note += ' (changed in ShowXpress since last time - that version now counts as the full scene)' }
  if ($new -ne $s.Cur) { $writes += ,@($s.Path, $new); $lines += "  CHANGED  $($s.File -replace '\.scex$', ''): $what$note" }
  else { $lines += "  same     $($s.File -replace '\.scex$', ''): $what$note" }
}
foreach ($w in $writes) {
  $bytes = [IO.File]::ReadAllBytes($w[0])
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  [IO.File]::WriteAllText($w[0], $w[1], (New-Object Text.UTF8Encoding($bom)))
}
$allHung = ($ids.Count -eq $movers.Count)
$o = [ordered]@{ hung = $(if ($allHung) { $null } else { @($ids) }); scenes = $newState }
if (-not $allHung -or $newState.Count) { [IO.File]::WriteAllText($statePath, ($o | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false))) }
elseif (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
"  heads hung: $($ids.Count) of $($movers.Count)" + $(if (-not $allHung) { "  (not hung: $((@($movers | Where-Object { -not $hungSet.Contains($_.Id) } | ForEach-Object { Get-Label $_ })) -join ', '))" } else { '' })
"  chase scenes: $($scenes.Count), changed: $($writes.Count)"
$lines
