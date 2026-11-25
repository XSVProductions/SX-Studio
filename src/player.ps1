# SX PLAYER (stage 1+2, user 2026-11-23) - the Helper plays the show's scenes itself, straight to the DMX interface, with
# ShowXpress closed. Started by df_aim_gui.ps1 (Lab tab) as a child process, like dmx_out.ps1 (Aim live).
#
#   Stage 1 = scenes (.scex): steps, step lengths (1/100 s), fades, looping chases.
#   Stage 2 = movements (.gpj, the Generator): only the sections ticked "Selected" drive channels, so a movement
#     layers over a colour scene. [Pan/Tilt/uPan/uTilt] = a closed path of 16-bit pan,tilt points gone round once per
#     Duration (1/10 s), each point the same time; Transition 0 = jump point to point, 1 = straight lines, 2 = smooth
#     curve through every point (closed cardinal spline, tangents 0.75 - checked against ShowXpress's Art-Net output).
#     Every other section (color, gobo, dimmer, zoom ...) = a graph of points "x,y": x = where in the cycle (0..65535),
#     y = value (0..65535, DMX = y / 256); same Transitions; its own Duration.
#     Per head ([Fixture_n]): Zoom (size around the path's centre, factor (1+Z/100)^2), Offset, Reverse (65535 - v).
#     Shift (% of a cycle) = the n-th head in the list runs n x Shift behind the first.
#   GUESSES, TO CHECK against ShowXpress's own output: the Shift direction (later heads lag), y/256 for values,
#     equal time per pan/tilt point (not equal distance), [Params] ignored (all 0 in this show).
#   Stage 3 = the live board: the show's buttons (live.ini) are loaded at start. "press" toggles a button; on a page
#     with swap = yes (MOVEMENTS) pressing one releases the others on that page. Speed faders ([master_faders]
#     type 1, button masterspeedfader = K) scale that button's clock: fader at the middle = normal speed, top = 4x,
#     bottom = 1/4x (GUESS, to check against ShowXpress); faders start at the middle until moved.
#     APC mini (param.ini MIDIINDEVICE / MIDIOUTDEVICE): a pad = the button whose trigger_midi_* matches; the pad light
#     shows trigger_midiout_data when the button plays, _data_off when not (sent at start too); fader CCs from
#     [live] faderN_midi_*. Keyboard keys (trigger_keyboard) come from the Lab window. Dimmer faders (type 0) and
#     flash buttons aren't in (the show has none).
#   Stage 4 = the beat. One beat clock: the BPM (start = auto_show.json's BPM, else 120), set by "bpm", by "tap"
#     (the average of the last taps; one tap after a pause only moves the beat), or by VirtualDJ: OS2L (param.ini
#     OS2LENABLE / OS2LPORT, announced with Bonjour as _os2l._tcp like ShowXpress does) - every beat VirtualDJ sends
#     is a beat here, with its BPM; when VirtualDJ goes quiet the clock carries on by itself at the last BPM.
#     BPM buttons (live.ini speed = auto_bpm): step mode = one step per beat (x the button's "beats", e.g. 0.25 =
#     4 steps a beat), fades take the whole step, the steps' own lengths are ignored; flash mode (bpm_trigger =
#     flash_mode, "run from step 1") = every beat the scene starts again from step 1 and runs once at its own step
#     lengths, holding the last step. On a BPM button the speed fader picks /4 /2 x1 x2 x4 (GUESS, to check).
#     "sync" = now is beat 1 (BPM chases start again from their first step). OS2L "btn" messages press buttons by title.
#     Auto Show: -Pipe <name> = a named pipe (this user only) that takes ton / toff / bpm / sync / tap lines, so the
#     Auto Show (sx_remote.ps1 -Action Auto -Pipe) can play its looks here instead of in ShowXpress.
#   Stage 5 = gig-ready. Show check at start: every button's file is loaded once (problems -> "warn" in the status,
#     and the first press of each is instant). The laptop is kept awake (no sleep, screen on) while the player runs.
#     DMX interface unplugged (Windows device gone; test copy: marker file _iface_unplugged): "iface":"lost", nothing
#     is sent, the show keeps counting; plugged back in -> the interface is opened again by itself ("reconn" + 1).
#   The show files are played exactly as they are (Reversed heads are already in them).
#   Patch: fixtures.ini  (DMX channel = fixture address + channel index; a .gpj head is found by its fixture ID).
#   How it plays (TO CHECK against ShowXpress's own output in stage 2):
#     - a scene loops through its steps; a channel marked fade="1" glides from the step before to this step's value
#       over the step's length (the very first step glides from what the light was doing when it was pressed)
#     - several buttons on: the one pressed LAST wins on every channel it uses; button off = its channels go back to
#       whatever else is on, or 0
#   First line printed:  "OK <interface name>"  or  "ERR <why>".
#   Then reads commands from stdin, one per line:
#     on <slot> <file path>           start (or restart) a scene (.scex) or movement (.gpj); slot = a name without spaces
#     off <slot>      alloff      bo 1 | bo 0  (blackout on / off)      k  (keep-alive)      q  (quit)
#     press <button section>   toggle a live button (swap pages release the rest of the page)
#     fader <k> <0..1>         set speed fader k          key <c>   a keyboard trigger
#     mi <status> <d1> <d2>    a MIDI message as if it came from the APC (tests)
#     bpm <40..250>   tap   sync      seton <sec> / setoff <sec>   ton <title> / toff <title>  (on/off, not toggle)
#     addb <sec>|<group>|<swap 0/1>|<fader>|<bpm 0/1>|<flash 0/1>|<beats>|<file path>|<title>   add (or replace) a button
#       that isn't in live.ini: a button on one of the SX Player's own pages (user 2026-11-24). group = the page it swaps
#       with (1000 + the player page's number, so it never meets a ShowXpress page). No pad, no key.
#     delb <sec>    take such a button away again (it stops if it was playing)
#   Status (-StatusFile, rewritten 5x a second): {"ok":true,"bo":false,"on":[{"slot":..,"step":1,"of":4}],"err":"",
#     "fd":[0.5,..],"midi":"APC mini mk2" or "","led":{"note":value,..},"bpm":124,"beat":37.25,"src":"manual|tap|VirtualDJ",
#     "os2l":"<VirtualDJ's address, when connected>","os2lPort":7350,"os2lErr":"","iface":"ok|lost","reconn":0,"warn":[..]}
#   Safety: no command for 30 s (Helper gone) or stdin closed -> all channels 0, interface closed, exit.
#   -Fake = no hardware (testing): the frame goes to -FakeLog as "ch=value" lines for channels above 0.
#   -DefineOnly = just load the player code (tests dot-source this file and drive [SxPlayer] with their own clock).
#   -List = (no DMX) JSON of the show's live pages + buttons for the Lab tab: {ok, show, pages:[{n,name,buttons:[..]}],
#     files:[scene / movement file names the SX Player's own pages can use]}
param([string]$Show = '', [string]$DllDir = "$env:ProgramFiles\ShowXpress", [switch]$Fake, [string]$FakeLog = '',
      [string]$StatusFile = '', [switch]$DefineOnly, [switch]$List, [string]$TestRoot = '', [switch]$NoMidi, [string]$Pipe = '')
