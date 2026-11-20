# SYNC TO GOOGLE DRIVE - copies the show into Google Drive > AWAAZ > Lighting > <show folder name>.
#   Uses the Google Drive app's own folder on this computer (Windows: the Google Drive drive letter, "My Drive";
#   Mac: ~/Library/CloudStorage/GoogleDrive-*/My Drive), so Google Drive uploads it by itself.
#   One way, never deletes: new and changed files are copied; a file that is NEWER on Google Drive is left alone.
#   -Action Preview -> JSON { ok, show, target, found, last }      -Action Sync -> copies, prints a summary
param(
  [ValidateSet('Preview','Sync')][string]$Action = 'Preview',
  [string]$TestRoot = '',
  [string]$Target = ''   # testing only: copy here instead of Google Drive
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$showName = Split-Path $root -Leaf
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
# a test show never goes to the real Google Drive: it goes next to the test LightShows folder
$dest = if ($Target) { $Target } elseif ($TestRoot) { Join-Path (Split-Path (Split-Path $root)) "GoogleDriveTest/$showName" } elseif ($my) { Join-Path $my "AWAAZ/Lighting/$showName" } else { '' }
$lastF = Join-Path $root 'gdrive_sync.json'
$last = if (Test-Path -LiteralPath $lastF) { "$(([IO.File]::ReadAllText($lastF) | ConvertFrom-Json).synced)" } else { '' }

if ($Action -eq 'Preview') {
  [pscustomobject]@{ ok = $true; show = $root; found = [bool]$dest; target = $dest; last = $last } | ConvertTo-Json -Compress
  return
}
if (-not $dest) { throw "Google Drive not found on this computer - is the Google Drive app installed and signed in? NOTHING was copied." }
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was copied. Close ShowXpress (save first) so the newest show is copied, then try again." }
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

$copied = 0; $newer = 0; $same = 0; $failed = @()
$src = (Get-Item -LiteralPath $root).FullName
foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File -Force) {
  $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
  if ($rel -eq 'gdrive_sync.json') { continue }
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
