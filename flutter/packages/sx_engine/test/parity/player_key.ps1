# Answer key for the SX Player's frame maths. Loads the old C# player (a copy of player.ps1 that compiles under
# PowerShell 7, made by player_frames_parity_test.dart) without starting it, then replays a list of operations at
# chosen clock values and prints what the player did, one line per operation:
#   F <ms> <ch=v ...>   a frame (every channel above 0, 1-based)     S <json>   the status
#   E <message>         the operation threw                          J <text>   JStr's answer (\n, \t escaped), or J <null>
param([string]$KeyPlayer, [string]$KeyShow, [string]$KeyOps)
# player.ps1 is dot-sourced, so its own param block (-Show ...) runs in this scope: hence the Key prefix
$ErrorActionPreference = 'Stop'
. $KeyPlayer -DefineOnly
[void](Set-PlayerPatch $KeyShow)
[void](Set-PlayerBoard $KeyShow)
[SxPlayer]::SetBpm((Get-StartBpm $KeyShow), 0, 'manual')
if (-not ('SxKeyFmt' -as [type])) {
  Add-Type -TypeDefinition @"
public static class SxKeyFmt {
  public static string Sparse(byte[] f) {
    System.Text.StringBuilder b = new System.Text.StringBuilder();
    for (int i = 0; i < f.Length; i++) if (f[i] != 0) { b.Append(' '); b.Append(i + 1); b.Append('='); b.Append(f[i]); }
    return b.ToString();
  }
}
"@
}
$np = [Reflection.BindingFlags]'NonPublic,Static'
$syncLeds = [SxPlayer].GetMethod('SyncLeds', $np)
$jstr = [SxPlayer].GetMethod('JStr', $np)
$ic = [Globalization.CultureInfo]::InvariantCulture
$out = New-Object Collections.Generic.List[string]
foreach ($o in ([IO.File]::ReadAllText($KeyOps) | ConvertFrom-Json)) {
  $a = @($o)
  try {
    switch ($a[0]) {
      'frame'   { $out.Add('F ' + ([double]$a[1]).ToString($ic) + [SxKeyFmt]::Sparse([SxPlayer]::Frame([double]$a[1]))) }
      'status'  { $out.Add('S ' + [SxPlayer]::Status()) }
      'on'      { [SxPlayer]::On([string]$a[1], [string]$a[2], [double]$a[3]) }
      'off'     { [SxPlayer]::Off([string]$a[1]) }
      'alloff'  { [SxPlayer]::AllOff() }
      'bo'      { [SxPlayer]::Blackout([bool]$a[1]) }
      'press'   { [SxPlayer]::Press([string]$a[1], [double]$a[2]) }
      'seton'   { [SxPlayer]::SetOn([string]$a[1], [double]$a[2]) }
      'ton'     { [SxPlayer]::SetOn([SxPlayer]::SecOf([string]$a[1]), [double]$a[2]) }
      'key'     { [SxPlayer]::KeyPress([string]$a[1], [double]$a[2]) }
      'midi'    { [SxPlayer]::Midi([int]$a[1], [double]$a[2]) }
      'leds'    { [void]$syncLeds.Invoke($null, @([bool]$a[1])) }
      'fader'   { [SxPlayer]::SetFader([int]$a[1], [double]$a[2]) }
      'bpm'     { [SxPlayer]::SetBpm([double]$a[1], [double]$a[2], 'manual') }
      'tap'     { [SxPlayer]::Tap([double]$a[1]) }
      'ext'     { [SxPlayer]::ExtBeat([double]$a[1], [double]$a[2]) }
      'sync'    { [SxPlayer]::SyncBeat([double]$a[1]) }
      'check'   { [void][SxPlayer]::CheckShow() }
      'addb'    { [SxPlayer]::AddButton([string]$a[1], [string]$a[2], [string]$a[3], [int]$a[4], [bool]$a[5], [int]$a[6], '', 1, -1, 1, -1, 0, 0)
                  if ($a[7]) { [SxPlayer]::SetBeat([string]$a[1], [bool]$a[8], [double]$a[9]) } }
      'delb'    { [SxPlayer]::RemoveButton([string]$a[1]) }
      'jstr'    { $r = $jstr.Invoke($null, @([string]$a[1], [string]$a[2])); $out.Add($(if ($null -eq $r) { 'J <null>' } else { 'J ' + $r.Replace("`n", '\n').Replace("`t", '\t') })) }
      default   { throw "unknown op $($a[0])" }
    }
  } catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    $out.Add('E ' + $e.Message)
  }
}
[IO.File]::WriteAllLines("$KeyOps.out", $out)
