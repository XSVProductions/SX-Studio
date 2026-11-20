# ShowXpress Helper - shared bits, dot-sourced by df_aim.ps1 (aim movers) and skip_flash.ps1 (skip flash heads).
# Runs on Windows (PowerShell 5.1, Boot Camp side) and macOS (PowerShell 7 "pwsh").
$onMac = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
$m140  = 'Intimidator Hybrid 140SR (19ch)'
$m251  = 'IntimidatorHybrid251Sr(19ch)'

# Show folder: 1) path in show_path.txt  (Mac: ~/AwaazTools/show_path.txt;
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
  if ($onMac) { throw "Mac show folder not found. Copy the show from Google Drive > AWAAZ > Lighting into ~/TheLightingController/LightShows, or write its folder path into ~/AwaazTools/show_path.txt. NOTHING was changed." }
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

# ---------------------------------------------------------------- live.ini (UTF-8 BOM, CRLF - kept exactly as found)
function Read-LiveIni($root) {
  $p = "$root/Live/live.ini"
  if (-not (Test-Path -LiteralPath $p)) { throw "Live/live.ini not found in the show. NOTHING was changed." }
  $b = [IO.File]::ReadAllBytes($p)
  $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  $o = if ($bom) { 3 } else { 0 }
  $t = [Text.Encoding]::UTF8.GetString($b, $o, $b.Length - $o)
  $nl = if ($t -match "`r`n") { "`r`n" } else { "`n" }
  $L = New-Object Collections.Generic.List[string]
  foreach ($x in ($t -split "`r?`n")) { $L.Add($x) }
  [pscustomobject]@{ Path = $p; Bom = $bom; Nl = $nl; Lines = $L; Text = $t }
}
function Save-LiveIni($ini) {
  $new = $ini.Lines -join $ini.Nl
  if ($new -eq $ini.Text) { return $false }
  [IO.File]::WriteAllText($ini.Path, $new, (New-Object Text.UTF8Encoding($ini.Bom)))
  $true
}
function Find-IniSection($ini, [string]$name) {
  # -> @(header index, end index exclusive - trailing blank lines left out) or $null
  $L = $ini.Lines; $h = "[$name]"; $s = -1
  for ($i = 0; $i -lt $L.Count; $i++) {
    if ($s -lt 0) { if ($L[$i] -eq $h) { $s = $i } }
    elseif ($L[$i] -match '^\[') { break }
  }
  if ($s -lt 0) { return $null }
  $e = $i; while ($e -gt $s + 1 -and -not $L[$e - 1].Trim()) { $e-- }
  ,@($s, $e)
}
function Get-IniKeys($ini, [string]$name) {
  $r = @{}; $se = Find-IniSection $ini $name; if (-not $se) { return $r }
  for ($i = $se[0] + 1; $i -lt $se[1]; $i++) {
    $l = $ini.Lines[$i]; $k = $l.IndexOf(' =')
    if ($k -gt 0) { $v = $l.Substring($k + 2); if ($v.StartsWith(' ')) { $v = $v.Substring(1) }; $r[$l.Substring(0, $k)] = $v }
  }
  $r
}
function Set-IniKey($ini, [string]$name, [string]$key, [string]$value, [string[]]$after = @()) {
  # replace "key = ..." in [name]; if missing, insert after the last of $after that exists (else at the end of the section)
  $se = Find-IniSection $ini $name; if (-not $se) { throw "Section [$name] not found in live.ini. NOTHING was changed." }
  $at = -1
  for ($i = $se[0] + 1; $i -lt $se[1]; $i++) {
    $l = $ini.Lines[$i]
    if ($l.StartsWith("$key = ") -or $l -eq "$key =") { $ini.Lines[$i] = "$key = $value"; return }
    foreach ($a in $after) { if ($l.StartsWith("$a = ") -or $l -eq "$a =") { $at = $i } }
  }
  if ($at -lt 0) { $at = $se[1] - 1 }
  $ini.Lines.Insert($at + 1, "$key = $value")
}
function Remove-IniKeys($ini, [string]$name, [string]$keyRegex) {
  $se = Find-IniSection $ini $name; if (-not $se) { return 0 }
  $n = 0
  for ($i = $se[1] - 1; $i -gt $se[0]; $i--) {
    $l = $ini.Lines[$i]; $k = $l.IndexOf(' =')
    if ($k -gt 0 -and $l.Substring(0, $k) -match $keyRegex) { $ini.Lines.RemoveAt($i); $n++ }
  }
  $n
}

