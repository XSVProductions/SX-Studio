# Tests for the scene editor engine (src/scene_edit.ps1). Runs on Windows PowerShell 5.1 and pwsh 7 (Mac / Linux).
#   pwsh -File tools/test_scene_edit.ps1                 -> builds a small test show in a temp folder and checks every rule
#   pwsh -File tools/test_scene_edit.ps1 -Show <folder>  -> also: every scene of a real show must read back byte for byte
#                                                          (the show is copied to a temp folder first; nothing in it is written)
# Exit code 0 = all passed.
param([string]$Show = '')
$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path $PSScriptRoot) 'src/scene_edit.ps1'
$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sxs_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$T = Join-Path $tmp 'Test Show'
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
function Save($changes) {
  $cf = Join-Path $tmp ('c_' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($cf, ($changes | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
  Run "-Action Save -ChangesFile `"$cf`""
}
function Bytes([string]$f) { [IO.File]::ReadAllBytes((Join-Path "$T/scenes" $f)) }
function Txt([string]$f) { $b = Bytes $f; $o = if ($b.Length -ge 3 -and $b[0] -eq 0xEF) { 3 } else { 0 }; [Text.Encoding]::UTF8.GetString($b, $o, $b.Length - $o) }
function Sha([string]$f) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash((Bytes $f))) -replace '-', '').ToLower() }
function W([string]$f, [string]$text, [bool]$bom = $false) { [IO.File]::WriteAllText((Join-Path "$T/scenes" $f), $text, (New-Object Text.UTF8Encoding($bom))) }
function Steps([int]$k) { @(for ($i = 0; $i -lt $k; $i++) { @{ src = $i; set = @() } }) }
function AllSha { $h = @{}; foreach ($f in Get-ChildItem -LiteralPath $T -Recurse -File) { $h[$f.FullName] = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($f.FullName))) -replace '-', '') }; $h }

# ---------------------------------------------------------------- the test show
New-Item -ItemType Directory -Force "$T/scenes", "$T/Live", "$T/fixtures" | Out-Null
$m = 'Intimidator Hybrid 140SR (19ch)'
[IO.File]::WriteAllText("$T/fixtures.ini", "[Fixture1]`r`nname = 140 #1`r`nmodel = $m`r`naddress = 1`r`nid = 11`r`n`r`n[Fixture2]`r`nname = 140 #2`r`nmodel = $m`r`naddress = 20`r`nid = 12`r`n`r`n[Fixture3]`r`nname = UPLIGHT`r`naddress = 513`r`nid = 30`r`n")
[IO.File]::WriteAllText("$T/fixtures/$m.txt", "Channel = color`r`nWhite,0,9,Red,10,19,Green,20,29`r`n`r`nChannel = shutter`r`nClosed,0,7,Open,8,15`r`n")
[IO.File]::WriteAllText("$T/Live/live.ini", "[live]`r`nmaster_faders = 0`r`n`r`n[page1]`r`nname = CHASES`r`nnb_buttons = 1`r`n`r`n[page1_button1]`r`nline = 1`r`ncolumn = 1`r`nname = CHASE.scex`r`ntitle = CHASE`r`n", (New-Object Text.UTF8Encoding($true)))
$crlf = "`r`n"
$chase = (@('<?xml version="1.0" encoding="UTF-8"?>', '', '<Scene>', '  <Fixtures>',
  "    <Fixture id=`"11`" name=`"140 #1`" model=`"$m`"/>", "    <Fixture id=`"12`" name=`"140 #2`" model=`"$m`"/>", '  </Fixtures>', '  <Steps>',
  '    <Step length="50">', '      <Fixture id="11">', '        <Channel index="5" name="color" value="10" fade="1"/>', '        <Channel index="15" name="dimmer" value="255"/>', '      </Fixture>',
  '      <Fixture id="12">', '        <Channel index="5" name="color" value="0"/>', '        <Channel index="15" name="dimmer" value="0"/>', '      </Fixture>', '    </Step>',
  '    <Step length="50">', '      <Fixture id="11">', '        <Channel index="5" name="color" value="10"/>', '        <Channel index="15" name="dimmer" value="0"/>', '      </Fixture>',
  '      <Fixture id="12">', '        <Channel index="5" name="color" value="20" fade="1"/>', '        <Channel index="15" name="dimmer" value="255"/>', '      </Fixture>', '    </Step>',
  '    <Step length="25">', '      <Fixture id="11">', '        <Channel index="5" name="color" value="0"/>', '        <Channel index="15" name="dimmer" value="0"/>', '      </Fixture>',
  '      <Fixture id="12">', '        <Channel index="5" name="color" value="0"/>', '        <Channel index="15" name="dimmer" value="0"/>', '      </Fixture>', '    </Step>',
  '  </Steps>', '</Scene>', '') -join $crlf)
W 'CHASE.scex' $chase $true
# things the editor doesn't know: extra attributes, an unknown tag in a step, a comment, single quotes, odd spacing
$odd = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<Scene version=`"9.4.7`" flags='x'>`n  <Fixtures>`n    <Fixture id=`"11`" name=`"140 #1`" model=`"$m`" extra=`"keep me`"/>`n  </Fixtures>`n  <Steps speed=`"1`">`n" +
  "    <Step length=`"100`" note=`"a &amp; b`">`n      <Fixture id=`"11`" x=`"1`">`n        <!-- keep this -->`n        <Channel index=`"5`" name=`"color`" value = '20'  curve=`"2`" />`n        <Channel   index=`"15`"   name=`"dimmer`"   value=`"200`"/>`n      </Fixture>`n      <Unknown a=`"b`"><Deep/></Unknown>`n    </Step>`n" +
  "    <Step>`n      <Fixture id=`"11`">`n        <Channel index=`"5`" name=`"color`" value=`"0`" fade=`"0`"/>`n        <Channel index=`"15`" name=`"dimmer`" value=`"0`"/>`n      </Fixture>`n    </Step>`n  </Steps>`n  <Other>text</Other>`n</Scene>"
W 'ODD.scex' $odd
$between = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<Scene>`n  <Fixtures>`n    <Fixture id=`"11`" name=`"140 #1`" model=`"$m`"/>`n  </Fixtures>`n  <Steps>`n    <Step length=`"10`">`n      <Fixture id=`"11`">`n        <Channel index=`"15`" name=`"dimmer`" value=`"9`"/>`n      </Fixture>`n    </Step>`n    <Marker/>`n    <Step length=`"20`">`n      <Fixture id=`"11`">`n        <Channel index=`"15`" name=`"dimmer`" value=`"8`"/>`n      </Fixture>`n    </Step>`n  </Steps>`n</Scene>`n"
W 'BETWEEN.scex' $between
W 'SELFSTEP.scex' "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<Scene>`r`n  <Fixtures>`r`n    <Fixture id=`"11`" name=`"140 #1`" model=`"$m`"/>`r`n  </Fixtures>`r`n  <Steps>`r`n    <Step length=`"10`"/>`r`n    <Step length=`"30`">`r`n      <Fixture id=`"11`">`r`n        <Channel index=`"15`" name=`"dimmer`" value=`"1`"/>`r`n      </Fixture>`r`n    </Step>`r`n  </Steps>`r`n</Scene>`r`n"
W 'BROKEN.scex' "<?xml version=`"1.0`"?>`n<Scene>`n  <Steps>`n    <Step length=`"10`">`n  </Steps>`n</Scene>`n"
[IO.File]::WriteAllText("$T/scenes/UTF16.scex", $chase, [Text.Encoding]::Unicode)
W 'NOSTEPS.scex' "<?xml version=`"1.0`"?>`n<Scene>`n  <Fixtures/>`n  <Steps/>`n</Scene>`n"

"Scene editor tests ($($PSVersionTable.PSVersion), $T)"

# ---------------------------------------------------------------- reading
$c = J (Run '-Action Check')
$ed = @{}; foreach ($s in $c.scenes) { $ed[$s.file] = $s }
foreach ($f in 'CHASE.scex', 'ODD.scex', 'BETWEEN.scex', 'SELFSTEP.scex') { Check "$f can be edited and reads back byte for byte" ($ed[$f].editable -and $ed[$f].same -and $ed[$f].selfCheck) "($($ed[$f].why))" }
foreach ($f in 'BROKEN.scex', 'UTF16.scex', 'NOSTEPS.scex') { Check "$f is left alone (read only)" (-not $ed[$f].editable) }
Check 'BETWEEN.scex: steps can be changed but not moved' ($ed['BETWEEN.scex'].editable -and -not $ed['BETWEEN.scex'].structural)
$l = J (Run '-Action List')
$ch = @($l.scenes | Where-Object { $_.file -eq 'CHASE.scex' })[0]
Check 'List: steps, heads and the button that uses it' ($ch.steps -eq 3 -and $ch.heads -eq 2 -and @($ch.used)[0] -eq 'CHASES: CHASE')
$o = J (Run '-Action Open -Scene "CHASE.scex"')
Check 'Open: steps, heads, DMX addresses, channel names, named ranges' ($o.ok -and @($o.steps).Count -eq 3 -and @($o.heads)[1].addr -eq 20 -and @($o.models.$m.chans).Count -eq 2 -and @($o.models.$m.ranges.color)[1].n -eq 'red')
Check 'Open: values and fades' (@(@($o.steps)[0].fx)[0].ch[0][2] -eq 10 -and @(@($o.steps)[0].fx)[0].ch[0][3] -eq 1 -and @(@($o.steps)[0].fx)[0].ch[1][3] -eq 0)
$ob = J (Run '-Action Open -Scene "BROKEN.scex"')
Check 'Open: a scene it can not read says why' ($ob.ok -and $ob.readonly)
$bad = Run '-Action Open -Scene "..\fixtures.ini"'
Check 'Open: only scene files in scenes/' (-not $bad.ok)

# ---------------------------------------------------------------- saving
$before = AllSha
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = (Steps 3); addch = @(); delch = @() }
Check 'Save with no changes writes nothing' ($r.ok -and $r.out -match 'nothing to change' -and (Sha 'CHASE.scex') -eq $o.sha)
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 0; set = @(@{ fx = '12'; ix = 15; v = 128 }) }, @{ src = 1 }, @{ src = 2 }) }
$exp = $chase.Replace("<Channel index=`"15`" name=`"dimmer`" value=`"0`"/>`r`n      </Fixture>`r`n    </Step>`r`n    <Step length=`"50`">", "<Channel index=`"15`" name=`"dimmer`" value=`"128`"/>`r`n      </Fixture>`r`n    </Step>`r`n    <Step length=`"50`">")
Check 'One value changed = only that value in the file' ($r.ok -and (Txt 'CHASE.scex') -ceq $exp) $r.err
$b = Bytes 'CHASE.scex'; Check 'The BOM is kept' ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
$after = AllSha; $other = @($before.Keys | Where-Object { $_ -notlike '*CHASE.scex' -and $after[$_] -ne $before[$_] })
Check 'No other file in the show changed' (-not $other.Count) ($other -join ', ')
$stale = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = (Steps 3) }
Check 'A save from an old copy is refused (the file changed since)' (-not $stale.ok -and $stale.err -match 'changed since')
$o = J (Run '-Action Open -Scene "CHASE.scex"'); $cur = Txt 'CHASE.scex'
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 0; len = 75; set = @(@{ fx = '11'; ix = 5; fade = $false }, @{ fx = '11'; ix = 15; fade = $true }) }, @{ src = 1 }, @{ src = 2 }) }
$exp = $cur.Replace('<Step length="50">' + $crlf + '      <Fixture id="11">' + $crlf + '        <Channel index="5" name="color" value="10" fade="1"/>' + $crlf + '        <Channel index="15" name="dimmer" value="255"/>',
                    '<Step length="75">' + $crlf + '      <Fixture id="11">' + $crlf + '        <Channel index="5" name="color" value="10"/>' + $crlf + '        <Channel index="15" name="dimmer" value="255" fade="1"/>')
