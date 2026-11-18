# Draws the AIM MOVERS icon -> aim_movers.ico (Windows) + aim_movers_1024.png (source for the Mac .icns)
Add-Type -AssemblyName System.Drawing
$out = Split-Path -Parent $MyInvocation.MyCommand.Path
function New-Icon([int]$s) {
  $b = New-Object Drawing.Bitmap $s, $s; $g = [Drawing.Graphics]::FromImage($b)
  $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $r = [single]($s * 0.2); $p = New-Object Drawing.Drawing2D.GraphicsPath
  $m = [single]($s * 0.04); $w = [single]($s - 2 * $m)
  $p.AddArc($m, $m, $r, $r, 180, 90); $p.AddArc($m + $w - $r, $m, $r, $r, 270, 90); $p.AddArc($m + $w - $r, $m + $w - $r, $r, $r, 0, 90); $p.AddArc($m, $m + $w - $r, $r, $r, 90, 90); $p.CloseFigure()
  $bg = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, 0)), ([Drawing.PointF]::new(0, $s)), ([Drawing.Color]::FromArgb(255, 32, 36, 46)), ([Drawing.Color]::FromArgb(255, 12, 14, 18))
  $g.FillPath($bg, $p)
  # beam: from the head (top) down to the floor spot
  $hx = $s * 0.5; $hy = $s * 0.2; $fy = $s * 0.72; $fw = $s * 0.34
  $beam = New-Object Drawing.Drawing2D.GraphicsPath
  $beam.AddPolygon([Drawing.PointF[]]@([Drawing.PointF]::new($hx - $s * 0.04, $hy), [Drawing.PointF]::new($hx + $s * 0.04, $hy), [Drawing.PointF]::new($hx + $fw, $fy), [Drawing.PointF]::new($hx - $fw, $fy)))
  $bb = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, $hy)), ([Drawing.PointF]::new(0, $fy)), ([Drawing.Color]::FromArgb(230, 255, 214, 120)), ([Drawing.Color]::FromArgb(60, 255, 160, 0))
  $g.FillPath($bb, $beam)
  # floor spot
  $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 255, 157, 0))), [single]($hx - $fw), [single]($fy - $s * 0.07), [single](2 * $fw), [single]($s * 0.14))
  $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 255, 226, 150))), [single]($hx - $fw * 0.45), [single]($fy - $s * 0.03), [single]($fw * 0.9), [single]($s * 0.06))
  # head
  $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 235, 238, 244))), [single]($hx - $s * 0.09), [single]($hy - $s * 0.09), [single]($s * 0.18), [single]($s * 0.14))
  $g.Dispose(); $b
}
$sizes = 256, 64, 48, 32, 24, 16
$pngs = foreach ($s in $sizes) { $ms = New-Object IO.MemoryStream; (New-Icon $s).Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
$fs = [IO.File]::Create("$out\aim_movers.ico"); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$off = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
  $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
  $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$off); $off += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()
(New-Icon 1024).Save("$out\aim_movers_1024.png", [Drawing.Imaging.ImageFormat]::Png)
"icon written"
