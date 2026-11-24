# SX Helper - answers ShowXpress's "Do you really want to quit?" with Yes after the Helper asked ShowXpress to close
# (user 2026-11-23). ONLY that question: its text has to be exactly ShowXpress's quit text (Txt_quit in any of its
# language files). "Do you want to save ...?" and every other question are never touched - they stay with the user.
# Runs for a short while after the close request and stops as soon as ShowXpress is gone or the question was answered.
#   -Pids = the processes to watch, comma separated (default: ShowXpress's own).  -Seconds = how long to watch.
param([string]$Pids = '', [int]$Seconds = 90, [string]$LangDir = "$env:ProgramFiles\ShowXpress\TheLightingController\language")
$ErrorActionPreference = 'Stop'
$pl = @("$Pids" -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

# the quit question in every language ShowXpress has (whichever one is in use)
$quit = @('Do you really want to quit?')
try { foreach ($f in Get-ChildItem -LiteralPath $LangDir -Filter *.ini -ErrorAction Stop) {
  foreach ($l in [IO.File]::ReadAllLines($f.FullName)) { if ($l -match '^Txt_quit=(.+)$') { $quit += $Matches[1].Trim() } } } } catch {}
$quit = @($quit | Where-Object { $_ } | Select-Object -Unique)

Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class SxQuit {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32")] static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  static string Txt(IntPtr h) { StringBuilder s = new StringBuilder(4096); SendMessage(h, 0x0D, (IntPtr)4096, s); return s.ToString(); }
  static string Cls(IntPtr h) { StringBuilder s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  static string Norm(string s) { return string.Join(" ", s.Replace("&", "").Split(new char[] { ' ', '\r', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries)).ToLowerInvariant(); }
  // -> "" (nothing found), or what was answered
  public static string Answer(uint[] pids, string[] quitTexts) {
    HashSet<string> q = new HashSet<string>(); foreach (string t in quitTexts) q.Add(Norm(t));
    string done = "";
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (Array.IndexOf(pids, p) < 0 || !IsWindowVisible(h) || Cls(h) != "#32770") return true;   // only standard Windows message boxes
      List<string> texts = new List<string>(); IntPtr yes = IntPtr.Zero; int yesId = 0, buttons = 0;
      EnumChildWindows(h, (c, l2) => {
        string cl = Cls(c), tx = Txt(c);
        if (cl == "Static" && tx.Trim() != "") texts.Add(tx);
        if (cl == "Button") { buttons++; string n = Norm(tx); int id = GetDlgCtrlID(c); if (id == 6 || (id == 1 && (n == "ok" || n == "yes"))) { yes = c; yesId = id; } }
        return true; }, IntPtr.Zero);
      string all = Norm(string.Join(" ", texts.ToArray()));
      // exactly the quit question - nothing about saving - with a Yes (or OK) button
      if (texts.Count == 1 && q.Contains(all) && !all.Contains("save") && yes != IntPtr.Zero && buttons <= 3) {
        PostMessage(h, 0x0111, (IntPtr)yesId, yes);   // WM_COMMAND: the same as clicking Yes
        done = string.Join(" ", texts.ToArray()).Trim();
        return false;
      }
      return true; }, IntPtr.Zero);
    return done;
  }
}
"@

$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
  $ids = if ($pl.Count) { @($pl | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }) }
         else { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(TheLightingContr|ShowXpress)' -and $_.ProcessName -notmatch 'Helper|sxh|setup|unins|updat' } | ForEach-Object { $_.Id }) }
  if (-not $ids.Count) { 'gone'; return }
  $a = [SxQuit]::Answer([uint32[]]$ids, [string[]]$quit)
  if ($a) { "answered: $a"; return }
  Start-Sleep -Milliseconds 250
}
'timeout'
