param(
  [string]$OutDir = (Join-Path $PSScriptRoot "assets"),
  [int]$Canvas = 1024
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$clrFolder = [System.Drawing.Color]::FromArgb(0,120,212)  # #0078D4
$clrFolderLight = [System.Drawing.Color]::FromArgb(42,150,232) # #2A96E8
$clrSpark = [System.Drawing.Color]::FromArgb(255,185,0)    # #FFB900

function New-FolderPath([int]$c) {
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $r = 40
  # tab
  $x1=$r+88; $y1=$r+136; $w1=432; $h1=154  # approx relative
  # better use fixed
  $gp.AddArc(128,176,80,80,180,90)
  $gp.AddArc(560-80,176,80,80,270,90)
  $gp.AddLine(560,176,560,330)
  $gp.AddArc(560-80,330-80,80,80,0,90)
  $gp.AddArc(128,330-80,80,80,90,90)
  $gp.CloseFigure()
  # body
  $gp2 = New-Object System.Drawing.Drawing2D.GraphicsPath
  $gp2.AddArc(128,300,80,80,180,90)
  $gp2.AddArc(896-80,300,80,80,270,90)
  $gp2.AddLine(896,300,896,848)
  $gp2.AddArc(896-80,848-80,80,80,0,90)
  $gp2.AddArc(128,848-80,80,80,90,90)
  $gp2.CloseFigure()
  # union
  $u = New-Object System.Drawing.Drawing2D.GraphicsPath
  $u.AddPath($gp,$false)
  $u.AddPath($gp2,$false)
  return $u
}

function New-SparkPath([int]$c, [int]$cx,[int]$cy,[int]$size) {
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $s = $size/2.0
  $tipT = New-Object System.Drawing.Point($cx, [int]($cy - $s*1.15))
  $tipR = New-Object System.Drawing.Point([int]($cx + $s*0.5), [int]($cy - $s*0.2))
  $tipB = New-Object System.Drawing.Point($cx, [int]($cy + $s*1.15))
  $tipL = New-Object System.Drawing.Point([int]($cx - $s*0.5), [int]($cy - $s*0.2))
  $cp1r = New-Object System.Drawing.Point([int]($cx + $s*0.28), [int]($cy - $s*0.28))
  $cp2r = New-Object System.Drawing.Point([int]($cx + $s*0.28), [int]($cy - $s*0.28))
  $cp1b = New-Object System.Drawing.Point([int]($cx + $s*0.28), [int]($cy + $s*0.28))
  $cp2b = New-Object System.Drawing.Point([int]($cx - $s*0.28), [int]($cy + $s*0.28))
  $cp1l = New-Object System.Drawing.Point([int]($cx - $s*0.28), [int]($cy - $s*0.28))
  $cp2l = New-Object System.Drawing.Point([int]($cx - $s*0.28), [int]($cy - $s*0.28))
  $gp.AddBezier($tipT, $cp1r, $cp2r, $tipR)
  $gp.AddBezier($tipR, $cp1b, $cp2b, $tipB)
  $gp.AddBezier($tipB, $cp1l, $cp2l, $tipL)
  $gp.AddBezier($tipL, $cp1r, $cp2r, $tipT)
  $gp.CloseFigure()
  return $gp
}

function Draw-Icon([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap($size,$size,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear([System.Drawing.Color]::Transparent)
  $scale = $size / 1024.0
  $m = New-Object System.Drawing.Drawing2D.Matrix
  $m.Scale($scale,$scale)
  # draw folder
  $fp = New-FolderPath 1024
  $fp.Transform($m)
  $g.FillPath((New-Object System.Drawing.SolidBrush($clrFolder)), $fp)
  # flap
  $flap = New-Object System.Drawing.Drawing2D.GraphicsPath
  $flap.AddArc(128*$scale,300*$scale,80*$scale,80*$scale,180,90)
  $flap.AddArc(896*$scale-80*$scale,300*$scale,80*$scale,80*$scale,270,90)
  $flap.AddLine(896*$scale,300*$scale,896*$scale,380*$scale)
  $flap.AddLine(128*$scale,380*$scale,128*$scale,300*$scale+40*$scale)
  $g.FillPath((New-Object System.Drawing.SolidBrush($clrFolderLight)), $flap)
  # spark
  $sp = New-SparkPath 1024 ([int](740*$scale)) ([int](330*$scale)) ([int](200*$scale))
  $g.FillPath((New-Object System.Drawing.SolidBrush($clrSpark)), $sp)
  $g.Dispose()
  return $bmp
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$sizes = @(16,24,32,48,64,128,256,512,1024)
foreach ($sz in $sizes) {
  $bmp = Draw-Icon $sz
  $path = Join-Path $OutDir ("icon-{0}.png" -f $sz)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
Write-Host "Done: $OutDir"