$ErrorActionPreference = 'Stop'
function Get-PageSwap($info, [int]$pg) {
  foreach ($s in $info.Sections) { if ($s[0] -eq "page$pg") { return ("$($s[1]['swap'])" -eq 'yes') } }
  $false
}
if ($List) {
  . (Join-Path $PSScriptRoot 'show_common.ps1')
  $root = if ($TestRoot) { $TestRoot } else { Find-Show }
  $info = Get-LiveInfo $root
  $pages = foreach ($pg in @($info.Pages.Keys | Sort-Object)) {
    $bs = foreach ($b in @($info.Buttons | Where-Object { $_.Page -eq $pg } | Sort-Object { [int]"0$($_.Keys['line'])" }, { [int]"0$($_.Keys['column'])" })) {
      $p = Get-ScenePath $root $b.Name
      $kind = if (-not $p) { 'missing' } elseif ($p -like '*.gpj') { 'gpj' } else { 'scex' }
      $steps = 0; if ($kind -eq 'scex') { $steps = [regex]::Matches([IO.File]::ReadAllText($p), '<Step[ >]').Count }
      $c = -1; if ("$($b.Keys['color'])" -match '^\d+$') { $c = [int64]$b.Keys['color'] }
      [pscustomobject]@{ sec = $b.Sec; title = $(if ($b.Title) { $b.Title } else { $b.Name -replace '\.(scex|gpj)$', '' }); file = $b.Name; path = "$p"; kind = $kind; steps = $steps
        line = [int]"0$($b.Keys['line'])"; col = [int]"0$($b.Keys['column'])"; color = $c; bpm = ("$($b.Keys['speed'])" -eq 'auto_bpm')
        fader = [int]"0$($b.Keys['masterspeedfader'])"; key = "$($b.Keys['trigger_keyboard'])"; flash = ("$($b.Keys['bpm_trigger'])" -eq 'flash_mode')
        beats = $(& { $bt = 1.0; [void][double]::TryParse("$($b.Keys['beats'])", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$bt); $bt }); pad = $(if ("$($b.Keys['trigger_midi_note'])" -match '^\d+$' -and "$($b.Keys['trigger_midi_device'])" -match '^0?$') { [int]$b.Keys['trigger_midi_note'] } else { -1 }) }
    }
    [pscustomobject]@{ n = $pg; name = $info.Pages[$pg]; swap = (Get-PageSwap $info $pg); buttons = @($bs) }
  }
  # every scene + movement a button on one of the player's own pages can play (only read, never changed)
  $files = @(@(if (Test-Path -LiteralPath "$root/scenes") { Get-ChildItem -LiteralPath "$root/scenes" -File | Where-Object { $_.Extension -in '.scex', '.gpj' } }) +
             @(if (Test-Path -LiteralPath "$root/Editor/Generator/projects") { Get-ChildItem -LiteralPath "$root/Editor/Generator/projects" -File -Filter '*.gpj' }) |
             ForEach-Object { $_.Name } | Sort-Object -Unique)
  [pscustomobject]@{ ok = $true; show = $root; pages = @($pages); faders = @($info.Faders); files = @($files) } | ConvertTo-Json -Depth 5 -Compress
  return
}
if (-not ('SxPlayer' -as [type])) {
$sxCs = @"
using System; using System.Collections.Generic; using System.Diagnostics; using System.IO; using System.Runtime.InteropServices;
using System.Text; using System.Threading; using System.Xml; using System.Collections.Concurrent;
using System.Net; using System.Net.Sockets; using System.IO.Pipes;
public static class SxPlayer {
  [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern bool SetDllDirectory(string p);
  [DllImport("winmm")] static extern uint timeBeginPeriod(uint ms);
  [DllImport("efk_hardware.dll")] static extern long EFK_check_hardware();
  [DllImport("efk_hardware.dll")] static extern long EFK_open();
  [DllImport("efk_hardware.dll")] static extern long EFK_close();
  [DllImport("efk_hardware.dll")] static extern long EFK_stream_mode();
  [DllImport("efk_hardware.dll")] static extern IntPtr EFK_get_name_of_interfaces();
  [DllImport("efk_hardware.dll")] static extern long EFK_send_dmx(byte[] buf);
  public const int N = 512 * 16;
  [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] static extern int CM_Locate_DevNodeW(out uint inst, string id, int flags);
  [DllImport("kernel32")] static extern uint SetThreadExecutionState(uint f);

  // ---------------------------------------------------------------- gig safety (stage 5)
  static string devId = "", devFile = "", ifName = "";
  static volatile bool lost;
  public static int Reconnects = 0;
  static List<string> warns = new List<string>();
  public static void Warn(string w) { lock (lk) { if (warns.Count < 40) warns.Add(w); } }
  public static int CheckShow() {   // load every button's file once: problems -> warnings, and the first press is instant
    List<Btn> all; lock (lk) { all = new List<Btn>(btns.Values); }
    HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); int n = 0;
    foreach (Btn b in all) {
      if (b.Path == "") { Warn(b.Title + ": its file is missing"); n++; continue; }
      if (!seen.Add(b.Path)) continue;
      try {
        int u = b.Path.EndsWith(".gpj", StringComparison.OrdinalIgnoreCase) ? LoadMove(b.Path).Unpatched : Load(b.Path).Unpatched;
        if (u > 0) { Warn(b.Title + ": " + u + " light(s) in it are not in the show's fixture list"); n++; }
      } catch (Exception e) { Warn(b.Title + ": " + e.Message); n++; }
    }
    return n;
  }
  public static void WatchDevice(string id, string file) { devId = id ?? ""; devFile = file ?? ""; }
  static bool Present() {
    if (devFile != "") return !File.Exists(devFile);
    if (devId == "") return true;
    try { uint d; return CM_Locate_DevNodeW(out d, devId, 0) == 0; } catch { return true; }
  }
  static bool Reopen() {   // the interface came back: open it again
    if (fake) return true;
    try { if (opened) EFK_close(); } catch { }
    opened = false; Thread.Sleep(300);
    try {
      EFK_check_hardware();
      string n = Marshal.PtrToStringUni(EFK_get_name_of_interfaces());
      if (n == null || n.Trim('|', ' ') == "" || n.StartsWith("err")) return false;
      EFK_open(); EFK_stream_mode(); opened = true; return true;
    } catch { return false; }
  }

  // ---------------------------------------------------------------- MIDI (winmm)
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct MidiInCaps { public ushort wMid, wPid; public uint ver;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public uint support; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct MidiOutCaps { public ushort wMid, wPid; public uint ver;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public ushort tech, voices, notes, mask; public uint support; }
  delegate void MidiProc(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2);
  [DllImport("winmm")] static extern uint midiInGetNumDevs();
  [DllImport("winmm")] static extern uint midiOutGetNumDevs();
  [DllImport("winmm", CharSet=CharSet.Unicode)] static extern uint midiInGetDevCapsW(IntPtr id, ref MidiInCaps c, uint sz);
  [DllImport("winmm", CharSet=CharSet.Unicode)] static extern uint midiOutGetDevCapsW(IntPtr id, ref MidiOutCaps c, uint sz);
  [DllImport("winmm")] static extern uint midiInOpen(out IntPtr h, uint id, MidiProc cb, IntPtr inst, uint flags);
  [DllImport("winmm")] static extern uint midiInStart(IntPtr h);
  [DllImport("winmm")] static extern uint midiInStop(IntPtr h);
  [DllImport("winmm")] static extern uint midiInReset(IntPtr h);
  [DllImport("winmm")] static extern uint midiInClose(IntPtr h);
  [DllImport("winmm")] static extern uint midiOutOpen(out IntPtr h, uint id, IntPtr cb, IntPtr inst, uint flags);
  [DllImport("winmm")] static extern uint midiOutShortMsg(IntPtr h, uint msg);
  [DllImport("winmm")] static extern uint midiOutClose(IntPtr h);
  static IntPtr midiIn = IntPtr.Zero, midiOut = IntPtr.Zero;
  static MidiProc midiCb;   // kept so the GC never collects the callback
  static BlockingCollection<int> midiQ = new BlockingCollection<int>();
  public static string MidiName = "";
  static void OnMidi(IntPtr h, uint msg, IntPtr inst, IntPtr p1, IntPtr p2) { if (msg == 0x3C3) midiQ.Add((int)(p1.ToInt64() & 0xFFFFFF)); }   // MIM_DATA
  static bool NameIs(string have, string want) { return have != null && want != "" && (have.Trim().Equals(want.Trim(), StringComparison.OrdinalIgnoreCase) || have.IndexOf(want.Trim(), StringComparison.OrdinalIgnoreCase) >= 0); }
  public static string OpenMidi(string inName, string outName) {
    string why = "";
    if (inName != "") {
      for (uint i = 0; i < midiInGetNumDevs(); i++) {
        MidiInCaps c = new MidiInCaps(); if (midiInGetDevCapsW(new IntPtr(i), ref c, (uint)Marshal.SizeOf(c)) != 0 || !NameIs(c.name, inName)) continue;
        midiCb = OnMidi; IntPtr h;
        if (midiInOpen(out h, i, midiCb, IntPtr.Zero, 0x30000) == 0) { midiIn = h; midiInStart(h); MidiName = c.name.Trim(); } else why = c.name + " is busy";
        break;
      }
      if (midiIn == IntPtr.Zero && why == "") why = inName + " is not plugged in";
    }
    if (outName != "") {
      for (uint i = 0; i < midiOutGetNumDevs(); i++) {
        MidiOutCaps c = new MidiOutCaps(); if (midiOutGetDevCapsW(new IntPtr(i), ref c, (uint)Marshal.SizeOf(c)) != 0 || !NameIs(c.name, outName)) continue;
        IntPtr h; if (midiOutOpen(out h, i, IntPtr.Zero, IntPtr.Zero, 0) == 0) midiOut = h;
        break;
      }
    }
    return why;
  }
  static void CloseMidi() {
    if (midiIn != IntPtr.Zero) { midiInStop(midiIn); midiInReset(midiIn); midiInClose(midiIn); midiIn = IntPtr.Zero; }
    if (midiOut != IntPtr.Zero) { midiOutClose(midiOut); midiOut = IntPtr.Zero; }
  }

  // ---------------------------------------------------------------- patch + scenes
  static Dictionary<string, int> addr = new Dictionary<string, int>();   // fixture id -> DMX address (1-based)
  public static void Patch(string id, int a) { addr[id] = a; }
  public static void ClearPatch() { addr.Clear(); }

  public class Scene {
    public string Path; public DateTime Stamp;
    public int[] Len;        // step length in ms (at least 10)
    public int Total;        // all steps, ms
    public int[] Chans;      // DMX channel (0-based) of each used channel
    public byte[][] Val;     // [step][chan]
    public bool[][] Fade;    // [step][chan]
    public int Unpatched;    // fixtures in the scene that aren't in fixtures.ini
  }
  static Dictionary<string, Scene> cache = new Dictionary<string, Scene>(StringComparer.OrdinalIgnoreCase);

  public static Scene Load(string path) {
    DateTime st = File.GetLastWriteTimeUtc(path);
    Scene c;
    if (cache.TryGetValue(path, out c) && c.Stamp == st) return c;
    XmlDocument x = new XmlDocument(); x.Load(path);
    XmlNodeList steps = x.SelectNodes("/Scene/Steps/Step");
    int ns = steps.Count; if (ns == 0) throw new Exception("the scene has no steps");
    Dictionary<int, int> col = new Dictionary<int, int>(); List<int> chans = new List<int>();
    List<Dictionary<int, int>> sv = new List<Dictionary<int, int>>(); List<Dictionary<int, bool>> sf = new List<Dictionary<int, bool>>();
    HashSet<string> unp = new HashSet<string>();
    int[] len = new int[ns]; int total = 0;
    for (int i = 0; i < ns; i++) {
      XmlElement s = (XmlElement)steps[i]; int cs;
      if (!int.TryParse(s.GetAttribute("length"), out cs)) cs = 100;
      len[i] = Math.Max(10, cs * 10); total += len[i];
      Dictionary<int, int> v = new Dictionary<int, int>(); Dictionary<int, bool> f = new Dictionary<int, bool>();
      foreach (XmlElement fx in s.SelectNodes("Fixture")) {
        string id = fx.GetAttribute("id"); int a;
        if (!addr.TryGetValue(id, out a)) { unp.Add(id); continue; }
        foreach (XmlElement ch in fx.SelectNodes("Channel")) {
          int ix, val; if (!int.TryParse(ch.GetAttribute("index"), out ix) || !int.TryParse(ch.GetAttribute("value"), out val)) continue;
          int d = a - 1 + ix; if (d < 0 || d >= N) continue;
          if (!col.ContainsKey(d)) { col[d] = chans.Count; chans.Add(d); }
          v[d] = Math.Max(0, Math.Min(255, val)); f[d] = ch.GetAttribute("fade") == "1";
        }
      }
      sv.Add(v); sf.Add(f);
    }
    c = new Scene(); c.Path = path; c.Stamp = st; c.Len = len; c.Total = total; c.Chans = chans.ToArray(); c.Unpatched = unp.Count;
    c.Val = new byte[ns][]; c.Fade = new bool[ns][];
    for (int i = 0; i < ns; i++) {
      c.Val[i] = new byte[chans.Count]; c.Fade[i] = new bool[chans.Count];
      for (int k = 0; k < chans.Count; k++) {
        int d = chans[k], v;
        // a channel missing from a step keeps the step before's value (the show's chases always have every channel)
        if (sv[i].TryGetValue(d, out v)) { c.Val[i][k] = (byte)v; c.Fade[i][k] = sf[i][d]; }
        else c.Val[i][k] = i > 0 ? c.Val[i - 1][k] : (byte)0;
      }
    }
    cache[path] = c; return c;
  }

  // ---------------------------------------------------------------- movements (.gpj)
  public class Sec { public string Name; public int Tr = 2; public double Dur = 20000; public double Shift; public double[] X, Y; }
  public class Head { public int A0; public int K; public Dictionary<string, int> Ix = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    public bool RP, RT; public double OP, OT, ZP = 1, ZT = 1; }
  public class Move {
    public string Path; public DateTime Stamp; public Sec PT; public List<Sec> Vals = new List<Sec>(); public List<Head> Heads = new List<Head>();
    public double Cx, Cy; public int Unpatched; public int Points;
  }
  static Dictionary<string, Move> mcache = new Dictionary<string, Move>(StringComparer.OrdinalIgnoreCase);
  static double D(Dictionary<string, string> s, string k, double def) {
    string v; double d; return s.TryGetValue(k, out v) && double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d) ? d : def;
  }

  public static Move LoadMove(string path) {
    DateTime st = File.GetLastWriteTimeUtc(path);
    Move m;
    if (mcache.TryGetValue(path, out m) && m.Stamp == st) return m;
    // the .gpj is an ini file: [section] then "key = value"
    List<KeyValuePair<string, Dictionary<string, string>>> secs = new List<KeyValuePair<string, Dictionary<string, string>>>();
    Dictionary<string, string> cur = null;
    foreach (string raw in File.ReadAllLines(path)) {
      string l = raw.Trim().TrimStart('\uFEFF');
      if (l.StartsWith("[") && l.EndsWith("]")) { cur = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); secs.Add(new KeyValuePair<string, Dictionary<string, string>>(l.Substring(1, l.Length - 2), cur)); continue; }
      int e = l.IndexOf(" = "); if (cur == null || e < 1) continue;
      cur[l.Substring(0, e).Trim()] = l.Substring(e + 3).Trim();
    }
    m = new Move(); m.Path = path; m.Stamp = st;
    HashSet<string> unp = new HashSet<string>();
    foreach (KeyValuePair<string, Dictionary<string, string>> kv in secs) {
      string name = kv.Key; Dictionary<string, string> s = kv.Value;
      if (name.StartsWith("Fixture_")) {
        string id; int a, k;
        if (!s.TryGetValue("ID", out id)) continue;
        if (!addr.TryGetValue(id, out a)) { unp.Add(id); continue; }
        Head h = new Head(); h.A0 = a - 1; h.K = int.TryParse(name.Substring(8), out k) ? k : m.Heads.Count;
        string chs; if (s.TryGetValue("Channels", out chs)) { string[] cs = chs.Split(','); for (int i = 0; i < cs.Length; i++) { string c = cs[i].Trim(); if (c != "" && !h.Ix.ContainsKey(c)) h.Ix[c] = i; } }
        h.RP = D(s, "ReversePan", 0) != 0; h.RT = D(s, "ReverseTilt", 0) != 0;
        h.OP = D(s, "OffsetPan", 0); h.OT = D(s, "OffsetTilt", 0);
        h.ZP = Math.Pow(1 + D(s, "ZoomPan", 0) / 100.0, 2); h.ZT = Math.Pow(1 + D(s, "ZoomTilt", 0) / 100.0, 2);
        m.Heads.Add(h); continue;
      }
      if (name == "Params" || D(s, "Selected", 0) == 0) continue;
      List<KeyValuePair<int, double[]>> pts = new List<KeyValuePair<int, double[]>>();
      foreach (KeyValuePair<string, string> e in s) {
        int n; if (!e.Key.StartsWith("Point_") || !int.TryParse(e.Key.Substring(6), out n)) continue;
        string[] xy = e.Value.Split(','); double x, y;
        if (xy.Length == 2 && double.TryParse(xy[0], out x) && double.TryParse(xy[1], out y)) pts.Add(new KeyValuePair<int, double[]>(n, new double[] { x, y }));
      }
      if (pts.Count == 0) continue;
      pts.Sort((p, q) => p.Key.CompareTo(q.Key));
      Sec sc = new Sec(); sc.Name = name; sc.Tr = (int)D(s, "Transition", 2); sc.Dur = Math.Max(100, D(s, "Duration", 200) * 100); sc.Shift = D(s, "Shift", 0);
      sc.X = new double[pts.Count]; sc.Y = new double[pts.Count];
      for (int i = 0; i < pts.Count; i++) { sc.X[i] = pts[i].Value[0]; sc.Y[i] = pts[i].Value[1]; }
      if (name == "Pan/Tilt/uPan/uTilt") m.PT = sc;
      else {   // a value graph: in cycle order
        int[] o = new int[sc.X.Length]; for (int i = 0; i < o.Length; i++) o[i] = i;
        double[] xs = sc.X; Array.Sort((double[])xs.Clone(), o);
        double[] X2 = new double[o.Length], Y2 = new double[o.Length];
        for (int i = 0; i < o.Length; i++) { X2[i] = sc.X[o[i]]; Y2[i] = sc.Y[o[i]]; }
        sc.X = X2; sc.Y = Y2; m.Vals.Add(sc);
      }
    }
    if (m.Heads.Count == 0) throw new Exception(unp.Count > 0 ? "none of its heads are in the show's fixture list" : "it has no heads");
    if (m.PT == null && m.Vals.Count == 0) throw new Exception("nothing in it is ticked to play");
    if (m.PT != null) {
      double x0 = double.MaxValue, x1 = double.MinValue, y0 = double.MaxValue, y1 = double.MinValue;
      for (int i = 0; i < m.PT.X.Length; i++) { x0 = Math.Min(x0, m.PT.X[i]); x1 = Math.Max(x1, m.PT.X[i]); y0 = Math.Min(y0, m.PT.Y[i]); y1 = Math.Max(y1, m.PT.Y[i]); }
      m.Cx = (x0 + x1) / 2; m.Cy = (y0 + y1) / 2; m.Points = m.PT.X.Length;
    }
    m.Unpatched = unp.Count;
    mcache[path] = m; return m;
  }

  static double Frac(double v) { return v - Math.Floor(v); }
  static double CR(double p0, double p1, double p2, double p3, double t) {
    return 0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t);
  }
  // the pan/tilt curve: like Catmull-Rom but with tangents 0.75 x (next - previous) instead of 0.5. Measured 2026-11-23 on
  // ShowXpress's own Art-Net output (AROUND ROOM / FIGURE 8 / ZIG ZAG): 0.75 fits to ~10/65535, 0.5 swung ~9% short.
  const double PtTension = 0.75;
  static double Card(double p0, double p1, double p2, double p3, double t) {
    double m1 = PtTension * (p2 - p0), m2 = PtTension * (p3 - p1), t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * p2 + (t3 - t2) * m2;
  }
  static int C16(double v) { return (int)Math.Max(0, Math.Min(65535, Math.Round(v))); }
  static void Put(byte[] f, Head h, string ch, int v) { int ix; if (h.Ix.TryGetValue(ch, out ix)) { int d = h.A0 + ix; if (d >= 0 && d < N) f[d] = (byte)Math.Max(0, Math.Min(255, v)); } }
  static double ValAt(Sec v, double x) {   // value graph at x (0..65535)
    int n = v.X.Length; if (n == 1 || x <= v.X[0]) return v.Y[0];
    if (x >= v.X[n - 1]) return v.Y[n - 1];
    int j = 0; while (j < n - 2 && x >= v.X[j + 1]) j++;
    if (v.Tr == 0) return v.Y[j];
    double w = v.X[j + 1] - v.X[j]; double t = w > 0 ? (x - v.X[j]) / w : 0;
    if (v.Tr == 1) return v.Y[j] + (v.Y[j + 1] - v.Y[j]) * t;
    return CR(v.Y[Math.Max(0, j - 1)], v.Y[j], v.Y[j + 1], v.Y[Math.Min(n - 1, j + 2)], t);
  }

  // writes the movement at el ms after it was pressed into the frame; returns the first head's pan/tilt point (0-based)
  public static int Eval(Move m, double el, byte[] f) {
    int first = -1;
    foreach (Head h in m.Heads) {
      Sec P = m.PT;
      if (P != null) {
        int n = P.X.Length; double s = Frac(el / P.Dur - h.K * P.Shift / 100.0) * n;
        int i = Math.Min(n - 1, (int)Math.Floor(s)); double t = s - i, px, py;
        if (P.Tr == 0 || n == 1) { px = P.X[i]; py = P.Y[i]; }
        else if (P.Tr == 1) { int j = (i + 1) % n; px = P.X[i] + (P.X[j] - P.X[i]) * t; py = P.Y[i] + (P.Y[j] - P.Y[i]) * t; }
        else {
          int a = (i - 1 + n) % n, b = (i + 1) % n, c = (i + 2) % n;
          px = Card(P.X[a], P.X[i], P.X[b], P.X[c], t); py = Card(P.Y[a], P.Y[i], P.Y[b], P.Y[c], t);
        }
        if (first < 0) first = i;
        px = m.Cx + (px - m.Cx) * h.ZP + h.OP; py = m.Cy + (py - m.Cy) * h.ZT + h.OT;
        if (h.RP) px = 65535 - px; if (h.RT) py = 65535 - py;
        int pv = C16(px), tv = C16(py);
        Put(f, h, "pan", pv >> 8); Put(f, h, "upan", pv & 255); Put(f, h, "tilt", tv >> 8); Put(f, h, "utilt", tv & 255);
      }
      foreach (Sec v in m.Vals) {
        if (!h.Ix.ContainsKey(v.Name)) continue;
        double x = Frac(el / v.Dur - h.K * v.Shift / 100.0) * 65535;
        Put(f, h, v.Name, C16(ValAt(v, x)) >> 8);
      }
    }
    return Math.Max(0, first);
  }

  // ---------------------------------------------------------------- the live board (stage 3)
  class Btn { public string Sec, Path, Title; public int Page, Fader, InCh, Note = -1, OutSt = -1, OutNote = -1, OnV, OffV; public bool Swap; public string Key = "";
    public bool Bpm, Flash; public double Bps = 1; }
  static Dictionary<string, Btn> byTitle = new Dictionary<string, Btn>();   // title -> first button with it (like ShowXpress)
  static Dictionary<string, Btn> btns = new Dictionary<string, Btn>();
  static Dictionary<int, Btn> byNote = new Dictionary<int, Btn>();     // (channel << 8) | note -> button (first one wins, like ShowXpress)
  static Dictionary<int, int> faderCc = new Dictionary<int, int>();    // (channel << 8) | cc -> speed fader index
  static double[] fv = new double[16];
  static bool[] isSpeed = new bool[16];
  public static void ClearBoard() { lock (lk) { btns.Clear(); byTitle.Clear(); byNote.Clear(); faderCc.Clear(); for (int i = 0; i < fv.Length; i++) { fv[i] = 0.5; isSpeed[i] = false; } } }
  public static void AddButton(string sec, string path, string title, int page, bool swap, int fader, string key,
                               int inCh, int note, int outCh, int outNote, int onV, int offV) {
    Btn b = new Btn(); b.Sec = sec; b.Path = path ?? ""; b.Title = title; b.Page = page; b.Swap = swap; b.Fader = fader; b.Key = key ?? "";
    b.InCh = inCh; b.Note = note; b.OutNote = outNote; b.OnV = onV; b.OffV = offV; b.OutSt = outNote >= 0 ? 0x90 | ((Math.Max(1, outCh) - 1) & 15) : -1;
    lock (lk) { btns[sec] = b; if (!string.IsNullOrEmpty(title) && !byTitle.ContainsKey(title)) byTitle[title] = b; if (note >= 0) { int k = (Math.Max(1, inCh) << 8) | note; if (!byNote.ContainsKey(k)) byNote[k] = b; } }
  }
  public static void AddFader(int k, bool speed, int ch, int cc) {
    if (k < 0 || k >= fv.Length) return;
    lock (lk) { isSpeed[k] = speed; if (cc >= 0) faderCc[(Math.Max(1, ch) << 8) | cc] = k; }
  }
  public static void RemoveButton(string sec) {   // only the player's own buttons (live.ini ones stay for the whole run)
    lock (lk) { Btn b; if (!btns.TryGetValue(sec, out b)) return; btns.Remove(sec); plays.RemoveAll(p => p.Slot == sec);
      if (!string.IsNullOrEmpty(b.Title)) { Btn t; if (byTitle.TryGetValue(b.Title, out t) && t == b) byTitle.Remove(b.Title); } }
  }
  public static void SetFader(int k, double v) { if (k >= 0 && k < fv.Length) lock (lk) fv[k] = Math.Max(0, Math.Min(1, v)); }
  public static double Speed(double v) { return Math.Pow(2, (v - 0.5) * 4); }   // GUESS: middle 1x, top 4x, bottom 1/4x
  public static int Buttons { get { return btns.Count; } }
  public static void SetBeat(string sec, bool flash, double beats) {   // a BPM button (speed = auto_bpm)
    lock (lk) { Btn b; if (btns.TryGetValue(sec, out b)) { b.Bpm = true; b.Flash = flash; b.Bps = beats > 0.01 && beats <= 64 ? beats : 1; } }
  }
  static bool IsOn(string sec) { lock (lk) return plays.Exists(p => p.Slot == sec); }
  public static void SetOn(string sec, double now) { if (!IsOn(sec)) Press(sec, now); }
  public static string SecOf(string title) {
    Btn b; lock (lk) { if (!byTitle.TryGetValue(title.Trim(), out b)) throw new Exception("there is no button called " + title.Trim()); }
    return b.Sec;
  }

  // ---------------------------------------------------------------- the beat (stage 4)
  static double bpm = 120, lastTick = 0, extAt = -1e9, lastB = 0;
  static long beatN = 0;
  static string bpmSrc = "manual";
  static List<double> taps = new List<double>();
  static double Per() { return 60000.0 / bpm; }
  static void Clock(double now) {   // the clock's own beats (not while VirtualDJ is sending them)
    double per = Per();
    if (now - extAt < 2 * per + 1000) return;
    if (now - lastTick >= per) { long n = (long)Math.Floor((now - lastTick) / per); beatN += n; lastTick += n * per; }
  }
  static double BeatAt(double now) { Clock(now); return beatN + Math.Min(0.999, Math.Max(0, (now - lastTick) / Per())); }
  public static double Beat(double now) { lock (lk) return BeatAt(now); }
  public static double Bpm { get { return bpm; } }
  static void TickAt(double now) {   // a beat is NOW: to the nearest whole beat
    double b = BeatAt(now), fl = Math.Floor(b); beatN = (long)fl + (b - fl >= 0.5 ? 1 : 0); lastTick = now;
  }
  public static void SetBpm(double v, double now, string src) {
    if (v < 40 || v > 250) return;
    lock (lk) { double b = BeatAt(now); bpm = Math.Round(v, 2); beatN = (long)Math.Floor(b); lastTick = now - (b - Math.Floor(b)) * Per(); bpmSrc = src; taps.Clear(); }
  }
  public static void Tap(double now) {
    lock (lk) {
      if (taps.Count > 0 && now - taps[taps.Count - 1] > 2000) taps.Clear();
      TickAt(now); extAt = -1e9; bpmSrc = "tap";
      taps.Add(now); if (taps.Count > 8) taps.RemoveAt(0);
      if (taps.Count >= 2) { double v = 60000.0 * (taps.Count - 1) / (now - taps[0]); if (v >= 40 && v <= 250) bpm = Math.Round(v, 1); }
    }
  }
  public static void ExtBeat(double now, double v) {   // VirtualDJ (OS2L): a beat now, at v BPM
    lock (lk) { TickAt(now); if (v >= 40 && v <= 250) bpm = Math.Round(v, 2); extAt = now; bpmSrc = "VirtualDJ"; }
  }
  public static void SyncBeat(double now) {   // now is beat 1: BPM chases start again from their first step
    lock (lk) {
      double b = BeatAt(now); long n = (long)Math.Round(b); beatN = ((n + 3) / 4) * 4; lastTick = now;
      foreach (Play p in plays) if (p.Bp) { p.Eb = 0; p.El = 0; for (int k = 0; k < p.Sc.Chans.Length; k++) p.From[k] = outF[p.Sc.Chans[k]]; }
    }
  }
  static double BeatMul(double v) { return Math.Pow(2, Math.Round((v - 0.5) * 4)); }   // GUESS: /4 /2 x1 x2 x4

  // one frame of a BPM scene (under lk)
  static void BeatScene(Play p, double B, byte[] f) {
    Scene s = p.Sc; int ns = s.Len.Length;
    double eb = p.Bps / (p.Fader >= 0 ? BeatMul(fv[p.Fader]) : 1);   // beats per step
    double x = B / eb; long g = (long)Math.Floor(x);
    if (p.Eb == 0) { p.G0 = g; p.LastG = g; p.X0 = x; p.Eb = eb; }
    else if (eb != p.Eb) { long s0 = p.LastG - p.G0; p.Eb = eb; p.G0 = g - s0; p.LastG = g; p.X0 = g; }   // fader moved: keep the step
    if (g < p.LastG) g = p.LastG;   // a tap / VirtualDJ beat can pull the clock back a little: never step backwards
    bool fresh = g > p.LastG; p.LastG = g;
    int i; double fr; byte[] prev;
    if (p.Fl) {   // flash mode: every beat the scene runs once from step 1 at its own step lengths, then holds its last step
      if (fresh) { p.El = 0; for (int k = 0; k < s.Chans.Length; k++) p.From[k] = outF[s.Chans[k]]; }
      double pos = p.El, at = 0; i = 0;
      while (i < ns - 1 && pos >= at + s.Len[i]) { at += s.Len[i]; i++; }
      fr = Math.Min(1.0, (pos - at) / s.Len[i]);
      prev = i > 0 ? s.Val[i - 1] : p.From;
    } else {      // step mode: one step per beat-step, fades over the whole step
      long si = g - p.G0; i = (int)(si % ns);
      double x0 = p.X0 - Math.Floor(p.X0);
      fr = si == 0 && (long)Math.Floor(p.X0) == g ? (x - p.X0) / Math.Max(1e-6, 1 - x0) : x - g;
      fr = Math.Max(0, Math.Min(1, fr));
      prev = si == 0 ? p.From : s.Val[(i - 1 + ns) % ns];
    }
    p.Step = i; byte[] v = s.Val[i]; bool[] fd = s.Fade[i];
    for (int k = 0; k < s.Chans.Length; k++) f[s.Chans[k]] = fd[k] ? (byte)Math.Round(prev[k] + (v[k] - prev[k]) * fr) : v[k];
  }

  // ---------------------------------------------------------------- VirtualDJ (OS2L, stage 4)
  [DllImport("dnssd.dll")] static extern int DNSServiceRegister(out IntPtr sd, uint flags, uint ifIx, [MarshalAs(UnmanagedType.LPStr)] string name,
    [MarshalAs(UnmanagedType.LPStr)] string type, IntPtr domain, IntPtr host, ushort port, ushort txtLen, IntPtr txt, IntPtr cb, IntPtr ctx);
  [DllImport("dnssd.dll")] static extern void DNSServiceRefDeallocate(IntPtr sd);
  static TcpListener os2l; static IntPtr mdns = IntPtr.Zero; static int os2lConns = 0, os2lPort = 0;
  public static string Os2lPeer = "", Os2lErr = "";
  public static int Os2lBeats = 0;
  public static string StartOs2l(int port, bool announce) {
    os2lPort = port;
    try { os2l = TcpListener.Create(port); os2l.Start(); }
    catch { os2l = null; Os2lErr = "port " + port + " is in use"; return Os2lErr; }
    if (announce) {
      try { IntPtr sd; if (DNSServiceRegister(out sd, 0, 0, "SX Studio", "_os2l._tcp", IntPtr.Zero, IntPtr.Zero, (ushort)IPAddress.HostToNetworkOrder((short)port), 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) mdns = sd; else Os2lErr = "Bonjour said no"; }
      catch { Os2lErr = "Bonjour is not installed"; }
    }
    Thread t = new Thread(Os2lAccept); t.IsBackground = true; t.Start();
    return "";
  }
  static void StopOs2l() {
    try { if (os2l != null) os2l.Stop(); } catch { }
    try { if (mdns != IntPtr.Zero) { DNSServiceRefDeallocate(mdns); mdns = IntPtr.Zero; } } catch { }
  }
  static void Os2lAccept() {
    while (run) {
      TcpClient c;
      try { if (!os2l.Pending()) { Thread.Sleep(50); continue; } c = os2l.AcceptTcpClient(); } catch { break; }
      Thread t = new Thread(() => Os2lRead(c)); t.IsBackground = true; t.Start();
    }
  }
  static void Os2lRead(TcpClient c) {
    string who = "?"; try { who = ((IPEndPoint)c.Client.RemoteEndPoint).Address.ToString().Replace("::ffff:", ""); } catch { }
    Interlocked.Increment(ref os2lConns); Os2lPeer = who;
    try {
      NetworkStream s = c.GetStream(); byte[] buf = new byte[8192]; char[] cb = new char[8192]; Decoder dec = new UTF8Encoding(false).GetDecoder();
      StringBuilder acc = new StringBuilder();
      while (run) {
        if (!c.Client.Poll(200000, SelectMode.SelectRead)) continue;
        int n = s.Read(buf, 0, buf.Length); if (n <= 0) break;
        acc.Append(cb, 0, dec.GetChars(buf, 0, n, cb, 0));
        // VirtualDJ sends JSON objects one after another, with or without anything between them
        string txt = acc.ToString(); int depth = 0, st = -1, keep = txt.Length; bool q = false, esc = false;
        for (int i = 0; i < txt.Length; i++) {
          char ch = txt[i];
          if (q) { if (esc) esc = false; else if (ch == '\\') esc = true; else if (ch == '"') q = false; continue; }
          if (ch == '"' && depth > 0) { q = true; continue; }
          if (ch == '{') { if (depth == 0) st = i; depth++; }
          else if (ch == '}' && depth > 0) { depth--; if (depth == 0) { try { Os2lMsg(txt.Substring(st, i - st + 1)); } catch (Exception e) { LastError = e.Message; } st = -1; } }
        }
        acc.Clear(); if (depth > 0 && st >= 0 && txt.Length - st < 65536) acc.Append(txt.Substring(st));
      }
    } catch { }
    try { c.Close(); } catch { }
    if (Interlocked.Decrement(ref os2lConns) <= 0) Os2lPeer = "";
  }
  static string JStr(string j, string key) {   // a "key":"value" string from a small JSON object
    int i = j.IndexOf("\"" + key + "\""); if (i < 0) return null;
    i = j.IndexOf(':', i + key.Length + 2); if (i < 0) return null; i++;
    while (i < j.Length && char.IsWhiteSpace(j[i])) i++;
    if (i >= j.Length) return null;
    if (j[i] != '"') { int e = i; while (e < j.Length && j[e] != ',' && j[e] != '}') e++; return j.Substring(i, e - i).Trim(); }
    StringBuilder b = new StringBuilder();
    for (i++; i < j.Length && j[i] != '"'; i++) {
      if (j[i] == '\\' && i + 1 < j.Length) { i++; char e = j[i];
        if (e == 'u' && i + 4 < j.Length) { b.Append((char)Convert.ToInt32(j.Substring(i + 1, 4), 16)); i += 4; }
        else b.Append(e == 'n' ? '\n' : e == 't' ? '\t' : e); }
      else b.Append(j[i]);
    }
    return b.ToString();
  }
  static void Os2lMsg(string j) {
    string evt = JStr(j, "evt");
    if (evt == "beat") {
      double v; string bs = JStr(j, "bpm");
      if (bs == null || !double.TryParse(bs, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) v = 0;
      ExtBeat(Now(), v); Interlocked.Increment(ref Os2lBeats);
    } else if (evt == "btn") {
      string name = JStr(j, "name"), state = JStr(j, "state"); if (string.IsNullOrEmpty(name)) return;
      Btn b; lock (lk) { byTitle.TryGetValue(name.Trim(), out b); } if (b == null) return;
      if (state == "off") Off(b.Sec); else SetOn(b.Sec, Now());
    }
  }

  // ---------------------------------------------------------------- the Auto Show's pipe (stage 4)
  public static void StartPipe(string name) { Thread t = new Thread(() => PipeLoop(name)); t.IsBackground = true; t.Start(); }
  static void PipeLoop(string name) {
    while (run) {
      try {
        using (NamedPipeServerStream ps = new NamedPipeServerStream(name, PipeDirection.In, 1, PipeTransmissionMode.Byte)) {
          ps.WaitForConnection();
          using (StreamReader r = new StreamReader(ps, new UTF8Encoding(false))) {
            string l;
            while (run && (l = r.ReadLine()) != null) {
              string w = l.Trim(); int sp = w.IndexOf(' '); string c0 = sp < 0 ? w : w.Substring(0, sp);
              if (c0 == "ton" || c0 == "toff" || c0 == "seton" || c0 == "setoff" || c0 == "bpm" || c0 == "sync" || c0 == "tap") Apply(w);
            }
          }
        }
      } catch { Thread.Sleep(200); }
    }
  }

  public static void Press(string sec, double now) {
    Btn b; lock (lk) { if (!btns.TryGetValue(sec, out b)) throw new Exception("that button is not in the show"); }
    bool on; lock (lk) { on = plays.Exists(p => p.Slot == sec); }
    if (on) { Off(sec); return; }
    if (b.Path == "") throw new Exception(b.Title + ": its file is missing");
    try { if (b.Path.EndsWith(".gpj", StringComparison.OrdinalIgnoreCase)) LoadMove(b.Path); else Load(b.Path); }
    catch (Exception e) { throw new Exception(b.Title + ": " + e.Message); }
    if (b.Swap) lock (lk) { plays.RemoveAll(p => { Btn o; return btns.TryGetValue(p.Slot, out o) && o.Swap && o.Page == b.Page; }); }
    On(sec, b.Path, now);
  }
  public static void KeyPress(string k, double now) {
    Btn hit = null;
    lock (lk) { foreach (Btn b in btns.Values) if (b.Key != "" && string.Equals(b.Key, k, StringComparison.OrdinalIgnoreCase)) { hit = b; break; } }
    if (hit != null) Press(hit.Sec, now);
  }
  public static void Midi(int m, double now) {
    int st = m & 0xF0, ch = (m & 0x0F) + 1, d1 = (m >> 8) & 0x7F, d2 = (m >> 16) & 0x7F; Btn b; int k;
    if (st == 0x90 && d2 > 0) { lock (lk) { byNote.TryGetValue((ch << 8) | d1, out b); } if (b != null) Press(b.Sec, now); }
    else if (st == 0xB0) { bool hit; lock (lk) { hit = faderCc.TryGetValue((ch << 8) | d1, out k); } if (hit) SetFader(k, d2 / 127.0); }
  }

  // pad lights: what each pad should show now; only changes are sent
  static Dictionary<int, int> ledSent = new Dictionary<int, int>();   // (status << 8) | note -> value
  static void SyncLeds(bool allOff) {
    Dictionary<int, int> want = new Dictionary<int, int>();
    lock (lk) {
      HashSet<string> on = new HashSet<string>(); foreach (Play p in plays) on.Add(p.Slot);
      foreach (Btn b in btns.Values) {
        if (b.OutSt < 0) continue; int k = (b.OutSt << 8) | b.OutNote; bool lit = !allOff && on.Contains(b.Sec);
        int cur; if (want.TryGetValue(k, out cur) && cur == b.OnV && !lit) continue;   // a shared pad: lit wins
        want[k] = lit ? b.OnV : b.OffV;
      }
    }
    lock (lk) foreach (KeyValuePair<int, int> w in want) {   // ledSent is read by Status() under the same lock
      int had; if (ledSent.TryGetValue(w.Key, out had) && had == w.Value) continue;
      ledSent[w.Key] = w.Value;
      if (midiOut != IntPtr.Zero) midiOutShortMsg(midiOut, (uint)((w.Key >> 8) | ((w.Key & 0x7F) << 8) | ((w.Value & 0x7F) << 16)));
    }
  }

  // ---------------------------------------------------------------- playback
  class Play { public string Slot; public Scene Sc; public Move Mv; public double T0, El, Last; public int Fader = -1; public byte[] From; public int Step;
    public bool Bp, Fl; public double Bps = 1, Eb, X0; public long G0, LastG; }
  static List<Play> plays = new List<Play>();           // oldest press first: the last one wins
  static byte[] outF = new byte[N];
  static bool blackout;
  static readonly object lk = new object();
  public static string LastError = "";

  public static void On(string slot, string path, double now) {
    if (path.EndsWith(".gpj", StringComparison.OrdinalIgnoreCase)) {
      Move mv = LoadMove(path);
      lock (lk) { plays.RemoveAll(p => p.Slot == slot); Play q = new Play(); q.Slot = slot; q.Mv = mv; q.T0 = now; q.Last = now; q.Fader = FaderOf(slot); plays.Add(q); }
      return;
    }
    Scene sc = Load(path);
    lock (lk) {
      plays.RemoveAll(p => p.Slot == slot);
      Play q = new Play(); q.Slot = slot; q.Sc = sc; q.T0 = now; q.Last = now; q.Fader = FaderOf(slot); q.From = new byte[sc.Chans.Length];
      for (int k = 0; k < sc.Chans.Length; k++) q.From[k] = outF[sc.Chans[k]];
      Btn bb; if (btns.TryGetValue(slot, out bb) && bb.Bpm) { q.Bp = true; q.Fl = bb.Flash; q.Bps = bb.Bps; }
      plays.Add(q);
    }
  }
  static int FaderOf(string slot) { Btn b; return btns.TryGetValue(slot, out b) && b.Fader >= 0 && b.Fader < fv.Length && isSpeed[b.Fader] ? b.Fader : -1; }
  public static void Off(string slot) { lock (lk) { plays.RemoveAll(p => p.Slot == slot); } }
  public static void AllOff() { lock (lk) { plays.Clear(); } }
  public static void Blackout(bool on) { lock (lk) { blackout = on; } }

  public static byte[] Frame(double now) {
    lock (lk) {
      byte[] f = new byte[N];
      double B = BeatAt(now); lastB = B;
      foreach (Play p in plays) {
        p.El += Math.Max(0, now - p.Last) * (p.Fader >= 0 && !p.Bp ? Speed(fv[p.Fader]) : 1); p.Last = now;
        if (p.Mv != null) { p.Step = Eval(p.Mv, p.El, f); continue; }
        if (p.Bp) { BeatScene(p, B, f); continue; }
        Scene s = p.Sc; int ns = s.Len.Length;
        double el = p.El;
        long pass = (long)Math.Floor(el / s.Total); double pos = el - pass * (double)s.Total;
        int i = 0; double at = 0;
        while (i < ns - 1 && pos >= at + s.Len[i]) { at += s.Len[i]; i++; }
        if (ns == 1 && pass > 0) { i = 0; pos = s.Len[0]; at = 0; }   // one step: after its first pass it just holds
        p.Step = i;
        byte[] prev = i > 0 ? s.Val[i - 1] : (pass == 0 ? p.From : s.Val[ns - 1]);
        double fr = Math.Min(1.0, (pos - at) / s.Len[i]);
        byte[] v = s.Val[i]; bool[] fd = s.Fade[i];
        for (int k = 0; k < s.Chans.Length; k++)
          f[s.Chans[k]] = fd[k] ? (byte)Math.Round(prev[k] + (v[k] - prev[k]) * fr) : v[k];
      }
      outF = f;
      return blackout ? new byte[N] : f;
    }
  }

  public static string Status() {
    lock (lk) {
      StringBuilder b = new StringBuilder("{\"ok\":true,\"bo\":" + (blackout ? "true" : "false") + ",\"on\":[");
      for (int i = 0; i < plays.Count; i++) {
        if (i > 0) b.Append(',');
        Play q = plays[i]; int of = q.Mv != null ? Math.Max(1, q.Mv.Points) : q.Sc.Len.Length;
        b.Append("{\"slot\":\"" + Js(q.Slot) + "\",\"step\":" + (q.Step + 1) + ",\"of\":" + of + (q.Mv != null ? ",\"mv\":true" : "") + (q.Bp ? ",\"bpm\":true" : "") + "}");
      }
      b.Append("],\"err\":\"" + Js(LastError) + "\",\"fd\":[");
      for (int i = 0; i < fv.Length; i++) { if (i > 0) b.Append(','); b.Append(fv[i].ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)); }
      b.Append("],\"midi\":\"" + Js(MidiName) + "\",\"led\":{");
      bool first = true; foreach (KeyValuePair<int, int> l in ledSent) { if (!first) b.Append(','); first = false; b.Append("\"" + (l.Key & 0x7F) + "\":" + l.Value); }
      System.Globalization.CultureInfo ic = System.Globalization.CultureInfo.InvariantCulture;
      b.Append("},\"bpm\":" + bpm.ToString("0.##", ic) + ",\"beat\":" + lastB.ToString("0.###", ic) + ",\"src\":\"" + bpmSrc + "\"");
      b.Append(",\"os2l\":\"" + Js(Os2lPeer) + "\",\"os2lPort\":" + (os2l != null ? os2lPort : 0) + ",\"os2lErr\":\"" + Js(Os2lErr) + "\",\"os2lBeats\":" + Os2lBeats);
      b.Append(",\"iface\":\"" + (lost ? "lost" : "ok") + "\",\"reconn\":" + Reconnects + ",\"warn\":[");
      for (int i = 0; i < warns.Count; i++) { if (i > 0) b.Append(','); b.Append("\"" + Js(warns[i]) + "\""); }
      b.Append("]}");
      return b.ToString();
    }
  }
  static string Js(string s) { if (s == null) return ""; return s.Replace("\\", "\\\\").Replace("\"", "\\\""); }

  // ---------------------------------------------------------------- the running engine
  static volatile bool run = true;
  static bool fake, opened;
  static string fakeLog, statusFile;
  static long lastCmd = DateTime.UtcNow.Ticks;
  static Stopwatch clock = Stopwatch.StartNew();
  static double Now() { return clock.Elapsed.TotalMilliseconds; }

  public static string Open(string dir, bool isFake, string log, string status) {
    fake = isFake; fakeLog = log; statusFile = status;
    if (fake) return "OK test interface";
    if (!File.Exists(Path.Combine(dir, "efk_hardware.dll"))) return "ERR ShowXpress's interface driver (efk_hardware.dll) was not found in " + dir;
    SetDllDirectory(dir);
    EFK_check_hardware();
    string n = Marshal.PtrToStringUni(EFK_get_name_of_interfaces());
    if (n == null || n.Trim('|', ' ') == "" || n.StartsWith("err")) return "ERR none";
    EFK_open(); EFK_stream_mode(); opened = true; ifName = n.Trim('|', ' ');
    return "OK " + ifName.ToUpper();
  }

  static void Sender() {
    try { timeBeginPeriod(1); } catch { }
    double next = Now(), lastStat = -1000, lastDev = -1000, backAt = -1, retryAt = 0; string lastLog = null;
    while (run) {
      byte[] o = Frame(Now());
      if (Now() - lastDev > 500) {
        lastDev = Now(); bool here = Present();
        if (!here) { lost = true; backAt = -1; }
        else if (lost) {
          if (backAt < 0) backAt = Now();
          if (Now() - backAt > 1500 && Now() >= retryAt) { if (Reopen()) { lost = false; Reconnects++; } else retryAt = Now() + 2000; }
        }
      }
      if (lost) { }
      else if (!fake) EFK_send_dmx(o);
      else if (!string.IsNullOrEmpty(fakeLog)) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 512; i++) if (o[i] != 0) sb.Append((i + 1) + "=" + o[i] + "\n");
        string s = sb.ToString(); if (s != lastLog) { lastLog = s; try { File.WriteAllText(fakeLog, s); } catch { } }
      }
      if (!string.IsNullOrEmpty(statusFile) && Now() - lastStat > 200) {
        lastStat = Now(); try { File.WriteAllText(statusFile + ".tmp", Status()); File.Copy(statusFile + ".tmp", statusFile, true); } catch { }
      }
      if (DateTime.UtcNow.Ticks - Interlocked.Read(ref lastCmd) > 30L * TimeSpan.TicksPerSecond) run = false;
      next += 25; double w = next - Now();   // 40 frames a second, on a steady clock
      if (w > 0) Thread.Sleep((int)w); else if (w < -200) next = Now();
    }
  }

  static void MidiWorker() {
    while (run) {
      int m;
      if (midiQ.TryTake(out m, 20)) { try { Midi(m, Now()); } catch (Exception e) { LastError = e.Message; } }
      try { SyncLeds(false); } catch { }
    }
  }

  static void Apply(string line) {
    line = line.Trim(); if (line == "") return;
    string[] a = line.Split(new char[] { ' ' }, 3);
    try {
      switch (a[0]) {
        case "on": if (a.Length == 3) { LastError = ""; On(a[1], a[2], Now()); } break;
        case "off": if (a.Length >= 2) Off(a[1]); break;
        case "alloff": AllOff(); break;
        case "bo": Blackout(a.Length >= 2 && a[1] == "1"); break;
        case "press": if (a.Length >= 2) { LastError = ""; Press(a[1], Now()); } break;
        case "key": if (a.Length >= 2) { LastError = ""; KeyPress(a[1], Now()); } break;
        case "fader": { double v; int k; if (a.Length == 3 && int.TryParse(a[1], out k) && double.TryParse(a[2], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) SetFader(k, v); } break;
        case "mi": { string[] q = line.Split(' '); int s0, s1, s2; if (q.Length == 4 && int.TryParse(q[1], out s0) && int.TryParse(q[2], out s1) && int.TryParse(q[3], out s2)) midiQ.Add(s0 | (s1 << 8) | (s2 << 16)); } break;
        case "bpm": { double v; if (a.Length >= 2 && double.TryParse(a[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) SetBpm(v, Now(), "manual"); } break;
        case "tap": Tap(Now()); break;
        case "sync": SyncBeat(Now()); break;
        case "seton": if (a.Length >= 2) { LastError = ""; SetOn(a[1], Now()); } break;
        case "setoff": if (a.Length >= 2) Off(a[1]); break;
        case "ton": if (line.Length > 4) { LastError = ""; SetOn(SecOf(line.Substring(4)), Now()); } break;
        case "toff": if (line.Length > 5) Off(SecOf(line.Substring(5))); break;
        case "addb": {   // a button on one of the SX Player's own pages (see the top of player.ps1)
          string[] q = line.Substring(5).Split(new char[] { '|' }, 9); int g, sw, fd, bp, fl; double bt;
          if (q.Length == 9 && q[0].StartsWith("x") && int.TryParse(q[1], out g) && int.TryParse(q[2], out sw) && int.TryParse(q[3], out fd) &&
              int.TryParse(q[4], out bp) && int.TryParse(q[5], out fl) &&
              double.TryParse(q[6], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out bt)) {
            bool was = IsOn(q[0]);
            lock (lk) { Btn o; if (btns.TryGetValue(q[0], out o)) { Btn t; if (byTitle.TryGetValue(o.Title ?? "", out t) && t == o) byTitle.Remove(o.Title); } }
            AddButton(q[0], q[7], q[8], g, sw == 1, fd, "", 1, -1, 1, -1, 0, 0);
            if (bp == 1) SetBeat(q[0], fl == 1, bt);
            if (was && q[7] != "") On(q[0], q[7], Now());   // edited while playing: carries on with the new settings
          } } break;
        case "delb": if (a.Length >= 2 && a[1].StartsWith("x")) RemoveButton(a[1]); break;
        case "q": run = false; break;
      }
    } catch (Exception e) { LastError = (a[0] == "on" && a.Length == 3 ? Path.GetFileNameWithoutExtension(a[2]) + ": " : "") + e.Message; }
  }

  static void Reader() {
    try {
      string line;
      while (run && (line = Console.In.ReadLine()) != null) { Interlocked.Exchange(ref lastCmd, DateTime.UtcNow.Ticks); Apply(line); }
    } catch { }
    run = false;
  }

  public static void Run() {
    Thread s = new Thread(Sender); s.IsBackground = true; s.Priority = ThreadPriority.AboveNormal; s.Start();
    Thread r = new Thread(Reader); r.IsBackground = true; r.Start();
    Thread mw = new Thread(MidiWorker); mw.IsBackground = true; mw.Start();
    try { SetThreadExecutionState(0x80000000 | 0x1 | 0x2); } catch { }   // no sleep, screen stays on, while the player runs
    while (run) Thread.Sleep(50);
    try { SetThreadExecutionState(0x80000000); } catch { }
    s.Join(500); mw.Join(300);
    // lights out, then let ShowXpress have the interface again
    AllOff(); StopOs2l();
    try { SyncLeds(true); Thread.Sleep(20); } catch { }   // pads back to their "off" colours
    CloseMidi();
    byte[] z = new byte[N];
    for (int i = 0; i < 3; i++) { if (!fake && !lost) EFK_send_dmx(z); Thread.Sleep(30); }
    if (fake && !string.IsNullOrEmpty(fakeLog)) { try { File.WriteAllText(fakeLog, ""); } catch { } }
    if (!string.IsNullOrEmpty(statusFile)) { try { File.Delete(statusFile); File.Delete(statusFile + ".tmp"); } catch { } }
    if (opened) EFK_close();
  }
}
"@
# the compiled player is kept (one file per version of the code above), so later starts skip compiling it (user 2026-11-23)
try {
  $sxHash = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sxCs))).Replace('-', '').Substring(0, 16)
  $sxDir = Join-Path $env:LOCALAPPDATA 'ShowXpress Helper\cache'; $sxDll = Join-Path $sxDir "sxplayer_$sxHash.dll"
  if (-not (Test-Path -LiteralPath $sxDll)) {
    New-Item -ItemType Directory -Force $sxDir | Out-Null
    $sxTmp = Join-Path $sxDir "sxplayer_$sxHash.$PID.dll"
    Add-Type -ReferencedAssemblies System.Xml, System.Core -TypeDefinition $sxCs -OutputAssembly $sxTmp -OutputType Library
    try { Move-Item -LiteralPath $sxTmp $sxDll -ErrorAction Stop } catch { Remove-Item -LiteralPath $sxTmp -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $sxDir -Filter 'sxplayer_*.dll' | Where-Object { $_.FullName -ne $sxDll } | Remove-Item -ErrorAction SilentlyContinue
  }
  try { Add-Type -Path $sxDll } catch { Remove-Item -LiteralPath $sxDll -ErrorAction SilentlyContinue }   # damaged: built again next time
} catch {}
if (-not ('SxPlayer' -as [type])) { Add-Type -ReferencedAssemblies System.Xml, System.Core -TypeDefinition $sxCs }
}

