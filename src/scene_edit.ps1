# SCENE EDITOR (phase 1 of SX Studio's own editor, user 2026-11-24) - reads and changes ShowXpress scenes (.scex).
#
#   Rules (user): ShowXpress must still open every file written, and anything the editor doesn't understand is passed
#   through untouched. So a save never rebuilds a scene: it starts from the file's own text and changes only
#     - the value="" / length="" of what was edited (and adds or removes fade="1"),
#     - whole <Step> blocks (copied as text for a new step, left out for a deleted one, put in a new order),
#     - whole <Channel .../> lines (a channel added to / taken out of one head in every step).
#   Everything else - the header, the fixture list, tags and attributes the editor doesn't know, comments, spacing,
#   the BOM and the line endings - stays byte for byte as it was.
#   Before anything is written the result is checked: the same changes are made a second, independent way (on the
#   parsed XML) and both must give the same scene, and the text outside <Steps> must be unchanged. If not: NOTHING is
#   written. Every save keeps the previous file as a backup (Backups / Revert).
#
#   -Action List                         -> JSON: every scene in scenes/ (steps, heads, buttons that use it, trimmed)
#   -Action Open -Scene "X.scex"         -> JSON: the scene for the editor (steps, heads, channels, named ranges, DMX addresses)
#   -Action Save -ChangesFile f.json     -> writes the changes (ShowXpress must be closed)
#        {scene, sha, steps:[{src, len, set:[{fx, ix, v, fade}]}], addch:[{fx, ix}], delch:[{fx, ix}]}
#        steps = the new list of steps, each a copy of old step number src (0-based), in order; len = new length (1/100 s)
#        set = changed channels (v = 0..255, fade = true/false; either may be left out). The order of the work:
#        delch, addch (value 0, no fade, in every step that has that head), then each step's len + set.
#   -Action Backups -Scene "X.scex"      -> JSON: the backups of a scene, newest first
#   -Action Revert -Scene "X.scex" -Backup <id> [-Force]  -> puts a backup back (the current file is backed up first)
#   -Action Check                        -> JSON: every scene read and "saved" with no changes in memory (nothing is
#                                           written) - each must come out byte for byte the same (tests, and a real show)
param(
  [ValidateSet('List', 'Open', 'Save', 'Backups', 'Revert', 'Check')][string]$Action = 'List',
  [string]$Scene = '',
  [string]$ChangesFile = '',
  [string]$Backup = '',
  [switch]$Force,
  [string]$TestRoot = ''   # testing only: run against a copy of the show, skip the ShowXpress check
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'show_common.ps1')

$root = if ($TestRoot) { $TestRoot } else { Find-Show }
if (-not (Test-Path -LiteralPath "$root/scenes")) { throw "The show has no scenes folder ($root). NOTHING was changed." }
$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$maxBackups = 20

function Get-BytesSha([byte[]]$b) { ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace '-', '').ToLower() }
function ConvertTo-Bytes([string]$text, [bool]$bom) {
  $b = $utf8Strict.GetBytes($text)
  if (-not $bom) { return ,$b }
  $o = New-Object byte[] ($b.Length + 3); $o[0] = 0xEF; $o[1] = 0xBB; $o[2] = 0xBF; [Array]::Copy($b, 0, $o, 3, $b.Length); ,$o
}
function Test-SameBytes([byte[]]$a, [byte[]]$b) { $a.Length -eq $b.Length -and (Get-BytesSha $a) -eq (Get-BytesSha $b) }
function Get-SceneFile([string]$name) {
  # only a plain .scex file name, in scenes/
  if ($name -notmatch '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$' -or $name -match '^\.') { throw "Not a scene name: '$name'. NOTHING was changed." }
  $p = Join-Path "$root/scenes" $name
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Scene '$name' not found in the show. NOTHING was changed." }
  $p
}

