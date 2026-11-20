# SPEED FADERS - which master speed fader (MOVEMENTS, COLORS, STROBES, CHASES...) each live button follows.
#
#   -Action Preview                     -> JSON for the ShowXpress Helper window (writes nothing)
#   -Action Apply -ChangesFile <json>   -> [{ sec: "page3_button1", title: "...", fader: 0-based master fader }]
#
#   live.ini key: masterspeedfader = K (0 = first fader). A button without the key follows fader 0.
#   Only live.ini is changed; ShowXpress must be closed.
param(
  [ValidateSet('Preview','Apply')][string]$Action = 'Preview',
  [string]$ChangesFile = '',
  [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$info = Get-LiveInfo $root
$speedFaders = @($info.Faders | Where-Object { $_.type -eq '1' })

if ($Action -eq 'Preview') {
  $btns = @(foreach ($b in @($info.Buttons | Sort-Object Page, @{e={ [int]$_.Keys['line'] }}, @{e={ [int]$_.Keys['column'] }})) {
    $p = Get-ScenePath $root $b.Name; $steps = -1
    if ($p -and $p -like '*.scex') { $steps = ([regex]'<Step\b').Matches([IO.File]::ReadAllText($p)).Count }
    $f = 0; if ("$($b.Keys['masterspeedfader'])" -match '^\d+$') { $f = [int]$b.Keys['masterspeedfader'] }
    [pscustomobject]@{ sec = $b.Sec; page = $b.Page; pageName = $b.PageName; title = $b.Title; scene = $b.Name; fader = $f; hasKey = $b.Keys.ContainsKey('masterspeedfader')
                       steps = $steps; gen = ($b.Name -like '*.gpj'); beat = ("$($b.Keys['speed'])" -eq 'auto_bpm'); missing = (-not $p) }
  })
  [pscustomobject]@{ ok = $true; show = $root; faders = @($info.Faders); buttons = $btns } | ConvertTo-Json -Depth 5 -Compress
  return
}

# ---------------------------------------------------------------- Apply
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }
$changes = Read-ChangesFile $ChangesFile
if (-not $changes.Count) { throw "No changes were sent. NOTHING was changed." }
$bySec = @{}; foreach ($b in $info.Buttons) { $bySec[$b.Sec] = $b }
$ok = @{}; foreach ($f in $info.Faders) { $ok[$f.k] = $f.caption }
$out = @()
foreach ($c in $changes) {
  $b = $bySec["$($c.sec)"]
  if (-not $b -or $b.Title -ne "$($c.title)") { throw "The show changed since this page was loaded ($($c.title)). Press Refresh and try again. NOTHING was changed." }
  $k = [int]$c.fader
  if (-not $ok.ContainsKey($k)) { throw "There is no master fader number $k. NOTHING was changed." }
  # ShowXpress writes the key after name/title/color/speed/bpm_trigger
  Set-IniKey $info.Ini $b.Sec 'masterspeedfader' "$k" @('line', 'column', 'name', 'title', 'imgpath', 'color', 'speed', 'bpm_trigger')
  $out += "  $($b.Title) ($($b.PageName)) -> $($ok[$k])"
}
if (Save-LiveIni $info.Ini) { "  live.ini saved - $($out.Count) button(s)"; $out } else { "  nothing to change." }