function Set-PlayerPatch([string]$root) {
  # fixtures.ini: [FixtureN] address = .. / id = ..  -> [SxPlayer]::Patch(id, address)
  [SxPlayer]::ClearPatch(); $a = $null; $n = 0
  foreach ($l in [IO.File]::ReadAllLines("$root/fixtures.ini")) {
    if ($l -match '^\[') { $a = $null }
    elseif ($l -match '^address = (\d+)\s*$') { $a = [int]$matches[1] }
    elseif ($l -match '^id = (\d+)\s*$' -and $a) { [SxPlayer]::Patch($matches[1], $a); $n++ }
  }
  $n
}
function Set-PlayerBoard([string]$root) {
  # live.ini -> [SxPlayer] buttons + faders; returns the number of buttons
  . (Join-Path $PSScriptRoot 'show_common.ps1')
  $info = Get-LiveInfo $root
  [SxPlayer]::ClearBoard()
  $int = { param($v, $d) if ("$v" -match '^-?\d+$') { [int]$v } else { $d } }
  foreach ($f in @($info.Faders)) {
    $n = $f.k + 1; $ty = & $int $info.Live["fader${n}_midi_type"] -1
    if ((& $int $info.Live["fader${n}_midi_device"] 0) -ne 0) { $ty = -1 }   # a fader on another controller: the player only listens to the APC mini
    [SxPlayer]::AddFader($f.k, ("$($f.type)" -eq '1'), (& $int $info.Live["fader${n}_midi_channel"] 1), $(if ($ty -eq 1) { & $int $info.Live["fader${n}_midi_note"] -1 } else { -1 }))
  }
  $swap = @{}; foreach ($s in $info.Sections) { if ($s[0] -match '^page(\d+)$' -and "$($s[1]['swap'])" -eq 'yes') { $swap[[int]$matches[1]] = $true } }
  foreach ($b in $info.Buttons) {
    $k = $b.Keys; $p = Get-ScenePath $root $b.Name
    # only the APC mini's pads (MIDI device 0); a button on another controller (the APC40) isn't on a pad here
    $note = if ((& $int $k['trigger_midi_type'] -1) -eq 0 -and (& $int $k['trigger_midi_device'] 0) -eq 0) { & $int $k['trigger_midi_note'] -1 } else { -1 }
    $onote = if ((& $int $k['trigger_midiout_type'] -1) -eq 0 -and (& $int $k['trigger_midiout_device'] 0) -eq 0) { & $int $k['trigger_midiout_note'] -1 } else { -1 }
    $title = if ($b.Title) { $b.Title } else { $b.Name -replace '\.(scex|gpj)$', '' }
    [SxPlayer]::AddButton($b.Sec, "$p", $title, $b.Page, [bool]$swap[$b.Page], (& $int $k['masterspeedfader'] 0), "$($k['trigger_keyboard'])",
      (& $int $k['trigger_midi_channel'] 1), $note, (& $int $k['trigger_midiout_channel'] 1), $onote, (& $int $k['trigger_midiout_data'] 0), (& $int $k['trigger_midiout_data_off'] 0))
    if ("$($k['speed'])" -eq 'auto_bpm') {
      $bt = 1.0; [void][double]::TryParse("$($k['beats'])", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$bt)
      [SxPlayer]::SetBeat($b.Sec, ("$($k['bpm_trigger'])" -eq 'flash_mode'), $bt)
    }
  }
  [SxPlayer]::Buttons
}
function Get-MidiNames([string]$root) {
  # ShowXpress's own MIDI choice: TheLightingController\param.ini (two folders above the show)
  $pi = Join-Path (Split-Path (Split-Path $root -Parent) -Parent) 'param.ini'; $r = @{ in = ''; out = '' }
  if (Test-Path -LiteralPath $pi) {
    foreach ($l in [IO.File]::ReadAllLines($pi)) {
      if ($l -match '^OS2LPORT = (\d+)') { $r.os2l = [int]$matches[1] } elseif ($l -match '^OS2LENABLE = no') { $r.os2lOff = $true }
      if ($l -match '^MIDIINDEVICE = (.*)$') { $r.in = $matches[1].Trim() } elseif ($l -match '^MIDIOUTDEVICE = (.*)$') { $r.out = $matches[1].Trim() }
      elseif ($l -match '^MIDIENABLE = no') { $r.inOff = $true } elseif ($l -match '^MIDIOUTENABLE = no') { $r.outOff = $true }
    }
  }
  if ($r.inOff) { $r.in = '' }; if ($r.outOff) { $r.out = '' }
  if (-not $r.os2l) { $r.os2l = 7350 }; if ($r.os2lOff) { $r.os2l = 0 }
  $r
}
function Get-StartBpm([string]$root) {
  # the Auto Show's BPM (auto_show.json), else 120 (live.ini manual_bpm is ShowXpress's sound-to-light setting, not a tempo)
  $f = Join-Path $root 'auto_show.json'; $b = 120.0
  if (Test-Path -LiteralPath $f) { try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json; if ($j.bpm -ge 40 -and $j.bpm -le 250) { $b = [double]$j.bpm } } catch {} }
  $b
}
if ($DefineOnly) { return }

