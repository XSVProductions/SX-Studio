# APC40 mk2 - pages of pads for ShowXpress (user 2026-11-25). Windows only.
#
#   The APC mini stays exactly as it is (its pads are learned in ShowXpress). The APC40 is NOT in ShowXpress's MIDI
#   settings at all: this script owns it and presses ShowXpress's buttons through ShowXpress's remote control
#   (the same "External App" connection sx_remote.ps1 uses, TCP 7348, buttons by TITLE).
#
#   Layout = SX Studio's own settings file apc40.json (never a ShowXpress file):
#     { "pages":[ { "name":"Dancefloor", "pads":{ "<0..39>":"<button title>", ... },
#                   "colors":{ "<0..39>":{ "on":<0..127>, "off":<0..127> } } }, ... up to 8 ],   (colors optional)
#       "faders":{ "<1..9>":<master fader index> } }        (fader 9 = the APC40's master fader)
#
#   On the APC40 (verified on the user's unit 2026-11-25):
#     - it is switched to "Ableton Live mode" (sysex) so every button sends a note and the computer drives the lights
#     - grid pads = notes 0..39 on channel 1, 0 = bottom left, 39 = top right
#     - Track Select 1..8 (note 51, channel = column) = pages 1..8; the lit one is the page you're on
#     - a pad press toggles its button (PRESS turns a button on, RELEASE off - both verified); a flash button is held
#     - a pad shows its button's ShowXpress colour: bright while the button is on, dim when off, dark = no button.
#       A pad can have its own colours instead (layout "colors": APC40 palette numbers, playing / idle)
#     - Scene Launch 1 = connection light: green = ShowXpress connected, red = not (closed / remote off)
#     - faders (CC 7 on channel 1..8, master CC 14) move ShowXpress's master faders: a speed fader's middle = normal
#       speed (ShowXpress keeps speed faders at 0 = normal, -100..100), a dimmer fader 0..100
#
#   -Action Run   [-Layout f] [-StatusFile f]   runs until stdin says q (or closes). stdin: q | reload |
#                 pad <n> [up] | sel <1..8> | fader <1..9> <0..127>   (the last three act like the APC40 - for tests)
#   -Action Info                       -> JSON { ok, show, file, layout, buttons:[{title,page,pageName,color,on,off,dup}], faders }
#   -Action Save -ConfigFile f [-Layout f]  checks the layout in f, writes it to the layout file, -> the same JSON as Info
#   -NoMidi       no APC40 (tests: drive it from stdin)
#   The layout file is SX Studio's own (next to settings.json): live.ini, the scenes and ShowXpress's MIDI settings are
#   never written.
param(
  [ValidateSet('Run', 'Info', 'Save')][string]$Action = 'Run',
  [string]$Layout = '',
  [string]$ConfigFile = '',
  [string]$StatusFile = '',
  [switch]$NoMidi,
  [string]$TestRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')
if (-not $Layout) { $Layout = Join-Path $env:APPDATA 'ShowXpress Helper\apc40.json' }

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Concurrent;
public static class Apc40Io {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct InCaps { public ushort wMid, wPid; public uint ver; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public uint sup; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct OutCaps { public ushort wMid, wPid; public uint ver; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public ushort tech, voices, notes, mask; public uint sup; }
  [StructLayout(LayoutKind.Sequential)] struct Hdr { public IntPtr data; public uint len, rec; public IntPtr user; public uint flags; public IntPtr next, res; public uint off; [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public IntPtr[] r2; }
  public delegate void MidiProc(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2);
  [DllImport("winmm")] static extern uint midiInGetNumDevs();
  [DllImport("winmm")] static extern uint midiOutGetNumDevs();
  [DllImport("winmm", CharSet=CharSet.Unicode)] static extern uint midiInGetDevCapsW(IntPtr id, ref InCaps c, uint sz);
  [DllImport("winmm", CharSet=CharSet.Unicode)] static extern uint midiOutGetDevCapsW(IntPtr id, ref OutCaps c, uint sz);
  [DllImport("winmm")] static extern uint midiInOpen(out IntPtr h, uint id, MidiProc cb, IntPtr inst, uint flags);
  [DllImport("winmm")] static extern uint midiInStart(IntPtr h);
  [DllImport("winmm")] static extern uint midiInStop(IntPtr h);
  [DllImport("winmm")] static extern uint midiInReset(IntPtr h);
  [DllImport("winmm")] static extern uint midiInClose(IntPtr h);
  [DllImport("winmm")] static extern uint midiOutOpen(out IntPtr h, uint id, IntPtr cb, IntPtr inst, uint flags);
  [DllImport("winmm")] static extern uint midiOutShortMsg(IntPtr h, uint msg);
  [DllImport("winmm")] static extern uint midiOutPrepareHeader(IntPtr h, IntPtr hdr, uint sz);
  [DllImport("winmm")] static extern uint midiOutUnprepareHeader(IntPtr h, IntPtr hdr, uint sz);
  [DllImport("winmm")] static extern uint midiOutLongMsg(IntPtr h, IntPtr hdr, uint sz);
  [DllImport("winmm")] static extern uint midiOutReset(IntPtr h);
  [DllImport("winmm")] static extern uint midiOutClose(IntPtr h);
  public static ConcurrentQueue<int> Q = new ConcurrentQueue<int>();
  // stdin lines on a thread of their own (Console.In.ReadLineAsync blocks in Windows PowerShell); null = stdin closed
  public static ConcurrentQueue<string> Cmd = new ConcurrentQueue<string>();
  public static void StartStdin() {
    var t = new System.Threading.Thread(() => { try { string l; while ((l = Console.In.ReadLine()) != null) Cmd.Enqueue(l); } catch { } Cmd.Enqueue(null); });
    t.IsBackground = true; t.Start();
  }
  static MidiProc keep; static IntPtr hIn = IntPtr.Zero, hOut = IntPtr.Zero;
  public static bool IsOpen { get { return hIn != IntPtr.Zero; } }
  public static int FindIn(string n) { for (uint i = 0; i < midiInGetNumDevs(); i++) { var c = new InCaps(); if (midiInGetDevCapsW(new IntPtr(i), ref c, (uint)Marshal.SizeOf(c)) == 0 && c.name.Contains(n)) return (int)i; } return -1; }
  public static int FindOut(string n) { for (uint i = 0; i < midiOutGetNumDevs(); i++) { var c = new OutCaps(); if (midiOutGetDevCapsW(new IntPtr(i), ref c, (uint)Marshal.SizeOf(c)) == 0 && c.name.Contains(n)) return (int)i; } return -1; }
  // 0 = ok, -1 = not plugged in, else the Windows error (4 = another program has it)
  public static int Open(string n) {
    Close();
    int i = FindIn(n), o = FindOut(n); if (i < 0 || o < 0) return -1;
    keep = (h, m, inst, p1, p2) => { if (m == 0x3C3) Q.Enqueue((int)(long)p1); };   // MIM_DATA
    uint r = midiInOpen(out hIn, (uint)i, keep, IntPtr.Zero, 0x30000);
    if (r != 0) { hIn = IntPtr.Zero; return (int)r; }
    r = midiOutOpen(out hOut, (uint)o, IntPtr.Zero, IntPtr.Zero, 0);
    if (r != 0) { midiInClose(hIn); hIn = IntPtr.Zero; hOut = IntPtr.Zero; return (int)r; }
    midiInStart(hIn); return 0;
  }
  public static void Send(int st, int d1, int d2) { if (hOut != IntPtr.Zero) midiOutShortMsg(hOut, (uint)(st | (d1 << 8) | (d2 << 16))); }
  public static uint SysEx(byte[] b) {
    if (hOut == IntPtr.Zero) return 1;
    IntPtr buf = Marshal.AllocHGlobal(b.Length); Marshal.Copy(b, 0, buf, b.Length);
    var h = new Hdr(); h.data = buf; h.len = (uint)b.Length; h.rec = (uint)b.Length; h.r2 = new IntPtr[8];
    int sz = Marshal.SizeOf(typeof(Hdr)); IntPtr ph = Marshal.AllocHGlobal(sz); Marshal.StructureToPtr(h, ph, false);
    uint r = midiOutPrepareHeader(hOut, ph, (uint)sz); if (r == 0) r = midiOutLongMsg(hOut, ph, (uint)sz);
    for (int w = 0; w < 100; w++) { var hh = (Hdr)Marshal.PtrToStructure(ph, typeof(Hdr)); if ((hh.flags & 1) != 0) break; System.Threading.Thread.Sleep(5); }
    midiOutUnprepareHeader(hOut, ph, (uint)sz); Marshal.FreeHGlobal(ph); Marshal.FreeHGlobal(buf); return r;
  }
  public static void Close() {
    if (hIn != IntPtr.Zero) { midiInStop(hIn); midiInReset(hIn); midiInClose(hIn); hIn = IntPtr.Zero; }
    if (hOut != IntPtr.Zero) { midiOutReset(hOut); midiOutClose(hOut); hOut = IntPtr.Zero; }
    int x; while (Q.TryDequeue(out x)) { }
  }
}
'@

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
$devName = 'APC40'
$liveMode = [byte[]](0xF0, 0x47, 0x7F, 0x29, 0x60, 0x00, 0x04, 0x41, 0x08, 0x02, 0x01, 0xF7)   # Ableton Live mode

# ---------------------------------------------------------------- colours
# the APC40 mk2 pad palette comes in groups of 4 from 4: pastel, BRIGHT, dim, very dim (4..7 red, 8..11 orange ...)
$groups = @(   # hue (degrees) of the group's bright colour -> group start
  @(0, 4), @(20, 8), @(60, 12), @(95, 16), @(120, 20), @(135, 24), @(150, 28), @(165, 32), @(195, 36), @(215, 40),
  @(240, 44), @(265, 48), @(300, 52), @(335, 56))
function Get-PadColor([string]$hex) {
  # ShowXpress colour (#RRGGBB) -> @(on, off) palette numbers
  if ($hex -notmatch '^#?([0-9a-fA-F]{6})$') { return @(3, 1) }
  $v = [Convert]::ToInt32($matches[1], 16); $r = (($v -shr 16) -band 255) / 255; $g = (($v -shr 8) -band 255) / 255; $b = ($v -band 255) / 255
  $mx = [math]::Max($r, [math]::Max($g, $b)); $mn = [math]::Min($r, [math]::Min($g, $b)); $d = $mx - $mn
  if ($mx -lt 0.08) { return @(3, 1) }   # a black button: white on the pad (dark would look unassigned)
  if ($d / $mx -lt 0.3) { return @(3, 1) }   # white / grey
  $h = if ($mx -eq $r) { 60 * ((($g - $b) / $d) % 6) } elseif ($mx -eq $g) { 60 * ((($b - $r) / $d) + 2) } else { 60 * ((($r - $g) / $d) + 4) }
  if ($h -lt 0) { $h += 360 }
  $best = 4; $bd = 999
  foreach ($gr in $groups) { $dd = [math]::Abs($h - $gr[0]); if ($dd -gt 180) { $dd = 360 - $dd }; if ($dd -lt $bd) { $bd = $dd; $best = $gr[1] } }
  @(($best + 1), ($best + 2))
}

# ---------------------------------------------------------------- state
$st = [ordered]@{ running = $true; pid = $PID; apc = 'starting'; sx = 'starting'; page = 1; pageName = ''; pages = 0; last = ''; error = ''; at = '' }
$lay = $null; $layoutT = [datetime]::MinValue
$page = 0                               # 0-based
$btns = @{}                             # title -> @{ on; flash; color }  (the first button with that title - ShowXpress presses that one)
$faderTypes = @{}                       # master fader index -> 'speed' | 'dimmer'
$sx = $null; $sxNextTry = [datetime]::MinValue; $listAt = [datetime]::MaxValue; $pollAt = [datetime]::MinValue
$apcNextTry = [datetime]::MinValue; $apcCheckAt = [datetime]::MinValue
$led = @{}                              # "status/note" -> value last sent
$held = @{}                             # pad note -> title being held (flash buttons)
$fadPend = @{}; $fadSent = @{}          # fader number -> value to send / when last sent

function Write-Dbg([string]$m) { if ($env:APC40_DEBUG) { [IO.File]::AppendAllText($env:APC40_DEBUG, "$((Get-Date).ToString("HH:mm:ss.fff")) $m`n") } }
function Write-Status {
  if (-not $StatusFile) { return }
  $st.at = (Get-Date).ToString('o'); $st.page = $page + 1
  $st.pages = if ($lay) { @($lay.pages).Count } else { 0 }
  $st.pageName = if ($lay -and $page -lt @($lay.pages).Count) { "$(@($lay.pages)[$page].name)" } else { '' }
  try { [IO.File]::WriteAllText($StatusFile, ($st | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) } catch {}
}
function Read-Layout($from = $null) {
  $j = $from
  if (-not $from) {
    $script:layoutT = if (Test-Path -LiteralPath $Layout) { (Get-Item -LiteralPath $Layout).LastWriteTimeUtc } else { [datetime]::MinValue }
    if (Test-Path -LiteralPath $Layout) { try { $j = [IO.File]::ReadAllText($Layout) | ConvertFrom-Json } catch { $script:st.error = "The APC40 layout file can't be read: $($_.Exception.Message)" } }
  }
  $pages = New-Object Collections.Generic.List[object]
  if ($j -and $j.pages) { foreach ($p in @($j.pages)) { if ($pages.Count -ge 8) { break }
    $pads = @{}; if ($p.pads) { foreach ($q in $p.pads.PSObject.Properties) { $n = -1; if ([int]::TryParse($q.Name, [ref]$n) -and $n -ge 0 -and $n -le 39 -and "$($q.Value)".Trim()) { $pads[$n] = "$($q.Value)".Trim() } } }
    $cols = @{}
    if ($p.colors) { foreach ($q in $p.colors.PSObject.Properties) { $n = -1
      if (-not ([int]::TryParse($q.Name, [ref]$n) -and $pads.ContainsKey($n))) { continue }
      $on = -1; $off = -1
      if (-not ([int]::TryParse("$($q.Value.on)", [ref]$on) -and [int]::TryParse("$($q.Value.off)", [ref]$off))) { continue }
      if ($on -ge 0 -and $on -le 127 -and $off -ge 0 -and $off -le 127) { $cols[$n] = @($on, $off) } } }
    $nm = ("$($p.name)" -replace '[\x00-\x1f]', '').Trim(); if ($nm.Length -gt 30) { $nm = $nm.Substring(0, 30) }
    $pages.Add([pscustomobject]@{ name = $(if ($nm) { $nm } else { "Page $($pages.Count + 1)" }); pads = $pads; colors = $cols }) } }
  if (-not $pages.Count) { $pages.Add([pscustomobject]@{ name = 'Dancefloor'; pads = @{}; colors = @{} }) }
  $fd = @{}
  if ($j -and $j.faders) { foreach ($q in $j.faders.PSObject.Properties) { $n = 0; if ([int]::TryParse($q.Name, [ref]$n) -and $n -ge 1 -and $n -le 9 -and "$($q.Value)" -match '^\d+$') { $fd[$n] = [int]$q.Value } } }
  elseif (-not $j -or $null -eq $j.faders) { for ($k = 1; $k -le 4; $k++) { $fd[$k] = $k - 1 } }   # default: faders 1-4 = master faders 1-4
  $script:lay = [pscustomobject]@{ pages = [object[]]$pages.ToArray(); faders = $fd }
  if ($script:page -ge $pages.Count) { $script:page = 0 }
}

# ---------------------------------------------------------------- ShowXpress
function Get-RemoteSetup {
  $info = Get-LiveInfo $root
  $pw = "$($info.Live['live_mobile_password'])"; $port = 7348
  $pp = Join-Path (Split-Path (Split-Path $root)) 'param.ini'
  if (Test-Path -LiteralPath $pp) { $t = [IO.File]::ReadAllText($pp); if ($t -match '(?m)^LIVEMOBILEPORT = (\d+)') { $port = [int]$matches[1] } }
  $ft = @{}; foreach ($f in $info.Faders) { $ft[[int]$f.k] = $(if ("$($f.type)" -eq '0') { 'dimmer' } else { 'speed' }) }
  $script:faderTypes = $ft
  @{ pw = $pw; port = $port }
}
function Send-Sx([string]$line) {
  if (-not $script:sx) { return $false }
  Write-Dbg ">> $(if ($line -like 'HELLO*') { 'HELLO|...' } else { $line })"
  try { $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $script:sx.s.Write($b, 0, $b.Length); return $true }
  catch { Write-Dbg "send failed: $($_.Exception.Message)"; Close-Sx 'lost'; return $false }
}
function Close-Sx([string]$why) {
  if ($script:sx) { try { $script:sx.c.Close() } catch {} }
  $script:sx = $null; $script:sxNextTry = (Get-Date).AddSeconds(2); $script:st.sx = $why
  foreach ($k in @($script:btns.Keys)) { $script:btns[$k].on = $false }
}
function Open-Sx {
  $script:sxNextTry = (Get-Date).AddSeconds(3)
  if (-not (Test-SxRunning)) { $script:st.sx = 'closed'; Write-Dbg 'ShowXpress not running'; return }
  Write-Dbg 'connecting'
  $rs = Get-RemoteSetup
  if (-not $rs.pw) { $script:st.sx = 'off'; $script:st.error = "ShowXpress's remote control is off - turn it on in SX Studio's Auto Show tab."; return }
  $c = New-Object Net.Sockets.TcpClient
  try { if (-not $c.ConnectAsync('127.0.0.1', $rs.port).Wait(1500)) { throw 'x' } } catch { $c.Close(); $script:st.sx = 'starting'; return }
  $c.NoDelay = $true
  $script:sx = [pscustomobject]@{ c = $c; s = $c.GetStream(); buf = (New-Object Text.StringBuilder); hello = $false; since = Get-Date }
  [void](Send-Sx "HELLO|SX Studio APC40|$($rs.pw)")
}
function Read-SxLines {
  $out = New-Object Collections.Generic.List[string]
  if (-not $script:sx) { return ,$out }
  try {
    if (-not $script:sx.c.Connected) { Close-Sx 'lost'; return ,$out }
    $bytes = New-Object byte[] 262144
    while ($script:sx.s.DataAvailable) {
      $n = $script:sx.s.Read($bytes, 0, $bytes.Length); if ($n -le 0) { Close-Sx 'lost'; return ,$out }
      [void]$script:sx.buf.Append([Text.Encoding]::UTF8.GetString($bytes, 0, $n))
    }
  } catch { Close-Sx 'lost'; return ,$out }
  $t = $script:sx.buf.ToString(); $k = $t.LastIndexOf("`r`n")
  if ($k -ge 0) { [void]$script:sx.buf.Clear(); [void]$script:sx.buf.Append($t.Substring($k + 2)); foreach ($l in ($t.Substring(0, $k) -split "`r`n")) { if ($l) { $out.Add($l) } } }
  ,$out
}
function Read-List([string]$xml) {
  try { [xml]$d = $xml } catch { return }
  $nb = @{}
  foreach ($p in @($d.buttons.page)) { if (-not $p) { continue }
    foreach ($b in @($p.button)) { if (-not $b) { continue }
      $t = "$($b.InnerText)".Trim(); if (-not $t -or $nb.ContainsKey($t)) { continue }
      $nb[$t] = @{ on = ("$($b.pressed)" -eq '1'); flash = ("$($b.flash)" -eq '1'); color = "$($b.color)" } } }
  $script:btns = $nb
}
function Step-Sx {
  $now = Get-Date
  if (-not $script:sx) { if ($now -ge $script:sxNextTry) { Open-Sx }; return }
  foreach ($l in (Read-SxLines)) {
    Write-Dbg "<< $($l.Substring(0, [math]::Min(120, $l.Length)))"
    if ($l -eq 'HELLO') { $script:sx.hello = $true; $script:st.sx = 'ok'; $script:st.error = ''; [void](Send-Sx 'BUTTON_LIST'); continue }
    if ($l -like 'ERROR*') { $script:st.error = "ShowXpress refused the APC40 ($l). Turn the remote on again from SX Studio."; Close-Sx 'refused'; $script:sxNextTry = (Get-Date).AddSeconds(10); return }
    if ($l.StartsWith('BUTTON_LIST|')) { Read-List $l.Substring(12); continue }
    if ($l.StartsWith('BUTTON_PRESS|')) { $t = $l.Substring(13); if ($script:btns.ContainsKey($t)) { $script:btns[$t].on = $true }; $script:listAt = (Get-Date).AddMilliseconds(400); continue }
    if ($l.StartsWith('BUTTON_RELEASE|')) { $t = $l.Substring(15); if ($script:btns.ContainsKey($t)) { $script:btns[$t].on = $false }; continue }
    if ($l -eq 'INTERFACE_CHANGE') { $script:listAt = (Get-Date).AddMilliseconds(300); continue }
    # BEAT_ON / BEAT_OFF / BPM: ShowXpress offering to take beats from us - we have none to give, so nothing is sent
  }
  if (-not $script:sx) { return }
  if (-not $script:sx.hello -and ((Get-Date) - $script:sx.since).TotalSeconds -gt 4) { Close-Sx 'starting'; return }
  if ($script:sx.hello) {
    # the list again a moment after a press (a solo page releases the others) and every 2 s (anything pressed elsewhere)
    if ($now -ge $script:listAt -or $now -ge $script:pollAt) { $script:listAt = [datetime]::MaxValue; $script:pollAt = $now.AddSeconds(2); [void](Send-Sx 'BUTTON_LIST') }
  }
}

# ---------------------------------------------------------------- APC40
function Open-Apc {
  $script:apcNextTry = (Get-Date).AddSeconds(2)
  if ($NoMidi) { $script:st.apc = 'sim'; return }
  $r = [Apc40Io]::Open($devName)
  if ($r -eq -1) { $script:st.apc = 'missing'; return }
  if ($r -ne 0) { $script:st.apc = 'busy'; $script:st.error = $(if ($r -eq 4) { 'Another program has the APC40 - take it out of ShowXpress''s MIDI settings.' } else { "The APC40 can't be opened (error $r)." }); return }
  [void][Apc40Io]::SysEx($liveMode); Start-Sleep -Milliseconds 200
  $script:led = @{}; $script:st.apc = 'ok'; if ($script:st.error -like '*APC40*') { $script:st.error = '' }
}
function Set-Led([int]$status, [int]$note, [int]$v) {
  $k = "$status/$note"
  if ($script:led.ContainsKey($k) -and $script:led[$k] -eq $v) { return }
  $script:led[$k] = $v; if (-not $NoMidi) { [Apc40Io]::Send($status, $note, $v) }
}
function Update-Leds {
  if ($script:st.apc -ne 'ok' -and $script:st.apc -ne 'sim') { return }
  $pg = @($script:lay.pages)[$script:page]; $conn = [bool]($script:sx -and $script:sx.hello)
  for ($n = 0; $n -lt 40; $n++) {
    $v = 0
    if ($pg.pads.ContainsKey($n)) {
      $t = $pg.pads[$n]
      if ($script:btns.ContainsKey($t)) { $b = $script:btns[$t]; $c = if ($pg.colors.ContainsKey($n)) { $pg.colors[$n] } else { Get-PadColor $b.color }; $v = if ($conn -and $b.on) { $c[0] } else { $c[1] } }
      elseif (-not $conn) { $v = 1 }   # not connected yet: assigned pads dim grey
    }
    Set-Led 0x90 $n $v
  }
  $np = @($script:lay.pages).Count
  for ($p = 0; $p -lt 8; $p++) { Set-Led (0x90 + $p) 51 $(if ($p -eq $script:page) { 1 } elseif ($p -lt $np) { 0 } else { 0 }) }
  Set-Led 0x90 82 $(if ($conn) { 21 } else { 5 })
}
function Clear-Leds {
  if ($NoMidi -or -not [Apc40Io]::IsOpen) { return }
  for ($n = 0; $n -lt 40; $n++) { [Apc40Io]::Send(0x90, $n, 0) }
  for ($p = 0; $p -lt 8; $p++) { [Apc40Io]::Send(0x90 + $p, 51, 0) }
  [Apc40Io]::Send(0x90, 82, 0)
}
function Invoke-Pad([int]$n, [bool]$down) {
  $pg = @($script:lay.pages)[$script:page]
  if (-not $down) { if ($script:held.ContainsKey($n)) { $t = $script:held[$n]; $script:held.Remove($n); [void](Send-Sx "BUTTON_RELEASE|$t"); if ($script:btns.ContainsKey($t)) { $script:btns[$t].on = $false } }; return }
  if (-not $pg.pads.ContainsKey($n)) { return }
  $t = $pg.pads[$n]
  if (-not ($script:sx -and $script:sx.hello)) { $script:st.last = "$t - ShowXpress isn't connected"; return }
  if (-not $script:btns.ContainsKey($t)) { $script:st.last = "$t - not in ShowXpress (renamed or removed?)"; return }
  $b = $script:btns[$t]
  if ($b.flash) { [void](Send-Sx "BUTTON_PRESS|$t"); $b.on = $true; $script:held[$n] = $t; $script:st.last = "$t (held)" }
  elseif ($b.on) { [void](Send-Sx "BUTTON_RELEASE|$t"); $b.on = $false; $script:st.last = "$t off" }
  else { [void](Send-Sx "BUTTON_PRESS|$t"); $b.on = $true; $script:st.last = "$t on" }
  $script:listAt = (Get-Date).AddMilliseconds(350)
}
function Set-Page([int]$p) { if ($p -ge 0 -and $p -lt @($script:lay.pages).Count) { $script:page = $p; $script:held = @{} } }
function Invoke-Fader([int]$f, [int]$v) { if ($script:lay.faders.ContainsKey($f)) { $script:fadPend[$f] = $v } }
function Step-Faders {
  if (-not ($script:sx -and $script:sx.hello)) { return }
  foreach ($f in @($script:fadPend.Keys)) {
    if ($script:fadSent.ContainsKey($f) -and ((Get-Date) - $script:fadSent[$f]).TotalMilliseconds -lt 40) { continue }
    $v = $script:fadPend[$f]; $script:fadPend.Remove($f); $script:fadSent[$f] = Get-Date
    $k = $script:lay.faders[$f]
    $x = if ($script:faderTypes[$k] -eq 'dimmer') { [int][math]::Round($v * 100 / 127) } else { [int][math]::Round(($v - 64) * 100 / 63.5) }
    $x = [math]::Max(-100, [math]::Min(100, $x))
    [void](Send-Sx "FADER_CHANGE|$k|$x")
  }
}
function Step-Midi {
  $m = 0
  while ([Apc40Io]::Q.TryDequeue([ref]$m)) {
    $s = $m -band 0xF0; $ch = $m -band 0x0F; $d1 = ($m -shr 8) -band 0x7F; $d2 = ($m -shr 16) -band 0x7F
    $on = ($s -eq 0x90 -and $d2 -gt 0); $off = ($s -eq 0x80 -or ($s -eq 0x90 -and $d2 -eq 0))
    if ($on -or $off) {
      if ($ch -eq 0 -and $d1 -le 39) { Invoke-Pad $d1 $on }
      elseif ($d1 -eq 51 -and $on) { Set-Page $ch }
    } elseif ($s -eq 0xB0) {
      if ($d1 -eq 7) { Invoke-Fader ($ch + 1) $d2 } elseif ($d1 -eq 14 -and $ch -eq 0) { Invoke-Fader 9 $d2 }
    }
  }
}

# ---------------------------------------------------------------- Info / Save (the APC40 tab)
function ConvertTo-LayoutJson {
  [ordered]@{
    pages = @(foreach ($p in @($lay.pages)) { $o = [ordered]@{}; foreach ($n in @($p.pads.Keys | Sort-Object)) { $o["$n"] = $p.pads[$n] }
      $pg = [ordered]@{ name = $p.name; pads = $o }
      if ($p.colors.Count) { $c = [ordered]@{}; foreach ($n in @($p.colors.Keys | Sort-Object)) { $c["$n"] = [ordered]@{ on = $p.colors[$n][0]; off = $p.colors[$n][1] } }; $pg.colors = $c }
      $pg })
    faders = $($o = [ordered]@{}; foreach ($n in @($lay.faders.Keys | Sort-Object)) { $o["$n"] = $lay.faders[$n] }; $o)
  }
}
function Get-Info {
  $info = Get-LiveInfo $root
  $seen = @{}; $bl = New-Object Collections.Generic.List[object]
  foreach ($b in @($info.Buttons | Sort-Object Page, Btn)) {
    $t = "$($b.Title)".Trim(); if (-not $t) { continue }
    $hex = '#FFFFFF'; $c = "$($b.Keys['color'])"; if ($c -match '^-?\d+$') { $hex = '#{0:X6}' -f ([int64]$c -band 0xFFFFFF) }
    $pc = Get-PadColor $hex
    $bl.Add([ordered]@{ title = $t; page = $b.Page; pageName = $b.PageName; color = $hex; on = $pc[0]; off = $pc[1]; dup = $seen.ContainsKey($t) })
    $seen[$t] = $true
  }
  [ordered]@{ ok = $true; show = (Split-Path $root -Leaf); file = $Layout; layout = (ConvertTo-LayoutJson); buttons = $bl
              faders = @(foreach ($f in $info.Faders) { [ordered]@{ k = $f.k; caption = $f.caption; type = $(if ("$($f.type)" -eq '0') { 'dimmer' } else { 'speed' }) } }) }
}
if ($Action -ne 'Run') {
  try {
    if ($Action -eq 'Save') {
      $j = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
      if (-not $j -or -not $j.pages) { throw 'Nothing to save.' }
      $st.error = ''; Read-Layout $j
      $d = Split-Path $Layout; if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
      [IO.File]::WriteAllText($Layout, ((ConvertTo-LayoutJson) | ConvertTo-Json -Depth 7), (New-Object Text.UTF8Encoding($false)))
    } else { Read-Layout }
    (Get-Info) | ConvertTo-Json -Depth 8 -Compress
  } catch { [ordered]@{ ok = $false; error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress }
  exit 0
}

# ---------------------------------------------------------------- run
Read-Layout
Write-Dbg "start apc=$($st.apc) pages=$(@($lay.pages).Count)"
[Apc40Io]::StartStdin()
$statusAt = [datetime]::MinValue
try {
  while ($true) {
    $now = Get-Date
    # stdin: commands from SX Studio (q = stop); stdin closed = SX Studio is gone -> stop
    $cmd = ''; $quit = $false
    while ([Apc40Io]::Cmd.TryDequeue([ref]$cmd)) {
      if ($null -eq $cmd) { $quit = $true; break }
      Write-Dbg "stdin: $cmd"
      $a = @("$cmd".Trim() -split '\s+')
      if ($a[0] -eq 'q') { $quit = $true; break }
      if ($a[0] -eq 'reload') { Read-Layout }
      elseif ($a[0] -eq 'pad' -and $a.Count -ge 2) { Invoke-Pad ([int]$a[1]) (-not ($a.Count -ge 3 -and $a[2] -eq 'up')) }
      elseif ($a[0] -eq 'sel' -and $a.Count -ge 2) { Set-Page ([int]$a[1] - 1) }
      elseif ($a[0] -eq 'fader' -and $a.Count -ge 3) { Invoke-Fader ([int]$a[1]) ([int]$a[2]) }
    }
    if ($quit) { break }
    if ($now -ge $apcCheckAt) {
      $apcCheckAt = $now.AddSeconds(2)
      if ((Test-Path -LiteralPath $Layout) -and (Get-Item -LiteralPath $Layout).LastWriteTimeUtc -ne $layoutT) { Read-Layout }
      if (-not $NoMidi -and $st.apc -eq 'ok' -and [Apc40Io]::FindIn($devName) -lt 0) { [Apc40Io]::Close(); $st.apc = 'missing' }   # unplugged
    }
    if ($st.apc -ne 'ok' -and $st.apc -ne 'sim' -and $now -ge $apcNextTry) { Open-Apc }
    elseif ($st.apc -eq 'starting') { Open-Apc }
    if ($st.apc -eq 'ok') { Step-Midi }
    # ShowXpress only while this copy has the APC40 (no long connection to ShowXpress for nothing)
    if ($st.apc -eq 'ok' -or $st.apc -eq 'sim') { Step-Sx } elseif ($sx) { Close-Sx 'waiting' } else { $st.sx = 'waiting' }
    Step-Faders
    Update-Leds
    if ($now -ge $statusAt) { $statusAt = $now.AddMilliseconds(500); Write-Status }
    Start-Sleep -Milliseconds 10
  }
} finally {
  try { Clear-Leds } catch {}
  try { [Apc40Io]::Close() } catch {}
  if ($sx) { try { $sx.c.Close() } catch {} }
  $st.running = $false; $st.apc = 'stopped'; Write-Status
}
