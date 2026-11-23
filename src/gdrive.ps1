# SYNC TO / IMPORT FROM GOOGLE DRIVE - the show's copy in Google Drive > AWAAZ > Lighting > <show folder name>.
#   Uses the Google Drive app's own folder on this computer (Windows: the Google Drive drive letter, "My Drive";
#   Mac: ~/Library/CloudStorage/GoogleDrive-*/My Drive), so Google Drive uploads/downloads it by itself.
#   -Action Preview -> JSON { ok, show, here, target, found, last, srcFound, srcTime, lastImport }
#   -Action Sync    -> one way, never deletes: new and changed files are copied; a file that is NEWER on Google Drive
#                      is left alone. Prints a summary.
#   -Action Import  -> (user 2026-11-22) the show on Google Drive REPLACES the show on this computer (files that aren't
#                      on Google Drive go too). The whole Drive copy is read into a temp folder first - if any file can't
#                      be read, NOTHING is changed. The old show is kept as a backup (Windows %APPDATA%\ShowXpress
#                      Helper\backups, Mac ~/AwaazTools/backups, newest 3). This computer's own ShowXpress window
#                      layout (thelightingcontroller.ini), error log and sync notes stay.
param(
  [ValidateSet('Preview','Sync','Import')][string]$Action = 'Preview',
  [string]$TestRoot = '',
  [string]$Target = ''   # testing only: copy here instead of Google Drive
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

function Find-MyDrive {
  if ($onMac) {
    $c = @(Get-ChildItem -LiteralPath (Join-Path $HOME 'Library/CloudStorage') -Directory -Filter 'GoogleDrive-*' -ErrorAction SilentlyContinue)
    foreach ($d in $c) { $p = Join-Path $d.FullName 'My Drive'; if (Test-Path -LiteralPath $p) { return $p } }
    return $null
  }
  foreach ($d in Get-PSDrive -PSProvider FileSystem) {
    $p = Join-Path $d.Root 'My Drive'
    if (($d.Description -match 'Google' -or $d.Name -eq 'G') -and (Test-Path -LiteralPath $p)) { return $p }
  }
  foreach ($p in (Join-Path $HOME 'Google Drive/My Drive'), (Join-Path $HOME 'My Drive')) { if (Test-Path -LiteralPath $p) { return $p } }
  $null
}
$my = if ($Target -or $TestRoot) { $null } else { Find-MyDrive }
$root = if ($TestRoot) { $TestRoot } else {
  try { Find-Show } catch {
    # no show on this computer yet (new Mac): the show on Google Drive goes into the normal ShowXpress folder
    $lib = if ($my) { Join-Path $my 'AWAAZ/Lighting' } else { '' }
    $cand = @(if ($lib -and (Test-Path -LiteralPath $lib)) { Get-ChildItem -LiteralPath $lib -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Live/live.ini') } })
    $pick = @(@($cand | Where-Object { $_.Name -eq 'Awaaz Lightshow' }) + @(if ($cand.Count -eq 1) { $cand[0] })) | Select-Object -First 1
    if (-not $pick) { throw }
    Join-Path $HOME "TheLightingController/LightShows/$($pick.Name)"
  }
}
$showName = Split-Path $root -Leaf
# a test show never goes to the real Google Drive: it goes next to the test LightShows folder
$dest = if ($Target) { $Target } elseif ($TestRoot) { Join-Path (Split-Path (Split-Path $root)) "GoogleDriveTest/$showName" } elseif ($my) { Join-Path $my "AWAAZ/Lighting/$showName" } else { '' }
$lastF = Join-Path $root 'gdrive_sync.json'
$last = if (Test-Path -LiteralPath $lastF) { "$(([IO.File]::ReadAllText($lastF) | ConvertFrom-Json).synced)" } else { '' }
$impF = Join-Path $root 'gdrive_import.json'
$keepLocal = @('gdrive_sync.json', 'gdrive_import.json', 'thelightingcontroller.ini', 'TheLightingController_Err.log')
$junk = '(^|[\\/])(desktop\.ini|\.DS_Store|Icon\r|~\$[^\\/]*|\._[^\\/]*|[^\\/]*\.tmp)$'
$srcLive = if ($dest) { Join-Path $dest 'Live/live.ini' } else { '' }

if ($Action -eq 'Preview') {
  $sf = [bool]($srcLive -and (Test-Path -LiteralPath $srcLive))
  [pscustomobject]@{ ok = $true; show = $root; here = (Test-Path -LiteralPath (Join-Path $root 'Live/live.ini')); found = [bool]$dest; target = $dest; last = $last
    srcFound = $sf; srcTime = $(if ($sf) { (Get-Item -LiteralPath $srcLive).LastWriteTime.ToString('s') } else { '' })
    lastImport = $(if (Test-Path -LiteralPath $impF) { "$(([IO.File]::ReadAllText($impF) | ConvertFrom-Json).imported)" } else { '' }) } | ConvertTo-Json -Compress
  return
}
if (-not $dest) { throw "Google Drive not found on this computer - is the Google Drive app installed and signed in? NOTHING was $(if ($Action -eq 'Import') { 'changed' } else { 'copied' })." }

if ($Action -eq 'Import') {
  if (-not (Test-Path -LiteralPath $srcLive)) { throw "There's no show on Google Drive at $dest - sync it from the other computer first. NOTHING was changed." }
  if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress first (it writes its old show back when it closes), then import." }
  $bk = if ($TestRoot) { Join-Path (Split-Path (Split-Path $root)) 'HelperBackups' } elseif ($onMac) { Join-Path $HOME 'AwaazTools/backups' } else { Join-Path $env:APPDATA 'ShowXpress Helper/backups' }
  if (-not (Test-Path -LiteralPath $bk)) { New-Item -ItemType Directory -Path $bk -Force | Out-Null }
  # 1) read everything from Google Drive into a temp folder next to the backups (same disk as the show)
  $stage = Join-Path $bk '_importing'
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  $srcFull = (Get-Item -LiteralPath $dest).FullName; $n = 0; $failed = @()
  foreach ($f in Get-ChildItem -LiteralPath $srcFull -Recurse -File -Force) {
    $rel = $f.FullName.Substring($srcFull.Length).TrimStart('\', '/')
    if ($rel -match $junk -or $keepLocal -contains $rel) { continue }
    try {
      $t = Join-Path $stage $rel; $td = Split-Path $t -Parent
      if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
      Copy-Item -LiteralPath $f.FullName -Destination $t -Force
      (Get-Item -LiteralPath $t -Force).LastWriteTimeUtc = $f.LastWriteTimeUtc; $n++
    } catch { $failed += $rel }
  }
  if ($failed.Count -or -not (Test-Path -LiteralPath (Join-Path $stage 'Live/live.ini'))) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    throw "Couldn't read $($failed.Count) file(s) from Google Drive ($(($failed | Select-Object -First 3) -join ', ')) - is this computer online and has Google Drive finished syncing? NOTHING was changed."
  }
  # 2) this computer's own files go along into the new copy (window layout only from Drive if this computer has none)
  $had = Test-Path -LiteralPath $root
  if ($had) { foreach ($k in $keepLocal) { $lf = Join-Path $root $k; if (Test-Path -LiteralPath $lf) { Copy-Item -LiteralPath $lf -Destination (Join-Path $stage $k) -Force } } }
  $dIni = Join-Path $srcFull 'thelightingcontroller.ini'
  if (-not (Test-Path -LiteralPath (Join-Path $stage 'thelightingcontroller.ini')) -and (Test-Path -LiteralPath $dIni)) { Copy-Item -LiteralPath $dIni -Destination (Join-Path $stage 'thelightingcontroller.ini') }
  # 3) swap: old show -> backup, new copy -> show folder (the old one is put back if the swap fails)
  $bName = ''
  if ($had) {
    $bName = "$showName before import $((Get-Date).ToString('yyyy-MM-dd HHmmss'))"
    try { Move-Item -LiteralPath $root -Destination (Join-Path $bk $bName) }
    catch { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue; throw "The show folder is in use (is a file in it open?) - NOTHING was changed. $($_.Exception.Message)" }
  } else { $pd = Split-Path $root -Parent; if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null } }
  try { Move-Item -LiteralPath $stage -Destination $root }
  catch { if ($had) { Move-Item -LiteralPath (Join-Path $bk $bName) -Destination $root }; throw "Couldn't put the new show in place - the old show was put back, NOTHING was changed. $($_.Exception.Message)" }
  [IO.File]::WriteAllText($impF, (@{ imported = (Get-Date).ToString('s'); from = $dest; backup = $bName } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  # keep the newest 3 backups
  @(Get-ChildItem -LiteralPath $bk -Directory | Where-Object { $_.Name -like "$showName before import *" } | Sort-Object Name -Descending) | Select-Object -Skip 3 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  "  Google Drive folder: $dest"
  "  CHANGED  show replaced with the Google Drive copy ($n files) in $root"
  if ($bName) { "  old show kept as a backup: $(Join-Path $bk $bName)" }
  return
}

if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was copied. Close ShowXpress (save first) so the newest show is copied, then try again." }
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

$copied = 0; $newer = 0; $same = 0; $failed = @()
$src = (Get-Item -LiteralPath $root).FullName
foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File -Force) {
  $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
  if ($rel -eq 'gdrive_sync.json' -or $rel -eq 'gdrive_import.json') { continue }
  $t = Join-Path $dest $rel
  if (Test-Path -LiteralPath $t) {
    $ti = Get-Item -LiteralPath $t -Force
    if ($ti.Length -eq $f.Length -and [Math]::Abs(($ti.LastWriteTimeUtc - $f.LastWriteTimeUtc).TotalSeconds) -le 2) { $same++; continue }
    if ($ti.LastWriteTimeUtc -gt $f.LastWriteTimeUtc.AddSeconds(2)) { $newer++; continue }
  }
  try {
    $td = Split-Path $t -Parent; if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $t -Force; $copied++
  } catch { $failed += $rel }
}
[IO.File]::WriteAllText($lastF, (@{ synced = (Get-Date).ToString('s'); target = $dest } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
"  Google Drive folder: $dest"
"  CHANGED  $copied file(s) copied, $same already up to date"
if ($newer) { "  $newer file(s) are newer on Google Drive - left alone" }
if ($failed.Count) { "  WARNING: could not copy $($failed.Count): $(($failed | Select-Object -First 5) -join ', ')" }
