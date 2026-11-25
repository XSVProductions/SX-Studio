# MOVEMENT EDITOR (phase 3 of SX Studio's own editor, user 2026-11-24) - reads and changes ShowXpress Generator
# movements (Editor/Generator/projects/*.gpj).
#
#   Rules (user): ShowXpress must still open every file written, and anything the editor doesn't understand is passed
#   through untouched. A .gpj is an ini file ([section], "key = value"). A save never rebuilds it: it starts from the
#   file's own text and changes only
#     - the value after " = " of the keys that were edited (Selected, Transition, Duration, Shift of a channel section;
#       OffsetPan / OffsetTilt / ZoomPan / ZoomTilt of a head),
#     - the block of Point_N lines of a section whose points were edited (rewritten as Point_0..Point_n-1, in place).
#   Everything else - [Params], CurveName, the fixture lists, keys the editor doesn't know, the BOM and every line's own
#   line ending (ShowXpress writes LF, some files are CRLF after ShowXpress saved them) - stays byte for byte.
#   Before anything is written the result is read back and must give exactly the movement that was asked for, with
#   every other line unchanged. If not: NOTHING is written. Every save keeps the previous file as a backup.
#
#   OWNED BY OTHER TABS (read-only here): ReversePan / ReverseTilt (Reverse heads - flip.ps1 keeps them in step with the
#   scenes); per-head OffsetPan/Tilt + ZoomPan/Tilt of the movements Aim Movers looks after (df_aim_state.json = Dance
#   Floor, room_aim_state.json = Room) - Aim writes those every Apply.
#   AIM MOVERS' SHAPE RECORD: Aim keeps the last shape it wrote for each of its movements and re-makes any shape that
#   changed since (symmetrical + centered). A shape saved HERE is written into that record too (written = the new shape,
#   base = the new shape at size 100), so the next Aim Apply keeps the shape exactly as it was drawn.
#
#   -Action List                         -> JSON: every movement (heads, cycle, points, what's ticked, buttons that use it)
#   -Action Open -Move "X.gpj"           -> JSON: the movement for the editor (heads, sections, points, DMX addresses)
#   -Action Save -ChangesFile f.json     -> writes the changes (ShowXpress must be closed)
#        {move, sha, secs:[{name, sel, tr, dur, shift, pts:[[x,y],..]}], heads:[{k, op, ot, zp, zt}]}  (any field may be left out)
#        sel 0/1; tr 0 points / 1 lines / 2 curves; dur = cycle in 1/10 s; shift = % of the cycle each next head runs behind;
#        pts 0..65535 (pan,tilt for Pan/Tilt/uPan/uTilt; for a value channel x = place in the cycle, y = value)
#   -Action Render -ChangesFile f.json -Out <file>  -> the same result written to <file> instead (the live preview; no checks
#                                           on ShowXpress, nothing in the show changes)
#   -Action Backups -Move "X.gpj"        -> JSON: the backups of a movement, newest first
#   -Action Revert -Move "X.gpj" -Backup <id> [-Force]  -> puts a backup back (the current file is backed up first)
#   -Action Check                        -> JSON: every movement read, and "saved" in memory with every point and value
#                                           written again - each must come out byte for byte the same (nothing is written)
param(
  [ValidateSet('List', 'Open', 'Save', 'Render', 'Backups', 'Revert', 'Check')][string]$Action = 'List',
  [string]$Move = '',
  [string]$ChangesFile = '',
  [string]$Out = '',
  [string]$Backup = '',
  [switch]$Force,
  [string]$TestRoot = ''   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$gdir = "$root/Editor/Generator/projects"
$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$inv = [Globalization.CultureInfo]::InvariantCulture
$maxBackups = 20
$ptSec = 'Pan/Tilt/uPan/uTilt'

function Get-BytesSha([byte[]]$b) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace '-', '').ToLower() }
function ConvertTo-Bytes([string]$text, [bool]$bom) {
  $b = $utf8Strict.GetBytes($text)
  if (-not $bom) { return ,$b }
  $o = New-Object byte[] ($b.Length + 3); $o[0] = 0xEF; $o[1] = 0xBB; $o[2] = 0xBF; [Array]::Copy($b, 0, $o, 3, $b.Length); ,$o
}
function Test-SameBytes([byte[]]$a, [byte[]]$b) { $a.Length -eq $b.Length -and (Get-BytesSha $a) -eq (Get-BytesSha $b) }
function Get-MoveFile([string]$name) {
  if ($name -notmatch '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.gpj$' -or $name -match '^\.') { throw "Not a movement name: '$name'. NOTHING was changed." }
  $p = Join-Path $gdir $name
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Movement '$name' not found in the show. NOTHING was changed." }
  $p
}
function Get-Title([string]$f) { $f -replace '\.gpj$', '' }
function Format-Num([double]$v, [bool]$dec) {
  # how ShowXpress writes numbers: whole numbers plain, Shift always with a decimal point ("0.0", "12.5")
  if (-not $dec) { return ([math]::Round($v)).ToString($inv) }
  $s = ([math]::Round($v, 4)).ToString('0.0###', $inv); $s
}

