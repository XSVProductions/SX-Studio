# REVERSE HEADS - the Helper's own pan / tilt reverse, instead of changing the setting in the fixture's menu (user 2026-11-23).
#
#   Tower pairs are meant to cross each other. When a head gets hung so it moves the same way as its partner, the user used
#   to change Pan / Tilt Reverse in that fixture's own menu. ShowXpress's reverse ticks in the fixture settings don't change
#   the real heads (user 2026-11-23), so the Helper does it in the show itself - exactly what the fixture's menu does:
#     scenes (.scex)       : that head's pan + fine pan (and/or tilt + fine tilt) value v -> 255 - v in every step
#     movements (.gpj)     : that head's ReversePan / ReverseTilt switched (ShowXpress then sends 65535 - its value)
#   Doing it again puts every value back exactly, so "back to normal" = untick. Every scene and movement in the show is done,
#   so all of them stay in step. Tonight's Rig's kept full scenes (rig_state.json) are reversed too.
#   Aim Movers, Rig Test and the live aim/colour preview know about it (show_common.ps1: Get-FlipState / ConvertTo-SentPos).
#
#   -Action Preview                     -> JSON: heads + which are reversed now (writes nothing)
#   -Action Apply -ChangesFile <json>   -> {"flip":{"<id>":{"pan":true,"tilt":false},...}} = the FULL list (a head left out = normal)
param(
  [ValidateSet('Preview','Apply')][string]$Action = 'Preview',
  [string]$ChangesFile = '',
  [string]$TestRoot = ''   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/Live/live.ini")) { throw "Show not found at '$root'. NOTHING was changed." }
$statePath = "$root/flip_state.json"
$movers = @(Get-ShowMovers $root)
if (-not $movers.Count) { throw "No 140SR/251SR fixtures found in the show. NOTHING was changed." }
$byId = @{}; foreach ($m in $movers) { $byId[$m.Id] = $m }
$cur = Get-FlipState $root

if ($Action -eq 'Preview') {
  [pscustomobject]@{ ok = $true; show = $root
    heads = @(foreach ($m in $movers) { $f = $cur[$m.Id]
      [pscustomobject]@{ id = $m.Id; label = (Get-Label $m); is140 = $m.Is140; pan = [bool]($f -and $f.pan); tilt = [bool]($f -and $f.tilt) } }) } | ConvertTo-Json -Depth 4 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
if (-not $ChangesFile -or -not (Test-Path -LiteralPath $ChangesFile)) { throw "No changes were sent. NOTHING was changed." }
$j = [IO.File]::ReadAllText($ChangesFile) | ConvertFrom-Json
$want = @{}
if ($j.flip) { foreach ($q in $j.flip.PSObject.Properties) {
  if (-not $byId.ContainsKey("$($q.Name)")) { throw "Unknown head '$($q.Name)'. NOTHING was changed." }
  $pn = [bool]$q.Value.pan; $tl = [bool]$q.Value.tilt
  if ($pn -or $tl) { $want["$($q.Name)"] = @{ pan = $pn; tilt = $tl } } } }

# what has to switch = wanted XOR what the show has now
$delta = @{}
foreach ($m in $movers) {
  $a = $cur[$m.Id]; $b = $want[$m.Id]
  $dp = [bool]($a -and $a.pan) -ne [bool]($b -and $b.pan); $dt = [bool]($a -and $a.tilt) -ne [bool]($b -and $b.tilt)
  if ($dp -or $dt) { $delta[$m.Id] = @{ pan = $dp; tilt = $dt } }
}
if (-not $delta.Count) { "  nothing to change - the show already has these heads reversed"; return }

function Switch-SceneText([string]$text) {
  # every step block <Fixture id="X"> ... </Fixture> of a switched head: pan/upan and/or tilt/utilt value v -> 255 - v
  $script:nCh = 0
  $new = [regex]::Replace($text, '(?s)(<Fixture id="(\d+)">)(.*?)(</Fixture>)', [Text.RegularExpressions.MatchEvaluator]{ param($m)
    $d = $delta[$m.Groups[2].Value]
    if (-not $d) { return $m.Value }
    $body = [regex]::Replace($m.Groups[3].Value, '<Channel\b[^>]*>', [Text.RegularExpressions.MatchEvaluator]{ param($c)
      $s = $c.Value
      if ($s -notmatch 'name="(u?pan|u?tilt)"') { return $s }
      $ax = if ($matches[1] -like '*pan') { 'pan' } else { 'tilt' }
      if (-not $d[$ax] -or $s -notmatch 'value="(\d+)"') { return $s }
      $v = [int]$matches[1]; if ($v -gt 255) { return $s }
      $script:nCh++
      $s -replace 'value="\d+"', "value=`"$(255 - $v)`"" })
    $m.Groups[1].Value + $body + $m.Groups[4].Value })
  @{ text = $new; n = $script:nCh }
}

function Switch-GpjText([string]$text) {
  # [Fixture_n] section of a switched head: ReversePan / ReverseTilt 0 <-> 1 (a missing line counts as 0 and is added)
  $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $out = New-Object Collections.Generic.List[string]; $id = $null; $inFx = $false; $seen = @{}; $n = 0
  $close = {
    if (-not ($inFx -and $id -and $delta[$id])) { return }
    foreach ($ax in 'Pan', 'Tilt') {
      if ($delta[$id][$ax.ToLower()] -and -not $seen[$ax]) {
        $at = $out.Count; while ($at -gt 0 -and -not $out[$at - 1].Trim()) { $at-- }
        $out.Insert($at, "Reverse$ax = 1"); $script:gN++ } }
  }
  $script:gN = 0
  foreach ($ln in ($text -split "`r?`n")) {
    if ($ln -match '^\[') { . $close; $inFx = $ln -match '^\[Fixture_\d+\]$'; $id = $null; $seen = @{}; $out.Add($ln); continue }
    if ($inFx -and $ln -match '^ID = (\d+)$') { $id = $matches[1] }
    if ($inFx -and $id -and $delta[$id] -and $ln -match '^Reverse(Pan|Tilt) = (\d+)$') {
      $ax = $matches[1]; $seen[$ax] = $true
      if ($delta[$id][$ax.ToLower()]) { $ln = "Reverse$ax = $(if ($matches[2] -eq '0') { 1 } else { 0 })"; $script:gN++ }
    }
    $out.Add($ln)
  }
  . $close
  @{ text = ($out -join $nl); n = $script:gN }
}

# ---- every scene + movement in the show (all of them, so nothing gets out of step)
$files = @()
foreach ($d in @("$root/scenes", "$root/Editor/Generator/projects")) {
  if (Test-Path -LiteralPath $d) { $files += @(Get-ChildItem -LiteralPath $d -File | Where-Object { $_.Extension -in '.scex', '.gpj' }) }
}
$writes = @{}; $nScene = 0; $nMove = 0; $nVal = 0
foreach ($f in $files) {
  $t = [IO.File]::ReadAllText($f.FullName)
  $r = if ($f.Extension -eq '.gpj') { Switch-GpjText $t } else { Switch-SceneText $t }
  if ($r.n -and $r.text -ne $t) {
    $writes[$f.FullName] = $r.text; $nVal += $r.n
    if ($f.Extension -eq '.gpj') { $nMove++ } else { $nScene++ }
  }
}

# ---- Tonight's Rig keeps the full version of trimmed chase scenes: reverse those too, so putting them back stays right
$rsPath = "$root/rig_state.json"; $rsOut = $null; $nRig = 0
if (Test-Path -LiteralPath $rsPath) {
  $rs = [IO.File]::ReadAllText($rsPath) | ConvertFrom-Json
  $sc = [ordered]@{}
  if ($rs.scenes) { foreach ($q in $rs.scenes.PSObject.Properties) {
    $orig = "$($q.Value.original)"; $wr = "$($q.Value.written)"; $p = "$root/scenes/$($q.Name)"
    if ((Test-Path -LiteralPath $p) -and (Get-TextSha ([IO.File]::ReadAllText($p))) -eq $wr) {
      $o2 = (Switch-SceneText $orig).text
      $fileNow = if ($writes.ContainsKey((Get-Item -LiteralPath $p).FullName)) { $writes[(Get-Item -LiteralPath $p).FullName] } else { [IO.File]::ReadAllText($p) }
      if ($o2 -ne $orig) { $nRig++ }
      $orig = $o2; $wr = Get-TextSha $fileNow
    }
    $sc[$q.Name] = [ordered]@{ original = $orig; written = $wr } } }
  $rsOut = [ordered]@{ hung = $(if ($rs.hung) { @($rs.hung | ForEach-Object { "$_" }) } else { $null }); scenes = $sc }
}

# ---- write (each file keeps its own BOM / line endings)
foreach ($p in $writes.Keys) {
  $b = [IO.File]::ReadAllBytes($p); $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  [IO.File]::WriteAllText($p, $writes[$p], (New-Object Text.UTF8Encoding($bom)))
}
if ($rsOut) { [IO.File]::WriteAllText($rsPath, ($rsOut | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false))) }
if ($want.Count) {
  $hs = [ordered]@{}; foreach ($m in $movers) { if ($want[$m.Id]) { $hs[$m.Id] = [ordered]@{ label = (Get-Label $m); pan = $want[$m.Id].pan; tilt = $want[$m.Id].tilt } } }
  [IO.File]::WriteAllText($statePath, ([ordered]@{ saved = (Get-Date).ToString('s'); heads = $hs } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
} elseif (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }

foreach ($m in $movers) {
  if (-not $delta[$m.Id]) { continue }
  $w = $want[$m.Id]; $now = @(); if ($w -and $w.pan) { $now += 'pan' }; if ($w -and $w.tilt) { $now += 'tilt' }
  "  CHANGED  $(Get-Label $m): " + $(if ($now.Count) { "$($now -join ' + ') reversed by the Helper" } else { 'back to normal (not reversed)' })
}
"  $nScene scenes + $nMove movements updated ($nVal values)" + $(if ($nRig) { ", $nRig kept full chase scene(s) of Tonight's Rig too" } else { '' })
