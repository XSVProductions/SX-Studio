# SX Studio (was SX Helper, before that AIM MOVERS) - small GUI (Windows PowerShell 5.1 + macOS pwsh 7).
# Runs a private web page on this computer only (localhost + random key) and opens it as an app window
# (Edge/Chrome "app" mode, else the normal browser). Each tab is backed by a script that does the work:
#   Tonight's Rig -> rig.ps1   Aim Movers -> df_aim.ps1       Strobe (the SKIP FLASH heads) -> skip_flash.ps1
#   APC mini -> apc.ps1        Speed Faders -> speed.ps1      Health Check -> health.ps1 (check, fix, revert)
#   Rig Test -> rig_test.ps1   Pre-show Check -> preshow.ps1
#   Auto Show -> sx_remote.ps1 (also presses RIG ID / DF CHECK / ROOM CHECK in a running ShowXpress through its remote)
#   Scene Editor -> scene_edit.ps1 (its live preview uses dmx_out.ps1 too)
#   LIVE AIM (Aim Movers tab) -> dmx_out.ps1 drives the DMX interface while ShowXpress is closed; df_aim.ps1 LiveInfo / LiveSave
# Quits by itself a few minutes after its window is closed.
#   PHONE / iPAD (user 2026-11-22): the same page, phone-sized, on the Wi-Fi - see "PHONE" below.
param([string]$TestRoot = '', [int]$Port = 47321, [int]$PhonePort = 47322, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'df_aim.ps1'
$skipEngine   = Join-Path $here 'skip_flash.ps1'
$rigEngine    = Join-Path $here 'rig.ps1'
$flipEngine   = Join-Path $here 'flip.ps1'
$apcEngine    = Join-Path $here 'apc.ps1'
$speedEngine  = Join-Path $here 'speed.ps1'
$healthEngine = Join-Path $here 'health.ps1'
$rtEngine     = Join-Path $here 'rig_test.ps1'
$preEngine    = Join-Path $here 'preshow.ps1'
$colorEngine  = Join-Path $here 'color.ps1'
$gdEngine     = Join-Path $here 'gdrive.ps1'
$liveEngine   = Join-Path $here 'dmx_out.ps1'
$playerEngine = Join-Path $here 'player.ps1'
$remoteEngine = Join-Path $here 'sx_remote.ps1'
$quitEngine = Join-Path $here 'sx_quit.ps1'
$sceneEngine = Join-Path $here 'scene_edit.ps1'
$moveEngine = Join-Path $here 'move_edit.ps1'
$looksEngine = Join-Path $here 'looks.ps1'
$apc40Engine = Join-Path $here 'apc40.ps1'
$repo   = 'XSVProductions/SX-Studio'   # was showxpress-helper (renamed 2026-11-24; GitHub redirects the old name)
$verF   = Join-Path $here 'version.txt'
$appVer = if (Test-Path -LiteralPath $verF) { ([IO.File]::ReadAllText($verF)).Trim() } else { '0.0.0' }
$updInfo = $null
$onMac  = [bool](Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
$psExe  = (Get-Process -Id $PID).Path
# a copy on other ports (testing) keeps its own info file, so the real Helper never opens the test copy's window
$infoF  = Join-Path ([IO.Path]::GetTempPath()) $(if ($Port -eq 47321) { 'showxpress_helper_gui.json' } else { "showxpress_helper_gui_$Port.json" })
$idleMax = 300   # seconds without the window checking in -> quit

# ---- a window left from an earlier start (user 2026-11-24: after an update the old window stayed open with
#      "this window can be closed"). This server has only just started, so any SX Studio window already open belongs
#      to a server that's gone - it can't work any more. It's closed before the new one opens. Found like the taskbar
#      code: an app window titled exactly "SX Studio" (a normal Edge window has " - Microsoft Edge" after the title)
function Close-OldWindows {
  if ($onMac -or $TestRoot -or $Port -ne 47321) { return }
  try {
    if (-not ('SxOldWin' -as [type])) {
      Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class SxOldWin {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  // asks every app window titled exactly <title> to close, then waits up to <ms> for them to go; returns how many
  public static int Close(string title, int ms) {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() != "Chrome_WidgetWin_1") return true;
      StringBuilder t = new StringBuilder(256); GetWindowText(h, t, 256);
      if (t.ToString() == title) found.Add(h);
      return true; }, IntPtr.Zero);
    foreach (IntPtr h in found) PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
    for (int w = 0; w < ms; w += 50) { if (!found.Exists(h => IsWindow(h))) break; System.Threading.Thread.Sleep(50); }
    return found.Count;
  }
}
'@
    }
    [void][SxOldWin]::Close('SX Studio', 1500)
  } catch {}
}

function Open-AppWindow($url) {
  if ($NoBrowser) { return }
  if ($onMac) {
    foreach ($b in 'Google Chrome', 'Microsoft Edge', 'Brave Browser') {
      if (Test-Path "/Applications/$b.app") { & open -na "$b" --args "--app=$url" '--window-size=1120,880'; return }
    }
    & open $url; return
  }
  $cands = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
             "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { Start-Process $c -ArgumentList "--app=$url", '--window-size=1120,880'; return } }
  Start-Process $url
}

# ---- TASKBAR (user 2026-11-24: pinning the window pinned Microsoft Edge). The window is an Edge --app window, so Windows
#      saw Edge. Give it SX Studio's own identity on the taskbar: AppUserModelID (same as the shortcuts' - set in the .iss),
#      relaunch command = our launcher, name + SX icon, so "Pin to taskbar" pins SX Studio. Found by class + exact title
#      "SX Studio" (a normal Edge window's title has " - Microsoft Edge" after it, so it is never touched).
$sxAppId = 'XSVProductions.SXStudio'
$script:tbNext = [datetime]::MinValue; $script:tbOk = $null
function Step-Taskbar {
  if ($onMac -or $script:tbOk -eq $false -or (Get-Date) -lt $script:tbNext) { return }
  $script:tbNext = (Get-Date).AddSeconds(1)
  if ($null -eq $script:tbOk) {
    try {
      if (-not ('SxTaskbar' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class SxTaskbar {
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore { void GetCount(out uint c); void GetAt(uint i, out PKEY k); void GetValue(ref PKEY k, out PV v); void SetValue(ref PKEY k, ref PV v); void Commit(); }
  [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PKEY { public Guid fmt; public uint pid; }
  [StructLayout(LayoutKind.Explicit, Size = 24)] struct PV { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref PV v);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  static readonly Guid F = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  static readonly HashSet<IntPtr> done = new HashSet<IntPtr>();
  static void Set(IPropertyStore ps, uint pid, string s) {
    PKEY k = new PKEY { fmt = F, pid = pid }; PV v = new PV { vt = 31, p = Marshal.StringToCoTaskMemUni(s) };
    try { ps.SetValue(ref k, ref v); } finally { PropVariantClear(ref v); }
  }
  // tags every visible app window titled exactly <title> that isn't tagged yet; returns how many were tagged now
  public static int Tag(string title, string id, string cmd, string icon, string name) {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h) || done.Contains(h)) return true;
      StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() != "Chrome_WidgetWin_1") return true;
      StringBuilder t = new StringBuilder(256); GetWindowText(h, t, 256);
      if (t.ToString() == title) found.Add(h);
      return true; }, IntPtr.Zero);
    int n = 0; Guid iid = typeof(IPropertyStore).GUID;
    foreach (IntPtr h in found) {
      IPropertyStore ps;
      if (SHGetPropertyStoreForWindow(h, ref iid, out ps) != 0 || ps == null) continue;
      try { Set(ps, 2, cmd); Set(ps, 3, icon); Set(ps, 4, name); Set(ps, 5, id); ps.Commit(); done.Add(h); n++; }
      catch { } finally { Marshal.ReleaseComObject(ps); }
    }
    return n;
  }
}
'@
      }
      $script:tbOk = $true
    } catch { $script:tbOk = $false; return }
  }
  $vbs = Join-Path $here 'showxpress_helper.vbs'
  $ico = @((Join-Path $here 'sx_studio_2.ico'), (Join-Path $here '../assets/aim_movers.ico')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $ico) { return }
  $cmd = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + $vbs + '"'
  try { [void][SxTaskbar]::Tag('SX Studio', $sxAppId, $cmd, ([IO.Path]::GetFullPath($ico) + ',0'), 'SX Studio') } catch {}
}

# ---- one copy only: if it's already running, just bring up its window
#      (an older version still running - e.g. right after an update - is stopped and replaced)
$token = [guid]::NewGuid().ToString('N')
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
try { $l.Start() }
catch {
  $i = $null
  if (Test-Path $infoF) { try { $i = Get-Content $infoF -Raw | ConvertFrom-Json } catch {} }
  $old = $null
  if ($i -and $i.pid -and "$($i.ver)" -ne $appVer) { $old = Get-Process -Id $i.pid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(pwsh|powershell)$' } }
  $up = $false
  if ($old) {
    $old | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($n = 0; $n -lt 20 -and -not $up; $n++) {
      Start-Sleep -Milliseconds 250
      $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$Port/")
      try { $l.Start(); $up = $true } catch {}
    }
  }
  if (-not $up) {
    if ($i) { Open-AppWindow $i.url; return }
    throw "Port $Port is busy and no running SX Studio was found."
  }
}
$url = "http://localhost:$Port/?t=$token"
[IO.File]::WriteAllText($infoF, (@{ url = $url; pid = $PID; ver = $appVer } | ConvertTo-Json))

function Test-SxOpen {
  if ($TestRoot) { return (Test-Path -LiteralPath (Join-Path $TestRoot '_sx_open')) }   # testing: marker file = "ShowXpress open"
  [bool]@(Get-SxProcess).Count
}
# ShowXpress itself = TheLightingController (Windows), TheLightingController.app (Mac; pwsh on Mac cuts process names
# to 16 letters, "TheLightingContr"). NOT our own Mac app "SXHelper" - matching it made the Helper think
# ShowXpress was always open on the Mac (user 2026-11-22).
function Get-SxProcess {
  if ($onMac) {
    # only ShowXpress's own main program counts (user 2026-11-22: a leftover part of it made the Helper say "open"
    # after ShowXpress had closed, so Launch did nothing): ps gives the full program path; finished (zombie) ones are skipped
    return @(& ps -axo 'pid=,stat=,comm=' 2>$null | ForEach-Object {
      if ($_ -match '^\s*(\d+)\s+(\S+)\s+(.+)$') {
        $id = [int]$Matches[1]; $stat = $Matches[2]; $exe = $Matches[3].Trim()
        if ($stat -notmatch '^Z' -and $exe -match '\.app/Contents/MacOS/(TheLightingController|ShowXpress)[^/]*$' -and $exe -notmatch 'Helper|sxh') { Get-Process -Id $id -ErrorAction SilentlyContinue }
      } })
  }
  @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(TheLightingContr|ShowXpress)' -and $_.ProcessName -notmatch 'Helper|sxh|setup|unins|updat' })
}
function Get-SxDllArg {
  # the folder with ShowXpress's interface driver, for dmx_out.ps1 / player.ps1 (2026-11-24: a 32-bit SX Studio, started
  # by the installer's "Open SX Studio now", looked in Program Files (x86) - its own %ProgramFiles%)
  if ($onMac -or $TestRoot) { return '' }
  $x = Get-SxExe; if (-not $x) { return '' }
  " -DllDir `"$(Split-Path $x)`""
}
function Get-SxExe {
  foreach ($p in "$env:ProgramW6432\ShowXpress\TheLightingController.exe", "$env:ProgramFiles\ShowXpress\TheLightingController.exe", "${env:ProgramFiles(x86)}\ShowXpress\TheLightingController.exe") { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  $null
}
function Get-Update {
  # newest release on GitHub, asked once per run (generic User-Agent - nothing about this computer is sent)
  if ($script:updInfo) { return $script:updInfo }
  try {
    if (-not $onMac) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'SX-Studio'; Accept = 'application/vnd.github+json' } -TimeoutSec 10 -UseBasicParsing
    $lat = "$($rel.tag_name)".TrimStart('v')
    $as = @($rel.assets | Where-Object { $_.name -match $(if ($onMac) { '\.pkg$' } else { '\.exe$' }) }) | Select-Object -First 1
    $newer = $false; try { $newer = [version]$lat -gt [version]$appVer } catch {}
    $script:updInfo = @{ ok = $true; mac = $onMac; current = $appVer; latest = $lat; newer = ($newer -and [bool]$as); asset = "$($as.browser_download_url)"; name = "$($as.name)" }
  } catch { return @{ ok = $false; mac = $onMac; current = $appVer; error = 'Could not reach GitHub.' } }
  $script:updInfo
}
function Update-SkipFlash($ids) {
  # SKIP FLASH follows the hung heads too (it needs 2 or more)
  $ids = @($ids | Where-Object { "$_" -match '^\d+$' })
  if ($ids.Count -lt 2) { return "`n  SKIP FLASH not changed (it needs at least 2 heads)" }
  $r = Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $skipEngine
  if (-not $r.ok) { return "`n  SKIP FLASH NOT updated: $($r.error)" }
  if ($r.out -match 'nothing to change') { "`n  SKIP FLASH already flashes these $($ids.Count) heads" } else { "`n  SKIP FLASH now flashes $($ids.Count) heads" }
}
function Send-Png($ctx, [string]$p) {
  $ib = [IO.File]::ReadAllBytes($p); $ctx.Response.ContentType = 'image/png'; $ctx.Response.Headers.Add('Cache-Control', 'no-store')
  $ctx.Response.ContentLength64 = $ib.Length; $ctx.Response.OutputStream.Write($ib, 0, $ib.Length); $ctx.Response.Close()
}

function Invoke-Engine([string]$engineArgs, [string]$script = $engine) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" $engineArgs"
  if ($TestRoot) { $a += " -TestRoot `"$TestRoot`"" }
  $psi.Arguments = $a
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; return @{ ok = $false; out = ''; error = 'Timed out.' } }
  $esc = [string][char]27 + '\[[0-9;]*m'; $out = $o.Result -replace $esc, ''; $err = $e.Result -replace $esc, ''
  $msg = ''
  if ($p.ExitCode -ne 0 -or $err.Trim()) {
    $el = @($err -split "`r?`n")
    $tl = -1; for ($i = 0; $i -lt $el.Count; $i++) { if ($el[$i] -match '^\s*\|\s*~+\s*$') { $tl = $i } }
    if ($tl -ge 0) {
      # PowerShell 7 (Mac) "concise" errors:  Line | ... / | ~~~~ / | the message (may wrap over several | lines)
      $msg = (@($el[($tl + 1)..($el.Count - 1)] | Where-Object { $_ -match '^\s*\|' } | ForEach-Object { ($_ -replace '^\s*\|\s?', '').Trim() }) -join ' ').Trim()
    } else {
      # Windows PowerShell 5.1:  C:\...\df_aim.ps1 : the message  /  At line... / + CategoryInfo ...
      $msg = (($el | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(At |\+ |\+\s|CategoryInfo|FullyQualifiedErrorId|~)' } | Select-Object -First 1))
      $msg = ("$msg" -replace '^.*?\.ps1\s*:\s*', '' -replace '^\w*Exception:\s*', '').Trim()
    }
    if (-not $msg -or $msg -match '^\d+$') { $msg = "Something went wrong (code $($p.ExitCode)) - see Full details." ; $out = "$out`n$err" }
  }
  @{ ok = (-not $msg); out = $out; error = $msg }
}

function Send-Text($ctx, [int]$code, [string]$type, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text); $r = $ctx.Response
  $r.StatusCode = $code; $r.ContentType = $type; $r.Headers.Add('Cache-Control', 'no-store'); $r.ContentLength64 = $b.Length
  $r.OutputStream.Write($b, 0, $b.Length); $r.Close()
}
# PAIRED PHONES STAY PAIRED (user 2026-11-22): the key is kept in 3 places on the phone - localStorage, a 10-year
# HttpOnly cookie set here, and the page address (/?k=...), so a Home Screen icon (own storage on iOS) carries it too.
# Only "Unpair all phones" (new key) makes a phone pair again.
function Set-PhoneCookie($ctx) { $ctx.Response.AppendHeader('Set-Cookie', "sxh_k=$($script:ph.key); Max-Age=315360000; Path=/; HttpOnly; SameSite=Lax") }
function Get-PhoneCookieKey($req) { $c = $req.Cookies['sxh_k']; if ($c -and $script:ph.key -and $c.Value -ceq $script:ph.key) { $c.Value } else { '' } }
function Send-Json($ctx, $obj) { Send-Text $ctx 200 'application/json; charset=utf-8' ($obj | ConvertTo-Json -Depth 10 -Compress) }
function Send-EngineJson($ctx, $r) {
  # engine printed one line of JSON (Preview / Check) -> pass it straight on
  if ($r.ok) {
    $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if ($j) { Send-Text $ctx 200 'application/json; charset=utf-8' $j } else { Send-Json $ctx @{ ok = $false; error = 'No answer from the helper script.' } }
  } else { Send-Json $ctx @{ ok = $false; error = $r.error } }
}
function Invoke-WithChanges([string]$script, $items) {
  # list of changes -> temp JSON file -> engine -Action Apply -ChangesFile (no quoting trouble on the command line)
  $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($cf, (ConvertTo-Json -InputObject @($items) -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
  try { Invoke-Engine "-Action Apply -ChangesFile `"$cf`"" $script } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
}

# Mac: TheLightingController.app (ShowXpress) - in Applications, or in a ShowXpress folder there (the download's layout,
# with the interface driver efk_hardware.dylib next to the app)
function Find-SxMacApp {
  $c = @()
  foreach ($r in '/Applications', (Join-Path $HOME 'Applications')) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $c += @(Get-ChildItem -LiteralPath $r -Directory -Filter '*.app' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' })
    foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' -and $_.Name -notlike '*.app' })) {
      $c += @(Get-ChildItem -LiteralPath $d.FullName -Directory -Filter '*.app' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ShowXpress|LightingController' })
    }
  }
  if (-not $c.Count) {
    $c += @(& mdfind "kMDItemFSName == 'TheLightingController.app'" 2>$null | Where-Object { $_ -and $_ -notmatch '^/Volumes/' } | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
  }
  @($c | Sort-Object { -not (Test-Path -LiteralPath (Join-Path (Split-Path $_.FullName) 'efk_hardware.dylib')) }) | Select-Object -First 1
}
function Start-Sx {
  if ($TestRoot) { [IO.File]::WriteAllText((Join-Path $TestRoot '_sx_open'), 'test'); return @{ ok = $true; out = '  (test) ShowXpress would open now'; error = '' } }
  if (Test-SxOpen) { return @{ ok = $true; already = $true; out = '  ShowXpress is already open'; error = '' } }
  if ($onMac) {
    $a = Find-SxMacApp
    if (-not $a) { return @{ ok = $false; error = 'ShowXpress was not found in Applications.'; out = '' } }
    & open $a.FullName
  } else {
    $x = Get-SxExe
    if (-not $x) { return @{ ok = $false; error = 'ShowXpress was not found in Program Files\ShowXpress.'; out = '' } }
    Start-Process -FilePath $x -WorkingDirectory (Split-Path $x)
  }
  @{ ok = $true; out = '  ShowXpress is starting'; error = '' }
}

# ---- LIVE AIM (user 2026-11-21): the Helper sends DMX itself (dmx_out.ps1 child process) so the real heads follow the
# mouse. Only one program can use the interface, so ShowXpress must be closed. The child stops by itself (lights out)
# if the Helper stops talking to it for 30 s.
$script:liveP = $null; $script:liveHold = [datetime]::MinValue
function Test-Live { [bool]($script:liveP -and -not $script:liveP.HasExited) }
function Stop-Live {
  $p = $script:liveP; $script:liveP = $null
  if (-not $p) { return }
  try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('q'); if (-not $p.WaitForExit(4000)) { $p.Kill() } } } catch { try { $p.Kill() } catch {} }
}
function Start-Live {
  Stop-Live
  $exe = $psExe; $ea = "-NoProfile -ExecutionPolicy Bypass -File `"$liveEngine`"$(Get-SxDllArg)"
  if ($TestRoot) { $ea += " -Fake -FakeLog `"$(Join-Path $TestRoot '_dmx_frame.txt')`"" }
  elseif ($onMac) {
    # Mac: a small tool inside the app (Contents/MacOS/sxh_dmx) drives the interface through ShowXpress's own driver
    $a = Find-SxMacApp
    if (-not $a) { return @{ ok = $false; error = 'ShowXpress was not found in Applications, so its interface driver was not found either.'; out = '' } }
    $exe = Join-Path (Split-Path $here) 'MacOS/sxh_dmx'
    if (-not (Test-Path -LiteralPath $exe)) { return @{ ok = $false; error = 'The live aim part of SX Studio is missing - install SX Studio again.'; out = '' } }
    $ea = "--dir `"$(Split-Path $a.FullName)`""
  }
  $r = Open-DmxChild $exe $ea
  if ($r.ok) { $script:liveP = $r.p }
  $r.Remove('p'); $r
}
function Open-DmxChild([string]$exe, [string]$ea) {
  # start a DMX child (dmx_out.ps1 / player.ps1 / sxh_dmx) -> @{ ok; p = the process; iface } or @{ ok = $false; error }
  $why = ''
  foreach ($try in 1..3) {   # right after ShowXpress closes the interface can take a moment to be free
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $ea; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.AutoFlush = $true
    $t = $p.StandardOutput.ReadLineAsync()
    if (-not $t.Wait(20000)) { try { $p.Kill() } catch {}; $why = 'The DMX interface did not answer.'; continue }
    $line = "$($t.Result)"
    if ($line -like 'OK *') { return @{ ok = $true; p = $p; iface = $line.Substring(3); out = ''; error = '' } }
    try { if (-not $p.WaitForExit(3000)) { $p.Kill() } } catch {}
    if ($line -eq 'ERR none') { $why = 'The DMX interface (D512S) was not found. Check its USB cable - unplug it, plug it back in, wait a few seconds - and try again. ShowXpress must stay closed.' }
    elseif ($line -like 'ERR *') { $why = $line.Substring(4); break }
    else { $why = "The DMX output didn't start: $(($p.StandardError.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1))"; break }
    Start-Sleep -Milliseconds 1500
  }
  @{ ok = $false; error = $why; out = '' }
}

# ---- SX PLAYER (Lab tab, stages 1+2, user 2026-11-23): the Helper plays the show's scenes + movements itself (player.ps1 child
# process). Same rule as live aim: ShowXpress closed, one program on the interface at a time. The Helper itself sends
# the keep-alive once a second (not the window), so the lights keep playing when the window is in the background; if
# the Helper quits, the player puts the lights out by itself.
$script:playP = $null; $script:labMap = @{}
$script:labStat = Join-Path ([IO.Path]::GetTempPath()) "sxh_player_$PID.json"
function Test-Player { [bool]($script:playP -and -not $script:playP.HasExited) }
function Stop-Player {
  $p = $script:playP; $script:playP = $null
  if ($p) { try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('q'); if (-not $p.WaitForExit(4000)) { $p.Kill() } } } catch { try { $p.Kill() } catch {} } }
  Remove-Item -LiteralPath $script:labStat -ErrorAction SilentlyContinue
}
function Start-Player([string]$root) {
  Stop-Player
  if ($onMac) { return @{ ok = $false; error = 'The SX Player only runs on Windows for now - the Mac part comes in a later stage.'; out = '' } }
  $ea = "-NoProfile -ExecutionPolicy Bypass -File `"$playerEngine`" -Show `"$root`" -StatusFile `"$($script:labStat)`" -Pipe sxh_player_$PID$(Get-SxDllArg)"
  if ($TestRoot) { $ea += " -Fake -FakeLog `"$(Join-Path $TestRoot '_dmx_frame.txt')`"" }
  $r = Open-DmxChild $psExe $ea
  if ($r.ok) {
    $script:playP = $r.p; $script:playRoot = $root; $script:playSnap = $null
    try { $r.p.StandardInput.WriteLine('k') } catch {}   # Windows PowerShell swallows the first line a child gets - make it this one
    $script:labXSent = @{}; Sync-PlayerExtras   # the buttons on the player's own pages
  }
  $r.Remove('p'); $r
}
# ---- stage 5 (gig-ready): watchdog, hand-over to ShowXpress, events for the Lab
$script:playRoot = ''; $script:playSnap = $null; $script:playTries = @(); $script:watchT = [datetime]::MinValue
$script:playEvent = $null; $script:playEvN = 0; $script:carry = $null
function Set-PlayEvent([string]$kind, [string]$text) { $script:playEvN++; $script:playEvent = @{ n = $script:playEvN; kind = $kind; text = $text; at = (Get-Date).ToString('o') } }
function Invoke-Handoff([bool]$launch, [string]$why) {
  # stop the player and let ShowXpress carry on with what was playing (the Auto Show goes back to ShowXpress by itself)
  $titles = @(); $st = Get-PlayerStatus
  if ($st) { foreach ($o in @($st.on)) { $b = $script:labMap["$($o.slot)"]
    # a copy on one of the player's own pages: ShowXpress plays the show's button with the same title, if there is one
    if (-not $b) { $x = $script:labX["$($o.slot)"]; if ($x -and @($script:labMap.Values | Where-Object { "$($_.title)" -eq "$($x.title)" }).Count) { $b = $x } }
    if ($b -and "$($b.title)" -match $titleRx -and $titles -notcontains "$($b.title)") { $titles += "$($b.title)" } } }
  $wasAuto = (Test-Auto) -and $script:autoPl
  Stop-Player
  if ($wasAuto) { $as = Get-AutoStatus; [void](Start-Auto "$(if ($as) { $as.lookId })") }
  elseif ($titles.Count) { Set-PendingPress $titles 'what the SX Player was playing' }
  $sx = if ($launch) { Start-Sx } else { @{ ok = $true; out = ''; error = '' } }
  Set-PlayEvent 'handoff' $why
  @{ ok = [bool]$sx.ok; error = "$($sx.error)"; out = "$($sx.out)"; titles = $titles; auto = [bool]$wasAuto; test = [bool]$TestRoot }
}
function Step-PlayerWatch {
  if (((Get-Date) - $script:watchT).TotalMilliseconds -lt 1000) { return }
  $script:watchT = Get-Date
  if (Test-Player) {
    # ShowXpress opened while the player plays: both would fight over the interface - hand over to it
    if (Test-SxOpen) { [void](Invoke-Handoff $false 'ShowXpress was opened, so the SX Player stopped and handed over to it.'); return }
    $s = Get-PlayerStatus
    if ($s) {
      $o = $script:playSnap
      if ("$($s.iface)" -eq 'lost' -and (-not $o -or "$($o.iface)" -ne 'lost')) { Set-PlayEvent 'lost' 'The DMX interface was unplugged. Plug it back in - the player carries on by itself.' }
      if ($o -and [int]$s.reconn -gt [int]$o.reconn) { Set-PlayEvent 'back' 'The DMX interface is back - the lights are playing again.' }
      $script:playSnap = $s
    }
    return
  }
  if (-not $script:playP) { return }   # stopped on purpose
  # the player stopped by itself: start it again and put back what was playing
  $script:playP = $null; $snap = $script:playSnap
  $script:playTries = @($script:playTries | Where-Object { ((Get-Date) - $_).TotalSeconds -lt 60 })
  if ($script:playTries.Count -ge 3 -or (Test-SxOpen) -or (Test-Live) -or -not $script:playRoot) {
    Set-PlayEvent 'gone' 'The SX Player stopped and could not be started again. Start it again, or hand over to ShowXpress.'; return
  }
  $script:playTries += Get-Date
  $r = Start-Player $script:playRoot
  if (-not $r.ok) { Set-PlayEvent 'gone' "The SX Player stopped and could not be started again: $($r.error)"; return }
  if ($snap) {
    $fd = @($snap.fd); for ($f = 0; $f -lt [math]::Min(16, $fd.Count); $f++) { [void](Send-Player ('fader ' + $f + ' ' + ([double]$fd[$f]).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture))) }
    if ("$($snap.src)" -ne 'VirtualDJ' -and $snap.bpm) { [void](Send-Player ('bpm ' + ([double]$snap.bpm).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture))) }
    if (-not ((Test-Auto) -and $script:autoPl)) { foreach ($o in @($snap.on)) { if ("$($o.slot)" -match '^page\d+_button\d+$' -or ("$($o.slot)" -match $xbRx -and $script:labX.ContainsKey("$($o.slot)"))) { [void](Send-Player "seton $($o.slot)") } } }
    if ($snap.bo) { [void](Send-Player 'bo 1') }
  }
  Set-PlayEvent 'restart' 'The SX Player stopped by itself and was started again - the lights were dark for a few seconds.'
}
$script:playK = [datetime]::MinValue
function Step-PlayerKeep {
  # keep-alive at most once a second, whether the Helper is idle or busy answering the window
  if (-not $script:playP -or ((Get-Date) - $script:playK).TotalMilliseconds -lt 1000) { return }
  $script:playK = Get-Date; [void](Send-Player 'k')
}
function Send-Player([string]$line) {
  if (-not (Test-Player)) { return $false }
  try { $script:playP.StandardInput.WriteLine($line); $true } catch { $false }
}
# the SX Player's own pages (settings playerLayout.custom): their buttons go to the player with "addb" (only the ones
# that changed, so a playing button isn't restarted when the layout is saved); labX = sec -> button, for press / on / off
$script:labX = @{}; $script:labXSent = @{}
function Get-PlayerFilePath([string]$root, [string]$file) {
  if (-not $root -or $file -notmatch $fileRx) { return '' }
  $c = if ($file -like '*.gpj') { @("$root/Editor/Generator/projects/$file", "$root/scenes/$file") } else { @("$root/scenes/$file") }
  foreach ($p in $c) { if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).ProviderPath } }
  ''
}
function Sync-PlayerExtras {
  if (-not (Test-Player)) { return }
  $ic = [Globalization.CultureInfo]::InvariantCulture; $want = @{}; $map = @{}
  foreach ($c in @((Get-Settings).playerLayout.custom)) {
    $g = 1000 + [int]("$($c.id)".Substring(1))
    foreach ($b in @($c.buttons)) {
      $path = Get-PlayerFilePath $script:playRoot "$($b.file)"
      $want["$($b.id)"] = 'addb ' + (@("$($b.id)", $g, $(if ($c.swap) { 1 } else { 0 }), $b.fader, $(if ($b.bpm) { 1 } else { 0 }), $(if ($b.flash) { 1 } else { 0 }),
        ([double]$b.beats).ToString('0.####', $ic), $path, "$($b.title)") -join '|')
      $map["$($b.id)"] = [pscustomobject]@{ sec = "$($b.id)"; title = "$($b.title)"; path = $path; kind = $(if (-not $path) { 'missing' } elseif ($path -like '*.gpj') { 'gpj' } else { 'scex' }) }
    }
  }
  foreach ($k in @($script:labXSent.Keys)) { if (-not $want.ContainsKey($k)) { [void](Send-Player "delb $k"); $script:labXSent.Remove($k) } }
  foreach ($k in $want.Keys) { if ($script:labXSent[$k] -ne $want[$k] -and (Send-Player $want[$k])) { $script:labXSent[$k] = $want[$k] } }
  $script:labX = $map
}
function Get-PlayerStatus {
  if (-not (Test-Player) -or -not (Test-Path -LiteralPath $script:labStat)) { return $null }
  try { [IO.File]::ReadAllText($script:labStat) | ConvertFrom-Json } catch { $null }
}

# ---- everything that changes the show. Called straight away, or later from the queue (see below).
function Invoke-Action([string]$path, $body) {
  switch ($path) {
    '/api/aim/install' { return (Invoke-Engine '-Action Install -Mode Room') }
    '/api/color/apply' {
      $hx = "$($body.hex)".Trim().TrimStart('#')
      if ($hx -notmatch '^[0-9a-fA-F]{6}$') { return @{ ok = $false; error = 'Pick a colour first.'; out = '' } }
      $nm = ("$($body.name)" -replace '[^A-Za-z0-9 \-]', '').Trim(); if ($nm.Length -gt 30) { $nm = $nm.Substring(0, 30) }
      $na = if ($nm) { " -Name `"$nm`"" } else { '' }
      return (Invoke-Engine "-Action Apply -Color $hx$na" $colorEngine)
    }
    '/api/gdrive/sync' { return (Invoke-Engine '-Action Sync' $gdEngine) }
    '/api/gdrive/import' { return (Invoke-Engine '-Action Import' $gdEngine) }
    '/api/apply' {
      $w = [int]$body.w; $d = [int]$body.d
      if ($w -lt 20 -or $w -gt 300 -or $d -lt 20 -or $d -gt 300) { return @{ ok = $false; error = 'Size must be 20-300%.'; out = '' } }
      $f = if ($body.force) { ' -Force' } else { '' }
      $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }
      $r = Invoke-Engine "-Action Apply -Size `"$w $d`" -NoPrompt$f$mo"
      # when ShowXpress is (next) open, show the result: DF CHECK 140 + 251 / ROOM CHECK
      if ($r.ok) { if ($mo) { Set-PendingPress @('ROOM CHECK') 'ROOM CHECK' } else { Set-PendingPress @('DF CHECK 140', 'DF CHECK 251') 'DF CHECK 140 + 251' } }
      return $r
    }
    '/api/home' { $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }; return (Invoke-Engine "-Action Home -NoPrompt$mo") }
    '/api/skip/apply' {
      $ids = @($body.heads | ForEach-Object { "$_" })
      if (@($ids | Where-Object { $_ -notmatch '^\d+$' }).Count -or $ids.Count -lt 2) { return @{ ok = $false; error = 'Pick at least 2 heads.'; out = '' } }
      return (Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $skipEngine)
    }
    '/api/rig/apply' {
      $ids = @($body.heads | ForEach-Object { "$_" })
      if (@($ids | Where-Object { $_ -notmatch '^\d+$' }).Count -or $ids.Count -lt 1) { return @{ ok = $false; error = 'Tick at least one head.'; out = '' } }
      # REVERSE HEADS (flip.ps1) are saved from this tab too: always the FULL list, so a queued save that replaces an older one keeps it
      $fo = ''
      if ($null -ne $body.flip) {
        $fl = [ordered]@{}
        foreach ($pp in $body.flip.PSObject.Properties) {
          if ($pp.Name -notmatch '^\d+$') { return @{ ok = $false; error = 'Unknown head.'; out = '' } }
          if ($pp.Value.pan -or $pp.Value.tilt) { $fl[$pp.Name] = [ordered]@{ pan = [bool]$pp.Value.pan; tilt = [bool]$pp.Value.tilt } }
        }
        $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($cf, (@{ flip = $fl } | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
        try { $rf = Invoke-Engine "-Action Apply -ChangesFile `"$cf`"" $flipEngine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
        if (-not $rf.ok) { $rf.error = "Reversed heads NOT saved (nothing was changed): $($rf.error)"; return $rf }
        if ($rf.out -notmatch 'nothing to change') { $fo = "  Reversed heads:`n" + $rf.out.TrimEnd() + "`n`n  Tonight's Rig:`n" }
      }
      $r = Invoke-Engine "-Action Apply -Heads `"$($ids -join ',')`"" $rigEngine
      $r.out = $fo + $r.out
      if ($r.ok) { $r.out += Update-SkipFlash $ids }
      elseif ($fo) { $r.error = "The reversed heads WERE saved, but Tonight's Rig was not: $($r.error)" }
      return $r
    }
    '/api/apc/apply' {
      $items = @(foreach ($c in @($body.changes)) { if ($c) { $o = [ordered]@{ sec = "$($c.sec)"; title = "$($c.title)"; note = $c.note }; if ($null -ne $c.on) { $o.on = $c.on; $o.off = $c.off }; $o } })
      $badC = @($items | Where-Object { $_.Contains('on') -and (("$($_.on)" -notmatch '^\d+$') -or ("$($_.off)" -notmatch '^\d+$') -or [int]$_.on -gt 127 -or [int]$_.off -gt 127) }).Count
      if ($badC -or -not $items.Count -or @($items | Where-Object { $_.sec -notmatch '^page\d+_button\d+$' -or "$($_.note)" -notmatch '^-?\d+$' -or [int]$_.note -lt -1 -or [int]$_.note -gt 63 }).Count) {
        return @{ ok = $false; error = 'Nothing valid to save.'; out = '' } }
      return (Invoke-WithChanges $apcEngine $items)
    }
    '/api/speed/apply' {
      $items = @(foreach ($c in @($body.changes)) { if ($c) { [ordered]@{ sec = "$($c.sec)"; title = "$($c.title)"; fader = $c.fader } } })
      if (-not $items.Count -or @($items | Where-Object { $_.sec -notmatch '^page\d+_button\d+$' -or "$($_.fader)" -notmatch '^\d+$' -or [int]$_.fader -gt 99 }).Count) {
        return @{ ok = $false; error = 'Nothing valid to save.'; out = '' } }
      return (Invoke-WithChanges $speedEngine $items)
    }
    '/api/health/fix' {
      $k = "$($body.key)"
      if ($k -notmatch '^(speed|midiout|midilight|pad|color|fixtures)\|(page\d+_button\d+|\d+)$') { return @{ ok = $false; error = 'Unknown fix.'; out = '' } }
      return (Invoke-Engine "-Action Fix -FixId `"$k`"" $healthEngine)
    }
    '/api/rt/install' { return (Invoke-Engine '-Action Install' $rtEngine) }
    '/api/scene/save' {
      # SCENE EDITOR: only the changes go to scene_edit.ps1, which changes just those in the file
      $f = "$($body.scene)"
      if ($f -notmatch $sceneRx) { return @{ ok = $false; error = 'Unknown scene.'; out = '' } }
      $o = [ordered]@{ scene = $f; sha = "$($body.sha)"; steps = @($body.steps | Where-Object { $null -ne $_ }); addch = @($body.addch | Where-Object { $null -ne $_ }); delch = @($body.delch | Where-Object { $null -ne $_ }) }
      $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
      [IO.File]::WriteAllText($cf, ($o | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
      try { return (Invoke-Engine "-Action Save -ChangesFile `"$cf`"" $sceneEngine) } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
    }
    '/api/move/save' {
      # MOVEMENT EDITOR: only the changes go to move_edit.ps1, which changes just those lines of the .gpj
      $f = "$($body.move)"
      if ($f -notmatch $moveRx) { return @{ ok = $false; error = 'Unknown movement.'; out = '' } }
      $o = [ordered]@{ move = $f; sha = "$($body.sha)"; secs = @($body.secs | Where-Object { $null -ne $_ }); heads = @($body.heads | Where-Object { $null -ne $_ }) }
      $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
      [IO.File]::WriteAllText($cf, ($o | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
      try { $r = Invoke-Engine "-Action Save -ChangesFile `"$cf`"" $moveEngine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
      return (Update-MoveScenes $f $r)
    }
    '/api/remote/enable' { return (Invoke-Engine '-Action Enable' $remoteEngine) }
    '/api/rt/apply' {
      $as = [ordered]@{}
      if ($body.assign) { foreach ($pp in $body.assign.PSObject.Properties) { if ($pp.Name -match '^(tl|tr|tm|bl|br|bm)-(l|r)$' -and "$($pp.Value)" -match '^\d+$') { $as[$pp.Name] = "$($pp.Value)" } } }
      if (-not $as.Count) { return @{ ok = $false; error = 'Put at least one mover on a truss.'; out = '' } }
      $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
      [IO.File]::WriteAllText($cf, (@{ assign = $as; extra = [bool]$body.extra } | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
      try { $r = Invoke-Engine "-Action Apply -ChangesFile `"$cf`"" $rtEngine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
      if ($r.ok -and $body.rig) {
        $hl = ($r.out -split "`r?`n") | Where-Object { $_ -match '^RIGHEADS: [\d,]+$' } | Select-Object -Last 1
        if ($hl) { $r2 = Invoke-Engine "-Action Apply -Heads `"$($hl.Substring(10))`"" $rigEngine
          if ($r2.ok) { $r.out += "`n  Tonight's Rig:`n" + $r2.out } else { $r.out += "`n  Tonight's Rig NOT updated: $($r2.error)" } }
        $sl = ($r.out -split "`r?`n") | Where-Object { $_ -match '^SKIPHEADS: [\d,]+$' } | Select-Object -Last 1
        if ($sl) { $r.out += Update-SkipFlash ($sl.Substring(11) -split ',') }
      }
      return $r
    }
  }
  @{ ok = $false; error = 'Unknown action.'; out = '' }
}

# ---- QUEUE (user 2026-11-21: close ShowXpress only once a night). While ShowXpress is open, Save/Apply in any tab is
# queued; as soon as ShowXpress has been closed for a few seconds (it rewrites live.ini as it closes) the queue runs in
# order (Google Drive sync always last) and ShowXpress is opened again. A later save of the same thing replaces the
# earlier one. The Helper doesn't quit while something is queued.
$queueable = @{
  '/api/apply' = 'Aim Movers'; '/api/home' = 'Aim Movers (reset)'; '/api/aim/install' = 'ROOM buttons on the SETUP page'
  '/api/color/apply' = "Tonight's Color"; '/api/skip/apply' = 'Strobe'; '/api/rig/apply' = "Tonight's Rig"
  '/api/apc/apply' = 'APC pads'; '/api/speed/apply' = 'Speed faders'; '/api/health/fix' = 'Health fix'
  '/api/rt/install' = 'RIG ID button'; '/api/rt/apply' = 'Rig Test (2D view)'; '/api/gdrive/sync' = 'Sync to Google Drive'
  '/api/gdrive/import' = 'Import from Google Drive'
  '/api/remote/enable' = 'ShowXpress remote control'; '/api/scene/save' = 'Scene'; '/api/move/save' = 'Movement' }
$sceneRx = '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$'
$moveRx = '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.gpj$'
# a step scene made from a movement (GRAND ENTRANCE.scex follows GRAND ENTRANCE.gpj, df_aim.ps1) is made again after it changes
function Update-MoveScenes([string]$f, $r) {
  if ($r.ok -and $f -eq 'GRAND ENTRANCE.gpj' -and "$($r.out)" -match 'CHANGED') {
    $r2 = Invoke-Engine '-Action Rebuild' $engine
    $r.out += $(if ($r2.ok) { "`n  GRAND ENTRANCE scene made again from the movement." } else { "`n  WARNING: the GRAND ENTRANCE scene was NOT made again: $($r2.error)" })
  }
  $r
}
$queue = New-Object Collections.Generic.List[object]
$qReopen = $true; $qDone = $null; $qClosed = 0
function Get-QueueKey([string]$path, $body) {
  if ($path -eq '/api/apply' -or $path -eq '/api/home') { return "aim-$(if ("$($body.mode)" -eq 'room') { 'room' } else { 'floor' })" }
  if ($path -eq '/api/health/fix') { return "fix-$($body.key)" }
  if ($path -eq '/api/scene/save') { return "scene-$("$($body.scene)".ToLower())" }   # one queued save per scene
  if ($path -eq '/api/move/save') { return "move-$("$($body.move)".ToLower())" }     # one queued save per movement
  $path
}
function Add-Queue([string]$path, $body) {
  $key = Get-QueueKey $path $body
  $label = $queueable[$path]
  if ($key -like 'aim-*') { $label = "$label - $(if ($key -eq 'aim-room') { 'Room' } else { 'Dance Floor' })" }
  if ($path -eq '/api/color/apply') { $label = "$label (#$("$($body.hex)".TrimStart('#').ToLower()))" }
  if ($path -eq '/api/scene/save') { $label = "$label $("$($body.scene)" -replace '\.scex$', '')" }
  if ($path -eq '/api/move/save') { $label = "$label $("$($body.move)" -replace '\.gpj$', '')" }
  $old = @($queue | Where-Object { $_.key -eq $key })
  foreach ($o in $old) { [void]$queue.Remove($o) }
  $queue.Add([pscustomobject]@{ key = $key; label = $label; path = $path; body = ($body | ConvertTo-Json -Depth 8 -Compress) })
  @{ ok = $true; queued = $true; replaced = [bool]$old.Count; label = $label; out = ''; error = '' }
}
function Get-QueueInfo {
  @{ items = @($queue | ForEach-Object { @{ key = $_.key; label = $_.label } }); reopen = $qReopen; done = $qDone }
}
function Step-Queue {
  # called about once a second by the main loop
  if (-not $queue.Count) { $script:qClosed = 0; return }
  if (Test-SxOpen) { $script:qClosed = 0; return }
  # live aim closed ShowXpress / is running: the queue waits for it (it runs when live aim is saved)
  if ((Test-Live) -or (Test-Player) -or ((Get-Date) - $script:liveHold).TotalSeconds -lt 180) { $script:qClosed = 0; return }
  $script:qClosed++
  if ($script:qClosed -lt 4) { return }   # give ShowXpress time to finish writing the show
  Invoke-QueueItems $qReopen
}
function Invoke-QueueItems([bool]$reopen) {
  $gd = '/api/gdrive/sync', '/api/gdrive/import'
  $items = @($queue | Where-Object { $_.path -eq '/api/gdrive/import' }) + @($queue | Where-Object { $gd -notcontains $_.path }) + @($queue | Where-Object { $_.path -eq '/api/gdrive/sync' })
  $queue.Clear(); $script:qClosed = 0
  $res = @(foreach ($it in $items) {
    $b = $it.body | ConvertFrom-Json
    $r = try { Invoke-Action $it.path $b } catch { @{ ok = $false; error = $_.Exception.Message; out = '' } }
    @{ label = $it.label; ok = [bool]$r.ok; error = "$($r.error)"; out = "$($r.out)" }
  })
  $reo = $null
  if ($reopen) { $reo = try { Start-Sx } catch { @{ ok = $false; error = $_.Exception.Message } } }
  $script:qDone = @{ at = (Get-Date).ToString('s'); results = $res; reopened = [bool]($reo -and $reo.ok); reopenError = $(if ($reo -and -not $reo.ok) { "$($reo.error)" } else { '' }) }
}

# ---- SHOWXPRESS REMOTE (user 2026-11-22): the Helper presses Live buttons itself (sx_remote.ps1, ShowXpress "External
# App" TCP remote). Rig Test turns RIG ID on, Aim turns DF AIM / DF CHECK on, and after an aim Apply the CHECK buttons
# come on by themselves as soon as ShowXpress is open again. Automatic presses never cut a running show (-Idle).
$titleRx = '^[^"|\r\n]{1,80}$'
function Invoke-Remote([string]$act, [string[]]$titles = @(), [string]$flags = '') {
  $ta = if (@($titles).Count) { " -Titles `"$(@($titles) -join '|')`"" } else { '' }
  $r = Invoke-Engine "-Action $act$ta $flags" $remoteEngine
  $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
  if ($j) { return ($j | ConvertFrom-Json) }
  [pscustomobject]@{ ok = $false; error = $(if ($r.error) { $r.error } else { 'No answer from the helper script.' }) }
}
$script:pend = $null; $script:pendT = [datetime]::MinValue; $script:remLast = $null
function Set-PendingPress([string[]]$titles, [string]$label, [int]$secs = 1200) { $script:pend = @{ titles = $titles; label = $label; until = (Get-Date).AddSeconds($secs) } }
function Step-Pending {
  $p = $script:pend; if (-not $p) { return }
  if ((Get-Date) -gt $p.until -or (Test-Auto)) { $script:pend = $null; return }
  if (((Get-Date) - $script:pendT).TotalSeconds -lt 3 -or -not (Test-SxOpen) -or (Test-Live)) { return }
  $script:pendT = Get-Date
  $r = Invoke-Remote 'Press' $p.titles '-Solo -Idle'
  if ($r.connected -or ($r.PSObject.Properties['ready'] -and -not $r.ready)) {
    $script:pend = $null
    $script:remLast = @{ at = (Get-Date).ToString('o'); label = $p.label; ok = [bool]($r.connected -and -not $r.skipped); skipped = [bool]$r.skipped
                         playing = @($r.playing); error = "$($r.error)" }
  }
}

# ---- AUTO SHOW (user 2026-11-22): sx_remote.ps1 -Action Auto runs as a child process and plays the looks from
# <show>/auto_show.json; commands go to its stdin, it writes its state to a temp file. The Helper doesn't quit while it plays.
$script:autoP = $null; $script:autoPl = $false; $autoStat = Join-Path ([IO.Path]::GetTempPath()) "sxh_autoshow_$PID.json"
function Test-Auto { [bool]($script:autoP -and -not $script:autoP.HasExited) }
function Get-AutoStatus {
  $s = $null
  if (Test-Path -LiteralPath $autoStat) { try { $s = [IO.File]::ReadAllText($autoStat) | ConvertFrom-Json } catch {} }
  if ($s -and -not (Test-Auto)) { $s.running = $false }
  $s
}
function Stop-Auto {
  $p = $script:autoP; $script:autoP = $null
  if (-not $p) { return }
  try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('q'); if (-not $p.WaitForExit(6000)) { $p.Kill() } } } catch { try { $p.Kill() } catch {} }
}
function Send-Auto([string]$c) { if (Test-Auto) { try { $script:autoP.StandardInput.WriteLine($c); return $true } catch {} }; $false }
function Start-Auto([string]$look) {
  Stop-Auto
  Remove-Item -LiteralPath $autoStat -ErrorAction SilentlyContinue
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$remoteEngine`" -Action Auto -StatusFile `"$autoStat`""
  if ($look -match '^[0-9a-f]{8}$') { $a += " -Titles $look" }
  if ($TestRoot) { $a += " -TestRoot `"$TestRoot`"" }
  # SX Player running (Lab, stage 4): the looks play on it instead of ShowXpress
  $script:autoPl = Test-Player
  if ($script:autoPl) { $a += " -Pipe sxh_player_$PID -PlayerStatus `"$($script:labStat)`"" }
  $psi.Arguments = $a; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.AutoFlush = $true
  $script:autoErr = $p.StandardError.ReadToEndAsync(); $script:autoOut = $p.StandardOutput.ReadToEndAsync()
  $script:autoP = $p
  for ($i = 0; $i -lt 60; $i++) {   # wait for its first state (or for it to stop with a reason)
    Start-Sleep -Milliseconds 100
    $s = Get-AutoStatus
    if ($s -and $s.running) { return @{ ok = $true; status = $s } }
    if ($p.HasExited) { break }
  }
  $s = Get-AutoStatus
  if ($s -and $s.error) { return @{ ok = $false; error = "$($s.error)"; status = $s } }
  if ($p.HasExited) { $e = "$($script:autoErr.Result)".Trim(); Stop-Auto; return @{ ok = $false; error = $(if ($e) { ($e -split "`r?`n")[0] } else { 'The Auto Show didn''t start.' }) } }
  @{ ok = $true; status = $s }
}

# ---- APC40 mk2 (user 2026-11-25): apc40.ps1 runs as a child process for as long as SX Studio does (Windows). It waits for
# the APC40 to be plugged in, then plays the user's own pages of pads (apc40.json, SX Studio's settings - never a show file)
# through ShowXpress's remote. SX Studio doesn't quit while the APC40 is in use, so it works with the window closed.
$script:a40P = $null; $script:a40Next = [datetime]::MinValue; $a40Stat = Join-Path ([IO.Path]::GetTempPath()) "sxh_apc40_$PID.json"
function Test-Apc40 { [bool]($script:a40P -and -not $script:a40P.HasExited) }
function Get-Apc40Lay { Join-Path $cfgDir 'apc40.json' }
function Get-Apc40Status {
  $s = $null
  if (Test-Path -LiteralPath $a40Stat) { try { $s = [IO.File]::ReadAllText($a40Stat) | ConvertFrom-Json } catch {} }
  if ($s -and -not (Test-Apc40)) { $s.running = $false }
  $s
}
function Test-Apc40Busy { if (-not (Test-Apc40)) { return $false }; $s = Get-Apc40Status; [bool]($s -and $s.apc -eq 'ok') }
function Stop-Apc40 {
  $p = $script:a40P; $script:a40P = $null
  if (-not $p) { return }
  try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('q'); if (-not $p.WaitForExit(4000)) { $p.Kill() } } } catch { try { $p.Kill() } catch {} }
}
function Send-Apc40([string]$c) { if (Test-Apc40) { try { $script:a40P.StandardInput.WriteLine($c); return $true } catch {} }; $false }
function Step-Apc40 {
  # (re)start it - not on a Mac, not in a test copy with -TestRoot (that would take the real APC40)
  if ($onMac -or $TestRoot -or (Test-Apc40) -or (Get-Date) -lt $script:a40Next) { return }
  $script:a40Next = (Get-Date).AddSeconds(20)
  Remove-Item -LiteralPath $a40Stat -ErrorAction SilentlyContinue
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$apc40Engine`" -Layout `"$(Get-Apc40Lay)`" -StatusFile `"$a40Stat`""
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.AutoFlush = $true
  $script:a40Err = $p.StandardError.ReadToEndAsync(); $script:a40Out = $p.StandardOutput.ReadToEndAsync()
  $script:a40P = $p
}
function Send-Apc40Json($ctx, $r) {
  $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 } else { $null }
  if (-not $j) { Send-Json $ctx @{ ok = $false; error = $(if ($r.error) { "$($r.error)" } else { 'No answer from the helper script.' }) }; return }
  $s = Get-Apc40Status
  Send-Text $ctx 200 'application/json; charset=utf-8' ($j.Substring(0, $j.Length - 1) + ',"windows":' + $(if ($onMac) { 'false' } else { 'true' }) + ',"status":' + $(if ($s) { $s | ConvertTo-Json -Depth 4 -Compress } else { 'null' }) + '}')
}

# ---- PHONE / iPAD (user 2026-11-22): the phone opens http://<this computer>:47322 on the same Wi-Fi and gets this same page,
# phone-sized. The page above stays on localhost; a small relay (C#, no admin needed) takes the phone's requests on the
# Wi-Fi port and hands them to it with the header X-SXH-Phone. A phone is let in once with a 6-digit code (shown on the
# Home page for 10 minutes after "Pair a phone"), then it keeps a key (phone.json). "Unpair" makes a new key.
# A phone can do everything the window can, except updates and these phone settings.
$cfgDir = if ($TestRoot) { $TestRoot } elseif ($onMac) { Join-Path $HOME 'AwaazTools' } else { Join-Path $env:APPDATA 'ShowXpress Helper' }
$phoneF = Join-Path $cfgDir 'phone.json'
$script:ph = [pscustomobject]@{ on = $false; key = '' }
if (Test-Path -LiteralPath $phoneF) { try { $j = [IO.File]::ReadAllText($phoneF) | ConvertFrom-Json; $script:ph = [pscustomobject]@{ on = [bool]$j.on; key = "$($j.key)" } } catch {} }
function New-PhoneKey { -join (1..2 | ForEach-Object { [guid]::NewGuid().ToString('N') }) }
function Save-Phone {
  if (-not (Test-Path -LiteralPath $cfgDir)) { [void](New-Item -ItemType Directory -Path $cfgDir -Force) }
  [IO.File]::WriteAllText($phoneF, ($script:ph | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}
if (-not $script:ph.key) { $script:ph.key = New-PhoneKey }

# ---- SETTINGS (user 2026-11-22: the cogwheel). settings.json next to phone.json. Light/dark is per device (browser);
# the tab layout is shared by the window, phones and iPads. driveFolder = Google Drive's My Drive (gdrive.ps1 reads it).
$setF = Join-Path $cfgDir 'settings.json'
# 'lab' = the SX Player tab (out of the Lab since 2026-11-23, the id stayed). tabNames = the user's own tab names (Settings).
# playerLayout = how the SX Player tab arranges the show's pages and buttons: {pages:[page n..], order:{"n":[button sec..]}} -
# only this tab's view, ShowXpress's own live screen is never changed.
# 2026-11-24 (user): pages can be collapsed / hidden (collapsed:[n..], hidden:[n..]), and the player has pages of its own
# (custom:[{id:"x1", name, swap, buttons:[{id:"x1_b1", title, file, fader, bpm, flash, beats, color}]}]) that play the
# show's scene / movement files. All of it is SX Studio's settings only - live.ini and the scenes are never written.
$tabIds = @('rt', 'aim', 'color', 'pre', 'lab', 'auto', 'rig', 'skip', 'apc', 'apc40', 'speed', 'scene', 'move', 'look', 'health')
$secRx = '^[\w .\-]{1,60}$'
function Get-TabNames($v) {
  $o = [ordered]@{}
  if ($v) { foreach ($p in $v.PSObject.Properties) { $n = ("$($p.Value)" -replace '[\x00-\x1f<>]', '').Trim(); if ($tabIds -contains $p.Name -and $n -and $n.Length -le 24) { $o[$p.Name] = $n } } }
  $o
}
$pgRx = '^(\d{1,3}|x\d{1,3})$'; $xbRx = '^x\d{1,3}_b\d{1,3}$'; $fileRx = '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.(scex|gpj)$'
function Get-CleanText($v, [int]$max) { $t = ("$v" -replace '[\x00-\x1f<>|]', '').Trim(); if ($t.Length -gt $max) { $t = $t.Substring(0, $max).Trim() }; $t }
function Get-PlayerLayout($v) {
  $pg = @(@($v.pages) | ForEach-Object { "$_" } | Where-Object { $_ -match $pgRx } | Select-Object -Unique -First 140)
  $od = [ordered]@{}
  if ($v -and $v.order) { foreach ($p in $v.order.PSObject.Properties) { if ($p.Name -match $pgRx) {
    $od[$p.Name] = @(@($p.Value) | ForEach-Object { "$_" } | Where-Object { $_ -match $secRx } | Select-Object -Unique -First 300) } } }
  $hid = @(@($v.hidden) | ForEach-Object { "$_" } | Where-Object { $_ -match $pgRx } | Select-Object -Unique -First 140)
  $col = @(@($v.collapsed) | ForEach-Object { "$_" } | Where-Object { $_ -match $pgRx } | Select-Object -Unique -First 140)
  $cu = @(foreach ($c in @($v.custom | Select-Object -First 40)) {
    if (-not $c -or "$($c.id)" -notmatch '^x\d{1,3}$') { continue }
    $id = "$($c.id)"; $nm = Get-CleanText $c.name 40; if (-not $nm) { $nm = 'NEW PAGE' }
    $bs = @(foreach ($b in @($c.buttons | Select-Object -First 64)) {
      if (-not $b -or "$($b.id)" -notmatch $xbRx -or -not "$($b.id)".StartsWith("${id}_") -or "$($b.file)" -notmatch $fileRx) { continue }
      $fd = 0; [void][int]::TryParse("$($b.fader)", [ref]$fd); $fd = [math]::Max(0, [math]::Min(15, $fd))
      $bt = 1.0; [void][double]::TryParse("$($b.beats)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$bt)
      if ($bt -le 0.01 -or $bt -gt 64) { $bt = 1.0 }
      $co = -1; if ("$($b.color)" -match '^\d{1,8}$' -and [int64]"$($b.color)" -le 0xFFFFFF) { $co = [int]"$($b.color)" }
      $ti = Get-CleanText $b.title 40; if (-not $ti) { $ti = "$($b.file)" -replace '\.(scex|gpj)$', '' }
      [ordered]@{ id = "$($b.id)"; title = $ti; file = "$($b.file)"; fader = $fd; bpm = [bool]$b.bpm; flash = [bool]$b.flash; beats = $bt; color = $co }
    })
    [ordered]@{ id = $id; name = $nm; swap = [bool]$c.swap; buttons = @($bs | Group-Object { $_.id } | ForEach-Object { $_.Group[0] }) }
  })
  $cu = @($cu | Group-Object { $_.id } | ForEach-Object { $_.Group[0] })
  [ordered]@{ pages = $pg; order = $od; hidden = $hid; collapsed = $col; custom = $cu }
}
function Get-Settings {
  $s = [ordered]@{ tabOrder = $tabIds; tabHidden = @(); tabNames = $null; playerLayout = $null; reopen = $true; autoUpd = $true; driveFolder = '' }
  if (Test-Path -LiteralPath $setF) {
    try { $j = [IO.File]::ReadAllText($setF) | ConvertFrom-Json; foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } } } catch {}
  }
  $o = @(@($s.tabOrder) | ForEach-Object { "$_" } | Where-Object { $tabIds -contains $_ } | Select-Object -Unique)
  # v1.9.7 put the tabs in menus with a new default order. An order still in the old default sequence was never changed
  # by the user (it was saved with the other settings), so it takes the new one; an order the user set is kept
  $old = @('rt', 'rig', 'aim', 'skip', 'color', 'apc', 'speed', 'health', 'pre', 'auto', 'lab', 'scene', 'move', 'look'); $k = 0
  $sub = $true; foreach ($t in $o) { while ($k -lt $old.Count -and $old[$k] -ne $t) { $k++ }; if ($k -ge $old.Count) { $sub = $false; break }; $k++ }
  if ($sub) { $o = @() }
  $s.tabOrder = @($o + @($tabIds | Where-Object { $o -notcontains $_ }))
  $s.tabHidden = @(@($s.tabHidden) | ForEach-Object { "$_" } | Where-Object { $tabIds -contains $_ } | Select-Object -Unique)
  $s.reopen = [bool]$s.reopen; $s.autoUpd = [bool]$s.autoUpd; $s.driveFolder = "$($s.driveFolder)"
  $s.tabNames = Get-TabNames $s.tabNames; $s.playerLayout = Get-PlayerLayout $s.playerLayout
  # the Skip Flash tab is called Strobe now (user 2026-11-24): their own name for it, Strobes, isn't needed any more
  if ($s.tabNames.Contains('skip') -and $s.tabNames['skip'] -match '^\s*strobes?\s*$') { $s.tabNames.Remove('skip') }
  $s
}
function Save-Settings($s) {
  if (-not (Test-Path -LiteralPath $cfgDir)) { [void](New-Item -ItemType Directory -Path $cfgDir -Force) }
  [IO.File]::WriteAllText($setF, ($s | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding($false)))
}
# ---- EXPORT / IMPORT SETTINGS (user 2026-11-25). One JSON file: { app:'SX Studio', kind:'settings', format:1, version,
# saved, settings, apc40, autoShow, device }. Import checks every part the way its own tab does (Get-PlayerLayout,
# apc40.ps1 -Action Save, sx_remote.ps1 -Action AutoSave) and backs up what it replaces first.
function Get-AutoConfig {
  $r = Invoke-Engine '-Action AutoGet' $remoteEngine
  $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
  if ($j) { try { return ($j | ConvertFrom-Json).config } catch {} }
  $null
}
function Get-EngineObj([string]$script) {
  $r = Invoke-Engine '-Action Preview' $script
  $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
  if ($j) { try { return ($j | ConvertFrom-Json) } catch {} }
  $null
}
# 2026-11-25 (user: "save everything customizable"): the APC mini pads (note + colours) and each button's speed fader,
# as the APC mini / Speed faders tabs set them. Import matches buttons by place AND title, so another show is safe.
function Get-ApcMiniExport {
  $a = Get-EngineObj $apcEngine; if (-not $a -or -not $a.ok) { return $null }
  @{ pads = @(foreach ($p in @($a.pads)) { if ([int]$p.type -eq 0) { [ordered]@{ sec = "$($p.sec)"; title = "$($p.title)"; note = [int]$p.note; on = [int]$p.on; off = [int]$p.off } } }) }
}
function Get-SpeedExport {
  $a = Get-EngineObj $speedEngine; if (-not $a -or -not $a.ok) { return $null }
  @{ buttons = @(foreach ($b in @($a.buttons)) { [ordered]@{ sec = "$($b.sec)"; title = "$($b.title)"; fader = [int]$b.fader } }) }
}
function Get-ConfigExport {
  $ap = $null; $f = Get-Apc40Lay
  if (Test-Path -LiteralPath $f) { try { $ap = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch {} }
  [ordered]@{ app = 'SX Studio'; kind = 'settings'; format = 1; version = $appVer; saved = (Get-Date -Format 's')
              settings = (Get-Settings); apc40 = $ap; autoShow = (Get-AutoConfig); apcMini = (Get-ApcMiniExport)
              speedFaders = (Get-SpeedExport); phone = @{ on = [bool]$script:ph.on } }
}
# this device's own choices (light/dark etc.) that the page sends along: sxh_* strings only, never the phone key
function Get-DeviceKeys($v) {
  $o = [ordered]@{}
  if ($v -is [pscustomobject]) { foreach ($q in @($v.PSObject.Properties | Select-Object -First 50)) {
    if ($q.Name -match '^sxh_[\w\-]{1,60}$' -and $q.Name -ne 'sxh_phone_key' -and $q.Value -is [string] -and $q.Value.Length -le 20000) { $o[$q.Name] = $q.Value } } }
  $o
}
function Get-DownloadsDir {
  $c = @()
  if ($onMac) { $c += Join-Path $HOME 'Downloads' }
  else {
    try { $c += (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
    $c += Join-Path $env:USERPROFILE 'Downloads'
  }
  @($c | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }) + @(Join-Path $cfgDir 'exports')
}
$script:cfgExport = ''
function Save-ConfigExport($device) {
  try {
    $d = Get-ConfigExport; $d['device'] = Get-DeviceKeys $device
    $js = $d | ConvertTo-Json -Depth 12; $base = 'SX Studio settings ' + (Get-Date -Format 'yyyy-MM-dd'); $err = ''
    # Downloads first; a Mac may not let SX Studio write there (Privacy & Security) -> its own folder (exports)
    foreach ($dir in $(if ($TestRoot) { @($TestRoot) } else { Get-DownloadsDir })) {
      try {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $f = Join-Path $dir "$base.json"; $k = 2
        while (Test-Path -LiteralPath $f) { $f = Join-Path $dir "$base ($k).json"; $k++ }
        [IO.File]::WriteAllText($f, $js, (New-Object Text.UTF8Encoding($false)))
        $script:cfgExport = $f
        return @{ ok = $true; path = $f; name = (Split-Path $f -Leaf); folder = $dir }
      } catch { $err = $_.Exception.Message }
    }
    @{ ok = $false; error = "The settings couldn't be saved: $err" }
  } catch { @{ ok = $false; error = "The settings couldn't be saved: $($_.Exception.Message)" } }
}
function Invoke-WithJson($obj, [string]$engineArgs, [string]$script) {
  $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($cf, ($obj | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
  try { Invoke-Engine "$engineArgs -ConfigFile `"$cf`"" $script } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
}
function Import-Config($d) {
  if (-not $d -or "$($d.app)" -ne 'SX Studio' -or "$($d.kind)" -ne 'settings') { return @{ ok = $false; error = "That file isn't an SX Studio settings file. Nothing was changed." } }
  if ("$($d.format)" -notmatch '^\d+$' -or [int]$d.format -gt 1) { return @{ ok = $false; error = 'That file is from a newer SX Studio - update SX Studio first. Nothing was changed.' } }
  # back up what is there now (newest 5 kept)
  $bd = Get-BackupDir; $bk = Join-Path $bd ('settings before import ' + (Get-Date -Format 'yyyy-MM-dd HHmmss'))
  try {
    [void](New-Item -ItemType Directory -Path $bk -Force)
    $cur = Get-ConfigExport
    [IO.File]::WriteAllText((Join-Path $bk 'SX Studio settings.json'), ($cur | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    @(Get-ChildItem -LiteralPath $bd -Directory -Filter 'settings before import *' | Sort-Object Name -Descending | Select-Object -Skip 5) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  } catch { return @{ ok = $false; error = "Couldn't back up the settings you have now, so nothing was changed: $($_.Exception.Message)" } }
  $done = New-Object Collections.Generic.List[string]; $warn = New-Object Collections.Generic.List[string]
  if ($d.settings -and -not ($d.settings -is [pscustomobject])) { $warn.Add("The tabs and SX Player pages in the file couldn't be read, so they were kept as they were.") }
  elseif ($d.settings) {
    $n = $d.settings; $st = Get-Settings
    if ($null -ne $n.tabOrder) { $st.tabOrder = @($n.tabOrder | ForEach-Object { "$_" }) }
    if ($null -ne $n.tabHidden) { $st.tabHidden = @($n.tabHidden | ForEach-Object { "$_" }) }
    if ($null -ne $n.tabNames) { $st.tabNames = Get-TabNames $n.tabNames }
    if ($null -ne $n.playerLayout) { $st.playerLayout = Get-PlayerLayout $n.playerLayout }
    if ($null -ne $n.reopen) { $st.reopen = [bool]$n.reopen; $script:qReopen = $st.reopen }
    if ($null -ne $n.autoUpd) { $st.autoUpd = [bool]$n.autoUpd }
    if ($null -ne $n.driveFolder) {
      $g = "$($n.driveFolder)".Trim()
      if (-not $g -or (Test-Path -LiteralPath $g -PathType Container)) { $st.driveFolder = $g }
      else { $warn.Add("The Google Drive folder in the file isn't on this computer, so that one setting was kept as it was.") }
    }
    Save-Settings $st; Sync-PlayerExtras
    $done.Add('the tabs and the SX Player pages')
  }
  $ap = @(if ($d.apc40) { $d.apc40.pages })
  if ($d.apc40 -and -not ($ap.Count -and -not @($ap | Where-Object { -not ($_ -is [pscustomobject] -and $_.pads -is [pscustomobject]) }).Count)) {
    $warn.Add("The APC40 pages in the file couldn't be read, so they were kept as they were.")
  } elseif ($d.apc40) {
    $r = Invoke-WithJson $d.apc40 "-Action Save -Layout `"$(Get-Apc40Lay)`"" $apc40Engine
    $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
    $ok = $false; if ($j) { try { $ok = [bool]($j | ConvertFrom-Json).ok } catch {} }
    if ($ok) { [void](Send-Apc40 'reload'); $done.Add('the APC40 pads and faders') } else { $warn.Add("The APC40 pages in the file couldn't be read, so they were kept as they were.") }
  }
  if ($d.autoShow -and -not ($d.autoShow -is [pscustomobject] -and $null -ne $d.autoShow.looks)) {
    $warn.Add("The Auto Show in the file couldn't be read, so it was kept as it was.")
  } elseif ($d.autoShow) {
    $r = Invoke-WithJson $d.autoShow '-Action AutoSave' $remoteEngine
    if ($r.ok) { [void](Send-Auto 'reload'); $done.Add('the Auto Show') } else { $warn.Add("The Auto Show couldn't be imported ($($r.error)), so it was kept as it was.") }
  }
  $sxOpen = Test-SxOpen
  $toShow = {
    param([string]$path, [object[]]$items, [string]$what)   # an array: an empty List as a script block argument throws in PS 5.1
    if (-not $items.Count) { $done.Add("$what (already the same)"); return }
    if ($sxOpen) { [void](Add-Queue $path @{ changes = $items }); $done.Add("$what (saved as soon as ShowXpress is closed)"); return }
    $r = try { Invoke-Action $path @{ changes = $items } } catch { @{ ok = $false; error = $_.Exception.Message } }
    if ($r.ok) { $done.Add($what) } else { $warn.Add("$what couldn't be imported ($($r.error)), so they were kept as they were.") }
  }
  if ($d.apcMini -and $d.apcMini.pads) {
    $cur = Get-EngineObj $apcEngine
    if (-not $cur -or -not $cur.ok) { $warn.Add("The show's APC mini pads couldn't be read, so they were kept as they were.") }
    else {
      $now = @{}; foreach ($p in @($cur.pads)) { $now["$($p.sec)"] = $p }
      $ch = New-Object Collections.Generic.List[object]; $miss = 0
      foreach ($p in @($d.apcMini.pads | Select-Object -First 300)) {
        if (-not $p -or "$($p.sec)" -notmatch '^page\d+_button\d+$' -or "$($p.note)" -notmatch '^-?\d+$') { continue }
        $n = [int]$p.note; $c = $now["$($p.sec)"]
        if (-not $c -or "$($c.title)" -ne "$($p.title)" -or [int]$c.type -ne 0 -or $n -lt -1 -or $n -gt 63) { $miss++; continue }
        $o = [ordered]@{ sec = "$($p.sec)"; title = "$($p.title)"; note = $n }
        $colOk = "$($p.on)" -match '^\d+$' -and "$($p.off)" -match '^\d+$' -and [int]$p.on -le 127 -and [int]$p.off -le 127
        $colCh = $colOk -and $n -ge 0 -and ([int]$p.on -ne [int]$c.on -or [int]$p.off -ne [int]$c.off)
        if ($colCh) { $o.on = [int]$p.on; $o.off = [int]$p.off }
        if ($n -ne [int]$c.note -or $colCh) { $ch.Add($o) }
      }
      & $toShow '/api/apc/apply' $ch.ToArray() 'the APC mini pads'
      if ($miss) { $warn.Add($(if ($miss -eq 1) { "1 APC mini pad in the file isn't the same button in this show, so it was left out." } else { "$miss APC mini pads in the file aren't the same buttons in this show, so they were left out." })) }
    }
  }
  if ($d.speedFaders -and $d.speedFaders.buttons) {
    $cur = Get-EngineObj $speedEngine
    if (-not $cur -or -not $cur.ok) { $warn.Add("The show's speed faders couldn't be read, so they were kept as they were.") }
    else {
      $now = @{}; foreach ($b in @($cur.buttons)) { $now["$($b.sec)"] = $b }
      $nf = @($cur.faders).Count; $ch = New-Object Collections.Generic.List[object]; $miss = 0
      foreach ($b in @($d.speedFaders.buttons | Select-Object -First 2000)) {
        if (-not $b -or "$($b.sec)" -notmatch '^page\d+_button\d+$' -or "$($b.fader)" -notmatch '^\d+$') { continue }
        $c = $now["$($b.sec)"]
        if (-not $c -or "$($c.title)" -ne "$($b.title)" -or [int]$b.fader -ge [Math]::Max($nf, 1)) { $miss++; continue }
        if ([int]$b.fader -ne [int]$c.fader) { $ch.Add([ordered]@{ sec = "$($b.sec)"; title = "$($b.title)"; fader = [int]$b.fader }) }
      }
      & $toShow '/api/speed/apply' $ch.ToArray() 'the speed faders'
      if ($miss) { $warn.Add($(if ($miss -eq 1) { "1 button in the file isn't in this show (or follows a fader it doesn't have), so its speed fader was left out." } else { "$miss buttons in the file aren't in this show (or follow a fader it doesn't have), so their speed faders were left out." })) }
    }
  }
  if ($d.phone -and $null -ne $d.phone.on -and [bool]$d.phone.on -ne [bool]$script:ph.on) {
    $script:ph.on = [bool]$d.phone.on; Save-Phone
    if ($script:ph.on) { Start-PhoneRelay } else { Stop-PhoneRelay; $script:pin = '' }
    $done.Add("phone access $(if ($script:ph.on) { 'on (phones still pair here with a code)' } else { 'off' })")
  }
  @{ ok = $true; done = @($done); warn = @($warn); settings = (Get-Settings); backup = $bk }
}
function Get-BackupDir { if ($TestRoot) { Join-Path (Split-Path (Split-Path $TestRoot)) 'HelperBackups' } elseif ($onMac) { Join-Path $HOME 'AwaazTools/backups' } else { Join-Path $env:APPDATA 'ShowXpress Helper/backups' } }
function Open-OnComputer([string]$what) {
  $t = switch ($what) {
    'show'    { $j = (Invoke-Engine '-Action Preview' $gdEngine).out -split "`r?`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1; if ($j) { ($j | ConvertFrom-Json).show } else { '' } }
    'backups' { Get-BackupDir }
    'export'  { $script:cfgExport }
    'gddl'    { 'https://www.google.com/drive/download/' }
    'gdapp'   { if ($onMac) { '/Applications/Google Drive.app' } else { Join-Path $env:ProgramFiles 'Google/Drive File Stream/launch.bat' } }
    default   { '' }
  }
  if (-not $t) { return @{ ok = $false; error = 'Nothing to open.'; out = '' } }
  if ($t -notmatch '^https://' -and -not (Test-Path -LiteralPath $t)) {
    return @{ ok = $false; out = ''; error = $(switch ($what) { 'backups' { 'No import backups yet - one is made each time you import from Google Drive.' } 'gdapp' { "Google Drive for desktop isn't installed - press Get Google Drive." } default { "Not found: $t" } }) }
  }
  if ($TestRoot) { return @{ ok = $true; out = "  (test) would open $t"; error = '' } }
  if ($what -eq 'export') { if ($onMac) { & open -R $t } else { Start-Process explorer.exe -ArgumentList "/select,`"$t`"" } }
  elseif ($onMac) { & open $t }
  elseif ($what -eq 'gdapp') { Start-Process -FilePath $t -WindowStyle Hidden }
  elseif ($t -match '^https://') { Start-Process $t }
  else { Start-Process explorer.exe -ArgumentList "`"$t`"" }
  @{ ok = $true; out = ''; error = '' }
}
$script:qReopen = (Get-Settings).reopen
$script:pin = ''; $script:pinUntil = [datetime]::MinValue; $script:pinFails = 0; $script:pinLock = [datetime]::MinValue
$script:relay = $null; $script:relayErr = ''
$relayCs = @'
using System; using System.IO; using System.Net; using System.Net.Sockets; using System.Text; using System.Threading;
public class SxhRelay {
  TcpListener ls; int local; int busy;
  public volatile bool Running; public string Error = ""; public string LastIp = ""; public DateTime LastSeen = DateTime.MinValue;
  public bool Start(int lanPort, int localPort) {
    local = localPort;
    try { ls = TcpListener.Create(lanPort); ls.Start(); }   // IPv4 and IPv6
    catch (Exception e) { Error = "Port " + lanPort + " can't be used (" + e.Message + ")"; return false; }
    Running = true; Error = "";
    Thread t = new Thread(Loop); t.IsBackground = true; t.Start();
    return true;
  }
  public void Stop() { Running = false; try { ls.Stop(); } catch { } }
  void Loop() {
    while (Running) {
      TcpClient c;
      try { c = ls.AcceptTcpClient(); } catch { break; }
      if (Interlocked.Increment(ref busy) > 24) { Interlocked.Decrement(ref busy); try { c.Close(); } catch { } continue; }
      ThreadPool.QueueUserWorkItem(Handle, c);
    }
    Running = false;
  }
  static string ReadHead(Stream s, out byte[] rest) {
    rest = new byte[0]; byte[] buf = new byte[32768]; int n = 0;
    while (n < buf.Length) {
      int k = s.Read(buf, n, buf.Length - n); if (k <= 0) return null;
      int from = Math.Max(0, n - 3); n += k;
      for (int i = from; i <= n - 4; i++) {
        if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
          rest = new byte[n - i - 4]; Array.Copy(buf, i + 4, rest, 0, rest.Length);
          return Encoding.ASCII.GetString(buf, 0, i);
        }
      }
    }
    return null;
  }
  static TcpClient Dial(int port) {
    // the window's server is on "localhost": 127.0.0.1, or only ::1 on some Macs
    try { TcpClient t4 = new TcpClient(AddressFamily.InterNetwork); t4.Connect(IPAddress.Loopback, port); return t4; } catch { }
    TcpClient t6 = new TcpClient(AddressFamily.InterNetworkV6); t6.Connect(IPAddress.IPv6Loopback, port); return t6;
  }
  static void Bad(Stream s, int code) {
    try { byte[] b = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + " Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); s.Write(b, 0, b.Length); } catch { }
  }
  void Handle(object o) {
    TcpClient c = (TcpClient)o; TcpClient up = null;
    try {
      c.ReceiveTimeout = 15000; c.SendTimeout = 15000;
      NetworkStream cs = c.GetStream();
      IPAddress ra = ((IPEndPoint)c.Client.RemoteEndPoint).Address;
      if (ra.IsIPv4MappedToIPv6) ra = ra.MapToIPv4();
      string ip = ra.ToString();
      byte[] rest; string head = ReadHead(cs, out rest);
      if (head == null) return;
      string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
      string[] rl = lines[0].Split(' ');
      if (rl.Length != 3 || !(rl[0] == "GET" || rl[0] == "POST" || rl[0] == "HEAD") || !rl[1].StartsWith("/") || !rl[2].StartsWith("HTTP/1.")) { Bad(cs, 400); return; }
      StringBuilder sb = new StringBuilder();
      sb.Append(rl[0]).Append(' ').Append(rl[1]).Append(" HTTP/1.1\r\n");
      int cl = 0;
      for (int i = 1; i < lines.Length; i++) {
        string ln = lines[i]; int ix = ln.IndexOf(':'); if (ix <= 0) continue;
        string nm = ln.Substring(0, ix).Trim(), v = ln.Substring(ix + 1).Trim(), lo = nm.ToLowerInvariant();
        if (lo == "transfer-encoding") { Bad(cs, 411); return; }
        if (lo == "host" || lo == "connection" || lo == "keep-alive" || lo == "upgrade" || lo == "te" || lo.StartsWith("proxy-") || lo.StartsWith("x-sxh-")) continue;
        if (lo == "content-length" && (!int.TryParse(v, out cl) || cl < 0 || cl > 4000000)) { Bad(cs, 413); return; }
        sb.Append(nm).Append(": ").Append(v).Append("\r\n");
      }
      sb.Append("Host: localhost:").Append(local).Append("\r\nX-SXH-Phone: ").Append(ip).Append("\r\nConnection: close\r\n\r\n");
      byte[] body = new byte[cl]; int got = Math.Min(rest.Length, cl); Array.Copy(rest, 0, body, 0, got);
      while (got < cl) { int k = cs.Read(body, got, cl - got); if (k <= 0) return; got += k; }
      LastIp = ip; LastSeen = DateTime.Now;
      up = Dial(local);
      up.ReceiveTimeout = 200000; up.SendTimeout = 15000;   // a show script can take a while
      NetworkStream us = up.GetStream();
      byte[] hb = Encoding.ASCII.GetBytes(sb.ToString()); us.Write(hb, 0, hb.Length);
      if (cl > 0) us.Write(body, 0, cl);
      us.Flush();
      byte[] rrest; string rhead = ReadHead(us, out rrest);
      if (rhead == null) { Bad(cs, 502); return; }
      long rcl = -1; StringBuilder ob = new StringBuilder();
      foreach (string ln in rhead.Split(new string[] { "\r\n" }, StringSplitOptions.None)) {
        string lo = ln.ToLowerInvariant();
        if (lo.StartsWith("connection:") || lo.StartsWith("keep-alive:")) continue;
        if (lo.StartsWith("content-length:")) long.TryParse(ln.Substring(15).Trim(), out rcl);
        ob.Append(ln).Append("\r\n");
      }
      ob.Append("Connection: close\r\n\r\n");
      byte[] oh = Encoding.ASCII.GetBytes(ob.ToString()); cs.Write(oh, 0, oh.Length);
      long sent = rrest.Length; if (rcl >= 0 && sent > rcl) sent = rcl;
      cs.Write(rrest, 0, (int)sent);
      byte[] buf = new byte[65536];
      while (rcl < 0 || sent < rcl) {
        int k = us.Read(buf, 0, buf.Length); if (k <= 0) break;
        if (rcl >= 0 && sent + k > rcl) k = (int)(rcl - sent);
        cs.Write(buf, 0, k); sent += k;
      }
      cs.Flush();
    } catch { }
    finally {
      try { c.Close(); } catch { }
      if (up != null) { try { up.Close(); } catch { } }
      Interlocked.Decrement(ref busy);
    }
  }
}
'@
function Start-PhoneRelay {
  if ($script:relay -and $script:relay.Running) { return }
  try { if (-not ('SxhRelay' -as [type])) { Add-Type -TypeDefinition $relayCs -Language CSharp } }
  catch { $script:relayErr = "The phone connection couldn't start: $($_.Exception.Message)"; return }
  $script:relay = New-Object SxhRelay
  if ($script:relay.Start($PhonePort, $Port)) { $script:relayErr = '' } else { $script:relayErr = $script:relay.Error; $script:relay = $null }
}
function Stop-PhoneRelay { if ($script:relay) { try { $script:relay.Stop() } catch {} }; $script:relay = $null }
function Get-LanAddrs {
  # this computer's Wi-Fi / network addresses a phone can use (Wi-Fi first)
  $a = @()
  try {
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ("$($ni.OperationalStatus)" -ne 'Up' -or "$($ni.NetworkInterfaceType)" -eq 'Loopback') { continue }
      if ("$($ni.Name) $($ni.Description)" -match 'vEthernet|VMware|VirtualBox|Hyper-V|Loopback|utun|awdl|llw|bridge|docker|WSL|Tailscale|ZeroTier') { continue }
      foreach ($u in $ni.GetIPProperties().UnicastAddresses) {
        if ("$($u.Address.AddressFamily)" -ne 'InterNetwork') { continue }
        $s = "$($u.Address)"; if ($s -like '127.*' -or $s -like '169.254.*') { continue }
        $wifi = "$($ni.NetworkInterfaceType)" -eq 'Wireless80211' -or "$($ni.Name) $($ni.Description)" -match 'Wi-?Fi|WLAN|Wireless|^en0'
        $a += [pscustomobject]@{ ip = $s; name = "$($ni.Name)"; wifi = $wifi }
      }
    }
  } catch {}
  @($a | Sort-Object @{ e = { -not $_.wifi } }, ip)
}
function Get-LocalName {
  # the Bonjour name (stays the same at every venue - iPhone and iPad understand it)
  $n = ''
  if ($onMac) { try { $n = "$(& scutil --get LocalHostName 2>$null)".Trim() } catch {} }
  if (-not $n) { $n = ([Net.Dns]::GetHostName() -replace '\.local$', '') }
  if ($n -match '^[A-Za-z0-9-]{1,63}$') { "$n.local" } else { '' }
}
function Get-PhoneInfo {
  $pinOn = $script:pin -and (Get-Date) -lt $script:pinUntil
  $seen = if ($script:relay -and $script:relay.LastSeen -gt [datetime]::MinValue) { $script:relay.LastSeen.ToString('s') } else { '' }
  @{ ok = $true; on = [bool]$script:ph.on; port = $PhonePort; running = [bool]($script:relay -and $script:relay.Running); error = "$script:relayErr"
     addrs = @(Get-LanAddrs); local = (Get-LocalName); mac = $onMac
     pin = $(if ($pinOn) { $script:pin } else { '' }); pinLeft = $(if ($pinOn) { [int]($script:pinUntil - (Get-Date)).TotalSeconds } else { 0 })
     lastSeen = $seen; lastIp = $(if ($seen) { "$($script:relay.LastIp)" } else { '' }) }
}
# routes a phone may use without its key, and routes only the computer itself may use
$phoneOpen = @('/', '/icon.png', '/brand.png', '/logo.png', '/mark.png', '/api/phone/pair', '/fonts/saira.woff2', '/fonts/orbitron.woff2')
$phoneNever = @('/api/update/install', '/api/phone', '/api/phone/set', '/api/phone/pin', '/api/phone/unpair', '/api/open')
if ($script:ph.on) { Start-PhoneRelay }

$html = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>SX Studio</title>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><link rel="icon" href="/icon.png?t=__TOKEN__">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="SX Studio"><meta name="theme-color" content="#0e1014"><link rel="apple-touch-icon" href="/icon.png">
<style>
:root{--bg:#0e1014;--card:#171a21;--line:#262b36;--txt:#e9ecf1;--dim:#8b93a3;--amber:#ffb020;--acc:#a3e635;--accrgb:163,230,53;--green:#3ddc84;--red:#ff5c5c;--blue:#5aa9ff;--panel:#12151b;--well:#0f1217;--hover:#1d212a;--line2:#3a4150;--txt2:#c7cdd8;--mute:#5d6574;--redtxt:#ffc9c9;--hdr:rgba(14,16,20,.95);--veil:rgba(14,16,20,.7);--tabon:#262b36}
html.light{color-scheme:light;--bg:#eef0f4;--card:#ffffff;--panel:#f4f6f9;--well:#e8ebf0;--hover:#e6e9ef;--line:#d3d8e1;--line2:#aab2bf;--txt:#141821;--txt2:#2b313d;--dim:#566070;--mute:#7d8696;--redtxt:#b3261e;--hdr:rgba(238,240,244,.95);--veil:rgba(238,240,244,.75);--tabon:#ffffff;--amber:#d98200;--acc:#4d7c0f;--accrgb:77,124,15;--green:#13994b;--red:#d63333;--blue:#1d6ad0}
html.light .primary{box-shadow:0 3px 12px rgba(77,124,15,.25)}html.light .card,html.light .modal .box{box-shadow:0 1px 3px rgba(20,24,33,.06)}html.light .modal{background:rgba(20,24,33,.35)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header{display:flex;align-items:center;gap:12px;padding:16px 22px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--hdr);backdrop-filter:blur(6px);z-index:5}
.logo{width:36px;height:36px;filter:drop-shadow(0 0 10px rgba(var(--accrgb),.3))}
h1{font-size:18px;margin:0;font-weight:650;letter-spacing:.3px}h1 span{color:var(--dim);font-weight:400;font-size:13px;margin-left:8px}
.pill{margin-left:auto;padding:6px 12px;border-radius:99px;font-size:12.5px;font-weight:600;border:1px solid}
.pill.ok{color:var(--green);border-color:rgba(61,220,132,.35);background:rgba(61,220,132,.08)}.pill.bad{color:var(--amber);border-color:rgba(255,176,32,.4);background:rgba(255,176,32,.1)}
main{max-width:1080px;margin:0 auto;padding:20px 22px 120px;display:grid;gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px}
.card h2{margin:0 0 4px;font-size:15px;font-weight:650}.sub{color:var(--dim);font-size:13px;margin:0 0 14px}
.how{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}.how div{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 12px;font-size:13px;color:var(--txt2)}.how b:first-child{display:block;color:var(--acc);font-size:12px;letter-spacing:.6px;margin-bottom:2px}.how b:not(:first-child){color:var(--txt)}
.row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.grow{flex:1}
.group{margin-top:10px}.group h3{font-size:12px;letter-spacing:1px;color:var(--dim);margin:12px 0 8px;font-weight:600}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(118px,1fr));gap:8px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:8px 10px;font-size:12.5px}
.tile .n{font-weight:650;font-size:13px;margin-bottom:3px}.tile .l{color:var(--dim)}.tile .v{color:var(--txt)}
.tile.moved{border-color:rgba(90,169,255,.45)}.tile.copied{border-style:dashed}.tile .cf{margin-top:3px;font-size:11px;color:var(--blue)}.tile.sized .sz{color:var(--acc)}.tile.warn{border-color:var(--red);background:rgba(255,92,92,.07)}.tile.warn .n::after{content:" !";color:var(--red)}
.summary{font-size:13px;color:var(--dim)}.summary b{color:var(--txt)}
.warnbox{margin-top:12px;padding:10px 12px;border-radius:10px;background:rgba(255,92,92,.08);border:1px solid rgba(255,92,92,.35);color:var(--redtxt);font-size:13px;display:none}
.sizegrid{display:grid;grid-template-columns:1fr 300px;gap:22px;align-items:center}
.slider{margin:10px 0 16px}.slider .top{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px}.slider label{font-weight:600}
input[type=range]{width:100%;accent-color:var(--acc);height:22px}
.num{width:76px;background:var(--well);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font-size:15px;text-align:right}
.chips{display:flex;gap:6px;flex-wrap:wrap}.chip{background:var(--panel);border:1px solid var(--line);color:var(--txt);border-radius:99px;padding:5px 12px;font-size:12.5px;cursor:pointer}.chip:hover{border-color:var(--acc)}
.link{display:flex;align-items:center;gap:8px;color:var(--dim);font-size:13px;cursor:pointer;user-select:none}
svg{width:100%;height:auto;background:var(--well);border:1px solid var(--line);border-radius:12px}
button{font:inherit;border-radius:10px;border:1px solid var(--line);background:var(--hover);color:var(--txt);padding:9px 16px;cursor:pointer;font-weight:600}
button:hover{border-color:var(--line2)}button:disabled{opacity:.45;cursor:not-allowed}
.primary{background:linear-gradient(180deg,#b8f25a,#8ccf1f);color:#142000;border:none;padding:12px 26px;font-size:15px;box-shadow:0 4px 18px rgba(140,207,31,.25)}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--hdr);border-top:1px solid var(--line);padding:14px 22px}
.bar .in{max-width:1080px;margin:0 auto;display:flex;align-items:center;gap:12px}
.bar .hint{color:var(--dim);font-size:13px}
.result{display:none}.result.ok{display:block;border-color:rgba(61,220,132,.4)}.result.err{display:block;border-color:rgba(255,92,92,.5)}
.result h2{display:flex;gap:8px;align-items:center}.result ul{margin:8px 0 0;padding-left:18px;color:var(--txt2);font-size:13px}
details{margin-top:10px}summary{cursor:pointer;color:var(--dim);font-size:12.5px}pre{white-space:pre-wrap;font:12px/1.4 ui-monospace,Consolas,Menlo,monospace;color:var(--txt2);background:var(--well);border:1px solid var(--line);border-radius:8px;padding:10px;max-height:300px;overflow:auto}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:20}
.modal .box{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:22px;max-width:440px}.modal h2{margin:0 0 8px;font-size:16px}.modal p{color:var(--txt2);margin:0 0 16px}
.busy{position:fixed;inset:0;background:var(--veil);display:none;align-items:center;justify-content:center;z-index:30;font-weight:600}
.spin{width:22px;height:22px;border:3px solid #3a3f4b;border-top-color:var(--acc);border-radius:50%;animation:s 0.8s linear infinite;margin-right:10px}@keyframes s{to{transform:rotate(360deg)}}
.foot{color:var(--mute);font-size:12px;text-align:center}
.gone{position:fixed;inset:0;background:var(--bg);display:none;align-items:center;justify-content:center;flex-direction:column;z-index:40;color:var(--dim)}
.tabs{display:flex;gap:3px;background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:3px;margin-left:14px}
.tabs button{border:none;background:transparent;color:var(--dim);padding:7px 16px;border-radius:8px;font-size:13.5px}
.tabs button:hover{color:var(--txt)}.tabs button.on{background:var(--tabon);color:var(--txt);box-shadow:inset 0 -2px 0 var(--acc)}
.view{display:none;gap:18px}.view.on{display:grid}.bar .in{display:none}.bar .in.on{display:flex}
.gh{display:flex;align-items:center;gap:8px;margin:14px 0 8px}.gh h3{margin:0;font-size:12px;letter-spacing:1px;color:var(--dim);font-weight:600}.gh .cnt{color:var(--mute);font-size:12px}
.mini{padding:3px 11px;font-size:12px;border-radius:99px;font-weight:600}
.heads{display:grid;grid-template-columns:repeat(8,1fr);gap:8px}
.hd{position:relative;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 0 10px;text-align:center;cursor:pointer;user-select:none;font-weight:700;font-size:17px;color:var(--mute);transition:background .12s,border-color .12s,color .12s}
.hd small{display:block;font-size:11px;font-weight:500;color:var(--mute);margin-top:2px}
.hd:hover{border-color:var(--line2)}
.hd.on{background:rgba(var(--accrgb),.13);border-color:var(--acc);color:var(--txt)}.hd.on small{color:var(--acc)}
.fxg .hd{cursor:default;padding:10px 0 8px}.fxg .hd.on{background:rgba(80,150,255,.12);border-color:var(--blue)}
.fx{display:inline-block;margin:7px 2px 0;padding:3px 7px;border-radius:8px;border:1px solid var(--line);font-size:11.5px;font-weight:600;cursor:pointer;color:var(--mute);user-select:none}
.fx.on{background:rgba(80,150,255,.25);border-color:var(--blue);color:var(--txt)}
.hd.chg::after{content:"";position:absolute;top:7px;right:8px;width:7px;height:7px;border-radius:50%;background:var(--blue)}
.order{display:flex;flex-wrap:wrap;gap:4px;align-items:center;margin-top:6px}.order span{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:2px 7px;font-size:12px}.order i{color:var(--mute);font-style:normal;font-size:11px}
.state{font-size:12.5px;font-weight:600;padding:4px 10px;border-radius:99px;border:1px solid}.state.ok{color:var(--green);border-color:rgba(61,220,132,.35)}.state.chg{color:var(--blue);border-color:rgba(90,169,255,.45)}
header{flex-wrap:wrap}.tabs{flex-wrap:wrap}.tabs button{padding:7px 12px}
.scenes{display:grid;gap:6px;margin-top:10px}
.sc{display:grid;grid-template-columns:minmax(150px,250px) 1fr auto;gap:12px;align-items:center;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:8px 12px}
.sc.chg{border-color:rgba(90,169,255,.45)}.sc .nm{font-weight:650;font-size:13px}.sc .nm small{display:block;color:var(--dim);font-weight:400;font-size:11.5px}
.dots{display:flex;flex-wrap:wrap;gap:3px}.dots i{width:14px;height:14px;border-radius:3px;background:var(--tabon);display:inline-block}
.dots i.l{background:var(--acc)}.dots i.o{background:var(--blue)}.dots i.x{background:transparent;border:1px dashed var(--red)}
.sc .st{font-size:12px;color:var(--dim);text-align:right;white-space:nowrap}.sc .st b{color:var(--txt)}
.tag{font-size:11px;padding:1px 7px;border-radius:99px;border:1px solid var(--line);color:var(--dim);margin-left:6px;font-weight:600}
.tag.blue{color:var(--blue);border-color:rgba(90,169,255,.45)}.tag.amber{color:var(--amber);border-color:rgba(255,176,32,.4)}.tag.red{color:var(--red);border-color:rgba(255,92,92,.45)}
.apcwrap{display:grid;grid-template-columns:minmax(0,1fr) 270px;gap:18px;margin-top:14px;align-items:start}
.apc{display:grid;grid-template-columns:repeat(8,1fr);gap:6px;background:#0b0d11;border:1px solid var(--line);border-radius:14px;padding:10px}
.pad{position:relative;aspect-ratio:1/1;border-radius:7px;border:1px solid var(--line);background:var(--panel);cursor:pointer;overflow:hidden;padding:5px 5px 4px;display:flex;flex-direction:column;justify-content:flex-end;user-select:none}
.pad .t{font-size:10px;line-height:1.15;font-weight:650;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.9);display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;word-break:break-word}
.pad .p{font-size:8.5px;color:rgba(255,255,255,.7);text-shadow:0 1px 2px #000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pad .on{position:absolute;left:0;right:0;top:0;height:5px}
.pad.empty{background:transparent;border-style:dashed;border-color:var(--line)}.pad.empty .t{color:var(--line2);text-shadow:none;font-weight:500}
.pad.sel{outline:2px solid var(--acc);outline-offset:1px}.pad.tgt:hover{outline:2px dashed var(--acc);outline-offset:1px}
.pad.mv::after{content:"";position:absolute;top:9px;right:5px;width:7px;height:7px;border-radius:50%;background:var(--blue);box-shadow:0 0 0 2px #0b0d11}
.pad.dup{border-color:var(--red);box-shadow:inset 0 0 0 1px var(--red)}.pad.miss .t{color:var(--redtxt)}
.pad .badge{position:absolute;top:8px;left:5px;background:var(--red);color:#fff;font-size:9px;font-weight:700;border-radius:99px;padding:0 5px}
.apside{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px;font-size:13px}
.apside h3{margin:0 0 6px;font-size:14px}.kv{display:grid;grid-template-columns:72px 1fr;gap:3px 8px;color:var(--dim);font-size:12.5px;margin:8px 0 12px}.kv b{color:var(--txt);font-weight:500}
.sw{display:inline-block;width:12px;height:12px;border-radius:3px;vertical-align:-2px;margin-right:4px;border:1px solid rgba(255,255,255,.2)}
.a4conn{margin-top:12px;font-size:13px;padding:8px 12px;border:1px solid var(--line);border-radius:10px;background:var(--panel)}
.a4conn .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:var(--amber);vertical-align:0}.a4conn .dot.green{background:var(--green)}.a4conn .dot.red{background:var(--red)}
.a4pages{display:flex;gap:6px;flex-wrap:wrap;margin-top:12px}.a4pages .mini.on{border-color:var(--acc);color:var(--acc)}
.a4grid .pad>*,#apgrid .pad>*{pointer-events:none}.a4col summary{cursor:pointer;margin:2px 0 8px;font-weight:600}.a4drop{outline:2px dashed var(--acc)!important;outline-offset:1px}
.a4list{max-height:360px;overflow:auto;margin:8px 0 10px;border:1px solid var(--line);border-radius:8px;padding:2px 4px}
.a4g{font-size:11px;color:var(--dim);margin:8px 4px 2px;text-transform:uppercase;letter-spacing:.04em}
.a4b{padding:4px 6px;border-radius:6px;cursor:pointer;font-size:12.5px}.a4b:hover{background:var(--hover)}.a4b.cur{color:var(--acc);font-weight:650}
.apside input[type=text]{width:100%;box-sizing:border-box;background:var(--well);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font:inherit;font-size:13px}
.faders{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:8px;margin-top:14px}
.fd{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:8px 12px;font-size:12.5px}.fd b{display:block;font-size:13px}.fd span{color:var(--dim)}
.iss{display:flex;gap:10px;align-items:flex-start;padding:9px 0;border-top:1px solid var(--line);font-size:13px}.iss:first-child{border-top:none}
.iss .ic{flex:none;width:20px;height:20px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:800}
.iss.error .ic{background:rgba(255,92,92,.16);color:var(--red)}.iss.warn .ic{background:rgba(255,176,32,.14);color:var(--amber)}.iss.info .ic{background:rgba(90,169,255,.14);color:var(--blue)}
.iss .d{color:var(--dim);font-size:12.5px;margin-top:1px}.iss b{font-weight:650}.iss .act{flex:none;display:flex;gap:6px;align-items:center}
.iss .fx{margin-top:5px;font-size:12.5px;color:var(--txt);background:rgba(61,220,132,.06);border-left:2px solid rgba(61,220,132,.55);padding:4px 9px;border-radius:0 6px 6px 0}.iss .fx b{color:var(--green);font-weight:650}
.iss .act button{white-space:nowrap}.iss.done .ic{background:rgba(61,220,132,.14);color:var(--green)}
.applied{background:var(--panel);border:1px solid rgba(61,220,132,.35);border-radius:12px;padding:6px 14px;margin:12px 0 4px}.applied h3{margin:6px 0 2px;font-size:13.5px;color:var(--green)}
.legend{display:flex;gap:8px;flex-wrap:wrap}
.lg{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:7px 12px;font-size:12.5px;cursor:pointer;user-select:none}.lg b{font-size:15px;margin-right:6px}.lg.on{border-color:var(--acc);background:rgba(var(--accrgb),.08)}
.srch{background:var(--well);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:7px 10px;font-size:13px;width:230px}
.spg{margin-top:16px}.spg .gh{margin:0 0 6px}.spg .gh select{width:170px}
.sp{display:grid;grid-template-columns:1fr 210px 170px;gap:10px;align-items:center;padding:5px 10px;border-radius:8px;border:1px solid transparent}
.sp:nth-child(odd){background:var(--panel)}.sp.chg{border-color:rgba(90,169,255,.45);background:rgba(90,169,255,.06)}
.sp .i{color:var(--dim);font-size:12px}.sp .i.no{color:var(--mute)}
select{background:var(--well);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font:inherit;font-size:13px;width:100%}
.iss.ok .ic{background:rgba(61,220,132,.14);color:var(--green)}
.rtmap{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;background:#0b0d11;border:1px solid var(--line);border-radius:14px;padding:14px;margin-top:14px}
.tw{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:8px 10px 10px}.tw h4{margin:0 0 6px;font-size:11.5px;letter-spacing:.8px;color:var(--dim);font-weight:600;text-transform:uppercase}
.tw .pr{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.slot{background:var(--well);border:1px dashed var(--line2);border-radius:10px;padding:8px 6px;text-align:center;cursor:pointer;min-height:66px;user-select:none}
.slot:hover{border-color:var(--acc)}.slot.set{border-style:solid;border-color:var(--line2)}.slot.chg{box-shadow:inset 0 0 0 1px var(--blue)}
.slot .sd{font-size:10.5px;color:var(--mute);display:block}.slot b{font-size:15px}.slot small{color:var(--dim);font-size:11px}
.dot{display:inline-block;width:18px;height:18px;border-radius:50%;border:2px solid rgba(255,255,255,.25);vertical-align:-4px;margin-right:5px}
.dot.fl{animation:bl .7s linear infinite}@keyframes bl{0%{opacity:1}100%{opacity:.1}}
.mid{grid-row:2;grid-column:1/4;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;color:var(--dim);font-size:12px;text-align:center;border:1px dashed var(--line);border-radius:12px;padding:10px}
.mid .sp2{display:flex;flex-wrap:wrap;gap:4px;justify-content:center}.mid .sp2 span{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:2px 7px;font-size:12px;color:var(--txt)}
.dj{grid-row:4;grid-column:1/4;align-self:end;text-align:center;color:var(--acc);font-size:12px;font-weight:600;letter-spacing:1px;border-top:2px solid rgba(var(--accrgb),.5);padding-top:6px}
.tw.off{visibility:hidden}
.pick{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin:6px 0 12px}.pick div{background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:7px 6px;cursor:pointer;font-size:12px;text-align:center}
.pick div:hover{border-color:var(--acc)}.pick div small{display:block;color:var(--mute);font-size:10.5px}.pick div.cur{border-color:var(--acc);background:rgba(var(--accrgb),.08)}
.legend2{display:grid;grid-template-columns:repeat(8,1fr);gap:6px;margin-top:12px}.legend2 div{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:5px 4px;text-align:center;font-size:11.5px}.legend2 div b{display:block;font-size:13px}
.pgrp h3{font-size:12px;letter-spacing:1px;color:var(--dim);margin:14px 0 4px;font-weight:600}
.hero{display:flex;align-items:center;gap:18px}.hlogo{width:84px;height:84px;filter:drop-shadow(0 0 22px rgba(var(--accrgb),.35))}.hname{font-size:26px;font-weight:700}.hver{color:var(--dim);font-size:13px}
.brand img{max-height:96px;max-width:320px;display:block}.brandtxt{font-weight:800;font-size:32px;letter-spacing:7px;color:#fff;text-align:right;line-height:1}.brandtxt span{display:block;font-size:11px;letter-spacing:7.6px;color:var(--acc);font-weight:600;margin-top:5px}
.htiles{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:18px}.ht{text-align:left;background:var(--panel);padding:12px 14px;border-radius:12px}.ht b{display:block;font-size:14px;margin-bottom:2px}.ht span{color:var(--dim);font-size:12.5px;font-weight:400}.ht:hover{border-color:var(--acc)}
.seg{display:flex;gap:3px;background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:3px;width:max-content}.seg button{border:none;background:transparent;color:var(--dim);padding:8px 24px;border-radius:8px}.seg button:hover{color:var(--txt)}.seg button.on{background:var(--tabon);color:var(--txt);box-shadow:inset 0 -2px 0 var(--acc)}
.hright{margin-left:auto;display:flex;gap:8px;align-items:center}.hright .pill{margin-left:0}
.psw{display:inline-block;width:17px;height:17px;border-radius:4px;margin:0 3px 3px 0;cursor:pointer;border:1px solid rgba(255,255,255,.15)}.psw.cur{outline:2px solid var(--acc);outline-offset:1px}.pcl{font-size:12px;color:var(--dim);margin:2px 0 10px}.pcl .pals{margin:3px 0 7px;line-height:0}
.clwrap{display:grid;grid-template-columns:minmax(0,1fr) 300px;gap:22px;margin-top:6px;align-items:start}
.clpal{display:grid;grid-template-columns:repeat(auto-fill,minmax(104px,1fr));gap:6px}
.cp{display:flex;align-items:center;gap:7px;background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:6px 8px;font-size:12.5px;cursor:pointer;user-select:none}.cp:hover{border-color:var(--line2)}.cp.cur{border-color:var(--acc);background:rgba(var(--accrgb),.08)}
.cp i{flex:none;width:18px;height:18px;border-radius:50%;border:1px solid rgba(255,255,255,.25)}
.wheel{position:relative;flex:none;width:200px;height:200px;border-radius:50%;background:radial-gradient(circle closest-side,#fff,rgba(255,255,255,0)),conic-gradient(red,yellow,lime,cyan,blue,magenta,red);cursor:crosshair;touch-action:none}
.wheel i{position:absolute;width:20px;height:20px;border-radius:50%;border:3px solid #fff;box-shadow:0 0 0 1px #000,0 2px 6px rgba(0,0,0,.6);transform:translate(-50%,-50%);pointer-events:none;display:none}
.clpv{display:none;align-items:center;gap:10px;flex-wrap:wrap;margin-top:12px;padding:10px 12px;border-radius:10px;background:rgba(61,220,132,.07);border:1px solid rgba(61,220,132,.45);font-size:12.5px}.clpv.on{display:flex}
.clpv .dot{width:9px;height:9px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);flex:none}
.clbig{height:120px;border-radius:12px;border:1px solid var(--line);display:flex;align-items:flex-end;padding:10px 12px;margin-bottom:10px}.clbig span{background:rgba(0,0,0,.55);padding:2px 8px;border-radius:6px;font:12px ui-monospace,Consolas,monospace}
input[type=color]{width:46px;height:34px;border:1px solid var(--line);border-radius:8px;background:var(--well);padding:2px;cursor:pointer}
.qbar{display:none;margin:14px 22px 0;padding:12px 16px;border-radius:12px;background:rgba(255,176,32,.08);border:1px solid rgba(255,176,32,.45);font-size:13px}
.qbar.on{display:block}.qbar.done{background:rgba(61,220,132,.07);border-color:rgba(61,220,132,.4)}.qbar.bad{background:rgba(255,92,92,.07);border-color:rgba(255,92,92,.45)}
.qbar h3{margin:0 0 6px;font-size:14px}.qbar .qi{display:inline-flex;align-items:center;gap:6px;background:var(--panel);border:1px solid var(--line);border-radius:99px;padding:3px 6px 3px 11px;margin:0 6px 6px 0}
.qbar .qi button{border:none;background:transparent;color:var(--dim);padding:0 4px;font-size:13px;cursor:pointer}.qbar .qi button:hover{color:var(--red)}
.qbar ul{margin:4px 0 6px;padding-left:18px}.qbar li.no{color:var(--redtxt)}
.lvcall{display:flex;align-items:center;gap:14px;margin:0 0 14px;padding:12px 14px;border-radius:12px;background:rgba(90,169,255,.07);border:1px solid rgba(90,169,255,.4);font-size:13px;color:var(--txt2)}.lvcall b{color:var(--txt)}
.live{position:fixed;inset:0;background:var(--bg);z-index:15;display:none;flex-direction:column}.live.on{display:flex}
.lvtop{display:flex;align-items:center;gap:12px;padding:12px 18px;border-bottom:1px solid var(--line)}.lvt{color:var(--acc);letter-spacing:1px;font-size:15px}
.lvgone{display:none;margin:10px 18px 0;padding:10px 14px;border-radius:10px;background:rgba(255,92,92,.08);border:1px solid rgba(255,92,92,.45);color:var(--redtxt);font-size:13px}.lvgone.on{display:flex;align-items:center;gap:12px}
.lvbody{flex:1;display:grid;grid-template-columns:220px minmax(0,1fr) 280px;min-height:0}
.lvlist{overflow:auto;border-right:1px solid var(--line);padding:4px 10px 20px}
.lvlist h4{margin:12px 0 5px;font-size:11px;letter-spacing:.8px;color:var(--dim);font-weight:600;text-transform:uppercase}
.lvh{display:flex;align-items:center;gap:6px;padding:6px 9px;border-radius:8px;cursor:pointer;border:1px solid transparent;font-size:13px;font-weight:600;user-select:none}
.lvh:hover{background:var(--card)}.lvh.on{border-color:var(--acc);background:rgba(var(--accrgb),.1)}.lvh.dim{color:var(--mute)}
.lvh small{margin-left:auto;font-weight:500;font-size:11px;color:var(--mute);white-space:nowrap}.lvh small.a{color:var(--blue)}.lvh small.cp{color:var(--txt2)}.lvh small.b{color:var(--dim)}
.lvh .sd{font-size:10px;color:var(--mute);width:10px}
.lvmain{display:flex;flex-direction:column;gap:12px;padding:14px 18px;min-height:0}
.seg button small{font-size:10.5px;color:var(--mute);font-weight:500}
.lvpad{flex:1;min-height:220px;touch-action:none;-webkit-user-select:none;-webkit-touch-callout:none;border:2px dashed var(--line2);border-radius:16px;background:radial-gradient(circle at 50% 50%,rgba(var(--accrgb),.07),transparent 60%),#0b0d11;display:flex;align-items:center;justify-content:center;text-align:center;cursor:grab;user-select:none;color:var(--dim);padding:20px}
.lvpad:hover{border-color:var(--mute)}.lvpad.drag{cursor:none;border-color:var(--acc);border-style:solid}
.lvbig{font-size:30px;font-weight:700;color:var(--txt);margin-bottom:6px}.lvbig span{color:var(--acc)}
.lvkeys{color:var(--dim);font-size:12.5px}.lvkeys b{color:var(--txt);font-weight:600}
.lvside{border-left:1px solid var(--line);padding:14px 16px;overflow:auto}.lvside h3{margin:0;font-size:17px}.lvside .sub{margin:2px 0 6px}
.lvside .kv{grid-template-columns:40px 1fr;margin:6px 0 8px}.lvside .kv small{color:var(--dim)}
.lvflip{display:grid;gap:4px;margin:10px 0}
.lvbtns{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:6px}.lvbtns button{padding:8px 10px;font-size:13px}.lvbtns .w2{grid-column:span 2}
.remrow{display:none;align-items:center;gap:8px;flex-wrap:wrap;margin:0 0 14px;padding:10px 14px;border-radius:12px;background:rgba(61,220,132,.05);border:1px solid rgba(61,220,132,.3);font-size:13px;color:var(--txt2)}.remrow.on{display:flex}.remrow b{color:var(--txt)}
.mini.son{border-color:var(--green);color:var(--green);background:rgba(61,220,132,.1)}
.aulook{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-top:8px}.aulook.off{opacity:.55}.aulook.cur{border-color:var(--green);box-shadow:0 0 0 1px rgba(61,220,132,.4)}
.aun{flex:none;width:24px;height:24px;border-radius:50%;background:var(--tabon);display:inline-flex;align-items:center;justify-content:center;font-size:12px;font-weight:700}.aulook.cur .aun{background:var(--green);color:#06210f}
.auchips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;align-items:center}.auchips .none{color:var(--mute);font-size:12.5px}
.auchip{display:inline-flex;align-items:center;gap:2px;background:var(--well);border:1px solid var(--line2);border-radius:99px;padding:3px 4px 3px 11px;font-size:12.5px}.auchip.bad{border-color:var(--red);color:var(--redtxt)}
.auchip button{border:none;background:transparent;color:var(--dim);padding:0 5px;font-size:12px}.auchip button:hover{color:var(--red)}
.auplay{background:#0b0d11;border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin-top:14px}.auplay.on{border-color:rgba(61,220,132,.5)}
.aubig{font-size:28px;font-weight:700;line-height:1.15}.aubig small{font-size:14px;color:var(--acc);font-weight:600;margin-left:6px}
.auprog{height:8px;border-radius:99px;background:var(--hover);margin:12px 0;overflow:hidden}.auprog i{display:block;height:100%;background:linear-gradient(90deg,#3ddc84,#a3e635);width:0;transition:width .25s linear}
.aubeats{display:flex;gap:8px}.aubeats i{width:18px;height:18px;border-radius:50%;background:var(--tabon)}.aubeats i.on{background:var(--acc);box-shadow:0 0 12px rgba(var(--accrgb),.6)}.aubeats i.on.one{background:var(--green);box-shadow:0 0 12px rgba(61,220,132,.6)}
.pkl{max-height:52vh;overflow:auto;margin:8px 0 12px}.pkl h4{margin:10px 0 5px;font-size:11px;letter-spacing:.8px;color:var(--dim);font-weight:600;text-transform:uppercase}
.pks{display:flex;flex-wrap:wrap;gap:5px}.pkb{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:5px 9px;font-size:12.5px;cursor:pointer;user-select:none}.pkb:hover{border-color:var(--acc)}.pkb.on{border-color:var(--acc);background:rgba(var(--accrgb),.12)}.pkb.no{opacity:.4;cursor:not-allowed}
#aupill{background:rgba(61,220,132,.1);border-color:rgba(61,220,132,.45);color:var(--green)}
.pair{position:fixed;inset:0;background:var(--bg);display:none;align-items:center;justify-content:center;z-index:50;padding:24px}.pair.on{display:flex}
.pair .box{max-width:380px;width:100%;text-align:center;display:grid;gap:12px;justify-items:center}.pair h2{margin:0;font-size:21px}.pair .sub{margin:0}
.pair input{font:600 30px/1 ui-monospace,Menlo,Consolas,monospace;letter-spacing:10px;text-align:center;width:100%;max-width:280px;padding:12px;border-radius:12px;border:1px solid var(--line);background:var(--well);color:var(--txt)}
.pair .primary{width:100%;max-width:280px}
.offl{position:fixed;left:0;right:0;top:0;z-index:45;display:none;padding:calc(env(safe-area-inset-top) + 9px) 14px 9px;background:rgba(200,60,60,.96);color:#fff;font-weight:600;font-size:13px;text-align:center}.offl.on{display:block}
.phaddr{font:600 16px ui-monospace,Menlo,Consolas,monospace;background:var(--well);border:1px solid var(--line);border-radius:10px;padding:7px 12px;display:inline-block;margin:4px 8px 4px 0;user-select:all;color:var(--txt)}
.phaddr small{font:500 11.5px var(--fb);color:var(--dim);margin-left:8px}
.phrow{display:flex;align-items:center;gap:6px;flex-wrap:wrap}.phrow .phaddr{margin-right:0}
.phcopy{flex:none}.phcopy.done{background:var(--green);border-color:var(--green);color:#0b0d11}
.phpin{font:700 34px ui-monospace,Menlo,Consolas,monospace;letter-spacing:8px;color:var(--acc);line-height:1.1}
.phgrid{display:grid;grid-template-columns:minmax(0,1fr) 250px;gap:18px;margin-top:12px;align-items:start}.phbox{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.phbox h3{margin:0 0 6px;font-size:12px;letter-spacing:1px;color:var(--dim);font-weight:600}
.ph #phcard,.ph #upd{display:none!important}
.ph header{padding-top:calc(10px + env(safe-area-inset-top));padding-left:calc(12px + env(safe-area-inset-left));padding-right:calc(12px + env(safe-area-inset-right))}
.ph .bar{padding-bottom:calc(12px + env(safe-area-inset-bottom))}
.ph body{-webkit-tap-highlight-color:transparent;-webkit-text-size-adjust:100%}
.ph button,.ph .chip,.ph .hd,.ph .slot,.ph .cp,.ph .pkb,.ph .pad,.ph .lvh,.ph .lg,.ph .pick div{touch-action:manipulation}
.ph .lvkeys{display:none}.ph .lvtop{padding-top:calc(10px + env(safe-area-inset-top))}
.ph .ht[data-go=rt]{order:1}.ph .ht[data-go=rig]{order:2}.ph .ht[data-go=skip]{order:3}.ph .ht[data-go=aim]{order:4}.ph .ht[data-go=color]{order:5}.ph .ht[data-go=pre]{order:6}.ph .ht[data-go=auto]{order:7}.ph .ht[data-go=apc]{order:8}.ph .ht[data-go=apc40]{order:8}.ph .ht[data-go=speed]{order:9}.ph .ht[data-go=health]{order:10}
@media (max-width:860px){.clwrap{grid-template-columns:1fr}.htiles{grid-template-columns:1fr 1fr}}
@media (max-width:860px){.apcwrap{grid-template-columns:1fr}.sc{grid-template-columns:1fr}.sc .st{text-align:left}.sp{grid-template-columns:1fr 1fr}}
@media (max-width:760px){.how{grid-template-columns:1fr}.sizegrid{grid-template-columns:1fr}.heads{grid-template-columns:repeat(4,1fr)}.phgrid{grid-template-columns:1fr}}
@media (max-width:640px){
 header{padding:10px 12px;gap:8px}.logo{width:28px;height:28px}h1{font-size:16px}
 .tabs{order:5;margin:0;width:100%;flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none}.tabs::-webkit-scrollbar{display:none}.tabs button{flex:none;padding:8px 12px}
 .hright{gap:6px}.pill{padding:4px 9px;font-size:11.5px}
 main{padding:12px 10px 160px;gap:12px}.card{padding:14px 13px;border-radius:12px}.qbar{margin:10px 10px 0}
 .htiles{grid-template-columns:1fr;gap:8px}.ht{padding:12px 14px}.hero{gap:12px}.hlogo{width:54px;height:54px}.hname{font-size:20px}.brand{display:none}
 .heads{gap:6px}.hd{padding:11px 0 9px;font-size:16px}
 .legend2{grid-template-columns:repeat(4,1fr)}.rtmap{gap:6px;padding:8px}.tw{padding:6px}.tw .pr{gap:4px}.slot{min-height:60px;padding:6px 3px}.slot b{font-size:14px}
 .pick{grid-template-columns:repeat(2,1fr)}.wheel{width:190px;height:190px}.clwrap .slider{width:100%!important}
 .bar{padding:10px 10px calc(10px + env(safe-area-inset-bottom))}.bar .in{flex-wrap:wrap;gap:8px}.bar .in .hint{flex-basis:100%;order:-1;font-size:12px}
 .bar .in .primary{flex:1;padding:12px 14px}.bar .in button{padding:11px 12px}
 .modal .box{max-width:94vw;padding:18px}.sp{grid-template-columns:1fr}.srch{width:100%}
 .tiles{grid-template-columns:repeat(auto-fill,minmax(100px,1fr))}.seg button{padding:8px 14px}
 .aubig{font-size:22px}.lvcall{flex-direction:column;align-items:stretch}
 .card>.row:first-child>.grow:first-child{flex-basis:100%}.card>.row:first-child>.state{margin-right:auto}
 .bar .in button:not(.primary){flex:1}
 .lvmain .seg button{padding:8px 10px}.lvmain .seg button small,.lvmain>.row>.sub{display:none}
}
@media (max-width:820px){
 .lvtop{flex-wrap:wrap;padding:8px 10px;gap:8px}.lvtop .link{order:5;flex-basis:100%}
 .lvbody{display:flex;flex-direction:column;overflow:auto;-webkit-overflow-scrolling:touch}
 .lvlist{display:flex;gap:6px;overflow-x:auto;border-right:none;border-bottom:1px solid var(--line);padding:8px 10px;flex:none}
 .lvlist h4{display:none}.lvh{flex:none;border-color:var(--line);background:var(--panel)}.lvh small{margin-left:6px}
 .lvmain{padding:10px;flex:none}.lvmain>.row{gap:8px}
 .lvpad{flex:none;min-height:38vh;touch-action:none}
 .lvside{display:flex;flex-direction:column;border-left:none;border-top:1px solid var(--line);overflow:visible;padding:12px 12px calc(16px + env(safe-area-inset-bottom))}
 .lvbtns{order:-1;margin:0 0 12px}.lvbtns button{padding:11px 10px}
 #lvmap{max-width:320px;display:block;margin:0 auto}
}

.cog{font-size:17px;line-height:1;padding:6px 9px;border-radius:99px}.cog.on{border-color:var(--acc);color:var(--acc)}
.txt{background:var(--well);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:7px 10px;font-size:13px}
.tablist{display:grid;gap:6px;margin-top:12px;max-width:520px}
.lbpg h3{margin:16px 0 6px;font-size:13.5px;font-weight:650}.lbpg:first-child h3{margin-top:0}
.lbg{display:flex;flex-wrap:wrap;gap:8px}
.lbfds{display:flex;flex-wrap:wrap;gap:10px 22px;margin-top:10px}.lbf{flex:1 1 200px;display:flex;flex-direction:column;gap:4px;font-size:13px}.lbf b{font-weight:650}.lbf span{color:var(--dim);font-size:12px}.lbf input{width:100%}
.lbb{flex:1 1 150px;min-width:140px;max-width:230px;background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--c,var(--line2));border-radius:10px;padding:9px 11px;cursor:pointer;user-select:none;-webkit-user-select:none}
.lbb b{display:block;font-size:13px;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.lbb small{display:block;color:var(--mute);font-size:11.5px;margin-top:2px}
.lbb:hover{border-color:var(--acc);border-left-color:var(--c,var(--acc))}.lbb.on{border-color:var(--green);border-left-color:var(--c,var(--green));box-shadow:0 0 0 1px rgba(61,220,132,.45);background:rgba(61,220,132,.09)}.lbb.on small{color:var(--green);font-weight:600}
.lbb.na{opacity:.45;cursor:default}.lbb.na:hover{border-color:var(--line)}
#lbpages.idle .lbb{opacity:.85}#lbpages.idle .lbb.na{opacity:.4}.lbb:active{transform:scale(.97)}
.lbtoast{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);background:var(--card);border:1px solid var(--line2);border-radius:12px;padding:11px 18px;font-size:13.5px;z-index:30;box-shadow:0 8px 30px rgba(0,0,0,.45);opacity:0;pointer-events:none;transition:opacity .2s;max-width:90vw;color:var(--txt)}.lbtoast.on{opacity:1}
.tabrow{display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:6px 8px}
.tabrow.drag{border-color:var(--acc);box-shadow:0 4px 14px rgba(0,0,0,.25);position:relative;z-index:2}.tabrow.off .link{opacity:.5}
.tabrow .hdl{cursor:grab;color:var(--mute);font-size:17px;padding:2px 6px;touch-action:none;user-select:none}.tabrow.drag .hdl{cursor:grabbing}
.tabrow .mini{padding:3px 9px}
.setsec h2{display:flex;align-items:center;gap:8px}
.ph .pc-only{display:none!important}
.ph .ht[data-go=settings]{order:11}.ph .ht[data-go=lab]{order:7}
/* ---- SX Studio look (2026-11-23): tech / sleek / modern. Saira for text, Orbitron for the name and headings,
   both bundled (fonts/, SIL OFL) so it looks the same offline and on the phone. */
@font-face{font-family:Saira;src:url(/fonts/saira.woff2?t=__TOKEN__) format('woff2');font-weight:100 900;font-display:swap}
@font-face{font-family:Orbitron;src:url(/fonts/orbitron.woff2?t=__TOKEN__) format('woff2');font-weight:400 900;font-display:swap}
:root{--fb:Saira,"Segoe UI",system-ui,sans-serif;--fd:Orbitron,Saira,"Segoe UI",sans-serif}
body{font-family:var(--fb);font-size:14.5px;letter-spacing:.1px}
.card h2,.modal h2,.pair h2,.lvside h3,.apside h3,.qbar h3{font-family:var(--fd);font-weight:600;letter-spacing:.5px;font-size:14px}
.group h3,.gh h3,.pgrp h3,.phbox h3,.tw h4,.lvlist h4,.pkl h4,.lbpg h3{font-family:var(--fd);font-weight:500;letter-spacing:1.4px;font-size:10.5px;text-transform:uppercase}
.lbpg h3{color:var(--dim)}
.aubig,.lvbig,.phpin,.hd{font-family:var(--fd);letter-spacing:.5px}
/* tabs on their own full-width row under the logo (2026-11-23: 11 tabs wrapped SX Player onto a 2nd line); too narrow = scrolls sideways */
.tabs{order:5;margin:0;width:100%;flex-wrap:nowrap;overflow-x:auto;scrollbar-width:none}.tabs::-webkit-scrollbar{display:none}.tabs{gap:2px}.tabs button{flex:none;padding:7px 10px;font-size:13px}@media (min-width:1300px){.tabs button{padding:7px 14px;font-size:13.5px}}header .hright{margin-left:auto}header{row-gap:10px;padding-bottom:12px}
.tabs button{font-weight:600;letter-spacing:.3px}.tabs button.on{box-shadow:inset 0 -2px 0 var(--acc),0 0 14px rgba(var(--accrgb),.08)}
.primary{letter-spacing:.4px}
:root{--ch1:#ffffff;--ch2:#c9ced6;--ch3:#8d939c;--ch4:#e6e9ee}
html.light{--ch1:#6a7280;--ch2:#3a404b;--ch3:#14171d;--ch4:#565e6b}
svg.mk{width:auto;background:none;border:0;border-radius:0;fill:url(#sxc);overflow:visible}
header .brandmk{display:flex;align-items:center;gap:10px;cursor:pointer;user-select:none}
header .brandmk svg{height:30px;filter:drop-shadow(0 0 10px rgba(var(--accrgb),.18))}
header h1{font-family:var(--fd);font-size:14px;font-weight:600;letter-spacing:4px;color:var(--txt2);margin:2px 0 0}
.hero2{position:relative;overflow:hidden;border-radius:16px;border:1px solid var(--line);padding:30px 30px 26px;color:#e9ecf1;
 background:radial-gradient(ellipse 60% 90% at 8% -10%,rgba(var(--accrgb),.22),transparent 60%),radial-gradient(ellipse 50% 80% at 100% 120%,rgba(90,169,255,.10),transparent 60%),linear-gradient(160deg,#10131a,#07080b)}
.hero2::before{content:"";position:absolute;inset:0;pointer-events:none;opacity:.5;
 background-image:linear-gradient(rgba(255,255,255,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px);background-size:26px 26px;
 -webkit-mask-image:linear-gradient(90deg,#000,transparent 75%);mask-image:linear-gradient(90deg,#000,transparent 75%)}
.hero2 .in{position:relative;display:flex;align-items:center;gap:26px;flex-wrap:wrap}
.hero2 svg.mk{height:88px;fill:url(#sxcd);filter:drop-shadow(0 6px 18px rgba(0,0,0,.6)) drop-shadow(0 0 22px rgba(var(--accrgb),.15))}
.hero2 .hname{font-family:var(--fd);font-size:30px;font-weight:700;letter-spacing:6px;line-height:1;
 background:linear-gradient(180deg,#fff 0%,#c9ced6 48%,#8d939c 54%,#e6e9ee 100%);-webkit-background-clip:text;background-clip:text;color:transparent}
.hero2 .hsub{font-size:12px;letter-spacing:3px;color:#a3e635;text-transform:uppercase;margin-top:8px;font-weight:600}
.hero2 .hver{color:#8b93a3;font-size:12.5px;margin-top:6px}
.hero2 .brand img{max-height:74px;max-width:300px;display:block;mix-blend-mode:screen}
.hero2 .brandtxt{color:#fff}
.htiles{grid-template-columns:repeat(4,1fr);gap:10px;margin-top:0}
.ht{position:relative;overflow:hidden;text-align:left;display:flex;flex-direction:column;justify-content:flex-start;align-items:stretch;background:var(--card);padding:14px 16px 15px;border-radius:12px;border:1px solid var(--line);transition:border-color .15s,transform .15s,background .15s}
.ht::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--acc);opacity:0;transition:opacity .15s}
.ht:hover{transform:translateY(-1px);background:var(--hover)}.ht:hover::before{opacity:1}
.ht i{display:block;font-style:normal;font-family:var(--fd);font-size:9.5px;letter-spacing:1.6px;color:var(--mute);margin-bottom:7px;font-weight:600}
.ht i.st{color:var(--acc)}.ht i.lv{color:var(--green)}
.ht b{font-size:15px;font-weight:650;letter-spacing:.2px}
.hsec{font-family:var(--fd);font-size:10.5px;letter-spacing:1.6px;color:var(--dim);text-transform:uppercase;margin:6px 2px -6px;font-weight:600}
.tabrow .tname{flex:1;min-width:0;background:var(--well);color:var(--txt);border:1px solid transparent;border-radius:7px;padding:5px 8px;font:inherit;font-weight:600}
.tabrow .tname:hover{border-color:var(--line)}.tabrow .tname:focus{border-color:var(--acc);outline:none}
.tabrow .tdef{color:var(--mute);font-size:11.5px;white-space:nowrap}
/* SX Player: arrange mode */
#lbpages.arr .lbb{cursor:grab;touch-action:none;border-style:dashed;opacity:1!important}#lbpages.arr .lbb small{color:var(--mute)}
#lbpages.arr .lbb.drag{opacity:.35!important;cursor:grabbing}
.lbghost{position:fixed;z-index:60;pointer-events:none;transform:rotate(-2deg);box-shadow:0 12px 30px rgba(0,0,0,.5);border-color:var(--acc)!important;opacity:.95}
.lbpg .pgbar{display:none;gap:4px;margin-left:8px}#lbpages.arr .lbpg .pgbar{display:inline-flex}
.lbpg h3{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.lbpg .pcol{background:none;border:0;padding:0 2px;color:var(--dim);cursor:pointer;font-size:12px;line-height:1;min-width:16px}.lbpg .pcol:hover{color:var(--acc)}
.lbpg.col .lbg,.lbpg.col>p{display:none}.lbpg .pgon{color:var(--green);font-weight:600;letter-spacing:.5px}
.lbpg .pgtag{font-size:9.5px;padding:1px 6px;border-radius:6px;border:1px solid var(--line2);color:var(--mute);letter-spacing:1px}
#lbpages.arr .lbpg.hid .lbg,#lbpages.arr .lbpg.hid h3{opacity:.45}
.lbb{position:relative}.lbb .xdel{display:none;position:absolute;top:2px;right:6px;font-style:normal;font-size:15px;color:var(--mute);cursor:pointer;padding:0 3px}#lbpages.arr .lbb .xdel{display:block}.lbb .xdel:hover{color:var(--red)}
.lbal{max-height:46vh;overflow:auto;border:1px solid var(--line);border-radius:10px;padding:4px}.lbal label{display:flex;gap:8px;align-items:baseline;padding:6px 8px;border-radius:8px;cursor:pointer}.lbal label:hover{background:rgba(var(--accrgb),.07)}.lbal small{color:var(--mute);margin-left:auto;text-align:right}
.arrbar{display:none;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 14px;border-radius:12px;background:rgba(var(--accrgb),.07);border:1px solid rgba(var(--accrgb),.4);font-size:13px;color:var(--txt2)}
.arrbar.on{display:flex}
@media (max-width:860px){.htiles{grid-template-columns:1fr 1fr}}
@media (max-width:640px){.hero2{padding:20px 18px}.hero2 svg.mk{height:58px}.hero2 .hname{font-size:22px;letter-spacing:4px}.hero2 .brand{display:none}.htiles{grid-template-columns:1fr 1fr}header .brandmk svg{height:24px}header h1{font-size:12px;letter-spacing:3px}}
.sepv{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:12px;padding:10px 12px;background:var(--panel);border:1px solid var(--line);border-radius:10px}.sepv.on{border-color:rgba(61,220,132,.5)}
.sesc{cursor:pointer}.sesc:hover{border-color:var(--line2)}
.sesteps{display:flex;gap:6px;flex-wrap:wrap}
.sst{background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:5px 9px;font-size:12.5px;font-weight:650;cursor:pointer;min-width:52px;text-align:center;user-select:none}
.sst small{display:block;color:var(--dim);font-size:11px;font-weight:400}.sst.on{border-color:var(--acc);background:rgba(var(--accrgb),.13)}.sst.chg{box-shadow:inset 0 -2px 0 var(--blue)}.sst.new{border-style:dashed}.sst.pl{background:rgba(61,220,132,.18);border-color:var(--green)}
.segrid{margin-top:14px;overflow-x:auto;background:var(--well);border:1px solid var(--line);border-radius:10px;padding:8px}
.segrid table{border-collapse:separate;border-spacing:2px;font-size:11px}.segrid td{min-width:15px;height:14px;border-radius:3px;background:var(--tabon);cursor:pointer}
.segrid td.l{background:var(--acc)}.segrid td.n{background:transparent;box-shadow:inset 0 0 0 1px var(--line)}.segrid td.c{outline:2px solid var(--blue)}
.segrid th{font-weight:500;color:var(--dim);text-align:right;padding-right:6px;white-space:nowrap;cursor:pointer}.segrid th.on{color:var(--txt)}.segrid tr.hd th{text-align:center;padding:0 0 2px}
.sewrap{display:grid;grid-template-columns:230px minmax(0,1fr);gap:16px;margin-top:14px;align-items:start}
.seheads{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px;max-height:560px;overflow:auto}
.seh{display:flex;justify-content:space-between;gap:6px;padding:5px 8px;border-radius:7px;cursor:pointer;font-size:13px;user-select:none}.seh:hover{background:var(--hover)}
.seh.on{background:rgba(var(--accrgb),.15)}.seh small{color:var(--dim);white-space:nowrap}.seh.dim{opacity:.45}
.sech{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px;min-width:0}
.secr{display:grid;grid-template-columns:110px minmax(80px,1fr) 64px 160px 64px 20px;gap:8px;align-items:center;padding:5px 0;border-bottom:1px solid var(--line)}
.secr .nm{font-weight:600;font-size:12.5px;word-break:break-word}.secr .nm small{display:block;color:var(--mute);font-weight:400}.secr.chg .nm{color:var(--blue)}.secr.mix .num{color:var(--dim)}
.secr .x{border:none;background:none;color:var(--mute);padding:0;font-size:18px;line-height:1}.secr .x:hover{color:var(--red)}.secr .fd{font-size:12px}
.lktpl{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:14px}
.lktpl button{text-align:left;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:11px 13px}.lktpl button b{display:block;font-size:14px;margin-bottom:2px}.lktpl button span{color:var(--dim);font-size:12px;font-weight:400}
.lktpl button.on{border-color:var(--acc);background:rgba(var(--accrgb),.12)}
.lkgrid{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(0,1fr);gap:14px;margin-top:14px}
.lkopts{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:grid;gap:9px;align-content:start}
.lkopts .gh{margin:0}.lkopts .mvf select{width:auto;max-width:230px}.lkopts input[type=range]{width:170px}
.lkpair{display:flex;align-items:center;gap:7px}.lkpair select{width:118px}
.lksw{display:inline-block;width:14px;height:14px;border-radius:50%;border:1px solid rgba(255,255,255,.3);flex:none;vertical-align:-2px}
.lkchips{display:flex;flex-wrap:wrap;gap:6px}.lkcc{display:flex;align-items:center;gap:6px;background:var(--card);border:1px solid var(--line);border-radius:99px;padding:5px 11px;font-size:12.5px}
.lkcc.on{border-color:var(--acc);background:rgba(var(--accrgb),.12)}.lkcc b{font-size:11px;color:var(--acc)}
.lkpr{display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:13px}.lkpr b{min-width:104px}.lkpr select{width:118px}.lkpr input[type=range]{flex:1;min-width:90px;width:auto}
.chip.lkgc.on{border-color:var(--acc);background:rgba(var(--accrgb),.13)}.chip.lkgc:disabled{opacity:.4;cursor:default}.chip.lkgc small{color:var(--dim)}
.lkvis{background:#07080b;border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:grid;gap:10px;min-height:60px;margin-top:8px}
.lkrow small{display:block;color:#8a8f99;font-size:11px;margin-bottom:5px}.lkrow div{display:flex;flex-wrap:wrap;gap:7px}
.lkrow i{width:22px;height:22px;border-radius:50%;background:#1b1d22;border:1px solid #2a2d33}
.lkrow i.pr{background:conic-gradient(#fff,#9cf,#fff,#c9f,#fff,#9cf,#fff,#c9f,#fff)!important;animation:lkspin 1.6s linear infinite}
@keyframes lkspin{to{transform:rotate(360deg)}}
@media(max-width:760px){.lktpl{grid-template-columns:1fr 1fr}.lkgrid{grid-template-columns:1fr}}
.ctxm{position:fixed;z-index:80;background:var(--panel);border:1px solid var(--line2);border-radius:10px;padding:4px;box-shadow:0 10px 28px rgba(0,0,0,.45);min-width:190px;display:none}
.ctxm.on{display:block}.ctxm .ctxh{padding:6px 12px 4px;font-size:11px;color:var(--mute);font-weight:600;letter-spacing:.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px}
.ctxm button{display:block;width:100%;text-align:left;border:none;background:none;padding:8px 12px;border-radius:7px;font-size:13px;color:var(--txt)}.ctxm button:hover:not(:disabled){background:var(--hover)}.ctxm button:disabled{color:var(--mute)}
.mvwrap{display:grid;grid-template-columns:minmax(0,1fr) 290px;gap:16px;margin-top:14px;align-items:start}
@media (max-width:900px){.mvwrap{grid-template-columns:1fr}}
.mvcvw{background:var(--well);border:1px solid var(--line);border-radius:12px;padding:8px}
#mvcv{display:block;width:100%;cursor:crosshair;touch-action:none;margin:0 auto}#mvcv[data-kind=pt]{max-width:620px}
.mvside{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:grid;gap:9px}
.mvf{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:13px}.mvf .num{width:96px;font-size:13px;padding:5px 7px}.mvf select{width:130px}
.mvtools{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}.mvf>span:last-child{white-space:nowrap}
.mvnote{margin-top:12px;padding:10px 12px;border-radius:10px;background:var(--panel);border:1px solid var(--line);color:var(--dim);font-size:13px}.mvnote b{color:var(--txt)}
.sst.off{opacity:.62}
.mvheads{margin-top:14px;overflow-x:auto}.mvheads table{width:100%;border-collapse:collapse;font-size:12.5px}
.mvheads th{font-weight:500;color:var(--dim);text-align:left;padding:4px 6px;white-space:nowrap}.mvheads td{padding:4px 6px;border-top:1px solid var(--line);vertical-align:middle}
.mvheads .num{width:86px;font-size:13px;padding:4px 6px}.mvheads .num.chg{border-color:var(--blue);color:var(--blue)}
@media (max-width:760px){.sewrap{grid-template-columns:1fr}.seheads{max-height:260px}.secr{grid-template-columns:90px minmax(0,1fr) 58px;row-gap:4px}.secr select{grid-column:1/3}}
.ph .sewrap{grid-template-columns:1fr}.ph .seheads{max-height:260px}.ph .secr{grid-template-columns:90px minmax(0,1fr) 58px;row-gap:4px}.ph .secr select{grid-column:1/3}
.tabs{flex-wrap:wrap!important;overflow:visible!important;align-items:center;gap:3px!important}
.tg{position:relative}.tgb{display:flex;align-items:center;white-space:nowrap}
.tgc{color:var(--txt)}.tgc:not(:empty)::before{content:'\00b7';margin:0 7px;color:var(--mute)}.tg.one .tgn,.tg.one .tgv{display:none}.tg.one .tgc::before{display:none}
.tgv{font-style:normal;font-size:10px;margin-left:7px;opacity:.65;transition:transform .15s}.tg.open .tgv{transform:rotate(180deg)}.tg.open .tgb{color:var(--txt);background:var(--tabon)}
.tgm{display:none;position:absolute;top:calc(100% + 7px);left:0;min-width:210px;background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:5px;box-shadow:0 14px 34px rgba(0,0,0,.45);z-index:60;flex-direction:column;gap:2px}
.tg.open .tgm{display:flex}.tg.r .tgm{left:auto;right:0}
.tabs .tgm button{text-align:left;padding:9px 13px;border-radius:8px;font-size:13.5px;white-space:nowrap;flex:none}
.tabs .tgm button:hover{background:var(--tabon);color:var(--txt)}.tabs .tgm button.on{color:var(--acc);background:transparent;box-shadow:inset 3px 0 0 var(--acc)}
.tabgh{font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--mute);margin:10px 2px 0}.tabgh:first-child{margin-top:0}
@media(max-width:620px){.tg.on .tgn{display:none}.tg.on .tgc::before{display:none}.tgm{min-width:190px}}
header .brandmk img.mk{height:38px;width:auto;display:block;filter:drop-shadow(0 0 10px rgba(var(--accrgb),.14))}
html.light header .brandmk img.mk{filter:brightness(.62) contrast(1.25) drop-shadow(0 1px 1px rgba(0,0,0,.25))}
.hero2 img.hlogo2{height:150px;width:auto;display:block;filter:drop-shadow(0 6px 18px rgba(0,0,0,.6)) drop-shadow(0 0 24px rgba(var(--accrgb),.10))}
@media(max-width:760px){.hero2 img.hlogo2{height:104px}header .brandmk img.mk{height:30px}}
</style>
<script>(function(){try{var m=localStorage.getItem('sxh_theme')||'dark';if(m==='light'||(m==='auto'&&matchMedia('(prefers-color-scheme: light)').matches))document.documentElement.classList.add('light');}catch(e){}})();</script></head><body>
<svg aria-hidden="true" style="position:absolute;width:0;height:0;border:0;overflow:hidden"><defs>
 <linearGradient id="sxc" gradientUnits="userSpaceOnUse" x1="0" y1="124" x2="0" y2="365"><stop offset="0" style="stop-color:var(--ch1)"/><stop offset=".45" style="stop-color:var(--ch2)"/><stop offset=".55" style="stop-color:var(--ch3)"/><stop offset="1" style="stop-color:var(--ch4)"/></linearGradient>
 <linearGradient id="sxcd" gradientUnits="userSpaceOnUse" x1="0" y1="124" x2="0" y2="365"><stop offset="0" stop-color="#ffffff"/><stop offset=".45" stop-color="#c9ced6"/><stop offset=".55" stop-color="#8d939c"/><stop offset="1" stop-color="#e6e9ee"/></linearGradient>
 <symbol id="sxm" viewBox="0 0 778 445"><polygon points="85.1,132 244,132 288,124 214,174 122.1,174 100,206 152.5,232.2 129.1,253.5 34,206"/><polygon points="202.9,357 44,357 0,365 74,315 165.9,315 188,283 135.5,256.8 158.9,235.5 254,283"/><polygon points="324,132 451,132 521,233 288,445 451,240 384,145"/><polygon points="778,0 524,158 476,133 538,218"/><polygon points="533,252 598,343 656,355 538,357 504,313 449,327"/></symbol>
</defs></svg>
<header><div class="brandmk" id="logo" title="Home"><img class="mk" data-img="mark" alt="SX"><h1 id="ttl">STUDIO</h1></div>
  <nav class="tabs"><button class="tgh" id="tghome">Home</button><div class="tg" data-g="gig"><button class="tgb" aria-haspopup="true" aria-expanded="false"><span class="tgn">Before the gig</span><span class="tgc"></span><i class="tgv">&#9662;</i></button><div class="tgm"><button data-tab="rt">Rig Test</button><button data-tab="aim">Aim Movers</button><button data-tab="color">Tonight's Color</button><button data-tab="pre">Pre-show Check</button></div></div><div class="tg" data-g="live"><button class="tgb" aria-haspopup="true" aria-expanded="false"><span class="tgn">Live</span><span class="tgc"></span><i class="tgv">&#9662;</i></button><div class="tgm"><button data-tab="lab">SX Player</button><button data-tab="auto">Auto Show</button></div></div><div class="tg" data-g="rig"><button class="tgb" aria-haspopup="true" aria-expanded="false"><span class="tgn">Rig &amp; Control</span><span class="tgc"></span><i class="tgv">&#9662;</i></button><div class="tgm"><button data-tab="rig">Tonight's Rig</button><button data-tab="skip">Strobe</button><button data-tab="apc">APC mini</button><button data-tab="apc40">APC40</button><button data-tab="speed">Speed Faders</button></div></div><div class="tg" data-g="edit"><button class="tgb" aria-haspopup="true" aria-expanded="false"><span class="tgn">Editors</span><span class="tgc"></span><i class="tgv">&#9662;</i></button><div class="tgm"><button data-tab="scene">Scene Editor</button><button data-tab="move">Movement Editor</button><button data-tab="look">Looks</button><button data-tab="health">Health Check</button></div></div></nav>
  <div class="hright"><button id="aupill" class="mini" style="display:none" title="Auto Show is playing"></button><div id="sx" class="pill ok">Checking ShowXpress&hellip;</div><button id="sxgo" class="mini" style="display:none">&#9654; Launch ShowXpress</button><button id="sxstop" class="mini" style="display:none">&#9632; Close ShowXpress</button><button id="upd" class="mini primary" style="display:none"></button><button id="cog" class="mini cog" title="Settings">&#9881;</button></div></header>
<div id="qbar" class="qbar"></div>
<main>
 <div class="view" id="v-home">
  <section class="hero2"><div class="in">
   <img class="hlogo2" data-img="logo" alt="SX Studio">
   <div><div class="hsub">Lighting control for ShowXpress</div><div class="hver" id="hver">&nbsp;</div></div><div class="grow"></div>
   <div id="brand" class="brand"><div class="brandtxt">XSV<span>PRODUCTIONS</span></div></div></div></section>
  <div class="hgrp"><div class="hsec">Before the gig</div></div>
  <div class="htiles hgrp">
   <button class="ht" data-go="rt"><i class="st">STEP 01</i><b>Rig Test</b><span>Which mover hangs where &rarr; 2D view, Tonight&rsquo;s Rig and Strobe</span></button>
   <button class="ht" data-go="aim"><i class="st">STEP 02</i><b>Aim Movers</b><span>Fit the dance floor and AROUND ROOM to tonight&rsquo;s venue</span></button>
   <button class="ht" data-go="color"><i class="st">STEP 03</i><b>Tonight&rsquo;s Color</b><span>The decor colour on the movers and uplights</span></button>
   <button class="ht" data-go="pre"><i class="st">STEP 04</i><b>Pre-show Check</b><span>One look before the guests arrive</span></button>
  </div>
  <div class="hgrp"><div class="hsec">Live</div></div>
  <div class="htiles hgrp">
   <button class="ht" data-go="lab"><i class="lv">PLAY</i><b>SX Player</b><span>Play your show&rsquo;s buttons straight to the lights, with ShowXpress closed</span></button>
   <button class="ht" data-go="auto"><i class="lv">AUTO</i><b>Auto Show</b><span>Your looks change every few bars while you mix</span></button>
  </div>
  <div class="hgrp"><div class="hsec">Show tools</div></div>
  <div class="htiles hgrp">
   <button class="ht" data-go="rig"><i>RIG</i><b>Tonight&rsquo;s Rig</b><span>Which heads are hung tonight</span></button>
   <button class="ht" data-go="skip"><i>RIG</i><b>Strobe</b><span>The heads the SKIP FLASH button uses</span></button>
   <button class="ht" data-go="apc"><i>CONTROL</i><b>APC mini</b><span>Move pads and pick their colours</span></button>
   <button class="ht" data-go="apc40"><i>CONTROL</i><b>APC40</b><span>Your own pages of pads for the APC40</span></button>
   <button class="ht" data-go="speed"><i>CONTROL</i><b>Speed Faders</b><span>Which fader drives which button</span></button>
   <button class="ht" data-go="health"><i>SHOW</i><b>Health Check</b><span>Find and fix problems in the show</span></button>
   <button class="ht" data-go="scene"><i>SHOW</i><b>Scene Editor</b><span>Change a scene and see it on the lights</span></button>
   <button class="ht" data-go="move"><i>SHOW</i><b>Movement Editor</b><span>Change a movement&rsquo;s shape and speed</span></button>
   <button class="ht" data-go="look"><i>SHOW</i><b>One-click Looks</b><span>Make a new scene from a template</span></button>
   <button class="ht" data-go="settings"><i>SETUP</i><b>&#9881; Settings</b><span>Google Drive, phone &amp; iPad, tabs, light mode, export &amp; import</span></button>
  </div>
 </div>

 <div class="view" id="v-settings">
  <section class="card"><h2>&#9881; Settings</h2><p class="sub" style="margin:0">Light or dark is set for each device. The tab order is the same on this computer, the phone and the iPad.</p></section>
  <section class="card setsec"><h2>Look</h2><p class="sub">Light is easier to read in daylight; dark is kinder in a dark venue.</p>
   <div class="seg" id="stheme"><button data-v="dark">&#127769; Dark</button><button data-v="light">&#9728;&#65039; Light</button><button data-v="auto">Same as this device</button></div></section>
  <section class="card setsec"><div class="row"><div class="grow"><h2>Tabs</h2><p class="sub" style="margin:0">The tabs are in four menus along the top. Drag &#9776; or use the arrows to change the order in a menu, and click a name to rename the tab (Enter to keep it, empty = its own name again). Untick a tab to hide it (it leaves the Home page too).</p></div><button id="stabreset" class="mini">Reset</button></div><div id="stabs" class="tablist"></div></section>
  <section class="card setsec" id="gdcard"><div class="row"><div class="grow"><h2>Google Drive</h2><p class="sub" id="gdacct" style="margin:0">Looking for Google Drive&hellip;</p></div>
   <div class="pc-only" style="display:flex;gap:6px;flex-wrap:wrap"><button id="gdapp" class="mini" style="display:none">Open Google Drive</button><button id="gddl" class="mini">Get Google Drive</button></div></div>
   <div class="row" style="margin-top:14px;align-items:flex-start"><div class="grow"><p class="sub" id="gdsub" style="margin:0">&nbsp;</p><div id="gdhint" class="summary"></div></div>
    <div style="display:flex;flex-direction:column;gap:6px"><button id="gdsync" class="primary" disabled>Sync to Google Drive</button><button id="gdimp" disabled>Import from Google Drive</button></div></div>
   <details class="pc-only"><summary>Google Drive folder and import backups</summary>
    <div class="row" style="margin-top:10px"><input id="gdfold" class="txt" style="flex:1;min-width:220px" placeholder="Found automatically"><button id="gdfoldset" class="mini">Use this folder</button><button id="gdfoldauto" class="mini">Find automatically</button></div>
    <p class="sub" style="margin:6px 0 0">Google Drive&rsquo;s <b>My Drive</b> folder (the one with AWAAZ in it). Only needed if SX Studio can&rsquo;t find Google Drive by itself.</p>
    <div class="row" style="margin-top:10px"><button id="gdbk" class="mini">Open import backups</button><span class="summary">The show as it was before each import (newest 3).</span></div></details></section>
  <section class="card setsec" id="phcard"><div class="row"><div class="grow"><h2>&#128241; Phone &amp; iPad</h2><p class="sub" style="margin:0">Use SX Studio from your iPhone or iPad on the same Wi-Fi &mdash; rig setup, aim live with your finger, tonight&rsquo;s colour, the pre-show check and the Auto Show.</p></div>
   <label class="link"><input type="checkbox" id="phon"> Let my phone and iPad connect</label></div><div id="phbody"></div></section>
  <section class="card setsec pc-only"><h2>ShowXpress</h2>
   <label class="link"><input type="checkbox" id="sreopen"> After queued changes are done, open ShowXpress again</label>
   <div class="row" style="margin-top:12px"><button id="sopenshow" class="mini">Open the show folder</button><span class="summary" id="sshow"></span></div></section>
  <section class="card setsec pc-only"><h2>Updates</h2><div class="row"><div class="grow summary" id="supd">&nbsp;</div><button id="supdchk" class="mini">Check now</button></div>
   <label class="link" style="margin-top:10px"><input type="checkbox" id="sautoupd"> Check for a new version when SX Studio opens</label></section>
  <section class="card setsec pc-only"><h2>Export &amp; import settings</h2><p class="sub">Save everything you set up in SX Studio in one file, and load it again later or on another computer: the tabs (order, names, hidden), the SX Player pages and your own player pages, the APC40 pads and faders, the APC mini pads and their colours, which speed fader each button follows, the Auto Show, the options above, phone access on or off, and this computer&rsquo;s own choices (light or dark, Looks options, live-aim view). Not in it: the show itself (scenes, movements, aims, Tonight&rsquo;s Rig and Color &mdash; Google Drive sync keeps those) and the phone pairing code. The APC mini pads and speed faders are saved in ShowXpress&rsquo;s live board, so while ShowXpress is open they wait until it&rsquo;s closed.</p>
   <div class="row"><button id="sexp" class="primary">&#11015; Export settings</button><button id="simp">&#11014; Import settings</button><input type="file" id="simpf" accept=".json,application/json" style="display:none"><span class="summary grow" id="scfg"></span></div></section>
 </div>

 <div class="view" id="v-lab">
  <section class="card"><div class="row" style="align-items:flex-start"><div class="grow"><h2>SX Player</h2>
   <p class="sub" style="margin:0">Plays your show&rsquo;s scenes and movements straight to the DMX interface, with ShowXpress closed &mdash; nothing in the show is changed. Tap a button to start it, tap again to stop; on a MOVEMENTS page one replaces the other. A movement only moves what it&rsquo;s set to (usually pan/tilt), so tap a colour scene as well. While it plays, the <b>APC mini</b> pads and speed faders, the keyboard keys, <b>BPM</b> (tap, type or VirtualDJ) and the <b>Auto Show</b> all work.</p>
   <details style="margin-top:8px"><summary>At a gig</summary><p class="sub" style="margin:8px 0 0"><b>Hand over to ShowXpress</b> stops the player and opens ShowXpress straight away, and ShowXpress carries on with what was playing (starting the player does the same the other way round). If the DMX interface gets unplugged the player waits and carries on when it&rsquo;s plugged back in; if the player itself stops, SX Studio starts it again; if someone opens ShowXpress, the player hands over to it. The laptop doesn&rsquo;t sleep while the player runs, and closing this window doesn&rsquo;t stop the lights &mdash; open SX Studio again from its icon. Scenes, chases and movements were checked against ShowXpress&rsquo;s own DMX output; which button wins when two use the same light isn&rsquo;t measured yet.</p></details></div>
   <button id="lbarr" class="mini" title="Order, hide and add pages and buttons (only here - ShowXpress's live screen stays as it is)">&#8645; Arrange</button></div>
   <div class="row" style="margin-top:14px;gap:8px;flex-wrap:wrap" id="lbctl"></div><div id="lbmsg" class="summary" style="margin-top:8px"></div></section>
  <section class="card" id="lbbpm" style="display:none"></section>
  <section class="card" id="lbfd" style="display:none"></section>
  <div class="arrbar" id="lbarrbar"><b>Arrange</b> Drag a button to move it inside its page; the arrows move a whole page, and <b>Hide</b> takes a page out of the player. <b>New page</b> makes a page that&rsquo;s only in the SX Player, with copies of any of the show&rsquo;s buttons. Every change shows and is saved straight away (for this computer, the phone and the iPad) &mdash; press <b>Done</b> when you&rsquo;re finished. ShowXpress and its live screen stay exactly as they are.<div class="grow"></div><button id="lbnewpg" class="mini">+ New page</button><button id="lbarrreset" class="mini">Reset to ShowXpress&rsquo;s order</button><button id="lbarrdone" class="mini son">&#10003; Done</button></div>
  <section class="card idle" id="lbpages"><p class="sub" style="margin:0">Loading&hellip;</p></section>
  <div class="lbtoast" id="lbtoast"></div>
 </div>

 <div class="view" id="v-aim">
  <div class="seg"><button data-am="floor" class="on">Dance Floor</button><button data-am="room">Room</button></div>
  <section class="card">
    <h2 id="aimttl">Dance floor &mdash; tonight's aims</h2>
    <p class="sub">Read from the scene <b id="aimsc">DF AIM (ADJUST)</b> in ShowXpress.</p>
    <div class="how" id="aimhow">
      <div><b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight's dancefloor &mdash; or just <b>one head per T-bar</b>: the head next to it gets the same aim (unless you aim that one too).</div>
      <div><b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size. A copied head gets this too.</div>
      <div><b>THEN</b>Save, close ShowXpress, press Refresh below, check the heads and Apply &mdash; <b>DF CHECK</b> comes on by itself when ShowXpress opens again.</div>
    </div>
    <div id="aimrem" class="remrow"></div>
    <div class="lvcall" id="lvcall"><div class="grow"><b>&#9678; Aim live</b> &mdash; aim from here instead of ShowXpress: slow, fine mouse control, and the real head follows as you drag. ShowXpress closes while you aim and opens again when you finish.</div><button id="lvgo" class="primary" style="padding:9px 20px;font-size:14px;white-space:nowrap">&#9678; Aim live</button></div>
    <div class="row"><div id="summary" class="summary grow">Loading&hellip;</div><button id="refresh">&#8635; Refresh</button></div>
    <div id="heads"></div>
    <div id="warnbox" class="warnbox"></div>
    <div id="aiminst" class="warnbox"></div>
  </section>

  <section class="card">
    <h2>Overall pattern size</h2>
    <p class="sub" id="sizesub">100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.</p>
    <div class="sizegrid">
      <div>
        <div class="slider"><div class="top"><label>Width</label><input id="wn" class="num" type="number" min="20" max="300"></div><input id="w" type="range" min="20" max="300" step="1"></div>
        <div class="slider"><div class="top"><label id="dlab">Depth</label><input id="dn" class="num" type="number" min="20" max="300"></div><input id="d" type="range" min="20" max="300" step="1"></div>
        <div class="row"><label class="link"><input id="lnk" type="checkbox" checked> Same both ways</label><div class="grow"></div>
          <div class="chips"><span class="chip" data-v="80">80</span><span class="chip" data-v="90">90</span><span class="chip" data-v="100">100</span><span class="chip" data-v="110">110</span><span class="chip" data-v="120">120</span></div></div>
      </div>
      <svg viewBox="0 0 300 210" aria-label="size preview">
        <text x="150" y="16" fill="#5d6574" font-size="10" text-anchor="middle">DJ / front</text>
        <rect id="floor" x="60" y="45" width="180" height="120" fill="none" stroke="#5d6574" stroke-dasharray="5 4" rx="4"/>
        <rect id="pat" x="60" y="45" width="180" height="120" fill="rgba(255,176,32,.16)" stroke="#ffb020" stroke-width="2" rx="6"/>
        <circle cx="150" cy="105" r="4" fill="#ffb020"/>
        <text id="svgl" x="150" y="200" fill="#5d6574" font-size="10" text-anchor="middle">dashed = dancefloor &middot; amber = patterns</text>
      </svg>
    </div>
  </section>
 </div>

 <div class="view" id="v-rt">
  <section class="card">
    <div class="row"><div class="grow"><h2>Rig test &mdash; which mover is where</h2>
      <p class="sub" style="margin-bottom:0"><b>1.</b> <b>RIG ID</b> comes on in ShowXpress by itself (green bar below &mdash; or press it on the SETUP page): every 140 lights in its own look (key below). <b>2.</b> Tap each truss spot and pick the look you see on that head. <b>3.</b> Close ShowXpress (save first) and press <b>Save to 2D view</b>.</p></div>
      <span id="rtstate" class="state ok" style="display:none"></span><button id="rtrefresh">&#8635; Refresh</button></div>
    <div id="rtrem" class="remrow" style="margin:12px 0 0"></div>
    <div id="rterr" class="warnbox"></div>
    <div id="rtinst" class="warnbox"></div>
    <div id="rtlegend" class="legend2"></div>
    <div id="rtmap" class="rtmap"></div>
    <div class="row" style="margin-top:12px"><label class="link"><input id="rtextra" type="checkbox"> Bigger event: 2 extra towers (top middle and bottom middle)</label><div class="grow"></div>
      <label class="link"><input id="rtrig" type="checkbox" checked> Also update Tonight's Rig and Strobe (heads not on a truss = not hung)</label></div>
  </section>
 </div>

 <div class="view" id="v-pre">
  <section class="card">
    <h2>Pre-show check</h2>
    <p class="sub">One look before the guests arrive: the show, your gear and the laptop. Checking changes nothing.</p>
    <div id="presum" class="summary"></div>
    <div id="prelist"></div>
  </section>
 </div>

 <div class="view" id="v-color">
  <section class="card">
    <div class="row"><div class="grow"><h2>Tonight's color</h2>
      <p class="sub" style="margin-bottom:0">The decor colour for tonight. Saving makes two ShowXpress buttons called <b>TONIGHTS COLOR</b>: on the MOVER COLORS page (every mover on the nearest colour of its wheel, colour only &mdash; it goes on top of any movement) and on the UPLIGHTS page (the uplights in exactly this colour).</p></div>
      <span id="clstate" class="state ok" style="display:none"></span><button id="clrefresh">&#8635; Refresh</button></div>
    <div id="clerr" class="warnbox"></div>
    <div class="clwrap">
      <div>
        <div class="gh"><h3>QUICK PICKS</h3></div><div id="clpal" class="clpal"></div>
        <div class="gh" style="margin-top:18px"><h3>ANY COLOUR</h3></div>
        <div class="row" style="align-items:flex-start;gap:22px"><div id="clwheel" class="wheel"><i id="clknob"></i></div>
          <div><div class="row"><input id="clpick" type="color" title="Colour picker"><input id="clhex" class="srch" style="width:110px" maxlength="7" placeholder="#RRGGBB"></div>
            <div class="slider" style="width:230px"><div class="top"><label>Brightness</label></div><input id="clval" type="range" min="10" max="100" step="1"></div>
            <p class="sub" style="margin:0;max-width:240px">Tap or drag on the wheel. The uplights get exactly this colour; the movers only have their wheel colours.</p></div></div>
      </div>
      <div><div id="clbig" class="clbig"></div>
        <input id="clname" class="srch" style="width:100%" maxlength="30" placeholder="Name (optional), e.g. Blush">
        <div id="clmap" class="kv" style="grid-template-columns:86px 1fr"></div>
        <button id="clprev" style="margin-top:12px;width:100%">&#128161; Show it on the lights</button>
        <div id="clpv" class="clpv"><span class="dot"></span><b class="grow">Live on the lights</b><button id="clpvstop" class="mini">Stop</button>
          <label style="flex-basis:100%;display:flex;gap:6px;align-items:center;color:var(--dim)"><input type="checkbox" id="clreo"> Open ShowXpress again when I stop</label>
          <span style="flex-basis:100%;color:var(--dim)">ShowXpress is closed while this is on. Movers go to the dance-floor center on their nearest wheel colour.</span></div></div>
    </div>
  </section>
 </div>

 <div class="view" id="v-skip">
  <section class="card">
    <div class="row"><div class="grow"><h2>Strobe heads</h2>
      <p class="sub" style="margin-bottom:0">Tap the movers that are set up tonight. <b>SKIP FLASH</b> will only flash those, so the chase has no dark gaps.</p></div>
      <span id="skstate" class="state ok" style="display:none"></span><button id="skrefresh">&#8635; Refresh</button></div>
    <div id="skerr" class="warnbox"></div>
    <div id="skgroups"></div>
  </section>
  <section class="card">
    <div class="row"><h2 class="grow" style="margin:0">Flash order</h2><div id="sksum" class="summary"></div></div>
    <div id="skorder" class="order"></div>
    <p class="sub" style="margin:10px 0 0">The order and the step time come from your scene &mdash; only the list of heads changes.</p>
  </section>
 </div>

 <div class="view" id="v-rig">
  <section class="card">
    <div class="row"><div class="grow"><h2>Tonight's rig</h2>
      <p class="sub" style="margin-bottom:0">Tap the movers that are hung tonight. Every chase scene (CHASE, SKIP AROUND, the BEAT scenes, SKIP FLASH&hellip;) drops the steps that would be dark without them, so nothing stutters. Tick them all again to put every scene back.</p></div>
      <span id="rgstate" class="state ok" style="display:none"></span><button id="rgrefresh">&#8635; Refresh</button></div>
    <div id="rgerr" class="warnbox"></div>
    <div id="rggroups"></div>
  </section>
  <section class="card">
    <div class="row"><div class="grow"><h2>Reversed heads</h2>
      <p class="sub" style="margin-bottom:0">Use this instead of Pan / Tilt Reverse in a fixture&rsquo;s own menu. A head hung so it moves the same way as its partner? Tap <b>&harr; pan</b> (or <b>&varr; tilt</b>) on it: every scene and movement in the show is flipped for that head &mdash; exactly what the fixture&rsquo;s menu does. Tap again to put it back. Leave the fixture&rsquo;s own menu as it is, and set this <b>before</b> you aim the movers.</p></div></div>
    <div id="rgflip"></div>
  </section>
  <section class="card">
    <div class="row"><h2 class="grow" style="margin:0">Chase scenes</h2><div id="rgsum" class="summary"></div></div>
    <div id="rgscenes" class="scenes"></div>
    <p class="sub" style="margin:10px 0 0"><i class="sw" style="background:var(--amber)"></i>movers lit &nbsp; <i class="sw" style="background:var(--blue)"></i>blinder / uplight only &nbsp; <i class="sw" style="background:#262b36"></i>dark &nbsp; <i class="sw" style="border:1px dashed var(--red)"></i>taken out tonight.
      Only whole steps are taken out &mdash; colours and timing stay as they are. A step that also lights a blinder or uplight is always kept.</p>
  </section>
 </div>

 <div class="view" id="v-apc">
  <section class="card">
    <div class="row"><div class="grow"><h2>APC mini pads</h2>
      <p class="sub" style="margin-bottom:0">The 8&times;8 grid as it sits on the controller (top row first), in each pad's own colours. Tap a pad, then tap where it should go &mdash; or pick its colours.</p></div>
      <span id="apstate" class="state ok" style="display:none"></span><button id="aprefresh">&#8635; Refresh</button></div>
    <div id="aperr" class="warnbox"></div>
    <div class="apcwrap"><div id="apgrid" class="apc"></div><div id="apside" class="apside"></div></div>
    <div id="apfaders" class="faders"></div>
  </section>
  <section class="card"><h2>Pad problems</h2><div id="apissues"></div></section>
 </div>

 <div class="view" id="v-apc40">
  <section class="card">
    <div class="row"><div class="grow"><h2>APC40 pads</h2>
      <p class="sub" style="margin-bottom:0">Up to 8 pages of your own, 40 pads each &mdash; put any ShowXpress button on any pad. On the APC40 the numbered <b>Track Select</b> buttons under the pads switch pages. A pad turns its button on (press again for off) and shows its ShowXpress colour (or a colour you pick for that pad), bright while it&rsquo;s on. The top <b>Scene Launch</b> button is green while ShowXpress is connected. The APC mini, ShowXpress&rsquo;s pages and the show aren&rsquo;t changed.</p></div>
      <span id="a4state" class="state ok" style="display:none"></span><button id="a4refresh">&#8635; Refresh</button></div>
    <div id="a4err" class="warnbox"></div>
    <div id="a4conn" class="a4conn"></div>
    <div id="a4pages" class="a4pages"></div>
    <div class="apcwrap"><div id="a4grid" class="apc a4grid"></div><div id="a4side" class="apside"></div></div>
  </section>
  <section class="card"><h2>APC40 faders</h2>
    <p class="sub">What each fader moves in ShowXpress (its master faders). A speed fader&rsquo;s middle is normal speed: down = slower, up = faster.</p>
    <div id="a4faders" class="faders"></div>
  </section>
 </div>

 <div class="view" id="v-speed">
  <section class="card">
    <div class="row"><div class="grow"><h2>Speed faders</h2>
      <p class="sub" style="margin-bottom:0">Which master speed fader each button follows. Faders only change step timing, so 1-step scenes don't react.</p></div>
      <span id="spstate" class="state ok" style="display:none"></span><button id="sprefresh">&#8635; Refresh</button></div>
    <div id="sperr" class="warnbox"></div>
    <div class="row" style="margin-top:14px"><div id="splegend" class="legend grow"></div><input id="spq" class="srch" type="search" placeholder="Find a button&hellip;"></div>
    <div id="splist"></div>
  </section>
 </div>

 <div class="view" id="v-auto">
  <section class="card">
   <div class="row"><div class="grow"><h2>Auto Show</h2><p class="sub" style="margin:0">SX Studio presses your <b>looks</b> in ShowXpress one after another, each for a number of bars &mdash; for the stretches when you&rsquo;re busy mixing. A look is a few buttons that play together (a movement, a colour, uplights&hellip;). Whatever you press yourself on the APC still works on top. Tap the BPM to the music and press <b>Bar 1 now</b> on a downbeat to line the changes up.</p></div><span id="austate" class="state ok" style="display:none"></span></div>
   <div id="auerr" class="warnbox"></div><div id="aurem" class="warnbox"></div>
   <div id="auplay" class="auplay"></div>
  </section>
  <section class="card">
   <div class="row"><div class="grow"><h2>Looks</h2><p class="sub" style="margin:0" id="ausum"></p></div><button id="aunew">+ New look</button><button id="augrab">&#8681; New look from what&rsquo;s playing</button></div>
   <div id="aulooks"></div>
   <div class="row" style="margin-top:16px;gap:14px">
    <span class="sub" style="margin:0">Order</span><div class="seg"><button data-ao="order">In order</button><button data-ao="shuffle">Shuffle</button></div>
    <span class="sub" style="margin:0">When I stop</span><select id="austop" style="width:auto"><option value="keep">Leave the last look playing</option><option value="off">Turn the look off</option></select>
    <label class="link"><input type="checkbox" id="auclean"> At start, turn off everything else that&rsquo;s playing</label></div>
   <div id="aumsg" class="sub" style="margin:10px 0 0"></div>
  </section>
 </div>

 <div class="view" id="v-health">
  <section class="card">
    <h2>Show health check</h2>
    <p class="sub">Looks through the whole show for things that have caused trouble before: missing scenes, broken beat settings, APC pads that fire two buttons, colour chases that spin the wheel&hellip; Checking changes nothing. Each problem shows a recommended fix; where the helper can do it for you there's a button, and every fix can be reverted.</p>
    <div id="hlapplied"></div>
    <div id="hlsum" class="summary"></div>
    <div id="hllist" style="margin-top:10px"></div>
  </section>
 </div>

  <section id="result" class="card result"><h2 id="rtitle"></h2><div id="rbody"></div><details><summary>Full details</summary><pre id="rlog"></pre></details></section>
  <div class="foot" id="foot"></div>
 <div class="view" id="v-scene">
  <section class="card">
    <div class="row"><div class="grow"><h2 id="setitle">Scene Editor</h2>
      <p class="sub" style="margin-bottom:0">Change a scene&rsquo;s steps and values and see it on the lights. Saving changes only what you changed in the scene file &mdash; everything else in it stays exactly as ShowXpress wrote it.</p></div>
      <span id="sestate" class="state ok" style="display:none"></span><button id="seback" style="display:none">&#8592; All scenes</button><button id="serefresh">&#8635; Reload</button></div>
    <div id="seerr" class="warnbox"></div>
    <div id="sepickw"><div class="row" style="margin-top:14px"><div class="sub grow" id="secount" style="margin:0"></div><input id="seq" class="srch" type="search" placeholder="Find a scene or button&hellip;"></div>
      <div id="selist" class="scenes"></div></div>
    <div id="sew" style="display:none">
      <div id="seinfo" class="sub" style="margin:8px 0 0"></div>
      <div id="sewarn" class="warnbox"></div>
      <div id="seedit">
        <div class="sepv" id="sepv"><b>&#9678; On the lights</b><span class="sub grow" style="margin:0" id="sepvsub">See the step you&rsquo;re on as you change it, or play the whole scene. ShowXpress is closed while this runs; nothing is saved until you press Save.</span>
          <span id="sepvif" class="tag amber" style="display:none"></span><label class="link" style="display:none" id="sepvreow"><input type="checkbox" id="sepvreo"> Open ShowXpress again when I stop</label>
          <button class="mini" id="sepvgo">Show on the lights</button><button class="mini" id="sepvplay" style="display:none"></button><button class="mini" id="sepvstop" style="display:none">&#9632; Stop</button></div>
        <div class="gh"><h3>STEPS</h3><span class="cnt" id="secnt"></span></div>
        <div class="sesteps" id="sesteps"></div>
        <div class="row" style="margin-top:10px">
          <button class="mini" id="seleft">&#9664; Move</button><button class="mini" id="seright">Move &#9654;</button><button class="mini" id="secopy">Copy step</button><button class="mini" id="sedel">Delete step</button>
          <div class="grow"></div><label class="link" style="cursor:default">Step time <input id="selen" class="num" type="number" min="0.01" step="0.01" style="width:84px;font-size:13px"> s</label><button class="mini" id="selenall">Same for every step</button></div>
        <div class="segrid" id="segrid"></div>
        <div class="sewrap">
          <div class="seheads"><div class="row"><b class="grow">Heads</b><button class="mini" id="seall">All</button><button class="mini" id="senone">None</button></div><div id="sehl"></div></div>
          <div class="sech"><div id="sechs"></div>
            <div class="row" style="margin-top:12px" id="seaddw"><select id="seadd" style="width:auto;flex:1;max-width:260px"></select><button class="mini" id="seaddb">Add channel</button><span class="sub" style="margin:0">to these heads, in every step</span></div></div>
        </div>
      </div>
    </div>
  </section>
  <section class="card" id="sebk" style="display:none"><h2>Earlier versions</h2><p class="sub">Every save keeps the scene as it was just before. Revert puts one back (with ShowXpress closed).</p><div id="sebkl" class="scenes"></div></section>
 </div>
 <div class="view" id="v-move">
  <section class="card">
    <div class="row"><div class="grow"><h2 id="mvtitle">Movement Editor</h2>
      <p class="sub" style="margin-bottom:0">Change a movement&rsquo;s shape, speed and the way the heads follow each other, and see it on the lights. Saving changes only what you changed in the movement file &mdash; everything else in it stays exactly as ShowXpress wrote it.</p></div>
      <span id="mvstate" class="state ok" style="display:none"></span><button id="mvback" style="display:none">&#8592; All movements</button><button id="mvrefresh">&#8635; Reload</button></div>
    <div id="mverr" class="warnbox"></div>
    <div id="mvpickw"><div class="row" style="margin-top:14px"><div class="sub grow" id="mvcount" style="margin:0"></div><input id="mvq" class="srch" type="search" placeholder="Find a movement or button&hellip;"></div>
      <div id="mvlist" class="scenes"></div></div>
    <div id="mvw" style="display:none">
      <div id="mvinfo" class="sub" style="margin:8px 0 0"></div>
      <div id="mvwarn" class="warnbox"></div>
      <div id="mvnote" class="mvnote" style="display:none"></div>
      <div id="mvedit">
        <div class="sepv" id="mvpv"><b>&#9678; On the lights</b><span class="sub grow" style="margin:0" id="mvpvsub">See the movement on the rig as you change it. ShowXpress is closed while this runs; nothing is saved until you press Save.</span>
          <label class="link" style="cursor:default">Light it with <select id="mvlite" style="width:auto;max-width:220px"></select></label>
          <span id="mvpvif" class="tag amber" style="display:none"></span><label class="link" style="display:none" id="mvpvreow"><input type="checkbox" id="mvpvreo"> Open ShowXpress again when I stop</label>
          <button class="mini" id="mvpvgo">Show on the lights</button><button class="mini" id="mvpvstop" style="display:none">&#9632; Stop</button></div>
        <div class="gh"><h3>CHANNELS</h3><span class="cnt">only the ones that play are sent to the lights</span></div>
        <div class="sesteps" id="mvsecs"></div>
        <div class="mvwrap">
          <div><div class="mvcvw" id="mvcvw"><canvas id="mvcv" data-kind="pt"></canvas></div>
            <div id="mvlock" class="warnbox">The points of this channel are written in a way SX Studio doesn&rsquo;t change, so they can only be edited in ShowXpress. Its other settings can be changed here.</div>
            <div class="sub" id="mvcvhint" style="margin:6px 0 0;font-size:12px"></div>
            <div class="mvtools" id="mvtools"><button class="mini" id="mvsmall">Smaller</button><button class="mini" id="mvbig">Bigger</button><button class="mini" id="mvflipx">Mirror &harr;</button><button class="mini" id="mvflipy">Mirror &varr;</button><button class="mini" id="mvrev">Reverse direction</button><button class="mini" id="mvcentre">Centre</button></div>
            <div class="mvtools"><button class="mini" id="mvhold">&#10074;&#10074; Pause</button><button class="mini" id="mvsync">Start again</button><button class="mini" id="mvfit">Zoom to the shape</button><button class="mini" id="mvwhole">Whole range</button><div class="grow"></div><button class="mini" id="mvstep">&#8630; Step back</button></div></div>
          <div class="mvside"><b id="mvsech"></b>
            <label class="mvf"><span>Plays</span><input type="checkbox" id="mvsel"></label>
            <label class="mvf"><span>Between points</span><select id="mvtr"><option value="2">Smooth curve</option><option value="1">Straight lines</option><option value="0">Jump</option></select></label>
            <label class="mvf"><span>Once round in</span><span><input id="mvdur" class="num" type="number" min="0.1" step="0.1"> s</span></label>
            <label class="mvf"><span>Each next head behind by</span><span><input id="mvshift" class="num" type="number" min="0" max="100" step="0.5"> %</span></label>
            <div id="mvpt" style="display:none"><div style="border-top:1px solid var(--line);padding-top:9px;display:grid;gap:9px"><b id="mvptn"></b>
              <label class="mvf"><span id="mvpxl">Pan</span><input id="mvpx" class="num" type="number" min="0" step="1"></label>
              <label class="mvf"><span id="mvpyl">Tilt</span><input id="mvpy" class="num" type="number" min="0" step="1"></label>
              <button class="mini" id="mvpdel" style="justify-self:start">Delete point</button></div></div></div>
        </div>
        <div class="gh"><h3>HEADS</h3><span class="cnt" id="mvhcnt"></span></div>
        <div class="mvheads" id="mvhl"></div>
      </div>
    </div>
  </section>
  <section class="card" id="mvbk" style="display:none"><h2>Earlier versions</h2><p class="sub">Every save keeps the movement as it was just before. Revert puts one back (with ShowXpress closed).</p><div id="mvbkl" class="scenes"></div></section>
 </div>

 <div class="view" id="v-look">
  <section class="card">
    <div class="row"><div class="grow"><h2>One-click Looks</h2>
      <p class="sub" style="margin-bottom:0">Make a new scene from a template and see it on the lights first. It&rsquo;s always a <b>new</b> scene file &mdash; no scene you have is changed, and ShowXpress&rsquo;s live board isn&rsquo;t touched: put the look on a button in ShowXpress, or on one of the SX Player&rsquo;s own pages.</p></div>
      <button id="lkrefresh">&#8635; Reload</button></div>
    <div id="lkerr" class="warnbox"></div>
    <div id="lkw" style="display:none">
      <div class="lktpl" id="lktpl">
        <button data-lt="contrast"><b>Contrast pairs</b><span>Two colours side by side, swapping</span></button>
        <button data-lt="chase"><b>Colour chase</b><span>One colour after another, back and forth</span></button>
        <button data-lt="strobe"><b>Strobe</b><span>One flash each beat, or a steady strobe</span></button>
        <button data-lt="prism"><b>Prism fan</b><span>Spinning prisms, no colour of its own</span></button>
      </div>
      <div class="lkgrid">
        <div class="lkopts" id="lkopts"></div>
        <div>
          <div class="gh" style="margin-top:0"><h3>HEADS</h3><span class="cnt" id="lkhcnt"></span></div>
          <div class="chips" id="lkgroups"></div>
          <div class="gh"><h3>HOW IT LOOKS</h3><span class="cnt" id="lkinfo"></span></div>
          <div class="lkvis" id="lkvis"></div>
        </div>
      </div>
      <div class="sepv" id="lkpv"><b>&#9678; On the lights</b><span class="sub grow" style="margin:0" id="lkpvsub">See the look on the rig before you make it. ShowXpress is closed while this runs; nothing is written until you press Make.</span>
        <span id="lkpvif" class="tag amber" style="display:none"></span><label class="link" style="display:none" id="lkpvreow"><input type="checkbox" id="lkpvreo"> Open ShowXpress again when I stop</label>
        <button class="mini" id="lkpvgo">Show on the lights</button><button class="mini" id="lkpvstop" style="display:none">&#9632; Stop</button></div>
      <div class="row" style="margin-top:14px;gap:10px;flex-wrap:wrap"><b style="font-size:13px">Name of the new scene</b><input id="lkname" class="srch" style="flex:1;min-width:200px;max-width:420px;font-size:14px" maxlength="100" spellcheck="false"><span class="sub" id="lknamehint" style="margin:0"></span></div>
    </div>
  </section>
  <section class="card" id="lkdone" style="display:none"></section>
 </div>

</main>
<div class="ctxm" id="ctxm"></div>
<div class="bar"><div class="in" data-for="home"><div class="hint grow">Pick a tab above to start. Nothing in the show changes until you save in a tab.</div></div>
  <div class="in" data-for="color"><button id="clsave" class="primary">Save tonight's color</button><button id="clundo">Undo changes</button><div class="hint grow" id="clhint"></div></div>
  <div class="in" data-for="rt"><button id="rtsave" class="primary">Save to 2D view</button><button id="rtclear">New event (clear spots)</button><button id="rtundo">Undo changes</button><div class="hint grow" id="rthint"></div></div>
  <div class="in" data-for="pre"><button id="prerun" class="primary">Check again</button><button id="pregd">Sync to Google Drive</button><div class="hint grow" id="prehint"></div></div>
  <div class="in" data-for="aim"><button id="apply" class="primary">Apply to show</button><button id="home">Reset to normal</button><div class="hint grow" id="hint"></div></div>
  <div class="in" data-for="skip"><button id="sksave" class="primary">Save to SKIP FLASH</button><button id="skundo">Undo changes</button><div class="hint grow" id="skhint"></div></div>
  <div class="in" data-for="rig"><button id="rgsave" class="primary">Save tonight's rig</button><button id="rgall">All heads (put back)</button><button id="rgundo">Undo changes</button><div class="hint grow" id="rghint"></div></div>
  <div class="in" data-for="apc"><button id="apsave" class="primary">Save pads</button><button id="apundo">Undo changes</button><div class="hint grow" id="aphint"></div></div>
  <div class="in" data-for="apc40"><button id="a4save" class="primary">Save APC40 pages</button><button id="a4undo">Undo changes</button><div class="hint grow" id="a4hint"></div></div>
  <div class="in" data-for="speed"><button id="spsave" class="primary">Save speed faders</button><button id="spundo">Undo changes</button><div class="hint grow" id="sphint"></div></div>
  <div class="in" data-for="auto"><button id="ausave" class="primary">Save Auto Show</button><button id="auundo">Undo changes</button><div class="hint grow" id="auhint"></div></div>
  <div class="in" data-for="scene"><button id="sesave" class="primary">Save scene</button><button id="seundo">Undo changes</button><div class="hint grow" id="sehint"></div></div>
  <div class="in" data-for="look"><button id="lkmake" class="primary">Make the scene</button><div class="hint grow" id="lkhint"></div></div>
  <div class="in" data-for="move"><button id="mvsave" class="primary">Save movement</button><button id="mvundo">Undo changes</button><div class="hint grow" id="mvhint"></div></div>
  <div class="in" data-for="health"><button id="hlrun" class="primary">Check again</button><div class="hint grow" id="hlhint"></div></div></div>
<div class="live" id="live">
 <div class="lvtop"><b class="lvt">&#9678; LIVE AIM</b><span id="lvmode" class="sub" style="margin:0"></span><span id="lvif" class="tag amber"></span><div class="grow"></div>
  <label class="link"><input type="checkbox" id="lvreo"> Open ShowXpress again after</label><button id="lvcancel">Cancel</button><button id="lvsave" class="primary" style="padding:9px 20px;font-size:14px">Save &amp; finish</button></div>
 <div id="lvgone" class="lvgone"></div>
 <div class="lvbody">
  <div class="lvlist" id="lvlist"></div>
  <div class="lvmain">
   <div class="row"><div class="seg"><button data-st="c" class="on">1 &middot; CENTER</button><button data-st="k">2 &middot; CORNER <small>optional</small></button></div><div class="grow"></div><span class="sub" style="margin:0">Speed</span><div class="seg"><button data-sp="0.4">Fine</button><button data-sp="1">Normal</button><button data-sp="3">Fast</button></div></div>
   <div class="lvpad" id="lvpad"><div><div class="lvbig" id="lvbig"></div><div id="lvtip"></div></div></div>
   <div class="lvkeys">Hold the mouse button down in the box and drag &middot; <b>Shift</b> = finer &middot; <b>Ctrl</b> = faster &middot; <b>arrow keys</b> nudge &middot; <b>N</b> / <b>P</b> or <b>Tab</b> = next / previous head &middot; <b>1</b> / <b>2</b> = step</div>
  </div>
  <div class="lvside">
   <h3 id="lvname"></h3><div id="lvst" class="sub"></div>
   <div class="kv" id="lvread"></div>
   <svg id="lvmap" viewBox="0 0 240 180"></svg>
   <div class="sub" style="font-size:11.5px">dashed = normal floor &middot; amber = tonight &middot; ring = where it points now</div>
   <div class="lvflip"><label class="link"><input type="checkbox" id="lvfx"> Flip left / right for this head</label><label class="link"><input type="checkbox" id="lvfy"> Flip up / down for this head</label></div>
   <div class="lvbtns"><button id="lvprev">&larr; Previous</button><button id="lvnext" class="primary" style="padding:8px 10px;font-size:13px">Next head &rarr;</button>
    <button id="lvpart" class="w2"></button><button id="lvundo">Undo this head</button><button id="lvhome">Back to normal</button></div>
   <label class="link" style="margin-top:12px"><input type="checkbox" id="lvall"> Light all hung heads (not just this one)</label>
  </div>
 </div>
</div>
<div class="modal" id="rtpick"><div class="box" style="max-width:540px"><h2 id="rtpt"></h2><p class="sub" style="margin:0 0 4px">Pick the look you see on this head.</p><div id="rtpb"></div><div class="row" style="justify-content:flex-end"><button id="rtpnone">Nothing hung here</button><button id="rtpcancel">Cancel</button></div></div></div>
<div class="modal" id="aupk"><div class="box" style="max-width:660px;width:92vw"><h2 id="aupkt"></h2><input id="aupks" class="srch" placeholder="Search buttons&hellip;" style="width:100%"><div id="aupkl" class="pkl"></div><div class="row" style="justify-content:flex-end"><button id="aupkd" class="primary" style="padding:9px 18px;font-size:14px">Done</button></div></div></div>
<div class="modal" id="modal"><div class="box"><h2 id="mt"></h2><p id="mp"></p><div class="row" style="justify-content:flex-end"><button id="mno">Cancel</button><button id="myes" class="primary" style="padding:9px 18px;font-size:14px"></button></div></div></div>
<div class="busy" id="busy"><div class="spin"></div><span id="busyt">Working&hellip;</span></div>
<div class="pair" id="pair"><div class="box"><img src="/icon.png" alt="" class="hlogo" style="width:64px;height:64px"><h2>Connect to the laptop</h2>
 <p class="sub">On the laptop, open <b>SX Studio</b>: press <b>&#9881;</b> (top right), and in <b>Phone &amp; iPad</b> press <b>Pair a phone</b>. Type the 6-digit code here.</p>
 <input id="pairpin" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" maxlength="6" placeholder="------">
 <button id="pairgo" class="primary">Connect</button><div id="pairmsg" class="sub"></div>
 <p class="sub" style="font-size:12px;margin-top:8px">Tip: first add this page to your Home Screen (Share &rarr; <b>Add to Home Screen</b>), then open it from there and pair &mdash; the Home Screen icon keeps its own pairing.</p></div></div>
<div class="offl" id="offl">Can&rsquo;t reach the laptop &mdash; trying again&hellip; (same Wi-Fi? SX Studio still open?)</div>
<div class="gone" id="gone"><h2 style="color:var(--txt)">SX Studio has closed</h2><p>Open it again from its icon.</p></div>
<script>
const PH=__PHONE__||/[?&]phone=1/.test(location.search);   // phone / iPad over the Wi-Fi (phone=1: try the phone layout on the computer)
let T='__TOKEN__';const $=id=>document.getElementById(id);
if(__PHONE__){let ls='';try{ls=localStorage.getItem('sxh_phone_key')||'';}catch(e){}
 const uk=new URLSearchParams(location.search).get('k')||'',ck='__PHONEKEY__';
 T=ck||uk||ls;   // the server only fills ck with the CURRENT key, so it wins over an old one
 if(T){phKeep(T);}}
function phKeep(k){try{localStorage.setItem('sxh_phone_key',k);}catch(e){}
 try{const u=new URL(location.href);if(u.searchParams.get('k')!==k){u.searchParams.set('k',k);history.replaceState(null,'',u.pathname+u.search+location.hash);}}catch(e){}}
if(PH)document.documentElement.classList.add('ph');
let P=null,sxOpen=false,linked=true;
function wq(b){return sxOpen?Object.assign({},b||{},{queue:true}):b;}
async function api(p,body){const r=await fetch(p+(p.includes('?')?'&':'?')+'t='+T,body?{method:'POST',headers:{'Content-Type':'text/plain'},body:JSON.stringify(body)}:{});
 if(r.status===403&&__PHONE__){phUnpaired(await r.text());throw new Error('not paired');}return r.json();}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function sign(v){return (v>0?'+':'')+v;}
function tile(h){const moved=h.op||h.ot,cls=['tile',moved?'moved':'',h.sized?'sized':'',h.warn?'warn':'',h.copyFrom?'copied':''].join(' ');
 return `<div class="${cls}" title="${esc(h.warn||(h.copyFrom?'Not aimed by you - gets the same aim as '+h.copyFrom+' on its T-bar. Aim it yourself and it keeps its own.':''))}"><div class="n">${esc(h.label)}</div>
 <div><span class="l">center </span><span class="v">${moved?sign(h.op)+' / '+sign(h.ot):'normal'}</span></div>
 <div><span class="l">size </span><span class="v sz">${h.sized?h.kp+'% &times; '+h.kt+'%':'normal'}</span></div>`+
 (h.copyFrom?`<div class="cf">&#8644; same as ${esc(h.copyFrom)}</div>`:'')+`</div>`;}
function render(){if(!P)return;
 if(!P.ok){$('summary').innerHTML='<span style="color:var(--red)">'+esc(P.error)+'</span>';$('heads').innerHTML='';$('warnbox').style.display='none';updBar();return;}
 const hs=P.heads,a=hs.filter(h=>h.is140),b=hs.filter(h=>!h.is140),moved=hs.filter(h=>h.op||h.ot).length,sized=hs.filter(h=>h.sized).length,w=hs.filter(h=>h.warn),cp=hs.filter(h=>h.copyFrom).length;
 $('summary').innerHTML=`<b>${a.length}</b> &times; 140SR${b.length?` &middot; <b>${b.length}</b> &times; 251SR`:''} &nbsp;&mdash;&nbsp; <b>${moved}</b> re-aimed${cp?` (<b>${cp}</b> copied from the head next to it on the T-bar)`:''} &middot; <b>${sized}</b> with a corner set`+(w.length?` &middot; <b style="color:var(--red)">${w.length} look wrong</b>`:'');
 $('heads').innerHTML=`<div class="group"><h3>140SR</h3><div class="tiles">${a.map(tile).join('')}</div></div>`+(b.length?`<div class="group"><h3>251SR</h3><div class="tiles">${b.map(tile).join('')}</div></div>`:'');
 const ins=P.install,ib=$('aiminst');
 if(aimMode==='room'&&ins&&(!ins.aim||!ins.check)){ib.style.display='block';ib.innerHTML='<b>ROOM AIM (ADJUST)</b> and <b>ROOM CHECK</b> aren&rsquo;t on the SETUP page yet. <button id="aiminstb" class="mini primary" style="margin-left:8px"'+'>Add them to the SETUP page</button>';
  $('aiminstb').onclick=()=>saveTo('/api/aim/install',{},'Adding the ROOM buttons…',async()=>{LD.room=0;await load();},'roominstall');}else ib.style.display='none';
 const wb=$('warnbox');if(w.length){wb.style.display='block';wb.innerHTML='<b>Check these heads:</b> '+w.map(h=>esc(h.label)+' &ndash; '+esc(h.warn)).join('<br>');}else wb.style.display='none';
 $('foot').textContent='Show: '+P.show;updBar();}
function updBar(){const bad=!P||!P.ok;$('apply').disabled=bad;$('home').disabled=bad;
 $('hint').innerHTML=sxOpen&&!bad?QH:(bad?'':(aimMode==='room'?'Writes to '+esc((P.targets||[]).filter(t=>!/CHECK/.test(t)).join(', ')||'AROUND ROOM'):'Writes to all dancefloor movement scenes')+' + CENTER SPOT (step 1 aims). Nothing is changed until you press Apply.');}
let aimMode='floor';const PM={floor:null,room:null},LD={};
const aimT=()=>(P&&P.aimTitle)||(aimMode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)');
async function load(){const m=aimMode;$('summary').textContent='Loading…';let p;try{p=await api('/api/preview'+(m==='room'?'?mode=room':''));}catch(e){p={ok:false,error:'Could not read the show.'}}
 PM[m]=p;if(aimMode!==m)return;P=p;
 if(P.ok&&!LD[m]){setW(P.lastW);setD(P.lastD);$('lnk').checked=linked=(P.lastW===P.lastD);LD[m]=1;}render();}
function clamp(v){v=Math.round(+v||100);return Math.max(20,Math.min(300,v));}
function setW(v){v=clamp(v);$('w').value=$('wn').value=v;if(linked){$('d').value=$('dn').value=v;}draw();}
function setD(v){v=clamp(v);$('d').value=$('dn').value=v;if(linked){$('w').value=$('wn').value=v;}draw();}
function draw(){const w=+$('w').value/100,d=+$('d').value/100,W=180*w,H=120*d;const r=$('pat');r.setAttribute('x',150-W/2);r.setAttribute('y',105-H/2);r.setAttribute('width',W);r.setAttribute('height',H);}
$('w').oninput=e=>setW(e.target.value);$('d').oninput=e=>setD(e.target.value);$('wn').onchange=e=>setW(e.target.value);$('dn').onchange=e=>setD(e.target.value);
$('lnk').onchange=e=>{linked=e.target.checked;if(linked)setW($('w').value);};
document.querySelectorAll('.chip').forEach(c=>c.onclick=()=>{if(linked)setW(c.dataset.v);else{setW(c.dataset.v);setD(c.dataset.v);}});
$('refresh').onclick=load;
function ask(t,p,yes){return new Promise(res=>{$('mt').textContent=t;$('mp').innerHTML=p;$('myes').textContent=yes;$('modal').style.display='flex';
 $('myes').onclick=()=>{$('modal').style.display='none';res(true)};$('mno').onclick=()=>{$('modal').style.display='none';res(false)};});}
function busy(on,t){$('busy').style.display=on?'flex':'none';if(t)$('busyt').textContent=t;}
function showResult(r,what){const box=$('result');box.className='card result '+(r.ok?'ok':'err');
 if(r.ok&&r.queued){$('rlog').textContent='';$('rtitle').innerHTML='<span style="color:var(--amber)">&#9203;</span> Queued: '+esc(r.label);
  $('rbody').innerHTML='<p class="sub" style="margin:4px 0 0">'+(r.replaced?'Replaces what was queued for it before. ':'')+'Nothing is changed yet. Keep setting up; when you&rsquo;re done, <b>save and close ShowXpress</b> &mdash; SX Studio does everything in the list at the top'+(Q&&Q.reopen?' and opens ShowXpress again':'')+'.</p>';
  qPoll();box.scrollIntoView({behavior:'smooth'});return;}
 const lines=(r.out||'').split(/\r?\n/);$('rlog').textContent=r.out||'';
 const SV=['skip','rig','apc','speed','fix','revert','keep','rt','install','color','gsync','gimport','prefix','roominstall','sx','update','remote','auto','scene','scenerev','move','moverev','look'];
 if(!r.ok){$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> '+(what==='gsync'?'Not copied':what==='gimport'?'Not imported':what==='live'?'Live aim didn&rsquo;t start':what==='clprev'?'Preview didn&rsquo;t start':what==='sx'||what==='update'||what==='prefix'||what==='lab'?'Didn&rsquo;t work':SV.includes(what)?'Not saved':'Not applied');$('rbody').innerHTML='<p>'+esc(r.error)+'</p><p class="sub">Nothing was changed.</p>';}
 else if(SV.includes(what)&&what!=='skip'){const same=lines.some(l=>/nothing to change/.test(l))&&!lines.some(l=>/SKIP FLASH now/.test(l));
  const ls=lines.filter(l=>/^ {2}\S/.test(l)).map(l=>l.trim()).filter(l=>!/^(same\s|live\.ini saved|nothing to change|2D view saved|RIGHEADS|SKIPHEADS)/.test(l)).map(l=>l.replace(/^CHANGED\s+/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(same?'Nothing needed changing':{rt:'Saved to the 2D view',install:'RIG ID added',rig:"Tonight's rig saved",apc:'APC pads saved',speed:'Speed faders saved',fix:'Fix applied',revert:'Fix reverted',keep:'Fix kept',color:"Tonight's color saved",gsync:'Copied to Google Drive',gimport:'Imported from Google Drive',prefix:'Done',roominstall:'ROOM buttons added to the SETUP page',sx:'Done',update:'Installer opened',remote:'ShowXpress remote control turned on',auto:'Auto Show saved',scene:'Scene saved',scenerev:'Scene reverted',move:'Movement saved',moverev:'Movement reverted',look:'Look made'}[what]);
  const use=['rig','apc','speed','rt','install','color','roominstall','remote'].includes(what),chk=['fix','revert','scene','scenerev','move','moverev'].includes(what);
  $('rbody').innerHTML=(ls.length?'<ul>'+ls.map(l=>'<li>'+esc(l)+'</li>').join('')+'</ul>':'')+(use||chk?'<p class="sub" style="margin:8px 0 0">Open ShowXpress to '+(use?'use':'check')+' it.</p>':'');}
 else if(what==='skip'){const same=lines.some(l=>/nothing to change/.test(l));const ls=lines.map(l=>l.trim()).filter(l=>/^(heads|loop):/.test(l));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(same?'SKIP FLASH already uses these heads':'Saved to SKIP FLASH');
  $('rbody').innerHTML='<ul>'+ls.map(l=>'<li>'+esc(l)+'</li>').join('')+'</ul><p class="sub" style="margin:8px 0 0">Open ShowXpress and press <b>SKIP FLASH</b> to check it.</p>';}
 else{const tot=lines.find(l=>/movement scenes checked/.test(l))||'';const ch=lines.filter(l=>/\s[1-9]\d* values changed/.test(l)).map(l=>l.trim().replace(/\s{2,}/g,' — '));
  const wr=lines.filter(l=>/WARNING/.test(l)).map(l=>l.replace(/^\s*WARNING:\s*/,''));
  $('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> '+(what==='home'?'Everything is back to normal':'Applied to the show');
  $('rbody').innerHTML='<p class="sub" style="margin:4px 0 0">'+esc(tot.replace(/^\s*->\s*/,''))+'. '+(what==='home'?'':aimMode==='room'?'When ShowXpress opens, <b>ROOM CHECK</b> comes on by itself (with the remote on) &mdash; the beams should trace the edge you aimed.':'When ShowXpress opens, <b>DF CHECK 140</b> + <b>DF CHECK 251</b> come on by themselves (with the remote on) &mdash; the beams should trace the floor corners.')+'</p>'+
   (ch.length?'<ul>'+ch.map(c=>'<li>'+esc(c)+'</li>').join('')+'</ul>':'')+(wr.length?'<div class="warnbox" style="display:block">'+wr.map(esc).join('<br>')+'</div>':'');}
 box.scrollIntoView({behavior:'smooth'});}
$('apply').onclick=async()=>{let force=false;const w=P.heads.filter(h=>h.warn);
 if(w.length){if(!await ask(w.length+' head(s) look wrong','Their aims in '+esc(aimT())+' look far off the floor &mdash; usually step 1 / step 2 not aimed yet.<br><br>Apply anyway?','Apply anyway'))return;force=true;}
 busy(true,'Applying to the show…');try{const r=await api('/api/apply',wq({w:+$('w').value,d:+$('d').value,force,mode:aimMode}));showResult(r,'apply');}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load();};
$('home').onclick=async()=>{if(!await ask('Reset to normal?','All heads go back to the normal center, size 100%, and the '+esc(aimT())+' scene is reset. Your shapes are kept.','Reset'))return;
 busy(true,'Resetting…');try{const r=await api('/api/home',wq({mode:aimMode}));showResult(r,'home');if(!r.queued)LD[aimMode]=0;}catch(e){showResult({ok:false,error:'Lost connection.'})}busy(false);load();};
let Q=null,QSEEN='';const NL=String.fromCharCode(10);
function renderQ(){const b=$('qbar');if(!Q){b.className='qbar';return;}const d=Q.done;
 if(d&&d.at!==QSEEN){const bad=d.results.filter(x=>!x.ok);b.className='qbar on '+(bad.length?'bad':'done');
  b.innerHTML='<h3>'+(bad.length?'&#9888; Done after ShowXpress closed &mdash; '+bad.length+' didn&rsquo;t work':'&#10003; Done after ShowXpress closed')+'</h3><ul>'+
   d.results.map(x=>'<li class="'+(x.ok?'':'no')+'">'+esc(x.label)+(x.ok?' &mdash; done':' &mdash; NOT done: '+esc(x.error))+'</li>').join('')+'</ul>'+
   (d.reopened?'<span class="sub">ShowXpress is opening again.</span> ':d.reopenError?'<span style="color:var(--red)">ShowXpress didn&rsquo;t open: '+esc(d.reopenError)+'</span> ':'')+
   '<details style="display:inline-block;margin-left:8px"><summary class="sub" style="cursor:pointer">Full details</summary><pre>'+esc(d.results.map(x=>'== '+x.label+NL+(x.out||x.error)).join(NL))+'</pre></details> <button class="mini" id="qok">OK</button>';
  $('qok').onclick=async()=>{QSEEN=d.at;try{await api('/api/queue/seen',{});}catch(e){}renderQ();};return;}
 if(!Q.items.length){b.className='qbar';return;}
 b.className='qbar on';b.innerHTML='<h3>&#9203; Waiting for ShowXpress to close &mdash; '+Q.items.length+' thing'+(Q.items.length>1?'s':'')+' to do</h3>'+
  Q.items.map(x=>'<span class="qi">'+esc(x.label)+'<button data-qk="'+esc(x.key)+'" title="Take it off the list">&#10005;</button></span>').join('')+
  '<div class="row" style="margin-top:4px"><label class="link"><input type="checkbox" id="qreo"'+(Q.reopen?' checked':'')+'> Open ShowXpress again afterwards</label><div class="grow"></div>'+
  (sxOpen?'<span class="sub">Save your show, then close ShowXpress.</span><button class="mini primary" id="qclose">Close ShowXpress now</button>':'<span class="sub">ShowXpress is closed &mdash; doing it now&hellip;</span>')+'</div>';
 b.querySelectorAll('[data-qk]').forEach(x=>x.onclick=async()=>{const r=await api('/api/queue/cancel',{key:x.dataset.qk});Q=r.q;renderQ();});
 $('qreo').onchange=async e=>{const r=await api('/api/queue/reopen',{on:e.target.checked});Q=r.q;};
 const qc=$('qclose');if(qc)qc.onclick=sxClose;}
async function qPoll(){try{const r=await api('/api/sx');Q=r.q;renderQ();}catch(e){}}
function reloadAll(){// the queue just changed the show: read everything again (unsaved edits are now saved)
 LD.floor=0;LD.room=0;load();S=null;R=null;A=null;SP=null;H=null;RT=null;CL=null;SL=null;if(SE)seOpen(SE.file,true);const b=document.querySelector('.tabs button[data-tab].on');setTab(b?b.dataset.tab:'home');}
async function poll(){try{const r=await api('/api/sx');if(PH)$('offl').classList.remove('on');const was=sxOpen;sxOpen=r.open;if(!sxOpen)sxCloseT=0;const pd=Q&&Q.done?Q.done.at:'';Q=r.q;
 remPoll(r,was);
 if(Q&&Q.done&&Q.done.at!==pd&&Q.done.at!==QSEEN)reloadAll();renderQ();const p=$('sx');p.className='pill '+(sxOpen?'bad':'ok');
 p.textContent=sxOpen?'ShowXpress open'+(Q&&Q.items.length?' · '+Q.items.length+' waiting':''):'ShowXpress closed ✓';$('sxgo').style.display=sxOpen?'none':'';$('sxstop').style.display=sxOpen?'':'none';
 updBar();updSkip();updRig();updApc();updSpeed();updHealth();updRt();updColor();updGd();updPre();updScene();
 if(was&&!sxOpen){load();if(S&&!dirty())loadSkip();if(R&&!rgDirty())loadRig();if(A&&!apDirty())loadApc();if(SP&&!spDirty())loadSpeed();if(H)loadHealth();if(RT&&!rtDirty())loadRt();if(CL&&!clDirty())loadColor();loadGd();}}
 catch(e){if(e&&e.message==='not paired')return;if(UPD){$('busyt').textContent='Update installed — opening the new version…';return;}
  if(PH){$('offl').classList.add('on');setTimeout(poll,3000);return;}$('gone').style.display='flex';return;}setTimeout(poll,2000);}

// ---------------- tabs
const TABS=['home','rt','rig','aim','skip','color','apc','apc40','speed','health','pre','auto','settings','lab','scene','move','look'];
let lastTab='';
function setTab(t){if(!TABS.includes(t))t='home';window.scrollTo(0,0);const fresh=t!==lastTab;lastTab=t;
 document.querySelectorAll('.tabs button[data-tab]').forEach(b=>b.classList.toggle('on',b.dataset.tab===t));tgClose();tgSync();
 document.querySelectorAll('.view').forEach(v=>v.classList.toggle('on',v.id==='v-'+t));
 document.querySelectorAll('.bar .in').forEach(v=>v.classList.toggle('on',v.dataset.for===t));
 $('result').className='card result';if(t==='skip'&&!S)loadSkip();if(t==='rig'&&!R)loadRig();if(t==='apc'&&!A)loadApc();if(t==='apc40'){if(!Q4)loadA40();a4Poll();}if(t==='speed'&&!SP)loadSpeed();if(t==='health'&&!H)loadHealth();if(t==='rt'&&!RT)loadRt();if(t==='pre')loadPre();if(t==='color'&&!CL)loadColor();if(t==='settings'){loadGd();loadSet();if(!PH)loadPhone();}if(t==='lab'){if(!LB)loadLab();else labPoll();}if(t==='scene'&&!SL&&!SE)loadScenes();if(t==='move'){if(!ML&&!MO)loadMoves();mvLiteList();mvAnim(!!MO);}if(t==='look'){if(!LK)loadLooks();lkAnim(true);}$('cog').classList.toggle('on',t==='settings');
 if(t==='auto'&&(!AU||!auDirty()))loadAuto();if(REMBOX[t]&&fresh)remRefresh(t,sxOpen&&!remRecent());}
document.querySelectorAll('.tabs button[data-tab]').forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
// the tab bar's menus: Home + one drop-down per group. A group with one tab left (the others hidden in Settings) is a plain button
function tgVis(g){return [...g.querySelectorAll('[data-tab]')].filter(b=>getComputedStyle(b).display!=='none');}
function tgSync(){document.querySelectorAll('.tg').forEach(g=>{const v=tgVis(g),on=g.querySelector('[data-tab].on'),one=v.length===1;
  g.style.display=v.length?'':'none';g.classList.toggle('one',one);g.classList.toggle('on',!!on);g.querySelector('.tgb').classList.toggle('on',!!on);
  g.querySelector('.tgc').textContent=one?v[0].textContent:(on?on.textContent:'');g.querySelector('.tgb').title=one?'':g.querySelector('.tgn').textContent;});
 $('tghome').classList.toggle('on',lastTab==='home');}
function tgClose(){document.querySelectorAll('.tg.open').forEach(g=>{g.classList.remove('open');g.querySelector('.tgb').setAttribute('aria-expanded','false');});}
function tgOpen(g){tgClose();g.classList.remove('r');g.classList.add('open');g.querySelector('.tgb').setAttribute('aria-expanded','true');
 if(g.querySelector('.tgm').getBoundingClientRect().right>innerWidth-8)g.classList.add('r');}
document.querySelectorAll('.tg').forEach(g=>{const b=g.querySelector('.tgb');
 b.onclick=()=>{if(g.classList.contains('one')){const v=tgVis(g)[0];if(v)setTab(v.dataset.tab);return;}g.classList.contains('open')?tgClose():tgOpen(g);};
 b.onpointerenter=e=>{if(e.pointerType==='mouse'&&document.querySelector('.tg.open')&&!g.classList.contains('open')&&!g.classList.contains('one'))tgOpen(g);};});
document.addEventListener('click',e=>{if(!e.target.closest('.tg'))tgClose();});
document.addEventListener('keydown',e=>{const g=document.querySelector('.tg.open');if(g&&e.key==='Escape'){tgClose();g.querySelector('.tgb').focus();}});
$('tghome').onclick=()=>setTab('home');
$('logo').onclick=()=>setTab('home');$('cog').onclick=()=>setTab('settings');document.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>setTab(b.dataset.go));

// ---------------- Strobe (the SKIP FLASH heads)
let S=null,sel=new Set();
const saved=()=>new Set(S&&S.ok?S.heads.filter(h=>h.on).map(h=>h.id):[]);
function dirty(){if(!S||!S.ok)return false;const s=saved();return s.size!==sel.size||[...sel].some(i=>!s.has(i));}
async function loadSkip(){$('sksum').textContent='Loading…';try{S=await api('/api/skip');}catch(e){S={ok:false,error:'Could not read the show.'}}
 sel=saved();renderSkip();}
function flashOrder(){ // same rule as skip_flash.ps1: 140s in the skip order, 251s spread evenly in between
 const hs=S.heads.filter(h=>sel.has(h.id)),pick=(is140,ord)=>{const g=hs.filter(h=>h.is140===is140);return ord.map(n=>g.find(h=>h.num===n)).filter(Boolean).concat(g.filter(h=>!ord.includes(h.num)));};
 const a=pick(true,S.order140),b=pick(false,S.order251),out=[];let i=0,j=0;
 while(i<a.length||j<b.length){const takeA=j>=b.length||(i<a.length&&(i+.5)/a.length<=(j+.5)/b.length);out.push(takeA?a[i++]:b[j++]);}return out;}
function headTile(h,s){const on=sel.has(h.id),chg=on!==s.has(h.id);
 return `<div class="hd${on?' on':''}${chg?' chg':''}" data-id="${esc(h.id)}" title="${chg?'changed - not saved yet':''}">#${h.num}<small>${on?'in use':'not here'}</small></div>`;}
function renderSkip(){if(!S)return;const er=$('skerr');
 if(!S.ok){er.style.display='block';er.innerHTML=esc(S.error);$('skgroups').innerHTML='';$('skorder').innerHTML='';$('sksum').textContent='';$('skstate').style.display='none';updSkip();return;}
 er.style.display='none';const s=saved();
 const grp=(is140,name)=>{const hs=S.heads.filter(h=>h.is140===is140);if(!hs.length)return'';const n=hs.filter(h=>sel.has(h.id)).length;
  return `<div class="gh"><h3>${name}</h3><span class="cnt">${n} of ${hs.length}</span><div class="grow"></div><button class="mini" data-all="${is140?1:0}">All</button><button class="mini" data-none="${is140?1:0}">None</button></div><div class="heads">${hs.map(h=>headTile(h,s)).join('')}</div>`;};
 $('skgroups').innerHTML=grp(true,'140SR')+grp(false,'251SR');
 document.querySelectorAll('.hd').forEach(t=>t.onclick=()=>{const id=t.dataset.id;sel.has(id)?sel.delete(id):sel.add(id);renderSkip();});
 const setG=(is140,on)=>{S.heads.filter(h=>h.is140===is140).forEach(h=>on?sel.add(h.id):sel.delete(h.id));renderSkip();};
 document.querySelectorAll('[data-all]').forEach(b=>b.onclick=()=>setG(b.dataset.all==='1',true));
 document.querySelectorAll('[data-none]').forEach(b=>b.onclick=()=>setG(b.dataset.none==='1',false));
 const o=flashOrder();$('skorder').innerHTML=o.length?o.map(h=>`<span>${esc(h.label)}</span>`).join('<i>&rsaquo;</i>'):'<span style="color:var(--dim)">no heads picked</span>';
 $('sksum').innerHTML=`<b>${o.length}</b> heads &middot; ${S.stepCs/100} s each &middot; one loop <b>${(o.length*S.stepCs/100).toFixed(2)} s</b>`;
 const st=$('skstate');st.style.display='inline-block';const d=dirty();st.className='state '+(d?'chg':'ok');st.textContent=d?'● Not saved yet':'✓ Matches the show';
 $('foot').textContent='Show: '+S.show;updSkip();}
function updSkip(){const ok=S&&S.ok,d=dirty(),n=sel.size;$('sksave').disabled=!ok||!d||n<2;$('skundo').disabled=!ok||!d;
 $('skhint').innerHTML=!ok?'':sxOpen?QH:
  n<2?'<span style="color:var(--amber)">Pick at least 2 heads.</span>':d?'Only the SKIP FLASH scene is changed. Heads you turn off are taken out of it.':'SKIP FLASH already uses exactly these heads.';}
$('skrefresh').onclick=loadSkip;
$('skundo').onclick=()=>{sel=saved();renderSkip();};
$('sksave').onclick=async()=>{busy(true,'Saving SKIP FLASH…');let r;try{r=await api('/api/skip/apply',wq({heads:[...sel]}));}catch(e){r={ok:false,error:'Lost connection.'}}
 busy(false);if(r.ok&&!r.queued){await loadSkip();R=null;H=null;}showResult(r,'skip');};

// ---------------- shared bits for the newer tabs
function stateTag(id,d){const st=$(id);st.style.display='inline-block';st.className='state '+(d?'chg':'ok');st.textContent=d?'● Not saved yet':'✓ Matches the show';}
const QH='<span style="color:var(--amber)">ShowXpress is open &mdash; this is <b>queued</b> and done as soon as you save and close ShowXpress.</span>';
function sxHint(what){return sxOpen?QH:null;}
async function getJ(p){try{return await api(p);}catch(e){return {ok:false,error:'Could not read the show.'};}}
async function saveTo(p,body,label,after,what){busy(true,sxOpen?'Queueing…':label);let r;try{r=await api(p,wq(body));}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);if(r.ok&&!r.queued)await after();showResult(r,what);}
function showErr(id,obj){const er=$(id);if(obj&&!obj.ok){er.style.display='block';er.innerHTML=esc(obj.error);return true;}er.style.display='none';return false;}

// ---------------- Tonight's rig (same step rule as rig.ps1)
let R=null,rsel=new Set(),rflip={};
const rSaved=()=>new Set(R&&R.ok?R.heads.filter(h=>h.on).map(h=>h.id):[]);
// Reversed heads (flip.ps1): id -> {pan,tilt}; saved with Tonight's Rig (always the full list)
const fSaved=()=>{const o={};if(R&&R.ok)R.heads.forEach(h=>o[h.id]={pan:!!h.rp,tilt:!!h.rt});return o;};
const fChg=id=>{const h=R.heads.find(x=>x.id===id),f=rflip[id]||{};return !!h&&(!!f.pan!==!!h.rp||!!f.tilt!==!!h.rt);};
const fDirty=()=>!!(R&&R.ok&&R.heads.some(h=>fChg(h.id)));
function rgDirty(){if(!R||!R.ok)return false;const s=rSaved();return s.size!==rsel.size||[...rsel].some(i=>!s.has(i))||fDirty();}
async function loadRig(){$('rgsum').textContent='Loading…';R=await getJ('/api/rig');rsel=rSaved();rflip=fSaved();renderRig();}
function rigDrop(sc,hung){const gs=sc.groups||[];let drop=[],kept=0;
 for(const g of gs){const s=sc.steps[g[0]];if(!s.other&&s.lit.length&&!s.lit.some(i=>hung.has(i)))drop.push(...g);else kept++;}
 return gs.length&&!kept?null:new Set(drop);}
function renderRig(){if(!R)return;
 if(showErr('rgerr',R)){$('rggroups').innerHTML=$('rgflip').innerHTML=$('rgscenes').innerHTML=$('rgsum').innerHTML='';$('rgstate').style.display='none';updRig();return;}
 const s=rSaved();
 const grp=(is140,name)=>{const hs=R.heads.filter(h=>h.is140===is140);if(!hs.length)return'';const n=hs.filter(h=>rsel.has(h.id)).length;
  return `<div class="gh"><h3>${name}</h3><span class="cnt">${n} of ${hs.length} hung</span><div class="grow"></div><button class="mini" data-rall="${is140?1:0}">All</button><button class="mini" data-rnone="${is140?1:0}">None</button></div><div class="heads">`+
   hs.map(h=>{const on=rsel.has(h.id),chg=on!==s.has(h.id);return `<div class="hd${on?' on':''}${chg?' chg':''}" data-rid="${esc(h.id)}" title="${chg?'changed - not saved yet':''}">#${h.num}<small>${on?'hung':'not here'}</small></div>`;}).join('')+'</div>';};
 $('rggroups').innerHTML=grp(true,'140SR')+grp(false,'251SR');
 const fgrp=(is140,name)=>{const hs=R.heads.filter(h=>h.is140===is140);if(!hs.length)return'';const n=hs.filter(h=>(rflip[h.id]||{}).pan||(rflip[h.id]||{}).tilt).length;
  return `<div class="gh"><h3>${name}</h3><span class="cnt">${n?n+' reversed':'none reversed'}</span></div><div class="heads">`+
   hs.map(h=>{const f=rflip[h.id]||{},on=f.pan||f.tilt,chg=fChg(h.id);return `<div class="hd${on?' on':''}${chg?' chg':''}" title="${chg?'changed - not saved yet':''}">#${h.num}<br><span class="fx${f.pan?' on':''}" data-fp="${esc(h.id)}" title="Reverse pan (left / right)">&harr; pan</span><span class="fx${f.tilt?' on':''}" data-ft="${esc(h.id)}" title="Reverse tilt (up / down)">&varr; tilt</span></div>`;}).join('')+'</div>';};
 $('rgflip').innerHTML='<div class="fxg">'+fgrp(true,'140SR')+fgrp(false,'251SR')+'</div>';
 const fset=(id,ax)=>{const f=rflip[id]=Object.assign({pan:false,tilt:false},rflip[id]);f[ax]=!f[ax];renderRig();};
 document.querySelectorAll('[data-fp]').forEach(e=>e.onclick=()=>fset(e.dataset.fp,'pan'));
 document.querySelectorAll('[data-ft]').forEach(e=>e.onclick=()=>fset(e.dataset.ft,'tilt'));
 document.querySelectorAll('[data-rid]').forEach(t=>t.onclick=()=>{const id=t.dataset.rid;rsel.has(id)?rsel.delete(id):rsel.add(id);renderRig();});
 const setG=(is140,on)=>{R.heads.filter(h=>h.is140===is140).forEach(h=>on?rsel.add(h.id):rsel.delete(h.id));renderRig();};
 document.querySelectorAll('[data-rall]').forEach(b=>b.onclick=()=>setG(b.dataset.rall==='1',true));
 document.querySelectorAll('[data-rnone]').forEach(b=>b.onclick=()=>setG(b.dataset.rnone==='1',false));
 let nTrim=0;const scs=R.scenes||[];
 $('rgscenes').innerHTML=scs.map(sc=>{const d=rigDrop(sc,rsel),drop=d||new Set(),n=sc.steps.length;if(drop.size)nTrim++;
  const dots=sc.steps.map((st,i)=>{const c=drop.has(i)?'x':st.lit.length?'l':st.other?'o':'';
   return `<i class="${c}" title="step ${i+1}: ${drop.has(i)?'taken out tonight':st.lit.length?st.lit.length+' mover(s) lit':st.other?'blinder / uplight only':'dark'}"></i>`;}).join('');
  const ti=(sc.titles||[]).filter(t=>t!==sc.name);
  const st=d===null?'<span style="color:var(--amber)">none of its heads hung &mdash; kept complete</span>':drop.size?`<b>${n-drop.size}</b> of ${n} steps`:`all ${n} steps`;
  const tags=(sc.trimmed?'<span class="tag amber" title="trimmed for the rig saved last time">trimmed now</span>':'')+(sc.edited?'<span class="tag red" title="Changed in ShowXpress while it was trimmed - that version now counts as the full scene">edited</span>':'');
  return `<div class="sc${drop.size?' chg':''}"><div class="nm">${esc(sc.name)}${tags}${ti.length?'<small>button: '+esc(ti.join(', '))+'</small>':''}</div><div class="dots">${dots}</div><div class="st">${st}</div></div>`;}).join('')||'<p class="sub">No chase scenes found on your live buttons.</p>';
 $('rgsum').innerHTML=`<b>${scs.length}</b> chase scenes &middot; <b>${nTrim}</b> trimmed for this rig`;
 stateTag('rgstate',rgDirty());$('foot').textContent='Show: '+R.show;updRig();}
function updRig(){const ok=!!(R&&R.ok),d=rgDirty(),n=rsel.size;$('rgsave').disabled=!ok||!d||!n;$('rgundo').disabled=!ok||!d;$('rgall').disabled=!ok||R.heads.every(h=>rsel.has(h.id));
 const s=rSaved(),rd=s.size!==rsel.size||[...rsel].some(i=>!s.has(i));
 $('rghint').innerHTML=!ok?'':sxHint('save')??(!n?'<span style="color:var(--amber)">Tick at least one head.</span>':d?[fDirty()?'Reversed heads: every scene and movement flips for those heads.':'',rd?'Only chase scenes change for the hung heads. The full scenes are kept, so ticking every head puts them back.':''].filter(Boolean).join(' '):'The show already matches these heads.');}
$('rgrefresh').onclick=loadRig;$('rgundo').onclick=()=>{rsel=rSaved();rflip=fSaved();renderRig();};
$('rgall').onclick=()=>{R.heads.forEach(h=>rsel.add(h.id));renderRig();};
$('rgsave').onclick=()=>saveTo('/api/rig/apply',{heads:[...rsel],flip:rflip},'Saving tonight\'s rig…',async()=>{await loadRig();S=null;H=null;},'rig');

// ---------------- APC mini (pad colours = APC mini mk2 velocity palette)
const PAL='000000 1E1E1E 7F7F7F FFFFFF FF4C4C FF0000 590000 190000 FFBD6C FF5400 591D00 271B00 FFFF4C FFFF00 595900 191900 88FF4C 54FF00 1D5900 142B00 4CFF4C 00FF00 005900 001900 4CFF5E 00FF19 00590D 001902 4CFF88 00FF55 00591D 001F12 4CFFB7 00FF99 005935 001912 4CC3FF 00A9FF 004152 001019 4C88FF 0055FF 001D59 000819 4C4CFF 0000FF 000059 000019 874CFF 5400FF 190064 0F0030 FF4CFF FF00FF 590059 190019 FF4C87 FF0054 59001D 220013 FF1500 993500 795100 436400 033900 005735 00547F 0000FF 00454F 2500CC 7F7F7F 202020 FF0000 BDFF2D AFED06 64FF09 108B00 00FF87 00A9FF 002AFF 3F00FF 7A00FF B21A7D 402100 FF4A00 88E106 72FF15 00FF00 3BFF26 59FF71 38FFCC 5B8AFF 3151C6 877FE9 D31DFF FF005D FF7F00 B9B000 90FF00 835D07 392B00 144C10 0D5038 15152A 16205A 693C1C A8000A DE513D D86A1C FFE126 9EE12F 67B50F 1E1E30 DCFF6B 80FFBD 9A99FF 8E66FF 404040 757575 E0FFFF A00000 350000 1AD000 074200 B9B000 3F3100 B35F00 4B1502'.split(' ');
let A=null,apN={},apC={},apSel=null,apMsg='';
const apOn=p=>(apC[p.sec]||p).on,apOff=p=>(apC[p.sec]||p).off,colChg=p=>!!apC[p.sec]&&(apC[p.sec].on!==p.on||apC[p.sec].off!==p.off);
const SWB=[5,9,13,17,21,29,33,37,41,45,49,53,57,3],SWD=[6,10,14,18,22,30,34,38,42,46,50,54,58,1];
function swRow(k,cur){return [...SWB,...SWD,0].map(v=>`<i class="psw${v===cur?' cur':''}" data-sw="${k}" data-v="${v}" style="background:#${PAL[v]}" title="${v?'colour '+v:'off'}"></i>`).join('');}
const rc=n=>'row '+(8-Math.floor(n/8))+', column '+(n%8+1);
const onGrid=p=>p.type===0&&apN[p.sec]>=0&&apN[p.sec]<=63;
function apDirty(){return !!(A&&A.ok&&A.pads.some(p=>apN[p.sec]!==p.note||colChg(p)));}
async function loadApc(){A=await getJ('/api/apc');apN={};apC={};apSel=null;apMsg='';if(A.ok)A.pads.forEach(p=>apN[p.sec]=p.note);renderApc();}
function padsAt(n){return A.pads.filter(p=>onGrid(p)&&apN[p.sec]===n);}
function padClick(n){const here=padsAt(n);
 if(apSel){const sp=A.pads.find(p=>p.sec===apSel),from=apN[apSel];
  if(onGrid(sp)&&from===n){if(here.length>1){const i=here.findIndex(p=>p.sec===apSel);apSel=here[(i+1)%here.length].sec;}else{apSel=null;apMsg='';}renderApc();return;}
  if(here.length>1){apMsg='That pad already has '+here.length+' buttons on it &mdash; move those apart first.';renderApc();return;}
  if(here.length===1){if(!onGrid(sp)){apMsg='That pad is taken &mdash; pick an empty pad.';renderApc();return;}apN[here[0].sec]=from;}
  apN[apSel]=n;apSel=null;apMsg='';renderApc();return;}
 if(here.length){apSel=here[0].sec;apMsg='';renderApc();}}
// drag a pad to move it (same rules as tap-then-tap: onto a used pad = swap); right-click = menu; click elsewhere = deselect
let apDrag=null;
function apDnd(){const off=()=>document.querySelectorAll('.a4drop').forEach(x=>x.classList.remove('a4drop'));
 document.querySelectorAll('#apgrid .pad').forEach(e=>{const n=+e.dataset.n;
  e.ondragstart=ev=>{const ps=padsAt(n);if(!ps.length){ev.preventDefault();return;}apDrag=(ps.find(x=>x.sec===apSel)||ps[0]).sec;ev.dataTransfer.effectAllowed='move';ev.dataTransfer.setData('text/plain',apDrag);ctxClose();};
  e.ondragend=()=>{apDrag=null;off();};
  e.ondragover=ev=>{if(apDrag===null)return;ev.preventDefault();ev.dataTransfer.dropEffect='move';e.classList.add('a4drop');};
  e.ondragleave=()=>e.classList.remove('a4drop');
  e.ondrop=ev=>{ev.preventDefault();off();if(apDrag===null)return;const s=apDrag;apDrag=null;if(apN[s]===n)return;apSel=s;padClick(n);};
  e.oncontextmenu=ev=>{ev.preventDefault();const ps=padsAt(n);
   if(!ps.length){ctxOpen(ev.clientX,ev.clientY,'Free pad - '+rc(n),[{h:'Nothing on this pad',off:true,go:()=>{}}]);return;}
   const it=[];ps.forEach(p=>{it.push({h:(ps.length>1?esc(p.title)+': ':'')+'Colours / details&hellip;',go:()=>{apSel=p.sec;apMsg='';renderApc();}});
    it.push({h:(ps.length>1?'Take '+esc(p.title)+' off the pads':'Take off the pads'),go:()=>{apN[p.sec]=-1;if(apSel===p.sec)apSel=null;apMsg='';renderApc();}});});
   ctxOpen(ev.clientX,ev.clientY,ps.map(p=>p.title).join(' + ')+' - '+rc(n),it);};});}
document.addEventListener('pointerdown',e=>{if(!apSel||curTab()!=='apc'||!e.target.closest)return;if(e.target.closest('#apgrid,#apside,#apissues,#ctxm,.bar'))return;apSel=null;apMsg='';renderApc();});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&apSel&&curTab()==='apc'){apSel=null;apMsg='';renderApc();}});
function renderApc(){if(!A)return;
 if(showErr('aperr',A)){['apgrid','apside','apfaders','apissues'].forEach(i=>$(i).innerHTML='');$('apstate').style.display='none';updApc();return;}
 let h='',used=0;const free=[];
 for(let r=1;r<=8;r++)for(let c=1;c<=8;c++){const n=(8-r)*8+(c-1),ps=padsAt(n),p=ps.find(x=>x.sec===apSel)||ps[0];
  if(!p){free.push('row '+r+' col '+c);h+=`<div class="pad empty${apSel?' tgt':''}" data-n="${n}" title="${rc(n)} - free"><div class="t">free</div></div>`;continue;}
  used++;const mv=ps.some(x=>apN[x.sec]!==x.note||colChg(x)),bg=PAL[apOff(p)]||'151820',on=PAL[apOn(p)]||'444444';
  h+=`<div class="pad${ps.some(x=>x.sec===apSel)?' sel':''}${apSel?' tgt':''}${mv?' mv':''}${ps.length>1?' dup':''}${p.sceneOk?'':' miss'}" data-n="${n}" draggable="true" style="background:linear-gradient(180deg,rgba(0,0,0,0) 35%,rgba(0,0,0,.6)),#${bg}" title="${esc(ps.map(x=>x.title+' ('+x.pageName+')').join(' + '))} - ${rc(n)}">`+
   `<div class="on" style="background:#${on}"></div>${ps.length>1?`<span class="badge">${ps.length}</span>`:''}<div class="t">${esc(p.title)}</div><div class="p">${esc(p.pageName)}</div></div>`;}
 $('apgrid').innerHTML=h;document.querySelectorAll('#apgrid .pad').forEach(e=>e.onclick=()=>padClick(+e.dataset.n));apDnd();
 const sp=apSel&&A.pads.find(p=>p.sec===apSel);
 if(sp){const n=apN[sp.sec],where=n<0?'none &mdash; will be taken off':onGrid(sp)?rc(n):'note '+n+' (not a pad)';
  $('apside').innerHTML=`<h3>${esc(sp.title)}</h3><div class="kv"><span>Page</span><b>${esc(sp.pageName)}</b><span>Scene</span><b>${sp.sceneOk?esc(sp.scene):'<span style="color:var(--red)">'+esc(sp.scene)+' &mdash; missing!</span>'}</b>`+
   `<span>Pad</span><b>${where}${n!==sp.note?' <span class="tag blue">moved</span>':''}</b><span>Light</span><b><span class="sw" style="background:#${PAL[apOn(sp)]||'000000'}"></span>playing &nbsp; <span class="sw" style="background:#${PAL[apOff(sp)]||'000000'}"></span>idle${colChg(sp)?' <span class="tag blue">changed</span>':''}</b>${sp.key?`<span>Key</span><b>${esc(sp.key)}</b>`:''}</div>`+
   (onGrid(sp)&&apN[sp.sec]>=0?`<div class="pcl"><span>Colour while playing</span><div class="pals">${swRow('on',apOn(sp))}</div><span>Colour when idle</span><div class="pals">${swRow('off',apOff(sp))}</div></div>`:'')+
   `<p class="sub" style="margin:0 0 10px">${apMsg||'Tap a colour to change it, or tap the pad it should go to. Tapping a used pad swaps the two.'}</p><div class="row"><button id="apdel">Take off the pads</button><button id="apcancel">Done</button></div>`;
  $('apdel').onclick=()=>{apN[sp.sec]=-1;apSel=null;apMsg='';renderApc();};
  document.querySelectorAll('[data-sw]').forEach(e=>e.onclick=()=>{const c=apC[sp.sec]||{on:sp.on??21,off:sp.off??0};c[e.dataset.sw]=+e.dataset.v;apC[sp.sec]=c;renderApc();});$('apcancel').onclick=()=>{apSel=null;apMsg='';renderApc();};}
 else $('apside').innerHTML=`<h3>Move a pad</h3><p class="sub" style="margin:0 0 8px">Tap a pad to see what it plays, then tap where it should go &mdash; or drag it there. Right-click a pad to take it off. A blue dot = moved, not saved yet.</p>${apMsg?'<p class="sub" style="color:var(--amber)">'+apMsg+'</p>':''}<div class="kv"><span>Pads used</span><b>${used} of 64</b><span>Free</span><b>${free.join(', ')||'none'}</b></div>`;
 $('apfaders').innerHTML=(A.faders||[]).map(f=>`<div class="fd"><b>Fader ${f.n}</b><span>CC ${f.cc} &rarr; </span>${esc(f.caption||'?')} speed</div>`).join('');
 const iss=[];
 for(let n=0;n<64;n++){const ps=padsAt(n);if(ps.length>1)iss.push(['error',rc(n)+' plays '+ps.length+' buttons',ps.map(p=>p.title+' ('+p.pageName+')').join(', ')+' &mdash; one press fires all of them. Tap the pad (again to pick the next one) and move one away.','']);}
 A.pads.filter(p=>!p.sceneOk&&apN[p.sec]>=0).forEach(p=>iss.push(['error',p.title+': scene file missing','Plays '+p.scene+', which isn\'t in the show any more.','']));
 A.pads.filter(p=>!onGrid(p)&&apN[p.sec]!==-1).forEach(p=>iss.push(['warn',p.title+' ('+p.pageName+') is mapped outside the pads',(p.type===0?'Note ':'MIDI type '+p.type+', number ')+apN[p.sec]+' &mdash; a round button or track button.',p.type===0?`<button class="mini" data-pick="${esc(p.sec)}">Move to a pad</button> <button class="mini" data-del="${esc(p.sec)}">Take off</button>`:`<button class="mini" data-del="${esc(p.sec)}">Take off</button>`]));
 A.pads.filter(p=>apN[p.sec]===-1).forEach(p=>iss.push(['info',p.title+' ('+p.pageName+') will be taken off the pads','Not saved yet.',`<button class="mini" data-back="${esc(p.sec)}">Put back</button>`]));
 $('apissues').innerHTML=iss.length?iss.map(i=>`<div class="iss ${i[0]}"><div class="ic">${i[0]==='error'?'!':i[0]==='warn'?'?':'i'}</div><div class="grow"><b>${esc(i[1])}</b><div class="d">${i[2]}</div></div><div class="act">${i[3]}</div></div>`).join(''):'<p style="color:var(--green);margin:4px 0">&#10003; Every pad plays one button and every scene exists.</p>';
 document.querySelectorAll('[data-del]').forEach(b=>b.onclick=()=>{apN[b.dataset.del]=-1;apSel=null;renderApc();});
 document.querySelectorAll('[data-back]').forEach(b=>b.onclick=()=>{const p=A.pads.find(x=>x.sec===b.dataset.back);apN[p.sec]=p.note;renderApc();});
 document.querySelectorAll('[data-pick]').forEach(b=>b.onclick=()=>{apSel=b.dataset.pick;apMsg='Tap a free pad to put it there.';renderApc();window.scrollTo({top:0,behavior:'smooth'});});
 stateTag('apstate',apDirty());$('foot').textContent='Show: '+A.show;updApc();}
function updApc(){const ok=!!(A&&A.ok),d=apDirty();$('apsave').disabled=!ok||!d;$('apundo').disabled=!ok||!d;
 $('aphint').innerHTML=!ok?'':sxHint('save')??(d?A.pads.filter(p=>apN[p.sec]!==p.note||colChg(p)).length+' button(s) changed. Only the pad notes and pad colours in live.ini change.':'Pads match the show.');}
$('aprefresh').onclick=loadApc;$('apundo').onclick=()=>{A.pads.forEach(p=>apN[p.sec]=p.note);apC={};apSel=null;apMsg='';renderApc();};
$('apsave').onclick=()=>saveTo('/api/apc/apply',{changes:A.pads.filter(p=>apN[p.sec]!==p.note||colChg(p)).map(p=>{const c={sec:p.sec,title:p.title,note:apN[p.sec]};if(colChg(p)&&apN[p.sec]>=0){c.on=apC[p.sec].on;c.off=apC[p.sec].off;}return c;})},'Saving pads…',async()=>{await loadApc();SP=null;H=null;},'apc');

// ---------------- APC40 mk2 (user 2026-11-25): pages of the user's own pads, played through ShowXpress's remote by apc40.ps1
let a4ColOpen=false;
let Q4=null,L4=null,a4Pg=0,a4Sel=-1,a4Q='',a4St=null,a4T=null,a4Msg='',a4MsgT=null;
const a4Copy=l=>JSON.parse(JSON.stringify(l));
function a4Fix(l){l=a4Copy(l||{});if(!Array.isArray(l.pages))l.pages=l.pages?[l.pages]:[];if(!l.pages.length)l.pages=[{name:'Dancefloor',pads:{}}];l.pages.forEach(p=>{if(!p.pads||Array.isArray(p.pads))p.pads={};if(!p.colors||Array.isArray(p.colors))p.colors={};Object.keys(p.colors).forEach(k=>{if(!p.pads[k])delete p.colors[k];});});if(!l.faders||Array.isArray(l.faders))l.faders={};return l;}
const a4Norm=l=>JSON.stringify({p:l.pages.map(p=>[p.name,Object.keys(p.pads).map(Number).sort((a,b)=>a-b).map(k=>[k,p.pads[k],p.colors&&p.colors[k]?[+p.colors[k].on,+p.colors[k].off]:0])]),f:Object.keys(l.faders).map(Number).sort((a,b)=>a-b).map(k=>[k,+l.faders[k]])});
function a4Dirty(){return !!(Q4&&Q4.ok&&L4&&a4Norm(L4)!==a4Norm(a4Fix(Q4.layout)));}
function a4B(){const m={};(Q4.buttons||[]).forEach(b=>{if(!b.dup&&!m[b.title])m[b.title]=b;});return m;}
const a4rc=n=>'row '+(5-Math.floor(n/8))+', column '+(n%8+1);
const a4On=(pg,n,b)=>{const c=pg.colors&&pg.colors[n];return c?+c.on:b?b.on:null;},a4Off=(pg,n,b)=>{const c=pg.colors&&pg.colors[n];return c?+c.off:b?b.off:null;};
function a4SwRow(k,cur){return [...SWB,...SWD,0].map(v=>`<i class="psw${v===cur?' cur':''}" data-a4sw="${k}" data-v="${v}" style="background:#${PAL[v]}" title="${v?'colour '+v:'off'}"></i>`).join('');}
function a4Next(n){const i=(4-Math.floor(n/8))*8+n%8+1;return i>=40?-1:(4-Math.floor(i/8))*8+i%8;}
async function loadA40(){Q4=await getJ('/api/apc40');if(Q4.ok){L4=a4Fix(Q4.layout);if(Q4.status)a4St=Q4.status;}a4Pg=L4?Math.min(a4Pg,L4.pages.length-1):0;a4Sel=-1;renderA40();}
function a4Say(m){a4Msg=m;clearTimeout(a4MsgT);a4MsgT=setTimeout(()=>{a4Msg='';updA40();},5000);updA40();}
function a4Poll(){clearTimeout(a4T);if(curTab()!=='apc40')return;api('/api/apc40/status').then(r=>{a4St=r.status;a4Conn();}).catch(()=>{}).finally(()=>{a4T=setTimeout(a4Poll,1500);});}
function a4Conn(){const e=$('a4conn'),s=a4St;if(!e||!Q4||!Q4.ok)return;
 if(Q4.windows===false){e.innerHTML='<span class="dot"></span>The APC40 works with SX Studio on Windows. You can still set up its pages here.';return;}
 let a,x='',cl='';
 if(!s||!s.running)a='Starting the APC40 part of SX Studio&hellip;';
 else if(s.apc==='ok'){a='<b>APC40 connected</b> &middot; on page '+s.page+(s.pageName?' ('+esc(s.pageName)+')':'');
  x=s.sx==='ok'?'ShowXpress connected':s.sx==='closed'?'ShowXpress is closed &mdash; the pads light up once it&rsquo;s open':(s.sx==='off'||s.sx==='refused')?esc(s.error):'connecting to ShowXpress&hellip;';cl=s.sx==='ok'?'green':'';}
 else if(s.apc==='missing')a='APC40 not plugged in &mdash; plug it in and it&rsquo;s ready in a couple of seconds';
 else if(s.apc==='busy'){a=esc(s.error||'Another program has the APC40.');cl='red';}
 else a='Starting&hellip;';
 e.innerHTML=`<span class="dot ${cl}"></span>${a}${x?' &middot; '+x:''}${s&&s.apc==='ok'&&s.last?' <span class="sub" style="margin:0 0 0 8px">last pad: '+esc(s.last)+'</span>':''}`;}
function renderA40(){if(!Q4)return;
 if(showErr('a4err',Q4)){['a4grid','a4side','a4faders','a4pages','a4conn'].forEach(i=>$(i).innerHTML='');$('a4state').style.display='none';updA40();return;}
 const B=a4B(),pg=L4.pages[a4Pg];
 $('a4pages').innerHTML=L4.pages.map((p,i)=>`<button class="mini${i===a4Pg?' on':''}" data-a4p="${i}" title="Track Select ${i+1}">${i+1} &middot; ${esc(p.name)}</button>`).join('')+(L4.pages.length<8?'<button class="mini" id="a4add">+ Add a page</button>':'');
 document.querySelectorAll('[data-a4p]').forEach(b=>b.onclick=()=>{a4Pg=+b.dataset.a4p;a4Sel=-1;renderA40();});
 if($('a4add'))$('a4add').onclick=()=>{L4.pages.push({name:'Page '+(L4.pages.length+1),pads:{}});a4Pg=L4.pages.length-1;a4Sel=-1;renderA40();setTimeout(()=>{const i=$('a4name');if(i){i.focus();i.select();}},0);};
 let h='';
 for(let r=0;r<5;r++)for(let c=0;c<8;c++){const n=(4-r)*8+c,t=pg.pads[n];
  if(!t){h+=`<div class="pad empty${a4Sel===n?' sel':''}" data-a4="${n}" title="${a4rc(n)} - empty"><div class="t">empty</div></div>`;continue;}
  const b=B[t],on=a4On(pg,n,b),off=a4Off(pg,n,b);
  h+=`<div class="pad${a4Sel===n?' sel':''}${b?'':' miss'}" data-a4="${n}" draggable="true" style="background:linear-gradient(180deg,rgba(0,0,0,0) 35%,rgba(0,0,0,.6)),#${b?PAL[off]:'151820'}" title="${esc(t)} - ${a4rc(n)}${b?'':' - not in ShowXpress!'}"><div class="on" style="background:#${b?PAL[on]:'444444'}"></div><div class="t">${esc(t)}</div><div class="p">${b?esc(b.pageName):'not in ShowXpress!'}</div></div>`;}
 $('a4grid').innerHTML=h;document.querySelectorAll('[data-a4]').forEach(e=>e.onclick=()=>{const n=+e.dataset.a4;a4Sel=a4Sel===n?-1:n;renderA40();if(a4Sel>=0){const q=$('a4q');if(q)q.focus();}});a4Dnd();
 if(a4Sel>=0){const cur=pg.pads[a4Sel];
  const own=!!(cur&&pg.colors[a4Sel]),cb=B[cur];
  $('a4side').innerHTML=`<h3>Pad: ${a4rc(a4Sel)}</h3><div class="kv"><span>Plays</span><b>${cur?esc(cur)+(B[cur]?' <span class="tag">'+esc(B[cur].pageName)+'</span>':' <span style="color:var(--red)">&mdash; not in ShowXpress!</span>'):'nothing yet'}</b>`+
   (cur&&cb?`<span>Light</span><b><span class="sw" style="background:#${PAL[a4On(pg,a4Sel,cb)]}"></span>playing &nbsp; <span class="sw" style="background:#${PAL[a4Off(pg,a4Sel,cb)]}"></span>idle &nbsp;<span class="tag${own?' blue':''}">${own?'own':'from ShowXpress'}</span></b>`:'')+`</div>`+
   (cur&&cb?`<details class="a4col"${own||a4ColOpen?' open':''}><summary>Pad colour</summary><div class="pcl"><span>Colour while playing</span><div class="pals">${a4SwRow('on',a4On(pg,a4Sel,cb))}</div><span>Colour when idle</span><div class="pals">${a4SwRow('off',a4Off(pg,a4Sel,cb))}</div></div>`+
    `<div class="row" style="margin:6px 0 10px"><button class="mini" id="a4colx"${own?'':' disabled'}>Use the ShowXpress button colour</button></div></details>`:'')+
   `<input type="text" id="a4q" placeholder="Search ShowXpress buttons&hellip;" value="${esc(a4Q)}"><div class="a4list" id="a4list"></div>`+
   `<p class="sub" style="margin:0 0 10px">Tap a button to put it on this pad &mdash; then it moves on to the next pad, so you can fill a row quickly.</p><div class="row"><button id="a4clr"${cur?'':' disabled'}>Clear this pad</button><button id="a4done">Done</button></div>`;
  $('a4q').oninput=e=>{a4Q=e.target.value;a4List();};a4List();
  $('a4clr').onclick=()=>{delete pg.pads[a4Sel];delete pg.colors[a4Sel];renderA40();};
  const dt=document.querySelector('#a4side .a4col');if(dt)dt.ontoggle=()=>{a4ColOpen=dt.open;};
  document.querySelectorAll('[data-a4sw]').forEach(e=>e.onclick=()=>{const c=pg.colors[a4Sel]||{on:a4On(pg,a4Sel,cb),off:a4Off(pg,a4Sel,cb)};c[e.dataset.a4sw]=+e.dataset.v;pg.colors[a4Sel]=c;a4ColOpen=true;renderA40();});
  if($('a4colx'))$('a4colx').onclick=()=>{delete pg.colors[a4Sel];renderA40();};$('a4done').onclick=()=>{a4Sel=-1;renderA40();};}
 else{const used=Object.keys(pg.pads).length,pn=[...new Set((Q4.buttons||[]).map(b=>b.pageName))];
  $('a4side').innerHTML=`<h3>Page ${a4Pg+1}</h3><div class="kv"><span>Name</span><b><input type="text" id="a4name" maxlength="30" value="${esc(pg.name)}"></b><span>Pads</span><b>${used} of 40 used</b><span>On the APC40</span><b>Track Select ${a4Pg+1}</b></div>`+
   `<p class="sub" style="margin:0 0 6px">Tap a pad to choose what it plays and its colour (pads take the ShowXpress button colour until you pick one). Drag a pad to move it (onto another pad to swap, onto a page tab to send it to that page). Right-click a pad for more.</p>`+
   `<div style="margin:10px 0"><select id="a4fill"><option value="">Fill the empty pads from a ShowXpress page&hellip;</option>${pn.map(n=>`<option>${esc(n)}</option>`).join('')}</select></div>`+
   `<div class="row">${a4Pg>0?'<button class="mini" id="a4left">&larr; Move page left</button>':''}${a4Pg<L4.pages.length-1?'<button class="mini" id="a4right">Move page right &rarr;</button>':''}${L4.pages.length>1?'<button class="mini" id="a4del">Delete this page</button>':''}${used?'<button class="mini" id="a4clear">Clear all pads</button>':''}</div>`;
  $('a4name').oninput=e=>{pg.name=e.target.value;const b=document.querySelector('[data-a4p="'+a4Pg+'"]');if(b)b.innerHTML=(a4Pg+1)+' &middot; '+esc(pg.name);updA40();};
  $('a4name').onchange=e=>{if(!pg.name.trim()){pg.name='Page '+(a4Pg+1);renderA40();}};
  $('a4fill').onchange=e=>{const nm=e.target.value;if(!nm)return;const have=new Set(Object.values(pg.pads));let n=32,add=0,left=0;
   (Q4.buttons||[]).filter(b=>b.pageName===nm&&!b.dup&&!have.has(b.title)).forEach(b=>{while(n>=0&&pg.pads[n])n=a4Next(n);if(n<0){left++;return;}pg.pads[n]=b.title;add++;n=a4Next(n);});
   renderA40();a4Say(add+' button(s) from '+esc(nm)+' put on the pads'+(left?' &mdash; '+left+' didn&rsquo;t fit':'')+'.');};
  const sw=(a,b)=>{const x=L4.pages[a];L4.pages[a]=L4.pages[b];L4.pages[b]=x;a4Pg=b;renderA40();};
  if($('a4left'))$('a4left').onclick=()=>sw(a4Pg,a4Pg-1);if($('a4right'))$('a4right').onclick=()=>sw(a4Pg,a4Pg+1);
  if($('a4del'))$('a4del').onclick=()=>{if(!confirm('Delete page '+(a4Pg+1)+' ('+pg.name+')?'))return;L4.pages.splice(a4Pg,1);a4Pg=Math.max(0,a4Pg-1);renderA40();};
  if($('a4clear'))$('a4clear').onclick=()=>{if(!confirm('Clear every pad on '+pg.name+'?'))return;pg.pads={};pg.colors={};renderA40();};}
 const FD=['1','2','3','4','5','6','7','8','9'];
 $('a4faders').innerHTML=FD.map(f=>`<div class="fd"><b>${f==='9'?'Master fader':'Fader '+f}</b><select data-a4f="${f}"><option value="">nothing</option>${(Q4.faders||[]).map(x=>`<option value="${x.k}"${L4.faders[f]!==undefined&&+L4.faders[f]===x.k?' selected':''}>${esc(x.caption||'Fader '+(x.k+1))} ${x.type}</option>`).join('')}</select></div>`).join('');
 document.querySelectorAll('[data-a4f]').forEach(s=>s.onchange=()=>{if(s.value==='')delete L4.faders[s.dataset.a4f];else L4.faders[s.dataset.a4f]=+s.value;updA40();});
 a4Conn();updA40();}
// drag a pad onto another pad (swap) or onto a page tab (same spot on that page); right-click = menu
let a4Drag=null;
function a4Move(fp,f,tp,to){if(fp===tp&&f===to)return;const a=L4.pages[fp].pads,b=L4.pages[tp].pads,x=a[f],y=b[to];if(!x)return;
 const ca=L4.pages[fp].colors,cb=L4.pages[tp].colors,cx=ca[f],cy=cb[to];
 if(y)a[f]=y;else delete a[f];b[to]=x;if(cy)ca[f]=cy;else delete ca[f];if(cx)cb[to]=cx;else delete cb[to];if(fp===a4Pg&&a4Sel===f)a4Sel=tp===a4Pg?to:-1;else if(tp===a4Pg&&a4Sel===to)a4Sel=f;}
function a4Dnd(){const off=()=>document.querySelectorAll('.a4drop').forEach(x=>x.classList.remove('a4drop'));
 document.querySelectorAll('#a4grid [data-a4]').forEach(e=>{const n=+e.dataset.a4;
  e.ondragstart=ev=>{a4Drag=n;ev.dataTransfer.effectAllowed='move';ev.dataTransfer.setData('text/plain',String(n));ctxClose();};
  e.ondragend=()=>{a4Drag=null;off();};
  e.ondragover=ev=>{if(a4Drag===null)return;ev.preventDefault();ev.dataTransfer.dropEffect='move';e.classList.add('a4drop');};
  e.ondragleave=()=>e.classList.remove('a4drop');
  e.ondrop=ev=>{ev.preventDefault();off();if(a4Drag===null)return;const f=a4Drag;a4Drag=null;a4Move(a4Pg,f,a4Pg,n);renderA40();};
  e.oncontextmenu=ev=>{ev.preventDefault();const t=L4.pages[a4Pg].pads[n];
   ctxOpen(ev.clientX,ev.clientY,(t||'Empty pad')+' - '+a4rc(n),[
    {h:t?'Change the button&hellip;':'Choose a button&hellip;',go:()=>{a4Sel=n;renderA40();const q=$('a4q');if(q)q.focus();}},
    {h:'Pad colour&hellip;',off:!t||!a4B()[t],go:()=>{a4Sel=n;a4ColOpen=true;renderA40();}},
    {h:'Use the ShowXpress button colour',off:!L4.pages[a4Pg].colors[n],go:()=>{delete L4.pages[a4Pg].colors[n];renderA40();}},
    {h:'Clear this pad',off:!t,go:()=>{delete L4.pages[a4Pg].pads[n];delete L4.pages[a4Pg].colors[n];if(a4Sel===n)a4Sel=-1;renderA40();}}]);};});
 document.querySelectorAll('#a4pages [data-a4p]').forEach(b=>{const i=+b.dataset.a4p;if(i===a4Pg)return;
  b.ondragover=ev=>{if(a4Drag===null)return;ev.preventDefault();ev.dataTransfer.dropEffect='move';b.classList.add('a4drop');};
  b.ondragleave=()=>b.classList.remove('a4drop');
  b.ondrop=ev=>{ev.preventDefault();off();if(a4Drag===null)return;const f=a4Drag,t=L4.pages[a4Pg].pads[f],had=L4.pages[i].pads[f];a4Drag=null;a4Move(a4Pg,f,i,f);renderA40();
   a4Say(esc(t)+' moved to '+esc(L4.pages[i].name)+' (same spot)'+(had?' &mdash; '+esc(had)+' came back here in its place':'')+'.');};});}
// the button list closes when you click anywhere else (or press Esc)
document.addEventListener('pointerdown',e=>{if(a4Sel<0||curTab()!=='apc40'||!e.target.closest)return;if(e.target.closest('#a4grid,#a4side,#a4pages,#ctxm,.bar'))return;a4Sel=-1;renderA40();});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&a4Sel>=0&&curTab()==='apc40'){a4Sel=-1;renderA40();}});
function a4List(){const e=$('a4list');if(!e)return;const pg=L4.pages[a4Pg],cur=pg.pads[a4Sel],q=a4Q.trim().toLowerCase();let h='',g=null;
 (Q4.buttons||[]).filter(b=>!b.dup&&(!q||b.title.toLowerCase().includes(q)||b.pageName.toLowerCase().includes(q))).forEach(b=>{if(b.pageName!==g){g=b.pageName;h+=`<div class="a4g">${esc(g)}</div>`;}
  h+=`<div class="a4b${b.title===cur?' cur':''}" data-a4t="${esc(b.title)}"><span class="sw" style="background:#${PAL[b.on]}"></span>${esc(b.title)}</div>`;});
 e.innerHTML=h||'<p class="sub" style="margin:8px">No button matches.</p>';
 e.querySelectorAll('[data-a4t]').forEach(x=>x.onclick=()=>{if(pg.pads[a4Sel]!==x.dataset.a4t)delete pg.colors[a4Sel];pg.pads[a4Sel]=x.dataset.a4t;a4Sel=a4Next(a4Sel);const st=e.scrollTop;renderA40();const l=$('a4list');if(l)l.scrollTop=st;});}
function updA40(){if(!$('a4save'))return;const ok=!!(Q4&&Q4.ok),d=a4Dirty();$('a4save').disabled=!ok||!d;$('a4undo').disabled=!ok||!d;if(ok){stateTag('a4state',d);if(!d)$('a4state').textContent='✓ Saved';}
 $('a4hint').innerHTML=a4Msg||(!ok?'':d?'Not saved yet. Saving only changes SX Studio&rsquo;s own APC40 settings &mdash; ShowXpress can stay open.':'The APC40 is using these pages.');}
$('a4refresh').onclick=loadA40;
$('a4undo').onclick=()=>{L4=a4Fix(Q4.layout);a4Pg=Math.min(a4Pg,L4.pages.length-1);a4Sel=-1;renderA40();};
$('a4save').onclick=async()=>{busy(true,'Saving the APC40 pages…');let r;try{r=await api('/api/apc40/save',{layout:L4});}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}busy(false);
 if(r.ok){Q4=r;L4=a4Fix(r.layout);if(r.status)a4St=r.status;a4Pg=Math.min(a4Pg,L4.pages.length-1);renderA40();a4Say('&#10003; Saved &mdash; the APC40 uses it straight away.');}
 else a4Say('<span style="color:var(--red)">Not saved: '+esc(r.error||'unknown problem')+'</span>');};

// ---------------- Speed faders
let SP=null,spF={},spOnly=-1;
function spDirty(){return !!(SP&&SP.ok&&SP.buttons.some(b=>spF[b.sec]!==b.fader));}
async function loadSpeed(){SP=await getJ('/api/speed');spF={};if(SP.ok)SP.buttons.forEach(b=>spF[b.sec]=b.fader);renderSpeed();}
function bInfo(b){if(b.missing)return['scene file missing','no'];if(b.gen)return['Generator movement'+(b.beat?' &middot; beat sync':''),''];
 if(b.steps>1)return[b.steps+' steps'+(b.beat?' &middot; beat sync':''),''];return['1 step &mdash; speed does nothing','no'];}
function fOpts(sel,first){return (first?`<option value="">${first}</option>`:'')+SP.faders.map(f=>`<option value="${f.k}"${f.k===sel?' selected':''}>${esc(f.caption||('Fader '+(f.k+1)))}</option>`).join('');}
function renderSpeed(){if(!SP)return;
 if(showErr('sperr',SP)){$('splegend').innerHTML=$('splist').innerHTML='';$('spstate').style.display='none';updSpeed();return;}
 $('splegend').innerHTML=SP.faders.map(f=>{const n=SP.buttons.filter(b=>spF[b.sec]===f.k).length;return `<div class="lg${spOnly===f.k?' on':''}" data-f="${f.k}" title="show only these"><b>${n}</b>${esc(f.caption||('Fader '+(f.k+1)))}</div>`;}).join('');
 document.querySelectorAll('.lg').forEach(e=>e.onclick=()=>{spOnly=spOnly===+e.dataset.f?-1:+e.dataset.f;renderSpeed();});
 const q=$('spq').value.trim().toLowerCase(),pages=[];
 SP.buttons.forEach(b=>{if(spOnly>=0&&spF[b.sec]!==spOnly)return;if(q&&!(b.title+' '+b.scene+' '+b.pageName).toLowerCase().includes(q))return;
  let g=pages.find(x=>x.page===b.page);if(!g)pages.push(g={page:b.page,name:b.pageName,bs:[]});g.bs.push(b);});
 $('splist').innerHTML=pages.map(g=>`<div class="spg"><div class="gh"><h3>${esc(g.name.toUpperCase())}</h3><span class="cnt">${g.bs.length}</span><div class="grow"></div><select data-pg="${g.page}">${fOpts(-1,'Set all on this page&hellip;')}</select></div>`+
  g.bs.map(b=>{const [t,c]=bInfo(b),chg=spF[b.sec]!==b.fader;return `<div class="sp${chg?' chg':''}"><div><b>${esc(b.title||b.scene)}</b>${chg?' <span class="tag blue">changed</span>':''}</div><div class="i ${c}">${t}</div><select data-sec="${esc(b.sec)}">${fOpts(spF[b.sec])}</select></div>`;}).join('')+'</div>').join('')||'<p class="sub" style="margin-top:14px">No buttons match.</p>';
 document.querySelectorAll('[data-sec]').forEach(s=>s.onchange=()=>{spF[s.dataset.sec]=+s.value;renderSpeed();});
 document.querySelectorAll('[data-pg]').forEach(s=>s.onchange=()=>{if(s.value==='')return;const k=+s.value,g=pages.find(x=>x.page===+s.dataset.pg);
  if(g)g.bs.forEach(b=>spF[b.sec]=k);renderSpeed();});
 stateTag('spstate',spDirty());$('foot').textContent='Show: '+SP.show;updSpeed();}
function updSpeed(){const ok=!!(SP&&SP.ok),d=spDirty();$('spsave').disabled=!ok||!d;$('spundo').disabled=!ok||!d;
 $('sphint').innerHTML=!ok?'':sxHint('save')??(d?SP.buttons.filter(b=>spF[b.sec]!==b.fader).length+' button(s) changed. Only the speed fader setting in live.ini changes.':'Every button matches the show.');}
$('spq').oninput=renderSpeed;$('sprefresh').onclick=loadSpeed;$('spundo').onclick=()=>{SP.buttons.forEach(b=>spF[b.sec]=b.fader);renderSpeed();};
$('spsave').onclick=()=>saveTo('/api/speed/apply',{changes:SP.buttons.filter(b=>spF[b.sec]!==b.fader).map(b=>({sec:b.sec,title:b.title,fader:spF[b.sec]}))},'Saving speed faders…',async()=>{await loadSpeed();A=null;H=null;},'speed');

// ---------------- Health check (check / fix / revert / keep)
let H=null;
async function loadHealth(){$('hlsum').innerHTML='Checking the show&hellip;';$('hllist').innerHTML='';$('hlapplied').innerHTML='';H=await getJ('/api/health');renderHealth();}
function renderHealth(){if(!H)return;if(!H.ok){$('hlsum').innerHTML='<span style="color:var(--red)">'+esc(H.error)+'</span>';$('hllist').innerHTML='';$('hlapplied').innerHTML='';updHealth();return;}
 const is=H.issues||[],ap=H.applied||[],c=l=>is.filter(i=>i.level===l).length;
 const row=i=>`<div class="iss ${i.level}"><div class="ic">${i.level==='error'?'!':i.level==='warn'?'?':'i'}</div><div class="grow"><b>${esc(i.title)}</b><div class="d">${esc(i.detail)}</div>${i.advice?`<div class="fx"><b>Fix:</b> ${esc(i.advice)}</div>`:''}</div>${i.fix?`<div class="act"><button class="mini primary hfix" data-k="${esc(i.fix.key)}">${esc(i.fix.label)}</button></div>`:''}</div>`;
 $('hlapplied').innerHTML=ap.length?`<div class="applied"><h3>&#10003; Fixes you applied (${ap.length})</h3>${ap.map(a=>`<div class="iss done"><div class="ic">&#10003;</div><div class="grow"><b>${esc(a.title)}</b><div class="d">${esc(a.label)} &middot; ${esc(a.time)} &mdash; <b>Revert</b> puts it back as it was, <b>Keep</b> forgets the backup.</div></div><div class="act"><button class="mini hrev" data-i="${esc(a.id)}">&#8630; Revert</button><button class="mini hkeep" data-i="${esc(a.id)}">Keep</button></div></div>`).join('')}</div>`:'';
 const nf=is.filter(i=>i.fix).length;
 $('hlsum').innerHTML=`Checked <b>${H.buttons}</b> buttons and <b>${H.scenes}</b> scenes &mdash; <b style="color:var(--red)">${c('error')}</b> problem(s) &middot; <b style="color:var(--amber)">${c('warn')}</b> warning(s) &middot; <b style="color:var(--blue)">${c('info')}</b> note(s)`+(nf?` &middot; <b style="color:var(--green)">${nf}</b> can be fixed here`:'');
 const main=is.filter(i=>i.level!=='info'),info=is.filter(i=>i.level==='info');
 $('hllist').innerHTML=(main.length?main.map(row).join(''):'<p style="color:var(--green);margin:6px 0">&#10003; No problems found.</p>')+(info.length?`<details><summary>${info.length} note(s) &mdash; probably fine</summary>${info.map(row).join('')}</details>`:'');
 document.querySelectorAll('.hfix').forEach(b=>b.onclick=()=>hlFix(b.dataset.k));
 document.querySelectorAll('.hrev').forEach(b=>b.onclick=()=>hlRev(b.dataset.i,false));
 document.querySelectorAll('.hkeep').forEach(b=>b.onclick=()=>hlKeep(b.dataset.i));
 $('foot').textContent='Show: '+H.show;updHealth();}
function updHealth(){const ok=!!(H&&H.ok);document.querySelectorAll('.hfix').forEach(b=>b.disabled=!ok);document.querySelectorAll('.hrev').forEach(b=>b.disabled=sxOpen||!ok);
 $('hlhint').innerHTML=sxHint('apply or revert a fix')??'Checking changes nothing. A fix changes only what it says, and can be reverted at the top of this tab.';}
async function hlAfter(){if(!dirty())S=null;if(!rgDirty())R=null;if(!apDirty())A=null;if(!spDirty())SP=null;await loadHealth();}
async function hlFix(k){const i=(H.issues||[]).find(x=>x.fix&&x.fix.key===k);if(!i)return;
 if(!await ask('Apply this fix?','<b>'+esc(i.title)+'</b><br><br>'+esc(i.advice)+'<br><br>You can revert it afterwards at the top of this tab.',i.fix.label))return;
 await saveTo('/api/health/fix',{key:k},'Applying the fix…',hlAfter,'fix');}
async function hlRev(id,force){const a=(H.applied||[]).find(x=>x.id===id);if(!a)return;
 if(!force&&!await ask('Revert this fix?','<b>'+esc(a.title)+'</b><br><br>Puts back what &ldquo;'+esc(a.label)+'&rdquo; changed, exactly as it was before.','Revert'))return;
 busy(true,'Reverting…');let r;try{r=await api('/api/health/revert',{id,force:!!force});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 if(r.ok&&r.conflict){if(await ask('Changed since the fix','<ul>'+r.conflict.map(x=>'<li>'+esc(x)+'</li>').join('')+'</ul>Reverting puts back the version from before the fix, so those later changes are lost too.','Revert anyway'))return hlRev(id,true);return;}
 if(r.ok)await hlAfter();showResult(r,'revert');}
async function hlKeep(id){const a=(H.applied||[]).find(x=>x.id===id);if(!a)return;
 if(!await ask('Keep this fix?','The backup of <b>'+esc(a.title)+'</b> is deleted, so it can&rsquo;t be reverted any more. The fix itself stays.','Keep it'))return;
 await saveTo('/api/health/keep',{id},'Saving…',loadHealth,'keep');}
$('hlrun').onclick=loadHealth;

// ---------------- Rig Test (rig_test.ps1)
let RT=null,rtA={},rtX=false,rtSlot=null;
const rtHead=id=>RT.heads.find(h=>h.id===id);
const rtUsed=k=>rtX||!RT.slots.find(s=>s.key===k).extra;
function rtDirty(){if(!RT||!RT.ok)return false;const a=RT.assign||{},ks=new Set([...Object.keys(a),...Object.keys(rtA)]);return rtX!==!!RT.extra||[...ks].some(k=>(a[k]||'')!==(rtA[k]||''));}
async function loadRt(){RT=await getJ('/api/rt');rtA={};rtX=false;if(RT.ok){Object.assign(rtA,RT.assign||{});rtX=!!RT.extra;}renderRt();}
function lookHtml(h){return `<span class="dot${h.flash?' fl':''}" style="background:#${h.hex}"></span>`;}
function renderRt(){if(!RT)return;
 if(showErr('rterr',RT)){['rtmap','rtlegend'].forEach(i=>$(i).innerHTML='');$('rtinst').style.display='none';$('rtstate').style.display='none';updRt();return;}
 const ins=RT.install||{},ib=$('rtinst');
 if(!ins.scene||!ins.button){ib.style.display='block';ib.innerHTML='The <b>RIG ID</b> button isn&rsquo;t in the show yet. <button id="rtinstb" class="mini primary" style="margin-left:8px">Add RIG ID to the SETUP page</button>';
  $('rtinstb').onclick=()=>saveTo('/api/rt/install',{},'Adding RIG ID…',loadRt,'install');}
 else if(ins.old){ib.style.display='block';ib.innerHTML='The <b>RIG ID</b> scene in the show is the old one (amber instead of light green, no visible flash). <button id="rtinstb" class="mini primary" style="margin-left:8px">Update RIG ID</button>';
  $('rtinstb').onclick=()=>saveTo('/api/rt/install',{},'Updating RIG ID…',loadRt,'install');}else ib.style.display='none';
 $('rtlegend').innerHTML=RT.heads.map(h=>`<div>${lookHtml(h)}<b>#${h.num}</b>${esc(h.look)}${h.flash?' flashing':''}</div>`).join('');
 $('rtextra').checked=rtX;
 const a0=RT.assign||{},placed=new Set(Object.entries(rtA).filter(([k,v])=>v&&rtUsed(k)).map(([k,v])=>v));
 const tower=t=>{const ss=RT.slots.filter(s=>s.tower===t),ex=ss[0].extra;
  return `<div class="tw${ex&&!rtX?' off':''}" style="grid-column:${t[1]==='l'?1:t[1]==='m'?2:3};grid-row:${t[0]==='t'?1:3}"><h4>${esc(ss[0].towerName)} tower</h4><div class="pr">`+ss.map(s=>{const id=rtA[s.key],h=id&&rtHead(id),chg=(a0[s.key]||'')!==(id||'');
   return `<div class="slot${h?' set':''}${chg?' chg':''}" data-slot="${s.key}"><span class="sd">${s.side} mover</span>${h?`${lookHtml(h)}<b>#${h.num}</b><br><small>${esc(h.look)}${h.flash?' flashing':''}</small>`:'<small>tap to set</small>'}</div>`;}).join('')+'</div></div>';};
 const spare=RT.heads.filter(h=>!placed.has(h.id));
 $('rtmap').innerHTML=['tl','tm','tr','bl','bm','br'].map(tower).join('')+
  `<div class="mid">${spare.length?`<div>Not on a truss &mdash; grouped in the middle of the 2D page</div><div class="sp2">${spare.map(h=>`<span>#${h.num}</span>`).join('')}</div>`:'Every 140 is on a truss'}</div><div class="dj">&#9650; DJ BOOTH (you) &#9650;</div>`;
 document.querySelectorAll('[data-slot]').forEach(e=>e.onclick=()=>rtOpen(e.dataset.slot));
 stateTag('rtstate',rtDirty());$('foot').textContent='Show: '+RT.show+(RT.saved?' · Rig Test last saved '+RT.saved.replace('T',' '):'');updRt();}
function rtOpen(k){rtSlot=k;const s=RT.slots.find(x=>x.key===k),cur=rtA[k];$('rtpt').textContent=s.towerName+' tower — '+s.side+' mover';
 const where=id=>{const e=Object.entries(rtA).find(([kk,v])=>v===id&&kk!==k&&rtUsed(kk));if(!e)return'';const o=RT.slots.find(x=>x.key===e[0]);return 'now '+o.towerName.toLowerCase()+' '+o.side;};
 const grid=fl=>`<div class="pick">${RT.heads.filter(h=>h.flash===fl).map(h=>`<div data-pk="${h.id}" class="${h.id===cur?'cur':''}">${lookHtml(h)}#${h.num}<small>${esc(h.look)}</small><small>${esc(where(h.id))||'&nbsp;'}</small></div>`).join('')}</div>`;
 $('rtpb').innerHTML='<div class="gh"><h3>SOLID</h3></div>'+grid(false)+'<div class="gh"><h3>FLASHING</h3></div>'+grid(true);
 document.querySelectorAll('[data-pk]').forEach(e=>e.onclick=()=>{const id=e.dataset.pk;for(const kk of Object.keys(rtA))if(rtA[kk]===id)delete rtA[kk];rtA[k]=id;$('rtpick').style.display='none';renderRt();});
 $('rtpick').style.display='flex';}
$('rtpnone').onclick=()=>{delete rtA[rtSlot];$('rtpick').style.display='none';renderRt();};
$('rtpcancel').onclick=()=>{$('rtpick').style.display='none';};
$('rtextra').onchange=e=>{rtX=e.target.checked;renderRt();};
function rtCount(){return Object.entries(rtA).filter(([k,v])=>v&&rtUsed(k)).length;}
function updRt(){const ok=!!(RT&&RT.ok),d=rtDirty(),n=ok?rtCount():0;$('rtsave').disabled=!ok||!n;$('rtundo').disabled=!ok||!d;$('rtclear').disabled=!ok||!Object.keys(rtA).length;
 $('rthint').innerHTML=!ok?'':sxHint('save (it rewrites the 2D view when it closes)')??(!n?'<span style="color:var(--amber)">Put at least one mover on a truss.</span>':n+' mover(s) on trusses. Only the 140 positions in the 2D view change'+($('rtrig').checked?', plus Tonight\'s Rig and SKIP FLASH.':'.'));}
$('rtrig').onchange=updRt;$('rtrefresh').onclick=loadRt;
$('rtundo').onclick=()=>{rtA=Object.assign({},RT.assign||{});rtX=!!RT.extra;renderRt();};
$('rtclear').onclick=()=>{rtA={};renderRt();};
$('rtsave').onclick=()=>{const a={};for(const [k,v] of Object.entries(rtA))if(v&&rtUsed(k))a[k]=v;
 saveTo('/api/rt/apply',{assign:a,extra:rtX,rig:$('rtrig').checked},'Saving the 2D view…',async()=>{await loadRt();R=null;S=null;H=null;},'rt');};

// ---------------- Pre-show check (preshow.ps1 + the health check)
let PRE=[];
async function loadPre(){$('presum').innerHTML='Checking&hellip;';$('prelist').innerHTML='';const [p,h,gd]=await Promise.all([getJ('/api/pre'),H?Promise.resolve(H):getJ('/api/health'),getJ('/api/gdrive')]);
 if(h&&h.ok)H=h;if(gd&&gd.ok){G=gd;updGd();}if(!p.ok){$('presum').innerHTML='<span style="color:var(--red)">'+esc(p.error)+'</span>';return;}
 const it=[...p.items];
 if(h&&h.ok){const e=(h.issues||[]).filter(i=>i.level==='error').length,w=(h.issues||[]).filter(i=>i.level==='warn').length,fx={key:'tab:health',label:'Open Health Check'};
  it.splice(2,0,e?{group:'Show',level:'error',title:'Health Check: '+e+' problem(s) in the show',detail:w?w+' warning(s) too.':'',advice:'Open the Health Check tab and look at the red ones.',fix:fx}:
   w?{group:'Show',level:'warn',title:'Health Check: '+w+' warning(s)',detail:'No real problems.',advice:'Have a look in the Health Check tab if you have time.',fix:fx}:{group:'Show',level:'ok',title:'Health Check: no problems in the show',detail:'',advice:''});}
 if(gd&&gd.ok){const today=gd.last&&new Date(gd.last).toDateString()===new Date().toDateString();
  it.push(!gd.found?{group:'Show',level:'info',title:'Google Drive not found on this laptop',detail:'The show can&rsquo;t be backed up to Google Drive > AWAAZ > Lighting.',advice:'Install Google Drive for desktop and sign in.'}:
   today?{group:'Show',level:'ok',title:'Backed up to Google Drive '+fmtT(gd.last),detail:'',advice:''}:
   {group:'Show',level:'warn',title:gd.last?'Last backed up to Google Drive '+fmtT(gd.last):'Show not backed up to Google Drive yet',detail:'A copy in Google Drive > AWAAZ > Lighting saves the night if this laptop dies.',advice:'Close ShowXpress (save first), sync, then open it again.',fix:{key:'gsync',label:'Sync now'}});}
 PRE=it;
 const c=l=>it.filter(i=>i.level===l).length;
 $('presum').innerHTML=c('error')?`<b style="color:var(--red)">${c('error')} thing(s) to fix</b> before the show &middot; ${c('warn')} to check`:c('warn')?`<b style="color:var(--amber)">${c('warn')} thing(s) to check</b> &mdash; nothing broken`:'<b style="color:var(--green)">&#10003; All good &mdash; ready for the show</b>';
 const groups=[...new Set(it.map(i=>i.group))];
 $('prelist').innerHTML=groups.map(g=>`<div class="pgrp"><h3>${esc(g.toUpperCase())}</h3>`+it.filter(i=>i.group===g).map(i=>`<div class="iss ${i.level}"><div class="ic">${i.level==='ok'?'&#10003;':i.level==='error'?'!':i.level==='warn'?'?':'i'}</div><div class="grow"><b>${esc(i.title)}</b>${i.detail?`<div class="d">${esc(i.detail)}</div>`:''}${i.advice&&i.level!=='ok'?`<div class="fx"><b>Fix:</b> ${esc(i.advice)}</div>`:''}</div>${i.fix&&i.level!=='ok'?`<div class="act"><button class="mini primary pfix" data-k="${esc(i.fix.key)}">${esc(i.fix.label)}</button></div>`:''}</div>`).join('')+'</div>').join('');
 document.querySelectorAll('.pfix').forEach(b=>b.onclick=()=>preFix(b.dataset.k));updPre();
 $('prehint').textContent='Checked at '+new Date().toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})+'. Checking changes nothing; a fix button changes only what it says.';$('foot').textContent='Show: '+p.show;}
function updPre(){document.querySelectorAll('.pfix').forEach(b=>{const k=b.dataset.k;b.disabled=sxOpen&&(k==='gsync'||k==='launch');b.title=b.disabled&&k==='gsync'?'Close ShowXpress first (save first)':'';});
 $('pregd').disabled=!(G&&G.ok&&G.found);}
async function preFix(k){const i=PRE.find(x=>x.fix&&x.fix.key===k);if(!i)return;
 if(k.startsWith('tab:'))return setTab(k.slice(4));if(k==='launch')return sxLaunch();if(k==='gsync')return gdSync();
 const msg={sleep:'Sets <b>When plugged in, PC goes to sleep after</b> to <b>Never</b>.',usb:'Turns <b>USB selective suspend</b> off when plugged in, so Windows never powers down the APC mini or the DMX interface.',restart:'<b>Windows restarts in 1 minute</b> to finish its updates. Save and close ShowXpress first. (Changed your mind? Run <b>shutdown /a</b>.)'}[k];
 if(!await ask(i.title,msg||'',i.fix.label))return;
 await saveTo('/api/pre/fix',{key:k},'Applying the fix…',loadPre,'prefix');}
$('prerun').onclick=()=>{H=null;loadPre();};$('pregd').onclick=()=>gdSync();

// ---------------- Aim Movers: Dance Floor / Room
const AIMTXT={floor:{t:'Dance floor &mdash; tonight\'s aims',how:['<b>STEP 1 &middot; CENTER</b>Aim every head at the center of tonight\'s dancefloor &mdash; or just <b>one head per T-bar</b>: the head next to it gets the same aim (unless you aim that one too).','<b>STEP 2 &middot; CORNER</b>Optional: aim a head at the same corner (front-left from the DJ) to set its size. A copied head gets this too.','<b>THEN</b>Save, close ShowXpress, press Refresh below, check the heads and Apply &mdash; <b>DF CHECK</b> comes on by itself when ShowXpress opens again.'],
  depth:'Depth',size:'100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.',svg:'dashed = dancefloor · amber = patterns'},
 room:{t:'Room &mdash; AROUND ROOM for tonight',how:['<b>STEP 1 &middot; CENTER</b>Aim every head at the middle of where AROUND ROOM should sweep (the walls around the room).','<b>STEP 2 &middot; CORNER</b>Optional: aim a head at the front-left edge of that sweep (from the DJ) to set its size.','<b>THEN</b>Save, close ShowXpress, press Refresh below and Apply &mdash; <b>ROOM CHECK</b> comes on by itself when ShowXpress opens again.'],
  depth:'Height',size:'100% = AROUND ROOM reaches the edge you aimed. Width = across the room, Height = up and down the walls.',svg:'dashed = what you aimed · amber = AROUND ROOM'}};
function aimTxt(){const x=AIMTXT[aimMode];$('aimttl').innerHTML=x.t;$('aimhow').innerHTML=x.how.map(h=>'<div>'+h+'</div>').join('');$('dlab').textContent=x.depth;$('sizesub').textContent=x.size;$('svgl').textContent=x.svg;$('aimsc').textContent=aimMode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)';}
document.querySelectorAll('[data-am]').forEach(b=>b.onclick=()=>{if(aimMode===b.dataset.am)return;aimMode=b.dataset.am;document.querySelectorAll('[data-am]').forEach(x=>x.classList.toggle('on',x===b));
 aimTxt();remRefresh('aim',sxOpen&&!remRecent());$('aiminst').style.display='none';$('heads').innerHTML='';$('warnbox').style.display='none';$('result').className='card result';P=PM[aimMode];LD[aimMode]=0;render();load();});

// ---------------- ShowXpress remote (sx_remote.ps1): the Helper presses buttons in ShowXpress itself
let PEND=false,REMSEEN=null,REMAT=0,remWait=0,remBusy=false;const REMR={},REMBOX={rt:'rtrem',aim:'aimrem'};
function remSets(t){if(t==='rt')return [{label:'RIG ID',titles:['RIG ID']}];
 return aimMode==='room'?[{label:'ROOM AIM (ADJUST)',titles:['ROOM AIM (ADJUST)']},{label:'ROOM CHECK',titles:['ROOM CHECK']}]
  :[{label:'DF AIM (ADJUST)',titles:['DF AIM (ADJUST)']},{label:'DF CHECK 140 + 251',titles:['DF CHECK 140','DF CHECK 251']}];}
function curTab(){const b=document.querySelector('.tabs button[data-tab].on');return b?b.dataset.tab:'home';}
const isSetup=p=>/^\s*setup\s*$/i.test(p||'');
function remRecent(){return PEND||(REMAT&&Date.now()-REMAT<60000);}
async function remGet(p,b){try{return await api(p,b);}catch(e){return {ok:false,error:'Lost connection.'};}}
async function remRefresh(t,auto){if(!REMBOX[t])return null;const sets=remSets(t),box=$(REMBOX[t]);
 if(!REMR[t]){box.className='remrow on';box.innerHTML='<span>Checking ShowXpress&hellip;</span>';}
 const doAuto=auto&&sxOpen&&!(AUS&&AUS.running)&&!PEND;
 const r=doAuto?await remGet('/api/remote/press',{titles:sets[0].titles,solo:true,idle:true}):await remGet('/api/remote');
 r.auto=doAuto;if(doAuto&&r.connected&&!r.skipped&&(r.pressedNow||[]).length)r.note='&#10003; Turned on by SX Studio.';
 REMR[t]=r;if(curTab()===t)remDraw(t);return r;}
function remDraw(t){const box=$(REMBOX[t]),r=REMR[t],sets=remSets(t);box.className='remrow on';if(!r){box.innerHTML='';return;}let h;
 if(r.ok===false&&!r.setup)h='<div class="grow">'+esc(r.error||'')+'</div><button class="mini" data-rem="retry">Try again</button>';
 else if(!r.ready)h='<div class="grow"><b>Let SX Studio press '+esc(sets.map(s=>s.label).join(' / '))+' for you.</b> Turn on ShowXpress remote control once &mdash; it&rsquo;s saved in the show'+(sxOpen?' (done when ShowXpress next closes).':'.')+'</div><button class="mini primary" data-rem="enable">Turn on remote control</button>';
 else if(!r.open)h='<div class="grow">ShowXpress is closed. Open it and SX Studio turns on <b>'+esc(sets[0].label)+'</b> by itself.</div><button class="mini" data-rem="launch">&#9654; Launch ShowXpress</button>';
 else if(!r.connected)h='<div class="grow">'+esc(r.error||'')+'</div><button class="mini" data-rem="retry">Try again</button>';
 else{const on=new Set((r.pressed||[]).map(p=>p.title)),have=new Set(r.titles||[]),cur=sets.find(s=>s.titles.every(x=>on.has(x)));
  h='<div class="grow">'+(r.note?r.note+' ':'')+(r.skipped?'<b style="color:var(--amber)">Your show is playing</b> ('+esc((r.playing||[]).slice(0,4).join(', '))+((r.playing||[]).length>4?'&hellip;':'')+') &mdash; SX Studio didn&rsquo;t press anything, so it isn&rsquo;t cut. ':'')+
   (cur?'<b style="color:var(--green)">&#9679; '+esc(cur.label)+'</b> is on in ShowXpress.':on.size?'Playing: '+esc([...on].slice(0,5).join(', '))+(on.size>5?'&hellip;':''):'Nothing is playing in ShowXpress.')+'</div>'+
   sets.map((s,i)=>{const miss=s.titles.some(x=>!have.has(x));return '<button class="mini'+(cur===s?' son':'')+'" data-rem="set" data-i="'+i+'"'+(miss?' disabled title="Not in the show yet"':'')+'>'+esc(s.label)+'</button>';}).join('')+
   (on.size?'<button class="mini" data-rem="off">All off</button>':'');}
 box.innerHTML=h;box.querySelectorAll('[data-rem]').forEach(b=>b.onclick=()=>remAct(t,b.dataset.rem,+b.dataset.i));}
async function remEnable(after){if(!await ask('Turn on ShowXpress remote control?','Lets SX Studio press buttons in ShowXpress (RIG ID, DF CHECK, ROOM CHECK, Auto Show). It switches on <b>External App</b> in ShowXpress and remote access for every Live page, with a password only SX Studio uses. Only this computer connects to it.'+(sxOpen?'<br><br>ShowXpress is open, so it&rsquo;s done when you next close it.':''),'Turn it on'))return;
 await saveTo('/api/remote/enable',{},'Turning on the remote…',after,'remote');}
async function remAct(t,k,i){const sets=remSets(t),r=REMR[t];
 if(k==='retry')return remRefresh(t,false);
 if(k==='launch')return sxLaunch();
 if(k==='enable')return remEnable(async()=>{await remRefresh(t,false);});
 if(k==='off'){if(!await ask('Turn everything off?','Releases every button that is playing in ShowXpress.'+(AUS&&AUS.running?' The Auto Show keeps playing &mdash; stop it in its tab.':''),'All off'))return;
  REMR[t]=await remGet('/api/remote/off',{});remDraw(t);return;}
 if(k==='set'){const s=sets[i],pl=((r&&r.pressed)||[]).filter(p=>!isSetup(p.page)&&!s.titles.includes(p.title)).map(p=>p.title);
  if(pl.length&&!await ask('Turn off what is playing?','<b>'+esc(pl.slice(0,6).join(', '))+(pl.length>6?'&hellip;':'')+'</b> '+(pl.length>1?'are':'is')+' playing. Turning on '+esc(s.label)+' turns '+(pl.length>1?'them':'it')+' off.','Turn on '+s.label))return;
  REMR[t]=await remGet('/api/remote/press',{titles:s.titles,solo:true});remDraw(t);}}
function remPoll(r,was){PEND=!!r.pend;const a=AUS;AUS=r.auto||null;auPill();if(curTab()==='auto'&&(!!(a&&a.running)!==!!(AUS&&AUS.running)))auPlay();
 if(r.rem){REMAT=Date.parse(r.rem.at)||0;if(REMSEEN!==null&&r.rem.at!==REMSEEN){const t=curTab(),m=r.rem;
   const msg=m.ok?'&#10003; SX Studio turned on <b>'+esc(m.label)+'</b> &mdash; check the beams.':m.skipped?'Your show was playing, so <b>'+esc(m.label)+'</b> wasn&rsquo;t turned on.':'';
   if(REMBOX[t])remRefresh(t,false).then(x=>{if(x&&msg){x.note=msg;remDraw(t);}});}
  REMSEEN=r.rem.at;}else if(REMSEEN===null)REMSEEN='';
 if(!was&&r.open)remWait=Date.now();
 if(was&&!r.open){for(const k in REMBOX)if(REMR[k]){REMR[k]=null;if(curTab()===k)remRefresh(k,false);}}
 const t=curTab();
 if(remWait&&REMBOX[t]&&r.open&&!remBusy){if(Date.now()-remWait>90000)remWait=0;
  else if(!REMR[t]||!REMR[t].connected||(!REMR[t].auto&&!remRecent())){remBusy=true;remRefresh(t,!remRecent()).then(x=>{remBusy=false;if(x&&(x.connected||x.ready===false))remWait=0;});}}}

// ---------------- Auto Show (sx_remote.ps1 -Action Auto, settings in <show>/auto_show.json)
let AU=null,auC=null,AUS=null,auTried=[],auTaps=[],auPk=-1,auStF=false,auLastId='',auBpmT=0;
const AUBARS=[1,2,4,8,12,16,24,32,48,64];
const rid=()=>Array.from({length:8},()=>'0123456789abcdef'[Math.random()*16|0]).join('');
const clone=o=>JSON.parse(JSON.stringify(o));
function auDirty(){return !!(AU&&AU.ok&&auC&&JSON.stringify(auC)!==JSON.stringify(AU.config));}
async function loadAuto(){$('ausum').textContent='Loading…';AU=await getJ('/api/auto');if(AU.ok){auC=clone(AU.config);if(AU.status)AUS=AU.status;}renderAuto();}
function auBtn(t){return AU.buttons.find(b=>b.title===t&&!b.dup);}
function auSec(l){return l.bars*4*60/auC.bpm;}
// ShowXpress "swap" page (MOVEMENTS): one button at a time - several of them in one look can't play together
function auClash(l){const g={};for(const x of l.titles){const b=auBtn(x);if(b&&b.swap)(g[b.page]=g[b.page]||[]).push(x);}return Object.entries(g).filter(e=>e[1].length>1);}
function auSplit(i){const l=auC.looks[i],cl=auClash(l);if(!cl.length)return 0;const[pg,many]=cl.sort((a,b)=>b[1].length-a[1].length)[0];
 const rest=l.titles.filter(x=>!many.includes(x)),one=new Set(many);
 const nl=many.map((m,k)=>({id:k?rid():l.id,name:(many.length>1?m:l.name).slice(0,40),bars:l.bars,on:l.on,titles:rest.filter(x=>!(auBtn(x)&&auBtn(x).swap&&auBtn(x).page===pg)).concat([m])}));
 auC.looks.splice(i,1,...nl);return nl.length;}
async function auAskSplit(i){const l=auC.looks[i],cl=auClash(l);if(!cl.length)return;const[pg,many]=cl.sort((a,b)=>b[1].length-a[1].length)[0];
 if(!await ask('Make each one its own look?','<b>'+esc(pg)+'</b> plays one button at a time in ShowXpress, so <b>'+many.length+'</b> of them in one look can&rsquo;t play together &mdash; only the last would stay on.<br><br>Split it into <b>'+many.length+' looks</b> ('+esc(many.join(', '))+')'+(l.titles.length>many.length?', each keeping the other buttons of this look':'')+', so the Auto Show cycles through them?','Split into '+many.length+' looks'))return;
 const n=auSplit(i);auMsg('&#10003; Split into '+n+' looks of '+l.bars+' bars. Save to keep it.');auLooks();auPlay();updAuto();}
function fmtS(s){s=Math.max(0,Math.round(s));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0');}
function auMsg(h){$('aumsg').innerHTML=h||'';}
function renderAuto(){if(!AU)return;
 if(showErr('auerr',AU)){['aulooks','auplay'].forEach(i=>$(i).innerHTML='');$('ausum').textContent='';updAuto();return;}
 const rb=$('aurem');
 if(!AU.ready&&!AU.player&&!(AUS&&AUS.running&&AUS.target==='player')){rb.style.display='block';rb.innerHTML='The ShowXpress remote is off, so the Auto Show can&rsquo;t press anything yet. <button class="mini primary" id="auen" style="margin-left:8px">Turn on remote control</button>';$('auen').onclick=()=>remEnable(loadAuto);}
 else rb.style.display='none';
 document.querySelectorAll('[data-ao]').forEach(b=>b.classList.toggle('on',b.dataset.ao===auC.order));$('austop').value=auC.stop;$('auclean').checked=!!auC.clean;
 auLooks();auPlay();$('foot').textContent='Show: '+AU.show+' · Auto Show settings are kept in the show folder (auto_show.json)';updAuto();}
function auLooks(){const L=auC.looks,run=!!(AUS&&AUS.running);
 const act=L.filter(l=>l.on&&l.titles.length);
 $('ausum').innerHTML=L.length?'<b>'+act.length+'</b> of '+L.length+' look'+(L.length>1?'s':'')+' in the show &middot; one round &asymp; <b>'+fmtS(act.reduce((a,l)=>a+auSec(l),0))+'</b> at '+auC.bpm+' BPM':'';
 if(!L.length){$('aulooks').innerHTML='<p class="sub" style="margin:12px 0 0">No looks yet. A look is what plays at the same time &mdash; e.g. one movement + a colour + the uplights. To cycle through movements, make one look per movement. Build one in ShowXpress, then press <b>New look from what&rsquo;s playing</b> &mdash; or press <b>+ New look</b> and pick the buttons.</p>';return;}
 $('aulooks').innerHTML=L.map((l,i)=>{const cur=run&&AUS.lookId===l.id,bars=AUBARS.includes(l.bars)?AUBARS:[...AUBARS,l.bars].sort((a,b)=>a-b);
  const chips=l.titles.map((x,j)=>{const b=auBtn(x),bad=!b?'Not in the show (renamed or deleted?)':!b.reach?'Its page can’t be reached by the remote - turn the remote on again':'';
   return '<span class="auchip'+(bad?' bad':'')+'" title="'+esc(bad||b.page)+'">'+esc(x)+'<button data-ad="'+i+'" data-j="'+j+'" title="Take it out of this look">&#10005;</button></span>';}).join('');
  return '<div class="aulook'+(l.on?'':' off')+(cur?' cur':'')+'"><div class="row"><span class="aun">'+(i+1)+'</span><input class="srch" data-ln="'+i+'" value="'+esc(l.name)+'" maxlength="40" style="width:190px">'+
   '<select data-lb="'+i+'" style="width:auto">'+bars.map(b=>'<option value="'+b+'"'+(b===l.bars?' selected':'')+'>'+b+' bar'+(b>1?'s':'')+'</option>').join('')+'</select><span class="sub" style="margin:0" data-ls="'+i+'">&asymp; '+fmtS(auSec(l))+'</span><div class="grow"></div>'+
   '<label class="link"><input type="checkbox" data-lo="'+i+'"'+(l.on?' checked':'')+'> In the show</label>'+
   '<button class="mini" data-la="try" data-i="'+i+'"'+(l.titles.length?'':' disabled')+'>&#9654; '+(run?'Play now':'Try')+'</button><button class="mini" data-la="up" data-i="'+i+'"'+(i?'':' disabled')+' title="Move up">&uarr;</button><button class="mini" data-la="down" data-i="'+i+'"'+(i<L.length-1?'':' disabled')+' title="Move down">&darr;</button><button class="mini" data-la="copy" data-i="'+i+'">Copy</button><button class="mini" data-la="del" data-i="'+i+'">Delete</button></div>'+
   (auClash(l).length?'<div class="row" style="margin-top:8px;color:var(--amber);font-size:13px"><div class="grow">&#9888; '+auClash(l).map(c=>'<b>'+esc(c[0])+'</b> plays one button at a time &mdash; only <b>'+esc(c[1][c[1].length-1])+'</b> of these '+c[1].length+' would play.').join(' ')+'</div><button class="mini primary" data-la="split" data-i="'+i+'">Split into one look each</button></div>':'')+
   '<div class="auchips">'+(chips||'<span class="none">No buttons yet &mdash;</span>')+'<button class="mini" data-la="add" data-i="'+i+'">+ Button</button><button class="mini" data-la="grab" data-i="'+i+'" title="Use the buttons playing in ShowXpress now">&#8681; What&rsquo;s playing</button></div></div>';}).join('');
 const q=s=>$('aulooks').querySelectorAll(s);
 q('[data-ln]').forEach(e=>e.oninput=()=>{auC.looks[+e.dataset.ln].name=e.value;updAuto();});
 q('[data-lb]').forEach(e=>e.onchange=()=>{auC.looks[+e.dataset.lb].bars=+e.value;auLooks();updAuto();});
 q('[data-lo]').forEach(e=>e.onchange=()=>{auC.looks[+e.dataset.lo].on=e.checked;auLooks();auPlay();updAuto();});
 q('[data-ad]').forEach(e=>e.onclick=()=>{auC.looks[+e.dataset.ad].titles.splice(+e.dataset.j,1);auLooks();updAuto();});
 q('[data-la]').forEach(e=>e.onclick=()=>auLookAct(e.dataset.la,+e.dataset.i));}
async function auGrab(){const r=await remGet('/api/remote');
 if(!r.connected){auMsg('<span style="color:var(--amber)">'+esc(!r.ready&&r.setup?'The ShowXpress remote is off.':r.error||'ShowXpress isn’t answering.')+'</span>');return null;}
 const ts=[...new Set((r.pressed||[]).filter(p=>!isSetup(p.page)).map(p=>p.title))];
 if(!ts.length){auMsg('<span style="color:var(--amber)">Nothing is playing in ShowXpress (SETUP page buttons don&rsquo;t count). Press the buttons for the look there first.</span>');return null;}
 auMsg('');return ts.slice(0,24);}
async function auLookAct(k,i){const L=auC.looks,l=L[i];
 if(k==='up'&&i>0){[L[i-1],L[i]]=[L[i],L[i-1]];}
 else if(k==='down'&&i<L.length-1){[L[i+1],L[i]]=[L[i],L[i+1]];}
 else if(k==='copy'){const c=clone(l);c.id=rid();c.name=(l.name+' copy').slice(0,40);L.splice(i+1,0,c);}
 else if(k==='del'){if(!await ask('Delete '+l.name+'?','The look is taken out of the Auto Show (nothing in ShowXpress changes). Undo changes brings it back until you save.','Delete'))return;L.splice(i,1);}
 else if(k==='add'){auPick(i);return;}
 else if(k==='split'){await auAskSplit(i);return;}
 else if(k==='grab'){const ts=await auGrab();if(!ts)return;l.titles=ts;auMsg('&#10003; <b>'+esc(l.name)+'</b> now uses what&rsquo;s playing: '+esc(ts.join(', ')));}
 else if(k==='try'){await auTry(l);return;}
 auLooks();auPlay();updAuto();}
async function auTry(l){
 if(AUS&&AUS.running){if(auDirty()&&!(await auSave(true)))return;const r=await remGet('/api/auto/cmd',{cmd:'go',v:l.id});if(r.status){AUS=r.status;auPlay();auLooks();}if(!r.ok)auMsg('<span style="color:var(--red)">'+esc(r.error)+'</span>');return;}
 const r=await remGet('/api/remote/press',{titles:l.titles,release:auTried.filter(x=>!l.titles.includes(x))});
 if(!r.connected){auMsg('<span style="color:var(--amber)">'+esc(!r.ready&&r.setup?'The ShowXpress remote is off.':r.error||'ShowXpress isn’t answering.')+'</span>');return;}
 auTried=l.titles.slice();auMsg('&#9654; Trying <b>'+esc(l.name)+'</b> in ShowXpress'+((r.missing||[]).length?' &mdash; <span style="color:var(--red)">not in the show: '+esc(r.missing.join(', '))+'</span>':'')+'. Press Try on another look to switch.');}
function auPick(i){auPk=i;$('aupkt').textContent='Buttons in '+auC.looks[i].name;$('aupks').value='';auPickDraw();$('aupk').style.display='flex';setTimeout(()=>$('aupks').focus(),50);}
function auPickDraw(){const l=auC.looks[auPk],q=$('aupks').value.trim().toLowerCase(),on=new Set(l.titles),pages=[];
 for(const b of AU.buttons){if(isSetup(b.page))continue;if(q&&!b.title.toLowerCase().includes(q)&&!b.page.toLowerCase().includes(q))continue;let g=pages.find(x=>x.p===b.page);if(!g){g={p:b.page,bs:[]};pages.push(g);}g.bs.push(b);}
 $('aupkl').innerHTML=pages.length?pages.map(g=>'<h4>'+esc(g.p)+(g.bs[0].swap?' &middot; one at a time':'')+'</h4><div class="pks">'+g.bs.map(b=>{const no=b.dup?'Same name as another button - ShowXpress can only press the first one. Rename one in ShowXpress.':!b.reach?'This page can’t be reached by the remote yet':'';
  return '<span class="pkb'+(on.has(b.title)&&!b.dup?' on':'')+(no?' no':'')+'"'+(no?' title="'+esc(no)+'"':' data-pk2="'+esc(b.title)+'"')+'>'+esc(b.title)+'</span>';}).join('')+'</div>').join(''):'<p class="sub">No button matches.</p>';
 $('aupkl').querySelectorAll('[data-pk2]').forEach(e=>e.onclick=()=>{const x=e.dataset.pk2,ts=l.titles,j=ts.indexOf(x);if(j>=0)ts.splice(j,1);else if(ts.length<24)ts.push(x);e.classList.toggle('on',ts.includes(x));});}
$('aupks').oninput=auPickDraw;$('aupkd').onclick=async()=>{$('aupk').style.display='none';auLooks();auPlay();updAuto();if(auPk>=0&&auC.looks[auPk])await auAskSplit(auPk);};
$('aunew').onclick=()=>{if(!auC)return;auC.looks.push({id:rid(),name:'Look '+(auC.looks.length+1),bars:16,on:true,titles:[]});auLooks();updAuto();auPick(auC.looks.length-1);};
$('augrab').onclick=async()=>{if(!auC)return;const ts=await auGrab();if(!ts)return;auC.looks.push({id:rid(),name:'Look '+(auC.looks.length+1),bars:16,on:true,titles:ts});auLooks();auPlay();updAuto();
 auMsg('&#10003; New look <b>Look '+auC.looks.length+'</b>: '+esc(ts.join(', '))+'. Give it a name and save.');};
document.querySelectorAll('[data-ao]').forEach(b=>b.onclick=()=>{if(!auC)return;auC.order=b.dataset.ao;document.querySelectorAll('[data-ao]').forEach(x=>x.classList.toggle('on',x===b));updAuto();});
$('austop').onchange=e=>{if(auC){auC.stop=e.target.value;updAuto();}};$('auclean').onchange=e=>{if(auC){auC.clean=e.target.checked;updAuto();}};
function auSetBpm(v,live){v=Math.round(Math.max(40,Math.min(220,+v||124))*10)/10;auC.bpm=v;const e=$('aubpm');if(e&&document.activeElement!==e)e.value=v;auLooks();updAuto();
 if(live&&AUS&&AUS.running){clearTimeout(auBpmT);auBpmT=setTimeout(async()=>{const r=await remGet('/api/auto/cmd',{cmd:'bpm',v:String(v)});if(r.status)AUS=r.status;},350);}}
function auTap(){const n=Date.now();if(auTaps.length&&n-auTaps[auTaps.length-1]>2000)auTaps=[];auTaps.push(n);if(auTaps.length>9)auTaps.shift();
 if(auTaps.length>=3){const d=(auTaps[auTaps.length-1]-auTaps[0])/(auTaps.length-1);auSetBpm(Math.round(60000/d),true);}
 const b=$('autap');if(b)b.textContent='Tap'+(auTaps.length<3?' ('+(3-auTaps.length)+' more)':' ✓');}
function auPlay(){const el=$('auplay');if(!AU||!AU.ok||!auC){el.innerHTML='';return;}const s=AUS,run=!!(s&&s.running);el.className='auplay'+(run?' on':'');
 const act=auC.looks.filter(l=>l.on&&l.titles.length);
 const bpm='<span class="sub" style="margin:0">BPM</span><input id="aubpm" class="num" type="number" min="40" max="220" step="1" value="'+auC.bpm+'"><button class="mini" id="autap" title="Tap along with the beat (3 taps or more)">Tap</button>';
 if(!run){el.innerHTML='<div class="row"><div class="grow"><div class="aubig">Not playing</div><div class="sub" style="margin:2px 0 0">'+(act.length?act.length+' look'+(act.length>1?'s':'')+' ready &middot; '+(auC.order==='shuffle'?'shuffled':'in order'):'Add a look below to start.')+'</div>'+
   (s&&s.error?'<div style="color:var(--red);margin-top:4px">'+esc(s.error)+'</div>':'')+'</div>'+bpm+
   (act.length?'<select id="aufirst" style="width:auto">'+act.map(l=>'<option value="'+l.id+'">Start with '+esc(l.name)+'</option>').join('')+'</select>':'')+
   '<button class="primary" id="austart"'+(act.length&&(AU.ready||AU.player)?'':' disabled')+'>&#9654; Start Auto Show</button></div>';
  $('austart').onclick=auStart;}
 else{el.innerHTML='<div class="row"><div class="grow"><div class="sub" style="margin:0;letter-spacing:1px;font-size:11.5px">NOW PLAYING</div><div class="aubig" id="auname"></div><div class="sub" id="aunext" style="margin:2px 0 0"></div><div id="auwarn" style="color:var(--amber);font-size:13px"></div><div class="sub" id="autgt" style="margin:2px 0 0"></div></div><div class="aubeats" id="aubeats"><i></i><i></i><i></i><i></i></div></div>'+
   '<div class="auprog"><i id="aupr"></i></div><div class="row"><button id="auprev" title="The look before">&#9198; Back</button><button id="aunextb" class="primary" style="padding:9px 18px;font-size:14px">&#9197; Next look</button><button id="auhold"></button><button id="ausync" title="Press on the first beat of a bar: the bar count starts again from here">Bar 1 now</button><div class="grow"></div>'+bpm+'<button id="austopb">&#9632; Stop</button></div>';
  const c=(id,cmd)=>$(id).onclick=async()=>{const r=await remGet('/api/auto/cmd',{cmd:typeof cmd==='function'?cmd():cmd});if(r.status){AUS=r.status;auDraw();auLooks();}if(!r.ok)auMsg('<span style="color:var(--red)">'+esc(r.error)+'</span>');};
  c('auprev','prev');c('aunextb','next');c('ausync','sync');c('auhold',()=>AUS&&AUS.held?'resume':'hold');
  $('austopb').onclick=async()=>{busy(true,'Stopping the Auto Show…');const r=await remGet('/api/auto/stop',{});busy(false);AUS=r.status||null;if(AUS)AUS.error='';auPlay();auLooks();auPill();};}
 $('aubpm').onchange=e=>auSetBpm(e.target.value,true);$('autap').onclick=auTap;auDraw();}
function auDraw(){const s=AUS;if(!s||!s.running||!$('auname'))return;
 const beatMs=60000/s.bpm,tot=s.bars*4*beatMs,dt=Math.max(0,Date.now()-(Date.parse(s.at)||Date.now()));
 const left=s.held?null:Math.max(0,s.msLeft-dt),el=left===null?null:tot-left;
 const bar=el===null?s.bar:Math.min(s.bars,Math.floor(el/(beatMs*4))+1),beat=el===null?s.beat:Math.floor(el/beatMs)%4+1;
 $('auname').innerHTML=esc(s.name||'')+(s.held?'<small>HELD</small>':'');
 $('aunext').innerHTML='bar <b>'+bar+'</b> of '+s.bars+' &middot; '+(s.held?'held &mdash; stays on this look until you resume':'next: <b>'+esc(s.next||s.name)+'</b> in '+fmtS(left/1000));
 $('aupr').style.width=(el===null?(s.bar-1)/s.bars*100:Math.min(100,el/tot*100))+'%';
 $('aubeats').querySelectorAll('i').forEach((x,k)=>{x.className=k<beat?'on'+(k===0?' one':''):'';});
 const tg=$('autgt');if(tg){const h=s.target==='player'?'Playing on the <b>SX Player</b> (Lab)'+(s.src==='VirtualDJ'?' &middot; tempo from VirtualDJ':s.src==='tap'?' &middot; tapped tempo':''):'';if(tg.innerHTML!==h)tg.innerHTML=h;}
 const ab=$('aubpm');if(ab&&s.target==='player'&&document.activeElement!==ab){const v=String(Math.round(s.bpm));if(ab.value!==v)ab.value=v;}
 $('auwarn').textContent=s.error||((s.missing||[]).length?'Not in the show: '+s.missing.join(', '):'');
 $('auhold').innerHTML=s.held?'&#9654; Resume':'&#9208; Hold';
 if(s.lookId!==auLastId){auLastId=s.lookId;auLooks();}}
async function auSave(quiet){busy(true,'Saving the Auto Show…');let r;try{r=await api('/api/auto/save',{config:auC});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 if(r.ok&&r.config){AU.config=r.config;auC=clone(r.config);renderAuto();}
 if(!quiet||!r.ok)showResult(r,'auto');return r.ok;}
async function auStart(){if(auDirty()&&!(await auSave(true)))return;busy(true,'Starting the Auto Show…');const f=$('aufirst');
 let r;try{r=await api('/api/auto/start',{look:f?f.value:''});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 AUS=r.status||null;if(!r.ok){showResult(r,'sx');$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> The Auto Show didn&rsquo;t start';}auTried=[];auPlay();auLooks();auPill();}
function updAuto(){const ok=!!(AU&&AU.ok),d=auDirty();$('ausave').disabled=!ok||!d;$('auundo').disabled=!ok||!d;if(ok)stateTag('austate',d);
 $('auhint').innerHTML=!ok?'':d?'Not saved yet'+(AUS&&AUS.running?' &mdash; the Auto Show picks the changes up when you save':'')+'.':'Saved. Starting, stopping and BPM taps work any time &mdash; ShowXpress stays open.';}
function auPill(){const b=$('aupill'),on=!!(AUS&&AUS.running);b.style.display=on?'':'none';if(on)b.innerHTML='&#9679; AUTO &middot; '+esc(AUS.name||'');}
$('aupill').onclick=()=>setTab('auto');
$('ausave').onclick=()=>auSave(false);$('auundo').onclick=()=>{auC=clone(AU.config);renderAuto();};
setInterval(async()=>{if(curTab()!=='auto'||!AUS||!AUS.running)return;auDraw();
 if(!auStF&&Date.now()%1000<260){auStF=true;try{const r=await api('/api/auto/status');AUS=r.status;if(!AUS||!AUS.running){auPlay();auLooks();}auPill();}catch(e){}auStF=false;}},250);

// ---------------- Tonight's Color (color.ps1)
const CPRE=[['Red','ff0000'],['Wine','8b0a2a'],['Rose','ff2a6d'],['Blush','f4a6b8'],['Hot pink','ff3fa4'],['Magenta','ff00ff'],['Purple','8a2be2'],['Lavender','b48cff'],['Royal blue','1f3fff'],['Navy','0a1a6e'],['Sky blue','6ec8ff'],
 ['Teal','00a8a8'],['Mint','7dffc4'],['Emerald','00b050'],['Lime','9aff00'],['Gold','ffb000'],['Yellow','ffee00'],['Peach','ffb38a'],['Orange','ff6a00'],['Warm white','ffd9a8'],['Cold white','e6f2ff']];
let CL=null,clHex='',clV=100,clDrag=false,CP=null;
function clWash(hx,hasW){  // same rule as Get-WashMix in color.ps1: hue on R/G/B at full strength, whiteness on W, brightness on the dimmer
 const c=[0,2,4].map(i=>parseInt(hx.substr(i,2),16)),mx=Math.max(...c),mn=Math.min(...c),v={dimmer:mx,red:0,green:0,blue:0,white:0};
 if(mx>0){if(!hasW){v.red=Math.round(c[0]*255/mx);v.green=Math.round(c[1]*255/mx);v.blue=Math.round(c[2]*255/mx);}
  else if(mx===mn)v.white=255;
  else{const k=1/(mx-mn),w=mn/mx;v.red=Math.round(255*(c[0]-mn)*k);v.green=Math.round(255*(c[1]-mn)*k);v.blue=Math.round(255*((c[2]-mn)*k)**(1-0.85*w));v.white=Math.round(255*(1-(1-w)**1.8));}}
 return v;}
function clUpVals(chs){  // uplight channel index -> value, exactly what TONIGHTS COLOR UPLIGHT will hold
 const v=clWash(clHex,chs.includes('white')),o=[];
 chs.forEach((n,i)=>{if(Object.prototype.hasOwnProperty.call(v,n))o.push([i,+v[n]]);else if(/^(dimmer|red|green|blue|white|amber|uv|strobe.*|.*macro.*|.*effect.*)$/.test(n))o.push([i,0]);});return o;}
function hsv2hex(h,s,v){const f=n=>{const k=(n+h/60)%6;return v-v*s*Math.max(0,Math.min(k,4-k,1));};return [f(5),f(3),f(1)].map(x=>Math.round(x*255).toString(16).padStart(2,'0')).join('');}
function hex2hsv(hx){const r=parseInt(hx.slice(0,2),16)/255,g=parseInt(hx.slice(2,4),16)/255,b=parseInt(hx.slice(4,6),16)/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn;let h=0;
 if(d){h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h=(h*60+360)%360;}return [h,mx?d/mx:0,mx];}
function nearest(w,hx){let c=[0,2,4].map(i=>parseInt(hx.substr(i,2),16));const mx=Math.max(1,...c);c=c.map(x=>x*255/mx);let best=null,bd=1e12;  // same rule as color.ps1
 for(const e of w||[]){const r=[0,2,4].map(i=>parseInt(e.hex.substr(i,2),16)),d=.3*(c[0]-r[0])**2+.59*(c[1]-r[1])**2+.11*(c[2]-r[2])**2;if(d<bd){bd=d;best=e;}}return best;}
function clDirty(){return !!(CL&&CL.ok&&clHex&&(clHex!==CL.hex||$('clname').value.trim()!==(CL.name||'')));}
async function loadColor(){CL=await getJ('/api/color');if(CL.ok){clHex=CL.hex||'';$('clname').value=CL.name||'';clV=clHex?Math.max(10,Math.round(hex2hsv(clHex)[2]*100)):100;}renderColor();}
function setColor(hx,name){clHex=hx.toLowerCase();if(name!==undefined)$('clname').value=name;clV=Math.max(10,Math.round(hex2hsv(clHex)[2]*100));renderColor();}
function renderColor(){if(!CL)return;if(showErr('clerr',CL)){$('clstate').style.display='none';updColor();return;}
 $('clpal').innerHTML=CPRE.map(([n,h])=>`<div class="cp${h===clHex?' cur':''}" data-ch="${h}" data-cn="${esc(n)}"><i style="background:#${h}"></i>${esc(n)}</div>`).join('');
 document.querySelectorAll('[data-ch]').forEach(e=>e.onclick=()=>setColor(e.dataset.ch,e.dataset.cn));
 const k=$('clknob');if(clHex){const [h,s]=hex2hsv(clHex),a=h*Math.PI/180;k.style.display='block';k.style.left=(100+Math.sin(a)*s*100)+'px';k.style.top=(100-Math.cos(a)*s*100)+'px';k.style.background='#'+clHex;}else k.style.display='none';
 $('clval').value=clV;$('clwheel').style.filter='brightness('+Math.max(.25,clV/100)+')';
 if(document.activeElement!==$('clhex'))$('clhex').value=clHex?'#'+clHex:'';$('clpick').value='#'+(clHex||'ffffff');
 const big=$('clbig');big.style.background=clHex?'#'+clHex:'repeating-linear-gradient(45deg,#1d212a 0 10px,#171a21 10px 20px)';big.innerHTML='<span>'+(clHex?'#'+clHex:'pick a colour')+'</span>';
 const n1=clHex&&nearest(CL.wheel140,clHex),n2=clHex&&nearest(CL.wheel251,clHex),sw=e=>e?`<span class="sw" style="background:#${e.hex}"></span>${esc(e.name)}`:'&mdash;',wa=CL.washes||[];
 $('clmap').innerHTML=`<span>140 movers</span><b>${sw(n1)}</b><span>251 movers</span><b>${sw(n2)}</b><span>Uplights</span><b>${clHex?'<span class="sw" style="background:#'+clHex+'"></span>exact colour':'&mdash;'}${wa.length?'<br><small style="color:var(--dim)">'+esc(wa.join(', '))+'</small>':' &middot; <span style="color:var(--amber)">none found</span>'}</b>`+
  (CL.hex?`<span>Saved</span><b><span class="sw" style="background:#${CL.hex}"></span>#${CL.hex}${CL.name?' '+esc(CL.name):''}${CL.saved?' &middot; '+fmtT(CL.saved):''}</b>`:'');
 stateTag('clstate',clDirty());if(!CL.hex&&!clHex)$('clstate').style.display='none';$('foot').textContent='Show: '+CL.show;updColor();cpUi();cpPush();}
function updColor(){const ok=!!(CL&&CL.ok),d=clDirty();$('clsave').disabled=!ok||!d;$('clundo').disabled=!ok||!d;
 const miss=ok?(CL.buttons||[]).filter(b=>!b.there).map(b=>b.page):[];
 $('clhint').innerHTML=!ok?'':sxHint('save')??(!clHex?'Pick a colour.':d?'Writes the two TONIGHTS COLOR scenes'+(miss.length?' and adds the button to the '+esc(miss.join(' and '))+' page'+(miss.length>1?'s':''):'')+'.':'This is tonight\'s colour already.');}
function wheelAt(e){const r=$('clwheel').getBoundingClientRect(),x=e.clientX-r.left-r.width/2,y=e.clientY-r.top-r.height/2,s=Math.min(1,Math.hypot(x,y)/(r.width/2)),h=(Math.atan2(x,-y)*180/Math.PI+360)%360;
 clHex=hsv2hex(h,s,clV/100);$('clname').value='';renderColor();}
$('clwheel').onpointerdown=e=>{if(!CL||!CL.ok)return;clDrag=true;$('clwheel').setPointerCapture(e.pointerId);wheelAt(e);};
$('clwheel').onpointermove=e=>{if(clDrag)wheelAt(e);};$('clwheel').onpointerup=()=>{clDrag=false;};
$('clval').oninput=e=>{clV=+e.target.value;if(clHex){const [h,s]=hex2hsv(clHex);clHex=hsv2hex(h,s,clV/100);}renderColor();};
$('clpick').oninput=e=>setColor(e.target.value.slice(1),'');
$('clhex').onchange=e=>{const v=e.target.value.trim().replace(/^#/,'');if(/^[0-9a-f]{6}$/i.test(v))setColor(v,'');else renderColor();};
$('clname').oninput=()=>{stateTag('clstate',clDirty());updColor();};
$('clrefresh').onclick=loadColor;$('clundo').onclick=()=>{clHex=CL.hex||'';$('clname').value=CL.name||'';renderColor();};
$('clsave').onclick=async()=>{let reo=false;if(CP){reo=$('clreo').checked;await cpStop(false);}   // saving needs the show closed and the interface free: end the preview first
 await saveTo('/api/color/apply',{hex:clHex,name:$('clname').value.trim()},'Saving tonight\'s color…',async()=>{await loadColor();H=null;},'color');
 if(reo)sxLaunch();};
// ---- live preview on the real lights (user 2026-11-23): ShowXpress closed, the Helper drives the DMX interface (same
// output as Aim live). Movers: dance-floor center aim, look from LiveInfo, colour wheel = nearest. Uplights: clUpVals().
function cpQ(k,s){if(CP.sent[k]===s)return;CP.sent[k]=s;CP.pend.set(k,s);}
function cpPush(){if(!CP||!CP.on||!CL||!CL.ok)return;const on=!!clHex,n1=on&&nearest(CL.wheel140,clHex),n2=on&&nearest(CL.wheel251,clHex);
 for(const h of CP.heads){cpQ('p'+h.addr,'s:'+h.addr+':'+(h.addr+1)+':'+Math.round(h.c[0]));cpQ('p'+(h.addr+2),'s:'+(h.addr+2)+':'+(h.addr+3)+':'+Math.round(h.c[1]));
  const n=h.is140?n1:n2;for(const [i,v] of h.look){const x=i===5?(n?n.value:0):(!on&&(i===h.dimI||i===h.shutI))?0:v;cpQ('b'+(h.addr+i),'b:'+(h.addr+i)+':'+x);}}
 for(const w of CP.wash){const vs=on?clUpVals(w.chs):w.chs.map((n,i)=>[i,0]);for(const [i,v] of vs)cpQ('b'+(w.addr+i),'b:'+(w.addr+i)+':'+Math.max(0,Math.min(255,Math.round(v))));}
 cpKick();}
function cpKick(){if(!CP||CP.tm||CP.fl)return;const d=30-(Date.now()-CP.last);if(d>0)CP.tm=setTimeout(()=>{if(CP){CP.tm=0;cpFlush();}},d);else cpFlush();}
async function cpFlush(){if(!CP||!CP.on||CP.fl)return;let l=((CP.z?'z ':'')+[...CP.pend.values()].join(' ')).trim();if(!l){if(!CP.ka)return;l='k';}
 const me=CP;CP.z=false;CP.ka=false;CP.pend.clear();CP.fl=true;CP.last=Date.now();let r;try{r=await api('/api/live/out',{l});}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}
 if(CP!==me||!CP.on)return;CP.fl=false;
 if(!r.ok){const reo=$('clreo').checked;await cpStop(false);showResult({ok:false,error:'The preview on the lights stopped: '+(/^The DMX output stopped/.test(r.error||'')?'the DMX interface was unplugged, or SX Studio lost it.':(r.error||'unknown error'))+(reo?' ShowXpress is opening again.':'')},'clprev');if(reo)sxLaunch();return;}
 if(CP.pend.size)cpKick();}
function cpUi(){const on=!!CP;$('clpv').classList.toggle('on',on);$('clprev').style.display=on?'none':'';$('clprev').disabled=!CL||!CL.ok;}
async function cpGo(){if(CP||LV||SEP||MVP||LKP||!CL||!CL.ok)return;
 const c=await sxCloseLive('Close ShowXpress to show the colour on the lights?','Only one program can use the DMX interface, so ShowXpress closes while you preview. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.<br><br>It can open again when you stop.','Close and preview','Show it on the lights','clprev');
 if(!c.go)return;
 const r=await lvStart('floor');
 if(!r.ok){try{await api('/api/live/stop',{});}catch(e){}if(c.reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'clprev');return;}
 CP={on:true,heads:r.info.heads||[],wash:CL.washFix||[],sent:{},pend:new Map(),z:true,ka:false,fl:false,tm:0,last:0};
 CP.kat=setInterval(()=>{if(CP&&CP.on&&Date.now()-CP.last>1000){CP.ka=true;cpKick();}},1000);
 $('clreo').checked=c.reo;cpUi();cpPush();}
async function cpStop(reo){if(!CP)return;clearInterval(CP.kat);if(CP.tm)clearTimeout(CP.tm);CP.on=false;CP=null;cpUi();
 busy(true,'Stopping the DMX output…');try{await api('/api/live/stop',{});}catch(e){}busy(false);if(reo)await sxLaunch();}
$('clprev').onclick=cpGo;$('clpvstop').onclick=()=>cpStop($('clreo').checked);

// ---------------- Home: Google Drive, ShowXpress launch / close, updates, brand
let G=null,UPD=0;
function fmtT(s){const d=new Date(s);if(isNaN(d))return esc(s);const t=d.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
 return d.toDateString()===new Date().toDateString()?'today at '+t:d.toLocaleDateString([],{weekday:'short',month:'short',day:'numeric'})+' '+t;}
async function loadGd(){G=await getJ('/api/gdrive');updGd();}
function updGd(){if(!G)return;
 $('gdsub').innerHTML=!G.ok?'<span style="color:var(--red)">'+esc(G.error)+'</span>':!G.found?'Google Drive isn&rsquo;t on this computer &mdash; install <b>Google Drive for desktop</b> and sign in.':
  'Copies the show to <b>'+esc(G.target)+'</b> &mdash; only new and changed files, nothing is deleted. '+(G.last?'Last sync: <b>'+fmtT(G.last)+'</b>.':'Not synced yet.')+
  '<br><b>Import</b> copies the show from Google Drive into <b>'+esc(G.show)+'</b> and replaces the one on this computer'+(G.srcFound?' (Google Drive copy saved '+fmtT(G.srcTime)+')':' &mdash; <span style="color:var(--amber)">no show on Google Drive yet</span>')+'.'+(G.lastImport?' Last import: <b>'+fmtT(G.lastImport)+'</b>.':'');
 updGdAcct();$('gdsync').disabled=!G.ok||!G.found||!G.here;$('gdimp').disabled=!G.ok||!G.found||!G.srcFound;$('gdhint').innerHTML=G.ok&&G.found&&sxOpen?QH:'';}
async function gdSync(){await saveTo('/api/gdrive/sync',{},'Copying the show to Google Drive…',async()=>{await loadGd();if($('v-pre').classList.contains('on'))loadPre();},'gsync');}
$('gdsync').onclick=()=>gdSync();
async function gdImport(){if(!G||!G.srcFound)return;
 if(!await ask('Import the show from Google Drive?','The show on this computer is <b>replaced</b> by the Google Drive copy'+(G.srcTime?' (saved '+fmtT(G.srcTime)+')':'')+' &mdash; anything changed here since then is lost. The old show is kept as a backup.'+(sxOpen?'<br><br>ShowXpress is open: this waits until you close it.':''),'Import'))return;
 await saveTo('/api/gdrive/import',{},'Copying the show from Google Drive…',async()=>{reloadAll();},'gimport');}
$('gdimp').onclick=()=>gdImport();
async function sxLaunch(){busy(true,'Starting ShowXpress…');let r;try{r=await api('/api/sx/launch',{});}catch(e){r={ok:false,error:'Lost connection.'}}
 if(r.ok&&r.already){busy(false);
  if(!await ask('ShowXpress is still running','SX Studio sees ShowXpress running on the laptop. If you can see its window there, just use it.<br><br>If you <b>can&rsquo;t</b> see it, it got stuck while closing: <b>Force close</b> stops it and opens it again (anything not saved is lost).','Force close and open'))return;
  if(!await sxForce())return;busy(true,'Starting ShowXpress…');try{r=await api('/api/sx/launch',{});}catch(e){r={ok:false,error:'Lost connection.'}}}
 setTimeout(()=>busy(false),r.ok?3000:0);if(!r.ok)showResult(r,'sx');}
async function sxForce(){busy(true,'Force closing ShowXpress…');let r;try{r=await api('/api/sx/close',{force:true});}catch(e){r={ok:false,error:'Lost connection.'}}busy(false);
 if(!r.ok){showResult(r,'sx');return false;}sxOpen=false;await new Promise(r=>setTimeout(r,2500));return true;}
let sxCloseT=0;
async function sxClose(){
 if(sxCloseT&&Date.now()-sxCloseT>8000){   // asked before and it's still running
  if(!await ask('ShowXpress didn&rsquo;t close','If ShowXpress is asking whether to save, answer it on the laptop.<br><br>If it has no window or is stuck, <b>Force close</b> stops it &mdash; anything not saved is lost.','Force close'))return;
  sxCloseT=0;await sxForce();return;}
 if(!await ask('Close ShowXpress?','ShowXpress is asked to close the normal way. Its &ldquo;Do you really want to quit?&rdquo; is answered Yes for you; if it asks whether to save, that one is yours to answer in ShowXpress.','Close ShowXpress'))return;
 let r;try{r=await api('/api/sx/close',{});}catch(e){r={ok:false,error:'Lost connection.'}}if(!r.ok){showResult(r,'sx');return;}sxCloseT=r.none?0:Date.now();}
$('sxgo').onclick=sxLaunch;$('sxstop').onclick=sxClose;
async function chkUpd(){const u=await getJ('/api/update');$('hver').textContent='Version '+(u.current||'?')+(u.ok?(u.newer?' · version '+u.latest+' is available':' · up to date'):'');
 if(u.ok&&u.newer){const b=$('upd');b.style.display='';b.className='mini primary';b.textContent='⬆ Update to '+u.latest;b.onclick=()=>doUpd(u);}}
async function doUpd(u){if(!await ask('Update to version '+esc(u.latest)+'?','Downloads it from GitHub and installs it. '+(u.mac?'SX Studio closes and the Mac installer opens &mdash; follow it, and SX Studio opens again when it&rsquo;s done.':'SX Studio closes and opens again by itself in a few seconds.')+' Your show isn&rsquo;t touched.','Update'))return;
 busy(true,'Downloading the update…');let r;try{r=await api('/api/update/install',{});}catch(e){r={ok:false,error:'Lost connection.'}}
 if(r.ok&&r.restarting){UPD=1;busy(true,u.mac?'Opening the installer — follow it, SX Studio opens again when it’s done…':'Installing the update — SX Studio opens again by itself…');return;}busy(false);showResult(r,'update');}
{const bi=new Image();bi.onload=()=>{const b=$('brand');b.innerHTML='';bi.alt='XSV Productions';b.appendChild(bi);};bi.src='/brand.png?t='+T;}
document.querySelectorAll('img[data-img]').forEach(i=>i.src='/'+i.dataset.img+'.png?t='+T);

// ---------------- LIVE AIM: the Helper drives the DMX interface itself (dmx_out.ps1) while ShowXpress is closed
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let LV=null;const LVB=10;   // 16-bit pan steps per mouse pixel at Normal speed (tilt gets more: same angle)
function lvFlip(id){try{return JSON.parse(localStorage.getItem('sxh_flip_'+id))||{x:false,y:false};}catch(e){return {x:false,y:false};}}
const lvCl=v=>Math.max(0,Math.min(65535,v));
function lvAimed(h){const w=LV.W[h.id];return w.tc||w.tk||!h.free;}
function lvCopies(h){const w=LV.W[h.id],p=h.partner&&LV.byId[h.partner];return !!(p&&!w.tc&&!w.tk&&h.free&&lvAimed(p));}
function lvCorner(h){const w=LV.W[h.id];return w.k||[lvCl(w.c[0]+h.dk[0]-h.home[0]),lvCl(w.c[1]+h.dk[1]-h.home[1])];}
function lvPos(h,st){if(lvCopies(h))return lvPos(LV.byId[h.partner],st);return st==='k'?lvCorner(h):LV.W[h.id].c;}
function lvLit(h){return h===LV.sel||(LV.all&&(!LV.towers||h.order<99||h.hung));}
// ---- output: only changed channels, one request at a time, at most ~30 a second
function lvPair(c,v,snap){v=Math.round(v);const k='p'+c;if(!snap&&LV.sent[k]===v)return;LV.sent[k]=v;const o=LV.pend.get(k);LV.pend.set(k,((snap||(o&&o[0]==='s'))?'s':'p')+':'+c+':'+(c+1)+':'+v);}
function lvByte(ch,v){const k='b'+ch;if(LV.sent[k]===v)return;LV.sent[k]=v;LV.pend.set(k,'b:'+ch+':'+v);}
function lvPush(snap){if(!LV)return;for(const h of LV.heads){const p=lvPos(h,LV.step),lit=lvLit(h);lvPair(h.addr,p[0],snap);lvPair(h.addr+2,p[1],snap);
 for(const [i,v] of h.look)lvByte(h.addr+i,(!lit&&(i===h.dimI||i===h.shutI))?0:v);}lvKick();}
function lvKick(){if(!LV||LV.tm||LV.fl)return;const d=30-(Date.now()-LV.last);if(d>0)LV.tm=setTimeout(()=>{if(LV){LV.tm=0;lvFlush();}},d);else lvFlush();}
async function lvFlush(){if(!LV||!LV.on||LV.gone||LV.fl)return;let l=((LV.z?'z ':'')+[...LV.pend.values()].join(' ')).trim();if(!l){if(!LV.ka)return;l='k';}
 const me=LV;LV.z=false;LV.ka=false;LV.pend.clear();LV.fl=true;LV.last=Date.now();let r;try{r=await api('/api/live/out',{l});}catch(e){r={ok:false,gone:true,error:'Lost connection to SX Studio.'};}
 if(LV!==me||!LV.on)return;LV.fl=false;if(!r.ok){lvGone(r.error);return;}if(LV.pend.size)lvKick();}
function lvGone(msg){LV.gone=true;if(/^The DMX output stopped/.test(msg||''))msg='Unplugged, or SX Studio lost it.';const g=$('lvgone');g.className='lvgone on';
 g.innerHTML='<b>&#9888; The DMX output stopped.</b><span>'+esc(msg||'')+' Your aims so far are kept.</span><div class="grow"></div><button id="lvre" class="mini primary">Reconnect</button>';$('lvre').onclick=lvReconnect;}
async function lvStart(mode,raw){busy(true,'Connecting to the DMX interface…');let r;try{r=await api('/api/live/start',{mode,raw:!!raw});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);
 if(!r.ok&&r.nova&&await ask('NovaStar is using the DMX interface','The NovaStar LED-screen software (NovaLCT) has a USB scanner that grabs the DMX interface. Pause it while you aim? NovaLCT starts it again by itself &mdash; your LED screens are not touched.','Pause it and continue')){
  busy(true,'Pausing NovaStar and connecting…');try{r=await api('/api/live/start',{mode,raw:!!raw,stopNova:true});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);}
 return r;}
async function lvReconnect(){const r=await lvStart(LV.mode);
 if(!LV)return;if(!r.ok){lvGone(r.error);return;}LV.gone=false;LV.fl=false;$('lvgone').className='lvgone';lvIf(r);LV.sent={};LV.pend.clear();LV.z=true;lvPush(true);}
function lvIf(r){const t=$('lvif');t.className='tag '+(r.test?'red':'blue');t.textContent=r.test?'TEST - no real output':'Output: '+r.iface;}
// ---- moving
function lvTake(h){// a head that shows its T-bar partner's aim starts from there when you aim it yourself
 if(!lvCopies(h))return;const p=LV.byId[h.partner],w=LV.W[h.id],pw=LV.W[p.id];w.c=lvPos(p,'c').slice();w.k=pw.k?pw.k.slice():null;w.tc=true;}
function lvMove(dx,dy,sh,ct){if(!LV||!LV.sel||LV.gone)return;const h=LV.sel,w=LV.W[h.id],f=LV.flip,m=LV.spd*(sh?0.25:1)*(ct?4:1);
 const dp=dx*LVB*m*(f.x?-1:1),dt=-dy*LVB*m*(h.deg[0]/h.deg[1])*(f.y?-1:1);if(!dp&&!dt)return;
 lvTake(h);
 if(LV.step==='k'){if(!w.k)w.k=lvCorner(h).slice();w.k=[lvCl(w.k[0]+dp),lvCl(w.k[1]+dt)];w.tk=true;}
 else{w.c=[lvCl(w.c[0]+dp),lvCl(w.c[1]+dt)];w.tc=true;}
 lvPush(false);lvDirty();}
function lvDirty(){if(LV&&!LV.raf)LV.raf=requestAnimationFrame(lvSide);}
function lvNav(){return LV.order.filter(h=>h===LV.sel||(!lvCopies(h)&&(!LV.towers||h.order<99)));}
function lvSelect(h,quiet){if(!h)return;LV.sel=h;LV.flip=lvFlip(h.id);$('lvfx').checked=LV.flip.x;$('lvfy').checked=LV.flip.y;if(!quiet)lvPush(false);lvSide();
 const e=$('lvlist').querySelector('.lvh.on');if(e)e.scrollIntoView({block:'nearest'});}
function lvSetStep(s){LV.step=s;document.querySelectorAll('[data-st]').forEach(b=>b.classList.toggle('on',b.dataset.st===s));lvPush(false);lvDirty();}
function lvStepTo(dir){const n=lvNav(),j=n.indexOf(LV.sel)+dir;if(j>=0&&j<n.length){lvSelect(n[j]);return;}
 if(dir>0&&LV.step==='c'){LV.step='k';const m=LV.order.filter(h=>!lvCopies(h)&&(!LV.towers||h.order<99));lvSetStep('k');lvSelect(m[0]||LV.sel);}}
// ---- drawing
function lvList(){const g=[];let cur=null;
 for(const h of LV.order){const t=h.order<99?h.tower:(LV.towers?'Other heads (not on a truss)':'Heads');if(t!==cur){g.push('<h4>'+esc(t)+'</h4>');cur=t;}
  const w=LV.W[h.id],cp=lvCopies(h);
  const st=(w.tc||w.tk)?'<small class="a">aimed'+(w.tk?' + corner':'')+'</small>':cp?'<small class="cp">&#8644; '+esc(LV.byId[h.partner].label)+'</small>':!h.free?'<small class="b">aimed before</small>':'<small>normal</small>';
  g.push('<div class="lvh'+(h===LV.sel?' on':'')+(LV.towers&&h.order>=99?' dim':'')+'" data-lv="'+esc(h.id)+'"><span class="sd">'+esc(h.side||'')+'</span>'+esc(h.label)+st+'</div>');}
 $('lvlist').innerHTML=g.join('');$('lvlist').querySelectorAll('[data-lv]').forEach(e=>e.onclick=()=>lvSelect(LV.byId[e.dataset.lv]));}
function lvSide(){if(!LV)return;LV.raf=0;const h=LV.sel;if(!h)return;lvList();const w=LV.W[h.id],cp=lvCopies(h),st=LV.step,p=lvPos(h,st),pt=h.partner&&LV.byId[h.partner],room=LV.mode==='room';
 $('lvname').textContent=h.label+(h.tower?' · '+h.tower+(h.side?(h.side==='L'?' left':' right'):''):'');
 $('lvst').innerHTML=cp?'Not aimed &mdash; gets the same aim as <b>'+esc(pt.label)+'</b> next to it. Drag to aim it yourself.':(w.tc||w.tk)?'Aimed now'+(w.tk?' (center + corner)':' (center)'):!h.free?'Aimed before &mdash; drag to change it.':'Normal aim &mdash; drag to aim it.';
 $('lvbig').innerHTML=esc(h.label)+' &mdash; <span>'+(st==='k'?'CORNER':'CENTER')+'</span>';
 $('lvtip').innerHTML=(st==='k'?'Aim it at the front-left '+(room?'edge of the AROUND ROOM sweep':'corner of the floor (from the DJ)')+(w.tk||(h.kSet&&!cp)?'':' &mdash; <i>until you do, it follows the center</i>'):
  'Aim it at the '+(room?'middle of where AROUND ROOM should sweep':'center of tonight&rsquo;s dance floor'))+'<br><span style="font-size:12px;color:#5d6574">'+(PH?'Put your finger in this box and drag':'Hold the mouse button down here and drag')+'</span>';
 const dg=(v,i)=>(v-h.home[i])*h.deg[i]/65536,f1=x=>(x>=0?'+':'&minus;')+Math.abs(x).toFixed(1)+'&deg;';
 $('lvread').innerHTML='<span>Pan</span><b>'+Math.round(p[0])+' &nbsp;<small>'+f1(dg(p[0],0))+' from normal</small></b><span>Tilt</span><b>'+Math.round(p[1])+' &nbsp;<small>'+f1(dg(p[1],1))+' from normal</small></b>';
 // minimap in degrees around the normal center, turned like the mouse moves
 const c=lvPos(h,'c'),k=lvPos(h,'k'),fx=LV.flip.x?-1:1,fy=LV.flip.y?-1:1,X=v=>dg(v,0)*fx,Y=v=>-dg(v,1)*fy;
 const bx=Math.abs(dg(h.dk[0],0)),by=Math.abs(dg(h.dk[1],1)),kx=Math.abs(X(k[0])-X(c[0])),ky=Math.abs(Y(k[1])-Y(c[1]));
 const R=Math.max(bx*2.2,by*2.2,10,Math.abs(X(c[0]))+kx+2,Math.abs(Y(c[1]))+ky+2,Math.abs(X(p[0]))+2,Math.abs(Y(p[1]))+2),sc=82/R,px=v=>(120+v*sc).toFixed(1),py=v=>(90+v*sc).toFixed(1);
 const rc=(x,y,hw,hh,a)=>'<rect x="'+px(x-hw)+'" y="'+py(y-hh)+'" width="'+(2*hw*sc).toFixed(1)+'" height="'+(2*hh*sc).toFixed(1)+'" '+a+'/>';
 $('lvmap').innerHTML='<line x1="120" y1="0" x2="120" y2="180" stroke="#1d212a"/><line x1="0" y1="90" x2="240" y2="90" stroke="#1d212a"/>'+
  rc(0,0,bx,by,'fill="none" stroke="#5d6574" stroke-dasharray="4 3" rx="3"')+rc(X(c[0]),Y(c[1]),kx,ky,'fill="rgba(255,176,32,.12)" stroke="#ffb020" stroke-width="1.5" rx="3"')+
  '<circle cx="'+px(X(c[0]))+'" cy="'+py(Y(c[1]))+'" r="4" fill="#ffb020"/><circle cx="'+px(X(k[0]))+'" cy="'+py(Y(k[1]))+'" r="4" fill="#5aa9ff"/>'+
  '<circle cx="'+px(X(p[0]))+'" cy="'+py(Y(p[1]))+'" r="8" fill="none" stroke="#fff" stroke-width="2"/>';
 const b=$('lvpart');b.style.display=pt?'':'none';if(pt)b.innerHTML='&#8644; Same as '+esc(pt.label)+' (next to it)';
 $('lvundo').disabled=JSON.stringify(w)===LV.I0[h.id];
 const n=lvNav(),i=n.indexOf(h),nx=$('lvnext');$('lvprev').disabled=i<=0;
 if(i<n.length-1){nx.disabled=false;nx.innerHTML='Next head &rarr;';}else if(st==='c'){nx.disabled=false;nx.innerHTML='Corners &rarr;';}else{nx.disabled=true;nx.innerHTML='Last head';}}
// ---- open / close
// close ShowXpress so the Helper can use the DMX interface (Aim live, Tonight's Color preview) -> {go, reo: it was open}
async function sxCloseLive(title,text,yes,again,what){if(!sxOpen)return {go:true,reo:false};
 if(!await ask(title,text,yes))return {go:false};
 let r;try{r=await api('/api/sx/close',{live:true});}catch(e){r={ok:false,error:'Lost connection.'};}if(!r.ok){showResult(r,what);return {go:false};}
 busy(true,'Waiting for ShowXpress to close… (save it if it asks)');const t0=Date.now();let open=true;
 while(Date.now()-t0<120000){await sleep(1000);try{open=(await api('/api/sx')).open;}catch(e){}if(!open)break;}
 if(open){busy(false);try{await api('/api/live/stop',{});}catch(e){}showResult({ok:false,error:'ShowXpress is still open. Close it (save if it asks), then press '+again+' again.'},what);return {go:false};}
 busy(true,'ShowXpress closed - waiting for it to let go of the interface…');await sleep(2500);return {go:true,reo:true};}
async function lvGo(){if(LV||CP||SEP||MVP||LKP)return;
 const c=await sxCloseLive('Close ShowXpress to aim live?','Only one program can use the DMX interface, so ShowXpress closes while you aim. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.<br><br>It opens again when you finish.','Close and aim live','Aim live','live');
 if(!c.go)return;const reo=c.reo;
 const r=await lvStart(aimMode);
 if(!r.ok){try{await api('/api/live/stop',{});}catch(e){}if(reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'live');return;}
 lvOpen(r,reo);}
function lvOpen(r,reo){const I=r.info;
 LV={on:true,mode:aimMode,heads:I.heads,byId:{},W:{},I0:{},sent:{},pend:new Map(),z:true,ka:false,fl:false,tm:0,last:0,step:'c',all:false,spd:+(localStorage.getItem('sxh_lvspd')||1)||1,drag:false,raf:0,gone:false};
 for(const h of LV.heads){LV.byId[h.id]=h;const w={c:h.c.slice(),k:h.kSet?h.k.slice():null,tc:false,tk:false};LV.W[h.id]=w;LV.I0[h.id]=JSON.stringify(w);}
 LV.towers=LV.heads.some(h=>h.order<99);LV.order=LV.heads.slice().sort((a,b)=>a.order-b.order);
 $('lvmode').textContent=(LV.mode==='room'?'Room':'Dance floor')+' · '+I.aimTitle;lvIf(r);$('lvreo').checked=!!reo;$('lvall').checked=false;$('lvgone').className='lvgone';
 document.querySelectorAll('[data-sp]').forEach(b=>b.classList.toggle('on',+b.dataset.sp===LV.spd));document.querySelectorAll('[data-st]').forEach(b=>b.classList.toggle('on',b.dataset.st==='c'));
 $('live').classList.add('on');document.body.style.overflow='hidden';
 LV.kat=setInterval(()=>{if(LV&&LV.on&&Date.now()-LV.last>2000){LV.ka=true;lvKick();}},1000);
 lvSelect(LV.order.find(h=>!LV.towers||h.order<99)||LV.order[0],true);lvPush(true);}
function lvClose(){if(!LV)return;clearInterval(LV.kat);if(LV.tm)clearTimeout(LV.tm);LV.on=false;LV=null;$('live').classList.remove('on');document.body.style.overflow='';
 if(document.pointerLockElement)document.exitPointerLock();}
function lvEdits(){return LV.heads.some(h=>JSON.stringify(LV.W[h.id])!==LV.I0[h.id]);}
async function lvStop(reo){lvClose();busy(true,'Stopping the DMX output…');try{await api('/api/live/stop',{});}catch(e){}busy(false);if(reo)sxLaunch();}
function lvResult(r,mode){const reo=r.reopened?'<p class="sub" style="margin:8px 0 0">ShowXpress is opening again.</p>':r.reopenError?'<p style="color:var(--red)">ShowXpress didn&rsquo;t open: '+esc(r.reopenError)+'</p>':'';
 const at=mode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)';
 if(r.ok&&r.applied){showResult({ok:true,out:r.out},'apply');$('rtitle').innerHTML='<span style="color:var(--green)">&#10003;</span> Live aims saved and applied';$('rbody').insertAdjacentHTML('beforeend',reo);return;}
 const box=$('result');box.className='card result err';$('rlog').textContent=r.out||'';
 if(r.ok){$('rtitle').innerHTML='<span style="color:var(--amber)">&#9888;</span> Aims saved, not applied yet';$('rbody').innerHTML='<p>The aims are saved in <b>'+at+'</b>, but applying them to the show didn&rsquo;t work: '+esc(r.applyError||'unknown error')+'</p><p class="sub">Check the heads above, then press <b>Apply to show</b>.</p>'+reo;}
 else{$('rtitle').innerHTML='<span style="color:var(--red)">&#10007;</span> Live aims not saved';$('rbody').innerHTML='<p>'+esc(r.error||'Unknown error.')+'</p><p class="sub">Nothing was changed.</p>'+reo;}
 box.scrollIntoView({behavior:'smooth'});}
$('lvgo').onclick=lvGo;
$('lvcancel').onclick=async()=>{if(!LV)return;if(lvEdits()&&!await ask('Stop without saving?','The aims you set here are not saved. The heads go dark and the show keeps the aims it had.','Stop without saving'))return;lvStop($('lvreo').checked);};
$('lvsave').onclick=async()=>{if(!LV)return;const aims={};let n=0;
 for(const h of LV.heads){const w=LV.W[h.id];if(!w.tc&&!w.tk)continue;aims[h.id]={c:w.c.map(Math.round),k:w.tk?(w.k?w.k.map(Math.round):h.dk.slice()):null};n++;}
 const reo=$('lvreo').checked,mode=LV.mode;
 if(!n){if(await ask('Nothing was aimed','No head was moved, so there is nothing to save. Stop live aim?','Stop'))lvStop(reo);return;}
 lvClose();busy(true,'Saving '+n+' aim'+(n>1?'s':'')+' and applying them to the show…');
 let r;try{r=await api('/api/live/save',{mode,aims,apply:true,w:clamp($('w').value),d:clamp($('d').value),force:false,reopen:reo});}catch(e){r={ok:false,error:'Lost connection.'};}
 busy(false);lvResult(r,mode);load();};
$('lvnext').onclick=()=>lvStepTo(1);$('lvprev').onclick=()=>lvStepTo(-1);
$('lvundo').onclick=()=>{const h=LV.sel;LV.W[h.id]=JSON.parse(LV.I0[h.id]);lvPush(false);lvDirty();};
$('lvhome').onclick=()=>{const h=LV.sel;if(h.free&&!h.kSet)LV.W[h.id]=JSON.parse(LV.I0[h.id]);else LV.W[h.id]={c:h.home.slice(),k:null,tc:true,tk:true};lvPush(false);lvDirty();};
$('lvpart').onclick=()=>{const h=LV.sel,p=LV.byId[h.partner];if(!p)return;const pw=LV.W[p.id];LV.W[h.id]={c:lvPos(p,'c').slice(),k:pw.k?pw.k.slice():null,tc:true,tk:!!pw.k};lvPush(false);lvDirty();};
$('lvall').onchange=e=>{LV.all=e.target.checked;lvPush(false);};
function lvSetFlip(){const h=LV.sel;LV.flip={x:$('lvfx').checked,y:$('lvfy').checked};localStorage.setItem('sxh_flip_'+h.id,JSON.stringify(LV.flip));
 if(h.partner&&localStorage.getItem('sxh_flip_'+h.partner)===null)localStorage.setItem('sxh_flip_'+h.partner,JSON.stringify(LV.flip));lvDirty();}
$('lvfx').onchange=lvSetFlip;$('lvfy').onchange=lvSetFlip;
document.querySelectorAll('[data-st]').forEach(b=>b.onclick=()=>lvSetStep(b.dataset.st));
document.querySelectorAll('[data-sp]').forEach(b=>b.onclick=()=>{LV.spd=+b.dataset.sp;localStorage.setItem('sxh_lvspd',b.dataset.sp);document.querySelectorAll('[data-sp]').forEach(x=>x.classList.toggle('on',x===b));});
{const pad=$('lvpad');
 pad.onmousedown=e=>{if(!LV||e.button!==0)return;e.preventDefault();LV.drag=true;pad.classList.add('drag');try{const pr=pad.requestPointerLock();if(pr&&pr.catch)pr.catch(()=>{});}catch(x){}};
 const end=()=>{if(!LV||!LV.drag)return;LV.drag=false;pad.classList.remove('drag');if(document.pointerLockElement)document.exitPointerLock();};
 document.addEventListener('mousemove',e=>{if(LV&&LV.drag)lvMove(e.movementX,e.movementY,e.shiftKey,e.ctrlKey);});
 document.addEventListener('mouseup',end);document.addEventListener('pointerlockchange',()=>{if(!document.pointerLockElement)end();});
 // phone / iPad: drag a finger (or the Pencil) in the box - the head moves as far as the finger does, like the mouse
 let tp=null;
 pad.addEventListener('pointerdown',e=>{if(!LV||e.pointerType==='mouse'||tp)return;e.preventDefault();tp={id:e.pointerId,x:e.clientX,y:e.clientY};LV.drag=true;pad.classList.add('drag');try{pad.setPointerCapture(e.pointerId);}catch(x){}});
 pad.addEventListener('pointermove',e=>{if(!tp||e.pointerId!==tp.id||!LV)return;e.preventDefault();const dx=e.clientX-tp.x,dy=e.clientY-tp.y;tp.x=e.clientX;tp.y=e.clientY;lvMove(dx,dy,false,false);});
 const tend=e=>{if(!tp||e.pointerId!==tp.id)return;tp=null;if(LV)LV.drag=false;pad.classList.remove('drag');};
 pad.addEventListener('pointerup',tend);pad.addEventListener('pointercancel',tend);
 pad.addEventListener('touchmove',e=>{if(tp)e.preventDefault();},{passive:false});}
document.addEventListener('keydown',e=>{if(!LV||!LV.on||$('modal').style.display==='flex'||$('busy').style.display==='flex')return;
 const k=e.key,A={ArrowLeft:[-4,0],ArrowRight:[4,0],ArrowUp:[0,-4],ArrowDown:[0,4]}[k];
 if(A){e.preventDefault();lvMove(A[0],A[1],e.shiftKey,e.ctrlKey);return;}
 if(k==='Tab'){e.preventDefault();lvStepTo(e.shiftKey?-1:1);return;}
 if(e.ctrlKey||e.altKey)return;
 if(k==='n'||k==='N')lvStepTo(1);else if(k==='p'||k==='P')lvStepTo(-1);else if(k==='1')lvSetStep('c');else if(k==='2')lvSetStep('k');});
window.addEventListener('beforeunload',()=>{if(LV||CP||SEP||MVP||LKP)navigator.sendBeacon('/api/live/stop?t='+T,'{}');});
window.addEventListener('pagehide',()=>{if((LV||CP||SEP||MVP||LKP)&&PH)navigator.sendBeacon('/api/live/stop?t='+T,'{}');});

// ---------------- SETTINGS (cogwheel, user 2026-11-22): look (per device), tab order / hidden tabs (shared, settings.json
// on the computer), Google Drive, phone & iPad, ShowXpress, updates
const TABDEF=[...document.querySelectorAll('.tabs button[data-tab]')].map(b=>({id:b.dataset.tab,name:b.textContent}));
const TGOF={},TGNAME=[...document.querySelectorAll('.tg .tgn')].map(x=>x.textContent);document.querySelectorAll('.tg').forEach((g,i)=>g.querySelectorAll('[data-tab]').forEach(b=>TGOF[b.dataset.tab]=i));
let SET=null,SETV='';
// ---------------- Lab: SX Player, stages 1+2 (user 2026-11-23). The Helper plays the show's scenes itself (player.ps1).
let LB=null,LBS=null,LBT=0,LBbo=false,LBreo=false,LBerr='',LBgen=0,LBlastErr='',LBfdT={},LBfdS={},LBtest=false;
const lbX=v=>Math.pow(2,(v-0.5)*4),lbXs=v=>{const x=lbX(v);return (x>=1?'\u00d7'+x.toFixed(x<2?2:1):'\u00d7'+x.toFixed(2))+(Math.abs(v-0.5)<0.01?' (normal)':'');};
function lbFaders(){const fd=$('lbfd');if(!lbRun()||!LB||!LB.ok){fd.style.display='none';return;}
 const fs=(LB.faders||[]).filter(f=>String(f.type)==='1');fd.style.display='';
 if(fd.dataset.n!==String(fs.length)){fd.dataset.n=String(fs.length);
  fd.innerHTML='<h2 style="margin:0">Speed faders</h2><p class="sub" style="margin:4px 0 0" id="lbmidi"></p><div class="lbfds">'+(fs.length?fs.map(f=>'<label class="lbf"><b>'+esc(f.caption||('Fader '+(f.k+1)))+'</b><input type="range" min="0" max="127" value="64" data-k="'+f.k+'"><span id="lbfv'+f.k+'">\u00d71.00 (normal)</span></label>').join(''):'<span class="sub">The show has no speed faders.</span>')+'</div>';
  fd.querySelectorAll('input[type=range]').forEach(el=>{el.oninput=()=>{const k=+el.dataset.k,v=el.value/127;LBfdT[k]=Date.now();$('lbfv'+k).textContent=lbXs(v);
   if(!LBfdS[k]){LBfdS[k]=setTimeout(()=>{LBfdS[k]=0;lbCmd({cmd:'fader',k:k,v:el.value/127},true);},60);}};});}}
function lbFdDraw(st){if(!st)return;const m=$('lbmidi');
 if(m)m.innerHTML=st.midi?'<span style="color:var(--green)">&#9679;</span> <b>'+esc(st.midi)+'</b> connected &mdash; pads, pad lights and faders work.':(LBtest?'Test copy: no MIDI (the APC is left alone).':'<span style="color:var(--amber)">&#9679;</span> No APC mini found &mdash; plug it in, then stop and start the player.');
 (st.fd||[]).forEach((v,k)=>{const el=document.querySelector('#lbfd input[data-k="'+k+'"]');if(!el||Date.now()-(LBfdT[k]||0)<1500)return;const n=Math.round(v*127);if(+el.value!==n){el.value=n;$('lbfv'+k).textContent=lbXs(v);}});}
let LBbt={bpm:0,beat:0,at:0},LBraf=0,LBdot=-1;
function lbBpmCard(){const c=$('lbbpm');if(!lbRun()||!LB||!LB.ok){c.style.display='none';cancelAnimationFrame(LBraf);LBraf=0;return;}c.style.display='';
 if(!c.dataset.ok){c.dataset.ok='1';
  c.innerHTML='<div class="row" style="gap:14px;flex-wrap:wrap;align-items:center"><div><div class="sub" style="margin:0;letter-spacing:1px;font-size:11.5px">TEMPO</div><div class="aubig"><span id="lbbpmv">&ndash;</span> <small style="font-size:13px;color:var(--dim)">BPM</small></div><div class="sub" id="lbsrc" style="margin:0"></div></div>'+
   '<div class="aubeats" id="lbbeats"><i></i><i></i><i></i><i></i></div><div class="grow"></div>'+
   '<button id="lbtap" class="primary" style="padding:12px 26px;font-size:15px" title="Tap along with the beat">Tap</button>'+
   '<button class="mini" id="lbbm" title="1 BPM slower">&minus;</button><input id="lbbin" class="num" type="number" min="40" max="250" step="0.1" style="width:76px"><button class="mini" id="lbbp" title="1 BPM faster">+</button>'+
   '<button id="lbsync" title="Press on the first beat of a bar: BPM chases start again from their first step">Beat 1 now</button></div><p class="sub" id="lbos2l" style="margin:8px 0 0"></p>';
  $('lbtap').onpointerdown=e=>{e.preventDefault();LBbt={bpm:LBbt.bpm,beat:Math.round(lbBeatNow()),at:Date.now()};lbCmd({cmd:'tap'},true);};
  const setB=v=>{v=Math.max(40,Math.min(250,Math.round(v*10)/10));$('lbbin').value=v;lbCmd({cmd:'bpm',v:v},true);};
  $('lbbin').onchange=e=>{const v=parseFloat(e.target.value);if(v>=40&&v<=250)setB(v);};
  $('lbbm').onclick=()=>setB((LBbt.bpm||120)-1);$('lbbp').onclick=()=>setB((LBbt.bpm||120)+1);
  $('lbsync').onclick=()=>lbCmd({cmd:'sync'},true);}
 if(!LBraf){const f=()=>{LBraf=requestAnimationFrame(f);const n=((Math.floor(lbBeatNow())%4)+4)%4;if(n===LBdot)return;LBdot=n;
   const bs=$('lbbeats');if(bs)bs.querySelectorAll('i').forEach((x,k)=>{x.className=k<=n&&LBbt.bpm?'on'+(k===0?' one':''):'';});};LBraf=requestAnimationFrame(f);}}
function lbBeatNow(){return LBbt.bpm?LBbt.beat+(Date.now()-LBbt.at)*LBbt.bpm/60000:0;}
function lbBpmDraw(st){if(!st||st.bpm==null||!$('lbbpmv'))return;
 const nb=st.beat,now=lbBeatNow(),keep=LBbt.bpm===st.bpm&&Math.abs(now-nb)<0.6;LBbt={bpm:st.bpm,beat:keep?now:nb,at:Date.now()};
 $('lbbpmv').textContent=(Math.round(st.bpm*10)/10).toString();
 $('lbsrc').innerHTML=st.src==='VirtualDJ'?'from <b>VirtualDJ</b>':st.src==='tap'?'tapped':'set by hand';
 const bi=$('lbbin');if(bi&&document.activeElement!==bi){const v=String(Math.round(st.bpm*10)/10);if(bi.value!==v)bi.value=v;}
 const o=$('lbos2l');if(o)o.innerHTML=st.os2l?'<span style="color:var(--green)">&#9679;</span> <b>VirtualDJ</b> is connected ('+esc(st.os2l)+') &mdash; the beat follows the music.':
  st.os2lPort?(LBtest?'Test copy: VirtualDJ link on test port '+st.os2lPort+' (not announced).':'<span style="color:var(--dim)">&#9675;</span> Waiting for VirtualDJ (OS2L, port '+st.os2lPort+') &mdash; with OS2L on in VirtualDJ it finds SX Studio by itself, on this computer or another one on the same Wi-Fi.'):
  '<span style="color:var(--amber)">&#9679;</span> VirtualDJ link off'+(st.os2lErr?': '+esc(st.os2lErr)+'.':' (OS2L is turned off in ShowXpress&rsquo;s settings).');}
function lbToast(h){const e=$('lbtoast');e.innerHTML=h;e.classList.add('on');clearTimeout(e._t);e._t=setTimeout(()=>e.classList.remove('on'),4000);}
const lbRun=()=>!!(LBS&&LBS.running);
function lbCol(c){return c==null||c<0?'':'rgb('+((c>>16)&255)+','+((c>>8)&255)+','+(c&255)+')';}
function lbKind(b){return (b.key?'['+b.key.toUpperCase()+'] ':'')+lbKind0(b);}
function lbKind0(b){return b.kind==='gpj'?'movement'+(b.bpm?' \u00b7 BPM':''):b.kind==='missing'?'scene file missing':(b.steps>1?b.steps+' steps':'scene')+(b.bpm?' \u00b7 BPM'+(b.flash?' flash':''):'');}
// ---- arrange (user 2026-11-23): the user's own order of pages and buttons, only in this tab (settings.json playerLayout,
// shared with the phone). Buttons stay on their own page - a MOVEMENTS page's "one replaces the other" depends on it.
// Buttons the layout doesn't know yet (new in the show) go at the end of their page.
// 2026-11-24 (user): pages can be collapsed (any time) and hidden (in Arrange), and the player has pages of its own with
// buttons that play the show's scene / movement files. All of it is SX Studio's settings: the show is never written.
let LBarr=false;
function lbLay(){const l=(SET&&SET.playerLayout)||{};return {pages:(l.pages||[]).map(String),order:l.order||{},hidden:(l.hidden||[]).map(String),collapsed:(l.collapsed||[]).map(String),custom:JSON.parse(JSON.stringify(l.custom||[]))};}
function lbFileKind(f){const fs=(LB&&LB.files)||[],l=String(f).toLowerCase();return !fs.some(x=>String(x).toLowerCase()===l)?'missing':/\.gpj$/i.test(f)?'gpj':'scex';}
function lbCustom(){return lbLay().custom.map(c=>({n:c.id,name:c.name,swap:!!c.swap,custom:true,buttons:(c.buttons||[]).map(b=>({sec:b.id,title:b.title,file:b.file,kind:lbFileKind(b.file),steps:0,color:b.color,bpm:!!b.bpm,flash:!!b.flash,fader:b.fader,beats:b.beats,key:'',custom:true}))}));}
function lbAllPages(){return LB&&LB.ok?LB.pages.concat(lbCustom()):[];}
function lbAllButtons(){return lbAllPages().flatMap(p=>p.buttons);}
function lbPageOf(sec){return lbAllPages().find(p=>p.buttons.some(x=>x.sec===sec));}
function lbPages(){if(!LB||!LB.ok)return [];const lay=lbLay(),po=lay.pages,od=lay.order,hid=new Set(lay.hidden);
 const ix=(a,v,d)=>{const i=a.indexOf(v);return i<0?d:i;},cu=lay.custom.map(c=>c.id),key=p=>ix(po,String(p.n),p.custom?2e6+cu.indexOf(p.n):1e6+p.n);
 return lbAllPages().filter(p=>(p.custom||p.buttons.length)&&(LBarr||!hid.has(String(p.n)))).sort((a,b)=>key(a)-key(b))
  .map(p=>{const o=p.custom?[]:(od[String(p.n)]||[]).map(String);return {p:p,hid:hid.has(String(p.n)),col:lay.collapsed.includes(String(p.n)),bs:p.custom?p.buttons:p.buttons.slice().sort((a,b)=>ix(o,a.sec,1e6)-ix(o,b.sec,1e6))};});}
function lbArrange(on){LBarr=on;$('lbpages').classList.toggle('arr',on);$('lbarrbar').classList.toggle('on',on);$('lbarr').classList.toggle('son',on);
 $('lbarr').innerHTML=on?'&#10003; Arranging':'&#8645; Arrange';$('lbpages').dataset.gen='';if(LB)renderLab();}
const lbGen=()=>String(LB.show)+LB.pages.length+'|'+LBarr+'|'+JSON.stringify((SET&&SET.playerLayout)||{});
// a change from the page (drag, page arrows) is already on screen; any other change (hide, add, delete...) redraws at once,
// so Arrange shows every change live and Done only closes it (user 2026-11-24: before, the change only showed after Done)
async function lbSaveLayout(lay){const dom=!lay;if(!lay){lay=lbLay();const pages=[],order={};
  document.querySelectorAll('#lbpages .lbpg').forEach(g=>{const n=g.dataset.n,secs=[...g.querySelectorAll('.lbb')].map(x=>x.dataset.sec);pages.push(n);
   const c=lay.custom.find(x=>x.id===n);if(c)c.buttons=secs.map(s=>c.buttons.find(b=>b.id===s)).filter(Boolean);else order[n]=secs;});
  lay.pages.forEach(n=>{if(!pages.includes(n))pages.push(n);});lay.pages=pages;lay.order=Object.assign({},lay.order,order);}
 SET=Object.assign(SET||{},{playerLayout:lay});if(dom)$('lbpages').dataset.gen=lbGen();else renderLab();
 try{const r=await api('/api/settings/set',{playerLayout:lay});if(r.ok){const was=lbGen();SET=r.settings;if(dom||lbGen()===was)$('lbpages').dataset.gen=lbGen();else renderLab();}else lbToast('<span style="color:var(--amber)">The layout wasn&rsquo;t saved.</span>');}
 catch(e){lbToast('<span style="color:var(--amber)">The layout wasn&rsquo;t saved &mdash; lost connection.</span>');}}
async function lbSetLay(f){const lay=lbLay();f(lay);await lbSaveLayout(lay);renderLab();}
$('lbarr').onclick=()=>lbArrange(!LBarr);$('lbarrdone').onclick=()=>lbArrange(false);
$('lbarrreset').onclick=async()=>{if(!await ask('Back to ShowXpress&rsquo;s order?','The pages and buttons go back to the order they have in ShowXpress, and hidden pages show again. Your own pages stay, at the end.','Reset'))return;
 await lbSetLay(l=>{l.pages=[];l.order={};l.hidden=[];l.collapsed=[];});};
// ---- the player's own pages
const lbNextPage=lay=>'x'+(1+Math.max(0,...lay.custom.map(c=>+c.id.slice(1)||0))),lbNextBtn=c=>c.id+'_b'+(1+Math.max(0,...(c.buttons||[]).map(b=>+b.id.split('_b')[1]||0)));
function lbPageForm(name,swap){return 'Name<br><input id="lbpn" maxlength="40" style="width:100%;margin:6px 0 12px" value="'+esc(name||'')+'"><label style="display:flex;gap:8px;align-items:center"><input type="checkbox" id="lbps"'+(swap?' checked':'')+'> One at a time &mdash; a button here stops the others on this page (like MOVEMENTS)</label>'+
 '<br><span class="sub">This page is only in the SX Player. ShowXpress and its live screen don&rsquo;t change.</span>';}
const lbClean=v=>String(v||'').replace(/[\x00-\x1f<>|]/g,'').trim().slice(0,40);
$('lbnewpg').onclick=async()=>{const lay=lbLay();if(lay.custom.length>=40){lbToast('<span style="color:var(--amber)">That&rsquo;s the most pages the player can have (40).</span>');return;}
 const go=ask('New page',lbPageForm('',false),'Make the page');setTimeout(()=>{const i=$('lbpn');if(i)i.focus();},50);if(!await go)return;
 const nm=lbClean($('lbpn').value)||'NEW PAGE',id=lbNextPage(lay);lay.custom.push({id:id,name:nm,swap:$('lbps').checked,buttons:[]});lay.pages=lbPages().map(x=>String(x.p.n)).concat(id);
 await lbSaveLayout(lay);renderLab();lbAddButtons(id);};
async function lbAddButtons(id){const lay=lbLay(),c=lay.custom.find(x=>x.id===id);if(!c)return;
 const used=new Set(LB.pages.flatMap(p=>p.buttons.map(b=>String(b.file).toLowerCase()))),items=[];
 LB.pages.forEach(p=>p.buttons.forEach(b=>{if(b.kind!=='missing')items.push({k:'b:'+b.sec,t:b.title,s:esc(p.name||('Page '+p.n))+' &middot; '+esc(lbKind0(b)),b:b});}));
 ((LB&&LB.files)||[]).filter(f=>!used.has(String(f).toLowerCase())).forEach(f=>items.push({k:'f:'+f,t:String(f).replace(/\.(scex|gpj)$/i,''),s:'not on a button &middot; '+(/\.gpj$/i.test(f)?'movement':'scene'),f:f}));
 const go=ask('Add buttons to '+c.name,'Tick the buttons to copy onto this page. A copy plays the same scene with the same speed and BPM settings; it has no APC pad or key of its own.'+
  '<input id="lbaq" placeholder="Search" style="width:100%;margin:10px 0 6px"><div id="lbal" class="lbal">'+items.map((x,i)=>'<label data-t="'+esc((x.t+' '+x.s).toLowerCase())+'"><input type="checkbox" data-i="'+i+'"><b>'+esc(x.t)+'</b><small>'+x.s+'</small></label>').join('')+'</div>','Add');
 setTimeout(()=>{const q=$('lbaq');if(!q)return;q.focus();q.oninput=()=>{const v=q.value.trim().toLowerCase();document.querySelectorAll('#lbal label').forEach(l=>l.style.display=!v||l.dataset.t.includes(v)?'':'none');};},50);
 if(!await go)return;const pick=[...document.querySelectorAll('#lbal input:checked')].map(x=>items[+x.dataset.i]);if(!pick.length)return;
 const l2=lbLay(),c2=l2.custom.find(x=>x.id===id);if(!c2)return;c2.buttons=c2.buttons||[];let full=false;
 pick.forEach(x=>{if(c2.buttons.length>=64){full=true;return;}const b=x.b;
  c2.buttons.push(b?{id:lbNextBtn(c2),title:b.title,file:b.file,fader:b.fader||0,bpm:!!b.bpm,flash:!!b.flash,beats:b.beats||1,color:b.color==null?-1:b.color}:{id:lbNextBtn(c2),title:x.t,file:x.f,fader:0,bpm:false,flash:false,beats:1,color:-1});});
 await lbSaveLayout(l2);renderLab();if(full)lbToast('<span style="color:var(--amber)">A page holds 64 buttons &mdash; the rest weren&rsquo;t added.</span>');}
$('lbpages').addEventListener('click',async e=>{const t=e.target.closest('[data-pa],[data-pmv],[data-xdel]');if(!t)return;e.stopPropagation();
 const g=t.closest('.lbpg'),n=g.dataset.n;
 if(t.dataset.pa==='col'){const lay=lbLay(),c=!lay.collapsed.includes(n);lay.collapsed=lay.collapsed.filter(x=>x!==n);if(c)lay.collapsed.push(n);g.classList.toggle('col',c);t.innerHTML=c?'&#9656;':'&#9662;';t.title=c?'Open this page':'Collapse this page';lbSaveLayout(lay);drawLab();return;}
 if(!LBarr)return;
 if(t.dataset.pmv){const box=g.parentElement,sib=t.dataset.pmv==='-1'?g.previousElementSibling:g.nextElementSibling;if(!sib||!sib.classList.contains('lbpg'))return;
  if(t.dataset.pmv==='-1')box.insertBefore(g,sib);else box.insertBefore(sib,g);lbSaveLayout();return;}
 if(t.dataset.pa==='hide'){await lbSetLay(l=>{const h=!l.hidden.includes(n);l.hidden=l.hidden.filter(x=>x!==n);if(h)l.hidden.push(n);});return;}
 const lay=lbLay(),c=lay.custom.find(x=>x.id===n);if(!c)return;
 if(t.dataset.xdel){c.buttons=c.buttons.filter(b=>b.id!==t.dataset.xdel);await lbSaveLayout(lay);renderLab();return;}
 if(t.dataset.pa==='add'){lbAddButtons(n);return;}
 if(t.dataset.pa==='edit'){const go=ask('Page settings',lbPageForm(c.name,c.swap),'Save');if(!await go)return;c.name=lbClean($('lbpn').value)||c.name;c.swap=$('lbps').checked;await lbSaveLayout(lay);renderLab();return;}
 if(t.dataset.pa==='del'){if(!await ask('Delete '+c.name+'?','The page and its '+c.buttons.length+' button'+(c.buttons.length===1?'':'s')+' go from the SX Player. The scenes themselves stay in the show.','Delete the page'))return;
  lay.custom=lay.custom.filter(x=>x.id!==n);lay.pages=lay.pages.filter(x=>x!==n);lay.hidden=lay.hidden.filter(x=>x!==n);lay.collapsed=lay.collapsed.filter(x=>x!==n);await lbSaveLayout(lay);renderLab();}},true);
$('lbpages').addEventListener('pointerdown',e=>{if(!LBarr||e.button>0)return;if(e.target.closest('[data-xdel]'))return;const el=e.target.closest('.lbb');if(!el)return;e.preventDefault();
 const grid=el.parentElement,r=el.getBoundingClientRect(),gh=el.cloneNode(true),start=[...grid.children].indexOf(el),dx=e.clientX-r.left,dy=e.clientY-r.top;
 gh.classList.add('lbghost');gh.style.width=r.width+'px';gh.style.height=r.height+'px';gh.style.margin='0';document.body.appendChild(gh);el.classList.add('drag');
 const place=ev=>{gh.style.left=(ev.clientX-dx)+'px';gh.style.top=(ev.clientY-dy)+'px';};place(e);
 const mv=ev=>{place(ev);
  for(const c of grid.children){if(c===el)continue;const b=c.getBoundingClientRect();
   if(ev.clientY>=b.top&&ev.clientY<=b.bottom&&ev.clientX>=b.left&&ev.clientX<=b.right){grid.insertBefore(el,ev.clientX>b.left+b.width/2?c.nextSibling:c);break;}}
  if(ev.clientY<70)window.scrollBy(0,-14);else if(ev.clientY>innerHeight-70)window.scrollBy(0,14);};
 const up=()=>{window.removeEventListener('pointermove',mv);window.removeEventListener('pointerup',up);window.removeEventListener('pointercancel',up);
  gh.remove();el.classList.remove('drag');if([...grid.children].indexOf(el)!==start)lbSaveLayout();};
 window.addEventListener('pointermove',mv);window.addEventListener('pointerup',up);window.addEventListener('pointercancel',up);});
async function loadLab(){$('lbpages').innerHTML='<p class="sub" style="margin:0">Loading&hellip;</p>';LB=await getJ('/api/lab');try{LBS=await api('/api/lab/status');}catch(e){}renderLab();labPoll();}
function renderLab(){const run=lbRun();
 $('lbctl').innerHTML=run?'<span class="pill ok" style="margin-left:0">&#9679; Playing</span><button id="lboff" class="mini">Release all</button><button id="lbbo" class="mini">Blackout</button><div class="grow"></div>'+
   (PH?'':'<label style="display:flex;gap:6px;align-items:center;color:var(--dim);font-size:13px"><input type="checkbox" id="lbreo"'+(LBreo?' checked':'')+'> Open ShowXpress again when I stop</label>')+'<button id="lbho" class="mini" title="Stops the player and opens ShowXpress straight away; it carries on with what was playing">&#8644; Hand over to ShowXpress</button><button id="lbstop" class="primary">&#9632; Stop the player</button>'
  :'<button id="lbgo" class="primary"'+(LB&&LB.ok?'':' disabled')+'>&#9654; Start the player</button><span class="summary">or just tap a scene below &mdash; the player starts and plays it. ShowXpress closes while the player runs (only one program can use the DMX interface).</span><div class="grow"></div><button id="lbreload" class="mini">Reload the show</button>';
 lbFaders();lbBpmCard();
 if(run){$('lboff').onclick=()=>lbCmd({cmd:'alloff'});$('lbbo').onclick=()=>lbCmd({cmd:'bo',on:!LBbo});$('lbstop').onclick=lbStop;if($('lbho'))$('lbho').onclick=lbHandoff;if($('lbreo'))$('lbreo').onchange=e=>LBreo=e.target.checked;}
 else{$('lbgo').onclick=()=>lbGo();$('lbreload').onclick=loadLab;}
 const pg=$('lbpages');pg.classList.toggle('idle',!run);
 if(!LB||!LB.ok){pg.innerHTML='<p class="sub" style="margin:0;color:var(--red)">'+esc((LB&&LB.error)||'Could not read the show.')+'</p>';drawLab();return;}
 const gen=lbGen();
 if(!pg.querySelector('.lbb')||pg.dataset.gen!==gen){pg.dataset.gen=gen;const ps=lbPages(),lay=lbLay(),ids=new Set(lbAllPages().map(p=>String(p.n))),nh=lay.hidden.filter(n=>ids.has(n)).length;
  pg.innerHTML=ps.map(({p,bs,hid,col})=>'<div class="lbpg'+(col?' col':'')+(hid?' hid':'')+'" data-n="'+esc(String(p.n))+'"><h3><button class="pcol" data-pa="col" title="'+(col?'Open this page':'Collapse this page')+'">'+(col?'&#9656;':'&#9662;')+'</button>'+esc(p.name||('Page '+p.n))+
   (p.custom?'<span class="pgtag" title="Only in the SX Player - not in ShowXpress">SX Player</span>':'')+(hid?'<span class="pgtag">hidden</span>':'')+'<span class="pgon"></span>'+
   '<span class="pgbar"><button class="mini" data-pmv="-1" title="Move this page up">&#9650;</button><button class="mini" data-pmv="1" title="Move this page down">&#9660;</button><button class="mini'+(hid?' son':'')+'" data-pa="hide" title="'+(hid?'This page is hidden - press to show it in the player again':'Hide this page from the player (it still plays from the APC and the Auto Show)')+'">'+(hid?'&#128065; Unhide':'Hide')+'</button>'+
   (p.custom?'<button class="mini" data-pa="add">+ Buttons</button><button class="mini" data-pa="edit">Settings</button><button class="mini" data-pa="del">Delete</button>':'')+'</span></h3><div class="lbg">'+bs.map(b=>{const c=lbCol(b.color);
   return '<div class="lbb'+(b.kind==='missing'?' na':'')+'" data-sec="'+esc(b.sec)+'" data-k="'+esc(lbKind(b))+'" title="'+esc(b.file)+'"'+(c?' style="--c:'+c+'"':'')+'>'+(b.custom?'<i class="xdel" data-xdel="'+esc(b.sec)+'" title="Take it off this page">&times;</i>':'')+'<b>'+esc(b.title)+'</b><small>'+esc(lbKind(b))+'</small></div>';}).join('')+'</div>'+
   (p.custom&&!bs.length?'<p class="sub" style="margin:0">No buttons yet &mdash; '+(LBarr?'press <b>+ Buttons</b>.':'press <b>Arrange</b>, then <b>+ Buttons</b>.')+'</p>':'')+'</div>').join('')+
   (!LBarr&&nh?'<p class="sub" style="margin:14px 0 0">'+nh+' page'+(nh===1?' is':'s are')+' hidden &mdash; press <b>Arrange</b> to show '+(nh===1?'it':'them')+' again.</p>':'')||'<p class="sub" style="margin:0">No live buttons in the show.</p>';}
 drawLab();}
function drawLab(){const st=LBS&&LBS.running&&LBS.status,on={};if(st&&st.on)st.on.forEach(x=>on[x.slot]=x);
 document.querySelectorAll('#lbpages .lbpg').forEach(g=>{const n=g.classList.contains('col')?[...g.querySelectorAll('.lbb')].filter(el=>on[el.dataset.sec]).length:0,s=g.querySelector('.pgon'),tx=n?'\u25b6 '+n+' playing':'';if(s&&s.textContent!==tx)s.textContent=tx;});
 document.querySelectorAll('#lbpages .lbb').forEach(el=>{const x=on[el.dataset.sec];el.classList.toggle('on',!!x);const s=el.querySelector('small'),tx=x?(x.mv?'\u25b6 moving':x.of>1?'\u25b6 step '+x.step+' of '+x.of:'\u25b6 on'):el.dataset.k;if(s.textContent!==tx)s.textContent=tx;});
 lbFdDraw(st);lbBpmDraw(st);if(st)LBbo=!!st.bo;const bb=$('lbbo');if(bb){bb.classList.toggle('son',LBbo);bb.textContent=LBbo?'\u25cf Blackout is ON':'Blackout';}
 const se=st&&st.err?'<span style="color:var(--red)">Couldn&rsquo;t play '+esc(st.err)+'</span>':'';if(se&&se!==LBlastErr)lbToast(se);LBlastErr=se;
 const lo=st&&st.iface==='lost'?'<div style="color:var(--red);font-weight:600">&#9888; The DMX interface is unplugged &mdash; the lights aren&rsquo;t getting the show. Plug its USB cable back in: the player carries on by itself.</div>':'';
 const wn=st&&st.warn&&st.warn.length?'<details style="margin-top:6px;color:var(--amber)"><summary>Show check: '+st.warn.length+' problem'+(st.warn.length>1?'s':'')+' in the show</summary>'+st.warn.map(w=>'<div>'+esc(w)+'</div>').join('')+'</details>':'';
 const h=lo+(se||LBerr)+wn;if($('lbmsg').innerHTML!==h)$('lbmsg').innerHTML=h;}
let LBev=null;
function lbEvent(e){if(!e)return;if(LBev===null){LBev=e.n;return;}if(e.n===LBev)return;LBev=e.n;
 const c=e.kind==='back'?'var(--green)':e.kind==='lost'||e.kind==='gone'?'var(--red)':'var(--amber)';lbToast('<span style="color:'+c+'">'+esc(e.text)+'</span>');
 if(e.kind==='handoff'||e.kind==='gone'||e.kind==='restart')LBerr='<span style="color:'+c+'">'+esc(e.text)+'</span>';}
async function labPoll(){clearTimeout(LBT);LBT=0;if(!$('v-lab').classList.contains('on'))return;
 const g=LBgen,was=lbRun();let r=null;try{r=await api('/api/lab/status');}catch(e){}
 if(g===LBgen&&r&&r.ok){LBS=r;const pe=LBev;lbEvent(r.event);if(was!==lbRun()){if(was&&LBev===pe)LBerr='<span style="color:var(--amber)">The player stopped &mdash; SX Studio lost it.</span>';renderLab();}else drawLab();}
 if(!LBT)LBT=setTimeout(labPoll,lbRun()?400:2000);}
async function lbCmd(b,quiet){let r;try{r=await api('/api/lab/cmd',b);}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}
 if(quiet&&r.ok)return;
 if(r.ok){}else if(r.gone){LBgen++;LBS={ok:true,running:false};LBerr='<span style="color:var(--amber)">'+esc(r.error)+'</span>';lbToast(LBerr);renderLab();return;}else{LBerr='<span style="color:var(--amber)">'+esc(r.error)+'</span>';lbToast(LBerr);}
 drawLab();clearTimeout(LBT);LBT=setTimeout(labPoll,120);}
// ---- SX Player: right-click (or long-press) a button -> open its scene in the Scene Editor or its movement in the
// Movement Editor (user 2026-11-24)
function ctxClose(){$('ctxm').classList.remove('on');}
function ctxOpen(x,y,title,items){const m=$('ctxm');m.innerHTML='<div class="ctxh">'+esc(title)+'</div>'+items.map((it,i)=>'<button data-ci="'+i+'"'+(it.off?' disabled':'')+'>'+it.h+'</button>').join('');
 m.querySelectorAll('[data-ci]').forEach(b=>b.onclick=()=>{ctxClose();items[+b.dataset.ci].go();});
 m.classList.add('on');const r=m.getBoundingClientRect();m.style.left=Math.max(4,Math.min(x,innerWidth-r.width-4))+'px';m.style.top=Math.max(4,Math.min(y,innerHeight-r.height-4))+'px';}
document.addEventListener('pointerdown',e=>{if(!e.target.closest||!e.target.closest('#ctxm'))ctxClose();},true);
document.addEventListener('keydown',e=>{if(e.key==='Escape')ctxClose();});window.addEventListener('scroll',ctxClose,true);window.addEventListener('blur',ctxClose);
async function lbEditFile(b){const f=String(b.file||'');
 if(/\.gpj$/i.test(f)){setTab('move');await mvOpen(f);}else if(/\.scex$/i.test(f)){setTab('scene');await seOpen(f);}}
$('lbpages').addEventListener('contextmenu',e=>{const el=e.target.closest('.lbb');if(!el)return;const b=lbAllButtons().find(x=>x.sec===el.dataset.sec);if(!b)return;
 e.preventDefault();const mv=/\.gpj$/i.test(String(b.file||'')),na=b.kind==='missing';
 ctxOpen(e.clientX,e.clientY,b.title,[{h:'&#9998; Edit '+(mv?'movement':'scene')+(na?' (file missing)':''),off:na,go:()=>lbEditFile(b)}]);});
$('lbpages').addEventListener('click',e=>{const el=e.target.closest('.lbb');if(!el||LBarr)return;LBerr='';
 const b=lbAllButtons().find(x=>x.sec===el.dataset.sec);if(!b)return;
 if(b.kind==='missing'){LBerr='<span style="color:var(--amber)">'+esc(b.title)+': its file is missing.</span>';lbToast(LBerr);drawLab();return;}
 if(!lbRun()){lbGo(b.sec);return;}
 const on=el.classList.contains('on'),pg=lbPageOf(b.sec);
 if(!on&&pg&&pg.swap)pg.buttons.forEach(x=>{const o=document.querySelector('.lbb[data-sec="'+x.sec+'"]');if(o)o.classList.remove('on');});
 el.classList.toggle('on',!on);lbCmd({cmd:'press',sec:b.sec});});
document.addEventListener('keydown',e=>{if(!$('v-lab').classList.contains('on')||!lbRun()||e.ctrlKey||e.altKey||e.metaKey||e.repeat)return;
 if(/^(INPUT|TEXTAREA|SELECT)$/.test((e.target&&e.target.tagName)||'')&&e.target.type!=='range')return;if($('modal').style.display==='flex'||$('busy').style.display==='flex')return;
 const k=(e.key||'').toLowerCase();if(k.length!==1||!/[a-z0-9]/.test(k))return;
 if(!LB||!LB.pages.some(p=>p.buttons.some(x=>(x.key||'').toLowerCase()===k)))return;e.preventDefault();lbCmd({cmd:'key',key:k});});
async function lbGo(first){if(lbRun())return;
 if(LV||CP||SEP||MVP||LKP){lbToast('<span style="color:var(--amber)">Aim live, the colour preview or an editor / Looks preview is using the DMX interface &mdash; finish that first.</span>');return;}
 let carry=[];if(sxOpen){try{carry=(await api('/api/lab/snap',{})).titles||[];}catch(e){}}
 const c=await sxCloseLive('Close ShowXpress to start the player?','Only one program can use the DMX interface, so ShowXpress closes while the SX Player runs. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.'+(carry.length?'<br><br>The player carries on with what ShowXpress is playing now: <b>'+carry.map(esc).join(', ')+'</b>.':'')+'<br><br>It can open again when you stop, or straight away with <b>Hand over to ShowXpress</b>.','Close and start','Start the player','lab');
 if(!c.go)return;
 busy(true,'Connecting to the DMX interface…');let r;try{r=await api('/api/lab/start',{});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);
 if(!r.ok&&r.nova&&await ask('NovaStar is using the DMX interface','The NovaStar LED-screen software (NovaLCT) has a USB scanner that grabs the DMX interface. Pause it while the player runs? NovaLCT starts it again by itself &mdash; your LED screens are not touched.','Pause it and continue')){
  busy(true,'Pausing NovaStar and connecting…');try{r=await api('/api/lab/start',{stopNova:true});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);}
 if(!r.ok){if(c.reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'lab');return;}
 LBgen++;LBreo=c.reo;LBtest=!!r.test;LBbo=false;LBS={ok:true,running:true,status:null};LBerr=r.test?'Test copy: no real interface &mdash; the output goes to _dmx_frame.txt.':'Playing on <b>'+esc(r.iface||'the DMX interface')+'</b>. Tap a button to start or stop it.';
 if(r.list&&r.list.ok){LB=r.list;$('lbpages').dataset.gen='';}else if(!$('lb'+'pages').querySelector('.lbb'))await loadLab();renderLab();
 if(r.carried&&r.carried.length)LBerr+=' Carried on from ShowXpress: <b>'+r.carried.map(esc).join(', ')+'</b>.';
 const fb=typeof first==='string'&&first&&LB&&LB.ok&&lbAllButtons().find(x=>x.sec===first);
 if(fb&&!(r.carried||[]).includes(fb.title)){const el=document.querySelector('.lbb[data-sec="'+first+'"]');if(el)el.classList.add('on');await lbCmd({cmd:'press',sec:first});}
 labPoll();}
async function lbStop(){const reo=!PH&&$('lbreo')&&$('lbreo').checked,st=LBS&&LBS.status;
 if(st&&((st.on&&st.on.length)||(typeof AUS!=='undefined'&&AUS&&AUS.running&&AUS.target==='player'))&&!await ask('Stop the player?','The lights go out.'+(reo?' ShowXpress opens again.':'')+'<br><br>To keep the show going, use <b>Hand over to ShowXpress</b> instead.','Stop the player'))return;
 LBgen++;busy(true,'Stopping the player…');try{await api('/api/lab/stop',{});}catch(e){}busy(false);
 LBS={ok:true,running:false};LBbo=false;LBerr='Stopped. The lights are out.';renderLab();labPoll();if(reo)await sxLaunch();}
async function lbHandoff(){
 if(!await ask('Hand over to ShowXpress?','The player stops and ShowXpress opens straight away. It carries on with what is playing now'+(typeof AUS!=='undefined'&&AUS&&AUS.running?' (the Auto Show moves over to it)':'')+'.<br><br>The lights are dark for a few seconds while ShowXpress starts.','Hand over'))return;
 LBgen++;LBev=null;busy(true,'Handing over to ShowXpress…');let r;try{r=await api('/api/lab/handoff',{});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);
 LBS={ok:true,running:false};LBbo=false;
 LBerr=r.ok?(r.test?'(test copy) ':'')+'Handed over: ShowXpress is starting'+(r.auto?' and the Auto Show carries on in it.':r.titles&&r.titles.length?' &mdash; it will play <b>'+r.titles.map(esc).join(', ')+'</b> once it&rsquo;s ready.':'.'):'<span style="color:var(--red)">The player stopped, but ShowXpress didn&rsquo;t open: '+esc(r.error||'')+' Press Launch ShowXpress at the top.</span>';
 renderLab();labPoll();}


function themeMode(){try{return localStorage.getItem('sxh_theme')||'dark';}catch(e){return 'dark';}}
function applyTheme(){const m=themeMode(),l=m==='light'||(m==='auto'&&matchMedia('(prefers-color-scheme: light)').matches);
 document.documentElement.classList.toggle('light',l);const mt=document.querySelector('meta[name=theme-color]');if(mt)mt.content=l?'#eef0f4':'#0e1014';
 document.querySelectorAll('#stheme button').forEach(b=>b.classList.toggle('on',b.dataset.v===m));if(typeof draw==='function')try{draw();}catch(e){}}
try{matchMedia('(prefers-color-scheme: light)').addEventListener('change',applyTheme);}catch(e){}
document.querySelectorAll('#stheme button').forEach(b=>b.onclick=()=>{try{localStorage.setItem('sxh_theme',b.dataset.v);}catch(e){}applyTheme();});
function tabOrder(){const o=((SET&&SET.tabOrder)||[]).filter(id=>TABDEF.some(t=>t.id===id));TABDEF.forEach(t=>{if(!o.includes(t.id))o.push(t.id);});return o.map((id,i)=>[id,i]).sort((a,b)=>TGOF[a[0]]-TGOF[b[0]]||a[1]-b[1]).map(x=>x[0]);}
const tabDef=id=>(TABDEF.find(t=>t.id===id)||{name:id}).name,tabName=id=>((SET&&SET.tabNames&&SET.tabNames[id])||tabDef(id));
function applyTabs(){const nav=document.querySelector('.tabs'),hid=new Set((SET&&SET.tabHidden)||[]);
 tabOrder().forEach(id=>{const b=nav.querySelector('[data-tab="'+id+'"]'),nm=tabName(id);if(b){b.parentElement.appendChild(b);b.style.display=hid.has(id)?'none':'';if(b.textContent!==nm)b.textContent=nm;}
  document.querySelectorAll('.ht[data-go="'+id+'"]').forEach(x=>{x.style.display=hid.has(id)?'none':'';const t=x.querySelector('b');if(t&&t.textContent!==nm)t.textContent=nm;});});
 // a Home group whose tiles are all hidden goes too (with its heading)
 document.querySelectorAll('.htiles.hgrp').forEach(g=>{const v=[...g.children].some(x=>x.style.display!=='none');g.style.display=v?'':'none';const h=g.previousElementSibling;if(h&&h.classList.contains('hgrp'))h.style.display=v?'':'none';});tgSync();}
function renderTabs(){const o=tabOrder(),hid=new Set((SET&&SET.tabHidden)||[]),n=o.length;
 $('stabs').innerHTML=o.map((id,i)=>{const d=tabDef(id),nm=tabName(id);return (i&&TGOF[o[i-1]]===TGOF[id]?'':'<div class="tabgh">'+TGNAME[TGOF[id]]+'</div>')+'<div class="tabrow'+(hid.has(id)?' off':'')+'" data-id="'+id+'"><span class="hdl" title="Drag to move">&#9776;</span>'+
  '<input type="checkbox" data-show="'+id+'"'+(hid.has(id)?'':' checked')+' title="Show this tab">'+
  '<input class="tname" data-name="'+id+'" value="'+esc(nm)+'" maxlength="24" placeholder="'+esc(d)+'" title="Type a new name for this tab">'+(nm!==d?'<span class="tdef">'+esc(d)+'</span>':'')+
  '<button class="mini" data-mv="-1" title="Move up"'+(i&&TGOF[o[i-1]]===TGOF[id]?'':' disabled')+'>&#9650;</button><button class="mini" data-mv="1" title="Move down"'+(i<n-1&&TGOF[o[i+1]]===TGOF[id]?'':' disabled')+'>&#9660;</button></div>';}).join('');}
async function saveTabs(order,hidden,names){const o={tabOrder:order,tabHidden:hidden};if(names)o.tabNames=names;SET=Object.assign(SET||{},o);applyTabs();renderTabs();
 try{const r=await api('/api/settings/set',o);if(r.ok){SET=r.settings;applyTabs();if(names)renderTabs();}}catch(e){}}
const rowsNow=()=>[...$('stabs').querySelectorAll('.tabrow')].map(r=>r.dataset.id),hidNow=()=>[...$('stabs').querySelectorAll('[data-show]')].filter(c=>!c.checked).map(c=>c.dataset.show);
const namesNow=()=>{const o={};$('stabs').querySelectorAll('.tname').forEach(x=>{const v=x.value.replace(/[<>]/g,'').trim().slice(0,24);if(v&&v!==tabDef(x.dataset.name))o[x.dataset.name]=v;});return o;};
$('stabs').addEventListener('click',e=>{const b=e.target.closest('[data-mv]');if(!b)return;const o=rowsNow(),i=o.indexOf(b.closest('.tabrow').dataset.id),j=i+(+b.dataset.mv);
 if(j<0||j>=o.length||TGOF[o[i]]!==TGOF[o[j]])return;[o[i],o[j]]=[o[j],o[i]];saveTabs(o,hidNow());});
$('stabs').addEventListener('change',e=>{if(e.target.dataset.show)saveTabs(rowsNow(),hidNow());else if(e.target.dataset.name)saveTabs(rowsNow(),hidNow(),namesNow());});
$('stabs').addEventListener('keydown',e=>{if(e.target.dataset.name&&e.key==='Enter'){e.preventDefault();e.target.blur();}else if(e.target.dataset.name&&e.key==='Escape'){e.target.value=tabName(e.target.dataset.name);e.target.blur();}});
$('stabs').addEventListener('pointerdown',e=>{const h=e.target.closest('.hdl');if(!h)return;e.preventDefault();const row=h.closest('.tabrow'),box=$('stabs'),start=rowsNow().join();
 row.classList.add('drag');
 const mv=ev=>{let before=null;for(const r of box.children){if(r===row||(r.classList.contains('tabrow')&&TGOF[r.dataset.id]!==TGOF[row.dataset.id]))continue;const bb=r.getBoundingClientRect();if(ev.clientY<bb.top+bb.height/2){before=r;break;}}
  if(before!==row.nextSibling||(!before&&box.lastChild!==row))box.insertBefore(row,before);};
 const up=()=>{window.removeEventListener('pointermove',mv);window.removeEventListener('pointerup',up);window.removeEventListener('pointercancel',up);row.classList.remove('drag');
  if(rowsNow().join()!==start)saveTabs(rowsNow(),hidNow());};
 window.addEventListener('pointermove',mv);window.addEventListener('pointerup',up);window.addEventListener('pointercancel',up);});
$('stabreset').onclick=async()=>{if(SET&&SET.tabNames&&Object.keys(SET.tabNames).length&&!await ask('Reset the tabs?','Every tab gets its first place and name back, and hidden tabs show again.','Reset'))return;saveTabs(TABDEF.map(t=>t.id),[],{});};
async function loadSet(){const r=await getJ('/api/settings');if(!r.ok)return;SET=r.settings;SETV=r.ver||'';applyTabs();renderSet();if(LB&&LB.ok)renderLab();}
function renderSet(){if(!SET)return;applyTheme();renderTabs();$('sreopen').checked=SET.reopen!==false;$('sautoupd').checked=SET.autoUpd!==false;
 if(G&&G.show)$('sshow').textContent=G.show;if(!$('supd').dataset.done)$('supd').innerHTML='Version <b>'+esc(SETV)+'</b>';}
async function setOne(o,what){let r;try{r=await api('/api/settings/set',o);}catch(e){r={ok:false,error:'Lost connection.'};}
 if(r.ok){SET=r.settings;renderSet();if(what==='gd')loadGd();}else showResult({ok:false,error:r.error||'Not saved.'},'sx');return r;}
$('sreopen').onchange=e=>setOne({reopen:e.target.checked});$('sautoupd').onchange=e=>setOne({autoUpd:e.target.checked});
async function openOn(what){let r;try{r=await api('/api/open',{what});}catch(e){r={ok:false,error:'Lost connection.'};}if(!r.ok)showResult(r,'sx');}
// export / import settings: the server gives SX Studio's settings, the page adds this device's own (light/dark etc.)
const andList=a=>a.length>1?a.slice(0,-1).join(', ')+' and '+a[a.length-1]:a.join('');
const devKeys=()=>{const o={};for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(/^sxh_/.test(k)&&k!=='sxh_phone_key')o[k]=localStorage.getItem(k);}return o;};
$('sexp').onclick=async()=>{busy(true,'Exporting the settings…');let r;try{r=await api('/api/config/export',{device:devKeys()});}catch(x){r={ok:false,error:'Lost connection to SX Studio.'};}busy(false);
 if(!r.ok){$('scfg').innerHTML='<span style="color:var(--red)">'+esc(r.error||'The settings couldn&rsquo;t be saved.')+'</span>';return;}
 $('scfg').innerHTML='&#10003; Saved <b>'+esc(r.name)+'</b> in '+esc(r.folder)+' <button class="mini" id="scfgshow">Show the file</button>';$('scfgshow').onclick=()=>openOn('export');};
$('simp').onclick=()=>{$('simpf').value='';$('simpf').click();};
$('simpf').onchange=async e=>{const f=e.target.files[0];if(!f)return;let d=null;try{d=JSON.parse(await f.text());}catch(x){}
 if(!d||d.app!=='SX Studio'||d.kind!=='settings'){$('scfg').innerHTML='<span style="color:var(--red)">That file isn&rsquo;t an SX Studio settings file.</span>';return;}
 const dev=d.device&&typeof d.device==='object'?d.device:null,what=[d.settings&&'the tabs and the SX Player pages',d.apc40&&'the APC40 pads and faders',d.apcMini&&'the APC mini pads',d.speedFaders&&'the speed faders',d.autoShow&&'the Auto Show',d.phone&&'phone access on/off',dev&&'this computer&rsquo;s own choices'].filter(Boolean);
 if(!what.length){$('scfg').innerHTML='<span style="color:var(--amber)">That file has no settings in it.</span>';return;}
 if(!await ask('Import these settings?','<b>'+esc(f.name)+'</b>'+(d.saved?' (saved '+esc(String(d.saved).slice(0,10))+(d.version?' by version '+esc(d.version):'')+')':'')+' replaces '+andList(what)+'. What you have now is backed up first.','Import'))return;
 busy(true,'Importing the settings…');let r;try{r=await api('/api/config/import',{data:d});}catch(x){r={ok:false,error:'Lost connection to SX Studio.'};}busy(false);
 if(!r.ok){$('scfg').innerHTML='<span style="color:var(--red)">'+esc(r.error||'Nothing was imported.')+'</span>';return;}
 const done=r.done||[];if(dev){Object.keys(dev).forEach(k=>{if(/^sxh_/.test(k)&&k!=='sxh_phone_key'&&typeof dev[k]==='string')localStorage.setItem(k,dev[k]);});done.push('this computer&rsquo;s own choices');}A=null;SP=null;H=null;
 SET=r.settings;Q4=null;L4=null;AU=null;applyTheme();applyTabs();renderSet();if(LB&&LB.ok)renderLab();
 $('scfg').innerHTML=(done.length?'&#10003; Imported '+andList(done)+'.':'Nothing was imported.')+((r.warn||[]).length?' <span style="color:var(--amber)">'+r.warn.map(esc).join(' ')+'</span>':'');};
$('sopenshow').onclick=()=>openOn('show');$('gdbk').onclick=()=>openOn('backups');$('gdapp').onclick=()=>openOn('gdapp');$('gddl').onclick=()=>openOn('gddl');
$('gdfoldset').onclick=async()=>{const v=$('gdfold').value.trim();if(!v)return;const r=await setOne({driveFolder:v},'gd');if(r.ok)$('gdfold').value=SET.driveFolder;};
$('gdfoldauto').onclick=async()=>{$('gdfold').value='';await setOne({driveFolder:''},'gd');};
$('supdchk').onclick=async()=>{$('supd').dataset.done='1';$('supd').textContent='Checking GitHub…';const u=await getJ('/api/update?fresh=1');
 $('supd').innerHTML='Version <b>'+esc(u.current||SETV)+'</b>'+(u.ok?(u.newer?' &mdash; version <b>'+esc(u.latest)+'</b> is ready: press <b>&#11014; Update</b> at the top.':' &mdash; up to date.'):' &mdash; couldn&rsquo;t reach GitHub.');
 if(u.ok)chkUpd();};
function updGdAcct(){if(!G||!$('gdacct'))return;
 $('gdacct').innerHTML=!G.ok?'':G.found?'&#10003; Google Drive is signed in'+(G.account?' as <b>'+esc(G.account)+'</b>':'')+' &mdash; it uploads and downloads the show by itself.':
  G.appFound?'<span style="color:var(--amber)">Google Drive is installed but not signed in.</span> Press <b>Open Google Drive</b> and sign in with the AWAAZ Google account.':
  '<span style="color:var(--amber)">Google Drive for desktop isn&rsquo;t on this computer.</span> Press <b>Get Google Drive</b>, install it and sign in.';
 $('gdapp').style.display=G.appFound?'':'none';$('gdapp').textContent=G.found?'Open Google Drive':'Sign in to Google Drive';
 if(document.activeElement!==$('gdfold'))$('gdfold').value=G.override||'';$('gdfold').placeholder=G.my&&!G.override?'Found: '+G.my:'Found automatically';
 if(G.show)$('sshow').textContent=G.show;}
applyTheme();

// ---------------- Scene Editor (scene_edit.ps1, user 2026-11-24): change a scene's steps and values, see it on the lights.
// The page keeps a working copy of the steps; Save sends only what differs from the file (scene_edit.ps1 changes just that).
let SL=null,SE=null,SW=null,seI=0,seSel=new Set(),seMo='',SEP=null,seVer=0,seTab=null;
const seKey=(f,i)=>f+'|'+i,seCs=w=>w.len==null?100:w.len,seSec=cs=>(cs/100).toFixed(2).replace(/0$/,'');
async function loadScenes(){$('secount').textContent='Loading…';SL=await getJ('/api/scenes');renderScenes();}
function renderScenes(){const pick=!SE;$('sepickw').style.display=pick?'':'none';$('sew').style.display=pick?'none':'';$('seback').style.display=pick?'none':'';
if(pick){$('sebk').style.display='none';$('setitle').textContent='Scene Editor';$('sestate').style.display='none';}
 if(!pick){updScene();return;}
 if(!SL){$('selist').innerHTML='';updScene();return;}
 if(showErr('seerr',SL)){$('selist').innerHTML='';$('secount').textContent='';updScene();return;}
 const q=$('seq').value.trim().toLowerCase(),ls=SL.scenes.filter(s=>!q||s.name.toLowerCase().includes(q)||(s.used||[]).some(u=>u.toLowerCase().includes(q)));
 $('secount').textContent=SL.scenes.length+' scenes'+(q?' · '+ls.length+' found':'')+' · tap one to open it';
 $('selist').innerHTML=ls.slice(0,500).map(s=>{const u=s.used||[];return `<div class="sc sesc" data-sf="${esc(s.file)}"><div class="nm">${esc(s.name)}${s.trimmed?'<span class="tag amber">trimmed tonight</span>':''}<small>${u.length?esc(u.join(' · ')):'not on a live button'}</small></div><div></div><div class="st"><b>${s.steps}</b> step${s.steps===1?'':'s'} &middot; <b>${s.heads}</b> head${s.heads===1?'':'s'}</div></div>`;}).join('')||'<p class="sub">No scene matches.</p>';
 $('selist').querySelectorAll('[data-sf]').forEach(e=>e.onclick=()=>seOpen(e.dataset.sf));updScene();}
async function seOpen(f,keep){
 if(!keep&&SE&&seDirty()&&!await ask('Leave this scene?','Your changes to <b>'+esc(SE.name)+'</b> are not saved yet. They will be lost.','Leave it'))return;
 await sePvStop(SEP?SEP.reo:false);
 busy(true,'Opening the scene…');const r=await getJ('/api/scene?f='+encodeURIComponent(f));busy(false);
 if(!r.ok){showErr('seerr',r);return;}showErr('seerr',null);
 const was=keep&&SE&&SE.file===f?{i:seI,sel:seSel,mo:seMo}:null;
 SE=r;SE.used=SE.used||[];SE.heads=SE.heads||[];SE.steps=SE.steps||[];SE.models=SE.models||{};SE.byId={};SE.heads.forEach(h=>SE.byId[h.id]=h);
 SE.steps.forEach(s=>{s.map={};s.fx=s.fx||[];s.ids=new Set();s.fx.forEach(x=>{s.ids.add(x.id);(x.ch||[]).forEach(c=>s.map[seKey(x.id,c[0])]=c);});});   // c = [index, name, value, fade]
 seReset();
 if(was){seI=Math.min(was.i,Math.max(0,SW.steps.length-1));seSel=was.sel;seMo=was.mo;}
 else{seI=0;seSel=new Set();seMo='';const h=SE.heads[0];if(h){seSel.add(h.id);seMo=h.model;}}
 renderScenes();renderScene();seBackups();}
function seReset(){SW={steps:SE.readonly?[]:SE.steps.map((s,i)=>seFromStep(i)),add:[],del:[]};seVer++;}
function seFromStep(i){const s=SE.steps[i],ch={};for(const k in s.map){const c=s.map[k];ch[k]=[c[2],c[3]?1:0];}return {src:i,len:s.len,ch};}
function seGone(fx,ix){return SW.del.some(d=>d.fx===fx&&d.ix===ix);}
function seBody(){const steps=SW.steps.map(w=>{const o=SE.steps[w.src],set=[];
  for(const k in w.ch){const p=k.split('|'),fx=p[0],ix=+p[1],c=o.map[k],v=w.ch[k];
   if(!c){if(v[0]||v[1])set.push({fx,ix,v:v[0],fade:!!v[1]});continue;}
   const x={fx,ix};let d=false;if(v[0]!==c[2]){x.v=v[0];d=true;}if(!!v[1]!==!!c[3]){x.fade=!!v[1];d=true;}if(d)set.push(x);}
  const s={src:w.src,set};if(w.len!==o.len)s.len=w.len;return s;});
 return {scene:SE.file,sha:SE.sha,steps,addch:SW.add.slice(),delch:SW.del.slice()};}
function seDirty(){if(!SE||SE.readonly||!SW)return false;const b=seBody();
 return b.addch.length||b.delch.length||b.steps.length!==SE.steps.length||b.steps.some((s,i)=>s.src!==i||s.set.length||s.len!==undefined);}
function seWhat(){const b=seBody();let v=0,l=0;b.steps.forEach(s=>{v+=s.set.length;if(s.len!==undefined)l++;});const o=[];
 if(b.steps.length!==SE.steps.length)o.push(SE.steps.length+' → '+b.steps.length+' steps');else if(b.steps.some((s,i)=>s.src!==i))o.push('steps moved');
 if(v)o.push(v+' value'+(v===1?'':'s'));if(l)o.push(l+' step time'+(l===1?'':'s'));if(b.addch.length)o.push(b.addch.length+' channel'+(b.addch.length===1?'':'s')+' added');if(b.delch.length)o.push(b.delch.length+' taken out');return o.join(', ');}
// ---- lit or dark (same rule as Tonight's Rig: dimmer above 0 and the shutter not closed; no dimmer = any channel above 0)
function seClosed(mo,v){const r=((SE.models[mo]||{}).ranges||{}).shutter;if(!r)return false;return r.some(x=>x.n==='closed'&&v>=x.lo&&v<=x.hi);}
function seChName(mo,ix,k){const m=SE.models[mo],c=m&&(m.chans||[]).find(x=>x.ix===ix);if(c)return c.name;for(const s of SE.steps){const x=s.map[k];if(x)return x[1];}return 'channel '+(ix+1);}
function seLit(w,h){let dim=null,sh=null,any=false;for(const k in w.ch){if(!k.startsWith(h.id+'|'))continue;const ix=+k.split('|')[1],n=seChName(h.model,ix,k).toLowerCase(),v=w.ch[k][0];
  if(n==='dimmer')dim=v;else if(n==='shutter')sh=v;if(v>0)any=true;}
 if(dim===null)return any;return dim>0&&!(sh!==null&&seClosed(h.model,sh));}
function seIn(w,id){return SE.steps[w.src].ids.has(id);}
// ---- drawing
function renderScene(){if(!SE)return;const ro=SE.readonly;$('setitle').textContent=SE.name;
 const np=SE.heads.filter(h=>!h.addr).length;
 $('seinfo').innerHTML=(SE.used.length?'On '+SE.used.map(esc).join(' &middot; '):'Not on a live button')+' &middot; '+SE.heads.length+' head'+(SE.heads.length===1?'':'s');
 const w=[];if(ro)w.push('SX Studio doesn&rsquo;t change this scene: '+esc(ro)+'. ShowXpress still opens and edits it as before.');
 if(SE.trimmed)w.push('<b>Tonight&rsquo;s Rig has trimmed this scene for tonight.</b> If you save it, the version you save counts as the full scene from then on: the steps Tonight&rsquo;s Rig took out don&rsquo;t come back.');
 if(!ro&&!SE.structural)w.push('This scene has something between its steps that SX Studio doesn&rsquo;t know, so its steps can be changed here but not added, moved or taken out.');
 if(!ro&&np)w.push(np+' head'+(np===1?' isn&rsquo;t':'s aren&rsquo;t')+' patched in the show (no DMX address), so '+(np===1?'it doesn&rsquo;t':'they don&rsquo;t')+' show on the lights.');
 const wb=$('sewarn');wb.style.display=w.length?'block':'none';wb.innerHTML=w.join('<br><br>');
 $('seedit').style.display=ro?'none':'';if(ro){updScene();return;}
 seStepsDraw();seGridDraw();seHeadsDraw();seChDraw();updScene();}
function seStepsDraw(){const seen={};
 $('sesteps').innerHTML=SW.steps.map((w,i)=>{const o=SE.steps[w.src],cp=seen[w.src];seen[w.src]=1;const b=seBody().steps[i];
  const chg=b.set.length||b.len!==undefined;const pl=SEP&&SEP.play&&SEP.at===i;
  return `<div class="sst${i===seI?' on':''}${chg?' chg':''}${cp?' new':''}${pl?' pl':''}" data-si="${i}">${i+1}<small>${seSec(seCs(w))} s</small></div>`;}).join('');
 $('sesteps').querySelectorAll('[data-si]').forEach(e=>e.onclick=()=>{seI=+e.dataset.si;seStepsDraw();seGridDraw();seHeadsDraw();seChDraw();updScene();sePush();});
 $('secnt').textContent=SW.steps.length+' step'+(SW.steps.length===1?'':'s')+' · loop '+seSec(SW.steps.reduce((a,w)=>a+seCs(w),0))+' s';
 const w=SW.steps[seI];if(document.activeElement!==$('selen'))$('selen').value=w?seSec(seCs(w)):'';}
function seGridDraw(){if(!SE.heads.length){$('segrid').innerHTML='';return;}
 const big=SW.steps.length>60;
 $('segrid').innerHTML='<table><tr class="hd"><th></th>'+SW.steps.map((w,i)=>'<th class="'+(i===seI?'on':'')+'" data-gs="'+i+'">'+(big&&i%5?'':(i+1))+'</th>').join('')+'</tr>'+
  SE.heads.map(h=>'<tr><th class="'+(seSel.has(h.id)?'on':'')+'" data-gh="'+esc(h.id)+'">'+esc(h.name)+'</th>'+SW.steps.map((w,i)=>{const inn=seIn(w,h.id);
   return '<td class="'+(!inn?'n':seLit(w,h)?'l':'')+(i===seI&&seSel.has(h.id)?' c':'')+'" data-gs="'+i+'" data-gh="'+esc(h.id)+'"></td>';}).join('')+'</tr>').join('')+'</table>';
 $('segrid').querySelectorAll('[data-gs],[data-gh]').forEach(e=>e.onclick=ev=>{const s=e.dataset.gs,h=e.dataset.gh;if(s!==undefined)seI=+s;
  if(h!==undefined){const m=SE.byId[h].model;if(m!==seMo||!(ev.shiftKey||ev.ctrlKey||ev.metaKey))seSel=new Set();seMo=m;seSel.has(h)&&seSel.size>1?seSel.delete(h):seSel.add(h);}
  seStepsDraw();seGridDraw();seHeadsDraw();seChDraw();updScene();sePush();});}
function seHeadsDraw(){const w=SW.steps[seI],g={};SE.heads.forEach(h=>(g[h.model]=g[h.model]||[]).push(h));
 $('sehl').innerHTML=Object.keys(g).map(m=>'<div class="gh" style="margin:10px 0 4px"><h3>'+esc(m)+'</h3></div>'+g[m].map(h=>'<div class="seh'+(seSel.has(h.id)?' on':'')+(w&&!seIn(w,h.id)?' dim':'')+'" data-hh="'+esc(h.id)+'"><span>'+esc(h.name)+'</span><small>'+(h.addr?'DMX '+h.addr:'not patched')+'</small></div>').join('')).join('');
 $('sehl').querySelectorAll('[data-hh]').forEach(e=>e.onclick=()=>{const h=SE.byId[e.dataset.hh];if(h.model!==seMo){seSel=new Set();seMo=h.model;}
  if(seSel.has(h.id))seSel.delete(h.id);else seSel.add(h.id);seGridDraw();seHeadsDraw();seChDraw();updScene();});}
function seRows(){// the channels of the picked heads in this step: ix -> {k:[keys], vals:[...]}
 const w=SW.steps[seI],r={};if(!w)return r;
 for(const id of seSel){for(const k in w.ch){if(!k.startsWith(id+'|'))continue;const ix=+k.split('|')[1];(r[ix]=r[ix]||{ix,keys:[]}).keys.push(k);}}
 return r;}
function seRangeOpts(rs,v){return '<option value="">'+(rs.length?'named&hellip;':'&mdash;')+'</option>'+rs.map(x=>'<option value="'+Math.round((x.lo+x.hi)/2)+'"'+(v>=x.lo&&v<=x.hi?' selected':'')+'>'+esc(x.n)+' ('+x.lo+(x.hi!==x.lo?'&ndash;'+x.hi:'')+')</option>').join('');}
function seChDraw(){const w=SW.steps[seI],box=$('sechs');if(!w||!seSel.size){box.innerHTML='<p class="sub" style="margin:0">Pick one or more heads on the left (or in the grid). Shift-click in the grid picks more.</p>';$('seaddw').style.display='none';return;}
 const rows=Object.values(seRows()).sort((a,b)=>a.ix-b.ix),o=SE.steps[w.src],ro=k=>{const c=o.map[k];return c&&c[2]<0;};
 const nm=[...seSel].map(id=>SE.byId[id].name);
 box.innerHTML='<div class="row" style="margin-bottom:6px"><b class="grow">'+esc(nm.length>3?nm.length+' heads':nm.join(', '))+' &middot; step '+(seI+1)+'</b><span class="sub" style="margin:0">'+esc(seMo)+'</span></div>'+
  (rows.length?rows.map(r=>{const vs=r.keys.map(k=>w.ch[k][0]),fs=r.keys.map(k=>w.ch[k][1]),v=vs[0],mix=vs.some(x=>x!==v),fm=fs.some(x=>x!==fs[0]),k0=r.keys[0],n=seChName(seMo,r.ix,k0),rs=((SE.models[seMo]||{}).ranges||{})[n.toLowerCase()]||[];
   const chg=r.keys.some(k=>{const c=o.map[k];return !c||c[2]!==w.ch[k][0]||!!c[3]!==!!w.ch[k][1];});
   if(r.keys.some(ro))return '<div class="secr"><div class="nm">'+esc(n)+'<small>ch '+(r.ix+1)+'</small></div><div class="sub" style="margin:0;grid-column:span 5">a value SX Studio doesn&rsquo;t change &mdash; edit it in ShowXpress</div></div>';
   return '<div class="secr'+(chg?' chg':'')+(mix?' mix':'')+'" data-cx="'+r.ix+'"><div class="nm">'+esc(n)+'<small>ch '+(r.ix+1)+(mix?' &middot; mixed':'')+'</small></div>'+
    '<input type="range" min="0" max="255" value="'+v+'" data-cv><input class="num" type="number" min="0" max="255" value="'+v+'" data-cn style="width:64px;font-size:13px">'+
    '<select data-cr>'+seRangeOpts(rs,v)+'</select><label class="link fd" title="Glide from the step before over this step&rsquo;s time"><input type="checkbox" data-cf'+(fs[0]&&!fm?' checked':'')+'> fade</label>'+
    '<button class="x" data-cd title="Take this channel out of these heads, in every step">&times;</button></div>';}).join(''):'<p class="sub" style="margin:0">'+(nm.length===1?'This head has':'These heads have')+' no channels in this step.</p>');
 box.querySelectorAll('[data-cx]').forEach(row=>{const ix=+row.dataset.cx,rg=row.querySelector('[data-cv]'),nb=row.querySelector('[data-cn]'),sl=row.querySelector('[data-cr]');
  const put=v=>{v=Math.max(0,Math.min(255,Math.round(+v||0)));for(const k of seRows()[ix].keys)w.ch[k][0]=v;rg.value=v;if(document.activeElement!==nb)nb.value=v;
   const n=seChName(seMo,ix,seRows()[ix].keys[0]),rs=((SE.models[seMo]||{}).ranges||{})[n.toLowerCase()]||[];sl.innerHTML=seRangeOpts(rs,v);row.classList.remove('mix');seVer++;seLite();};
  rg.oninput=()=>put(rg.value);nb.oninput=()=>{if(nb.value!=='')put(nb.value);};nb.onchange=()=>{put(nb.value);seChDraw();};rg.onchange=()=>seChDraw();
  sl.onchange=()=>{if(sl.value!=='')put(sl.value);seChDraw();};
  row.querySelector('[data-cf]').onchange=e=>{for(const k of seRows()[ix].keys)w.ch[k][1]=e.target.checked?1:0;seVer++;seLite();seChDraw();};
  row.querySelector('[data-cd]').onclick=()=>seDelCh(ix);});
 // add a channel the model has (as named in the show's scenes) that these heads don't have yet
 const have=new Set(rows.map(r=>r.ix)),opts=((SE.models[seMo]||{}).chans||[]).filter(c=>!have.has(c.ix)&&[...seSel].some(id=>seIn(w,id)));
 $('seaddw').style.display=opts.length?'':'none';$('seadd').innerHTML=opts.map(c=>'<option value="'+c.ix+'">'+esc(c.name)+' (ch '+(c.ix+1)+')</option>').join('');}
function seLite(){seStepsDraw();seGridDraw();updScene();sePush();}
async function seDelCh(ix){const ids=[...seSel].filter(id=>SW.steps.some(w=>w.ch[seKey(id,ix)]));if(!ids.length)return;
 const n=seChName(seMo,ix,seKey(ids[0],ix));
 if(!await ask('Take '+n+' out?','Channel <b>'+esc(n)+'</b> comes out of '+(ids.length===1?esc(SE.byId[ids[0]].name):ids.length+' heads')+' in <b>every step</b> of this scene. In ShowXpress it then isn&rsquo;t set by this scene at all.','Take it out'))return;
 for(const id of ids){const k=seKey(id,ix);SW.steps.forEach(w=>delete w.ch[k]);
  const a=SW.add.findIndex(x=>x.fx===id&&x.ix===ix);if(a>=0)SW.add.splice(a,1);else if(SE.steps.some(s=>s.map[k]))SW.del.push({fx:id,ix});}
 seVer++;seChDraw();seLite();}
function seAddCh(){const ix=+$('seadd').value;if(isNaN(ix))return;
 for(const id of seSel){const k=seKey(id,ix);const d=SW.del.findIndex(x=>x.fx===id&&x.ix===ix);
  if(d>=0){SW.del.splice(d,1);SW.steps.forEach(w=>{const c=SE.steps[w.src].map[k];if(c)w.ch[k]=[c[2],c[3]?1:0];});continue;}   // put back what was taken out
  if(SE.steps.some(s=>s.map[k])||SW.add.some(x=>x.fx===id&&x.ix===ix))continue;
  SW.add.push({fx:id,ix});SW.steps.forEach(w=>{if(seIn(w,id))w.ch[k]=[0,0];});}
 seVer++;seChDraw();seLite();}
function updScene(){const ok=!!(SE&&!SE.readonly),d=seDirty(),st=ok&&SE.structural,n=ok?SW.steps.length:0;
 $('sesave').disabled=!ok||!d;$('seundo').disabled=!ok||!d;
 $('seleft').disabled=!st||seI<1;$('seright').disabled=!st||seI>=n-1;$('secopy').disabled=!st||n>=999;$('sedel').disabled=!st||n<2;
 if(SE)stateTag('sestate',d);
 $('sehint').innerHTML=!SE?'Open a scene to change it.':SE.readonly?'This scene can only be changed in ShowXpress.':sxHint('save')??(d?esc(seWhat())+'. Only that is changed in the file.':'Matches the show.');
 document.querySelectorAll('.sebkr').forEach(b=>b.disabled=sxOpen);}
function seMove(dir){const j=seI+dir;if(j<0||j>=SW.steps.length)return;const s=SW.steps;[s[seI],s[j]]=[s[j],s[seI]];seI=j;seVer++;seStepsDraw();seGridDraw();seHeadsDraw();seChDraw();updScene();sePush();}
$('seleft').onclick=()=>seMove(-1);$('seright').onclick=()=>seMove(1);
$('secopy').onclick=()=>{const w=SW.steps[seI],c={src:w.src,len:w.len,ch:{}};for(const k in w.ch)c.ch[k]=w.ch[k].slice();SW.steps.splice(seI+1,0,c);seI++;seVer++;seStepsDraw();seGridDraw();seChDraw();updScene();sePush();};
$('sedel').onclick=()=>{if(SW.steps.length<2)return;SW.steps.splice(seI,1);seI=Math.min(seI,SW.steps.length-1);seVer++;seStepsDraw();seGridDraw();seHeadsDraw();seChDraw();updScene();sePush();};
const seLenIn=()=>{const v=parseFloat(String($('selen').value).replace(',','.'));return isFinite(v)&&v>0?Math.max(1,Math.round(v*100)):null;};
$('selen').oninput=()=>{const cs=seLenIn(),w=SW&&SW.steps[seI];if(!w||cs==null)return;w.len=cs;seVer++;seStepsDraw();updScene();};
$('selen').onchange=()=>seStepsDraw();
$('selenall').onclick=()=>{const cs=seLenIn();if(cs==null||!SW)return;SW.steps.forEach(w=>w.len=cs);seVer++;seStepsDraw();updScene();};
$('seall').onclick=()=>{if(!SE)return;if(!seMo&&SE.heads[0])seMo=SE.heads[0].model;seSel=new Set(SE.heads.filter(h=>h.model===seMo).map(h=>h.id));seGridDraw();seHeadsDraw();seChDraw();};
$('senone').onclick=()=>{seSel=new Set();seGridDraw();seHeadsDraw();seChDraw();};
$('seaddb').onclick=seAddCh;
$('seq').oninput=renderScenes;
$('seback').onclick=async()=>{if(SE&&seDirty()&&!await ask('Leave this scene?','Your changes to <b>'+esc(SE.name)+'</b> are not saved yet. They will be lost.','Leave it'))return;await sePvStop(SEP?SEP.reo:false);SE=null;SW=null;if(!SL)loadScenes();else renderScenes();};
$('serefresh').onclick=async()=>{if(SE){if(seDirty()&&!await ask('Reload the scene?','Your changes that are not saved yet will be lost.','Reload'))return;seOpen(SE.file,true);}else loadScenes();};
$('seundo').onclick=()=>{if(!SE)return;seReset();seI=Math.min(seI,SW.steps.length-1);renderScene();sePush();};
$('sesave').onclick=()=>{if(!SE||!seDirty())return;const f=SE.file;
 saveTo('/api/scene/save',seBody(),'Saving the scene…',async()=>{SL=null;await seOpen(f,true);},'scene');};
// ---- earlier versions (backups kept by scene_edit.ps1, outside the show folder)
async function seBackups(){if(!SE){$('sebk').style.display='none';return;}const f=SE.file,r=await getJ('/api/scene/backups?f='+encodeURIComponent(f));if(!SE||SE.file!==f)return;
 const b=(r.ok&&r.backups)||[];$('sebk').style.display=b.length?'':'none';
 $('sebkl').innerHTML=b.map(x=>'<div class="sc"><div class="nm">'+esc(String(x.at).replace('T',' '))+'<small>'+esc(x.what)+'</small></div><div></div><div class="st"><button class="mini sebkr" data-bk="'+esc(x.id)+'"'+(sxOpen?' disabled':'')+'>Revert to this</button></div></div>').join('');
 $('sebkl').querySelectorAll('[data-bk]').forEach(e=>e.onclick=()=>seRevert(e.dataset.bk,false));}
async function seRevert(id,force){if(!SE)return;const f=SE.file;
 if(!force&&!await ask('Put this version back?','<b>'+esc(SE.name)+'</b> goes back to how it was before that save.'+(seDirty()?' Your changes that are not saved yet are lost.':'')+' The scene as it is now is kept as a backup too, so this can be undone.','Revert'))return;
 busy(true,'Reverting…');let r;try{r=await api('/api/scene/revert',{f,id,force:!!force});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);
 if(r.ok&&r.conflict){if(await ask('The scene changed since','<b>'+esc(SE.name)+'</b> was changed after that save (in ShowXpress or here). Revert anyway? The scene as it is now is kept as a backup.','Revert anyway'))return seRevert(id,true);return;}
 if(r.ok){SL=null;await seOpen(f,true);}showResult(r,'scenerev');}
// ---- on the lights: the step on screen, or Play (the whole scene, looping, with its fades) - straight from this page
// through the Helper's DMX output (same as the colour preview). The scene's own values go out as they are.
function seVals(){// [step][key] -> value, a channel missing from a step keeps the step before's value (like the SX Player)
 if(seTab&&seTab.ver===seVer)return seTab;const keys=new Set();SW.steps.forEach(w=>{for(const k in w.ch)keys.add(k);});
 const v=[],f=[];let prev={};SW.steps.forEach((w,i)=>{const a={},b={};for(const k of keys){if(w.ch[k]){a[k]=w.ch[k][0];b[k]=!!w.ch[k][1];}else a[k]=prev[k]||0;}v.push(a);f.push(b);prev=a;});
 seTab={ver:seVer,keys:[...keys],v,f};return seTab;}
function seFrame(){const t=seVals(),out={},n=SW.steps.length;if(!n)return out;let at=seI,frac=1;
 if(SEP.play){const ms=SW.steps.map(w=>Math.max(10,seCs(w)*10)),tot=ms.reduce((a,b)=>a+b,0);let p=(Date.now()-SEP.t0)%tot;at=0;while(p>=ms[at]){p-=ms[at];at++;}frac=p/ms[at];
  if(SEP.at!==at){SEP.at=at;seStepsDraw();}}
 const pv=t.v[(at-1+n)%n];
 for(const k of t.keys){const h=SE.byId[k.split('|')[0]];if(!h||!h.addr)continue;const ch=h.addr+(+k.split('|')[1]);if(ch<1||ch>8192)continue;
  let v=t.v[at][k];if(SEP.play&&t.f[at][k])v=pv[k]+(v-pv[k])*frac;out[ch]=Math.max(0,Math.min(255,Math.round(v)));}
 return out;}
function sePush(){if(!SEP||!SEP.on||!SE||SE.readonly)return;const fr=seFrame();
 for(const ch in SEP.sent){if(!(ch in fr)&&SEP.sent[ch]!==0){SEP.sent[ch]=0;SEP.pend.set(ch,'b:'+ch+':0');}}
 for(const ch in fr){if(SEP.sent[ch]!==fr[ch]){SEP.sent[ch]=fr[ch];SEP.pend.set(ch,'b:'+ch+':'+fr[ch]);}}
 seKick();}
function seKick(){if(!SEP||SEP.tm||SEP.fl)return;const d=30-(Date.now()-SEP.last);if(d>0)SEP.tm=setTimeout(()=>{if(SEP){SEP.tm=0;seFlush();}},d);else seFlush();}
async function seFlush(){if(!SEP||!SEP.on||SEP.fl)return;let l=((SEP.z?'z ':'')+[...SEP.pend.values()].join(' ')).trim();if(!l){if(!SEP.ka)return;l='k';}
 const me=SEP;SEP.z=false;SEP.ka=false;SEP.pend.clear();SEP.fl=true;SEP.last=Date.now();let r;try{r=await api('/api/live/out',{l});}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}
 if(SEP!==me||!SEP.on)return;SEP.fl=false;
 if(!r.ok){const reo=SEP.reo;await sePvStop(false);showResult({ok:false,error:(r.error||'The DMX output stopped.')+(reo?' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.':'')},'clprev');return;}
 if(SEP.pend.size)seKick();}
function sePvUi(){const on=!!SEP;$('sepv').classList.toggle('on',on);$('sepvsub').style.display=on?'none':'';$('sepvgo').style.display=on?'none':'';$('sepvgo').disabled=!SE||!!SE.readonly;$('sepvplay').style.display=on?'':'none';$('sepvstop').style.display=on?'':'none';$('sepvreow').style.display=on?'':'none';
 $('sepvplay').innerHTML=on&&SEP.play?'&#10074;&#10074; Hold this step':'&#9654; Play the scene';const t=$('sepvif');t.style.display=on?'':'none';
 if(on){t.className='tag '+(SEP.test?'red':'blue');t.textContent=SEP.test?'TEST - no real output':'Output: '+SEP.iface;}}
async function sePvGo(){if(SEP||MVP||LKP||LV||CP||!SE||SE.readonly)return;
 const c=await sxCloseLive('Close ShowXpress to see the scene on the lights?','Only one program can use the DMX interface, so ShowXpress closes while you preview. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.<br><br>It can open again when you stop.','Close and preview','Show on the lights','clprev');
 if(!c.go)return;
 const r=await lvStart('floor',true);
 if(!r.ok){try{await api('/api/live/stop',{});}catch(e){}if(c.reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'clprev');return;}
 SEP={on:true,sent:{},pend:new Map(),z:true,ka:false,fl:false,tm:0,last:0,play:false,t0:0,at:-1,reo:c.reo,test:!!r.test,iface:r.iface};
 SEP.kat=setInterval(()=>{if(SEP&&SEP.on&&Date.now()-SEP.last>1000){SEP.ka=true;seKick();}},1000);
 SEP.pt=setInterval(()=>{if(SEP&&SEP.play)sePush();},40);
 $('sepvreo').checked=c.reo;sePvUi();sePush();}
async function sePvStop(reo){if(!SEP)return;clearInterval(SEP.kat);clearInterval(SEP.pt);if(SEP.tm)clearTimeout(SEP.tm);SEP.on=false;SEP=null;sePvUi();if(SE&&!SE.readonly)seStepsDraw();
 busy(true,'Stopping the DMX output…');try{await api('/api/live/stop',{});}catch(e){}busy(false);if(reo)await sxLaunch();}
$('sepvgo').onclick=sePvGo;$('sepvstop').onclick=()=>sePvStop($('sepvreo').checked);
$('sepvplay').onclick=()=>{if(!SEP)return;SEP.play=!SEP.play;if(SEP.play)SEP.t0=Date.now();else{if(SEP.at>=0)seI=SEP.at;SEP.at=-1;seStepsDraw();seGridDraw();seHeadsDraw();seChDraw();}sePvUi();sePush();};
// ---------------- Movement Editor (move_edit.ps1, phase 3, user 2026-11-24): change a Generator movement (.gpj) - its
// shape, cycle, shift and transition, the other channels' graphs and the heads' aim and size - and see it on the lights.
// The page keeps a working copy (MW); Save sends only what differs from the file (move_edit.ps1 changes just those lines).
// The movement is worked out here the same way the SX Player plays it (player.ps1 LoadMove / Eval), so the drawing, the
// moving dots and the preview on the lights all match what ShowXpress does.
const MV_PT='Pan/Tilt/uPan/uTilt',MV_TEN=0.75,MVX=65535;
let ML=null,MLS=null,MO=null,MW=null,MW0='',mvS=0,mvP=-1,MVH=[],MVP=null,mvView=null,mvT0=Date.now(),mvRaf=0,mvDrag=null,mvLite=null,mvHold=false,mvHoldT=0;
const mvArr=v=>v==null?[]:Array.isArray(v)?v:[v];
const mvSecs=d=>String(Math.round(d)/10);   // 1/10 s -> "2.5"
const mvClamp=v=>Math.max(0,Math.min(MVX,Math.round(v)));
async function loadMoves(){$('mvcount').textContent='Loading…';ML=await getJ('/api/moves');renderMoves();}
function renderMoves(){const pick=!MO;$('mvpickw').style.display=pick?'':'none';$('mvw').style.display=pick?'none':'';$('mvback').style.display=pick?'none':'';
 if(pick){$('mvbk').style.display='none';$('mvtitle').textContent='Movement Editor';$('mvstate').style.display='none';}
 mvAnim(!pick);if(!pick){updMove();return;}
 if(!ML){$('mvlist').innerHTML='';updMove();return;}
 if(showErr('mverr',ML)){$('mvlist').innerHTML='';$('mvcount').textContent='';updMove();return;}
 const all=mvArr(ML.moves),q=$('mvq').value.trim().toLowerCase(),ls=all.filter(m=>!q||m.name.toLowerCase().includes(q)||mvArr(m.used).some(u=>u.toLowerCase().includes(q)));
 $('mvcount').textContent=all.length+' movements'+(q?' · '+ls.length+' found':'')+' · tap one to open it';
 $('mvlist').innerHTML=ls.map(m=>{const u=mvArr(m.used),on=mvArr(m.on);
  return `<div class="sc sesc" data-mf="${esc(m.file)}"><div class="nm">${esc(m.name)}${m.aim?'<span class="tag">Aim &middot; '+(m.aim==='room'?'Room':'Floor')+'</span>':''}${m.readonly?'<span class="tag amber">ShowXpress only</span>':''}<small>${u.length?esc(u.join(' · ')):'not on a live button'}</small></div>`+
   `<div class="sub" style="margin:0;font-size:12px">${on.length?'also plays '+esc(on.join(', ')):''}</div>`+
   `<div class="st">${m.moves?'<b>'+m.points+'</b> point'+(m.points===1?'':'s')+' &middot; <b>'+m.cycle+'</b> s &middot; ':''}<b>${m.heads}</b> head${m.heads===1?'':'s'}</div></div>`;}).join('')||'<p class="sub">No movement matches.</p>';
 $('mvlist').querySelectorAll('[data-mf]').forEach(e=>e.onclick=()=>mvOpen(e.dataset.mf));updMove();}
async function mvLeaveOk(t){return !(MO&&mvDirty())||await ask(t||'Leave this movement?','Your changes to <b>'+esc(MO.name)+'</b> are not saved yet. They will be lost.','Leave it');}
async function mvOpen(f,keep){
 if(!keep&&!await mvLeaveOk())return;
 if(!keep||(MO&&MO.file!==f))await mvPvStop(MVP?MVP.reo:false);
 busy(true,'Opening the movement…');const r=await getJ('/api/move?f='+encodeURIComponent(f));busy(false);
 if(!r.ok){showErr('mverr',r);return;}showErr('mverr',null);
 const was=keep&&MO&&MO.file===f?{s:MO.secs[mvS]&&MO.secs[mvS].name,p:mvP,v:mvView}:null;
 r.used=mvArr(r.used);r.heads=mvArr(r.heads);r.secs=mvArr(r.secs);
 r.heads.forEach(h=>{h.chans=mvArr(h.chans);h.has=mvArr(h.has);h.ix={};h.chans.forEach((c,i)=>{const k=String(c).trim().toLowerCase();if(k&&!(k in h.ix))h.ix[k]=i;});});
 r.secs.forEach(s=>{s.has=mvArr(s.has);s.pts=mvArr(s.pts).map(p=>[+p[0],+p[1]]);});
 MO=r;mvReset();
 mvS=0;const pt=MO.secs.findIndex(s=>s.name===MV_PT);if(pt>=0)mvS=pt;
 if(was){const i=MO.secs.findIndex(s=>s.name===was.s);if(i>=0)mvS=i;mvP=was.p;}else mvP=-1;
 mvView=was&&was.v?was.v:null;if(!mvView)mvFit();
 mvT0=Date.now();mvHold=false;renderMoves();renderMove();mvBackups();if(MVP)mvLiteLoad();}
function mvReset(){MW={secs:MO.secs.map(s=>({sel:+s.sel?1:0,tr:+s.tr,dur:+s.dur,shift:+s.shift,pts:s.pts.map(p=>p.slice())})),heads:MO.heads.map(h=>({op:+h.op,ot:+h.ot,zp:+h.zp,zt:+h.zt}))};MW0=JSON.stringify(MW);MVH=[];}
function mvSnap(){MVH.push(JSON.stringify(MW));if(MVH.length>200)MVH.shift();}
function mvStepBack(){if(!MVH.length)return;MW=JSON.parse(MVH.pop());const s=MW.secs[mvS];if(s&&mvP>=s.pts.length)mvP=-1;renderMove();}
function mvBody(){const b={move:MO.file,sha:MO.sha,secs:[],heads:[]};
 MO.secs.forEach((o,i)=>{const w=MW.secs[i],c={name:o.name};let any=false;
  if(w.sel!==(+o.sel?1:0)){c.sel=w.sel;any=true;}if(w.tr!==+o.tr){c.tr=w.tr;any=true;}if(w.dur!==+o.dur){c.dur=w.dur;any=true;}if(w.shift!==+o.shift){c.shift=w.shift;any=true;}
  if(!o.locked&&JSON.stringify(w.pts)!==JSON.stringify(o.pts)){c.pts=w.pts;any=true;}if(any)b.secs.push(c);});
 MO.heads.forEach((o,i)=>{const w=MW.heads[i],c={k:o.k};let any=false;['op','ot','zp','zt'].forEach(p=>{if(w[p]!==+o[p]){c[p]=w[p];any=true;}});if(any)b.heads.push(c);});
 return b;}
function mvDirty(){return !!(MO&&!MO.readonly&&MW&&JSON.stringify(MW)!==MW0);}
function mvSecName(n){return n===MV_PT?'Pan / Tilt':n;}
function mvWhat(){const b=mvBody(),w=[];
 b.secs.forEach(c=>{const p=[];if(c.pts)p.push(c.name===MV_PT?'shape':'graph');if(c.sel!==undefined)p.push(c.sel?'turned on':'turned off');if(c.tr!==undefined)p.push('transition');if(c.dur!==undefined)p.push('cycle');if(c.shift!==undefined)p.push('shift');
  w.push(mvSecName(c.name)+': '+p.join(', '));});
 if(b.heads.length)w.push(b.heads.length+' head'+(b.heads.length===1?'':'s')+' aimed or sized');
 return w.join(' · ');}
// ---- the movement, worked out like the SX Player does
function mvCard(p0,p1,p2,p3,t){const m1=MV_TEN*(p2-p0),m2=MV_TEN*(p3-p1),t2=t*t,t3=t2*t;return (2*t3-3*t2+1)*p1+(t3-2*t2+t)*m1+(-2*t3+3*t2)*p2+(t3-t2)*m2;}
function mvCR(p0,p1,p2,p3,t){return 0.5*(2*p1+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t);}
function mvPathAt(P,tr,u){const n=P.length;if(!n)return [0,0];const s=(u-Math.floor(u))*n,i=Math.min(n-1,Math.floor(s)),t=s-i;
 if(tr===0||n===1)return P[i];
 if(tr===1){const j=(i+1)%n;return [P[i][0]+(P[j][0]-P[i][0])*t,P[i][1]+(P[j][1]-P[i][1])*t];}
 const a=(i-1+n)%n,b=(i+1)%n,c=(i+2)%n;return [mvCard(P[a][0],P[i][0],P[b][0],P[c][0],t),mvCard(P[a][1],P[i][1],P[b][1],P[c][1],t)];}
function mvSorted(P){return P.map((p,i)=>[p[0],p[1],i]).sort((a,b)=>a[0]-b[0]||a[2]-b[2]);}
function mvValAt(S,tr,x){const n=S.length;if(!n)return 0;if(n===1||x<=S[0][0])return S[0][1];if(x>=S[n-1][0])return S[n-1][1];
 let j=0;while(j<n-2&&x>=S[j+1][0])j++;if(tr===0)return S[j][1];const w=S[j+1][0]-S[j][0],t=w>0?(x-S[j][0])/w:0;
 if(tr===1)return S[j][1]+(S[j+1][1]-S[j][1])*t;return mvCR(S[Math.max(0,j-1)][1],S[j][1],S[j+1][1],S[Math.min(n-1,j+2)][1],t);}
function mvCentre(P){let x0=1e9,x1=-1e9,y0=1e9,y1=-1e9;P.forEach(p=>{x0=Math.min(x0,p[0]);x1=Math.max(x1,p[0]);y0=Math.min(y0,p[1]);y1=Math.max(y1,p[1]);});return P.length?[(x0+x1)/2,(y0+y1)/2]:[MVX/2,MVX/2];}
function mvHeadXY(h,w,c,p){// a point of the shape as head h plays it: size around the shape's centre, then its aim, then Reverse
 const zp=Math.pow(1+w.zp/100,2),zt=Math.pow(1+w.zt/100,2);let x=c[0]+(p[0]-c[0])*zp+w.op,y=c[1]+(p[1]-c[1])*zt+w.ot;if(+h.rp)x=MVX-x;if(+h.rt)y=MVX-y;return [x,y];}
function mvNow(){return mvHold?mvHoldT:Date.now()-mvT0;}
function mvPhase(w,k,el){const dur=Math.max(100,w.dur*100);return el/dur-k*w.shift/100;}
// DMX values of the whole movement at el ms (channel -> value); only what's ticked plays, like in ShowXpress
function mvFrame(el){const out={},ptI=MO.secs.findIndex(s=>s.name===MV_PT),pt=ptI>=0?MW.secs[ptI]:null,c=pt?mvCentre(pt.pts):null;
 MO.heads.forEach((h,hi)=>{if(!h.addr)return;const hw=MW.heads[hi],put=(n,v)=>{const ix=h.ix[n];if(ix===undefined)return;const ch=h.addr+ix;if(ch>=1&&ch<=8192)out[ch]=Math.max(0,Math.min(255,v));};
  if(pt&&pt.sel&&pt.pts.length){const q=mvHeadXY(h,hw,c,mvPathAt(pt.pts,pt.tr,mvPhase(pt,h.k,el))),pv=mvClamp(q[0]),tv=mvClamp(q[1]);put('pan',pv>>8);put('upan',pv&255);put('tilt',tv>>8);put('utilt',tv&255);}
  MO.secs.forEach((o,i)=>{const w=MW.secs[i];if(i===ptI||!w.sel||!w.pts.length)return;const u=mvPhase(w,h.k,el);put(o.name.trim().toLowerCase(),mvClamp(mvValAt(mvSorted(w.pts),w.tr,(u-Math.floor(u))*MVX))>>8);});});
 return out;}
// ---- drawing
function mvCol(v){return getComputedStyle(document.body).getPropertyValue(v).trim()||'#888';}
function mvHue(i,n,a){return 'hsla('+Math.round(360*i/Math.max(1,n))+',85%,62%,'+a+')';}
function mvFit(){const i=MO?MO.secs.findIndex(s=>s.name===MV_PT):-1;if(i<0){mvView={x:0,y:0,s:MVX};return;}
 const w=MW.secs[i],c=mvCentre(w.pts),all=[],n=Math.max(48,w.pts.length*24);for(let k=0;k<n;k++){const p=mvPathAt(w.pts,w.tr,k/n);all.push(p);MO.heads.forEach((h,hi)=>all.push(mvHeadXY(h,MW.heads[hi],c,p)));}
 let x0=1e9,x1=-1e9,y0=1e9,y1=-1e9;all.forEach(p=>{x0=Math.min(x0,p[0]);x1=Math.max(x1,p[0]);y0=Math.min(y0,p[1]);y1=Math.max(y1,p[1]);});
 if(!all.length){mvView={x:0,y:0,s:MVX};return;}
 const s=Math.min(MVX,Math.max(6000,(x1-x0)*1.3,(y1-y0)*1.3));mvView={x:Math.max(0,Math.min(MVX-s,(x0+x1)/2-s/2)),y:Math.max(0,Math.min(MVX-s,(y0+y1)/2-s/2)),s};}
function mvCanvas(){const cv=$('mvcv'),r=cv.getBoundingClientRect(),d=window.devicePixelRatio||1,W=Math.max(10,Math.round(r.width)),H=cv.dataset.kind==='pt'?W:220;
 if(cv.width!==W*d||cv.height!==H*d){cv.width=W*d;cv.height=H*d;cv.style.height=H+'px';}const g=cv.getContext('2d');g.setTransform(d,0,0,d,0,0);return {cv,g,W,H};}
function mvToPx(p,W,H){const v=mvView;return [(p[0]-v.x)/v.s*W,(p[1]-v.y)/v.s*H];}
function mvFromPx(x,y,W,H){const v=mvView;return [v.x+x/W*v.s,v.y+y/H*v.s];}
function mvGx(x,W){return 30+x/MVX*(W-40);}function mvGy(y,H){return H-18-y/MVX*(H-30);}
function mvGxInv(px,W){return (px-30)/(W-40)*MVX;}function mvGyInv(py,H){return (H-18-py)/(H-30)*MVX;}
function mvDraw(){if(!MO||MO.readonly)return;const s=MO.secs[mvS],w=MW.secs[mvS];if(!s)return;const {g,W,H}=mvCanvas(),el=mvNow();
 const amb=mvCol('--acc'),line=mvCol('--line'),dim=mvCol('--dim'),blue=mvCol('--blue');g.clearRect(0,0,W,H);g.lineWidth=1;g.font='11px system-ui,sans-serif';
 if(s.name===MV_PT){const v=mvView,c=mvCentre(w.pts);
  // grid every 1/8 of the range that's in view
  g.strokeStyle=line;for(let k=0;k<=8;k++){const a=k*MVX/8,x=(a-v.x)/v.s*W,y=(a-v.y)/v.s*H;if(x>=0&&x<=W){g.beginPath();g.moveTo(x,0);g.lineTo(x,H);g.stroke();}if(y>=0&&y<=H){g.beginPath();g.moveTo(0,y);g.lineTo(W,y);g.stroke();}}
  g.fillStyle=dim;g.fillText('pan →',W-44,H-6);g.save();g.translate(12,46);g.rotate(Math.PI/2);g.fillText('tilt →',0,0);g.restore();
  const n=MO.heads.length,steps=Math.max(48,w.pts.length*24);
  // each head's own path (its aim and size), faint
  MO.heads.forEach((h,hi)=>{g.strokeStyle=mvHue(hi,n,.35);g.beginPath();for(let k=0;k<=steps;k++){const q=mvToPx(mvHeadXY(h,MW.heads[hi],c,mvPathAt(w.pts,w.tr,k/steps)),W,H);k?g.lineTo(q[0],q[1]):g.moveTo(q[0],q[1]);}g.stroke();});
  // the shape itself
  g.strokeStyle=amb;g.lineWidth=2.2;g.beginPath();for(let k=0;k<=steps;k++){const q=mvToPx(mvPathAt(w.pts,w.tr,k/steps),W,H);k?g.lineTo(q[0],q[1]):g.moveTo(q[0],q[1]);}g.stroke();g.lineWidth=1;
  w.pts.forEach((p,i)=>{const q=mvToPx(p,W,H);g.beginPath();g.arc(q[0],q[1],i===mvP?8:6,0,7);g.fillStyle=i===mvP?blue:amb;g.fill();g.fillStyle='#000';g.font='bold 10px system-ui,sans-serif';g.textAlign='center';g.fillText(i+1,q[0],q[1]+3.5);g.textAlign='left';});
  // where each head is now
  if(w.pts.length)MO.heads.forEach((h,hi)=>{const q=mvToPx(mvHeadXY(h,MW.heads[hi],c,mvPathAt(w.pts,w.tr,mvPhase(w,h.k,el))),W,H);g.beginPath();g.arc(q[0],q[1],5,0,7);g.fillStyle=mvHue(hi,n,1);g.fill();if(n<=8){g.fillStyle=dim;g.font='10px system-ui,sans-serif';g.fillText(h.label||('#'+(hi+1)),q[0]+7,q[1]-6);}});
 }else{// a value graph: x = where in the cycle, y = value
  g.strokeStyle=line;for(let k=0;k<=4;k++){const y=mvGy(k*MVX/4,H);g.beginPath();g.moveTo(30,y);g.lineTo(W-10,y);g.stroke();g.fillStyle=dim;g.fillText(String(Math.round(k*255/4)),2,y+4);}
  for(let k=0;k<=4;k++){const x=mvGx(k*MVX/4,W);g.beginPath();g.moveTo(x,12);g.lineTo(x,H-18);g.stroke();g.fillStyle=dim;g.textAlign=k?k===4?'right':'center':'left';g.fillText(k*25+'%',x,H-4);g.textAlign='left';}
  const S=mvSorted(w.pts);if(S.length){g.strokeStyle=amb;g.lineWidth=2.2;g.beginPath();for(let k=0;k<=240;k++){const x=k/240*MVX,px=mvGx(x,W),py=mvGy(mvValAt(S,w.tr,x),H);k?g.lineTo(px,py):g.moveTo(px,py);}g.stroke();g.lineWidth=1;}
  w.pts.forEach((p,i)=>{const px=mvGx(p[0],W),py=mvGy(p[1],H);g.beginPath();g.arc(px,py,i===mvP?8:6,0,7);g.fillStyle=i===mvP?blue:amb;g.fill();});
  const n=MO.heads.length;MO.heads.forEach((h,hi)=>{const u=mvPhase(w,h.k,el),x=mvGx((u-Math.floor(u))*MVX,W);g.strokeStyle=mvHue(hi,n,hi?.35:.9);g.beginPath();g.moveTo(x,12);g.lineTo(x,H-18);g.stroke();});}}
function mvAnim(on){if(on&&!mvRaf){const f=()=>{mvRaf=0;if(!MO||lastTab!=='move')return;mvDraw();mvRaf=requestAnimationFrame(f);};mvRaf=requestAnimationFrame(f);}if(!on&&mvRaf){cancelAnimationFrame(mvRaf);mvRaf=0;}}
// ---- the page
function renderMove(){if(!MO)return;const ro=MO.readonly;$('mvtitle').textContent=MO.name;
 const np=MO.heads.filter(h=>!h.addr).length;
 $('mvinfo').innerHTML=(MO.used.length?'On '+MO.used.map(esc).join(' &middot; '):'Not on a live button')+' &middot; '+MO.heads.length+' head'+(MO.heads.length===1?'':'s');
 const w=[];if(ro)w.push('SX Studio doesn&rsquo;t change this movement: '+esc(ro)+'. ShowXpress still opens and edits it as before.');
 $('mvnote').style.display=!ro&&MO.aim?'':'none';if(!ro&&MO.aim)$('mvnote').innerHTML=('<b>Aim Movers looks after this movement</b> ('+(MO.aim==='room'?'Room':'Dance Floor')+'): it sets where each head points and how big the shape is, so those are changed in the Aim Movers tab. The shape you draw here is kept as you draw it the next time Aim Movers saves.');
 if(!ro&&np)w.push(np+' head'+(np===1?' isn&rsquo;t':'s aren&rsquo;t')+' patched in the show (no DMX address), so '+(np===1?'it doesn&rsquo;t':'they don&rsquo;t')+' show on the lights.');
 const wb=$('mvwarn');wb.style.display=w.length?'block':'none';wb.innerHTML=w.join('<br><br>');
 $('mvedit').style.display=ro?'none':'';if(ro){updMove();return;}
 mvSecsDraw();mvSideDraw();mvHeadsDraw();updMove();mvDraw();}
function mvSecsDraw(){const o0=JSON.parse(MW0).secs;$('mvsecs').innerHTML=MO.secs.map((o,i)=>{const w=MW.secs[i],b=JSON.stringify(w)!==JSON.stringify(o0[i]);
  return `<div class="sst${i===mvS?' on':''}${b?' chg':''}${w.sel?'':' off'}" data-ms="${i}">${esc(mvSecName(o.name))}<small>${w.sel?'plays':'off'}${w.pts.length?' &middot; '+w.pts.length+' pt':''}</small></div>`;}).join('');
 $('mvsecs').querySelectorAll('[data-ms]').forEach(e=>e.onclick=()=>{mvS=+e.dataset.ms;mvP=-1;$('mvcv').dataset.kind=MO.secs[mvS].name===MV_PT?'pt':'val';renderMove();});
 $('mvcv').dataset.kind=MO.secs[mvS]&&MO.secs[mvS].name===MV_PT?'pt':'val';}
function mvSideDraw(){const o=MO.secs[mvS],w=MW.secs[mvS],pt=o.name===MV_PT,lk=!!o.locked;
 $('mvsech').textContent=mvSecName(o.name);
 $('mvsel').checked=!!w.sel;$('mvsel').disabled=!o.has.includes('Selected');$('mvtr').value=String(w.tr);$('mvtr').disabled=!o.has.includes('Transition');
 const act=document.activeElement;if(act!==$('mvdur'))$('mvdur').value=mvSecs(w.dur);if(act!==$('mvshift'))$('mvshift').value=String(w.shift);
 $('mvdur').disabled=!o.has.includes('Duration');$('mvshift').disabled=!o.has.includes('Shift');
 $('mvlock').style.display=lk?'block':'none';$('mvcvw').style.display=lk?'none':'';$('mvtools').style.display=lk||!pt?'none':'';$('mvfit').style.display=pt?'':'none';
 $('mvcvhint').innerHTML=pt?'Drag a point to move it &middot; drag empty space to move the whole shape &middot; double-click to add a point &middot; Delete removes the selected one':'Drag a point &middot; double-click to add one &middot; Delete removes the selected one. Left to right = once round the cycle, bottom to top = value 0&ndash;255';
 const p=mvP>=0?w.pts[mvP]:null;$('mvpt').style.display=p&&!lk?'':'none';
 if(p){$('mvptn').textContent='Point '+(mvP+1);$('mvpxl').textContent=pt?'Pan':'At %';$('mvpyl').textContent=pt?'Tilt':'Value';
  if(act!==$('mvpx'))$('mvpx').value=pt?p[0]:(p[0]/MVX*100).toFixed(1).replace(/\.0$/,'');if(act!==$('mvpy'))$('mvpy').value=pt?p[1]:(p[1]>>8);
  $('mvpx').max=pt?MVX:100;$('mvpy').max=pt?MVX:255;$('mvpdel').disabled=w.pts.length<2;}}
function mvHeadsDraw(){const own=!!MO.aim,o0=JSON.parse(MW0).heads;
 $('mvhcnt').textContent=own?'aim and size are set by Aim Movers':'aim = where it points, as 16-bit pan / tilt steps · zoom = size of its shape';
 $('mvhl').innerHTML='<table><tr><th>Head</th><th>DMX</th><th>Aim pan</th><th>Aim tilt</th><th>Zoom pan</th><th>Zoom tilt</th><th></th></tr>'+MO.heads.map((h,i)=>{const w=MW.heads[i];
  const f=(p,key,mn,mx)=>!h.has.includes(key)?'<span class="sub">&mdash;</span>':own?String(w[p]):`<input class="num${w[p]!==o0[i][p]?' chg':''}" type="number" data-mh="${i}" data-mp="${p}" min="${mn}" max="${mx}" step="1" value="${w[p]}">`;
  const tg=(+h.rp?'<span class="tag">reverse pan</span>':'')+(+h.rt?'<span class="tag">reverse tilt</span>':'');
  return `<tr><td><b>${esc(h.label||h.name)}</b><small class="sub" style="display:block;margin:0">${esc(h.model||'')}</small></td><td>${h.addr||'<span class="tag amber">not patched</span>'}</td><td>${f('op','OffsetPan',-65535,65535)}</td><td>${f('ot','OffsetTilt',-65535,65535)}</td><td>${f('zp','ZoomPan',-99,900)}</td><td>${f('zt','ZoomTilt',-99,900)}</td><td>${tg}</td></tr>`;}).join('')+'</table>';
 $('mvhl').querySelectorAll('[data-mh]').forEach(e=>e.onchange=()=>{const i=+e.dataset.mh,p=e.dataset.mp,lim=p[0]==='o'?[-65535,65535]:[-99,900];let v=Math.round(+e.value);if(!isFinite(v))v=0;v=Math.max(lim[0],Math.min(lim[1],v));
  mvSnap();MW.heads[i][p]=v;renderMove();});}
function updMove(){const ok=!!(MO&&!MO.readonly),d=mvDirty();
 $('mvsave').disabled=!ok||!d;$('mvundo').disabled=!ok||!d;$('mvstep').disabled=!ok||!MVH.length;
 if(MO)stateTag('mvstate',d);
 $('mvhint').innerHTML=!MO?'Open a movement to change it.':MO.readonly?'This movement can only be changed in ShowXpress.':sxHint('save')??(d?esc(mvWhat())+'. Only that is changed in the file.':'Matches the show.');
 mvPush();}
// ---- editing
function mvSet(fn){mvSnap();fn(MW.secs[mvS]);renderMove();}
function mvHit(px,py){const {W,H}=mvCanvas(),w=MW.secs[mvS],pt=MO.secs[mvS].name===MV_PT;let best=-1,bd=13*13;
 w.pts.forEach((p,i)=>{const q=pt?mvToPx(p,W,H):[mvGx(p[0],W),mvGy(p[1],H)],d=(q[0]-px)**2+(q[1]-py)**2;if(d<=bd){bd=d;best=i;}});return best;}
function mvEvXY(e){const r=$('mvcv').getBoundingClientRect();return [e.clientX-r.left,e.clientY-r.top];}
function mvDown(e){if(!MO||MO.readonly||MO.secs[mvS].locked||e.button>0)return;const [x,y]=mvEvXY(e),i=mvHit(x,y),w=MW.secs[mvS];
 $('mvcv').setPointerCapture(e.pointerId);mvDrag={i,x,y,moved:false,start:w.pts.map(p=>p.slice()),snap:JSON.stringify(MW)};if(i>=0){mvP=i;mvSideDraw();}e.preventDefault();}
function mvMove(e){if(!mvDrag)return;const [x,y]=mvEvXY(e),{W,H}=mvCanvas(),w=MW.secs[mvS],pt=MO.secs[mvS].name===MV_PT;
 if(!mvDrag.moved&&Math.abs(x-mvDrag.x)+Math.abs(y-mvDrag.y)<3)return;mvDrag.moved=true;
 if(mvDrag.i>=0){const p=w.pts[mvDrag.i];if(pt){const q=mvFromPx(x,y,W,H);p[0]=mvClamp(q[0]);p[1]=mvClamp(q[1]);}else{p[0]=mvClamp(mvGxInv(x,W));p[1]=mvClamp(Math.round(mvGyInv(y,H)/256)*256);}}
 else if(pt){const a=mvFromPx(mvDrag.x,mvDrag.y,W,H),b=mvFromPx(x,y,W,H),s=mvDrag.start;let dx=b[0]-a[0],dy=b[1]-a[1];
  const x0=Math.min(...s.map(p=>p[0])),x1=Math.max(...s.map(p=>p[0])),y0=Math.min(...s.map(p=>p[1])),y1=Math.max(...s.map(p=>p[1]));
  dx=Math.max(-x0,Math.min(MVX-x1,dx));dy=Math.max(-y0,Math.min(MVX-y1,dy));w.pts=s.map(p=>[mvClamp(p[0]+dx),mvClamp(p[1]+dy)]);}
 mvSideDraw();mvDraw();mvPush();}
function mvUp(){if(!mvDrag)return;const d=mvDrag;mvDrag=null;if(d.moved){MVH.push(d.snap);if(MVH.length>200)MVH.shift();renderMove();}else if(d.i<0&&mvP>=0){mvP=-1;mvSideDraw();mvDraw();}}
function mvDbl(e){if(!MO||MO.readonly||MO.secs[mvS].locked)return;const [x,y]=mvEvXY(e),{W,H}=mvCanvas(),w=MW.secs[mvS],pt=MO.secs[mvS].name===MV_PT;if(mvHit(x,y)>=0||w.pts.length>=256)return;
 mvSnap();if(pt){const q=mvFromPx(x,y,W,H),np=[mvClamp(q[0]),mvClamp(q[1])];let at=w.pts.length,bd=1e18;const n=w.pts.length;
  // into the side of the shape nearest to where you clicked
  for(let i=0;i<n;i++){const a=w.pts[i],b=w.pts[(i+1)%n],dx=b[0]-a[0],dy=b[1]-a[1],l=dx*dx+dy*dy,t=l?Math.max(0,Math.min(1,((np[0]-a[0])*dx+(np[1]-a[1])*dy)/l)):0,d=(a[0]+t*dx-np[0])**2+(a[1]+t*dy-np[1])**2;if(d<bd){bd=d;at=i+1;}}
  w.pts.splice(at,0,np);mvP=at;}
 else{w.pts.push([mvClamp(mvGxInv(x,W)),mvClamp(Math.round(mvGyInv(y,H)/256)*256)]);mvP=w.pts.length-1;}
 renderMove();}
function mvDelPt(){const w=MW.secs[mvS];if(mvP<0||w.pts.length<2||MO.secs[mvS].locked)return;mvSnap();w.pts.splice(mvP,1);mvP=Math.min(mvP,w.pts.length-1);renderMove();}
function mvShape(fn){const w=MW.secs[mvS];if(!w.pts.length)return;mvSnap();const c=mvCentre(w.pts);w.pts=fn(w.pts,c).map(p=>[mvClamp(p[0]),mvClamp(p[1])]);renderMove();}
// ---- on the lights: the movement as it is on this page, straight to the DMX interface (like the Scene Editor's
// preview). A movement on its own only moves the heads - "Light it with" adds a scene underneath (its first step).
function mvPush(){if(!MVP||!MVP.on||!MO||MO.readonly)return;const fr=Object.assign({},mvLite&&mvLite.f===$('mvlite').value?mvLite.v:{},mvFrame(mvNow()));
 for(const ch in MVP.sent){if(!(ch in fr)&&MVP.sent[ch]!==0){MVP.sent[ch]=0;MVP.pend.set(ch,'b:'+ch+':0');}}
 for(const ch in fr){if(MVP.sent[ch]!==fr[ch]){MVP.sent[ch]=fr[ch];MVP.pend.set(ch,'b:'+ch+':'+fr[ch]);}}
 mvKick();}
function mvKick(){if(!MVP||MVP.tm||MVP.fl)return;const d=40-(Date.now()-MVP.last);if(d>0)MVP.tm=setTimeout(()=>{if(MVP){MVP.tm=0;mvFlush();}},d);else mvFlush();}
async function mvFlush(){if(!MVP||!MVP.on||MVP.fl)return;let l=((MVP.z?'z ':'')+[...MVP.pend.values()].join(' ')).trim();if(!l){if(!MVP.ka)return;l='k';}
 const me=MVP;MVP.z=false;MVP.ka=false;MVP.pend.clear();MVP.fl=true;MVP.last=Date.now();let r;try{r=await api('/api/live/out',{l});}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}
 if(MVP!==me||!MVP.on)return;MVP.fl=false;
 if(!r.ok){const reo=MVP.reo;await mvPvStop(false);showResult({ok:false,error:(r.error||'The DMX output stopped.')+(reo?' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.':'')},'clprev');return;}
 if(MVP.pend.size)mvKick();}
function mvPvUi(){const on=!!MVP;$('mvpv').classList.toggle('on',on);$('mvpvsub').style.display=on?'none':'';$('mvpvgo').style.display=on?'none':'';$('mvpvgo').disabled=!MO||!!MO.readonly;$('mvpvstop').style.display=on?'':'none';$('mvpvreow').style.display=on?'':'none';
 const t=$('mvpvif');t.style.display=on?'':'none';if(on){t.className='tag '+(MVP.test?'red':'blue');t.textContent=MVP.test?'TEST - no real output':'Output: '+MVP.iface;}}
async function mvPvGo(){if(MVP||SEP||LKP||LV||CP||!MO||MO.readonly)return;
 const c=await sxCloseLive('Close ShowXpress to see the movement on the lights?','Only one program can use the DMX interface, so ShowXpress closes while you preview. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.<br><br>It can open again when you stop.','Close and preview','Show on the lights','clprev');
 if(!c.go)return;
 const r=await lvStart('floor',true);
 if(!r.ok){try{await api('/api/live/stop',{});}catch(e){}if(c.reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'clprev');return;}
 MVP={on:true,sent:{},pend:new Map(),z:true,ka:false,fl:false,tm:0,last:0,reo:c.reo,test:!!r.test,iface:r.iface};
 MVP.kat=setInterval(()=>{if(MVP&&MVP.on&&Date.now()-MVP.last>1000){MVP.ka=true;mvKick();}},1000);
 MVP.pt=setInterval(()=>{if(MVP)mvPush();},40);
 $('mvpvreo').checked=c.reo;mvPvUi();mvLiteLoad();mvPush();}
async function mvPvStop(reo){if(!MVP)return;clearInterval(MVP.kat);clearInterval(MVP.pt);if(MVP.tm)clearTimeout(MVP.tm);MVP.on=false;MVP=null;mvPvUi();
 busy(true,'Stopping the DMX output…');try{await api('/api/live/stop',{});}catch(e){}busy(false);if(reo)await sxLaunch();}
async function mvLiteList(){if(!MLS)MLS=await getJ('/api/scenes');const sel=$('mvlite'),cur=sel.value||(()=>{try{return localStorage.getItem('sxh_mvlite')||'';}catch(e){return '';}})();
 sel.innerHTML='<option value="">nothing (only moves the heads)</option>'+(MLS&&MLS.ok?mvArr(MLS.scenes):[]).map(s=>`<option value="${esc(s.file)}">${esc(s.name)}</option>`).join('');
 sel.value=[...sel.options].some(o=>o.value===cur)?cur:'';}
async function mvLiteLoad(){const f=$('mvlite').value;try{localStorage.setItem('sxh_mvlite',f);}catch(e){}
 if(!f){mvLite=null;mvPush();return;}if(mvLite&&mvLite.f===f)return;
 const r=await getJ('/api/scene?f='+encodeURIComponent(f));if(!r.ok||$('mvlite').value!==f){if(!r.ok)showErr('mverr',r);return;}
 const by={};mvArr(r.heads).forEach(h=>by[h.id]=h);const v={},st=mvArr(r.steps)[0];
 if(st)mvArr(st.fx).forEach(x=>{const h=by[x.id];if(!h||!h.addr)return;mvArr(x.ch).forEach(c=>{const ch=h.addr+(+c[0]);if(ch>=1&&ch<=8192)v[ch]=Math.max(0,Math.min(255,+c[2]||0));});});
 mvLite={f,v};mvPush();}
// ---- earlier versions (backups kept by move_edit.ps1, outside the show folder)
async function mvBackups(){if(!MO){$('mvbk').style.display='none';return;}const f=MO.file,r=await getJ('/api/move/backups?f='+encodeURIComponent(f));if(!MO||MO.file!==f)return;
 const b=(r.ok&&mvArr(r.backups))||[];$('mvbk').style.display=b.length?'':'none';
 $('mvbkl').innerHTML=b.map(x=>'<div class="sc"><div class="nm">'+esc(String(x.at).replace('T',' '))+'<small>'+esc(x.what)+'</small></div><div></div><div class="st"><button class="mini" data-bk="'+esc(x.id)+'"'+(sxOpen?' disabled':'')+'>Revert to this</button></div></div>').join('');
 $('mvbkl').querySelectorAll('[data-bk]').forEach(e=>e.onclick=()=>mvRevert(e.dataset.bk,false));}
async function mvRevert(id,force){if(!MO)return;const f=MO.file;
 if(!force&&!await ask('Put this version back?','<b>'+esc(MO.name)+'</b> goes back to how it was before that save.'+(mvDirty()?' Your changes that are not saved yet are lost.':'')+' The movement as it is now is kept as a backup too, so this can be undone.','Revert'))return;
 busy(true,'Reverting…');let r;try{r=await api('/api/move/revert',{f,id,force:!!force});}catch(e){r={ok:false,error:'Lost connection.'};}busy(false);
 if(r.ok&&r.conflict){if(await ask('The movement changed since','<b>'+esc(MO.name)+'</b> was changed after that save (in ShowXpress or here). Revert anyway? The movement as it is now is kept as a backup.','Revert anyway'))return mvRevert(id,true);return;}
 if(r.ok){ML=null;await mvOpen(f,true);}showResult(r,'moverev');}
// ---- wiring
$('mvq').oninput=renderMoves;
$('mvback').onclick=async()=>{if(!await mvLeaveOk())return;await mvPvStop(MVP?MVP.reo:false);MO=null;MW=null;if(!ML)loadMoves();else renderMoves();};
$('mvrefresh').onclick=async()=>{if(MO){if(mvDirty()&&!await ask('Reload the movement?','Your changes that are not saved yet will be lost.','Reload'))return;mvOpen(MO.file,true);}else loadMoves();};
$('mvundo').onclick=()=>{if(!MO)return;mvReset();mvP=-1;renderMove();};
$('mvstep').onclick=mvStepBack;
$('mvsave').onclick=()=>{if(!MO||!mvDirty())return;const f=MO.file;saveTo('/api/move/save',mvBody(),'Saving the movement…',async()=>{ML=null;await mvOpen(f,true);},'move');};
$('mvsel').onchange=()=>mvSet(w=>w.sel=$('mvsel').checked?1:0);
$('mvtr').onchange=()=>mvSet(w=>w.tr=+$('mvtr').value);
$('mvdur').onchange=()=>{let v=Math.round(parseFloat($('mvdur').value)*10);if(!isFinite(v))v=MW.secs[mvS].dur;v=Math.max(1,Math.min(360000,v));mvSet(w=>w.dur=v);$('mvdur').value=mvSecs(v);};
$('mvshift').onchange=()=>{let v=parseFloat($('mvshift').value);if(!isFinite(v))v=MW.secs[mvS].shift;v=Math.round(Math.max(0,Math.min(100,v))*100)/100;mvSet(w=>w.shift=v);$('mvshift').value=String(v);};
$('mvpx').onchange=$('mvpy').onchange=()=>{const w=MW.secs[mvS],p=w.pts[mvP];if(!p)return;const pt=MO.secs[mvS].name===MV_PT;let x=parseFloat($('mvpx').value),y=parseFloat($('mvpy').value);
 if(!isFinite(x))x=pt?p[0]:p[0]/MVX*100;if(!isFinite(y))y=pt?p[1]:p[1]>>8;mvSnap();
 if(pt){p[0]=mvClamp(x);p[1]=mvClamp(y);}else{p[0]=mvClamp(Math.max(0,Math.min(100,x))/100*MVX);p[1]=mvClamp(Math.max(0,Math.min(255,Math.round(y)))*256);}renderMove();};
$('mvpdel').onclick=mvDelPt;
$('mvbig').onclick=()=>mvShape((P,c)=>P.map(p=>[c[0]+(p[0]-c[0])*1.1,c[1]+(p[1]-c[1])*1.1]));
$('mvsmall').onclick=()=>mvShape((P,c)=>P.map(p=>[c[0]+(p[0]-c[0])/1.1,c[1]+(p[1]-c[1])/1.1]));
$('mvflipx').onclick=()=>mvShape((P,c)=>P.map(p=>[2*c[0]-p[0],p[1]]));
$('mvflipy').onclick=()=>mvShape((P,c)=>P.map(p=>[p[0],2*c[1]-p[1]]));
$('mvrev').onclick=()=>{mvShape(P=>[P[0]].concat(P.slice(1).reverse()));mvP=-1;mvSideDraw();};
$('mvcentre').onclick=()=>mvShape((P,c)=>P.map(p=>[p[0]+MVX/2-c[0],p[1]+MVX/2-c[1]]));
$('mvfit').onclick=()=>{mvFit();mvDraw();};$('mvwhole').onclick=()=>{mvView={x:0,y:0,s:MVX};mvDraw();};
$('mvhold').onclick=()=>{if(mvHold){mvT0=Date.now()-mvHoldT;mvHold=false;}else{mvHoldT=Date.now()-mvT0;mvHold=true;}$('mvhold').innerHTML=mvHold?'&#9654; Play':'&#10074;&#10074; Pause';};
$('mvsync').onclick=()=>{mvT0=Date.now();mvHoldT=0;};
const mvc=$('mvcv');mvc.addEventListener('pointerdown',mvDown);mvc.addEventListener('pointermove',mvMove);mvc.addEventListener('pointerup',mvUp);mvc.addEventListener('pointercancel',mvUp);mvc.addEventListener('dblclick',mvDbl);
document.addEventListener('keydown',e=>{if(lastTab!=='move'||!MO||MO.readonly)return;const t=e.target&&e.target.tagName;if(t==='INPUT'||t==='SELECT'||t==='TEXTAREA'||$('modal').style.display==='flex')return;
 if((e.key==='Delete'||e.key==='Backspace')&&mvP>=0){e.preventDefault();mvDelPt();}
 else if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='z'){e.preventDefault();mvStepBack();}});
window.addEventListener('resize',()=>{if(MO&&lastTab==='move')mvDraw();});
$('mvpvgo').onclick=mvPvGo;$('mvpvstop').onclick=()=>mvPvStop($('mvpvreo').checked);
$('mvlite').onchange=mvLiteLoad;

// ---------------- One-click Looks (looks.ps1, phase 4, user 2026-11-24): a NEW scene from a template - contrast pairs, a
// colour chase, a strobe or a prism fan - for the heads picked. The steps are worked out here, so the look can be seen on
// the lights before it is made; looks.ps1 checks them and writes the new file. No scene the show has and no live button
// is ever changed (the live board stays ShowXpress's own: the user puts the look on a button there, or on one of the SX
// Player's own pages). Each look sets only what it is about (a colour look: colour, dimmer, shutter; the prism fan: the
// beam, no colour), so looks can be played together, like the user's own CONTRAST ALL + PRISM FAN.
let LK=null,lkT='contrast',LKP=null,lkCur=null,lkMade=null,lkNameSet=false,lkRaf=0,lkT0=Date.now(),lkDots={},lkLastAt=-1,lkLastL=null;
const LK_COLS=[['White','#ffffff'],['Red','#ff0000'],['Orange','#ff7a00'],['Amber','#ffb000'],['Yellow','#ffe600'],['Green','#00e040'],['Cyan','#00e5ff'],['Blue','#0030ff'],['Purple','#8a2be2'],['Magenta','#ff00c8'],['Pink','#ff6fae'],['UV','#6a00ff']];
// colour-wheel slot names (from the fixtures' own definitions) -> about how they look
const LK_SLOT={white:'#ffffff',red:'#ff0000',orange:'#ff7a00',yellow:'#ffe600',dark_yellow:'#d4a000',amber:'#ffb000',green:'#00e040',light_green:'#80ff80',pastel_sky_blue:'#80d0ff',sky_blue:'#80d0ff',light_blue:'#80d0ff',cyan:'#00e5ff',blue:'#0030ff',dark_blue:'#0010a0',purple:'#8a2be2',magenta:'#ff00c8',pink:'#ff6fae',lavender:'#c0a0ff',uv:'#6a00ff',cto:'#ffb070',natural_white:'#fff0dc',cold_white:'#e6f2ff',warm_white:'#ffe0b0'};
const LK_DEF={contrast:{pairs:[['Red','Blue'],['Green','Magenta'],['Yellow','Purple'],['Cyan','Pink']],split:'alt',swap:true,hold:1,fade:false},
 chase:{cols:['Red','Orange','Yellow','Green','Cyan','Blue','Purple','Magenta'],pp:true,spread:false,hold:0.5,fade:false},
 strobe:{col:'White',mode:'beat',on:0.05,off:0.05},
 prism:{p:[{m:'l',s:77},{m:'l',s:29}],zoom:80,focus:128}};
let LKO=(()=>{let o={};try{o=JSON.parse(localStorage.getItem('sxh_looks')||'{}')||{};}catch(e){}const r={on:o.on||{}};
 for(const k in LK_DEF)r[k]=Object.assign(JSON.parse(JSON.stringify(LK_DEF[k])),o[k]||{});return r;})();
function lkKeep(){try{localStorage.setItem('sxh_looks',JSON.stringify(LKO));}catch(e){}}
const lkHex=h=>[1,3,5].map(i=>parseInt(h.slice(i,i+2),16));
const lkColHex=n=>(LK_COLS.find(c=>c[0]===n)||LK_COLS[0])[1];
const lkByte=v=>Math.max(0,Math.min(255,Math.round(+v||0)));
const lkLabel=m=>String(m).replace(/\s*\(\d+\s*ch\)\s*$/i,'').replace(/_?CH\d+$/i,'').replace(/_/g,' ').trim()||String(m);
const lkSec=t=>(Math.round(t*100)/100)+' s';
async function loadLooks(){$('lkerr').style.display='none';const r=await getJ('/api/looks');
 if(!r||!r.ok){LK=null;$('lkw').style.display='none';showErr('lkerr',r||{ok:false,error:'Could not read the show.'});return;}
 r.byId={};const gs=[];(r.heads||[]).forEach(h=>{r.byId[h.id]=h;let g=gs.find(x=>x.model===h.model);if(!g)gs.push(g={model:h.model,label:lkLabel(h.model),c:r.models[h.model],heads:[]});h.gi=g.heads.length;g.heads.push(h);});
 r.groups=gs;r.scenes=r.scenes||[];r.skipped=r.skipped||[];LK=r;$('lkw').style.display='';lkTplDraw();lkOptsDraw();lkUpdate();lkDoneDraw();}
// which lights a template can use, and which it starts with (the user's beat strobe left the Ovation out)
const lkHasRgb=c=>['red','green','blue','white'].some(k=>c.rgb&&c.rgb[k]&&c.rgb[k].length);
const lkCan=(c,t)=>!!c&&(t==='prism'?c.prisms.length>0:(c.wheel>=0||lkHasRgb(c)));
const lkDefOn=(g,t)=>t==='prism'||!(t==='strobe'?/ovation/i:/ovation|oppsk|blinder/i).test(g.model);
function lkOn(g){const m=LKO.on[lkT]||{};return lkCan(g.c,lkT)&&(g.model in m?!!m[g.model]:lkDefOn(g,lkT));}
function lkHeads(){const hs=[];if(LK)LK.groups.forEach(g=>{if(lkOn(g))g.heads.forEach(h=>hs.push({h:h,c:g.c,gi:h.gi,n:g.heads.length}));});return hs;}
// a colour on one head: the nearest slot of its colour wheel, or red/green/blue (+ white / amber / UV LEDs for those)
function lkWheel(c,name){const n=name.toLowerCase(),w=lkHex(lkColHex(name));let best=null,bd=1e9;
 for(const s of c.slots){const k=String(s.n).toLowerCase().replace(/\s+/g,'_'),hx=LK_SLOT[k];if(!hx)continue;if(k===n)return {v:s.v,hx:hx};
  const q=lkHex(hx),d=(q[0]-w[0])**2+(q[1]-w[1])**2+(q[2]-w[2])**2;if(d<bd){bd=d;best={v:s.v,hx:hx};}}
 return best||{v:c.slots[0].v,hx:'#ffffff'};}
function lkRgb(c,name){const o={},has=k=>c.rgb[k]&&c.rgb[k].length;let [r,g,b]=lkHex(lkColHex(name)),w=0,a=0,u=0;
 if(name==='White'&&has('white')){r=g=b=0;w=255;}else if(name==='Amber'&&has('amber')){r=g=b=0;a=255;}else if(name==='UV'&&has('uv')){r=g=b=0;u=255;}
 const set=(k,v)=>(c.rgb[k]||[]).forEach(ix=>o[ix]=v);set('red',r);set('green',g);set('blue',b);set('white',w);set('amber',a);set('uv',u);return o;}
function lkColCh(c,name,on,fade){const out=[],f=fade?1:0;let hx=lkColHex(name);
 if(c.wheel>=0){const s=lkWheel(c,name);out.push([c.wheel,s.v,0]);hx=s.hx;}   // a wheel never fades (it would spin through the slots)
 else{const v=lkRgb(c,name);for(const ix in v)out.push([+ix,on||c.dim>=0?v[ix]:0,f]);}
 if(c.dim>=0)out.push([c.dim,on?255:0,c.wheel<0?f:0]);
 if(c.shut)out.push([c.shut.ix,on?c.shut.open:c.shut.closed,0]);
 (c.kill||[]).forEach(k=>{if(!out.some(x=>x[0]===k[0]))out.push([k[0],k[1],0]);});   // built-in strobe / effect programs off
 return {ch:out,hx:on?hx:null};}
function lkPrismCh(c,o){const out=[];(c.gobos||[]).forEach(ix=>out.push([ix,0,0]));
 c.prisms.forEach((p,j)=>{const q=o.p[Math.min(j,o.p.length-1)]||{m:'off'};let v=0;
  if(q.m==='still')v=p.on;else if(q.m==='l'||q.m==='r'){const r=q.m==='l'?p.l:p.r;v=r?Math.round(r[0]+(r[1]-r[0])*Math.max(0,Math.min(100,+q.s||0))/100):p.on;}
  out.push([p.ix,v,0]);});
 if(c.focus>=0)out.push([c.focus,lkByte(o.focus),0]);if(c.zoom>=0)out.push([c.zoom,lkByte(o.zoom),0]);if(c.frost>=0&&!out.some(x=>x[0]===c.frost))out.push([c.frost,0,0]);
 if(c.dim>=0)out.push([c.dim,255,0]);if(c.shut)out.push([c.shut.ix,c.shut.open,0]);
 return {ch:out,hx:'#e8ecff'};}
function lkBuild(){const o=LKO[lkT],hs=lkHeads(),steps=[];if(!hs.length)return {steps:steps,err:'Pick the lights for the look (HEADS).'};
 const st=(len,fn)=>{const s={len:Math.max(1,Math.min(360000,Math.round(len))),f:{},show:{}};hs.forEach(x=>{const r=fn(x);s.f[x.h.id]=r.ch;s.show[x.h.id]=r.hx;});steps.push(s);};
 const hold=v=>Math.round(Math.max(0.01,Math.min(3600,+v||1))*100);
 if(lkT==='contrast'){const ps=(o.pairs||[]).filter(p=>p&&p[0]&&p[1]);if(!ps.length)return {steps:steps,err:'Add a pair of colours.'};
  const side=x=>o.split==='half'?(x.gi<Math.ceil(x.n/2)?0:1):o.split==='type'?(x.c.pan?0:1):x.gi%2;
  ps.forEach(p=>(o.swap?[0,1]:[0]).forEach(sw=>st(hold(o.hold),x=>lkColCh(x.c,p[(side(x)+sw)%2],true,o.fade))));}
 else if(lkT==='chase'){const cs=(o.cols||[]).filter(Boolean);if(cs.length<2)return {steps:steps,err:'Pick at least 2 colours.'};
  const seq=cs.map((_,i)=>i);if(o.pp&&cs.length>2)for(let i=cs.length-2;i>0;i--)seq.push(i);   // 1..n..2: no jump from the last colour back to the first
  seq.forEach((_,k)=>st(hold(o.hold),x=>lkColCh(x.c,cs[seq[(k+(o.spread?x.gi:0))%seq.length]],true,o.fade)));}
 else if(lkT==='strobe'){const cn=o.col||'White';
  if(o.mode==='beat'){st(8,x=>lkColCh(x.c,cn,true,false));st(6000,x=>lkColCh(x.c,cn,false,false));}   // like the user's BEAT STROBE WHITE
  else{st(hold(o.on),x=>lkColCh(x.c,cn,true,false));st(hold(o.off),x=>lkColCh(x.c,cn,false,false));}}
 else st(500,x=>lkPrismCh(x.c,o));
 return {steps:steps,err:'',beat:lkT==='strobe'&&o.mode==='beat',prism:lkT==='prism'};}
function lkAutoName(){const o=LKO[lkT],up=x=>String(x).toUpperCase();let b;
 if(lkT==='contrast'){const p=(o.pairs||[]).filter(x=>x&&x[0]&&x[1]);b=p.length===1?'CONTRAST '+up(p[0][0])+' '+up(p[0][1]):'CONTRAST PAIRS';}
 else if(lkT==='chase')b=o.spread?'RAINBOW COLOR CHASE':'COLOR CHASE';
 else if(lkT==='strobe')b=up(o.col||'White')+(o.mode==='beat'?' BEAT STROBE':' STROBE');
 else b='PRISM FAN';
 let n=b,i=2;while(lkHas(n))n=b+' '+(i++);return n;}
function lkName(){return $('lkname').value.replace(/[\\/:*?"<>|\x00-\x1f]/g,'').replace(/\s+/g,' ').trim().replace(/\.scex$/i,'').replace(/[. ]+$/,'').slice(0,100);}
const lkHas=n=>!!LK&&LK.scenes.some(s=>String(s).toLowerCase()===(n+'.scex').toLowerCase());
function lkNameChk(){const n=lkName(),bad=!n||lkHas(n),e=lkCur&&lkCur.err;
 $('lknamehint').innerHTML=!n?'<span style="color:var(--amber)">Give it a name.</span>':lkHas(n)?'<span style="color:var(--amber)">There&rsquo;s already a scene called that &mdash; pick another name.</span>':'a new file: scenes/'+esc(n)+'.scex';
 $('lkmake').disabled=!LK||bad||!lkCur||!!e;$('lkhint').innerHTML=!LK?'':e?'<span style="color:var(--amber)">'+esc(e)+'</span>':bad?'':'Makes a <b>new</b> scene &mdash; nothing else in the show changes.';}
function lkTplDraw(){document.querySelectorAll('#lktpl [data-lt]').forEach(b=>b.classList.toggle('on',b.dataset.lt===lkT));}
function lkGroupsDraw(){$('lkgroups').innerHTML=LK.groups.map((g,i)=>{const can=lkCan(g.c,lkT),on=lkOn(g);
  return '<button class="chip lkgc'+(on?' on':'')+'" data-gi="'+i+'"'+(can?'':' disabled title="This look doesn&rsquo;t use these lights"')+'>'+(on?'&#10003; ':'')+esc(g.label)+' <small>&times;'+g.heads.length+'</small></button>';}).join('')+
  (LK.skipped.length?'<p class="sub" style="margin:6px 0 0;font-size:12px">Not used (a group of several heads, or no fixture definition): '+LK.skipped.map(esc).join(', ')+'</p>':'');}
function lkVisDraw(){const v=$('lkvis'),gs=LK.groups.filter(lkOn);lkDots={};lkLastL=null;
 if(!gs.length){v.innerHTML='<p class="sub" style="margin:0">No lights picked.</p>';return;}
 v.innerHTML=gs.map(g=>'<div class="lkrow"><small>'+esc(g.label)+'</small><div>'+g.heads.map(h=>'<i data-lh="'+esc(h.id)+'" title="'+esc(h.name)+'"></i>').join('')+'</div></div>').join('');
 v.querySelectorAll('[data-lh]').forEach(e=>lkDots[e.dataset.lh]=e);}
function lkAt(L,now){const n=L.steps.length,ms=L.steps.map(s=>s.len*10);let p=now-lkT0;
 p=L.beat?p%500:p%ms.reduce((a,b)=>a+b,0);   // a beat look is shown at 120 BPM
 let at=0;while(at<n-1&&p>=ms[at]){p-=ms[at];at++;}return {at:at,frac:Math.min(1,p/ms[at])};}
function lkTick(){const L=lkCur;if(!L||!L.steps.length)return;const at=lkAt(L,Date.now()).at;if(at===lkLastAt&&L===lkLastL)return;lkLastAt=at;lkLastL=L;const s=L.steps[at];
 for(const id in lkDots){const hx=s.show[id],e=lkDots[id];e.style.background=hx||'';e.style.boxShadow=hx?'0 0 12px '+hx:'';e.classList.toggle('pr',!!L.prism);}}
function lkAnim(on){if(on&&!lkRaf){const f=()=>{lkRaf=0;if(!LK||lastTab!=='look')return;lkTick();lkRaf=requestAnimationFrame(f);};lkRaf=requestAnimationFrame(f);}}
function lkUpdate(){if(!LK)return;lkCur=lkBuild();const L=lkCur,n=L.steps.length,tot=L.steps.reduce((a,s)=>a+s.len,0)/100,hs=lkHeads();
 $('lkhcnt').textContent=hs.length+' head'+(hs.length===1?'':'s');
 $('lkinfo').textContent=L.err?'':L.beat?'one flash, then dark till the next beat (shown at 120 BPM)':n===1?'one look that holds':n+' steps, '+lkSec(tot)+' round';
 if(!lkNameSet)$('lkname').value=lkAutoName();lkNameChk();lkGroupsDraw();lkVisDraw();lkTick();if(LKP)lkPush();}
// ---- the options of each template
const lkCSel=(k)=>'<select data-k="'+k+'">'+LK_COLS.map(c=>'<option>'+c[0]+'</option>').join('')+'</select>';
const lkSw=n=>'<i class="lksw" style="background:'+lkColHex(n)+'"></i>';
const lkNum=(k,min,max,step)=>'<span><input class="num" type="number" min="'+min+'" max="'+max+'" step="'+step+'" data-k="'+k+'"> s</span>';
function lkGet(o,k){const a=k.split('.');if(a[0]==='pair')return (o.pairs[+a[1]]||[])[+a[2]];if(a[0]==='pm')return (o.p[+a[1]]||{}).m||'off';if(a[0]==='ps')return (o.p[+a[1]]||{}).s;return o[k];}
function lkSet(o,k,v){const a=k.split('.');if(a[0]==='pair'){if(o.pairs[+a[1]])o.pairs[+a[1]][+a[2]]=v;return;}
 if(a[0]==='pm'||a[0]==='ps'){while(o.p.length<=+a[1])o.p.push({m:'off',s:50});if(a[0]==='pm')o.p[+a[1]].m=v;else o.p[+a[1]].s=+v;return;}o[k]=v;}
function lkOptsDraw(){const o=LKO[lkT],b=$('lkopts');let h='';
 if(lkT==='contrast'){
  h='<div class="gh"><h3>COLOUR PAIRS</h3><span class="cnt">one colour on half the heads, the other on the rest</span></div>'+
   o.pairs.map((p,i)=>'<div class="lkpair">'+lkSw(p[0])+lkCSel('pair.'+i+'.0')+'<span class="sub" style="margin:0">with</span>'+lkSw(p[1])+lkCSel('pair.'+i+'.1')+(o.pairs.length>1?'<button class="mini" data-lka="delpair" data-i="'+i+'" title="Take this pair out">&times;</button>':'')+'</div>').join('')+
   (o.pairs.length<8?'<div><button class="mini" data-lka="addpair">+ Add a pair</button></div>':'')+
   '<label class="mvf"><span>Split the heads</span><select data-k="split"><option value="alt">Every other head</option><option value="half">First half / second half</option><option value="type">Movers / the other lights</option></select></label>'+
   '<label class="mvf"><span>Swap the two colours each step</span><input type="checkbox" data-k="swap"></label>'+
   '<label class="mvf"><span>Each step</span>'+lkNum('hold',0.05,3600,0.05)+'</label>'+
   '<label class="mvf"><span>Fade between steps (LED lights)</span><input type="checkbox" data-k="fade"></label>';}
 else if(lkT==='chase'){
  h='<div class="gh"><h3>COLOURS</h3><span class="cnt">in the order you tick them</span></div><div class="lkchips">'+LK_COLS.map(c=>{const i=o.cols.indexOf(c[0]);
    return '<button class="lkcc'+(i>=0?' on':'')+'" data-lka="col" data-c="'+c[0]+'">'+lkSw(c[0])+c[0]+(i>=0?'<b>'+(i+1)+'</b>':'')+'</button>';}).join('')+'</div>'+
   '<div style="display:flex;gap:6px"><button class="mini" data-lka="clear">Clear</button><button class="mini" data-lka="rainbow">Rainbow</button></div>'+
   '<label class="mvf"><span>Back and forth (the colour wheel never jumps far)</span><input type="checkbox" data-k="pp"></label>'+
   '<label class="mvf"><span>Spread over the heads (a rainbow that moves)</span><input type="checkbox" data-k="spread"></label>'+
   '<label class="mvf"><span>Each colour</span>'+lkNum('hold',0.05,3600,0.05)+'</label>'+
   '<label class="mvf"><span>Fade between colours (LED lights)</span><input type="checkbox" data-k="fade"></label>';}
 else if(lkT==='strobe'){
  h='<div class="gh"><h3>COLOUR</h3></div><div class="lkchips">'+LK_COLS.map(c=>'<button class="lkcc'+(c[0]===o.col?' on':'')+'" data-lka="scol" data-c="'+c[0]+'">'+lkSw(c[0])+c[0]+'</button>').join('')+'</div>'+
   '<label class="mvf"><span>Strobe</span><select data-k="mode"><option value="beat">One flash each beat</option><option value="steady">Steady on / off</option></select></label>'+
   (o.mode==='beat'?'<p class="sub" style="margin:0;font-size:12.5px">One short flash, then dark. Set its button to <b>BPM</b> with <b>flash</b> (&ldquo;run from step 1&rdquo;) in ShowXpress &mdash; or put it on an SX Player page from here, which does that for you &mdash; and it flashes on every beat.</p>':
    '<label class="mvf"><span>On for</span>'+lkNum('on',0.01,10,0.01)+'</label><label class="mvf"><span>Off for</span>'+lkNum('off',0.01,10,0.01)+'</label>');}
 else{const g=LK.groups.find(x=>lkOn(x))||LK.groups.find(x=>x.c&&x.c.prisms.length),nm=g?g.c.prisms.map(p=>p.name):[];
  h='<div class="gh"><h3>PRISMS</h3><span class="cnt">no colour of its own &mdash; play it with a colour look</span></div>'+
   (nm.length?nm.slice(0,2).map((n,j)=>{const m=lkGet(o,'pm.'+j);return '<div class="lkpr"><b>'+esc(n)+'</b><select data-k="pm.'+j+'"><option value="off">Off</option><option value="still">In, still</option><option value="l">Spin left</option><option value="r">Spin right</option></select>'+
     (m==='l'||m==='r'?'<input type="range" min="0" max="100" data-k="ps.'+j+'"><span class="sub" style="margin:0;min-width:24px" data-pv="'+j+'">'+esc(lkGet(o,'ps.'+j))+'</span>':'')+'</div>';}).join(''):'<p class="sub" style="margin:0">None of the show&rsquo;s lights has a prism.</p>')+
   '<label class="mvf"><span>Zoom</span><input type="range" min="0" max="255" data-k="zoom"></label><label class="mvf"><span>Focus</span><input type="range" min="0" max="255" data-k="focus"></label>'+
   '<p class="sub" style="margin:0;font-size:12.5px">Spin speed: try it on the lights &mdash; each fixture counts it its own way. The gobos are set open and frost off.</p>';}
 b.innerHTML=h;b.querySelectorAll('[data-k]').forEach(e=>{const v=lkGet(o,e.dataset.k);if(e.type==='checkbox')e.checked=!!v;else if(v!=null)e.value=v;});}
$('lkopts').addEventListener('input',e=>{const t=e.target;if(!t.dataset||!t.dataset.k||t.tagName==='SELECT'||t.type==='checkbox')return;
 lkSet(LKO[lkT],t.dataset.k,t.value===''?'':+t.value);if(t.dataset.k.startsWith('ps.')){const s=$('lkopts').querySelector('[data-pv="'+t.dataset.k.slice(3)+'"]');if(s)s.textContent=t.value;}
 lkKeep();lkUpdate();});
$('lkopts').addEventListener('change',e=>{const t=e.target;if(!t.dataset||!t.dataset.k)return;
 if(t.type==='checkbox')lkSet(LKO[lkT],t.dataset.k,t.checked);else if(t.tagName==='SELECT')lkSet(LKO[lkT],t.dataset.k,t.value);else return;
 lkKeep();if(t.tagName==='SELECT')lkOptsDraw();lkUpdate();});
$('lkopts').addEventListener('click',e=>{const b=e.target.closest('[data-lka]');if(!b)return;const o=LKO[lkT],a=b.dataset.lka,u=LK_COLS.map(c=>c[0]);
 if(a==='addpair')o.pairs.push([u[(o.pairs.length*3+1)%u.length],u[(o.pairs.length*3+7)%u.length]]);
 else if(a==='delpair')o.pairs.splice(+b.dataset.i,1);
 else if(a==='col'){const i=o.cols.indexOf(b.dataset.c);if(i>=0)o.cols.splice(i,1);else o.cols.push(b.dataset.c);}
 else if(a==='clear')o.cols=[];else if(a==='rainbow')o.cols=LK_DEF.chase.cols.slice();
 else if(a==='scol')o.col=b.dataset.c;
 lkKeep();lkOptsDraw();lkUpdate();});
$('lktpl').onclick=e=>{const b=e.target.closest('[data-lt]');if(!b||b.dataset.lt===lkT)return;lkT=b.dataset.lt;lkNameSet=false;lkT0=Date.now();lkTplDraw();lkOptsDraw();lkUpdate();};
$('lkgroups').onclick=e=>{const b=e.target.closest('[data-gi]');if(!b||b.disabled)return;const g=LK.groups[+b.dataset.gi],m=LKO.on[lkT]=LKO.on[lkT]||{};m[g.model]=!lkOn(g);lkKeep();if(lkT==='prism')lkOptsDraw();lkUpdate();};
$('lkname').oninput=()=>{lkNameSet=!!$('lkname').value.trim();lkNameChk();};
$('lkrefresh').onclick=()=>{LK=null;loadLooks();};
// ---- on the lights (the same raw DMX output as the editors' previews: one at a time)
function lkFrame(){const L=lkCur,out={};if(!L||!L.steps.length)return out;const q=lkAt(L,Date.now()),s=L.steps[q.at],p=L.steps[(q.at-1+L.steps.length)%L.steps.length];
 for(const id in s.f){const h=LK.byId[id];if(!h||!h.addr)continue;const pv={};(p.f[id]||[]).forEach(c=>pv[c[0]]=c[1]);
  for(const c of s.f[id]){const ch=h.addr+c[0];if(ch<1||ch>8192)continue;let v=c[1];if(c[2]&&L.steps.length>1&&c[0] in pv)v=pv[c[0]]+(v-pv[c[0]])*q.frac;out[ch]=lkByte(v);}}
 return out;}
function lkPush(){if(!LKP||!LKP.on)return;const fr=lkFrame();
 for(const ch in LKP.sent){if(!(ch in fr)&&LKP.sent[ch]!==0){LKP.sent[ch]=0;LKP.pend.set(ch,'b:'+ch+':0');}}
 for(const ch in fr){if(LKP.sent[ch]!==fr[ch]){LKP.sent[ch]=fr[ch];LKP.pend.set(ch,'b:'+ch+':'+fr[ch]);}}
 lkKick();}
function lkKick(){if(!LKP||LKP.tm||LKP.fl)return;const d=30-(Date.now()-LKP.last);if(d>0)LKP.tm=setTimeout(()=>{if(LKP){LKP.tm=0;lkFlush();}},d);else lkFlush();}
async function lkFlush(){if(!LKP||!LKP.on||LKP.fl)return;let l=((LKP.z?'z ':'')+[...LKP.pend.values()].join(' ')).trim();if(!l){if(!LKP.ka)return;l='k';}
 const me=LKP;LKP.z=false;LKP.ka=false;LKP.pend.clear();LKP.fl=true;LKP.last=Date.now();let r;try{r=await api('/api/live/out',{l:l});}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}
 if(LKP!==me||!LKP.on)return;LKP.fl=false;
 if(!r.ok){const reo=LKP.reo;await lkPvStop(false);showResult({ok:false,error:(r.error||'The DMX output stopped.')+(reo?' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.':'')},'clprev');return;}
 if(LKP.pend.size)lkKick();}
function lkPvUi(){const on=!!LKP;$('lkpv').classList.toggle('on',on);$('lkpvsub').style.display=on?'none':'';$('lkpvgo').style.display=on?'none':'';$('lkpvstop').style.display=on?'':'none';$('lkpvreow').style.display=on?'':'none';
 const t=$('lkpvif');t.style.display=on?'':'none';if(on){t.className='tag '+(LKP.test?'red':'blue');t.textContent=LKP.test?'TEST - no real output':'Output: '+LKP.iface;}}
async function lkPvGo(){if(LKP||SEP||MVP||LV||CP||!LK)return;
 const c=await sxCloseLive('Close ShowXpress to see the look on the lights?','Only one program can use the DMX interface, so ShowXpress closes while you preview. <b>Save your show first</b> if you changed anything &mdash; if ShowXpress asks, answer it there.<br><br>It can open again when you stop.','Close and preview','Show on the lights','clprev');
 if(!c.go)return;
 const r=await lvStart('floor',true);
 if(!r.ok){try{await api('/api/live/stop',{});}catch(e){}if(c.reo)r.error=(r.error||'')+' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';showResult(r,'clprev');return;}
 LKP={on:true,sent:{},pend:new Map(),z:true,ka:false,fl:false,tm:0,last:0,reo:c.reo,test:!!r.test,iface:r.iface};
 LKP.kat=setInterval(()=>{if(LKP&&LKP.on&&Date.now()-LKP.last>1000){LKP.ka=true;lkKick();}},1000);
 LKP.pt=setInterval(lkPush,40);$('lkpvreo').checked=c.reo;lkPvUi();lkPush();}
async function lkPvStop(reo){if(!LKP)return;clearInterval(LKP.kat);clearInterval(LKP.pt);if(LKP.tm)clearTimeout(LKP.tm);LKP.on=false;LKP=null;lkPvUi();
 busy(true,'Stopping the DMX output…');try{await api('/api/live/stop',{});}catch(e){}busy(false);if(reo)await sxLaunch();}
$('lkpvgo').onclick=lkPvGo;$('lkpvstop').onclick=()=>lkPvStop($('lkpvreo').checked);
// ---- make it, then: open it in the Scene Editor, or put it on one of the SX Player's own pages (settings only)
$('lkmake').onclick=async()=>{const L=lkCur,n=lkName();if(!LK||!L||L.err||!n||lkHas(n))return;
 busy(true,'Making the scene…');let r;try{r=await api('/api/looks/make',{name:n+'.scex',steps:L.steps.map(s=>({len:s.len,f:s.f}))});}catch(e){r={ok:false,error:'Lost connection to SX Studio.'};}busy(false);
 if(r.ok){LK.scenes.push(n+'.scex');lkMade={file:n+'.scex',name:n,beat:!!L.beat};SL=null;MLS=null;if(LB&&LB.files)LB.files.push(n+'.scex');lkNameSet=false;lkUpdate();lkDoneDraw();}
 showResult(r,'look');};
function lkDoneDraw(){const m=lkMade,c=$('lkdone');if(!m){c.style.display='none';return;}c.style.display='';const cu=lbLay().custom;
 c.innerHTML='<h2>&#10003; Made: '+esc(m.name)+'</h2><p class="sub">A new scene in the show. To play it, add a button for it on ShowXpress&rsquo;s live board (if ShowXpress is open, open the show again so it lists the new scene), or put it on one of the SX Player&rsquo;s own pages here'+(m.beat?' &mdash; it gets <b>BPM + flash</b>, so it flashes on every beat':'')+'.</p>'+
  '<div class="row" style="gap:8px;flex-wrap:wrap"><select id="lkpg" style="width:auto;max-width:240px">'+cu.map(p=>'<option value="'+esc(p.id)+'">'+esc(p.name)+'</option>').join('')+'<option value="">+ a new page: LOOKS</option></select>'+
  '<button id="lkaddpg">Put it on this SX Player page</button><button id="lkedit">Change it in the Scene Editor</button></div><div class="sub" id="lkpgmsg" style="margin:8px 0 0"></div>';
 $('lkedit').onclick=async()=>{setTab('scene');await seOpen(m.file);};
 $('lkaddpg').onclick=async()=>{const lay=lbLay(),msg=$('lkpgmsg');let id=$('lkpg').value,p=lay.custom.find(x=>x.id===id);
  if(!p){if(lay.custom.length>=40){msg.innerHTML='<span style="color:var(--amber)">The player already has 40 pages of its own &mdash; pick one of them.</span>';return;}
   id=lbNextPage(lay);p={id:id,name:'LOOKS',swap:false,buttons:[]};lay.custom.push(p);if(lay.pages.length)lay.pages.push(id);}
  p.buttons=p.buttons||[];if(p.buttons.length>=64){msg.innerHTML='<span style="color:var(--amber)">That page is full (64 buttons).</span>';return;}
  p.buttons.push({id:lbNextBtn(p),title:m.name.slice(0,40),file:m.file,fader:0,bpm:m.beat,flash:m.beat,beats:1,color:-1});
  let r;try{r=await api('/api/settings/set',{playerLayout:lay});}catch(e){r={ok:false};}
  if(!r.ok){msg.innerHTML='<span style="color:var(--amber)">It wasn&rsquo;t saved &mdash; try again.</span>';return;}
  SET=r.settings;if(LB)renderLab();lkDoneDraw();$('lkpgmsg').innerHTML='&#10003; On the SX Player page <b>'+esc(p.name)+'</b>. <a href="#" id="lkgolab">Open the SX Player</a>';
  $('lkgolab').onclick=e=>{e.preventDefault();setTab('lab');};};}

// ---------------- PHONE / iPAD: pairing (on the phone) and the Phone & iPad card (on the computer)
function phUnpaired(msg){const off=/turned off/.test(msg||'');
 if(!off){try{localStorage.removeItem('sxh_phone_key');}catch(e){}try{const u=new URL(location.href);if(u.searchParams.has('k')){u.searchParams.delete('k');history.replaceState(null,'',u.pathname+u.search+location.hash);}}catch(e){}T='';}
 $('pairmsg').innerHTML=/turned off/.test(msg||'')?'<span style="color:var(--amber)">Phone access is turned off on the laptop (&#9881; Settings &rarr; Phone &amp; iPad).</span>':'';$('pair').classList.add('on');}
async function phPair(){const v=$('pairpin').value.replace(/\D/g,'');if(v.length!==6){$('pairmsg').textContent='Type the 6 digits from the laptop.';return;}
 $('pairgo').disabled=true;let r;
 try{const x=await fetch('/api/phone/pair',{method:'POST',headers:{'Content-Type':'text/plain'},body:JSON.stringify({pin:v})});r=x.ok?await x.json():{ok:false,error:await x.text()};}
 catch(e){r={ok:false,error:'Can’t reach the laptop. Is this phone on the same Wi-Fi?'};}
 $('pairgo').disabled=false;if(!r.ok){$('pairmsg').innerHTML='<span style="color:var(--red)">'+esc(r.error)+'</span>';return;}
 phKeep(r.key);location.reload();}
$('pairgo').onclick=phPair;$('pairpin').addEventListener('keydown',e=>{if(e.key==='Enter')phPair();});
$('pairpin').addEventListener('input',e=>{const v=e.target.value.replace(/\D/g,'').slice(0,6);e.target.value=v;if(v.length===6)phPair();});
let PHI=null,phT=0;
async function loadPhone(){if(PH)return;PHI=await getJ('/api/phone');renderPhone();}
async function copyText(t){try{if(navigator.clipboard&&window.isSecureContext){await navigator.clipboard.writeText(t);return true;}}catch(e){}
 const ta=document.createElement('textarea');ta.value=t;ta.setAttribute('readonly','');ta.style.cssText='position:fixed;left:-9999px;top:0';document.body.appendChild(ta);ta.select();
 let ok=false;try{ok=document.execCommand('copy');}catch(e){}ta.remove();return ok;}
document.addEventListener('click',async e=>{const b=e.target.closest&&e.target.closest('.phcopy');if(!b)return;e.preventDefault();
 const ok=await copyText(b.dataset.copy),was=b.dataset.label||(b.dataset.label=b.innerHTML);b.classList.toggle('done',ok);b.innerHTML=ok?'&#10003; Copied':'Select it and copy';
 clearTimeout(b._t);b._t=setTimeout(()=>{b.classList.remove('done');b.innerHTML=was;},1600);});
function renderPhone(){const p=PHI,b=$('phbody');if(!p)return;$('phon').checked=!!(p.ok&&p.on);
 if(!p.ok){b.innerHTML='<div class="warnbox" style="display:block">'+esc(p.error||'')+'</div>';return;}
 if(!p.on){b.innerHTML='<p class="sub" style="margin:10px 0 0">Off. Tick the box, then open the address it shows in Safari on the iPhone or iPad.</p>';return;}
 if(!p.running){b.innerHTML='<div class="warnbox" style="display:block">'+esc(p.error||'The phone connection is not running.')+'</div>';return;}
 const u=a=>'http://'+a+':'+p.port,list=[];
 const cb=t=>'<button class="mini phcopy" data-copy="'+esc(t)+'" title="Copy">&#128203; Copy</button>';
 if(p.local)list.push('<div class="phrow"><span class="phaddr">'+esc(u(p.local))+'<small>same at every venue &mdash; try this first</small></span>'+cb(u(p.local))+'</div>');
 p.addrs.forEach(a=>list.push('<div class="phrow"><span class="phaddr">'+esc(u(a.ip))+'<small>'+esc(a.name)+'</small></span>'+cb(u(a.ip))+'</div>'));
 const seen=p.lastSeen?'<p class="sub" style="margin:10px 0 0">Last phone: <b>'+esc(p.lastIp)+'</b>, '+fmtT(p.lastSeen)+'.</p>':'';
 b.innerHTML='<div class="phgrid"><div><div class="phbox"><h3>ON THE PHONE OR iPAD, OPEN SAFARI AND GO TO</h3>'+(list.length?list.join(''):'<span style="color:var(--red)">This computer isn&rsquo;t on a network right now.</span>')+'</div>'+
  '<p class="sub" style="margin:10px 0 0">Then <b>Share &rarr; Add to Home Screen</b> for an app icon. The phone and the laptop must be on the <b>same Wi-Fi</b>. Venue Wi-Fi often keeps devices apart &mdash; the surest way is your own small travel router, or the laptop on your iPhone&rsquo;s Personal Hotspot.'+
  (p.mac?' If macOS asks whether <b>pwsh</b> may accept incoming connections, press <b>Allow</b>.':' The first time, Windows may ask whether <b>PowerShell</b> may use the network &mdash; tick <b>Private networks</b> and press <b>Allow</b>.')+'</p>'+seen+'</div>'+
  '<div class="phbox" style="text-align:center"><h3>PAIR A PHONE</h3>'+(p.pin?'<div class="phpin">'+esc(p.pin)+'</div><div style="margin:6px 0 2px">'+cb(p.pin).replace('&#128203; Copy','&#128203; Copy code')+'</div><p class="sub" style="margin:4px 0 10px">Type this on the phone. Good for '+Math.max(1,Math.ceil(p.pinLeft/60))+' more min.</p>':
   '<p class="sub" style="margin:0 0 10px">Each phone or iPad is paired once, with a 6-digit code.</p><button id="phpinb" class="primary" style="padding:10px 22px;font-size:14px">Pair a phone</button>')+
  '<div style="margin-top:12px"><button id="phunp" class="mini">Unpair all phones</button></div></div></div>';
 const pb=$('phpinb');if(pb)pb.onclick=async()=>{PHI=await getJ('/api/phone/pin');renderPhone();};
 $('phunp').onclick=async()=>{if(!await ask('Unpair all phones?','Every paired phone and iPad has to be paired again with a new code.','Unpair'))return;PHI=await api('/api/phone/unpair',{});renderPhone();};}
$('phon').onchange=async e=>{busy(true,e.target.checked?'Turning on phone access…':'Turning off phone access…');try{PHI=await api('/api/phone/set',{on:e.target.checked});}catch(x){PHI={ok:false,error:'Lost connection.'};}busy(false);renderPhone();};
if(!PH){loadPhone();setInterval(()=>{if(PHI&&PHI.on&&$('v-settings').classList.contains('on')&&!document.hidden)loadPhone();},5000);}

if(__PHONE__&&!T){phUnpaired('');}
else{setTab(location.hash.slice(1)||'home');draw();load();poll();loadSet().then(()=>{if(!PH&&(!SET||SET.autoUpd!==false))chkUpd();});}
</script></body></html>
'@

if (-not $NoBrowser) { Close-OldWindows; Open-AppWindow $url }
$last = Get-Date
try {
  while ($l.IsListening) {
    $task = $l.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(1000)) {
      try { Step-Queue } catch {}
      try { Step-Pending } catch {}
      Step-PlayerKeep
      try { Step-PlayerWatch } catch {}
      try { Step-Taskbar } catch {}
      try { Step-Apc40 } catch {}
      if (((Get-Date) - $last).TotalSeconds -gt $idleMax -and -not $queue.Count -and -not (Test-Auto) -and -not (Test-Player) -and -not (Test-Apc40Busy)) { $l.Stop(); break }
    }
    if (-not $l.IsListening) { break }
    $ctx = $task.Result; $req = $ctx.Request
    Step-PlayerKeep   # busy windows (the Lab polls 2-3x a second) never reach the idle loop above
    try { Step-PlayerWatch } catch {}
    try { Step-Taskbar } catch {}
    try {
      $path = $req.Url.AbsolutePath
      # a phone (through the Wi-Fi relay) needs the phone key; everything else needs this window's key
      $fromPhone = [bool]"$($req.Headers['X-SXH-Phone'])"
      if ($fromPhone) {
        if (-not $script:ph.on) { Send-Text $ctx 403 'text/plain' 'Phone access is turned off in SX Studio.'; continue }
        if ($phoneNever -contains $path) { Send-Text $ctx 403 'text/plain' 'Only on the computer.'; continue }
        if ($phoneOpen -notcontains $path -and -not ($script:ph.key -and ($req.QueryString['t'] -ceq $script:ph.key -or (Get-PhoneCookieKey $req)))) { Send-Text $ctx 403 'text/plain' 'Pair this phone again.'; continue }
      } elseif ($req.QueryString['t'] -ne $token) { Send-Text $ctx 403 'text/plain' 'Open SX Studio from its icon.'; continue }
      $last = Get-Date
      $body = $null
      if ($req.HttpMethod -eq 'POST') { $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); if ($raw) { $body = $raw | ConvertFrom-Json } }
      if ($req.HttpMethod -eq 'POST' -and $queueable.ContainsKey($path)) {
        # ShowXpress open + the page asked to queue -> do it when ShowXpress closes; else now
        if ($body -and $body.queue -and (Test-SxOpen)) { Send-Json $ctx (Add-Queue $path $body) } else { Send-Json $ctx (Invoke-Action $path $body) }
        continue
      }
      switch ($path) {
        '/'            {
          if ($fromPhone) {
            # a paired phone gets its key back from the cookie (or from ?k= in the address) even if its storage was cleared
            $ck = Get-PhoneCookieKey $req; $uk = "$($req.QueryString['k'])"
            if (-not $ck -and $script:ph.key -and $uk -ceq $script:ph.key) { $ck = $uk }
            if ($ck) { Set-PhoneCookie $ctx }
            Send-Text $ctx 200 'text/html; charset=utf-8' ($html.Replace('__TOKEN__', '').Replace('__PHONEKEY__', $ck).Replace('__PHONE__', 'true'))
          }
          else { Send-Text $ctx 200 'text/html; charset=utf-8' ($html.Replace('__TOKEN__', $token).Replace('__PHONEKEY__', '').Replace('__PHONE__', 'false')) }
        }
        '/api/phone'   { Send-Json $ctx (Get-PhoneInfo) }
        '/api/phone/set' {
          $script:ph.on = [bool]$body.on; Save-Phone
          if ($script:ph.on) { Start-PhoneRelay } else { Stop-PhoneRelay; $script:pin = '' }
          Send-Json $ctx (Get-PhoneInfo)
        }
        '/api/phone/pin' {
          # a new 6-digit code, good for 10 minutes (any number of phones / iPads can use it in that time)
          $script:pin = '{0:D6}' -f (Get-Random -Minimum 0 -Maximum 1000000); $script:pinUntil = (Get-Date).AddMinutes(10); $script:pinFails = 0
          Send-Json $ctx (Get-PhoneInfo)
        }
        '/api/phone/unpair' { $script:ph.key = New-PhoneKey; Save-Phone; $script:pin = ''; Send-Json $ctx (Get-PhoneInfo) }
        '/api/phone/pair' {
          $now = Get-Date
          if (-not $fromPhone) { Send-Json $ctx @{ ok = $false; error = 'Pairing is for phones.' }; break }
          if ($now -lt $script:pinLock) { Send-Json $ctx @{ ok = $false; error = 'Too many wrong codes. On the laptop, press "Pair a phone" again for a new code.' }; break }
          if (-not $script:pin -or $now -gt $script:pinUntil) { Send-Json $ctx @{ ok = $false; error = 'No code is showing on the laptop. In SX Studio on the laptop, press the cogwheel (top right) and press "Pair a phone".' }; break }
          if ("$($body.pin)".Trim() -ceq $script:pin) { $script:pinFails = 0; Save-Phone; Set-PhoneCookie $ctx; Send-Json $ctx @{ ok = $true; key = $script:ph.key }; break }
          $script:pinFails++
          if ($script:pinFails -ge 5) { $script:pin = ''; $script:pinLock = $now.AddSeconds(60) }
          Start-Sleep -Milliseconds 600
          Send-Json $ctx @{ ok = $false; error = 'That code is not right. Check the 6 digits on the laptop.' }
        }
        '/brand.png'   {
          $bp = @((Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ShowXpress Helper/brand.png'), (Join-Path $HOME 'AwaazTools/brand.png'), (Join-Path $here 'brand.png'), (Join-Path $here '../assets/brand.png')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
          if ($bp) { Send-Png $ctx $bp } else { Send-Text $ctx 404 'text/plain' 'no brand image' }
        }
        { $_ -eq '/fonts/saira.woff2' -or $_ -eq '/fonts/orbitron.woff2' } {
          # SX Studio's fonts (SIL Open Font License, see fonts/OFL-*.txt), bundled so it looks the same offline
          $fp = @((Join-Path $here "fonts/$(Split-Path -Leaf $path)"), (Join-Path $here "../assets/fonts/$(Split-Path -Leaf $path)")) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
          if ($fp) { $fb = [IO.File]::ReadAllBytes($fp); $ctx.Response.ContentType = 'font/woff2'; $ctx.Response.Headers.Add('Cache-Control', 'max-age=86400'); $ctx.Response.ContentLength64 = $fb.Length; $ctx.Response.OutputStream.Write($fb, 0, $fb.Length); $ctx.Response.Close() }
          else { Send-Text $ctx 404 'text/plain' 'no font' }
        }
        { $_ -eq '/logo.png' -or $_ -eq '/mark.png' } {
          # the SX Studio logo (tools/make_sx_brand.py): sx_logo.png = mark + STUDIO, sx_mark.png = the mark
          $lf = if ($path -eq '/logo.png') { 'sx_logo.png' } else { 'sx_mark.png' }
          $lp = @((Join-Path $here $lf), (Join-Path $here "../assets/$lf")) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
          if ($lp) { Send-Png $ctx $lp } else { Send-Text $ctx 404 'text/plain' 'no logo' }
        }
        '/icon.png'    { $ip = Join-Path $here 'aim_movers_1024.png'; if (-not (Test-Path $ip)) { $ip = Join-Path $here '../assets/aim_movers_1024.png' } if (Test-Path $ip) { $ib = [IO.File]::ReadAllBytes($ip); $ctx.Response.ContentType = 'image/png'; $ctx.Response.ContentLength64 = $ib.Length; $ctx.Response.OutputStream.Write($ib, 0, $ib.Length); $ctx.Response.Close() } else { Send-Text $ctx 404 'text/plain' 'no icon' } }
        '/api/sx'      { Send-Json $ctx @{ open = (Test-SxOpen); q = (Get-QueueInfo); live = (Test-Live); play = (Test-Player); auto = (Get-AutoStatus); pend = [bool]$script:pend; rem = $script:remLast } }
        '/api/remote'  { Send-Json $ctx (Invoke-Remote 'State') }
        '/api/remote/press' {
          $ts = @($body.titles | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
          $rs = @($body.release | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
          if (-not $ts.Count -or $ts.Count -gt 30 -or $rs.Count -gt 30 -or @($ts + $rs | Where-Object { $_ -notmatch $titleRx }).Count) { Send-Json $ctx @{ ok = $false; error = 'Unknown button.' }; break }
          $fl = ''
          if ($body.solo) { $fl += '-Solo ' }
          if ($body.idle) { $fl += '-Idle ' }
          if ($rs.Count) { $fl += '-Release "' + ($rs -join '|') + '"' }
          Send-Json $ctx (Invoke-Remote 'Press' $ts $fl)
        }
        '/api/remote/off' { Send-Json $ctx (Invoke-Remote 'Off') }
        '/api/auto' {
          $r = Invoke-Engine '-Action AutoGet' $remoteEngine
          $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
          if (-not $j) { Send-Json $ctx @{ ok = $false; error = $(if ($r.error) { $r.error } else { 'Could not read the show.' }) }; break }
          $st = Get-AutoStatus; Send-Text $ctx 200 'application/json; charset=utf-8' ($j.Substring(0, $j.Length - 1) + ',"player":' + $(if (Test-Player) { 'true' } else { 'false' }) + ',"status":' + $(if ($st) { $st | ConvertTo-Json -Depth 4 -Compress } else { 'null' }) + '}')
        }
        '/api/auto/status' { Send-Json $ctx @{ ok = $true; status = (Get-AutoStatus) } }
        '/api/apc40'        { Send-Apc40Json $ctx (Invoke-Engine "-Action Info -Layout `"$(Get-Apc40Lay)`"" $apc40Engine) }
        '/api/apc40/status' { Send-Json $ctx @{ ok = $true; status = (Get-Apc40Status) } }
        '/api/apc40/save' {
          if (-not $body -or -not $body.layout) { Send-Json $ctx @{ ok = $false; error = 'Nothing to save.' }; break }
          $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
          [IO.File]::WriteAllText($cf, ($body.layout | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
          try { $r = Invoke-Engine "-Action Save -ConfigFile `"$cf`" -Layout `"$(Get-Apc40Lay)`"" $apc40Engine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
          if ($r.ok) { [void](Send-Apc40 'reload') }
          Send-Apc40Json $ctx $r
        }
        '/api/auto/save' {
          if (-not $body -or -not $body.config) { Send-Json $ctx @{ ok = $false; error = 'Nothing to save.'; out = '' }; break }
          $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
          [IO.File]::WriteAllText($cf, ($body.config | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
          try { $r = Invoke-Engine "-Action AutoSave -ConfigFile `"$cf`"" $remoteEngine } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
          if ($r.ok) { [void](Send-Auto 'reload'); $j = ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1; if ($j) { $r.config = ($j | ConvertFrom-Json) } }
          Send-Json $ctx $r
        }
        '/api/auto/start' { Send-Json $ctx (Start-Auto "$($body.look)") }
        '/api/auto/stop'  { Stop-Auto; Start-Sleep -Milliseconds 100; Send-Json $ctx @{ ok = $true; status = (Get-AutoStatus) } }
        '/api/auto/cmd' {
          $c = "$($body.cmd)"; $v = "$($body.v)"
          if ($c -notin 'next', 'prev', 'hold', 'resume', 'sync', 'bpm', 'go' -or ($c -eq 'bpm' -and $v -notmatch '^\d{2,3}(\.\d)?$') -or ($c -eq 'go' -and $v -notmatch '^[0-9a-f]{8}$')) { Send-Json $ctx @{ ok = $false; error = 'Unknown command.' }; break }
          $ok = Send-Auto $(if ($c -eq 'bpm' -or $c -eq 'go') { "$c $v" } else { $c })
          Start-Sleep -Milliseconds 350
          Send-Json $ctx @{ ok = $ok; error = $(if ($ok) { '' } else { 'The Auto Show isn''t playing.' }); status = (Get-AutoStatus) }
        }
        '/api/live/start' {
          if (Test-SxOpen) { Send-Json $ctx @{ ok = $false; sxopen = $true; error = 'ShowXpress is open - it has to be closed while you aim live (only one program can use the DMX interface).'; out = '' }; break }
          if (Test-Player) { Send-Json $ctx @{ ok = $false; error = 'The SX Player (Lab) is using the DMX interface. Stop it in the Lab first.'; out = '' }; break }
          # raw = the Scene Editor's preview: the scene's own values go out as they are (the show files already hold
          # what goes out to reversed heads), so no head info and no reversing
          $raw = [bool]$body.raw
          if ($raw) { $j = '{}' }
          else {
            $mo = if ("$($body.mode)" -eq 'room') { ' -Mode Room' } else { '' }
            $r = Invoke-Engine "-Action LiveInfo$mo"
            $j = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 }
            if (-not $j) { Send-Json $ctx @{ ok = $false; error = $(if ($r.error) { $r.error } else { 'Could not read the show.' }); out = '' }; break }
          }
          $script:liveHold = Get-Date
          # REVERSE HEADS: the screen works "as if hung normally"; heads the Helper reverses get 65535 - v here (like the fixture's menu)
          $script:liveInv = @{}
          if (-not $raw) { try { foreach ($h in @(($j | ConvertFrom-Json).heads)) { $ad = [int]$h.addr
            if ($h.rp) { $script:liveInv[$ad] = 1; $script:liveInv[$ad + 1] = 1 }; if ($h.rt) { $script:liveInv[$ad + 2] = 1; $script:liveInv[$ad + 3] = 1 } } } catch {} }
          # NovaStar NovaLCT (LED screens) has a USB scanner that grabs the D512S (found 2026-11-21). Paused only when the user says so.
          if ($body.stopNova -and -not $onMac) { Get-Process MarsServerProvider -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }
          $s = Start-Live
          if (-not $s.ok -and -not $onMac -and "$($s.error)" -like '*was not found*' -and (Get-Process MarsServerProvider -ErrorAction SilentlyContinue)) {
            $s.nova = $true; $s.error = 'The NovaStar LED-screen software (NovaLCT) is holding the DMX interface. Its USB scanner can be paused while you aim - NovaLCT starts it again by itself.'
          }
          if (-not $s.ok) { Send-Json $ctx $s; break }
          Send-Text $ctx 200 'application/json; charset=utf-8' ('{"ok":true,"iface":' + (ConvertTo-Json $s.iface -Compress) + ',"test":' + $(if ($TestRoot) { 'true' } else { 'false' }) + ',"info":' + $j + '}')
        }
        '/api/live/out' {
          $ln = "$($body.l)"
          if ($ln.Length -gt 60000 -or @($ln -split ' ' | Where-Object { $_ -and $_ -notmatch '^(z|k|b:\d{1,4}:\d{1,3}|[ps]:\d{1,4}:\d{1,4}:\d{1,5})$' }).Count) { Send-Json $ctx @{ ok = $false; error = 'Bad output command.' }; break }
          if (-not (Test-Live)) { Send-Json $ctx @{ ok = $false; gone = $true; error = 'The DMX output stopped.' }; break }
          if ($script:liveInv -and $script:liveInv.Count) {
            $ln = (@($ln -split ' ') | ForEach-Object {
              if ($_ -match '^([ps]):(\d+):(\d+):(\d+)$' -and $script:liveInv[[int]$matches[2]]) { "$($matches[1]):$($matches[2]):$($matches[3]):$(65535 - [int]$matches[4])" }
              elseif ($_ -match '^b:(\d+):(\d+)$' -and $script:liveInv[[int]$matches[1]]) { "b:$($matches[1]):$(255 - [int]$matches[2])" }
              else { $_ } }) -join ' '
          }
          try { $script:liveP.StandardInput.WriteLine($ln); Send-Json $ctx @{ ok = $true } } catch { Send-Json $ctx @{ ok = $false; gone = $true; error = 'The DMX output stopped.' } }
        }
        '/api/live/stop' { Stop-Live; $script:liveHold = [datetime]::MinValue; Send-Json $ctx @{ ok = $true } }
        '/api/lab'        { Send-EngineJson $ctx (Invoke-Engine '-List' $playerEngine) }
        '/api/lab/status' { Send-Json $ctx @{ ok = $true; running = (Test-Player); status = (Get-PlayerStatus); event = $script:playEvent } }
        '/api/lab/snap' {
          # before ShowXpress closes for the player: remember what it's playing, so the player carries on with it
          $script:carry = $null
          if ((Test-SxOpen) -and -not (Test-Auto)) {
            $x = Invoke-Remote 'State'
            if ($x.connected) { $script:carry = @{ at = Get-Date; titles = @(@($x.pressed) | Where-Object { "$($_.page)" -notmatch '^\s*setup\s*$' -and "$($_.title)" -match $titleRx } | ForEach-Object { "$($_.title)" } | Select-Object -Unique) } }
          }
          Send-Json $ctx @{ ok = $true; titles = $(if ($script:carry) { @($script:carry.titles) } else { @() }) }
        }
        '/api/lab/handoff' {
          if (-not (Test-Player)) { $r = Start-Sx; Send-Json $ctx @{ ok = [bool]$r.ok; error = "$($r.error)"; titles = @(); test = [bool]$TestRoot }; break }
          Send-Json $ctx (Invoke-Handoff $true 'Handed over to ShowXpress.')
        }
        '/api/lab/start' {
          if (Test-SxOpen) { Send-Json $ctx @{ ok = $false; sxopen = $true; error = 'ShowXpress is open - it has to be closed while the SX Player plays (only one program can use the DMX interface).'; out = '' }; break }
          if (Test-Live) { Send-Json $ctx @{ ok = $false; error = 'Aim live or the colour preview is using the DMX interface. Finish that first.'; out = '' }; break }
          $r = Invoke-Engine '-List' $playerEngine
          $j = $null; if ($r.ok) { try { $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json } catch {} }
          if (-not $j -or -not $j.ok) { Send-Json $ctx @{ ok = $false; error = $(if ($r.error) { $r.error } else { 'Could not read the show.' }); out = '' }; break }
          $script:labMap = @{}
          foreach ($pg in @($j.pages)) { foreach ($b in @($pg.buttons)) { $script:labMap["$($b.sec)"] = $b } }
          if ($body.stopNova -and -not $onMac) { Get-Process MarsServerProvider -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }
          $s = Start-Player "$($j.show)"
          if (-not $s.ok -and -not $onMac -and "$($s.error)" -like '*was not found*' -and (Get-Process MarsServerProvider -ErrorAction SilentlyContinue)) {
            $s.nova = $true; $s.error = 'The NovaStar LED-screen software (NovaLCT) is holding the DMX interface. Its USB scanner can be paused while the player runs - NovaLCT starts it again by itself.'
          }
          $s.test = [bool]$TestRoot
          # an Auto Show waiting for ShowXpress carries on on the player (same look)
          if ($s.ok -and (Test-Auto) -and -not $script:autoPl) { $as = Get-AutoStatus; [void](Start-Auto "$(if ($as) { $as.lookId })"); $s.auto = $true }
          # carry on with what ShowXpress was playing (snapshot from /api/lab/snap, taken just before it closed)
          $s.carried = @()
          if ($s.ok -and -not $s.auto -and $script:carry -and ((Get-Date) - $script:carry.at).TotalSeconds -lt 300) {
            foreach ($tt in @($script:carry.titles)) { if (Send-Player "ton $tt") { $s.carried += $tt } }
          }
          if ($s.ok) { $s.list = $j }   # the window redraws its buttons from this: edits saved in ShowXpress show up on every start
          if ($s.ok) { $script:carry = $null; if ($script:pend -and $script:pend.label -eq 'what the SX Player was playing') { $script:pend = $null } }
          Send-Json $ctx $s
        }
        '/api/lab/cmd' {
          if (-not (Test-Player)) { Send-Json $ctx @{ ok = $false; gone = $true; error = 'The SX Player stopped.' }; break }
          $c = "$($body.cmd)"; $line = ''; $err = ''
          if ($c -eq 'press') {
            $b = $script:labMap["$($body.sec)"]; if (-not $b -and "$($body.sec)" -match $xbRx) { $b = $script:labX["$($body.sec)"] }
            if ($b -and "$($b.sec)" -match $xbRx -and $b.kind -eq 'missing') { $err = "The file for $($b.title) is missing." }
            elseif (-not $b -or ("$($b.sec)" -notmatch '^page\d+_button\d+$' -and "$($b.sec)" -notmatch $xbRx)) { $err = 'That button is not in the show any more - press Reload.' }
            else { $line = "press $($b.sec)" }
          }
          elseif ($c -eq 'fader') {
            $k = 0; $v = 0.0
            if (-not [int]::TryParse("$($body.k)", [ref]$k) -or $k -lt 0 -or $k -gt 15 -or -not [double]::TryParse("$($body.v)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $err = 'Bad fader value.' }
            else { $line = "fader $k " + ([math]::Max(0, [math]::Min(1, $v))).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) }
          }
          elseif ($c -eq 'tap' -or $c -eq 'sync') { $line = $c }
          elseif ($c -eq 'bpm') {
            $v = 0.0
            if ([double]::TryParse("$($body.v)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -ge 40 -and $v -le 250) { $line = 'bpm ' + $v.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) }
            else { $err = 'The BPM has to be 40 to 250.' }
          }
          elseif ($c -eq 'key') { $kk = "$($body.key)".ToLower(); if ($kk -match '^[a-z0-9]$') { $line = "key $kk" } else { $err = 'Bad key.' } }
          elseif ($c -eq 'on' -or $c -eq 'off') {
            $b = $script:labMap["$($body.sec)"]; if (-not $b -and "$($body.sec)" -match $xbRx) { $b = $script:labX["$($body.sec)"] }
            if (-not $b -or ("$($b.sec)" -notmatch '^page\d+_button\d+$' -and "$($b.sec)" -notmatch $xbRx)) { $err = 'That button is not in the show any more - press Reload.' }
            elseif ($c -eq 'off') { $line = "off $($b.sec)" }
            elseif ($b.kind -notin 'scex', 'gpj' -or -not (Test-Path -LiteralPath "$($b.path)")) { $err = "The file for $($b.title) is missing." }
            else { $line = "on $($b.sec) $($b.path)" }
          }
          elseif ($c -eq 'alloff') { $line = 'alloff' }
          elseif ($c -eq 'bo') { $line = "bo $(if ($body.on) { 1 } else { 0 })" }
          else { $err = 'Unknown player command.' }
          if ($err) { Send-Json $ctx @{ ok = $false; error = $err }; break }
          if (-not (Send-Player $line)) { Send-Json $ctx @{ ok = $false; gone = $true; error = 'The SX Player stopped.' }; break }
          Send-Json $ctx @{ ok = $true }
        }
        '/api/lab/stop' {
          Stop-Player
          # an Auto Show on the player goes back to ShowXpress (it waits there until ShowXpress is open)
          if ((Test-Auto) -and $script:autoPl) { $as = Get-AutoStatus; [void](Start-Auto "$(if ($as) { $as.lookId })") }
          Send-Json $ctx @{ ok = $true }
        }
        '/api/live/save' {
          # stop the output, write the aims into the aim scene, Apply (size from the Aim tab), run anything queued, reopen ShowXpress
          Stop-Live
          $mo = if ("$($body.mode)" -eq 'room') { 'room' } else { 'floor' }
          $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_changes_' + [guid]::NewGuid().ToString('N') + '.json')
          [IO.File]::WriteAllText($cf, (@{ aims = $body.aims } | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
          try { $r = Invoke-Engine "-Action LiveSave$(if ($mo -eq 'room') { ' -Mode Room' }) -ChangesFile `"$cf`"" } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
          $res = @{ ok = $r.ok; saved = $r.ok; applied = $false; error = "$($r.error)"; out = "$($r.out)"; applyError = '' }
          if ($r.ok -and $body.apply) {
            $r2 = Invoke-Action '/api/apply' ([pscustomobject]@{ w = $body.w; d = $body.d; force = [bool]$body.force; mode = $mo })
            $res.out += "`n" + "$($r2.out)"; $res.applied = [bool]$r2.ok; $res.applyError = "$($r2.error)"
          }
          $script:liveHold = [datetime]::MinValue
          if ($queue.Count) { Invoke-QueueItems $false }
          if ($body.reopen) { $reo = try { Start-Sx } catch { @{ ok = $false; error = $_.Exception.Message } }; $res.reopened = [bool]$reo.ok; $res.reopenError = "$($reo.error)" }
          Send-Json $ctx $res
        }
        '/api/queue/cancel' { $k = "$($body.key)"; foreach ($o in @($queue | Where-Object { $_.key -eq $k -or $k -eq '*' })) { [void]$queue.Remove($o) }; Send-Json $ctx @{ ok = $true; q = (Get-QueueInfo) } }
        '/api/queue/reopen' { $script:qReopen = [bool]$body.on; $st = Get-Settings; $st.reopen = $script:qReopen; Save-Settings $st; Send-Json $ctx @{ ok = $true; q = (Get-QueueInfo) } }
        '/api/settings' { Send-Json $ctx @{ ok = $true; settings = (Get-Settings); ver = $appVer } }
        '/api/settings/set' {
          $st = Get-Settings
          if ($null -ne $body.tabOrder) { $st.tabOrder = @($body.tabOrder | ForEach-Object { "$_" }) }
          if ($null -ne $body.tabHidden) { $st.tabHidden = @($body.tabHidden | ForEach-Object { "$_" }) }
          if ($null -ne $body.tabNames) { $st.tabNames = Get-TabNames $body.tabNames }
          if ($null -ne $body.playerLayout) { $st.playerLayout = Get-PlayerLayout $body.playerLayout }
          $lay = $null -ne $body.playerLayout
          if (-not $fromPhone) {
            if ($null -ne $body.reopen) { $st.reopen = [bool]$body.reopen; $script:qReopen = $st.reopen }
            if ($null -ne $body.autoUpd) { $st.autoUpd = [bool]$body.autoUpd }
            if ($null -ne $body.driveFolder) {
              $d = "$($body.driveFolder)".Trim().Trim('"').TrimEnd('\', '/')
              if ($d -and -not (Test-Path -LiteralPath $d -PathType Container)) { Send-Json $ctx @{ ok = $false; error = "That folder doesn't exist: $d" }; break }
              $st.driveFolder = $d
            }
          }
          Save-Settings $st
          if ($lay) { Sync-PlayerExtras }   # a button added to / changed on one of the player's own pages plays straight away
          Send-Json $ctx @{ ok = $true; settings = (Get-Settings) }
        }
        '/api/config/export' {
          # SX Studio's settings in one file (user 2026-11-25): settings.json, the APC40 pages (apc40.json) and the Auto Show
          # (<show>/auto_show.json). Not the phone pairing key and nothing of the show itself. The page adds this device's look.
          if ($fromPhone) { Send-Json $ctx @{ ok = $false; error = 'Export the settings on the computer.' }; break }
          Send-Json $ctx (Save-ConfigExport $(if ($body) { $body.device } else { $null }))
        }
        '/api/config/import' {
          if ($fromPhone) { Send-Json $ctx @{ ok = $false; error = 'Import the settings on the computer.' }; break }
          Send-Json $ctx (Import-Config $body.data)
        }
        '/api/open' { Send-Json $ctx (Open-OnComputer "$($body.what)") }
        '/api/queue/seen'   { $script:qDone = $null; Send-Json $ctx @{ ok = $true } }
        '/api/sx/launch' { Stop-Player; Send-Json $ctx (Start-Sx) }
        '/api/sx/close' {
          if ($body -and $body.live) { $script:liveHold = Get-Date }   # live aim asked: the queue must not reopen ShowXpress now
          $ps = @(Get-SxProcess)
          if (-not $ps.Count) { Send-Json $ctx @{ ok = $true; out = "  ShowXpress isn't open"; error = ''; none = $true }; break }
          if ($body -and $body.force) {
            # stuck (no window, or it never finished closing): stop it - anything not saved is lost
            foreach ($p in $ps) { try { $p.Kill() } catch {} }
            Start-Sleep -Milliseconds 800
            Send-Json $ctx @{ ok = -not @(Get-SxProcess).Count; out = '  ShowXpress was force closed'; error = 'ShowXpress could not be stopped - restart the computer.' }; break
          }
          if ($onMac) {
            $apps = @($ps | ForEach-Object { if ("$($_.Path)" -match '^(.+?\.app)/') { $Matches[1] } } | Select-Object -Unique)
            if ($ps.Count -and -not $apps.Count) { $a = Find-SxMacApp; if ($a) { $apps = @($a.FullName) } }
            foreach ($ap in $apps) { & osascript -e "tell application `"$ap`" to quit" 2>$null }
          } else {
            foreach ($p in $ps) { [void]$p.CloseMainWindow() }
            # "Do you really want to quit?" gets Yes by itself; "Do you want to save ...?" stays with the user (sx_quit.ps1)
            if (-not $TestRoot -and (Test-Path -LiteralPath $quitEngine)) {
              try { Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$quitEngine`"", '-Pids', (@($ps | ForEach-Object { $_.Id }) -join ','), '-Seconds', '120' } catch {}
            }
          }
          Send-Json $ctx @{ ok = $true; out = '  ShowXpress was asked to close'; error = '' }
        }
        '/api/update'  { if ($req.QueryString['fresh']) { $script:updInfo = $null }; Send-Json $ctx (Get-Update) }
        '/api/update/install' {
          $u = Get-Update
          if (-not $u.ok -or -not $u.newer -or $u.asset -notmatch '^https://github\.com/') { Send-Json $ctx @{ ok = $false; error = 'No newer version found on GitHub.'; out = '' }; break }
          $dl = Join-Path ([IO.Path]::GetTempPath()) ($u.name -replace '[^\w\.-]', '_')
          try { Invoke-WebRequest -Uri $u.asset -OutFile $dl -UseBasicParsing -Headers @{ 'User-Agent' = 'SX-Helper' } -TimeoutSec 300 }
          catch { Send-Json $ctx @{ ok = $false; error = "Download failed: $($_.Exception.Message)"; out = '' }; break }
          if ($onMac) {
            # this server stops and the app quits (it sees the flag); a small script opens the installer, waits for it, then opens the new version
            $tmp = [IO.Path]::GetTempPath()
            $flag = Join-Path $tmp 'sxh_updating'; $us = Join-Path $tmp 'sxh_update.sh'
            [IO.File]::WriteAllText($flag, "$($u.latest)")
            [IO.File]::WriteAllText($us, "sleep 2`nopen -W '$dl'`nsleep 1`nrm -f '$flag'`nopen '/Applications/SX Studio.app'`n")
            & /bin/bash -c "nohup /bin/bash '$us' >/dev/null 2>&1 &"
            Send-Json $ctx @{ ok = $true; restarting = $true; out = ''; error = '' }
            $l.Stop(); break
          }
          # the installer closes this window server itself; a small script waits for it and opens the new version
          $us = Join-Path ([IO.Path]::GetTempPath()) 'sxh_update.ps1'
          $vbs = Join-Path $here 'showxpress_helper.vbs'
          [IO.File]::WriteAllText($us, "Start-Sleep 2`r`nStart-Process -Wait -FilePath '$dl' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART'`r`nStart-Process -FilePath `"`$env:SystemRoot\System32\wscript.exe`" -ArgumentList '`"$vbs`"'`r`n")
          Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$us`"" -WindowStyle Hidden
          Send-Json $ctx @{ ok = $true; restarting = $true; out = ''; error = '' }
          $l.Stop()
        }
        '/api/preview' {
          $mo = if ($req.QueryString['mode'] -eq 'room') { ' -Mode Room' } else { '' }
          Send-EngineJson $ctx (Invoke-Engine "-Action Preview$mo")
        }
        '/api/color'   { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $colorEngine) }
        '/api/gdrive'  { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $gdEngine) }
        '/api/pre/fix' {
          $k = "$($body.key)"
          if ($k -notmatch '^(sleep|usb|restart)$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Fix -FixId $k" $preEngine)
        }
        '/api/skip'    {
          $r = Invoke-Engine '-Action Preview' $skipEngine
          if ($r.ok) { $j = (($r.out -split "`r?`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1); Send-Text $ctx 200 'application/json; charset=utf-8' $j }
          else { Send-Json $ctx @{ ok = $false; error = $r.error } }
        }
        '/api/rig'     { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $rigEngine) }
        '/api/apc'     { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $apcEngine) }
        '/api/speed'   { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $speedEngine) }
        '/api/health'  { Send-EngineJson $ctx (Invoke-Engine '-Action Check' $healthEngine) }
        '/api/health/revert' {
          $i = "$($body.id)"
          if ($i -notmatch '^[0-9a-f]{8}$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          $r = Invoke-Engine "-Action Revert -FixId $i$(if ($body.force) { ' -Force' })" $healthEngine
          $cj = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{"conflict"' } | Select-Object -Last 1 }
          if ($cj) { Send-Json $ctx @{ ok = $true; conflict = @(($cj | ConvertFrom-Json).conflict); out = '' } } else { Send-Json $ctx $r }
        }
        '/api/health/keep' {
          $i = "$($body.id)"
          if ($i -notmatch '^[0-9a-f]{8}$') { Send-Json $ctx @{ ok = $false; error = 'Unknown fix.'; out = '' }; break }
          Send-Json $ctx (Invoke-Engine "-Action Keep -FixId $i" $healthEngine)
        }
        '/api/rt'      { Send-EngineJson $ctx (Invoke-Engine '-Action Preview' $rtEngine) }
        '/api/scenes'  { Send-EngineJson $ctx (Invoke-Engine '-Action List' $sceneEngine) }
        '/api/scene'   {
          $f = "$($req.QueryString['f'])"
          if ($f -notmatch $sceneRx) { Send-Json $ctx @{ ok = $false; error = 'Unknown scene.' }; break }
          Send-EngineJson $ctx (Invoke-Engine "-Action Open -Scene `"$f`"" $sceneEngine)
        }
        '/api/scene/backups' {
          $f = "$($req.QueryString['f'])"
          if ($f -notmatch $sceneRx) { Send-Json $ctx @{ ok = $false; error = 'Unknown scene.' }; break }
          Send-EngineJson $ctx (Invoke-Engine "-Action Backups -Scene `"$f`"" $sceneEngine)
        }
        '/api/scene/revert' {
          $f = "$($body.f)"; $i = "$($body.id)"
          if ($f -notmatch $sceneRx -or $i -notmatch '^\d{8}-\d{6}-\d{3}$') { Send-Json $ctx @{ ok = $false; error = 'Unknown backup.'; out = '' }; break }
          if (Test-SxOpen) { Send-Json $ctx @{ ok = $false; error = 'ShowXpress is open. Close it (save first), then press Revert again.'; out = '' }; break }
          $r = Invoke-Engine "-Action Revert -Scene `"$f`" -Backup $i$(if ($body.force) { ' -Force' })" $sceneEngine
          $cj = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{"conflict"' } | Select-Object -Last 1 }
          if ($cj) { Send-Json $ctx @{ ok = $true; conflict = $true; out = '' } } else { Send-Json $ctx $r }
        }
        '/api/moves'   { Send-EngineJson $ctx (Invoke-Engine '-Action List' $moveEngine) }
        '/api/move'    {
          $f = "$($req.QueryString['f'])"
          if ($f -notmatch $moveRx) { Send-Json $ctx @{ ok = $false; error = 'Unknown movement.' }; break }
          Send-EngineJson $ctx (Invoke-Engine "-Action Open -Move `"$f`"" $moveEngine)
        }
        '/api/move/backups' {
          $f = "$($req.QueryString['f'])"
          if ($f -notmatch $moveRx) { Send-Json $ctx @{ ok = $false; error = 'Unknown movement.' }; break }
          Send-EngineJson $ctx (Invoke-Engine "-Action Backups -Move `"$f`"" $moveEngine)
        }
        '/api/move/revert' {
          $f = "$($body.f)"; $i = "$($body.id)"
          if ($f -notmatch $moveRx -or $i -notmatch '^\d{8}-\d{6}-\d{3}$') { Send-Json $ctx @{ ok = $false; error = 'Unknown backup.'; out = '' }; break }
          if (Test-SxOpen) { Send-Json $ctx @{ ok = $false; error = 'ShowXpress is open. Close it (save first), then press Revert again.'; out = '' }; break }
          $r = Invoke-Engine "-Action Revert -Move `"$f`" -Backup $i$(if ($body.force) { ' -Force' })" $moveEngine
          $cj = if ($r.ok) { ($r.out -split "`r?`n") | Where-Object { $_ -match '^\{"conflict"' } | Select-Object -Last 1 }
          if ($cj) { Send-Json $ctx @{ ok = $true; conflict = $true; out = '' } } else { Send-Json $ctx (Update-MoveScenes $f $r) }
        }
        '/api/looks'   { Send-EngineJson $ctx (Invoke-Engine '-Action Rig' $looksEngine) }
        '/api/looks/make' {
          # ONE-CLICK LOOKS: a NEW scene file - looks.ps1 checks every step and never overwrites a scene (live.ini untouched)
          if ("$($body.name)" -notmatch $sceneRx) { Send-Json $ctx @{ ok = $false; error = 'Give the look a name.'; out = '' }; break }
          $cf = Join-Path ([IO.Path]::GetTempPath()) ('sxh_look_' + [guid]::NewGuid().ToString('N') + '.json')
          [IO.File]::WriteAllText($cf, $raw, (New-Object Text.UTF8Encoding($false)))
          try { Send-Json $ctx (Invoke-Engine "-Action Make -ChangesFile `"$cf`"" $looksEngine) } finally { Remove-Item -LiteralPath $cf -ErrorAction SilentlyContinue }
        }
        '/api/pre'     { Send-EngineJson $ctx (Invoke-Engine '-Action Check' $preEngine) }
        default        { Send-Text $ctx 404 'text/plain' 'not found' }
      }
    } catch {
      try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message; out = '' } } catch {}
    }
  }
} finally {
  Stop-PhoneRelay
  Stop-Live
  Stop-Player
  Stop-Auto
  Stop-Apc40
  Remove-Item -LiteralPath $autoStat, $a40Stat -ErrorAction SilentlyContinue
  try { $l.Close() } catch {}
  if (Test-Path $infoF) { try { $i = Get-Content $infoF -Raw | ConvertFrom-Json; if ($i.pid -eq $PID) { Remove-Item $infoF } } catch {} }
}