# ---------------------------------------------------------------- reading (every line kept with its own line ending)
function Read-MoveBytes([byte[]]$b) {
  $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  $o = if ($bom) { 3 } else { 0 }
  $t = $null; $why = ''
  try { $t = $utf8Strict.GetString($b, $o, $b.Length - $o) } catch { $why = 'the file is not plain UTF-8 text' }
  if (-not $why -and -not (Test-SameBytes (ConvertTo-Bytes $t $bom) $b)) { $why = 'the file does not read back the same way'; $t = $null }
  [pscustomobject]@{ Bytes = $b; Bom = $bom; Text = $t; Why = $why; Sha = (Get-BytesSha $b) }
}
function Split-Lines([string]$t) {
  # -> list of @(text, ending); joining them back gives $t exactly
  $res = New-Object Collections.Generic.List[object]
  foreach ($m in [regex]::Matches($t, '([^\r\n]*)(\r\n|\n|\r|$)')) {
    if ($m.Length -eq 0 -and $m.Index -ge $t.Length) { break }
    $res.Add(@($m.Groups[1].Value, $m.Groups[2].Value))
  }
  ,$res
}
function Join-Lines($lines) { $sb = New-Object Text.StringBuilder; foreach ($l in $lines) { [void]$sb.Append($l[0]).Append($l[1]) }; $sb.ToString() }

