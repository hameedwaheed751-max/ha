Add-Type -AssemblyName System.Drawing

$out = Join-Path $PSScriptRoot '..\assets\images\icons\3d'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Brush([string]$top, [string]$bottom, [System.Drawing.RectangleF]$rect) {
  $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList @($rect, [System.Drawing.ColorTranslator]::FromHtml($top), [System.Drawing.ColorTranslator]::FromHtml($bottom), 90)
  return $b
}
function Pen([System.Drawing.Color]$color, [float]$width) {
  return New-Object System.Drawing.Pen -ArgumentList @($color, $width)
}
function PointArray([float[]]$coords) {
  $points = [System.Array]::CreateInstance([System.Drawing.PointF], [int]($coords.Count / 2))
  for ($i = 0; $i -lt $points.Length; $i++) {
    $points[$i] = New-Object System.Drawing.PointF -ArgumentList @($coords[$i * 2], $coords[$i * 2 + 1])
  }
  return [System.Drawing.PointF[]]$points
}
function RoundRect($g, $pen, $brush, [float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure()
  if ($brush) { $g.FillPath($brush, $p) }; if ($pen) { $g.DrawPath($pen, $p) }
  $p.Dispose()
}
function DrawIcon([string]$name, [string]$kind, [string]$primary, [string]$secondary) {
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList @(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)
  $shadow = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::FromArgb(55, 20, 30, 35))
  $g.FillEllipse($shadow, 84, 390, 344, 48); $shadow.Dispose()
  $pen = New-Object System.Drawing.Pen -ArgumentList @([System.Drawing.Color]::FromArgb(110, 255, 255, 255), 8)
  $dark = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.ColorTranslator]::FromHtml($secondary))
  $main = Brush $primary $secondary (New-Object System.Drawing.RectangleF -ArgumentList @(80, 60, 350, 350))
  $white = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::White)
  $gold = New-Object System.Drawing.SolidBrush -ArgumentList @([System.Drawing.Color]::FromArgb(255, 255, 193, 42))
  switch ($kind) {
    'check' { $g.FillEllipse($main, 92, 82, 328, 328); $g.DrawArc($pen, 127, 117, 258, 258, 210, 170); $g.DrawLine((Pen ([System.Drawing.Color]::White) 30), 150, 255, 220, 322); $g.DrawLine((Pen ([System.Drawing.Color]::White) 30), 220, 322, 360, 170) }
    'wifi' { $g.DrawArc((Pen ([System.Drawing.Color]::White) 28), 95, 105, 320, 250, 220, 100); $g.DrawArc((Pen ([System.Drawing.Color]::White) 28), 145, 175, 220, 175, 220, 100); $g.FillEllipse($main, 235, 335, 45, 45) }
    'banknotes' { RoundRect $g $pen $dark 95 145 315 190 35; RoundRect $g $pen $main 70 105 315 190 35; $g.FillEllipse($gold, 190, 165, 78, 78); $g.DrawString('$', (New-Object System.Drawing.Font('Segoe UI', 38, [System.Drawing.FontStyle]::Bold)), $dark, 213, 175) }
    'wallet' { RoundRect $g $pen $dark 80 125 330 220 42; RoundRect $g $pen $main 95 95 330 220 42; $g.FillEllipse($gold, 318, 188, 38, 38); $g.FillRectangle($white, 313, 194, 28, 26) }
    'gift' { RoundRect $g $pen $main 105 170 300 220 22; $g.FillRectangle($gold, 238, 150, 34, 260); $g.FillRectangle($gold, 82, 202, 346, 40); $g.DrawArc($pen, 176, 78, 95, 115, 185, 170); $g.DrawArc($pen, 240, 78, 95, 115, 185, -170) }
    'users' { $g.FillEllipse($main, 190, 85, 130, 130); $g.FillEllipse($dark, 72, 155, 100, 100); $g.FillEllipse($dark, 340, 155, 100, 100); RoundRect $g $pen $main 105 250 300 150 75; RoundRect $g $pen $dark 40 275 150 115 55; RoundRect $g $pen $dark 322 275 150 115 55 }
    'usercheck' { $g.FillEllipse($main, 175, 70, 145, 145); RoundRect $g $pen $main 90 235 290 160 80; $g.FillEllipse($dark, 300, 280, 128, 128); $g.DrawLine((Pen ([System.Drawing.Color]::White) 20), 325, 340, 350, 365); $g.DrawLine((Pen ([System.Drawing.Color]::White) 20), 350, 365, 405, 305) }
    'hourglass' { $pts = PointArray @(155,80,357,80,285,245,357,410,155,410,227,245); $g.FillPolygon($main, $pts); $g.DrawLine($pen, 145, 75, 367, 75); $g.DrawLine($pen, 145, 415, 367, 415); $g.FillPolygon($gold, (PointArray @(215,250,295,250,275,305,235,305))) }
    'chat' { $g.FillEllipse($main, 72, 95, 365, 270); $g.FillPolygon($main, (PointArray @(105,315,78,410,205,350))); $g.FillEllipse($white, 175, 220, 25, 25); $g.FillEllipse($white, 250, 220, 25, 25); $g.FillEllipse($white, 325, 220, 25, 25) }
    'clipboard' { RoundRect $g $pen $main 105 90 300 325 28; RoundRect $g $pen $dark 180 55 150 65 25; $g.DrawLine($pen, 165, 180, 210, 180); $g.DrawLine($pen, 165, 250, 210, 250); $g.DrawLine($pen, 165, 320, 210, 320); $g.DrawLine($pen, 245, 180, 350, 180); $g.DrawLine($pen, 245, 250, 350, 250); $g.DrawLine($pen, 245, 320, 350, 320) }
    'userplus' { $g.FillEllipse($main, 130, 75, 140, 140); RoundRect $g $pen $main 55 230 290 170 85; $g.FillEllipse($gold, 315, 235, 100, 100); $g.DrawLine($pen, 365, 260, 365, 310); $g.DrawLine($pen, 340, 285, 390, 285) }
    'calculator' { RoundRect $g $pen $main 100 65 310 350 42; RoundRect $g $pen $dark 145 110 220 80 18; for ($i=0; $i -lt 3; $i++) { for ($j=0; $j -lt 3; $j++) { $g.FillEllipse($gold, 145 + $j*70, 230 + $i*58, 30, 30) } } }
    'speedometer' { $g.FillEllipse($main, 70, 80, 370, 370); $g.FillPie($dark, 120, 130, 270, 270, 200, 140); $g.DrawLine((Pen ([System.Drawing.Color]::White) 22), 255, 265, 345, 180); $g.FillEllipse($gold, 230, 240, 50, 50) }
    'router' { RoundRect $g $pen $main 65 220 380 160 45; $g.FillEllipse($gold, 150, 285, 32, 32); $g.FillEllipse($gold, 225, 285, 32, 32); $g.DrawLine($pen, 170, 220, 150, 115); $g.DrawLine($pen, 340, 220, 360, 115); $g.DrawArc($pen, 95, 60, 150, 120, 205, 65); $g.DrawArc($pen, 267, 60, 150, 120, 270, 65) }
    'debt' { RoundRect $g $pen $main 85 120 340 220 42; $g.FillEllipse($gold, 318, 195, 45, 45); $g.DrawLine((Pen ([System.Drawing.Color]::White) 24), 150, 230, 355, 230); $g.FillEllipse($dark, 100, 315, 80, 80) }
  }
  $pen.Dispose(); $dark.Dispose(); $main.Dispose(); $white.Dispose(); $gold.Dispose()
  $bmp.Save((Join-Path $out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

DrawIcon 'check' 'check' '#74E6A0' '#079B58'
DrawIcon 'wifi' 'wifi' '#4FC3FF' '#0968D7'
DrawIcon 'banknotes' 'banknotes' '#7CF0A2' '#079B58'
DrawIcon 'wallet' 'wallet' '#FF9B55' '#E45B14'
DrawIcon 'gift' 'gift' '#C79BFF' '#6430D8'
DrawIcon 'users' 'users' '#64B5FF' '#1461D2'
DrawIcon 'user_check' 'usercheck' '#77E8A2' '#079B58'
DrawIcon 'hourglass' 'hourglass' '#FFC078' '#F07818'
DrawIcon 'chat' 'chat' '#C58BFF' '#7138D8'
DrawIcon 'clipboard' 'clipboard' '#63C7FF' '#1266D8'
DrawIcon 'user_plus' 'userplus' '#77E8A2' '#079B58'
DrawIcon 'calculator' 'calculator' '#77E8A2' '#079B58'
DrawIcon 'speedometer' 'speedometer' '#FFC078' '#F07818'
DrawIcon 'router' 'router' '#63C7FF' '#1266D8'
DrawIcon 'debt' 'debt' '#FF8B8B' '#D42D35'
Write-Output "Generated 15 transparent PNG icons in $out"
