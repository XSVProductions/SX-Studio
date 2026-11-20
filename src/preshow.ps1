# PRE-SHOW CHECK - one look before the guests arrive. Reads only, changes nothing.
#   Show:    ShowXpress open, DMX output on, Rig Test saved today, Tonight's Rig matches it, movers aimed today
#   Gear:    APC mini plugged in, DMX interface plugged in, VirtualDJ beat link (OS2L) connected
#   Laptop:  on charger, never sleeps on charger, USB power saving off, no Windows restart waiting
#   -Action Check -> one line of JSON: { ok, show, items: [ { group, level (ok|warn|error|info), title, detail, advice } ] }
param(
  [ValidateSet('Check')][string]$Action = 'Check',
  [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$items = New-Object Collections.Generic.List[object]
function Add-Item($group, $level, $title, $detail = '', $advice = '') { $items.Add([pscustomobject]@{ group = $group; level = $level; title = $title; detail = $detail; advice = $advice }) }
function Get-Ago([datetime]$t) {
  $d = ((Get-Date).Date - $t.Date).Days
  if ($d -le 0) { "today at $($t.ToString('h:mm tt'))" } elseif ($d -eq 1) { "yesterday" } else { "$d days ago ($($t.ToString('MMM d')))" }
}
$today = (Get-Date).Date

# ---------------------------------------------------------------- Show
$sxOpen = Test-SxRunning
if ($sxOpen) { Add-Item 'Show' 'ok' 'ShowXpress is open' }
else { Add-Item 'Show' 'warn' 'ShowXpress is not open yet' 'Some checks below use the last saved show.' 'Open ShowXpress and load the Awaaz show.' }

$lv = Get-IniKeys (Read-LiveIni $root) 'live'
if ("$($lv['dmx_on'])" -eq 'no') { Add-Item 'Show' 'error' 'DMX output is switched OFF in Live' 'No light will react to anything.' 'In ShowXpress Live, switch DMX output back on.' }
else { Add-Item 'Show' 'ok' 'DMX output is on in Live' $(if ($sxOpen) { 'As last saved - ShowXpress is open, so a change made since then would not show here.' } else { '' }) }

$rt = "$root/rig_test.json"; $rtHung = $null
if (Test-Path -LiteralPath $rt) {
  $j = [IO.File]::ReadAllText($rt) | ConvertFrom-Json; $t = [datetime]"$($j.saved)"; $rtHung = @($j.hung | ForEach-Object { "$_" })
  if ($t.Date -eq $today) { Add-Item 'Show' 'ok' "Rig Test saved $(Get-Ago $t)" "$($rtHung.Count) movers placed on the trusses." }
  else { Add-Item 'Show' 'warn' "Rig Test last saved $(Get-Ago $t)" 'The 2D view may not match where the heads hang tonight.' 'Press RIG ID on the SETUP page and do the Rig Test tab.' }
} else { Add-Item 'Show' 'warn' 'Rig Test not done yet' '' 'Press RIG ID on the SETUP page and do the Rig Test tab.' }

$rs = "$root/rig_state.json"; $rigHung = $null
if (Test-Path -LiteralPath $rs) { $j = [IO.File]::ReadAllText($rs) | ConvertFrom-Json; if ($j.hung) { $rigHung = @($j.hung | ForEach-Object { "$_" }) } }
if ($rtHung) {
  $m140 = @(Get-ShowMovers $root | Where-Object { $_.Is140 })
  $rig140 = if ($rigHung) { @($m140 | Where-Object { $rigHung -contains $_.Id }) } else { $m140 }
  $diff = @($m140 | Where-Object { ($rtHung -contains $_.Id) -ne ($rig140.Id -contains $_.Id) })
  if ($diff.Count) { Add-Item 'Show' 'warn' "Tonight's Rig doesn't match the Rig Test" "Different: $(($diff | ForEach-Object { '140 #' + $_.Num }) -join ', ')." "Save the Rig Test again with 'Also update Tonight's Rig' ticked, or fix it in the Tonight's Rig tab." }
  else { Add-Item 'Show' 'ok' "Tonight's Rig matches the Rig Test" "$($rig140.Count) of $($m140.Count) 140s hung." }
}

$aim = "$root/df_aim_state.json"
if (Test-Path -LiteralPath $aim) {
  $t = (Get-Item -LiteralPath $aim).LastWriteTime
  if ($t.Date -eq $today) { Add-Item 'Show' 'ok' "Movers aimed $(Get-Ago $t)" }
  else { Add-Item 'Show' 'warn' "Movers last aimed $(Get-Ago $t)" 'Every venue is different - the movements may miss tonight''s dancefloor.' 'Aim DF AIM (ADJUST) at tonight''s floor, then Apply in the Aim Movers tab.' }
} else { Add-Item 'Show' 'warn' 'Movers not aimed yet' '' 'Aim DF AIM (ADJUST) at tonight''s floor, then Apply in the Aim Movers tab.' }

# ---------------------------------------------------------------- Gear + Laptop (Windows only)
if ($onMac) {
  Add-Item 'Gear' 'info' 'Controller, DMX interface and laptop checks only run on Windows'
} else {
  $pnp = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })
  $apc = @($pnp | Where-Object { $_.FriendlyName -match 'APC mini' })
  if ($apc.Count) { Add-Item 'Gear' 'ok' 'APC mini is plugged in' }
  else { Add-Item 'Gear' 'error' 'APC mini not found' 'The pads and speed faders won''t work.' 'Plug in the APC mini (try another USB port), then restart ShowXpress so it picks it up.' }

  $dmx = @($pnp | Where-Object { $_.FriendlyName -match 'DMX|Nicolaudie|Sunlite|Chauvet|ShowXpress|Enttec|USB Serial Converter|FT232' -or $_.Manufacturer -match 'Nicolaudie|Sunlite|Chauvet|FTDI|Enttec' })
  if ($dmx.Count) { Add-Item 'Gear' 'ok' 'DMX interface is plugged in' (($dmx | Select-Object -ExpandProperty FriendlyName -Unique) -join ', ') }
  else { Add-Item 'Gear' 'error' 'No DMX interface found' 'Without it no light gets any signal.' 'Plug in the DMX interface and check the DMX cable to the first light. If it is plugged in and this still shows, tell me what it is called in Device Manager.' }

  $p = @{}; $pf = Join-Path (Split-Path (Split-Path $root)) 'param.ini'
  if (Test-Path -LiteralPath $pf) { foreach ($l in [IO.File]::ReadAllLines($pf)) { if ($l -match '^(OS2L\w+) = (.*)$') { $p[$matches[1]] = $matches[2].Trim() } } }
  $port = if ($p['OS2LPORT']) { [int]$p['OS2LPORT'] } else { 7350 }
  $con = @(Get-NetTCPConnection -LocalPort $port -State Established -ErrorAction SilentlyContinue)
  $vdj = [bool](Get-Process -Name 'virtualdj*' -ErrorAction SilentlyContinue)
  if ("$($p['OS2LENABLE'])" -ne 'yes') { Add-Item 'Gear' 'info' 'VirtualDJ beat link is off in ShowXpress' 'Beat scenes follow the BPM / audio beat instead.' 'To use it: ShowXpress Preferences > Network > Virtual DJ: Enable.' }
  elseif ($con.Count) { Add-Item 'Gear' 'ok' 'VirtualDJ is connected (beat link)' }
  elseif ($vdj) { Add-Item 'Gear' 'warn' 'VirtualDJ is running but not connected to ShowXpress' 'Beat scenes won''t follow the music from VirtualDJ.' 'Restart VirtualDJ after ShowXpress is open, and make sure both are on the same network.' }
  else { Add-Item 'Gear' 'info' 'VirtualDJ is not connected' 'Fine if VirtualDJ runs on the other laptop and isn''t open yet, or you''re using the BPM / audio beat.' 'Open VirtualDJ after ShowXpress - it connects by itself.' }

  Add-Type -AssemblyName System.Windows.Forms
  $ps = [Windows.Forms.SystemInformation]::PowerStatus
  $pct = [int]($ps.BatteryLifePercent * 100)
  if ($ps.PowerLineStatus -eq 'Online') { Add-Item 'Laptop' 'ok' 'On the charger' $(if ($ps.BatteryChargeStatus -notmatch 'NoSystemBattery') { "Battery $pct%." } else { '' }) }
  elseif ($ps.PowerLineStatus -eq 'Offline') { Add-Item 'Laptop' 'error' "Running on battery ($pct%)" 'The laptop could die or slow down mid-show.' 'Plug in the charger.' }

  function Get-AcIndex($sub, $set) {
    $o = & powercfg /q SCHEME_CURRENT $sub $set 2>$null | Out-String
    if ($o -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { [Convert]::ToInt32($matches[1], 16) } else { $null }
  }
  $sleep = Get-AcIndex 'SUB_SLEEP' 'STANDBYIDLE'
  if ($null -ne $sleep) {
    if ($sleep -eq 0) { Add-Item 'Laptop' 'ok' 'Never sleeps on the charger' }
    else { Add-Item 'Laptop' 'warn' "Goes to sleep after $([int]($sleep / 60)) min on the charger" 'If nobody touches it (dinner, speeches) the lights freeze.' 'Settings > System > Power & sleep > "When plugged in, PC goes to sleep after" = Never.' }
  }
  $usb = Get-AcIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
  if ($usb -eq 1) { Add-Item 'Laptop' 'warn' 'USB power saving is on' 'Windows can switch off an idle USB port - the DMX interface or APC can drop out.' 'Control Panel > Power Options > Change plan settings > Change advanced power settings > USB settings > USB selective suspend > Plugged in: Disabled.' }
  elseif ($usb -eq 0) { Add-Item 'Laptop' 'ok' 'USB power saving is off' }

  $rb = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
  if ($rb) { Add-Item 'Laptop' 'warn' 'Windows wants to restart for updates' 'It could restart by itself during the event.' 'Restart the laptop now, before the show.' }
  else { Add-Item 'Laptop' 'ok' 'No Windows restart waiting' }
}

[pscustomobject]@{ ok = $true; show = $root; items = $items.ToArray() } | ConvertTo-Json -Depth 5 -Compress