function Read-Move([string]$t) {
  # the model + where each value sits. why = a reason the file can't be changed here (then it's read-only)
  $lines = Split-Lines $t
  $m = [pscustomobject]@{ Lines = $lines; Params = [ordered]@{}; Heads = New-Object Collections.Generic.List[object]; Secs = New-Object Collections.Generic.List[object]; Why = ''; Seen = @{} }
  $cur = $null; $kind = ''
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i][0]; if ($i -eq 0) { $l = $l.TrimStart([char]0xFEFF) }
    if ($l -match '^\[(.+)\]$') {
      $nm = $matches[1]
      if ($m.Seen.ContainsKey($nm)) { $m.Why = "the section [$nm] is in the file twice"; }
      $m.Seen[$nm] = $true
      if ($nm -eq 'Params') { $kind = 'p'; $cur = $null }
      elseif ($nm -match '^Fixture_(\d+)$') { $kind = 'h'; $cur = [pscustomobject]@{ k = [int]$matches[1]; sec = $nm; keys = [ordered]@{}; at = @{} }; $m.Heads.Add($cur) }
      else { $kind = 's'; $cur = [pscustomobject]@{ name = $nm; keys = [ordered]@{}; at = @{}; pts = New-Object Collections.Generic.List[object]; ptAt = New-Object Collections.Generic.List[int]; ptBad = $false; last = $i }; $m.Secs.Add($cur) }
      continue
    }
    if (-not $kind) { continue }
    $e = $l.IndexOf(' = '); if ($e -lt 1) { continue }
    $k = $l.Substring(0, $e); $v = $l.Substring($e + 3)
    if ($kind -eq 'p') { $m.Params[$k] = $v; continue }
    if ($kind -eq 's') { $cur.last = $i }
    if ($kind -eq 's' -and $k -match '^Point_(\d+)$') {
      if ($v -match '^(-?\d+),(-?\d+)$' -and [int]$k.Substring(6) -eq $cur.pts.Count) { $cur.pts.Add(@([int]$matches[1], [int]$matches[2])); $cur.ptAt.Add($i) }
      else { $cur.ptBad = $true }
      continue
    }
    if ($cur.keys.Contains($k)) { $cur.ptBad = $true }   # a key twice: don't touch this section
    $cur.keys[$k] = $v; $cur.at[$k] = $i
  }
  foreach ($s in $m.Secs) {   # the points have to be one block of lines (Point_0, Point_1, ... one after the other)
    for ($j = 1; $j -lt $s.ptAt.Count; $j++) { if ($s.ptAt[$j] -ne $s.ptAt[$j - 1] + 1) { $s.ptBad = $true } }
  }
  if (-not $m.Heads.Count) { $m.Why = $(if ($m.Why) { $m.Why } else { 'it has no heads' }) }
  $m
}
function Open-Move([string]$path) {
  $f = Read-MoveBytes ([IO.File]::ReadAllBytes($path))
  $m = if ($f.Text -ne $null) { Read-Move $f.Text } else { $null }
  [pscustomobject]@{ File = $f; M = $m; Why = $(if ($f.Why) { $f.Why } elseif ($m.Why) { $m.Why } else { '' }) }
}
function Get-D($keys, [string]$k, [double]$def) { $d = 0.0; if ($keys.Contains($k) -and [double]::TryParse("$($keys[$k])", [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $def } }

# a plain model, for the page AND for the self-check (the same function reads the old and the new file)
function Get-Model($m) {
  [pscustomobject]@{
    heads = @(foreach ($h in $m.Heads) { [pscustomobject]@{ k = $h.k; id = "$($h.keys['ID'])"; name = "$($h.keys['Name'])"; dmx = "$($h.keys['DMX'])"
      chans = @("$($h.keys['Channels'])" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      rp = [int](Get-D $h.keys 'ReversePan' 0); rt = [int](Get-D $h.keys 'ReverseTilt' 0)
      op = (Get-D $h.keys 'OffsetPan' 0); ot = (Get-D $h.keys 'OffsetTilt' 0); zp = (Get-D $h.keys 'ZoomPan' 0); zt = (Get-D $h.keys 'ZoomTilt' 0)
      has = @(@('OffsetPan', 'OffsetTilt', 'ZoomPan', 'ZoomTilt') | Where-Object { $h.keys.Contains($_) }) } })
    secs = @(foreach ($s in $m.Secs) { [pscustomobject]@{ name = $s.name; sel = [int](Get-D $s.keys 'Selected' 0); tr = [int](Get-D $s.keys 'Transition' 2)
      dur = (Get-D $s.keys 'Duration' 200); shift = (Get-D $s.keys 'Shift' 0); curve = "$($s.keys['CurveName'])"
      pts = @(foreach ($p in $s.pts) { ,@($p[0], $p[1]) }); locked = [bool]$s.ptBad
      has = @(@('Selected', 'Transition', 'Duration', 'Shift') | Where-Object { $s.keys.Contains($_) }) } })
  }
}
function Get-ModelJson($mo) { $mo | ConvertTo-Json -Depth 8 -Compress }

# ---------------------------------------------------------------- what other tabs own
function Get-AimOwner {
  # movement file (lowercase) -> 'floor' | 'room'  (the movements Aim Movers rewrites)
  $r = @{}
  foreach ($x in @(@('df_aim_state.json', 'floor'), @('room_aim_state.json', 'room'))) {
    $p = Join-Path $root $x[0]; if (-not (Test-Path -LiteralPath $p)) { continue }
    try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { continue }
    if ($j.files) { foreach ($q in $j.files.PSObject.Properties) { $r["$($q.Name)".ToLower()] = $x[1] } }
  }
  $r
}
function Get-Patch {
  $a = @{}; $cur = $null
  if (Test-Path -LiteralPath "$root/fixtures.ini") {
    foreach ($l in [IO.File]::ReadAllLines("$root/fixtures.ini")) {
      if ($l -match '^\[') { $cur = @{}; continue }
      if ($null -eq $cur) { continue }
      if ($l -match '^address = (\d+)') { $cur.a = [int]$matches[1] }
      if ($l -match '^id = (\S+)\s*$') { $cur.id = $matches[1] }
      if ($cur.id -and $cur.a) { $a[$cur.id] = $cur.a }
    }
  }
  $a
}
function Get-UsedBy {
  $r = @{}
  try { $info = Get-LiveInfo $root } catch { return $r }
  foreach ($b in $info.Buttons) {
    if ("$($b.Name)" -notlike '*.gpj') { continue }
    $k = "$($b.Name)".ToLower(); if (-not $r.ContainsKey($k)) { $r[$k] = New-Object Collections.Generic.List[object] }
    $r[$k].Add([pscustomobject]@{ page = $b.PageName; title = $(if ($b.Title) { $b.Title } else { Get-Title $b.Name }); sec = $b.Sec })
  }
  $r
}
function Get-Labels {
  $r = @{}; try { foreach ($mv in @(Get-ShowMovers $root)) { $r[$mv.Id] = @{ label = (Get-Label $mv); model = $mv.Model } } } catch {}
  $r
}

# ---------------------------------------------------------------- the change, done on the text
function Test-Changes($o, $ch) {
  # checks what was sent against the file -> list of line edits: @{ at = line; n = how many lines; new = @(lines) }
  $m = $o.M; $own = (Get-AimOwner)[$script:Move.ToLower()]
  $edits = New-Object Collections.Generic.List[object]
  $secBy = @{}; foreach ($s in $m.Secs) { $secBy[$s.name] = $s }
  $headBy = @{}; foreach ($h in $m.Heads) { $headBy[$h.k] = $h }
  $done = @{}
  $setKey = {
    param($obj, [string]$k, [string]$v, [string]$what)
    if (-not $obj.at.ContainsKey($k)) { throw "$what has no '$k' line, so it can't be changed here - change it once in ShowXpress. NOTHING was changed." }
    $i = $obj.at[$k]; $old = $m.Lines[$i][0]; $pre = $old.Substring(0, $old.IndexOf(' = ') + 3)
    if ($old.Substring($pre.Length) -ne $v) { $edits.Add(@{ at = $i; n = 1; new = @(, @(($pre + $v), $m.Lines[$i][1])) }) }
  }
  foreach ($c in @($ch.secs | Where-Object { $_ })) {
    $nm = "$($c.name)"; $s = $secBy[$nm]
    if (-not $s) { throw "The movement has no channel '$nm'. NOTHING was changed." }
    if ($done.ContainsKey("s|$nm")) { throw "'$nm' was sent twice. NOTHING was changed." }; $done["s|$nm"] = 1
    $what = "Channel '$nm'"
    if ($null -ne $c.sel) { if ("$($c.sel)" -notin '0', '1', 'True', 'False') { throw "$what : Selected has to be on or off. NOTHING was changed." }
      & $setKey $s 'Selected' $(if ("$($c.sel)" -in '1', 'True') { '1' } else { '0' }) $what }
    if ($null -ne $c.tr) { if ("$($c.tr)" -notmatch '^[012]$') { throw "$what : the transition has to be points, lines or curves. NOTHING was changed." }; & $setKey $s 'Transition' "$($c.tr)" $what }
    if ($null -ne $c.dur) { $d = 0; if (-not [int]::TryParse("$($c.dur)", [ref]$d) -or $d -lt 1 -or $d -gt 360000) { throw "$what : the cycle has to be 0.1 s to 10 hours. NOTHING was changed." }; & $setKey $s 'Duration' "$d" $what }
    if ($null -ne $c.shift) { $d = 0.0
      if (-not [double]::TryParse("$($c.shift)", [Globalization.NumberStyles]::Float, $inv, [ref]$d) -or $d -lt 0 -or $d -gt 100) { throw "$what : the shift has to be 0 to 100 %. NOTHING was changed." }
      & $setKey $s 'Shift' (Format-Num $d $true) $what }
    if ($null -ne $c.pts) {
      if ($s.ptBad) { throw "$what : its points are written in a way SX Studio doesn't change - edit them in ShowXpress. NOTHING was changed." }
      $pts = @($c.pts | ForEach-Object { ,@($_) })
      if ($pts.Count -lt 1 -or $pts.Count -gt 256) { throw "$what : a movement needs 1 to 256 points. NOTHING was changed." }
      $new = New-Object Collections.Generic.List[object]
      $nl = if ($s.ptAt.Count) { $m.Lines[$s.ptAt[0]][1] } else { $m.Lines[$s.last][1] }
      if (-not $nl) { $nl = if ($o.File.Text -match "`r`n") { "`r`n" } else { "`n" } }
      for ($j = 0; $j -lt $pts.Count; $j++) {
        $x = 0; $y = 0
        if ($pts[$j].Count -ne 2 -or -not [int]::TryParse("$($pts[$j][0])", [ref]$x) -or -not [int]::TryParse("$($pts[$j][1])", [ref]$y) -or $x -lt 0 -or $x -gt 65535 -or $y -lt 0 -or $y -gt 65535) {
          throw "$what : point $($j + 1) is not two numbers 0..65535. NOTHING was changed." }
        $new.Add(@("Point_$j = $x,$y", $nl))
      }
      if ($s.ptAt.Count) {
        $last = $s.ptAt[$s.ptAt.Count - 1]; $new[$new.Count - 1] = @($new[$new.Count - 1][0], $m.Lines[$last][1])   # keep the block's own last ending
        $same = $s.ptAt.Count -eq $new.Count; if ($same) { for ($j = 0; $j -lt $new.Count; $j++) { if ($m.Lines[$s.ptAt[$j]][0] -ne $new[$j][0]) { $same = $false; break } } }
        if (-not $same) { $edits.Add(@{ at = $s.ptAt[0]; n = $s.ptAt.Count; new = $new.ToArray() }) }
      } else {
        # no points yet: after the section's last line (that line gets a line ending if it was the file's last line)
        $i = $s.last; $e = @{ at = $i; n = 1; new = @(, @($m.Lines[$i][0], $(if ($m.Lines[$i][1]) { $m.Lines[$i][1] } else { $nl }))) + $new.ToArray() }
        if (-not $m.Lines[$i][1]) { $e.new[$e.new.Count - 1] = @($e.new[$e.new.Count - 1][0], '') }
        $edits.Add($e)
      }
    }
  }
  foreach ($c in @($ch.heads | Where-Object { $_ })) {
    $k = 0; if (-not [int]::TryParse("$($c.k)", [ref]$k) -or -not $headBy.ContainsKey($k)) { throw "The movement has no head number $($c.k). NOTHING was changed." }
    if ($done.ContainsKey("h|$k")) { throw "Head $k was sent twice. NOTHING was changed." }; $done["h|$k"] = 1
    $h = $headBy[$k]; $what = "Head $("$($h.keys['Name'])")"
    foreach ($p in @(@('op', 'OffsetPan', -65535, 65535), @('ot', 'OffsetTilt', -65535, 65535), @('zp', 'ZoomPan', -99, 900), @('zt', 'ZoomTilt', -99, 900))) {
      $v = $c.($p[0]); if ($null -eq $v) { continue }
      if ($own) { throw "$what : Aim Movers sets the aim and size of the heads in this movement$(if ($own -eq 'room') { ' (Room)' }) - change them there. NOTHING was changed." }
      $d = 0; if (-not [int]::TryParse("$v", [ref]$d) -or $d -lt $p[2] -or $d -gt $p[3]) { throw "$what : $($p[1]) has to be a whole number $($p[2])..$($p[3]). NOTHING was changed." }
      & $setKey $h $p[1] "$d" $what
    }
    foreach ($q in 'rp', 'rt') { if ($null -ne $c.$q) { throw "$what : Reverse is set by Reverse heads in SX Studio, not here. NOTHING was changed." } }
  }
  # no two edits on the same lines
  $sorted = @($edits | Sort-Object { $_.at })
  for ($j = 1; $j -lt $sorted.Count; $j++) { if ($sorted[$j].at -lt $sorted[$j - 1].at + $sorted[$j - 1].n) { throw "Self-check failed (two changes on the same line). NOTHING was changed." } }
  ,$sorted
}
function Get-ChangedText($o, $edits) {
  $L = $o.M.Lines; $out = New-Object Collections.Generic.List[object]; $i = 0
  foreach ($e in $edits) { while ($i -lt $e.at) { $out.Add($L[$i]); $i++ }; foreach ($n in $e.new) { $out.Add($n) }; $i += $e.n }
  while ($i -lt $L.Count) { $out.Add($L[$i]); $i++ }
  Join-Lines $out
}
function Get-ExpectedModel($o, $ch) {
  # the same changes made on the plain model (the second, independent way)
  $mo = Get-Model $o.M
  foreach ($c in @($ch.secs | Where-Object { $_ })) {
    $s = @($mo.secs | Where-Object { $_.name -eq "$($c.name)" })[0]
    if ($null -ne $c.sel) { $s.sel = $(if ("$($c.sel)" -in '1', 'True') { 1 } else { 0 }) }
    if ($null -ne $c.tr) { $s.tr = [int]$c.tr }
    if ($null -ne $c.dur) { $s.dur = [double][int]$c.dur }
    if ($null -ne $c.shift) { $s.shift = [double]::Parse((Format-Num ([double]::Parse("$($c.shift)", $inv)) $true), $inv) }
    if ($null -ne $c.pts) { $s.pts = @(foreach ($p in @($c.pts)) { ,@([int]$p[0], [int]$p[1]) }) }
  }
  foreach ($c in @($ch.heads | Where-Object { $_ })) {
    $h = @($mo.heads | Where-Object { $_.k -eq [int]$c.k })[0]
    foreach ($p in 'op', 'ot', 'zp', 'zt') { if ($null -ne $c.$p) { $h.$p = [double][int]$c.$p } }
  }
  $mo
}
function Get-NewBytes($o, $ch) {
  # -> @{ bytes; what } after the checks; throws if anything doesn't add up
  $edits = Test-Changes $o $ch
  $nt = Get-ChangedText $o $edits
  $re = Read-Move $nt
  if ($re.Why -or (Get-ModelJson (Get-Model $re)) -ne (Get-ModelJson (Get-ExpectedModel $o $ch))) { throw "Self-check failed (the new movement doesn't read back as asked). NOTHING was changed." }
  # every line that wasn't edited is still there, in the same order
  $keep = @{}; foreach ($e in $edits) { for ($j = 0; $j -lt $e.n; $j++) { $keep[$e.at + $j] = 1 } }
  $a = New-Object Text.StringBuilder; for ($j = 0; $j -lt $o.M.Lines.Count; $j++) { if (-not $keep.ContainsKey($j)) { [void]$a.Append($o.M.Lines[$j][0]).Append($o.M.Lines[$j][1]).Append("`0") } }
  $edited = @{}; $pos = 0; $idx = 0; foreach ($e in $edits) { $idx += ($e.at - $pos); for ($j = 0; $j -lt $e.new.Count; $j++) { $edited[$idx + $j] = 1 }; $idx += $e.new.Count; $pos = $e.at + $e.n }
  $b = New-Object Text.StringBuilder; for ($j = 0; $j -lt $re.Lines.Count; $j++) { if (-not $edited.ContainsKey($j)) { [void]$b.Append($re.Lines[$j][0]).Append($re.Lines[$j][1]).Append("`0") } }
  if ($a.ToString() -ne $b.ToString()) { throw "Self-check failed (a line that wasn't edited would change). NOTHING was changed." }
  # what changed, in words
  $old = Get-Model $o.M; $new = Get-Model $re; $w = @()
  foreach ($s in $new.secs) { $os = @($old.secs | Where-Object { $_.name -eq $s.name })[0]; $d = @()
    if ((Get-ModelJson $os.pts) -ne (Get-ModelJson $s.pts)) { $d += 'shape' }
    if ($os.sel -ne $s.sel) { $d += $(if ($s.sel) { 'on' } else { 'off' }) }
    if ($os.tr -ne $s.tr) { $d += 'transition' }; if ($os.dur -ne $s.dur) { $d += 'cycle time' }; if ($os.shift -ne $s.shift) { $d += 'shift' }
    if ($d.Count) { $w += "$(if ($s.name -eq $ptSec) { 'pan/tilt' } else { $s.name }) ($($d -join ', '))" } }
  $nh = 0; for ($j = 0; $j -lt $new.heads.Count; $j++) { if ((Get-ModelJson $old.heads[$j]) -ne (Get-ModelJson $new.heads[$j])) { $nh++ } }
  if ($nh) { $w += "$nh head(s) aim/size" }
  @{ bytes = (ConvertTo-Bytes $nt $o.File.Bom); what = ($w -join '; '); ptsChanged = ((Get-ModelJson ($old.secs | Where-Object { $_.name -eq $ptSec }).pts) -ne (Get-ModelJson ($new.secs | Where-Object { $_.name -eq $ptSec }).pts)); newPts = @(($new.secs | Where-Object { $_.name -eq $ptSec }).pts) }
}

# ---------------------------------------------------------------- Aim Movers' shape record
function Update-AimRecord([string]$file, $pts) {
  $own = (Get-AimOwner)[$file.ToLower()]; if (-not $own -or -not $pts -or @($pts).Count -lt 2) { return $null }
  $p = Join-Path $root $(if ($own -eq 'room') { 'room_aim_state.json' } else { 'df_aim_state.json' })
  $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
  $rec = $j.files.$file; if (-not $rec) { return $null }
  $sx = [double]$rec.sx; $sy = [double]$rec.sy; if ($sx -le 0) { $sx = 1 }; if ($sy -le 0) { $sy = 1 }
  $xs = @($pts | ForEach-Object { [double]$_[0] }); $ys = @($pts | ForEach-Object { [double]$_[1] })
  $cx = (($xs | Measure-Object -Minimum).Minimum + ($xs | Measure-Object -Maximum).Maximum) / 2
  $cy = (($ys | Measure-Object -Minimum).Minimum + ($ys | Measure-Object -Maximum).Maximum) / 2
  $fmt = { param($a) (@($a | ForEach-Object { "{0},{1}" -f [int][math]::Round($_[0]), [int][math]::Round($_[1]) }) -join ';') }
  $rec.written = & $fmt $pts
  $rec.base = & $fmt @($pts | ForEach-Object { ,@(($cx + ($_[0] - $cx) / $sx), ($cy + ($_[1] - $cy) / $sy)) })
  [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  $own
}

# ---------------------------------------------------------------- backups (outside the show folder, so Google Drive never gets them)
function Get-BackupDir([string]$name) {
  $base = if ($TestRoot) { Join-Path (Split-Path $TestRoot) 'move_backups' }
          elseif ($onMac) { Join-Path $HOME 'AwaazTools/move_backups' }
          else { Join-Path $env:APPDATA 'ShowXpress Helper/move_backups' }
  Join-Path (Join-Path $base (Split-Path $root -Leaf)) $name
}
function Get-Backups([string]$name) {
  $d = Get-BackupDir $name
  if (-not (Test-Path -LiteralPath $d)) { return @() }
  @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File | Sort-Object Name -Descending | ForEach-Object {
    try { $j = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } catch { return }
    $f = Join-Path $d ($_.BaseName + '.gpj')
    if (Test-Path -LiteralPath $f) { [pscustomobject]@{ id = $_.BaseName; at = "$($j.at)"; what = "$($j.what)"; written = "$($j.written)"; path = $f } }
  })
}
function Add-Backup([string]$name, [byte[]]$bytes, [string]$what) {
  $d = Get-BackupDir $name
  New-Item -ItemType Directory -Force $d | Out-Null
  $id = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  [IO.File]::WriteAllBytes((Join-Path $d "$id.gpj"), $bytes)
  [pscustomobject]@{ id = $id; dir = $d; json = (Join-Path $d "$id.json"); at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); what = $what }
}
function Save-BackupInfo($bk, [string]$written, [string]$name) {
  [IO.File]::WriteAllText($bk.json, ([ordered]@{ at = $bk.at; what = $bk.what; written = $written } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  foreach ($old in @(Get-Backups $name | Select-Object -Skip $maxBackups)) {
    Remove-Item -LiteralPath $old.path -ErrorAction SilentlyContinue; Remove-Item -LiteralPath ($old.path -replace '\.gpj$', '.json') -ErrorAction SilentlyContinue
  }
}
function Write-MoveBytes([string]$path, [byte[]]$bytes) {
  $tmp = "$path.sxm-tmp"
  [IO.File]::WriteAllBytes($tmp, $bytes)
  try { [IO.File]::Replace($tmp, $path, $null) } catch { [IO.File]::Copy($tmp, $path, $true); Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  if (-not (Test-SameBytes ([IO.File]::ReadAllBytes($path)) $bytes)) { throw "The movement didn't read back the same after saving. Use Revert to put the earlier version back." }
}

# ================================================================ actions
if (-not (Test-Path -LiteralPath $gdir)) { throw "The show has no Generator movements folder ($gdir). NOTHING was changed." }

if ($Action -eq 'List') {
  $used = Get-UsedBy; $own = Get-AimOwner
  $list = foreach ($fi in @(Get-ChildItem -LiteralPath $gdir -Filter '*.gpj' -File | Sort-Object Name)) {
    $o = $null; try { $o = Open-Move $fi.FullName } catch {}
    $mo = if ($o -and $o.M) { Get-Model $o.M } else { $null }
    $pt = if ($mo) { @($mo.secs | Where-Object { $_.name -eq $ptSec })[0] } else { $null }
    $u = $used[$fi.Name.ToLower()]
    [pscustomobject]@{ file = $fi.Name; name = (Get-Title $fi.Name); heads = $(if ($mo) { $mo.heads.Count } else { 0 })
      points = $(if ($pt) { $pt.pts.Count } else { 0 }); moves = [bool]($pt -and $pt.sel); cycle = $(if ($pt) { $pt.dur / 10 } else { 0 })
      on = @(if ($mo) { $mo.secs | Where-Object { $_.sel -and $_.name -ne $ptSec } | ForEach-Object { $_.name } })
      used = @(if ($u) { $u | ForEach-Object { "$($_.page): $($_.title)" } }); aim = "$($own[$fi.Name.ToLower()])"
      readonly = $(if (-not $o) { 'it could not be read' } else { $o.Why }); at = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
  }
  [pscustomobject]@{ ok = $true; show = (Split-Path $root -Leaf); moves = @($list) } | ConvertTo-Json -Depth 5 -Compress
  return
}

if ($Action -eq 'Open') {
  $path = Get-MoveFile $Move
  $o = Open-Move $path
  $patch = Get-Patch; $lab = Get-Labels; $u = (Get-UsedBy)[$Move.ToLower()]
  $mo = if ($o.M) { Get-Model $o.M } else { $null }
  $heads = @(if ($mo) { foreach ($h in $mo.heads) {
    $l = $lab[$h.id]
    [pscustomobject]@{ k = $h.k; id = $h.id; name = $h.name; label = $(if ($l) { $l.label } else { $h.name -replace '^.*?(#\d+)?$', '$1' }); model = $(if ($l) { $l.model } else { $h.name -replace '\s*#\d+(\s*#\d+)*$', '' })
      addr = $(if ($patch.ContainsKey($h.id)) { $patch[$h.id] } else { 0 }); chans = $h.chans; rp = $h.rp; rt = $h.rt; op = $h.op; ot = $h.ot; zp = $h.zp; zt = $h.zt; has = $h.has }
  } })
  [pscustomobject]@{ ok = $true; file = $Move; name = (Get-Title $Move); sha = $o.File.Sha; readonly = $o.Why
    aim = "$((Get-AimOwner)[$Move.ToLower()])"; used = @(if ($u) { $u | ForEach-Object { "$($_.page): $($_.title)" } })
    params = $(if ($o.M) { $o.M.Params } else { @{} }); heads = $heads; secs = @(if ($mo) { $mo.secs }) } | ConvertTo-Json -Depth 8 -Compress
  return
}

if ($Action -eq 'Backups') {
  $null = Get-MoveFile $Move
  [pscustomobject]@{ ok = $true; file = $Move; backups = @(Get-Backups $Move | ForEach-Object { [pscustomobject]@{ id = $_.id; at = $_.at; what = $_.what } }) } | ConvertTo-Json -Depth 3 -Compress
  return
}

if ($Action -eq 'Check') {
  # every movement: read, then every value + every point block written again from the model -> must be byte-identical
  $res = foreach ($fi in @(Get-ChildItem -LiteralPath $gdir -Filter '*.gpj' -File | Sort-Object Name)) {
    $o = Open-Move $fi.FullName
    if ($o.Why) { [pscustomobject]@{ file = $fi.Name; ok = $true; skipped = $o.Why }; continue }
    $mo = Get-Model $o.M; $own = (Get-AimOwner)[$fi.Name.ToLower()]
    $ch = [pscustomobject]@{
      secs = @(foreach ($s in $mo.secs) { $c = [ordered]@{ name = $s.name }
        if ('Selected' -in $s.has) { $c.sel = $s.sel }; if ('Transition' -in $s.has) { $c.tr = $s.tr }; if ('Duration' -in $s.has -and $s.dur -eq [math]::Round($s.dur)) { $c.dur = [int]$s.dur }
        if (-not $s.locked -and $s.pts.Count) { $c.pts = $s.pts }; [pscustomobject]$c })
      heads = @(if (-not $own) { foreach ($h in $mo.heads) { $c = [ordered]@{ k = $h.k }; foreach ($p in @(@('op', 'OffsetPan'), @('ot', 'OffsetTilt'), @('zp', 'ZoomPan'), @('zt', 'ZoomTilt'))) { if ($p[1] -in $h.has -and $h.($p[0]) -eq [math]::Round($h.($p[0]))) { $c[$p[0]] = [int]$h.($p[0]) } }; [pscustomobject]$c } }) }
    $script:Move = $fi.Name
    try { $r = Get-NewBytes $o $ch; $same = Test-SameBytes $r.bytes $o.File.Bytes; [pscustomobject]@{ file = $fi.Name; ok = $same; skipped = ''; why = $(if ($same) { '' } else { 'did not come out byte for byte the same' }) } }
    catch { [pscustomobject]@{ file = $fi.Name; ok = $false; skipped = ''; why = $_.Exception.Message } }
  }
  $res = @($res)
  [pscustomobject]@{ ok = -not @($res | Where-Object { -not $_.ok }).Count; moves = $res } | ConvertTo-Json -Depth 4 -Compress
  return
}

if ($Action -eq 'Render') {
  # the live preview: the movement as it would be saved, into a file of its own (the show isn't touched)
  if (-not $Out -or $Out -notmatch '\.gpj$') { throw 'Render needs -Out <file>.gpj.' }
  $ch = Read-ChangesFile $ChangesFile; if ($ch.Count -ne 1) { throw 'No changes were sent.' }; $ch = $ch[0]
  $Move = "$($ch.move)"; $path = Get-MoveFile $Move
  $o = Open-Move $path; if ($o.Why) { throw "$(Get-Title $Move) can't be shown from here: $($o.Why)." }
  $r = Get-NewBytes $o $ch
  [IO.File]::WriteAllBytes($Out, $r.bytes)
  "  rendered $(Get-Title $Move)"
  return
}

# ---------------------------------------------------------------- Save / Revert: ShowXpress has to be closed
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }

if ($Action -eq 'Revert') {
  $path = Get-MoveFile $Move
  $bk = @(Get-Backups $Move | Where-Object { $_.id -eq $Backup }) | Select-Object -First 1
  if (-not $bk) { throw "That backup is not there any more. NOTHING was changed." }
  $cur = [IO.File]::ReadAllBytes($path); $curSha = Get-BytesSha $cur
  if (-not $Force -and $bk.written -and $curSha -ne $bk.written) {
    '{"conflict":true}'
    "  The movement was changed after that save (in ShowXpress or SX Studio). Revert anyway?"
    return
  }
  $old = [IO.File]::ReadAllBytes($bk.path)
  if ($curSha -eq (Get-BytesSha $old)) { "  $(Get-Title $Move) is already that version - nothing to change."; return }
  $nb = Add-Backup $Move $cur "before going back to $($bk.at)"
  Write-MoveBytes $path $old
  Save-BackupInfo $nb (Get-BytesSha $old) $Move
  "  CHANGED  $(Get-Title $Move): back to the version from before $($bk.at)"
  $ro = Open-Move $path
  if (-not $ro.Why) { $pt = @((Get-Model $ro.M).secs | Where-Object { $_.name -eq $ptSec })[0]; if ($pt) { $own = Update-AimRecord $Move $pt.pts; if ($own) { "  Aim Movers will keep this shape as it is now." } } }
  return
}

# Save
$ch = Read-ChangesFile $ChangesFile
if ($ch.Count -ne 1) { throw "No changes were sent. NOTHING was changed." }
$ch = $ch[0]
$Move = "$($ch.move)"; $path = Get-MoveFile $Move
$o = Open-Move $path
if ($o.Why) { throw "$(Get-Title $Move) can't be changed by SX Studio: $($o.Why). NOTHING was changed." }
if ("$($ch.sha)" -ne $o.File.Sha) { throw "$(Get-Title $Move) was changed since you opened it (in ShowXpress or another window). Press Reload to see it as it is now. NOTHING was changed." }
$r = Get-NewBytes $o $ch
if (Test-SameBytes $r.bytes $o.File.Bytes) { "  $(Get-Title $Move) - nothing to change."; return }
$bk = Add-Backup $Move $o.File.Bytes "before: $($r.what)"
Write-MoveBytes $path $r.bytes
Save-BackupInfo $bk (Get-BytesSha $r.bytes) $Move
"  CHANGED  $(Get-Title $Move): $($r.what)"
if ($r.ptsChanged) {
  $own = Update-AimRecord $Move $r.newPts
  if ($own) { "  Aim Movers$(if ($own -eq 'room') { ' (Room)' }) will keep this shape as you drew it (it moves and sizes it, but doesn't re-make it)." }
}
"  backup kept: $($bk.id)"