# ---------------------------------------------------------------- reading a scene's text (positions kept)
function Read-SceneBytes([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  $o = if ($bom) { 3 } else { 0 }
  $t = $null; $why = ''
  try { $t = $utf8Strict.GetString($b, $o, $b.Length - $o) } catch { $why = 'the file is not plain UTF-8 text' }
  if (-not $why -and -not (Test-SameBytes (ConvertTo-Bytes $t $bom) $b)) { $why = 'the file does not read back the same way'; $t = $null }
  [pscustomobject]@{ Bytes = $b; Bom = $bom; Text = $t; Why = $why; Sha = (Get-BytesSha $b) }
}

# The reader: one pass over the text with the positions of every step, head, channel and attribute. In C# because a
# big chase (64 steps x 22 heads x 19 channels) took seconds in PowerShell; compiled once and kept, like the player.
$sxsCs = @"
using System; using System.Collections.Generic; using System.Net; using System.Text; using System.Text.RegularExpressions; using System.Xml;
public class SxsAttr { public string v, raw; public int vs, ve, @as, ae; }
public class SxsCh { public int ix = -1, v = -1, start, end, insAt; public string name = ""; public SxsAttr val, fadeA; public bool fade, self; }
public class SxsFx { public string id = ""; public int start, closeAt = -1; public bool self; public List<SxsCh> ch = new List<SxsCh>(); }
public class SxsStep { public int n, from, start, end = -1, insAt; public SxsAttr len; public List<SxsFx> fx = new List<SxsFx>(); }
public class SxsHead { public string id = "", name = "", model = ""; }
public class SxsScene {
  public bool ok, structural = true; public string why = "", nl = "\n"; public int open = -1, close = -1;
  public List<SxsStep> steps = new List<SxsStep>(); public List<SxsHead> heads = new List<SxsHead>();
  static readonly Regex Tok = new Regex("<!--[\\s\\S]*?-->|<!\\[CDATA\\[[\\s\\S]*?\\]\\]>|<\\?[\\s\\S]*?\\?>|<!DOCTYPE[^>]*>|<(/?)([A-Za-z_][\\w.:\\-]*)((?:\\s+[^\\s=/>]+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'))*)\\s*(/?)>|<", RegexOptions.Compiled);
  static readonly Regex Att = new Regex("\\s+([^\\s=/>]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", RegexOptions.Compiled);
  static Dictionary<string, SxsAttr> Attrs(Match m) {
    Dictionary<string, SxsAttr> r = new Dictionary<string, SxsAttr>(); Group g = m.Groups[3];
    foreach (Match a in Att.Matches(g.Value)) {
      Group vg = a.Groups[2].Success ? a.Groups[2] : a.Groups[3];
      SxsAttr x = new SxsAttr(); x.raw = vg.Value; x.v = WebUtility.HtmlDecode(vg.Value);
      x.vs = g.Index + vg.Index; x.ve = x.vs + vg.Length; x.@as = g.Index + a.Index; x.ae = x.@as + a.Length;
      r[a.Groups[1].Value] = x;
    }
    return r;
  }
  static string A(Dictionary<string, SxsAttr> d, string k) { SxsAttr x; return d.TryGetValue(k, out x) ? x.v : ""; }
  static bool Num(string s, int max, out int v) { v = -1; if (s == null || s.Length < 1 || s.Length > 3) return false; foreach (char c in s) if (c < '0' || c > '9') return false; v = int.Parse(s); return v <= max; }
  public static SxsScene Read(string t) {
    SxsScene r = new SxsScene(); if (t.Contains("\r\n")) r.nl = "\r\n";
    List<string> st = new List<string>(); SxsStep step = null; SxsFx fx = null; int roots = 0, lastEnd = -1;
    foreach (Match m in Tok.Matches(t)) {
      if (!m.Groups[2].Success) {
        if (m.Value == "<") { r.why = "it has a \"<\" the editor does not understand"; return r; }
        if (st.Count == 2 && st[1] == "Steps") r.structural = false;   // a comment between steps
        continue;
      }
      string name = m.Groups[2].Value; int end = m.Index + m.Length, d;
      if (m.Groups[1].Value == "/") {
        if (st.Count == 0 || st[st.Count - 1] != name) { r.why = "its <" + name + "> tags don't match up"; return r; }
        st.RemoveAt(st.Count - 1); d = st.Count;
        if (d == 2 && name == "Step" && step != null) { step.end = end; lastEnd = end; step = null; }
        else if (d == 3 && name == "Fixture" && fx != null) { fx.closeAt = m.Index; fx = null; }
        else if (d == 1 && name == "Steps" && r.open >= 0 && r.close < 0) r.close = m.Index;
        continue;
      }
      bool self = m.Groups[4].Value == "/"; d = st.Count; int insAt = m.Groups[3].Index + m.Groups[3].Length;
      if (d == 0) { roots++; if (name != "Scene") { r.why = "it is not a scene file"; return r; } }
      else if (d == 1 && name == "Steps") {
        if (r.open >= 0) { r.why = "it has two lists of steps"; return r; }
        if (self) { r.why = "it has no steps"; return r; }
        r.open = end; lastEnd = end;
      }
      else if (d == 2 && st[1] == "Steps") {
        if (name != "Step") r.structural = false;
        else {
          Dictionary<string, SxsAttr> at = Attrs(m); SxsAttr la; at.TryGetValue("length", out la);
          step = new SxsStep(); step.n = r.steps.Count; step.from = lastEnd; step.start = m.Index; step.insAt = insAt; step.len = la;
          r.steps.Add(step);
          if (self) { step.end = end; lastEnd = end; step = null; }
        }
      }
      else if (d == 2 && st[1] == "Fixtures" && name == "Fixture") {
        Dictionary<string, SxsAttr> at = Attrs(m); SxsHead h = new SxsHead(); h.id = A(at, "id"); h.name = A(at, "name"); h.model = A(at, "model"); r.heads.Add(h);
      }
      else if (d == 3 && st[2] == "Step" && name == "Fixture" && step != null) {
        Dictionary<string, SxsAttr> at = Attrs(m);
        fx = new SxsFx(); fx.id = A(at, "id"); fx.start = m.Index; fx.self = self; step.fx.Add(fx); if (self) fx = null;
      }
      else if (d == 4 && st[3] == "Fixture" && st[2] == "Step" && name == "Channel" && fx != null) {
        Dictionary<string, SxsAttr> at = Attrs(m); SxsCh c = new SxsCh(); int v;
        if (Num(A(at, "index"), 999, out v)) c.ix = v;
        at.TryGetValue("value", out c.val); if (c.val != null && Num(c.val.v, 255, out v)) c.v = v;
        at.TryGetValue("fade", out c.fadeA); c.fade = c.fadeA != null && c.fadeA.v == "1";
        c.name = A(at, "name"); c.start = m.Index; c.end = end; c.insAt = insAt; c.self = self; fx.ch.Add(c);
      }
      if (!self) st.Add(name);
    }
    if (st.Count > 0) { r.why = "its <" + st[st.Count - 1] + "> is never closed"; return r; }
    if (roots != 1) { r.why = "it is not a single scene"; return r; }
    if (r.open < 0 || r.close < 0) { r.why = "it has no list of steps"; return r; }
    if (r.steps.Count == 0) { r.why = "it has no steps"; return r; }
    // only whitespace between the steps, or steps can't be added / moved (the in-between bits would move with them)
    foreach (SxsStep s in r.steps) if (t.Substring(s.from, s.start - s.from).Trim().Length > 0) r.structural = false;
    if (t.Substring(lastEnd, r.close - lastEnd).Trim().Length > 0) r.structural = false;
    r.ok = true; return r;
  }
  // the steps as one string - from this reader, and from the XML parser: the two must agree or the scene isn't edited
  public string Model() {
    StringBuilder b = new StringBuilder();
    foreach (SxsStep s in steps) {
      if (b.Length > 0) b.Append('\n');
      b.Append(s.len != null ? s.len.v : "").Append('|'); bool f1 = true;
      foreach (SxsFx f in s.fx) {
        if (!f1) b.Append(';'); f1 = false; b.Append(f.id).Append(':'); bool c1 = true;
        foreach (SxsCh c in f.ch) { if (!c1) b.Append(','); c1 = false; b.Append(c.ix).Append('=').Append(c.val != null ? c.val.v : "").Append(c.fade ? "f" : ""); }
      }
    }
    return b.ToString();
  }
  public static string XmlModel(string t) {
    XmlDocument x = new XmlDocument(); x.PreserveWhitespace = true; x.LoadXml(t);
    StringBuilder b = new StringBuilder(); bool first = true;
    foreach (XmlElement s in x.SelectNodes("/Scene/Steps/Step")) {
      if (!first) b.Append('\n'); first = false;
      b.Append(s.GetAttribute("length")).Append('|'); bool f1 = true;
      foreach (XmlNode fn in s.ChildNodes) {
        XmlElement f = fn as XmlElement; if (f == null || f.Name != "Fixture") continue;
        if (!f1) b.Append(';'); f1 = false; b.Append(f.GetAttribute("id")).Append(':'); bool c1 = true;
        foreach (XmlNode cn in f.ChildNodes) {
          XmlElement c = cn as XmlElement; if (c == null || c.Name != "Channel") continue;
          int ix; if (!Num(c.GetAttribute("index"), 999, out ix)) ix = -1;
          if (!c1) b.Append(','); c1 = false; b.Append(ix).Append('=').Append(c.GetAttribute("value")).Append(c.GetAttribute("fade") == "1" ? "f" : "");
        }
      }
    }
    return b.ToString();
  }
  // model -> index -> channel name, for the heads of the given models (ShowXpress's own names, from any scene)
  public static void Names(string t, Dictionary<string, bool> want, Dictionary<string, Dictionary<int, string>> into) {
    SxsScene s = Read(t); if (!s.ok) return;
    Dictionary<string, string> mo = new Dictionary<string, string>(); foreach (SxsHead h in s.heads) mo[h.id] = h.model;
    foreach (SxsStep p in s.steps) foreach (SxsFx f in p.fx) {
      string m; if (!mo.TryGetValue(f.id, out m) || !want.ContainsKey(m)) continue;
      Dictionary<int, string> d; if (!into.TryGetValue(m, out d)) { d = new Dictionary<int, string>(); into[m] = d; }
      foreach (SxsCh c in f.ch) if (c.ix >= 0 && c.name != "" && !d.ContainsKey(c.ix)) d[c.ix] = c.name;
    }
  }
}
"@
if (-not ('SxsScene' -as [type])) {
  try {
    $h = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sxsCs))).Replace('-', '').Substring(0, 16)
    $cd = if ($onMac) { Join-Path $HOME 'AwaazTools/cache' } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'ShowXpress Helper\cache' } else { Join-Path ([IO.Path]::GetTempPath()) 'sxs_cache' }
    $dll = Join-Path $cd "sxscene_$h.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
      New-Item -ItemType Directory -Force $cd | Out-Null
      $tmpDll = Join-Path $cd "sxscene_$h.$PID.dll"
      Add-Type -TypeDefinition $sxsCs -OutputAssembly $tmpDll -OutputType Library
      try { Move-Item -LiteralPath $tmpDll $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmpDll -ErrorAction SilentlyContinue }
      Get-ChildItem -LiteralPath $cd -Filter 'sxscene_*.dll' | Where-Object { $_.FullName -ne $dll } | Remove-Item -ErrorAction SilentlyContinue
    }
    try { Add-Type -Path $dll } catch { Remove-Item -LiteralPath $dll -ErrorAction SilentlyContinue }   # damaged: built again next time
  } catch {}
  if (-not ('SxsScene' -as [type])) { Add-Type -TypeDefinition $sxsCs }
}
function Read-SceneText([string]$t) { [SxsScene]::Read($t) }

