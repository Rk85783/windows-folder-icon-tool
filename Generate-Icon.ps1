<#
    Generate-Icon.ps1

    Draws the application icon - a blue folder with an amber sparkle - and writes
    it at every size a Windows shell asks for, plus a multi-frame .ico.

    The folder is a single GraphicsPath traced clockwise in one continuous run:
    up the tab's left edge, across the tab, down into the body, around the body.
    Tracing it as one figure avoids the self-intersection you get from filling a
    tab and a body as two separate shapes, and a single fill colour means there
    is no seam where the tab meets the body.

    Geometry is in 1024 x 1024 canvas units and each size is a scaled copy of
    the master, so the small sizes stay proportional instead of being redrawn.

    Outputs, relative to -OutDir
        icon-16.png .. icon-512.png, icon-1024.png
        icon.ico      7 frames: 16 24 32 48 64 128 256
#>

[CmdletBinding()]
param(
    [string] $OutDir,
    [int]    $Canvas = 1024,
    [int[]]  $IcoSizes  = @(16, 24, 32, 48, 64, 128, 256),
    [int[]]  $PngSizes  = @(16, 24, 32, 48, 64, 128, 256, 512)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

trap {
    Write-Host ''
    Write-Host ('FAILED at line {0}' -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    Write-Host ('  {0}' -f $_.InvocationInfo.Line.Trim()) -ForegroundColor Red
    Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor DarkRed
    break
}

if (-not $OutDir) {
    $root = $PSScriptRoot
    if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $OutDir = Join-Path $root 'assets'
}

$F_X1 = 88;    $F_X2 = 936     # folder spans 88 .. 936
$T_X2 = 552                     # tab ends at 552
$T_Y1 = 168                     # tab top
$B_Y1 = 316                     # body top
$B_Y2 = 884                     # body bottom
$R_TAB  = 46
$R_BODY = 44

$CBody  = [System.Drawing.Color]::FromArgb(0, 120, 212)    # #0078D4
$CLip   = [System.Drawing.Color]::FromArgb(0, 90, 158)     # #005A9E, folder lip
$CSpark = [System.Drawing.Color]::FromArgb(255, 185, 0)    # #FFB900

$S_CX = 758; $S_CY = 404; $S_R = 150

function Get-RoundRectPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $r = $R * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.StartFigure()
    $p.AddArc($X, $Y, $r, $r, 180, 90)
    $p.AddArc(($X + $W - $r), $Y, $r, $r, 270, 90)
    $p.AddArc(($X + $W - $r), ($Y + $H - $r), $r, $r, 0, 90)
    $p.AddArc($X, ($Y + $H - $r), $r, $r, 90, 90)
    $p.CloseFigure()
    $p
}

# Traced clockwise as one figure so the tab and body form a single outline with
# no seam. GraphicsPath.AddLine has a (Point,Point) overload as well as the
# (x1,y1,x2,y2) one, so every call below passes all four coordinates - a two
# argument call silently becomes two points at y = 0.
function Get-FolderPath {
    $rt = $R_TAB * 2
    $rb = $R_BODY * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath

    $p.AddLine($F_X1, ($T_Y1 + $R_TAB), $F_X1, $T_Y1)
    $p.AddArc($F_X1, $T_Y1, $rt, $rt, 180, 90)
    $p.AddLine(($F_X1 + $R_TAB), $T_Y1, ($T_X2 - $R_TAB), $T_Y1)
    $p.AddArc(($T_X2 - $rt), $T_Y1, $rt, $rt, 270, 90)
    $p.AddLine($T_X2, ($T_Y1 + $R_TAB), $T_X2, $B_Y1)
    $p.AddArc(($F_X2 - $rb), $B_Y1, $rb, $rb, 270, 90)
    $p.AddArc(($F_X2 - $rb), ($B_Y2 - $rb), $rb, $rb, 0, 90)
    $p.AddArc($F_X1, ($B_Y2 - $rb), $rb, $rb, 90, 90)
    $p.CloseFigure()
    $p
}

# Four-point sparkle. Each edge is a cubic with both control points placed at the
# same spot, $Pinch of the way from the centre towards the edge's midpoint, which
# pulls the edge into a concave waist. $Pinch near 1 flattens the edge into a
# diamond; near 0 collapses the shape to a sliver, so it is kept mid range.
function Get-SparkPath {
    param([single]$CX, [single]$CY, [single]$R, [single]$Pinch = 0.38, [single]$Reach = 0.82)
    $tip = @(
        [System.Drawing.PointF]::new($CX, ($CY - $R)),
        [System.Drawing.PointF]::new(($CX + $R * $Reach), $CY),
        [System.Drawing.PointF]::new($CX, ($CY + $R)),
        [System.Drawing.PointF]::new(($CX - $R * $Reach), $CY)
    )
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    for ($i = 0; $i -lt 4; $i++) {
        $from = $tip[$i]
        $to   = $tip[($i + 1) % 4]
        $mx = ($from.X + $to.X) / 2
        $my = ($from.Y + $to.Y) / 2
        $cx = $CX + ($mx - $CX) * $Pinch
        $cy = $CY + ($my - $CY) * $Pinch
        $ctl = [System.Drawing.PointF]::new($cx, $cy)
        $p.AddBezier($from, $ctl, $ctl, $to)
    }
    $p.CloseFigure()
    $p
}

function Get-Master {
    $bmp = New-Object System.Drawing.Bitmap($Canvas, $Canvas, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $folder = Get-FolderPath
    $g.FillPath((New-Object System.Drawing.SolidBrush($CBody)), $folder)

    # A darker strip along the top of the body reads as the folder lip. It is a
    # plain rectangle clipped to the folder outline, so the body's own rounded
    # top corners shape it and it can never spill past them.
    $saved = $g.Clip
    $g.SetClip($folder)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($CLip)),
                     $F_X1, $B_Y1, ($F_X2 - $F_X1), 54)
    $g.Clip = $saved

    $g.FillPath((New-Object System.Drawing.SolidBrush($CSpark)),
                (Get-SparkPath $S_CX $S_CY $S_R))
    $g.Dispose()
    $bmp
}

