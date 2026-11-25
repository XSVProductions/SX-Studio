# Tests for the one-click looks engine (src/looks.ps1). Runs on Windows PowerShell 5.1 and pwsh 7 (Mac / Linux).
#   pwsh -File tools/test_looks.ps1    -> builds a small test show in a temp folder and checks every rule
# Exit code 0 = all passed.
$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path $PSScriptRoot) 'src/looks.ps1'
$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sxl_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$T = Join-Path $tmp 'Test Show'
$fails = New-Object Collections.Generic.List[string]; $n = 0
function Check([string]$what, [bool]$ok, [string]$more = '') { $script:n++; if ($ok) { "  ok    $what" } else { "  FAIL  $what $more"; $script:fails.Add($what) } }
function Run([string]$a) {
  $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = $psExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$engine`" $a -TestRoot `"$T`""
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
  [pscustomobject]@{ ok = ($p.ExitCode -eq 0 -and -not $e.Result.Trim()); out = $o.Result; err = $e.Result }
}
function J($r) { (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json }
function Make([string]$json) {   # the page's own JSON, as it sends it
  $cf = Join-Path $tmp ('c_' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($cf, $json, (New-Object Text.UTF8Encoding($false))); Run "-Action Make -ChangesFile `"$cf`""
}
function Scene([string]$f) { Join-Path "$T/scenes" $f }

# ---------------------------------------------------------------- the test show
New-Item -ItemType Directory -Force "$T/scenes", "$T/fixtures", "$T/Live" | Out-Null
$mv = 'Mover 140 (19ch)'; $led = 'LED_BAR_CH8'
[IO.File]::WriteAllText("$T/fixtures/$mv.txt", ("ViewType = VIEW_TYPE_HEAD`r`n`r`nChannel = pan`r`n dimmer,0,255 `r`n`r`nChannel = tilt`r`n dimmer,0,255 `r`n`r`n" +
  "Channel = color`r`n white,0,3 red,4,7 yellow,8,11 blue,12,15 index,16,127 right_rotate,128,255 `r`n`r`nChannel = gobo`r`n open,0,7 gobo1,8,15 `r`n`r`nChannel = gobo`r`n open,0,7 `r`n`r`n" +
  "Channel = 8 facet prism`r`n no_function,0,7 8 facet prsim,8,12 right_rotate,13,130 left_rotate,131,247 `r`n`r`nChannel = zoom`r`n zoom,0,255 `r`n`r`n" +
  "Channel = dimmer`r`n`r`nChannel = shutter`r`n closed,0,7 open,8,15 strobe,16,131 open,248,255 `r`n"))
[IO.File]::WriteAllText("$T/fixtures/$led.txt", "Channel = dimmer`r`n`r`nChannel = strobe`r`n no_function,0,5 strobe,6,255 `r`n`r`nChannel = red`r`n`r`nChannel = green`r`n`r`nChannel = blue`r`n`r`nChannel = red`r`n`r`nChannel = green`r`n`r`nChannel = blue`r`n")
[IO.File]::WriteAllText("$T/fixtures.ini", ("`r`n[Fixture1]`r`naddress = 1`r`nname = Mover 140 (19ch)`r`nmodel = $mv`r`nquantity = 1`r`nid = 101`r`n" +
  "[Fixture2]`r`naddress = 20`r`nname = Mover <A&B> `"2`"`r`nmodel = $mv`r`nquantity = 1`r`nid = 102`r`n" +
  "[Fixture3]`r`naddress = 40`r`nname = LED BAR`r`nmodel = $led`r`nquantity = 1`r`nid = 201`r`n" +
  "[Fixture4]`r`naddress = 60`r`nname = PARS`r`nmodel = $led`r`nquantity = 4`r`nid = 301`r`n" +
  "[Fixture5]`r`naddress = 100`r`nname = HAZER`r`nmodel = NO DEFINITION`r`nquantity = 1`r`nid = 401`r`n"), (New-Object Text.UTF8Encoding($true)))
$live = "[live]`r`nmaster_faders = 0`r`n"; [IO.File]::WriteAllText("$T/Live/live.ini", $live)
$old = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n`n<Scene>`n  <Fixtures/>`n  <Steps/>`n</Scene>`n"; [IO.File]::WriteAllText((Scene 'OLD.scex'), $old)

# ---------------------------------------------------------------- Rig
$r = Run '-Action Rig'; $g = J $r
Check 'Rig answers' ($r.ok -and $g.ok) $r.err
Check 'Rig: the single heads, in fixtures.ini order' ((@($g.heads | ForEach-Object { $_.id }) -join ',') -eq '101,102,201')
Check 'Rig: a group of 4 and a head with no definition are left out, by name' ((@($g.skipped) -join ',') -eq 'PARS,HAZER')
$c = $g.models.$mv
Check 'Rig: a repeated channel name gets #2 (as ShowXpress writes it)' ((@($c.chans | ForEach-Object { $_.name }) -join ',') -eq 'pan,tilt,color,gobo,gobo#2,8 facet prism,zoom,dimmer,shutter')
Check 'Rig: colour wheel slots up to the index range' ($c.wheel -eq 2 -and (@($c.slots | ForEach-Object { "$($_.n)=$($_.v)" }) -join ',') -eq 'white=2,red=6,yellow=10,blue=14')
Check 'Rig: shutter open 255 / closed 0, dimmer' ($c.shut.ix -eq 8 -and $c.shut.open -eq 255 -and $c.shut.closed -eq 0 -and $c.dim -eq 7)
Check 'Rig: prism with its spin ranges, both gobos, zoom' (@($c.prisms).Count -eq 1 -and $c.prisms[0].ix -eq 5 -and (@($c.prisms[0].l) -join '-') -eq '131-247' -and (@($c.gobos) -join ',') -eq '3,4' -and $c.zoom -eq 6)
$l = $g.models.$led
Check 'Rig: an LED head - every red / green / blue, the strobe kept at no_function' ($l.wheel -eq -1 -and (@($l.rgb.red) -join ',') -eq '2,5' -and (@($l.kill | ForEach-Object { $_ -join ':' }) -join ',') -eq '1:0' -and $null -eq $l.shut)
Check 'Rig: lists the scenes already in the show' (@($g.scenes) -contains 'OLD.scex')

# ---------------------------------------------------------------- Make
$look = '{"name":"MY LOOK.scex","steps":[{"len":100,"f":{"102":[[2,6],[7,255],[8,255]],"201":[[0,255],[1,0],[2,255,1],[3,0,1],[4,0,1],[5,255,1],[6,0,1],[7,0,1]],"101":[[2,14],[7,255],[8,255]]}},' +
        '{"len":8,"f":{"101":[[2,6],[7,0],[8,0]],"102":[[2,14],[7,0],[8,0]],"201":[[0,0],[1,0],[2,0,1],[3,0,1],[4,255,1],[5,0,1],[6,0,1],[7,255,1]]}}]}'
$r = Make $look
Check 'Make writes a new scene' ($r.ok -and (Test-Path -LiteralPath (Scene 'MY LOOK.scex')) -and (J $r).made -eq 'MY LOOK.scex') $r.err
$b = [IO.File]::ReadAllBytes((Scene 'MY LOOK.scex')); $txt = [Text.Encoding]::UTF8.GetString($b)
Check 'Written like ShowXpress: UTF-8 with no BOM, LF only, the XML header and a blank line' ($b[0] -ne 0xEF -and $txt -notmatch "`r" -and $txt.StartsWith("<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n`n<Scene>`n  <Fixtures>`n"))
[xml]$x = $txt
Check 'Fixtures in fixtures.ini order, names and models as in the show (escaped)' ((@($x.Scene.Fixtures.Fixture | ForEach-Object { $_.id }) -join ',') -eq '101,102,201' -and $x.Scene.Fixtures.Fixture[1].name -eq 'Mover <A&B> "2"' -and $x.Scene.Fixtures.Fixture[2].model -eq $led)
$s = @($x.Scene.Steps.Step)
Check 'Steps and their times' ($s.Count -eq 2 -and $s[0].length -eq '100' -and $s[1].length -eq '8')
$f = @($s[0].Fixture)[2]
Check 'Channels sorted, named from the definition (#2 for the second red)' ((@($f.Channel | ForEach-Object { "$($_.index):$($_.name)" }) -join ',') -eq '0:dimmer,1:strobe,2:red,3:green,4:blue,5:red#2,6:green#2,7:blue#2')
Check 'Values and fade="1" where asked' ($f.Channel[2].value -eq '255' -and $f.Channel[2].fade -eq '1' -and -not $f.Channel[0].HasAttribute('fade') -and @($s[1].Fixture)[0].Channel[0].value -eq '6')
Check 'The text has one line per channel, ShowXpress style' ($txt -match "`n        <Channel index=`"2`" name=`"red`" value=`"255`" fade=`"1`"/>`n")
Check 'live.ini and the other scenes are untouched' ([IO.File]::ReadAllText("$T/Live/live.ini") -eq $live -and [IO.File]::ReadAllText((Scene 'OLD.scex')) -eq $old)