if (-not $Show -or -not (Test-Path -LiteralPath "$Show/fixtures.ini")) { [Console]::Out.WriteLine("ERR The show's fixture list (fixtures.ini) was not found."); [Console]::Out.Flush(); [Environment]::Exit(0) }
if (-not (Set-PlayerPatch $Show)) { [Console]::Out.WriteLine("ERR No fixtures found in the show's fixtures.ini."); [Console]::Out.Flush(); [Environment]::Exit(0) }
try { [void](Set-PlayerBoard $Show) } catch { [Console]::Out.WriteLine("ERR Could not read the show's live pages: $_"); [Console]::Out.Flush(); [Environment]::Exit(0) }
$r = [SxPlayer]::Open($DllDir, [bool]$Fake, $FakeLog, $StatusFile)
[SxPlayer]::SetBpm((Get-StartBpm $Show), 0, 'manual')
if ($r -like 'OK*') {
  try { [void][SxPlayer]::CheckShow() } catch {}
  # watch the interface: unplugged -> stop sending, plugged back -> open it again
  if ($Fake) { [SxPlayer]::WatchDevice('', (Join-Path (Split-Path $FakeLog -Parent) '_iface_unplugged')) }
  else {
    # the interface's Windows device: USB vendor 1069 (the D512S family), else a device with the interface's name
    $nm = ($r.Substring(3) -split '\|')[0].Trim()
    try {
      $all = @(Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB%'" -ErrorAction Stop)
      $d = @(@($all | Where-Object { "$($_.PNPDeviceID)" -like 'USB\VID_1069&*' }) + @($all | Where-Object { $_.Name -and $_.Name.Trim() -eq $nm }))
      if ($d.Count) { [SxPlayer]::WatchDevice("$($d[0].PNPDeviceID)", '') }
    } catch {}
  }
}
$mn = Get-MidiNames $Show
if ($r -like 'OK*' -and -not $Fake -and -not $NoMidi) { try { [void][SxPlayer]::OpenMidi($mn.in, $mn.out) } catch {} }
# VirtualDJ: the show's OS2L port (the test copy uses 47350 and doesn't announce itself, so it never meets the real VirtualDJ)
if ($r -like 'OK*') { try { if ($Fake) { [void][SxPlayer]::StartOs2l(47350, $false) } elseif ($mn.os2l) { [void][SxPlayer]::StartOs2l($mn.os2l, $true) } } catch {} }
if ($r -like 'OK*' -and $Pipe -match '^[A-Za-z0-9_]+$') { [SxPlayer]::StartPipe($Pipe) }
[Console]::Out.WriteLine($r); [Console]::Out.Flush()
if ($r -like 'OK*') { [SxPlayer]::Run() }
[Environment]::Exit(0)