function Get-LiveInfo($root, $ini = $null) {
  # buttons, page names and master faders from live.ini
  if (-not $ini) { $ini = Read-LiveIni $root }
  $pages = @{}; $buttons = New-Object Collections.Generic.List[object]
  $secs = New-Object Collections.Generic.List[object]; $sec = $null; $keys = $null
  foreach ($l in $ini.Lines) {
    if ($l -match '^\[(.+)\]\s*$') { if ($sec) { $secs.Add(@($sec, $keys)) }; $sec = $matches[1]; $keys = @{}; continue }
    if ($sec) { $k = $l.IndexOf(' ='); if ($k -gt 0) { $v = $l.Substring($k + 2); if ($v.StartsWith(' ')) { $v = $v.Substring(1) }; $keys[$l.Substring(0, $k)] = $v } }
  }
  if ($sec) { $secs.Add(@($sec, $keys)) }
  foreach ($s in $secs) {
    $nm = $s[0]; $ky = $s[1]
    if ($nm -match '^page(\d+)$') { $pages[[int]$matches[1]] = "$($ky['name'])" }
    elseif ($nm -match '^page(\d+)_button(\d+)$') {
      $pg = [int]$matches[1]; $bn = [int]$matches[2]
      $buttons.Add([pscustomobject]@{ Sec = $nm; Page = $pg; Btn = $bn; Name = "$($ky['name'])"; Title = "$($ky['title'])"; Keys = $ky; PageName = '' })
    }
  }
  foreach ($b in $buttons) { $b.PageName = $(if ($pages.ContainsKey($b.Page) -and $pages[$b.Page]) { $pages[$b.Page] } else { "Page $($b.Page)" }) }
  $lv = Get-IniKeys $ini 'live'; $mf = Get-IniKeys $ini 'master_faders'
  $nf = 0; if ("$($lv['master_faders'])" -match '^\d+$') { $nf = [int]$lv['master_faders'] }
  $faders = @(for ($k = 0; $k -lt $nf; $k++) { [pscustomobject]@{ k = $k; caption = "$($mf["caption_fader$k"])"; type = "$($mf["type_fader$k"])" } })
  [pscustomobject]@{ Ini = $ini; Pages = $pages; Buttons = $buttons; Faders = $faders; Live = $lv; Sections = $secs }
}

function Get-ScenePath($root, [string]$name) {
  # file a live button plays: .scex in scenes/, .gpj in the Generator projects (or scenes/)
  if (-not $name) { return $null }
  $c = if ($name -like '*.gpj') { @("$root/Editor/Generator/projects/$name", "$root/scenes/$name") } else { @("$root/scenes/$name") }
  foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
  $null
}

# ---------------------------------------------------------------- fixture definitions (fixtures/<model>.txt)
$script:fxDefCache = @{}
function Get-FixtureDef($root, [string]$model) {
  # -> @{ channel name (lowercase) = list of @{ n = range name; lo; hi } }  (first definition of each channel name)
  if ($script:fxDefCache.ContainsKey($model)) { return $script:fxDefCache[$model] }
  $d = @{}; $p = "$root/fixtures/$model.txt"
  if (Test-Path -LiteralPath $p) {
    $ch = $null
    foreach ($l in [IO.File]::ReadAllLines($p)) {
      if ($l -match '^Channel = (.+?)\s*$') { $ch = $matches[1].ToLower(); if ($d.ContainsKey($ch)) { $ch = $null } else { $d[$ch] = @() }; continue }
      if ($ch -and $l.Trim() -and $d[$ch].Count -eq 0) {
        $d[$ch] = @(foreach ($r in [regex]::Matches($l, '([^,]+?),(\d+),(\d+)')) { @{ n = $r.Groups[1].Value.Trim().ToLower(); lo = [int]$r.Groups[2].Value; hi = [int]$r.Groups[3].Value } })
      }
    }
  }
  $script:fxDefCache[$model] = $d; $d
}
function Test-ShutterClosed($root, [string]$model, [int]$v) {
  $r = @((Get-FixtureDef $root $model)['shutter'] | Where-Object { $_ -and $_.n -eq 'closed' })
  if (-not $r.Count) { return ($v -eq 0) }
  foreach ($x in $r) { if ($v -ge $x.lo -and $v -le $x.hi) { return $true } }
  $false
}
function Get-ColorSlot($root, [string]$model, [int]$v) {
  # fixed colour-wheel slot number (0 = first) or -1 for index/rotate/unknown
  $i = 0
  foreach ($x in @((Get-FixtureDef $root $model)['color'] | Where-Object { $_ })) {
    if ($x.n -match 'index|rotate|stop') { break }
    if ($v -ge $x.lo -and $v -le $x.hi) { return $i }
    $i++
  }
  -1
}