Check 'Step length, fade on and fade off' ($r.ok -and (Txt 'CHASE.scex') -ceq $exp) $r.err
$o = J (Run '-Action Open -Scene "CHASE.scex"'); $cur = Txt 'CHASE.scex'
$sc = [regex]::Matches($cur, '(?s)\r\n    <Step.*?</Step>'); $head = $cur.Substring(0, $sc[0].Index); $tail = $cur.Substring($sc[2].Index + $sc[2].Length)
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 2 }, @{ src = 0 }, @{ src = 0; set = @(@{ fx = '11'; ix = 15; v = 7 }) }) }
$exp = $head + $sc[2].Value + $sc[0].Value + $sc[0].Value.Replace('value="255" fade="1"', 'value="7" fade="1"') + $tail
Check 'Steps moved, copied and taken out - each step exactly as it was' ($r.ok -and (Txt 'CHASE.scex') -ceq $exp) $r.err
$o = J (Run '-Action Open -Scene "CHASE.scex"'); $cur = Txt 'CHASE.scex'
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 0; set = @(@{ fx = '12'; ix = 15; v = 9; fade = $true }) }, @{ src = 1 }, @{ src = 2 }); addch = @(@{ fx = '12'; ix = 15 }); delch = @(@{ fx = '12'; ix = 5 }) }
$t2 = Txt 'CHASE.scex'
Check 'A channel that is already there is not added twice' ($r.ok -and ([regex]::Matches($t2, 'index="15"')).Count -eq 6 -and ([regex]::Matches($t2, 'index="5"')).Count -eq 3 -and $t2.Contains('<Channel index="15" name="dimmer" value="9" fade="1"/>')) $r.err
$o = J (Run '-Action Open -Scene "CHASE.scex"'); $cur = Txt 'CHASE.scex'
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 0; set = @(@{ fx = '11'; ix = 5; v = 20; fade = $true }) }, @{ src = 1 }, @{ src = 2 }); addch = @(@{ fx = '11'; ix = 5 }) }
$exp = $cur.Replace("      <Fixture id=`"11`">`r`n        <Channel index=`"15`"", "      <Fixture id=`"11`">`r`n        <Channel index=`"5`" name=`"color`" value=`"0`"/>`r`n        <Channel index=`"15`"")
$i0 = $exp.IndexOf('<Channel index="5" name="color" value="0"/>'); $exp = $exp.Remove($i0, 43).Insert($i0, '<Channel index="5" name="color" value="20" fade="1"/>')
Check 'A channel added to every step (its name from the show), set in one step' ($r.ok -and (Txt 'CHASE.scex') -ceq $exp) "$($r.err)"
$o = J (Run '-Action Open -Scene "CHASE.scex"'); $cur = Txt 'CHASE.scex'
$r = Save @{ scene = 'CHASE.scex'; sha = $o.sha; steps = (Steps 3); delch = @(@{ fx = '11'; ix = 5 }) }
$exp = [regex]::Replace($cur, '\r\n        <Channel index="5" name="color" value="\d+"( fade="1")?/>(?=\r\n        <Channel index="15"[^\r]*\r\n      </Fixture>\r\n      <Fixture id="12">)', '')
Check 'A channel taken out of every step (whole lines)' ($r.ok -and (Txt 'CHASE.scex') -ceq $exp) "$($r.err)"

# ODD: everything it doesn't know stays
$o = J (Run '-Action Open -Scene "ODD.scex"')
$r = Save @{ scene = 'ODD.scex'; sha = $o.sha; steps = @(@{ src = 0; set = @(@{ fx = '11'; ix = 5; v = 30; fade = $true }) }, @{ src = 1; len = 40; set = @(@{ fx = '11'; ix = 5; fade = $false }) }, @{ src = 0 }) }
$s0 = "`n    <Step length=`"100`" note=`"a &amp; b`">`n      <Fixture id=`"11`" x=`"1`">`n        <!-- keep this -->`n        <Channel index=`"5`" name=`"color`" value = '20'  curve=`"2`" />`n        <Channel   index=`"15`"   name=`"dimmer`"   value=`"200`"/>`n      </Fixture>`n      <Unknown a=`"b`"><Deep/></Unknown>`n    </Step>"
$s1 = "`n    <Step>`n      <Fixture id=`"11`">`n        <Channel index=`"5`" name=`"color`" value=`"0`" fade=`"0`"/>`n        <Channel index=`"15`" name=`"dimmer`" value=`"0`"/>`n      </Fixture>`n    </Step>"
$i1 = $odd.IndexOf($s0); $i2 = $odd.IndexOf($s1) + $s1.Length
$exp = $odd.Substring(0, $i1) + $s0.Replace("value = '20'  curve=`"2`"", "value = '30'  curve=`"2`" fade=`"1`"") + $s1.Replace('<Step>', '<Step length="40">').Replace(' fade="0"', '') + $s0 + $odd.Substring($i2)
Check 'Tags, attributes, comments and spacing it does not know are kept' ($r.ok -and (Txt 'ODD.scex') -ceq $exp) "$($r.err)"
$b = Bytes 'ODD.scex'; Check 'No BOM added, line endings kept' ($b[0] -eq 0x3C -and -not (Txt 'ODD.scex').Contains("`r"))

# BETWEEN: values yes, moving steps no
$o = J (Run '-Action Open -Scene "BETWEEN.scex"')
$r = Save @{ scene = 'BETWEEN.scex'; sha = $o.sha; steps = @(@{ src = 1 }, @{ src = 0 }) }
Check 'Steps with something unknown between them are not moved' (-not $r.ok -and (Txt 'BETWEEN.scex') -ceq $between)
$r = Save @{ scene = 'BETWEEN.scex'; sha = $o.sha; steps = @(@{ src = 0 }, @{ src = 1; set = @(@{ fx = '11'; ix = 15; v = 99 }) }) }
Check '...but their values can be changed' ($r.ok -and (Txt 'BETWEEN.scex') -ceq $between.Replace('value="8"', 'value="99"'))
$o = J (Run '-Action Open -Scene "SELFSTEP.scex"'); $cur = Txt 'SELFSTEP.scex'
$r = Save @{ scene = 'SELFSTEP.scex'; sha = $o.sha; steps = @(@{ src = 1 }, @{ src = 0; len = 15 }) }
Check 'An empty step (<Step/>) moves too' ($r.ok -and (Txt 'SELFSTEP.scex') -ceq $cur.Replace("`r`n    <Step length=`"10`"/>", '').Replace("    </Step>`r`n  </Steps>", "    </Step>`r`n    <Step length=`"15`"/>`r`n  </Steps>")) "$($r.err)"

# refused, nothing written
$o = J (Run '-Action Open -Scene "CHASE.scex"'); $s0 = Sha 'CHASE.scex'
foreach ($tc in @(
  @{ w = 'no steps left'; c = @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @() } },
  @{ w = 'a value over 255'; c = @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 0; set = @(@{ fx = '11'; ix = 15; v = 300 }) }, @{ src = 1 }, @{ src = 2 }) } },
  @{ w = 'a step that is not there'; c = @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 9 }) } },
  @{ w = 'a head that is not in the scene'; c = @{ scene = 'CHASE.scex'; sha = $o.sha; steps = @(@{ src = 0; set = @(@{ fx = '99'; ix = 15; v = 1 }) }, @{ src = 1 }, @{ src = 2 }) } },
  @{ w = 'a channel with no name anywhere'; c = @{ scene = 'CHASE.scex'; sha = $o.sha; steps = (Steps 3); addch = @(@{ fx = '11'; ix = 18 }) } },
  @{ w = 'a scene it can not read'; c = @{ scene = 'BROKEN.scex'; sha = ''; steps = @(@{ src = 0 }) } })) {
  $r = Save $tc.c
  Check "Refused: $($tc.w)" (-not $r.ok -and (Sha 'CHASE.scex') -eq $s0 -and $r.err -match 'NOTHING was changed')
}

