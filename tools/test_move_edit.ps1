# Tests for the movement editor engine (src/move_edit.ps1). Runs on Windows PowerShell 5.1 and pwsh 7 (Mac / Linux).
#   pwsh -File tools/test_move_edit.ps1                 -> builds a small test show in a temp folder and checks every rule
#   pwsh -File tools/test_move_edit.ps1 -Show <folder>  -> also: every movement of a real show must read back byte for byte
#                                                         (copied to a temp folder first; nothing in the show is written)
# Exit code 0 = all passed.
param([string]$Show = '')
$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path $PSScriptRoot) 'src/move_edit.ps1'
$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sxm_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$T = Join-Path $tmp 'Test Show'
$G = "$T/Editor/Generator/projects"
$fails = New-Object Collections.Generic.List[string]; $n = 0
function Check([string]$what, [bool]$ok, [string]$more = '') { $script:n++; if ($ok) { "  ok    $what" } else { "  FAIL  $what $more"; $script:fails.Add($what) } }
function Run([string]$a, [string]$root = $T) {
  $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = $psExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$engine`" $a -TestRoot `"$root`""
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
  [pscustomobject]@{ ok = ($p.ExitCode -eq 0 -and -not $e.Result.Trim()); out = $o.Result; err = $e.Result }
}
function J($r) { (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json }
function CF($changes) {
  $cf = Join-Path $tmp ('c_' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($cf, ($changes | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false))); $cf
}
function Save($changes) { Run "-Action Save -ChangesFile `"$(CF $changes)`"" }
function Bytes([string]$f) { [IO.File]::ReadAllBytes((Join-Path $G $f)) }
function Txt([string]$f) { $b = Bytes $f; $o = if ($b.Length -ge 3 -and $b[0] -eq 0xEF) { 3 } else { 0 }; [Text.Encoding]::UTF8.GetString($b, $o, $b.Length - $o) }
function Sha([string]$f) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash((Bytes $f))) -replace '-', '').ToLower() }
function W([string]$f, [string]$text, [bool]$bom = $true) { [IO.File]::WriteAllText((Join-Path $G $f), $text, (New-Object Text.UTF8Encoding($bom))) }
function Open([string]$f) { J (Run "-Action Open -Move `"$f`"") }
$pt = 'Pan/Tilt/uPan/uTilt'

# ---------------------------------------------------------------- the test show
New-Item -ItemType Directory -Force $G, "$T/Live", "$T/scenes" | Out-Null
$m = 'Intimidator Hybrid 140SR (19ch)'
[IO.File]::WriteAllText("$T/fixtures.ini", "[Fixture1]`r`nname = 140 #1`r`nmodel = $m`r`naddress = 1`r`nid = 11`r`n`r`n[Fixture2]`r`nname = 140 #2`r`nmodel = $m`r`naddress = 20`r`nid = 12`r`n")
[IO.File]::WriteAllText("$T/Live/live.ini", "[live]`r`nmaster_faders = 0`r`n`r`n[page1]`r`nname = MOVEMENTS`r`nnb_buttons = 1`r`n`r`n[page1_button1]`r`nline = 1`r`ncolumn = 1`r`nname = FIG.gpj`r`ntitle = FIG`r`n", (New-Object Text.UTF8Encoding($true)))
$chs = 'pan,upan,tilt,utilt,dimmer'
function Head([int]$k, [string]$id, [string]$nm, [int]$dmx) { @("[Fixture_$k]", "ID = $id", "Name = $nm", "DMX = $dmx", "Channels = $chs", 'ReversePan = 0', 'ReverseTilt = 0', 'OffsetPan = 0', 'OffsetTilt = 0', 'ZoomPan = 0', 'ZoomTilt = 0', 'ExplodeIndex = 0') }
function Sec([string]$nm, [int]$sel, [int]$tr, [int]$dur, [string[]]$pts) { @("[$nm]", "Selected = $sel", 'CurveName = Default Curve', "Transition = $tr", "Duration = $dur", 'Shift = 0.0') + @(for ($i = 0; $i -lt $pts.Count; $i++) { "Point_$i = $($pts[$i])" }) }
$lines = @('', '[Params]', 'PanTiltShift = 0.0', 'ExplodePanTilt = 0', 'GroupRGB = 0', 'FanPanOffset = 0', 'FanTiltOffset = 0') + (Head 0 '11' $m 0) + (Head 1 '12' "$m #2" 19) +
  (Sec $pt 1 2 100 @('20000,50000', '25000,45000', '25000,50000', '20000,45000')) + (Sec 'dimmer' 0 0 50 @('0,65535', '65535,65535'))
$fig = ($lines -join "`n") + "`n"                  # ShowXpress's own way: BOM, LF, a blank first line
W 'FIG.gpj' $fig
$crlf = ($lines -join "`r`n")                        # saved again by ShowXpress: CRLF, and no line ending at the very end
W 'CRLF.gpj' $crlf
# mixed line endings + things the editor doesn't know (an unknown key, an unknown section, a key with no " = ")
$odd = "`n[Params]`r`nPanTiltShift = 0.0`n[Fixture_0]`nID = 11`nName = $m`nChannels = $chs`nOffsetPan = 5`r`nSomething = keep me`nZoomPan = 0`n" +
  "[$pt]`nSelected = 1`nTransition = 1`nDuration = 30`nShift = 0.0`nWeird line`nPoint_0 = 1,2`r`nPoint_1 = 3,4`n[Extra]`nA = b`n"
W 'ODD.gpj' $odd $false
# points not in one block -> read-only points, the rest can still be changed
W 'GAP.gpj' ("`n[Fixture_0]`nID = 11`nName = $m`n[$pt]`nSelected = 1`nTransition = 2`nDuration = 10`nShift = 0.0`nPoint_0 = 1,1`nCurveName = x`nPoint_1 = 2,2`n")
W 'NOHEADS.gpj' "`n[Params]`nPanTiltShift = 0.0`n[$pt]`nSelected = 1`nPoint_0 = 1,1`n"
[IO.File]::WriteAllBytes((Join-Path $G 'BAD.gpj'), [byte[]](0xEF, 0xBB, 0xBF, 0x0A, 0xC3, 0x28, 0x0A))
# Aim Movers' record of FIG (Dance Floor), at size 1.2
$aimRec = '{"sx":1.2,"sy":1.2,"files":{"FIG.gpj":{"base":"x","written":"20000,50000;25000,45000;25000,50000;20000,45000","sx":1.2,"sy":1.2}},"copied":{}}'
[IO.File]::WriteAllText("$T/df_aim_state.json", $aimRec)

# ---------------------------------------------------------------- reading
$c = J (Run '-Action Check')
Check 'Check: every movement it can edit comes out byte for byte the same' ($c.ok) (($c.moves | Where-Object { -not $_.ok } | ForEach-Object { "$($_.file): $($_.why)" }) -join '; ')
Check 'Check: a file with no heads / not UTF-8 is skipped, not broken' (@($c.moves | Where-Object { $_.skipped }).Count -eq 2)
$l = J (Run '-Action List')
$f = @($l.moves | Where-Object { $_.file -eq 'FIG.gpj' })[0]
Check 'List: heads, points, cycle, buttons, Aim owner' ($f.heads -eq 2 -and $f.points -eq 4 -and $f.cycle -eq 10 -and $f.moves -and ($f.used -join '') -eq 'MOVEMENTS: FIG' -and $f.aim -eq 'floor')
Check 'List: an unreadable file is read-only' ((@($l.moves | Where-Object { $_.file -eq 'BAD.gpj' })[0].readonly) -ne '')
$o = Open 'FIG.gpj'
$s = @($o.secs | Where-Object { $_.name -eq $pt })[0]
Check 'Open: heads with DMX addresses from fixtures.ini' ($o.heads.Count -eq 2 -and $o.heads[0].addr -eq 1 -and $o.heads[1].addr -eq 20 -and $o.aim -eq 'floor')
Check 'Open: the pan/tilt points' ($s.pts.Count -eq 4 -and $s.pts[1][0] -eq 25000 -and $s.pts[1][1] -eq 45000 -and $s.dur -eq 100 -and $s.tr -eq 2)
$gp = Open 'GAP.gpj'
Check 'Open: points that are not one block are locked' (@($gp.secs)[0].locked)

# ---------------------------------------------------------------- saving
$s0 = Sha 'CRLF.gpj'; $oc = Open 'CRLF.gpj'
$r = Save @{ move = 'CRLF.gpj'; sha = $oc.sha; secs = @(@{ name = $pt; pts = @(@(1, 2), @(3, 4), @(5, 6), @(7, 8), @(9, 10)); dur = 45; shift = 6.25; tr = 1 }, @{ name = 'dimmer'; sel = 1 }); heads = @(@{ k = 1; op = -300; zt = 25 }) }
$want = $crlf.Replace("Duration = 100`r`nShift = 0.0`r`nPoint_0 = 20000,50000`r`nPoint_1 = 25000,45000`r`nPoint_2 = 25000,50000`r`nPoint_3 = 20000,45000",
  "Duration = 45`r`nShift = 6.25`r`nPoint_0 = 1,2`r`nPoint_1 = 3,4`r`nPoint_2 = 5,6`r`nPoint_3 = 7,8`r`nPoint_4 = 9,10").Replace("Transition = 2`r`nDuration = 45", "Transition = 1`r`nDuration = 45")
$want = $want.Replace("[dimmer]`r`nSelected = 0", "[dimmer]`r`nSelected = 1")
$i1 = $want.IndexOf('[Fixture_1]'); $want = $want.Substring(0, $i1) + $want.Substring($i1).Replace('OffsetPan = 0', 'OffsetPan = -300').Replace('ZoomTilt = 0', 'ZoomTilt = 25')
Check 'Save (CRLF file): only the edited lines change, CRLF kept, no ending added at the end' ($r.ok -and (Txt 'CRLF.gpj') -ceq $want -and (Bytes 'CRLF.gpj')[0] -eq 0xEF) $r.err
$r = Save @{ move = 'CRLF.gpj'; sha = $s0; secs = @(@{ name = $pt; dur = 50 }) }
Check 'Save refused when the file changed since it was opened' (-not $r.ok -and $r.err -match 'changed since')
$o2 = Open 'CRLF.gpj'
$r = Save @{ move = 'CRLF.gpj'; sha = $o2.sha; secs = @(@{ name = 'dimmer'; pts = @(@(0, 0), @(70000, 1)) }) }
Check 'Save refused: a point outside 0..65535' (-not $r.ok -and $r.err -match '0\.\.65535' -and (Txt 'CRLF.gpj') -ceq $want)
$r = Save @{ move = 'CRLF.gpj'; sha = $o2.sha; secs = @(@{ name = 'nope'; sel = 1 }) }
Check 'Save refused: a channel the movement does not have' (-not $r.ok -and $r.err -match 'no channel')
$r = Save @{ move = 'CRLF.gpj'; sha = $o2.sha; heads = @(@{ k = 0; rp = 1 }) }
Check 'Save refused: Reverse belongs to Reverse heads' (-not $r.ok -and $r.err -match 'Reverse heads')
$r = Save @{ move = 'CRLF.gpj'; sha = $o2.sha; secs = @(@{ name = $pt; pts = @(@(1, 2), @(3, 4), @(5, 6), @(7, 8), @(9, 10)) }) }
Check 'Save with nothing different writes nothing' ($r.ok -and $r.out -match 'nothing to change' -and (Txt 'CRLF.gpj') -ceq $want)
$r = Save @{ move = 'CRLF.gpj'; sha = $o2.sha; secs = @(@{ name = $pt; pts = @(,@(11, 12)) }) }
Check 'Fewer points: the block shrinks in place' ($r.ok -and (Txt 'CRLF.gpj') -match "Shift = 6\.25`r`nPoint_0 = 11,12`r`n\[dimmer\]") $r.err

# ODD: unknown keys / sections / lines and mixed endings survive a change
$oo = Open 'ODD.gpj'
$r = Save @{ move = 'ODD.gpj'; sha = $oo.sha; secs = @(@{ name = $pt; pts = @(@(10, 20), @(30, 40), @(50, 60)) }); heads = @(@{ k = 0; op = 9 }) }
$wo = $odd.Replace("Point_0 = 1,2`r`nPoint_1 = 3,4`n", "Point_0 = 10,20`r`nPoint_1 = 30,40`r`nPoint_2 = 50,60`n").Replace("OffsetPan = 5`r`n", "OffsetPan = 9`r`n")
Check 'Save (odd file): unknown keys, lines and sections kept, each line keeps its own ending, no BOM added' ($r.ok -and (Txt 'ODD.gpj') -ceq $wo -and (Bytes 'ODD.gpj')[0] -ne 0xEF) $r.err
$r = Save @{ move = 'ODD.gpj'; sha = (Open 'ODD.gpj').sha; heads = @(@{ k = 0; ot = 1 }) }
Check 'Save refused: a key the head does not have' (-not $r.ok -and $r.err -match "no 'OffsetTilt' line")
$og = Open 'GAP.gpj'
$r = Save @{ move = 'GAP.gpj'; sha = $og.sha; secs = @(@{ name = $pt; pts = @(@(5, 5)) }) }
Check 'Save refused: locked points' (-not $r.ok -and $r.err -match "doesn't change")
$r = Save @{ move = 'GAP.gpj'; sha = $og.sha; secs = @(@{ name = $pt; dur = 77 }) }
Check '...but its cycle can still be changed' ($r.ok -and (Txt 'GAP.gpj') -match 'Duration = 77')

# Aim Movers' movements: head aim/size belong to Aim; a new shape goes into Aim's record
$of = Open 'FIG.gpj'
$r = Save @{ move = 'FIG.gpj'; sha = $of.sha; heads = @(@{ k = 0; op = 100 }) }
Check 'Save refused: head aim in a movement Aim Movers looks after' (-not $r.ok -and $r.err -match 'Aim Movers')
$r = Save @{ move = 'FIG.gpj'; sha = $of.sha; secs = @(@{ name = $pt; pts = @(@(20000, 50000), @(32000, 44000), @(26000, 50000)) }) }
$aj = [IO.File]::ReadAllText("$T/df_aim_state.json") | ConvertFrom-Json
Check "A saved shape goes into Aim Movers' record (written = as saved, base = at size 100)" ($r.ok -and $aj.files.'FIG.gpj'.written -eq '20000,50000;32000,44000;26000,50000' -and $aj.files.'FIG.gpj'.base -eq '21000,49500;31000,44500;26000,49500') "$($aj.files.'FIG.gpj' | ConvertTo-Json -Compress) $($r.err)"

# Render = the preview file; the show isn't touched
$before = Sha 'FIG.gpj'; $rf = Join-Path $tmp 'preview.gpj'; $of = Open 'FIG.gpj'
$r = Run "-Action Render -ChangesFile `"$(CF @{ move = 'FIG.gpj'; sha = $of.sha; secs = @(@{ name = $pt; dur = 20 }) })`" -Out `"$rf`""
Check 'Render writes the preview file only' ($r.ok -and (Sha 'FIG.gpj') -eq $before -and ([IO.File]::ReadAllText($rf)) -match 'Duration = 20') $r.err

# backups + revert
$bk = J (Run '-Action Backups -Move "CRLF.gpj"')
Check 'Every save kept a backup' (@($bk.backups).Count -eq 2)
$first = @($bk.backups)[-1]
$r = Run "-Action Revert -Move `"CRLF.gpj`" -Backup $($first.id)"
Check 'Revert of an old backup asks first (it was saved again since)' ($r.ok -and $r.out -match '"conflict"')
$r = Run "-Action Revert -Move `"CRLF.gpj`" -Backup $($first.id) -Force"
Check 'Revert puts the very first version back, byte for byte' ($r.ok -and (Sha 'CRLF.gpj') -eq $s0) $r.err
Check 'No temp file left in projects/' (-not @(Get-ChildItem -LiteralPath $G -Filter '*.sxm-tmp').Count)

# ---------------------------------------------------------------- a real show (read only, on a copy)
if ($Show) {
  $R = Join-Path $tmp 'Real Show'
  New-Item -ItemType Directory -Force "$R/Editor/Generator" | Out-Null
  Copy-Item -Recurse -LiteralPath (Join-Path $Show 'Editor/Generator/projects') -Destination "$R/Editor/Generator"
  foreach ($x in 'fixtures.ini', 'Live', 'df_aim_state.json', 'room_aim_state.json') { $p = Join-Path $Show $x; if (Test-Path -LiteralPath $p) { Copy-Item -Recurse -LiteralPath $p -Destination $R } }
  $c = J (Run '-Action Check' $R)
  "  Real show: $(@($c.moves).Count) movements"
  foreach ($s in @($c.moves | Where-Object { $_.skipped })) { "        read only: $($s.file) - $($s.skipped)" }
  Check 'Real show: every movement reads back byte for byte' ($c.ok) (($c.moves | Where-Object { -not $_.ok } | ForEach-Object { "$($_.file): $($_.why)" }) -join '; ')
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
""
if ($fails.Count) { "$($fails.Count) of $n FAILED"; exit 1 }
"All $n passed"
