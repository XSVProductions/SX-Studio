# APC MINI - shows which live button each APC mini mk2 pad plays, and moves / swaps / clears pad mappings.
#
#   -Action Preview                     -> JSON for the SX Helper window (writes nothing)
#   -Action Apply -ChangesFile <json>   -> [{ sec: "page3_button1", title: "...", note: 0-63 | -1 (take it off the pads),
#                                             on: 0-127, off: 0-127 (optional: pad colour while playing / idle, mk2 palette) }]
#
#   Pads: bottom row = notes 0-7 ... top row = 56-63 (row 1 = top). A move changes the button's trigger note and its
#   light (midiout) note together, so the pad colours move with it. Only live.ini is changed; ShowXpress must be closed.
param(
  [ValidateSet('Preview','Apply')][string]$Action = 'Preview',
  [string]$ChangesFile = '',
  [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$info = Get-LiveInfo $root

function Get-Int($v, $def = -1) { if ("$v" -match '^-?\d+$') { [int]$v } else { $def } }

if ($Action -eq 'Preview') {
  $pads = @(foreach ($b in $info.Buttons) {
    $k = $b.Keys; if (-not $k.ContainsKey('trigger_midi_note')) { continue }
    if ((Get-Int $k['trigger_midi_device'] 0) -ne 0) { continue }   # on another controller (e.g. the APC40), not the APC mini
    [pscustomobject]@{
      sec = $b.Sec; page = $b.Page; pageName = $b.PageName; title = $b.Title; scene = $b.Name; sceneOk = [bool](Get-ScenePath $root $b.Name)
      note = (Get-Int $k['trigger_midi_note']); type = (Get-Int $k['trigger_midi_type'] 0); channel = (Get-Int $k['trigger_midi_channel'] 1); device = (Get-Int $k['trigger_midi_device'] 0)
      outNote = (Get-Int $k['trigger_midiout_note']); on = (Get-Int $k['trigger_midiout_data']); off = (Get-Int $k['trigger_midiout_data_off'])
      color = (Get-Int $k['color']); key = "$($k['trigger_keyboard'])"
    } })
  $faders = @(foreach ($key in @($info.Live.Keys | Where-Object { $_ -match '^fader(\d+)_midi_note$' } | Sort-Object { [int]($_ -replace '\D', '') })) {
    $n = [int]($key -replace '\D', ''); $mf = $n - 1
    if ((Get-Int $info.Live["fader${n}_midi_device"] 0) -ne 0) { continue }   # a fader on another controller
    [pscustomobject]@{ n = $n; cc = (Get-Int $info.Live[$key]); type = (Get-Int $info.Live["fader${n}_midi_type"]); channel = (Get-Int $info.Live["fader${n}_midi_channel"])
                       caption = $(if ($mf -lt $info.Faders.Count) { $info.Faders[$mf].caption } else { '' }) } })
  [pscustomobject]@{ ok = $true; show = $root; pads = $pads; faders = $faders; buttons = $info.Buttons.Count } | ConvertTo-Json -Depth 5 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
$changes = Read-ChangesFile $ChangesFile
if (-not $changes.Count) { throw "No changes were sent. NOTHING was changed." }
$bySec = @{}; foreach ($b in $info.Buttons) { $bySec[$b.Sec] = $b }
$touched = @{}; $colors = @{}
foreach ($c in $changes) {
  $b = $bySec["$($c.sec)"]
  if (-not $b -or $b.Title -ne "$($c.title)") { throw "The show changed since this page was loaded ($($c.title)). Press Refresh and try again. NOTHING was changed." }
  if (-not $b.Keys.ContainsKey('trigger_midi_note')) { throw "$($b.Title) isn't on a pad. NOTHING was changed." }
  if ((Get-Int $b.Keys['trigger_midi_device'] 0) -ne 0) { throw "$($b.Title) is on another MIDI controller, not the APC mini. NOTHING was changed." }
  $n = [int]$c.note
  if ($n -ne -1 -and ($n -lt 0 -or $n -gt 63)) { throw "Pad note $n is not on the 8x8 grid. NOTHING was changed." }
  if ($n -ne -1 -and (Get-Int $b.Keys['trigger_midi_type'] 0) -ne 0) { throw "$($b.Title) is mapped to a MIDI controller, not a note - it can only be removed. NOTHING was changed." }
  $touched[$b.Sec] = $n
  foreach ($w in 'on', 'off') {
    $v = $c.$w
    if ($null -ne $v -and "$v" -ne '') {
      if ("$v" -notmatch '^\d+$' -or [int]$v -gt 127) { throw "Pad colour $v is not 0-127. NOTHING was changed." }
      if (-not $colors.ContainsKey($b.Sec)) { $colors[$b.Sec] = @{} }; $colors[$b.Sec][$w] = [int]$v
    }
  }
}
# no two buttons may end up on the same pad
$final = @{}
foreach ($b in $info.Buttons) {
  if (-not $b.Keys.ContainsKey('trigger_midi_note')) { continue }
  $n = if ($touched.ContainsKey($b.Sec)) { $touched[$b.Sec] } else { Get-Int $b.Keys['trigger_midi_note'] }
  if ($n -lt 0 -or $n -gt 63 -or (Get-Int $b.Keys['trigger_midi_type'] 0) -ne 0 -or (Get-Int $b.Keys['trigger_midi_device'] 0) -ne 0) { continue }
  if ($final.ContainsKey($n) -and ($touched.ContainsKey($b.Sec) -or $touched.ContainsKey($final[$n].Sec))) {
    throw "Two buttons would be on the same pad ($($final[$n].Title) and $($b.Title)). NOTHING was changed."
  }
  $final[$n] = $b
}
$out = @()
foreach ($sec in $touched.Keys) {
  $b = $bySec[$sec]; $n = $touched[$sec]; $old = Get-Int $b.Keys['trigger_midi_note']
  if ($n -eq -1) {
    $k = Remove-IniKeys $info.Ini $sec '^trigger_midi(out)?_'
    $out += "  removed from the pads: $($b.Title) ($($b.PageName))"
  } elseif ($n -ne $old) {
    Set-IniKey $info.Ini $sec 'trigger_midi_note' "$n"
    if ($b.Keys.ContainsKey('trigger_midiout_note')) { Set-IniKey $info.Ini $sec 'trigger_midiout_note' "$n" }
    $r = 8 - [math]::Floor($n / 8); $col = ($n % 8) + 1
    $out += "  moved: $($b.Title) ($($b.PageName)) -> row $r, column $col  (note $old -> $n)"
  }
  if ($n -ne -1 -and $colors.ContainsKey($sec)) {
    $cl = $colors[$sec]
    if (-not $b.Keys.ContainsKey('trigger_midiout_note')) {
      # pad light not set up yet: APC mini mk2 = device of the trigger, channel 7 (full brightness), note = its pad
      foreach ($kv in @(@('trigger_midiout_device', "$(Get-Int $b.Keys['trigger_midi_device'] 0)"), @('trigger_midiout_channel', '7'), @('trigger_midiout_type', '0'), @('trigger_midiout_note', "$n"))) {
        Set-IniKey $info.Ini $sec $kv[0] $kv[1] @('trigger_midi_note', 'trigger_midiout_device', 'trigger_midiout_channel', 'trigger_midiout_type') }
    }
    $msg = @()
    if ($cl.ContainsKey('on'))  { Set-IniKey $info.Ini $sec 'trigger_midiout_data' "$($cl.on)" @('trigger_midiout_note'); $msg += "playing $($cl.on)" }
    if ($cl.ContainsKey('off')) { Set-IniKey $info.Ini $sec 'trigger_midiout_data_off' "$($cl.off)" @('trigger_midiout_data', 'trigger_midiout_note'); $msg += "idle $($cl.off)" }
    $out += "  pad colour: $($b.Title) ($($b.PageName)) -> $($msg -join ', ')"
  }
}
if (Save-LiveIni $info.Ini) { "  live.ini saved - $($out.Count) pad change(s)"; $out } else { "  nothing to change." }