function Save-Scaled {
    param($Master, [int]$Size, [string]$Path)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($Master, 0, 0, $Size, $Size)
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# .ico with PNG-compressed frames. A width or height byte of 0 means 256.
function Write-Ico {
    param([string]$OutPath, [int[]]$Sizes, [string]$Dir)
    $blobs = @()
    foreach ($s in $Sizes) {
        $blobs += ,([IO.File]::ReadAllBytes((Join-Path $Dir ('icon-{0}.png' -f $s))))
    }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$Sizes.Count)
    $offset = 6 + (16 * $Sizes.Count)
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        $s = $Sizes[$i]
        $w = $s; $h = $s
        if ($s -ge 256) { $w = 0; $h = 0 }
        $bw.Write([byte]$w); $bw.Write([byte]$h)
        $bw.Write([byte]0);  $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$blobs[$i].Length)
        $bw.Write([uint32]$offset)
        $offset += $blobs[$i].Length
    }
    foreach ($b in $blobs) { $bw.Write($b, 0, $b.Length) }
    $bw.Flush()
    [IO.File]::WriteAllBytes($OutPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Write-Host ("Icon -> {0}" -f $OutDir) -ForegroundColor Cyan

$master = Get-Master
$sizes = @($PngSizes + $Canvas) | Sort-Object -Unique -Descending
foreach ($s in $sizes) {
    $p = Join-Path $OutDir ('icon-{0}.png' -f $s)
    Save-Scaled $master $s $p
    Write-Host ("  icon-{0,-4}.png  {1} KB" -f $s, [math]::Round((Get-Item $p).Length / 1KB))
}
$master.Dispose()

$icoPath = Join-Path $OutDir 'icon.ico'
Write-Ico $icoPath $IcoSizes $OutDir
Write-Host ("  icon.ico       {0} frames, {1} KB" -f $IcoSizes.Count, [math]::Round((Get-Item $icoPath).Length / 1KB)) -ForegroundColor Green