$sha = (Get-FileHash -LiteralPath (Scene 'MY LOOK.scex')).Hash
$r = Make $look
Check 'An existing scene is never overwritten' (-not $r.ok -and $r.err -match 'already in the show' -and (Get-FileHash -LiteralPath (Scene 'MY LOOK.scex')).Hash -eq $sha)
$r = Make ($look -replace 'MY LOOK', 'old')
Check 'Not even with other capitals (OLD.scex)' (-not $r.ok -and [IO.File]::ReadAllText((Scene 'OLD.scex')) -eq $old)
function Bad([string]$what, [string]$json, [string]$rx) {
  $before = @(Get-ChildItem -LiteralPath "$T/scenes").Count; $r = Make $json
  Check "Refused: $what" (-not $r.ok -and $r.err -match $rx -and @(Get-ChildItem -LiteralPath "$T/scenes").Count -eq $before) $r.err
}
Bad 'a head not in the show' '{"name":"B1.scex","steps":[{"len":10,"f":{"999":[[0,1]]}}]}' 'isn.t in the show'
Bad 'a head of a group (no id of its own)' '{"name":"B2.scex","steps":[{"len":10,"f":{"301":[[0,1]]}}]}' 'isn.t in the show'
Bad 'a channel the head does not have' '{"name":"B3.scex","steps":[{"len":10,"f":{"101":[[9,1]]}}]}' 'no channel 9'
Bad 'a value over 255' '{"name":"B4.scex","steps":[{"len":10,"f":{"101":[[0,256]]}}]}' '0-255'
Bad 'a step time of 0' '{"name":"B5.scex","steps":[{"len":0,"f":{"101":[[0,1]]}}]}' 'time'
Bad 'steps with different channels' '{"name":"B6.scex","steps":[{"len":10,"f":{"101":[[0,1]]}},{"len":10,"f":{"101":[[1,1]]}}]}' 'same heads and channels'
Bad 'steps with different heads' '{"name":"B7.scex","steps":[{"len":10,"f":{"101":[[0,1]]}},{"len":10,"f":{"102":[[0,1]]}}]}' 'same heads and channels'
Bad 'a channel twice' '{"name":"B8.scex","steps":[{"len":10,"f":{"101":[[0,1],[0,2]]}}]}' 'twice'
Bad 'no steps' '{"name":"B9.scex","steps":[]}' 'no steps'
Bad 'a name with a folder in it' '{"name":"..\\x.scex","steps":[{"len":10,"f":{"101":[[0,1]]}}]}' 'can.t be a scene name'
Bad 'a name that is not a .scex' '{"name":"x.gpj","steps":[{"len":10,"f":{"101":[[0,1]]}}]}' 'can.t be a scene name'

$r = Make '{"name":"ONE.scex","steps":[{"len":500,"f":{"101":[[3,0]]}}]}'
Check 'A one-channel, one-step look (single-item lists)' ($r.ok -and ([xml][IO.File]::ReadAllText((Scene 'ONE.scex'))).Scene.Steps.Step.Fixture.Channel.name -eq 'gobo') $r.err
Check 'No temp file left in scenes/' (-not @(Get-ChildItem -LiteralPath "$T/scenes" | Where-Object { $_.Name -notmatch '\.scex$' }).Count)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
""
if ($fails.Count) { "$($fails.Count) of $n FAILED"; exit 1 }
"All $n passed"