function Get-StepModel($sc) { $sc.Model() }
function Get-XmlStepModel([string]$t) { [SxsScene]::XmlModel($t) }
function Open-Scene([string]$path) {
  # -> @{ file; sc (Read-SceneText) or $null; why (why it can't be edited) }
  $f = Read-SceneBytes $path
  $o = [pscustomobject]@{ File = $f; Sc = $null; Why = $f.Why }
  if ($o.Why) { return $o }
  $sc = Read-SceneText $f.Text
  if (-not $sc.ok) { $o.Why = $sc.why; return $o }
  try { $xm = Get-XmlStepModel $f.Text } catch { $o.Why = 'it is not valid XML'; return $o }
  if ($xm -ne (Get-StepModel $sc)) { $o.Why = 'the editor could not read it safely'; return $o }
  $o.Sc = $sc; $o
}

# ---------------------------------------------------------------- the changes, made two ways
function Get-Indent([string]$t, [int]$at) {
  $ls = $t.LastIndexOf("`n", [Math]::Max(0, $at - 1)) + 1; if ($at -eq 0) { $ls = 0 }
  $w = $t.Substring($ls, $at - $ls); if ($w.Trim()) { return $null }; $w
}
function Test-OwnLine([string]$t, $c) {
  # the tag is alone on its line -> its line can be taken out whole
  if ($null -eq (Get-Indent $t $c.start)) { return $false }
  $e = $t.IndexOf("`n", $c.end); $rest = if ($e -lt 0) { $t.Substring($c.end) } else { $t.Substring($c.end, $e - $c.end) }
  -not $rest.Trim() -and $c.start -gt 0
}
function Get-NewChannelTag($ix, [string]$name) { "<Channel index=`"$ix`" name=`"$([Security.SecurityElement]::Escape($name))`" value=`"0`"/>" }
function Get-ChangedText($o, $ch, $names) {
  # the text way: edits on the file's own text -> new text
  $t = $o.File.Text; $sc = $o.Sc; $nl = $sc.nl
  $edits = New-Object Collections.Generic.List[object]   # per old step: list of @(at, length, new text), relative to the file
  $perStep = @{}
  $E = { param($s, $at, $len, $txt) if (-not $perStep.ContainsKey($s.n)) { $perStep[$s.n] = New-Object Collections.Generic.List[object] }; $perStep[$s.n].Add(@($at, $len, $txt)) }
  # delch / addch hit every step the same way - done on the old steps (a copied step gets them too)
  foreach ($dc in @($ch.delch)) {
    foreach ($s in $sc.steps) { foreach ($f in @($s.fx | Where-Object { $_.id -eq "$($dc.fx)" })) {
      foreach ($c in @($f.ch | Where-Object { $_.ix -eq [int]$dc.ix })) {
        if (Test-OwnLine $t $c) {
          $ls = $t.LastIndexOf("`n", $c.start - 1); if ($ls -gt 0 -and $t[$ls - 1] -eq "`r") { $ls-- }
          & $E $s $ls ($c.end - $ls) ''
        } else { & $E $s $c.start ($c.end - $c.start) '' }
      } } }
  }
  foreach ($ac in @($ch.addch)) {
    $tag = Get-NewChannelTag ([int]$ac.ix) $names["$($ac.fx)|$($ac.ix)"]
    foreach ($s in $sc.steps) { foreach ($f in @($s.fx | Where-Object { $_.id -eq "$($ac.fx)" })) {
      if (@($f.ch | Where-Object { $_.ix -eq [int]$ac.ix }).Count) { continue }
      $kept = @($f.ch | Where-Object { $cc = $_; -not @(@($ch.delch) | Where-Object { "$($_.fx)" -eq $f.id -and [int]$_.ix -eq $cc.ix }).Count })
      if (-not $kept.Count) { throw "Head $($f.id) has no channels left in step $($s.n + 1), so a channel can't be added there. NOTHING was changed." }
      $after = @($kept | Where-Object { $_.ix -lt [int]$ac.ix }) | Select-Object -Last 1
      if ($after) {
        $ind = Get-Indent $t $after.start
        if ($null -ne $ind -and (Test-OwnLine $t $after)) { & $E $s $after.end 0 ($nl + $ind + $tag) } else { & $E $s $after.end 0 $tag }
      } else {
        $first = $kept[0]; $ind = Get-Indent $t $first.start
        if ($null -ne $ind -and (Test-OwnLine $t $first)) { & $E $s ($first.start - $ind.Length) 0 ($ind + $tag + $nl) } else { & $E $s $first.start 0 $tag }
      }
    } }
  }
  # the new list of steps: each a copy of an old step's text (with its leading spacing), with its own edits
  $parts = New-Object Text.StringBuilder
  [void]$parts.Append($t.Substring(0, $sc.open))
  foreach ($ns in @($ch.steps)) {
    $s = $sc.steps[[int]$ns.src]; $ed = New-Object Collections.Generic.List[object]
    if ($perStep.ContainsKey($s.n)) { foreach ($x in $perStep[$s.n]) { $ed.Add(@($x[0], $x[1], $x[2])) } }   # a copy: a copied step has its own
    if ($null -ne $ns.len) {
      $lv = "$([int]$ns.len)"
      if ($s.len) { $ed.Add(@($s.len.vs, ($s.len.ve - $s.len.vs), $lv)) } else { $ed.Add(@($s.insAt, 0, " length=`"$lv`"")) }
    }
    foreach ($st in @($ns.set)) {
      if (-not $st) { continue }
      $f = @($s.fx | Where-Object { $_.id -eq "$($st.fx)" }) | Select-Object -First 1
      if (-not $f) { throw "Head $($st.fx) is not in step $($s.n + 1). NOTHING was changed." }
      $c = @($f.ch | Where-Object { $_.ix -eq [int]$st.ix }) | Select-Object -First 1
      if (-not $c) {
        # a channel added just now: its new tag is in this step's edits - change it there
        $tagOld = Get-NewChannelTag ([int]$st.ix) $names["$($st.fx)|$($st.ix)"]
        $hit = $null; foreach ($x in $ed) { if ($x[2].Contains($tagOld)) { $hit = $x } }
        if (-not $hit -or -not @(@($ch.addch) | Where-Object { "$($_.fx)" -eq "$($st.fx)" -and [int]$_.ix -eq [int]$st.ix }).Count) { throw "Channel $($st.ix) of head $($st.fx) is not in step $($s.n + 1). NOTHING was changed." }
        $nt = $tagOld
        if ($null -ne $st.v) { $nt = $nt.Replace('value="0"', "value=`"$([int]$st.v)`"") }
        if ($st.fade -eq $true) { $nt = $nt.Replace('"/>', '" fade="1"/>') }
        $hit[2] = $hit[2].Replace($tagOld, $nt); continue
      }
      if ($null -ne $st.v) {
        if ($c.v -lt 0 -or -not $c.val) { throw "Channel $($st.ix) of head $($st.fx) has a value the editor doesn't change. NOTHING was changed." }
        $ed.Add(@($c.val.vs, ($c.val.ve - $c.val.vs), "$([int]$st.v)"))
      }
      if ($null -ne $st.fade) {
        if ($st.fade -eq $true -and -not $c.fade) {
          if ($c.fadeA) { $ed.Add(@($c.fadeA.vs, ($c.fadeA.ve - $c.fadeA.vs), '1')) } else { $ed.Add(@($c.insAt, 0, ' fade="1"')) }
        } elseif ($st.fade -eq $false -and $c.fadeA) { $ed.Add(@($c.fadeA.as, ($c.fadeA.ae - $c.fadeA.as), '')) }
      }
    }
    # apply this step's edits from the back, on its own text
    $chunk = $t.Substring($s.from, $s.end - $s.from)
    # from the back; at the same place a removal goes before an insert (so the insert isn't removed with it)
    foreach ($x in @($ed | Sort-Object { $_[0] }, { $_[1] } -Descending)) { $chunk = $chunk.Remove($x[0] - $s.from, $x[1]).Insert($x[0] - $s.from, $x[2]) }
    [void]$parts.Append($chunk)
  }
  $last = $sc.steps[$sc.steps.Count - 1].end
  [void]$parts.Append($t.Substring($last))
  $parts.ToString()
}
function Get-ChangedXml($o, $ch, $names) {
  # the XML way: the same changes on the parsed scene -> canonical XML
  $x = New-Object Xml.XmlDocument; $x.LoadXml($o.File.Text)
  $stepsNode = $x.SelectSingleNode('/Scene/Steps'); $old = @($stepsNode.SelectNodes('Step'))
  foreach ($dc in @($ch.delch)) { foreach ($s in $old) { foreach ($f in @($s.SelectNodes('Fixture'))) { if ($f.GetAttribute('id') -ne "$($dc.fx)") { continue }
    foreach ($c in @($f.SelectNodes('Channel'))) { if ($c.GetAttribute('index') -match '^\d{1,3}$' -and [int]$c.GetAttribute('index') -eq [int]$dc.ix) { [void]$f.RemoveChild($c) } } } } }
  foreach ($ac in @($ch.addch)) { foreach ($s in $old) { foreach ($f in @($s.SelectNodes('Fixture'))) { if ($f.GetAttribute('id') -ne "$($ac.fx)") { continue }
    $cs = @($f.SelectNodes('Channel')); $ixOf = { param($c) if ($c.GetAttribute('index') -match '^\d{1,3}$') { [int]$c.GetAttribute('index') } else { -1 } }
    if (@($cs | Where-Object { (& $ixOf $_) -eq [int]$ac.ix }).Count) { continue }
    $n = $x.CreateElement('Channel'); $n.SetAttribute('index', "$([int]$ac.ix)"); $n.SetAttribute('name', $names["$($ac.fx)|$($ac.ix)"]); $n.SetAttribute('value', '0')
    $after = @($cs | Where-Object { (& $ixOf $_) -lt [int]$ac.ix }) | Select-Object -Last 1
    if ($after) { [void]$f.InsertAfter($n, $after) } else { [void]$f.InsertBefore($n, $cs[0]) } } } }
  $new = @(foreach ($ns in @($ch.steps)) {
    $s = $old[[int]$ns.src].CloneNode($true)
    if ($null -ne $ns.len) { $s.SetAttribute('length', "$([int]$ns.len)") }
    foreach ($st in @($ns.set)) { if (-not $st) { continue }
      foreach ($f in @($s.SelectNodes('Fixture'))) { if ($f.GetAttribute('id') -ne "$($st.fx)") { continue }
        foreach ($c in @($f.SelectNodes('Channel'))) { if ($c.GetAttribute('index') -notmatch '^\d{1,3}$' -or [int]$c.GetAttribute('index') -ne [int]$st.ix) { continue }
          if ($null -ne $st.v) { $c.SetAttribute('value', "$([int]$st.v)") }
          if ($st.fade -eq $true) { $c.SetAttribute('fade', '1') } elseif ($st.fade -eq $false) { $c.RemoveAttribute('fade') } } } }
    $s })
  if ($o.Sc.structural) { foreach ($s in $old) { [void]$stepsNode.RemoveChild($s) }; foreach ($s in $new) { [void]$stepsNode.AppendChild($s) } }
  else { for ($i = 0; $i -lt $old.Count; $i++) { [void]$stepsNode.ReplaceChild($new[$i], $old[$i]) } }
  $x.OuterXml
}
function Get-CanonXml([string]$t) { $x = New-Object Xml.XmlDocument; $x.LoadXml($t); $x.OuterXml }

function Test-Changes($o, $ch) {
  # what may be changed, before anything is done
  $sc = $o.Sc; $n = $sc.steps.Count
  $steps = @($ch.steps | Where-Object { $null -ne $_ })
  if (-not $steps.Count) { throw "A scene needs at least one step. NOTHING was changed." }
  if ($steps.Count -gt 999) { throw "Too many steps. NOTHING was changed." }
  foreach ($s in $steps) {
    if ("$($s.src)" -notmatch '^\d+$' -or [int]$s.src -ge $n) { throw "Unknown step. NOTHING was changed." }
    if ($null -ne $s.len -and ("$($s.len)" -notmatch '^\d+$' -or [int]$s.len -lt 1 -or [int]$s.len -gt 999999)) { throw "A step length has to be 1 or more (1/100 s). NOTHING was changed." }
    foreach ($x in @($s.set)) { if (-not $x) { continue }
      if ("$($x.fx)" -notmatch '^[\w\-]{1,40}$' -or "$($x.ix)" -notmatch '^\d{1,3}$') { throw "Unknown channel. NOTHING was changed." }
      if ($null -ne $x.v -and ("$($x.v)" -notmatch '^\d{1,3}$' -or [int]$x.v -gt 255)) { throw "A value has to be 0 to 255. NOTHING was changed." }
      if ($null -ne $x.fade -and $x.fade -isnot [bool]) { throw "Bad fade setting. NOTHING was changed." } }
  }
  $ident = $steps.Count -eq $n; for ($i = 0; $ident -and $i -lt $n; $i++) { if ([int]$steps[$i].src -ne $i) { $ident = $false } }
  if (-not $ident -and -not $sc.structural) { throw "This scene has something between its steps that the editor doesn't know, so its steps can be changed but not added, taken out or moved. NOTHING was changed." }
  $heads = @{}; foreach ($h in $sc.heads) { $heads[$h.id] = $h }
  $seen = @{}
  foreach ($x in @(@($ch.addch) + @($ch.delch))) { if (-not $x) { continue }
    if ("$($x.fx)" -notmatch '^[\w\-]{1,40}$' -or "$($x.ix)" -notmatch '^\d{1,3}$' -or -not $heads.ContainsKey("$($x.fx)")) { throw "Unknown head or channel. NOTHING was changed." }
    $k = "$($x.fx)|$([int]$x.ix)"; if ($seen.ContainsKey($k)) { throw "A channel is both added and taken out. NOTHING was changed." }; $seen[$k] = 1 }
  $gone = @{}; foreach ($x in @($ch.delch)) { if ($x) { $gone["$($x.fx)|$([int]$x.ix)"] = 1 } }
  foreach ($s in $steps) { foreach ($x in @($s.set)) { if ($x -and $gone.ContainsKey("$($x.fx)|$([int]$x.ix)")) { throw "A channel that is taken out can't be changed too. NOTHING was changed." } } }
  ,$steps
}

# ---------------------------------------------------------------- show info
function Get-Patch {
  $a = @{}; $cur = $null
  if (Test-Path -LiteralPath "$root/fixtures.ini") {
    foreach ($l in [IO.File]::ReadAllLines("$root/fixtures.ini")) {
      if ($l -match '^\[') { $cur = @{}; continue }
      if ($null -eq $cur) { continue }
      if ($l -match '^address = (\d+)') { $cur.a = [int]$matches[1] }
      if ($l -match '^id = (\S+)\s*$') { $cur.id = $matches[1] }
      if ($cur.id -and $cur.a) { $a[$cur.id] = $cur.a }
    }
  }
  $a
}
function Get-UsedBy {
  # scene file -> list of "PAGE: title"
  $r = @{}
  try { $info = Get-LiveInfo $root } catch { return $r }
  foreach ($b in $info.Buttons) {
    if ("$($b.Name)" -notlike '*.scex') { continue }
    $k = "$($b.Name)".ToLower(); if (-not $r.ContainsKey($k)) { $r[$k] = New-Object Collections.Generic.List[object] }
    $r[$k].Add([pscustomobject]@{ page = $b.PageName; title = $(if ($b.Title) { $b.Title } else { $b.Name -replace '\.scex$', '' }); sec = $b.Sec })
  }
  $r
}
function Get-RigTrimmed {
  # scene files Tonight's Rig has trimmed right now -> their sha (as rig.ps1 writes it)
  $r = @{}; $p = "$root/rig_state.json"
  if (-not (Test-Path -LiteralPath $p)) { return $r }
  try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return $r }
  if ($j.scenes) { foreach ($q in $j.scenes.PSObject.Properties) { $r["$($q.Name)".ToLower()] = "$($q.Value.written)" } }
  $r
}
function Test-Trimmed($trim, [string]$name, [string]$path) {
  $w = $trim["$name".ToLower()]
  $w -and (Get-TextSha ([IO.File]::ReadAllText($path))) -eq $w
}
function Get-ChannelNames($o) {
  # model -> index -> channel name, from this scene and then every other scene (names as ShowXpress wrote them)
  $sc = $o.Sc
  $want = New-Object 'Collections.Generic.Dictionary[string,bool]'
  foreach ($h in $sc.heads) { if ($h.model) { $want[$h.model] = $true } }
  $r = New-Object 'Collections.Generic.Dictionary[string,Collections.Generic.Dictionary[int,string]]'
  [SxsScene]::Names($o.File.Text, $want, $r)
  foreach ($fi in @(Get-ChildItem -LiteralPath "$root/scenes" -Filter '*.scex' -File -ErrorAction SilentlyContinue)) {
    try { $t = [IO.File]::ReadAllText($fi.FullName) } catch { continue }
    $hit = $false; foreach ($k in $want.Keys) { if ($t.Contains([Security.SecurityElement]::Escape($k))) { $hit = $true; break } }
    if ($hit) { [SxsScene]::Names($t, $want, $r) }
  }
  $r
}
function Get-Ranges([string]$model) {
  # channel name (lowercase) -> named ranges from fixtures/<model>.txt (Get-FixtureDef)
  $d = Get-FixtureDef $root $model; $o = [ordered]@{}
  foreach ($k in $d.Keys) { $rs = @($d[$k] | Where-Object { $_ }); if ($rs.Count) { $o[$k] = @($rs | ForEach-Object { [pscustomobject]@{ n = $_.n; lo = $_.lo; hi = $_.hi } }) } }
  $o
}

# ---------------------------------------------------------------- backups (outside the show folder, so Google Drive never gets them)
function Get-BackupDir([string]$name) {
  $base = if ($TestRoot) { Join-Path (Split-Path $TestRoot) 'scene_backups' }
          elseif ($onMac) { Join-Path $HOME 'AwaazTools/scene_backups' }
          else { Join-Path $env:APPDATA 'ShowXpress Helper/scene_backups' }
  Join-Path (Join-Path $base (Split-Path $root -Leaf)) $name
}
function Get-Backups([string]$name) {
  $d = Get-BackupDir $name
  if (-not (Test-Path -LiteralPath $d)) { return @() }
  @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File | Sort-Object Name -Descending | ForEach-Object {
    try { $j = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } catch { return }
    $f = Join-Path $d ($_.BaseName + '.scex')
    if (Test-Path -LiteralPath $f) { [pscustomobject]@{ id = $_.BaseName; at = "$($j.at)"; what = "$($j.what)"; written = "$($j.written)"; path = $f } }
  })
}
function Add-Backup([string]$name, [byte[]]$bytes, [string]$what) {
  $d = Get-BackupDir $name
  New-Item -ItemType Directory -Force $d | Out-Null
  $id = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  [IO.File]::WriteAllBytes((Join-Path $d "$id.scex"), $bytes)
  $o = [pscustomobject]@{ id = $id; dir = $d; json = (Join-Path $d "$id.json"); at = (Get-Date).ToString('s'); what = $what }
  $o
}
function Save-BackupInfo($bk, [string]$written) {
  [IO.File]::WriteAllText($bk.json, ([ordered]@{ at = $bk.at; what = $bk.what; written = $written } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  foreach ($old in @(Get-Backups $name | Select-Object -Skip $maxBackups)) {
    Remove-Item -LiteralPath $old.path -ErrorAction SilentlyContinue; Remove-Item -LiteralPath ($old.path -replace '\.scex$', '.json') -ErrorAction SilentlyContinue
  }
}
function Write-SceneBytes([string]$path, [byte[]]$bytes) {
  # write next to it, then swap it in (a half-written scene is never left behind); read back to be sure
  $tmp = "$path.sxs-tmp"
  [IO.File]::WriteAllBytes($tmp, $bytes)
  try { [IO.File]::Replace($tmp, $path, $null) } catch { [IO.File]::Copy($tmp, $path, $true); Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  if (-not (Test-SameBytes ([IO.File]::ReadAllBytes($path)) $bytes)) { throw "The scene didn't read back the same after saving. Use Revert to put the earlier version back." }
}

# ================================================================ actions
if ($Action -eq 'List') {
  $used = Get-UsedBy; $trim = Get-RigTrimmed; $stRx = [regex]'<Step[\s>/]'; $hdRx = [regex]'(?s)<Fixtures>(.*?)</Fixtures>'
  $list = foreach ($fi in @(Get-ChildItem -LiteralPath "$root/scenes" -Filter '*.scex' -File | Sort-Object Name)) {
    $t = ''; try { $t = [IO.File]::ReadAllText($fi.FullName) } catch {}
    $hm = $hdRx.Match($t); $nh = if ($hm.Success) { ([regex]'<Fixture\s').Matches($hm.Groups[1].Value).Count } else { 0 }
    $u = $used[$fi.Name.ToLower()]
    [pscustomobject]@{ file = $fi.Name; name = ($fi.Name -replace '\.scex$', ''); steps = $stRx.Matches($t).Count; heads = $nh
      used = @(if ($u) { $u | ForEach-Object { "$($_.page): $($_.title)" } }); trimmed = [bool](Test-Trimmed $trim $fi.Name $fi.FullName); at = $fi.LastWriteTime.ToString('s') }
  }
  [pscustomobject]@{ ok = $true; show = $root; scenes = @($list) } | ConvertTo-Json -Depth 4 -Compress
  return
}

if ($Action -eq 'Check') {
  $res = foreach ($fi in @(Get-ChildItem -LiteralPath "$root/scenes" -Filter '*.scex' -File | Sort-Object Name)) {
    $o = Open-Scene $fi.FullName; $same = $false; $self = $false
    if (-not $o.Why) {
      $ch = [pscustomobject]@{ steps = @(for ($i = 0; $i -lt $o.Sc.steps.Count; $i++) { [pscustomobject]@{ src = $i; len = $null; set = @() } }); addch = @(); delch = @() }
      $nt = Get-ChangedText $o $ch @{}
      $same = Test-SameBytes (ConvertTo-Bytes $nt $o.File.Bom) $o.File.Bytes
      $self = (Get-CanonXml $nt) -eq (Get-ChangedXml $o $ch @{})
    }
    [pscustomobject]@{ file = $fi.Name; editable = (-not $o.Why); why = $o.Why; structural = [bool]($o.Sc -and $o.Sc.structural); same = $same; selfCheck = $self }
  }
  $res = @($res)
  [pscustomobject]@{ ok = $true; show = $root; scenes = $res; total = $res.Count; editable = @($res | Where-Object editable).Count
    bad = @($res | Where-Object { $_.editable -and -not ($_.same -and $_.selfCheck) } | ForEach-Object file) } | ConvertTo-Json -Depth 4 -Compress
  return
}

if ($Action -eq 'Open') {
  $path = Get-SceneFile $Scene; $o = Open-Scene $path
  $used = Get-UsedBy; $u = $used[$Scene.ToLower()]
  $base = [ordered]@{ ok = $true; show = $root; file = $Scene; name = ($Scene -replace '\.scex$', ''); sha = $o.File.Sha
    used = @(if ($u) { $u | ForEach-Object { "$($_.page): $($_.title)" } }); trimmed = [bool](Test-Trimmed (Get-RigTrimmed) $Scene $path)
    readonly = $o.Why; structural = [bool]($o.Sc -and $o.Sc.structural); backups = @(Get-Backups $Scene).Count }
  if ($o.Why) { [pscustomobject]$base | ConvertTo-Json -Depth 3 -Compress; return }
  $sc = $o.Sc; $patch = Get-Patch; $names = Get-ChannelNames $o
  $models = [ordered]@{}
  foreach ($mo in @($sc.heads | ForEach-Object { $_.model } | Select-Object -Unique)) {
    $cn = if ($names.ContainsKey($mo)) { $names[$mo] } else { $null }
    $models[$mo] = [pscustomobject]@{ chans = @(if ($cn) { foreach ($k in @($cn.Keys | Sort-Object)) { [pscustomobject]@{ ix = $k; name = $cn[$k] } } }); ranges = (Get-Ranges $mo) }
  }
  $base.heads = @($sc.heads | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; model = $_.model; addr = $(if ($patch.ContainsKey($_.id)) { $patch[$_.id] } else { 0 }) } })
  $base.models = $models
  $base.steps = @(foreach ($s in $sc.steps) {
    [pscustomobject]@{ len = $(if ($s.len -and $s.len.v -match '^\d+$') { [int]$s.len.v } else { $null }); lenRaw = $(if ($s.len) { $s.len.v } else { '' })
      fx = @(foreach ($f in $s.fx) { [pscustomobject]@{ id = $f.id; ch = @(foreach ($c in $f.ch) { ,@($c.ix, $c.name, $c.v, [int]$c.fade) }) } }) }
  })
  [pscustomobject]$base | ConvertTo-Json -Depth 8 -Compress
  return
}

if ($Action -eq 'Backups') {
  $null = Get-SceneFile $Scene
  [pscustomobject]@{ ok = $true; file = $Scene; backups = @(Get-Backups $Scene | ForEach-Object { [pscustomobject]@{ id = $_.id; at = $_.at; what = $_.what } }) } | ConvertTo-Json -Depth 3 -Compress
  return
}

# ---------------------------------------------------------------- Save / Revert: ShowXpress has to be closed
if (-not $TestRoot -and (Test-SxRunning)) { throw "ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again." }

if ($Action -eq 'Revert') {
  $path = Get-SceneFile $Scene; $name = $Scene
  $bk = @(Get-Backups $Scene | Where-Object { $_.id -eq $Backup }) | Select-Object -First 1
  if (-not $bk) { throw "That backup is not there any more. NOTHING was changed." }
  $cur = [IO.File]::ReadAllBytes($path); $curSha = Get-BytesSha $cur
  if (-not $Force -and $bk.written -and $curSha -ne $bk.written) {
    '{"conflict":true}'
    "  The scene was changed after that save (in ShowXpress or SX Studio). Revert anyway?"
    return
  }
  $old = [IO.File]::ReadAllBytes($bk.path)
  if ($curSha -eq (Get-BytesSha $old)) { "  $($Scene -replace '\.scex$', '') is already that version - nothing to change."; return }
  $nb = Add-Backup $Scene $cur "before going back to $($bk.at)"
  Write-SceneBytes $path $old
  Save-BackupInfo $nb (Get-BytesSha $old)
  "  CHANGED  $($Scene -replace '\.scex$', ''): back to the version from before $($bk.at -replace 'T', ' ')"
  return
}

# Save
$ch = Read-ChangesFile $ChangesFile
if ($ch.Count -ne 1) { throw "No changes were sent. NOTHING was changed." }
$ch = $ch[0]
$Scene = "$($ch.scene)"; $path = Get-SceneFile $Scene; $name = $Scene
$o = Open-Scene $path
if ($o.Why) { throw "$($Scene -replace '\.scex$', '') can't be changed by SX Studio: $($o.Why). NOTHING was changed." }
if ("$($ch.sha)" -ne $o.File.Sha) { throw "$($Scene -replace '\.scex$', '') was changed since you opened it (in ShowXpress or another window). Press Reload to see it as it is now. NOTHING was changed." }
$steps = Test-Changes $o $ch
$ch = [pscustomobject]@{ steps = $steps; addch = @($ch.addch | Where-Object { $_ }); delch = @($ch.delch | Where-Object { $_ }) }
$names = @{}
if ($ch.addch.Count) {
  $cn = Get-ChannelNames $o; $modelOf = @{}; foreach ($h in $o.Sc.heads) { $modelOf[$h.id] = $h.model }
  foreach ($a in $ch.addch) {
    $nm = $null; $mo = "$($modelOf["$($a.fx)"])"
    if ($cn.ContainsKey($mo) -and $cn[$mo].ContainsKey([int]$a.ix)) { $nm = $cn[$mo][[int]$a.ix] }
    if (-not $nm) { throw "Channel $($a.ix) of $($modelOf["$($a.fx)"]) has no name in any scene, so it can't be added here - add it once in ShowXpress. NOTHING was changed." }
    $names["$($a.fx)|$($a.ix)"] = $nm
  }
}
$nt = Get-ChangedText $o $ch $names
$nb = ConvertTo-Bytes $nt $o.File.Bom
if (Test-SameBytes $nb $o.File.Bytes) { "  $($Scene -replace '\.scex$', '') - nothing to change."; return }
# the checks: outside <Steps> untouched, the text way = the XML way, and SX Studio can read the result again
$sc = $o.Sc; $t = $o.File.Text
$tailOld = $t.Substring($sc.steps[$sc.steps.Count - 1].end)
if (-not $nt.StartsWith($t.Substring(0, $sc.open), [StringComparison]::Ordinal) -or -not $nt.EndsWith($tailOld, [StringComparison]::Ordinal)) { throw "Self-check failed (the scene's header would change). NOTHING was changed." }
$canon = try { Get-CanonXml $nt } catch { '' }
if (-not $canon -or $canon -ne (Get-ChangedXml $o $ch $names)) { throw "Self-check failed (the two ways of making the change don't agree). NOTHING was changed." }
$re = Read-SceneText $nt
if (-not $re.ok -or (Get-XmlStepModel $nt) -ne (Get-StepModel $re)) { throw "Self-check failed (the new scene doesn't read back cleanly). NOTHING was changed." }

$nVals = 0; $nLen = 0; foreach ($s in $steps) { $nVals += @($s.set | Where-Object { $_ }).Count; if ($null -ne $s.len) { $nLen++ } }
$what = @()
if ($steps.Count -ne $sc.steps.Count) { $what += "$($sc.steps.Count) -> $($steps.Count) steps" }
elseif (@(for ($i = 0; $i -lt $steps.Count; $i++) { if ([int]$steps[$i].src -ne $i) { 1 } }).Count) { $what += 'steps moved' }
if ($nVals) { $what += "$nVals value(s)" }
if ($nLen) { $what += "$nLen step length(s)" }
if ($ch.addch.Count) { $what += "$($ch.addch.Count) channel(s) added" }
if ($ch.delch.Count) { $what += "$($ch.delch.Count) channel(s) taken out" }
$trimmedNow = Test-Trimmed (Get-RigTrimmed) $Scene $path
$bk = Add-Backup $Scene $o.File.Bytes "before: $($what -join ', ')"
Write-SceneBytes $path $nb
Save-BackupInfo $bk (Get-BytesSha $nb)
"  CHANGED  $($Scene -replace '\.scex$', ''): $($what -join ', ')"
if ($trimmedNow) { "  NOTE  Tonight's Rig had trimmed this scene - the version you saved now counts as the full scene." }
"  backup kept: $($bk.id)"