# backups + revert
$bk = J (Run '-Action Backups -Scene "CHASE.scex"')
Check 'Every save kept a backup' (@($bk.backups).Count -eq 6)
$first = @($bk.backups)[-1]
$r = Run "-Action Revert -Scene `"CHASE.scex`" -Backup $($first.id)"
Check 'Revert of an old backup asks first (the scene was saved again since)' ($r.ok -and $r.out -match '"conflict"' -and (Sha 'CHASE.scex') -eq $s0)
$r = Run "-Action Revert -Scene `"CHASE.scex`" -Backup $($first.id) -Force"
Check 'Revert puts the very first version back, byte for byte' ($r.ok -and (Txt 'CHASE.scex') -ceq $chase -and (Bytes 'CHASE.scex')[0] -eq 0xEF) $r.err
$bk = J (Run '-Action Backups -Scene "CHASE.scex"')
$r = Run "-Action Revert -Scene `"CHASE.scex`" -Backup $(@($bk.backups)[0].id)"
Check '...and that can be undone too' ($r.ok -and (Sha 'CHASE.scex') -eq $s0) $r.err
Check 'No temp file left in scenes/' (-not @(Get-ChildItem -LiteralPath "$T/scenes" -Filter '*.sxs-tmp').Count)

# ---------------------------------------------------------------- a real show (read only, on a copy)
if ($Show) {
  $R = Join-Path $tmp 'Real Show'
  New-Item -ItemType Directory -Force $R | Out-Null
  Copy-Item -Recurse -LiteralPath (Join-Path $Show 'scenes') -Destination $R
  foreach ($x in 'fixtures.ini', 'Live', 'fixtures', 'rig_state.json') { $p = Join-Path $Show $x; if (Test-Path -LiteralPath $p) { Copy-Item -Recurse -LiteralPath $p -Destination $R } }
  $c = J (Run '-Action Check' $R)
  "  Real show: $($c.total) scenes, $($c.editable) can be edited"
  foreach ($s in @($c.scenes | Where-Object { -not $_.editable })) { "        read only: $($s.file) - $($s.why)" }
  foreach ($s in @($c.scenes | Where-Object { $_.editable -and -not $_.structural })) { "        steps can't be moved: $($s.file)" }
  Check 'Real show: every scene it can edit reads back byte for byte' (-not @($c.bad).Count) ($c.bad -join ', ')
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
""
if ($fails.Count) { "$($fails.Count) of $n FAILED"; exit 1 }
"All $n passed"
