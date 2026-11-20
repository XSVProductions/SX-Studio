# SHOW HEALTH CHECK - scan of the show for problems that have caused trouble before, with fixes you can apply and revert.
#
#   -Action Check               -> JSON { ok, show, issues: [{ level, kind, title, detail, advice, fix }], applied: [...] }  (writes nothing)
#   -Action Fix    -FixId kind|target   applies the fix of that issue (ShowXpress must be closed)
#   -Action Revert -FixId <id> [-Force] puts back what that fix changed. Without -Force it refuses (prints {"conflict":[...]})
#                                       if the show was changed again after the fix.
#   -Action Keep   -FixId <id>          forgets the backup of that fix (it can't be reverted afterwards)
#
#   errors: button plays a scene that doesn't exist, beat settings ShowXpress can't use (beats = 0), speed fader that
#           doesn't exist, two buttons on the same APC pad, scene uses fixtures that aren't in the show
#   warns : APC notes outside the 8x8 pads, pad light on a different pad than its trigger, faders on the same CC,
#           two buttons on the same spot of a page, colour chases that jump back across the colour wheel when they
#           loop (the mechanical wheel visibly spins through every colour), page button count off
#   info  : keyboard keys shared by several buttons, scene files no button uses
#
#   Fixes that can be applied: colour wheel (play the steps back and forth), deleted fixtures (.scex), speed fader that
#   doesn't exist, mapping outside the pads, pad light on another pad, two buttons on one pad (move to the nearest free pad).
#   What each fix changed (live.ini keys before/after, whole scene files before) is kept in <show>/health_fixes.json.
param(
  [ValidateSet('Check','Fix','Revert','Keep')][string]$Action = 'Check',
  [string]$FixId = '',
  [switch]$Force,
  [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$logPath = "$root/health_fixes.json"
$rigPath = "$root/rig_state.json"
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-FixLog {
  $l = New-Object Collections.Generic.List[object]
  if (Test-Path -LiteralPath $logPath) { $j = [IO.File]::ReadAllText($logPath) | ConvertFrom-Json; foreach ($x in $j) { if ($x) { $l.Add($x) } } }
  ,$l
}
function Save-FixLog($l) {
  if (-not $l.Count) { if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath }; return }
  [IO.File]::WriteAllText($logPath, (ConvertTo-Json -InputObject $l.ToArray() -Depth 6), $utf8)
}
function Test-NeedClosed { if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." } }
function Read-TextFile($p) {
  $b = [IO.File]::ReadAllBytes($p); $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  $o = if ($bom) { 3 } else { 0 }
  @{ text = [Text.Encoding]::UTF8.GetString($b, $o, $b.Length - $o); bom = $bom }
}

# ---------------------------------------------------------------- Keep / Revert (no scan needed)
if ($Action -eq 'Keep' -or $Action -eq 'Revert') {
  $log = Read-FixLog
  $e = $log | Where-Object { $_.id -eq $FixId } | Select-Object -First 1
  if (-not $e) { throw "That fix isn't in the list any more. Press Check again. NOTHING was changed." }
  if ($Action -eq 'Keep') { [void]$log.Remove($e); Save-FixLog $log; "  $($e.title): kept ($($e.label)) - the backup is gone, it can't be reverted now."; return }

  Test-NeedClosed
  $ini = $null; $conf = @()
  if (@($e.ini).Count) {
    $ini = Read-LiveIni $root
    foreach ($r in @($e.ini)) {
      if (-not (Find-IniSection $ini $r.sec)) { $conf += "button $($r.sec) is gone from live.ini"; continue }
      $k = Get-IniKeys $ini $r.sec; $cur = if ($k.ContainsKey($r.key)) { $k[$r.key] } else { $null }
      if ("$cur" -ne "$($r.after)" -or ($null -eq $cur) -ne ($null -eq $r.after)) { $conf += "$($r.key) of '$($k['title'])' was changed again" }
    }
  }
  foreach ($f in @($e.files)) {
    $p = "$root/$($f.file)"
    if (-not (Test-Path -LiteralPath $p)) { $conf += "$($f.file) is gone" }
    elseif ((Get-TextSha (Read-TextFile $p).text) -ne $f.written) { $conf += "$([IO.Path]::GetFileName($f.file)) was edited after the fix" }
  }
  if ($conf.Count -and -not $Force) { [pscustomobject]@{ conflict = @($conf | Select-Object -Unique) } | ConvertTo-Json -Compress; return }

  $out = @()
  if ($ini) {
    $rs = @($e.ini); [array]::Reverse($rs)
    foreach ($r in $rs) {
      if (-not (Find-IniSection $ini $r.sec)) { continue }
      if ($null -eq $r.before) { [void](Remove-IniKeys $ini $r.sec ('^' + [regex]::Escape($r.key) + '$')) }
      else { Set-IniKey $ini $r.sec $r.key "$($r.before)" @($r.prev) }
    }
    if (Save-LiveIni $ini) { $out += "  live.ini put back" }
  }
  foreach ($f in @($e.files)) {
    [IO.File]::WriteAllText("$root/$($f.file)", "$($f.original)", (New-Object Text.UTF8Encoding([bool]$f.bom)))
    $out += "  $([IO.Path]::GetFileName($f.file)) put back"
  }
  [void]$log.Remove($e); Save-FixLog $log
  "  $($e.title): reverted ($($e.label))"; $out
  return
}

# ---------------------------------------------------------------- scan
$info = Get-LiveInfo $root
$issues = New-Object Collections.Generic.List[object]
function Add-Issue($level, $kind, $title, $detail, $advice = '', $fix = $null) {
  $issues.Add([pscustomobject]@{ level = $level; kind = $kind; title = $title; detail = $detail; advice = $advice; fix = $fix })
}
function New-Fix($key, $label, $ini = @(), $file = $null) { [pscustomobject]@{ key = $key; label = $label; ini = @($ini); file = $file } }
function New-IniOp($sec, $key, $value) { [pscustomobject]@{ sec = $sec; key = $key; value = $value } }
function Get-Where($b) { "$($b.PageName) page, line $($b.Keys['line']) col $($b.Keys['column'])" }
function Get-Int($v, $def = -1) { if ("$v" -match '^-?\d+$') { [int]$v } else { $def } }
function Get-Pad($n) { "row $(8 - [math]::Floor($n / 8)) col $(($n % 8) + 1)" }

# scenes Tonight's Rig is holding trimmed -> no scene fixes on those (the rig keeps its own copy)
$rigFiles = @{}
if (Test-Path -LiteralPath $rigPath) { try { $rj = [IO.File]::ReadAllText($rigPath) | ConvertFrom-Json; if ($rj.scenes) { foreach ($p in $rj.scenes.PSObject.Properties) { $rigFiles[$p.Name.ToLower()] = $true } } } catch {} }
$rigNote = " Tonight's Rig has trimmed this scene - put all heads back in that tab first, then the fix can be applied here."

# ---- fixtures in the show
$showIds = @{}
foreach ($l in [IO.File]::ReadAllLines("$root/fixtures.ini")) { if ($l -match '^id = (\d+)') { $showIds[$matches[1]] = $true } }
$movers = @(Get-ShowMovers $root); $modelOf = @{}; foreach ($m in $movers) { $modelOf[$m.Id] = $m.Model }

# ---- buttons -> scenes
$used = @{}; $realPath = @{}
foreach ($b in $info.Buttons) {
  if (-not $b.Name) { continue }
  $p = Get-ScenePath $root $b.Name
  if (-not $p) { Add-Issue 'error' 'scene' "$($b.Title): scene file missing" "Plays '$($b.Name)', which isn't in the show any more ($(Get-Where $b)). Renamed or deleted?" "Pick the scene again in the button's settings in ShowXpress, or delete the button."; continue }
  $lk = [IO.Path]::GetFullPath($p).ToLower(); $used[$lk] = $b; $realPath[$lk] = $p
}

# ---- scenes that use fixtures not in the show
foreach ($p in $used.Keys) {
  $b = $used[$p]; $rp = $realPath[$p]; $txt = [IO.File]::ReadAllText($rp); $fn = [IO.Path]::GetFileName($rp)
  $ids = if ($p -like '*.gpj') { @([regex]::Matches($txt, '(?m)^ID = (\d+)') | ForEach-Object { $_.Groups[1].Value }) }
         else { @([regex]::Matches($txt, '<Fixture id="(\d+)"') | ForEach-Object { $_.Groups[1].Value }) }
  $miss = @($ids | Select-Object -Unique | Where-Object { -not $showIds[$_] })
  if (-not $miss.Count) { continue }
  $d = "Scene '$fn' still uses fixtures that were deleted from the show (ids $($miss -join ', '))."
  if ($p -like '*.gpj') { Add-Issue 'error' 'fixtures' "$($b.Title): $($miss.Count) fixture(s) not in the show" $d "Open the scene in the Generator and take the missing fixtures out." }
  elseif ($rigFiles[$fn.ToLower()]) { Add-Issue 'error' 'fixtures' "$($b.Title): $($miss.Count) fixture(s) not in the show" ($d + $rigNote) "Take the missing fixtures out of the scene." }
  else { Add-Issue 'error' 'fixtures' "$($b.Title): $($miss.Count) fixture(s) not in the show" $d "Take the missing fixtures out of the scene. Nothing else in it changes." (New-Fix "fixtures|$($b.Sec)" 'Remove the missing fixtures' @() ([pscustomobject]@{ path = $rp; op = 'dropfix'; ids = $miss })) }
}

# ---- beat / speed settings
foreach ($b in $info.Buttons) {
  $k = $b.Keys
  if ($k.ContainsKey('beats') -and "$($k['beats'])".Trim() -eq '0') { Add-Issue 'error' 'beat' "$($b.Title): beats = 0" "ShowXpress can't use this - the button runs as a fast strobe ($(Get-Where $b))." "Set Beat/Step/Trigger again in the button's speed dialog in ShowXpress." }
  if ($k.ContainsKey('bpm_trigger') -and "$($k['bpm_trigger'])" -match '^\d+$') { Add-Issue 'warn' 'beat' "$($b.Title): odd beat trigger setting" "bpm_trigger = $($k['bpm_trigger']) isn't what ShowXpress writes (it uses flash_mode) ($(Get-Where $b))." "Set it again in the button's speed dialog in ShowXpress." }
  if ($k.ContainsKey('masterspeedfader')) {
    $f = Get-Int $k['masterspeedfader']
    if ($f -lt 0 -or $f -ge $info.Faders.Count) {
      if ($info.Faders.Count) {
        $c0 = $info.Faders[0].caption
        Add-Issue 'error' 'speed' "$($b.Title): speed fader $f doesn't exist" "There are only $($info.Faders.Count) master faders ($(Get-Where $b))." "Let it follow the first master fader ($c0). You can pick another one in the Speed Faders tab afterwards." (New-Fix "speed|$($b.Sec)" "Use $c0" @(New-IniOp $b.Sec 'masterspeedfader' '0'))
      } else { Add-Issue 'error' 'speed' "$($b.Title): speed fader $f doesn't exist" "The show has no master faders." "Add master faders in ShowXpress, or remove the speed fader from the button." }
    }
  }
}

# ---- APC mini / MIDI
$byNote = @{}; $taken = @{}
foreach ($b in $info.Buttons) { $k = $b.Keys; if ((Get-Int $k['trigger_midi_type'] 0) -eq 0) { $n = Get-Int $k['trigger_midi_note']; if ($n -ge 0 -and $n -le 63) { $taken[$n] = $true } } }
foreach ($b in $info.Buttons) {
  $k = $b.Keys; if (-not $k.ContainsKey('trigger_midi_note')) { continue }
  $n = Get-Int $k['trigger_midi_note']; $t = Get-Int $k['trigger_midi_type'] 0
  if ($t -ne 0 -or $n -lt 0 -or $n -gt 63) {
    $ops = @($k.Keys | Where-Object { $_ -match '^trigger_midi(out)?_' } | Sort-Object | ForEach-Object { New-IniOp $b.Sec $_ $null })
    Add-Issue 'warn' 'midi' "$($b.Title): mapped outside the 8x8 pads" "MIDI $(if ($t -eq 0) { 'note' } else { "type $t" }) $n - not one of the 64 pads; the round and track buttons are meant to stay unmapped ($(Get-Where $b))." "Remove the MIDI mapping from this button. You can give it a pad in the APC mini tab afterwards." (New-Fix "midiout|$($b.Sec)" 'Remove the mapping' $ops)
    continue
  }
  $key = "$($k['trigger_midi_device'])/$($k['trigger_midi_channel'])/$n"
  if (-not $byNote.ContainsKey($key)) { $byNote[$key] = @() }; $byNote[$key] += $b
  if ($k.ContainsKey('trigger_midiout_note') -and (Get-Int $k['trigger_midiout_note']) -ne $n) {
    Add-Issue 'warn' 'midi' "$($b.Title): pad light is on a different pad" "Triggered by note $n ($(Get-Pad $n)) but lights note $($k['trigger_midiout_note'])." "Light the pad that triggers it." (New-Fix "midilight|$($b.Sec)" 'Light its own pad' @(New-IniOp $b.Sec 'trigger_midiout_note' "$n"))
  }
}
foreach ($key in @($byNote.Keys | Sort-Object)) {
  $bs = @($byNote[$key] | Sort-Object Page, @{e={ Get-Int $_.Keys['line'] 0 }}, @{e={ Get-Int $_.Keys['column'] 0 }}); if ($bs.Count -lt 2) { continue }
  $n = [int]($key -split '/')[2]
  $moves = @(); $ops = @()
  foreach ($x in $bs[1..($bs.Count - 1)]) {
    $best = -1; $bd = 1e9
    for ($q = 0; $q -lt 64; $q++) {
      if ($taken[$q]) { continue }
      $dr = [math]::Floor($q / 8) - [math]::Floor($n / 8); $dc = ($q % 8) - ($n % 8); $d = $dr * $dr * 1.01 + $dc * $dc
      if ($d -lt $bd) { $bd = $d; $best = $q }
    }
    if ($best -lt 0) { $moves = @(); break }
    $taken[$best] = $true; $moves += "$($x.Title) to $(Get-Pad $best)"
    $ops += New-IniOp $x.Sec 'trigger_midi_note' "$best"
    if ($x.Keys.ContainsKey('trigger_midiout_note')) { $ops += New-IniOp $x.Sec 'trigger_midiout_note' "$best" }
  }
  $d = "$(($bs | ForEach-Object { "$($_.Title) ($($_.PageName))" }) -join ', ') - one press fires all of them."
  if ($moves.Count) { Add-Issue 'error' 'midi' "Pad $(Get-Pad $n) plays $($bs.Count) buttons" $d "Keep $($bs[0].Title) on this pad and move $($moves -join ', ') (the nearest free pad)." (New-Fix "pad|$n" 'Move to a free pad' $ops) }
  else { Add-Issue 'error' 'midi' "Pad $(Get-Pad $n) plays $($bs.Count) buttons" $d "There's no free pad left - take one off in the APC mini tab." }
}
$ccs = @{}
foreach ($kk in @($info.Live.Keys | Where-Object { $_ -match '^fader(\d+)_midi_note$' })) { $cc = $info.Live[$kk]; if (-not $ccs.ContainsKey($cc)) { $ccs[$cc] = @() }; $ccs[$cc] += ($kk -replace '_midi_note', '') }
foreach ($cc in $ccs.Keys) { if (@($ccs[$cc]).Count -gt 1) { Add-Issue 'warn' 'midi' "Faders share CC $cc" "$($ccs[$cc] -join ', ') move together." "Learn the MIDI of one of the faders again in ShowXpress." } }

# ---- keyboard keys / layout
$keys = @{}
foreach ($b in $info.Buttons) { $kb = "$($b.Keys['trigger_keyboard'])"; if ($kb) { if (-not $keys.ContainsKey($kb)) { $keys[$kb] = @() }; $keys[$kb] += $b } }
foreach ($kb in $keys.Keys) { $bs = @($keys[$kb]); if ($bs.Count -gt 1) { Add-Issue 'info' 'keys' "Keyboard key '$kb' fires $($bs.Count) buttons together" "$(($bs | ForEach-Object { "$($_.Title) ($($_.PageName))" }) -join ', '). Fine if that's on purpose." } }
$spots = @{}
foreach ($b in $info.Buttons) { $s = "$($b.Page)/$($b.Keys['line'])/$($b.Keys['column'])"; if (-not $spots.ContainsKey($s)) { $spots[$s] = @() }; $spots[$s] += $b }
foreach ($s in $spots.Keys) { $bs = @($spots[$s]); if ($bs.Count -gt 1) { Add-Issue 'warn' 'layout' "Buttons on top of each other" "$(($bs | ForEach-Object { $_.Title }) -join ' and ') share one spot ($(Get-Where $bs[0])) - only one can be seen/clicked." "Drag one of them to a free spot in ShowXpress." } }
foreach ($pg in $info.Pages.Keys) {
  $nb = Get-Int (Get-IniKeys $info.Ini "page$pg")['nb_buttons']; $real = @($info.Buttons | Where-Object { $_.Page -eq $pg }).Count
  if ($nb -ge 0 -and $nb -ne $real) { Add-Issue 'warn' 'layout' "$($info.Pages[$pg]) page: button count off" "live.ini says $nb buttons but has $real." "Check that page in ShowXpress for a button that's missing or hidden." }
}

# ---- colour chases that jump back across the wheel when they loop
$stepRx = [regex]'(?s)\r?\n[ \t]*<Step\b(?:[^>]*/>|[^>]*>.*?</Step>)'
foreach ($p in $used.Keys) {
  if ($p -notlike '*.scex') { continue }
  $b = $used[$p]; $steps = Get-SceneSteps $root $realPath[$p] $modelOf
  if ($steps.Count -lt 3) { continue }
  $bad = @(); $ex = $null
  foreach ($m in $movers) {
    $seq = @(foreach ($s in $steps) { if ($s.colors.ContainsKey($m.Id)) { Get-ColorSlot $root $m.Model $s.colors[$m.Id] } })
    $seq = @($seq | Where-Object { $_ -ge 0 })
    if ($seq.Count -lt 3 -or @($seq | Select-Object -Unique).Count -lt 3) { continue }
    $maxIn = 0; for ($i = 1; $i -lt $seq.Count; $i++) { $d = [math]::Abs($seq[$i] - $seq[$i - 1]); if ($d -gt $maxIn) { $maxIn = $d } }
    $wrap = [math]::Abs($seq[0] - $seq[$seq.Count - 1])
    if ($wrap -ge 3 -and $wrap -gt $maxIn) {
      $bad += (Get-Label $m)
      if (-not $ex) { $nm = @((Get-FixtureDef $root $m.Model)['color'] | ForEach-Object { $_.n -replace '_', ' ' }); $ex = "$($nm[$seq[$seq.Count - 1]]) back to $($nm[$seq[0]])" }
    }
  }
  if (-not $bad.Count) { continue }
  $rp = $realPath[$p]; $fn = [IO.Path]::GetFileName($rp); $n = $steps.Count; $n2 = 2 * $n - 2
  $d = "At the end of the loop $($bad.Count) head(s) jump $ex, so the wheel visibly runs through every colour in between ($(($bad | Select-Object -First 6) -join ', ')$(if ($bad.Count -gt 6) { '...' }))."
  $adv = "Play the steps forward then back (1 to $n, then $($n - 1) back to 2) instead of jumping from the last step to the first, so the wheel only ever moves to a neighbouring colour. Every step stays as long as it is now; one loop becomes $n2 steps instead of $n."
  if ($rigFiles[$fn.ToLower()]) { Add-Issue 'warn' 'color' "$($b.Title): colour wheel spins on loop" ($d + $rigNote) $adv }
  elseif ($stepRx.Matches([IO.File]::ReadAllText($rp)).Count -ne $n) { Add-Issue 'warn' 'color' "$($b.Title): colour wheel spins on loop" $d $adv }
  else { Add-Issue 'warn' 'color' "$($b.Title): colour wheel spins on loop" $d $adv (New-Fix "color|$($b.Sec)" 'Play it back and forth' @() ([pscustomobject]@{ path = $rp; op = 'pingpong' })) }
}

# ---- scene files no button uses
$unused = @()
foreach ($f in @(Get-ChildItem -LiteralPath "$root/scenes" -Filter '*.scex') + @(Get-ChildItem -LiteralPath "$root/Editor/Generator/projects" -Filter '*.gpj' -ErrorAction SilentlyContinue)) {
  if (-not $used.ContainsKey($f.FullName.ToLower())) { $unused += $f.BaseName }
}
if ($unused.Count) { Add-Issue 'info' 'unused' "$($unused.Count) scenes aren't on any button" (($unused | Sort-Object) -join ', ') }

# ---------------------------------------------------------------- Check
if ($Action -eq 'Check') {
  $order = @{ error = 0; warn = 1; info = 2 }
  $applied = @(foreach ($e in (Read-FixLog)) { [pscustomobject]@{ id = $e.id; title = $e.title; label = $e.label; time = $e.time; what = $e.what } })
  $list = @(foreach ($i in @($issues | Sort-Object @{e={ $order[$_.level] }}, kind, title)) {
    [pscustomobject]@{ level = $i.level; kind = $i.kind; title = $i.title; detail = $i.detail; advice = $i.advice
                       fix = $(if ($i.fix) { [pscustomobject]@{ key = $i.fix.key; label = $i.fix.label } } else { $null }) } })
  [pscustomobject]@{ ok = $true; show = $root; buttons = $info.Buttons.Count; scenes = $used.Count; issues = $list; applied = $applied } | ConvertTo-Json -Depth 5 -Compress
  return
}

# ---------------------------------------------------------------- Fix
Test-NeedClosed
$iss = $issues | Where-Object { $_.fix -and $_.fix.key -eq $FixId } | Select-Object -First 1
if (-not $iss) { throw "That problem isn't there any more (already fixed?). Press Check again. NOTHING was changed." }
$fx = $iss.fix
$entry = [ordered]@{ id = [guid]::NewGuid().ToString('N').Substring(0, 8); key = $fx.key; title = $iss.title; label = $fx.label; what = $iss.advice
                     time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ini = @(); files = @() }
$out = @()

# scene file first (if this throws, nothing has been written yet)
$fileRec = $null
if ($fx.file) {
  $p = $fx.file.path; $rt = Read-TextFile $p; $t = $rt.text
  if ($fx.file.op -eq 'pingpong') {
    $ms = $stepRx.Matches($t); $n = $ms.Count
    if ($n -lt 3) { throw "The scene has fewer than 3 steps. NOTHING was changed." }
    $last = $ms[$n - 1]; $sb = New-Object Text.StringBuilder
    [void]$sb.Append($t.Substring(0, $last.Index + $last.Length))
    for ($i = $n - 2; $i -ge 1; $i--) { [void]$sb.Append($ms[$i].Value) }
    [void]$sb.Append($t.Substring($last.Index + $last.Length))
    $new = $sb.ToString(); $out += "  $([IO.Path]::GetFileName($p)): $n steps -> $(2 * $n - 2) (back and forth)"
  } elseif ($fx.file.op -eq 'dropfix') {
    $new = $t; $cnt = 0
    foreach ($id in @($fx.file.ids)) {
      $rx = '(?s)\r?\n[ \t]*<Fixture id="' + [regex]::Escape("$id") + '"(?:[^>]*/>|[^>]*>.*?</Fixture>)'
      $cnt += [regex]::Matches($new, $rx).Count; $new = [regex]::Replace($new, $rx, '')
    }
    try { [void]([xml]$new) } catch { throw "Taking the fixtures out would break the scene file. NOTHING was changed." }
    $out += "  $([IO.Path]::GetFileName($p)): removed $(@($fx.file.ids).Count) missing fixture(s) ($cnt entries)"
  }
  if ($new -eq $t) { throw "Nothing to change in the scene. NOTHING was changed." }
  $rel = [IO.Path]::GetFullPath($p).Substring([IO.Path]::GetFullPath($root).TrimEnd('\', '/').Length + 1) -replace '\\', '/'
  $fileRec = [ordered]@{ file = $rel; bom = $rt.bom; original = $t; written = (Get-TextSha $new) }
  $fileNew = @($p, $new, $rt.bom)
}

if (@($fx.ini).Count) {
  $ini = $info.Ini
  foreach ($op in @($fx.ini)) {
    $se = Find-IniSection $ini $op.sec; if (-not $se) { throw "Button $($op.sec) is gone from live.ini. NOTHING was changed." }
    $order = @(); $prev = @(); $before = $null
    for ($i = $se[0] + 1; $i -lt $se[1]; $i++) { $l = $ini.Lines[$i]; $k = $l.IndexOf(' ='); if ($k -gt 0) { $order += $l.Substring(0, $k) } }
    $kv = Get-IniKeys $ini $op.sec
    if ($kv.ContainsKey($op.key)) { $before = $kv[$op.key]; $prev = @($order[0..([array]::IndexOf($order, $op.key))] | Where-Object { $_ -ne $op.key }) }
    if ($null -eq $op.value) { [void](Remove-IniKeys $ini $op.sec ('^' + [regex]::Escape($op.key) + '$')) }
    else { Set-IniKey $ini $op.sec $op.key $op.value @('line', 'column', 'name', 'title', 'imgpath', 'color', 'speed', 'bpm_trigger') }
    $entry.ini += [ordered]@{ sec = $op.sec; key = $op.key; before = $before; after = $op.value; prev = @($prev) }
    $out += "  $($kv['title']): $($op.key) $(if ($null -eq $before) { '(none)' } else { $before }) -> $(if ($null -eq $op.value) { '(removed)' } else { $op.value })"
  }
}

# the backup goes in first: if it can't be saved, nothing in the show is touched
if ($fileRec) { $entry.files = @($fileRec) }
$log = Read-FixLog; $log.Add([pscustomobject]$entry); Save-FixLog $log
try {
  if ($fileRec) { [IO.File]::WriteAllText($fileNew[0], $fileNew[1], (New-Object Text.UTF8Encoding([bool]$fileNew[2]))) }
  if (@($fx.ini).Count) { [void](Save-LiveIni $info.Ini) }
} catch {
  $msg = $_.Exception.Message
  if ($fileRec) { try { [IO.File]::WriteAllText($fileNew[0], $fileRec.original, (New-Object Text.UTF8Encoding([bool]$fileNew[2]))) } catch {} }
  $log = Read-FixLog; $log = New-Object Collections.Generic.List[object] (,@($log | Where-Object { $_.id -ne $entry.id })); Save-FixLog $log
  throw "Could not save the fix ($msg). NOTHING was changed."
}
"  $($iss.title): fixed ($($fx.label))"
$out