function Get-SceneSteps($root, [string]$path, $modelOf) {
  # .scex -> steps with which movers are lit. Movers (in $modelOf): lit = dimmer above 0 (or no dimmer) and shutter not closed.
  # other = some non-mover fixture (blinder, uplight...) has a channel above 0 in that step.
  [xml]$x = [IO.File]::ReadAllText($path)
  $out = New-Object Collections.Generic.List[object]
  foreach ($s in @($x.Scene.Steps.Step | Where-Object { $_ })) {
    $lit = New-Object Collections.Generic.List[string]; $other = $false; $colors = @{}
    foreach ($fx in @($s.Fixture | Where-Object { $_ })) {
      $id = $fx.GetAttribute('id'); $chs = @($fx.Channel | Where-Object { $_ })
      if ($modelOf.ContainsKey($id)) {
        $on = $true
        foreach ($c in $chs) {
          $n = $c.GetAttribute('name'); $v = [int]$c.GetAttribute('value')
          if ($n -eq 'dimmer' -and $v -le 0) { $on = $false }
          if ($n -eq 'shutter' -and (Test-ShutterClosed $root $modelOf[$id] $v)) { $on = $false }
          if ($n -eq 'color') { $colors[$id] = $v }
        }
        if ($on) { $lit.Add($id) }
      } elseif (@($chs | Where-Object { [int]$_.GetAttribute('value') -gt 0 }).Count) { $other = $true }
    }
    $len = 0; if ("$($s.GetAttribute('length'))" -match '^\d+$') { $len = [int]$s.GetAttribute('length') }
    $out.Add([pscustomobject]@{ cs = $len; lit = @($lit); other = $other; colors = $colors })
  }
  ,$out
}

function Get-TextSha([string]$s) {
  $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
  ([BitConverter]::ToString($h) -replace '-', '').ToLower()
}
function Add-LiveButton($ini, $info, $pg, [string]$scene, [string]$title, [int[]]$cols = @(1..10), [switch]$Down) {
  # new button on live page $pg in the first free cell (lines 1-8, columns in $cols order; -Down = fill a column first) -> @(line, column)
  $mine = @($info.Buttons | Where-Object { $_.Page -eq $pg })
  $used = @{}; foreach ($b in $mine) { $used["$($b.Keys['line'])/$($b.Keys['column'])"] = 1 }
  $cell = $null
  if ($Down) { foreach ($co in $cols) { foreach ($ln in 1..8) { if (-not $cell -and -not $used.ContainsKey("$ln/$co")) { $cell = @($ln, $co) } } } }
  else { foreach ($ln in 1..8) { foreach ($co in $cols) { if (-not $cell -and -not $used.ContainsKey("$ln/$co")) { $cell = @($ln, $co) } } } }
  if (-not $cell) { throw "The page $($info.Pages[$pg]) is full. NOTHING was changed." }
  $n = 1; while (Find-IniSection $ini "page${pg}_button$n") { $n++ }
  $last = if ($mine.Count) { Find-IniSection $ini (($mine | Sort-Object Btn | Select-Object -Last 1).Sec) } else { Find-IniSection $ini "page$pg" }
  $ini.Lines.InsertRange($last[1], [string[]]@("[page${pg}_button$n]", "line = $($cell[0])", "column = $($cell[1])", "name = $scene", "title = $title", 'masterspeedfader = 0'))
  Set-IniKey $ini "page$pg" 'nb_buttons' "$($mine.Count + 1)" @('name')
  ,$cell
}
function Read-ChangesFile([string]$p) {
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "No changes were sent. NOTHING was changed." }
  $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
  ,@(foreach ($x in $j) { $x })
}
