# DMX OUT - the Helper's own DMX output for LIVE AIM (Windows). Started by df_aim_gui.ps1 as a child process.
#
#   Uses ShowXpress's own interface driver (efk_hardware.dll in the ShowXpress folder) to send DMX straight to the
#   USB interface (EFK D512S). Only ONE program can use the interface: ShowXpress must be CLOSED while this runs.
#   First line printed:  "OK <interface name>"  or  "ERR <why>".
#   Then reads commands from stdin, one line = one atomic change (space separated tokens):
#     z            everything to 0 (all channels, all glides)
#     b:ch:v       raw byte, ch = DMX channel 1..8192 (universe 1 = 1..512), v = 0..255
#     p:c:f:v      16-bit value v (0..65535) on coarse channel c + fine channel f, GLIDES there (smooth)
#     s:c:f:v      same, but jumps there at once
#     k            keep-alive (nothing else)          q   quit
#   Safety: no command for 30 s (Helper window gone) or stdin closed -> all channels 0, interface closed, exit.
#   -Fake = no hardware (testing): the frame is written to -FakeLog as "ch=value" lines for channels above 0.
param([string]$DllDir = "$env:ProgramFiles\ShowXpress", [switch]$Fake, [string]$FakeLog = '')
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.IO; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public static class SxhDmx {
  [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern bool SetDllDirectory(string p);
  [DllImport("efk_hardware.dll")] static extern long EFK_check_hardware();
  [DllImport("efk_hardware.dll")] static extern long EFK_open();
  [DllImport("efk_hardware.dll")] static extern long EFK_close();
  [DllImport("efk_hardware.dll")] static extern long EFK_stream_mode();
  [DllImport("efk_hardware.dll")] static extern IntPtr EFK_get_name_of_interfaces();
  [DllImport("efk_hardware.dll")] static extern long EFK_send_dmx(byte[] buf);
  const int N = 512 * 16;
  class Pair { public int c, f; public double cur, tgt; }
  static byte[] frame = new byte[N];
  static Dictionary<int, Pair> pairs = new Dictionary<int, Pair>();
  static readonly object lk = new object();
  static volatile bool run = true;
  static bool fake, opened;
  static string fakeLog;
  static long lastCmd = DateTime.UtcNow.Ticks;
  static volatile bool dirty = true;

  public static string Open(string dir, bool isFake, string log) {
    fake = isFake; fakeLog = log;
    if (fake) return "OK test interface";
    if (!File.Exists(Path.Combine(dir, "efk_hardware.dll"))) return "ERR ShowXpress's interface driver (efk_hardware.dll) was not found in " + dir;
    SetDllDirectory(dir);
    EFK_check_hardware();
    string n = Marshal.PtrToStringUni(EFK_get_name_of_interfaces());
    if (n == null || n.Trim('|', ' ') == "" || n.StartsWith("err")) return "ERR none";
    EFK_open(); EFK_stream_mode(); opened = true;
    return "OK " + n.Trim('|', ' ').ToUpper();
  }

  static void Sender() {
    byte[] o = new byte[N];
    while (run) {
      lock (lk) {
        foreach (Pair p in pairs.Values) {
          double d = p.tgt - p.cur;
          if (Math.Abs(d) < 3) { if (d != 0) dirty = true; p.cur = p.tgt; } else { p.cur += d * 0.45; dirty = true; }
          int v = (int)Math.Round(p.cur); frame[p.c] = (byte)(v >> 8); frame[p.f] = (byte)(v & 255);
        }
        Buffer.BlockCopy(frame, 0, o, 0, N);
      }
      if (!fake) EFK_send_dmx(o);
      else if (fakeLog != null && fakeLog != "" && dirty) {
        dirty = false;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 512; i++) if (o[i] != 0) sb.Append((i + 1) + "=" + o[i] + "\n");
        try { File.WriteAllText(fakeLog, sb.ToString()); } catch { }
      }
      if (DateTime.UtcNow.Ticks - Interlocked.Read(ref lastCmd) > 30L * TimeSpan.TicksPerSecond) run = false;
      Thread.Sleep(25);
    }
  }

  static int Num(string s, int max) { int v; if (!int.TryParse(s, out v) || v < 0 || v > max) throw new FormatException(s); return v; }

  static void Apply(string line) {
    lock (lk) {
      foreach (string t in line.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)) {
        try {
          if (t == "z") { Array.Clear(frame, 0, N); pairs.Clear(); continue; }
          if (t == "k") continue;
          if (t == "q") { run = false; continue; }
          string[] a = t.Split(':');
          if (a[0] == "b" && a.Length == 3) { frame[Num(a[1], N) - 1] = (byte)Num(a[2], 255); continue; }
          if ((a[0] == "p" || a[0] == "s") && a.Length == 4) {
            int c = Num(a[1], N) - 1, f = Num(a[2], N) - 1, v = Num(a[3], 65535);
            if (c < 0 || f < 0) continue;
            Pair p;
            if (!pairs.TryGetValue(c, out p)) { p = new Pair(); p.c = c; p.f = f; p.cur = v; pairs[c] = p; }
            p.f = f; p.tgt = v; if (a[0] == "s") p.cur = v;
          }
        } catch { }
      }
      dirty = true;
    }
  }

  static void Reader() {
    try {
      string line;
      while (run && (line = Console.In.ReadLine()) != null) { Interlocked.Exchange(ref lastCmd, DateTime.UtcNow.Ticks); Apply(line); }
    } catch { }
    run = false;
  }

  public static void Run() {
    Thread s = new Thread(Sender); s.IsBackground = true; s.Start();
    Thread r = new Thread(Reader); r.IsBackground = true; r.Start();
    while (run) Thread.Sleep(50);
    s.Join(500);
    // lights out, then let ShowXpress have the interface again
    lock (lk) { Array.Clear(frame, 0, N); pairs.Clear(); }
    byte[] z = new byte[N];
    for (int i = 0; i < 3; i++) { if (!fake) EFK_send_dmx(z); Thread.Sleep(30); }
    if (fake && fakeLog != null && fakeLog != "") { try { File.WriteAllText(fakeLog, ""); } catch { } }
    if (opened) EFK_close();
  }
}
"@
$r = [SxhDmx]::Open($DllDir, [bool]$Fake, $FakeLog)
[Console]::Out.WriteLine($r); [Console]::Out.Flush()
if ($r -like 'OK*') { [SxhDmx]::Run() }
[Environment]::Exit(0)
