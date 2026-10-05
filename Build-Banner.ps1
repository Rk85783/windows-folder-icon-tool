<#
    Build-Banner.ps1

    Renders the README / GitHub social assets from the real screenshots in
    docs\ plus the generated app icon in assets\.

    No external dependencies: System.Drawing (GDI+) only.

    Outputs
        assets\banner-hero.png      1600 x 800   README hero
        assets\social-card.png     1280 x 640   GitHub social preview
        assets\banner-steps.png    1400 x 900   3-step walkthrough
#>

[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $OutDir
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

# $PSScriptRoot is not bound yet while default parameter values are evaluated,
# so resolve the paths after the param block.
if (-not $RepoRoot) { $RepoRoot = $PSScriptRoot }
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir)   { $OutDir   = Join-Path $RepoRoot 'assets' }

# --- palette ---------------------------------------------------------------
$BG_TOP    = [System.Drawing.Color]::FromArgb(22, 27, 34)
$BG_BOT    = [System.Drawing.Color]::FromArgb(13, 17, 23)
$PANEL     = [System.Drawing.Color]::FromArgb(28, 33, 40)
$BORDER    = [System.Drawing.Color]::FromArgb(48, 54, 61)
$TEXT      = [System.Drawing.Color]::FromArgb(230, 237, 243)
$MUTED     = [System.Drawing.Color]::FromArgb(139, 148, 158)
$ACCENT    = [System.Drawing.Color]::FromArgb(0, 120, 212)
$ACCENT_LT = [System.Drawing.Color]::FromArgb(42, 150, 232)
$AMBER     = [System.Drawing.Color]::FromArgb(255, 185, 0)
$WHITE     = [System.Drawing.Color]::White

# --- helpers ---------------------------------------------------------------
function New-RoundRect {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $r = [Math]::Min($R, [Math]::Min($W, $H) / 2)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function Get-Gfx {
    param($Bmp)
    $g = [System.Drawing.Graphics]::FromImage($Bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g
}

function Set-Bg {
    param($G, [int]$W, [int]$H, [int]$R1, [int]$G1, [int]$B1, [int]$R2, [int]$G2, [int]$B2)
    # NOTE: $G.ClipRectangle is not usable from PowerShell here - its Width/Height
    # come back empty, which would collapse FillRectangle to a zero-width call.
    # The canvas size is therefore always passed in explicitly.
    $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)),
        (New-Object System.Drawing.Point(0, $H)),
        [System.Drawing.Color]::FromArgb($R1, $G1, $B1),
        [System.Drawing.Color]::FromArgb($R2, $G2, $B2))
    $G.FillRectangle($b, 0, 0, $W, $H)
    $b.Dispose()
}

function New-Font {
    param([string]$Name, [single]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    New-Object System.Drawing.Font($Name, $Size, $Style, [System.Drawing.GraphicsUnit]::Pixel)
}

function Draw-Text {
    param($G, [string]$Text, $Font, [single]$X, [single]$Y, [System.Drawing.Color]$Color, [single]$MaxW = 0)
    $br = New-Object System.Drawing.SolidBrush($Color)
    if ($MaxW -gt 0) {
        $sf = New-Object System.Drawing.StringFormat
        $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $r = New-Object System.Drawing.RectangleF($X, $Y, $MaxW, 400)
        $G.DrawString($Text, $Font, $br, $r, $sf)
        $sf.Dispose()
    } else {
        $G.DrawString($Text, $Font, $br, $X, $Y)
    }
    $br.Dispose()
}

# Fits an image inside a box, preserving aspect, centred. Never upscales.
function Get-FitBox {
    param([string]$Path, [single]$X, [single]$Y, [single]$W, [single]$H)
    $img = [System.Drawing.Image]::FromFile($Path)
    $ar = $img.Width / $img.Height
    $img.Dispose()
    if (($W / $H) -gt $ar) {
        $h = $H; $w = $H * $ar
    } else {
        $w = $W; $h = $W / $ar
    }
    @{ X = $X + (($W - $w) / 2); Y = $Y + (($H - $h) / 2); W = $w; H = $h }
}

function Draw-RoundedImage {
    param($G, [string]$Path, [single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $img = [System.Drawing.Image]::FromFile($Path)
    $clip = New-RoundRect $X $Y $W $H $R
    $saved = $G.Clip
    $G.SetClip($clip)
    $G.DrawImage($img, (New-Object System.Drawing.RectangleF($X, $Y, $W, $H)))
    $G.Clip = $saved
    $clip.Dispose()
    $img.Dispose()
}


# Crops a region out of a screenshot and returns it as a new bitmap.
function Get-Crop {
    param([string]$Path, [int]$X, [int]$Y, [int]$W, [int]$H)
    $src = [System.Drawing.Image]::FromFile($Path)
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)),
                        (New-Object System.Drawing.Rectangle($X, $Y, $W, $H)),
                        [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose(); $src.Dispose()
    $bmp
}


function Save-Canvas {
    param($G, $Bmp, [string]$Path)
    $w = $Bmp.Width; $h = $Bmp.Height
    $G.Dispose()
    $Bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $Bmp.Dispose()
    Write-Host ("  {0}  ({1}x{2}, {3} KB)" -f (Split-Path -Leaf $Path), $w, $h, [math]::Round((Get-Item $Path).Length / 1KB))
}

$docs   = Join-Path $RepoRoot 'docs'
$icon   = Join-Path $RepoRoot 'assets\icon-512.png'
$shot01 = Join-Path $docs '01-projects-drive-custom-icons.png'
$shot02 = Join-Path $docs '02-right-click-context-menu.png'
$shot03 = Join-Path $docs '03-image-picker-dialog.png'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# ===========================================================================
# 1. Hero banner 1600 x 800
# ===========================================================================
Write-Host 'Hero banner' -ForegroundColor Cyan
$W = 1600; $H = 800
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = Get-Gfx $bmp
Set-Bg $g $W $H 22 27 34 13 17 23

# soft accent glow behind the headline block
$glowPath = New-RoundRect 60 90 700 620 40
$gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.Point(60, 90)), (New-Object System.Drawing.Point(760, 710)),
    [System.Drawing.Color]::FromArgb(38, 0, 120, 212), [System.Drawing.Color]::FromArgb(0, 0, 120, 212))
$g.FillPath($gb, $glowPath)
$gb.Dispose(); $glowPath.Dispose()

# logo + wordmark
$g.DrawImage([System.Drawing.Image]::FromFile($icon), 100, 150, 84, 84)

$fTitle = New-Font 'Segoe UI' 46 ([System.Drawing.FontStyle]::Bold)
$fTag   = New-Font 'Segoe UI' 25
$fFeat  = New-Font 'Segoe UI' 21
$fPill  = New-Font 'Segoe UI' 19 ([System.Drawing.FontStyle]::Bold)
$fSmall = New-Font 'Segoe UI' 17

Draw-Text $g 'Windows Folder Icon Tool' $fTitle 206 158 $TEXT
Draw-Text $g 'Set any custom icon on any Windows folder.' $fTag 100 268 $MUTED
Draw-Text $g 'Right-click, pick an image, done. No admin needed.' $fTag 100 302 $MUTED

# divider
$div = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(48, 54, 61), 2)
$g.DrawLine($div, 100, 372, 660, 372)
$div.Dispose()

# features
$features = @(
    'Survives renames and moves',
    'Per-user install, no admin rights',
    'PNG, JPG, BMP, ICO - any size'
)
$y = 404
foreach ($f in $features) {
    $tick = New-RoundRect 102 ($y + 2) 20 20 6
    $tb = New-Object System.Drawing.SolidBrush($ACCENT_LT)
    $g.FillPath($tb, $tick)
    $tb.Dispose(); $tick.Dispose()
    $fg = New-Object System.Drawing.SolidBrush($BG_TOP)
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddLine(106, ($y + 12), 110, ($y + 16))
    $gp.AddLine(110, ($y + 16), 118, ($y + 7))
    $pw = New-Object System.Drawing.Pen($fg, 2.6)
    $pw.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pw, $gp)
    $pw.Dispose(); $gp.Dispose(); $fg.Dispose()

    Draw-Text $g $f $fFeat 140 $y $TEXT
    $y += 44
}

# CTA pills
function Draw-Pill {
    param($G, [string]$Label, [single]$X, [single]$Y, [single]$W, [bool]$Primary)
    $p = New-RoundRect $X $Y $W 46 12
    if ($Primary) {
        $b = New-Object System.Drawing.SolidBrush($ACCENT)
    } else {
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    }
    $G.FillPath($b, $p)
    $b.Dispose()
    if (-not $Primary) {
        $o = New-Object System.Drawing.Pen($BORDER, 2)
        $G.DrawPath($o, $p)
        $o.Dispose()
    }
    $col = if ($Primary) { $WHITE } else { $TEXT }
    $br = New-Object System.Drawing.SolidBrush($col)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $G.DrawString($Label, $script:fPill, $br, (New-Object System.Drawing.RectangleF($X, $Y, $W, 46)), $sf)
    $sf.Dispose(); $br.Dispose(); $p.Dispose()
}
Draw-Pill $g 'Download'          100 560 168 $true
Draw-Pill $g 'MIT  -  Windows 10/11' 284 560 268 $false

Draw-Text $g 'Per-user HKCU registration. Nothing outside your profile is touched.' $fSmall 100 630 $MUTED

# screenshot frame
$fx = 810; $fy = 96; $fw = 700; $fh = 596; $bar = 46
$shadowPath = New-RoundRect ($fx + 4) ($fy + 10) $fw $fh 16
$sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
$g.FillPath($sb, $shadowPath); $sb.Dispose(); $shadowPath.Dispose()

$frame = New-RoundRect $fx $fy $fw $fh 16
$fb = New-Object System.Drawing.SolidBrush($PANEL)
$g.FillPath($fb, $frame)
$fb.Dispose()
$g.DrawPath((New-Object System.Drawing.Pen($BORDER, 2)), $frame)

# title bar strip
$g.SetClip($frame)
$g.FillRectangle((New-Object System.Drawing.SolidBrush($PANEL)), $fx, $fy, $fw, $bar)
$g.FillRectangle((New-Object System.Drawing.SolidBrush($BORDER)), $fx, ($fy + $bar - 2), $fw, 2)
$dotColors = @([System.Drawing.Color]::FromArgb(255, 95, 86),
               [System.Drawing.Color]::FromArgb(255, 189, 46),
               [System.Drawing.Color]::FromArgb(39, 201, 63))
for ($i = 0; $i -lt 3; $i++) {
    $d = New-Object System.Drawing.SolidBrush($dotColors[$i])
    $g.FillEllipse($d, ($fx + 18 + $i * 20), ($fy + 17), 12, 12)
    $d.Dispose()
}
Draw-Text $g 'F:\Projects' $fSmall ($fx + 92) ($fy + 14) $MUTED
$g.ResetClip()
$frame.Dispose()

# screenshot inside frame
$innerX = $fx + 14; $innerY = $fy + $bar + 14
$innerW = $fw - 28; $innerH = $fh - $bar - 28
$fit = Get-FitBox $shot01 $innerX $innerY $innerW $innerH
Draw-RoundedImage $g $shot01 $fit.X $fit.Y $fit.W $fit.H 8

Save-Canvas $g $bmp (Join-Path $OutDir 'banner-hero.png')

# ===========================================================================
# 2. Social preview card 1280 x 640
# ===========================================================================
Write-Host 'Social card' -ForegroundColor Cyan
$W = 1280; $H = 640
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = Get-Gfx $bmp
Set-Bg $g $W $H 22 27 34 13 17 23

# blurred, darkened copy of the real Explorer grid as texture
$tiny = New-Object System.Drawing.Bitmap(80, 51, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$tg = [System.Drawing.Graphics]::FromImage($tiny)
$tg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$tg.DrawImage([System.Drawing.Image]::FromFile($shot01), 0, 0, 80, 51)
$tg.Dispose()
$g.DrawImage($tiny, -40, -30, ($W + 80), ($H + 60))
$g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(198, 13, 17, 23))), 0, 0, $W, $H)
$tiny.Dispose()

$fBig  = New-Font 'Segoe UI' 62 ([System.Drawing.FontStyle]::Bold)
$fSub  = New-Font 'Segoe UI' 27
$fFoot = New-Font 'Segoe UI' 19

$g.DrawImage([System.Drawing.Image]::FromFile($icon), (($W - 132) / 2), 92, 132, 132)

$sfC = New-Object System.Drawing.StringFormat
$sfC.Alignment = [System.Drawing.StringAlignment]::Center
function Draw-Centered {
    param($G, [string]$Text, $Font, [single]$Y, [System.Drawing.Color]$Color, [single]$Size = 1280)
    $br = New-Object System.Drawing.SolidBrush($Color)
    $G.DrawString($Text, $Font, $br, (New-Object System.Drawing.RectangleF(0, $Y, $script:W, 90)), $script:sfC)
    $br.Dispose()
}
Draw-Centered $g 'Windows Folder Icon Tool' $fBig 254 $TEXT
Draw-Centered $g 'Right-click any folder  ->  Set Folder Icon  ->  pick an image' $fSub 336 $MUTED
Draw-Centered $g 'Open source  -  MIT License  -  Windows 10 / 11' $fFoot 392 $AMBER

Save-Canvas $g $bmp (Join-Path $OutDir 'social-card.png')

# ===========================================================================
# 3. Walkthrough 1200 x 1180  (vertical stack - screenshots stay legible)
# ===========================================================================
Write-Host 'Walkthrough strip' -ForegroundColor Cyan

$W = 1200; $H = 1180
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = Get-Gfx $bmp
Set-Bg $g $W $H 22 27 34 13 17 23

$fH2   = New-Font 'Segoe UI' 40 ([System.Drawing.FontStyle]::Bold)
$fStep = New-Font 'Segoe UI' 22 ([System.Drawing.FontStyle]::Bold)
$fCap  = New-Font 'Segoe UI' 22
$fCapS = New-Font 'Segoe UI' 17
$fLead = New-Font 'Segoe UI' 23

Draw-Text $g 'How it works' $fH2 60 54 $TEXT
Draw-Text $g 'Three steps. No restart, no admin prompt.' $fLead 60 110 $MUTED

# Each screenshot is cropped to the frame's aspect so nothing is letterboxed.
# shot02 : the context menu, centred on the two entries the tool adds.
# shot03 : the picker dialog (its blank list is kept - cropping it leaves a
#          very wide, thin strip that can never fill this frame).
# shot01 : one clean band of the finished grid.
$shots = @(
    @{ N = '1'; Title = 'Right-click the folder';
       Crop = @(790, 300, 560, 300);
       Cap  = 'Pick "Set Folder Icon" from the folder context menu.'
       Sub  = 'Registered under HKCU for the current user - no admin, no machine-wide keys.' },
    @{ N = '2'; Title = 'Choose an image';
       Crop = @(0, 14, 942, 504);
       Cap  = 'Any PNG, JPG, BMP or ICO. It is resized into 7 sizes automatically.'
       Sub  = 'Non-square images keep their aspect ratio and are padded transparently.' },
    @{ N = '3'; Title = 'Icon applied';
       Crop = @(0, 450, 560, 300);
       Cap  = 'The folder now carries the icon - and keeps it when renamed or moved.'
       Sub  = 'desktop.ini is written atomically, so a failure never leaves a half-written file.' }
)
$src = @($shot02, $shot03, $shot01)

$rowW = 1080; $rowH = 300; $rowX = 60; $rowY0 = 170; $rowGap = 24
$frameW = 560; $frameH = 300

for ($i = 0; $i -lt 3; $i++) {
    $s = $shots[$i]
    $y = $rowY0 + $i * ($rowH + $rowGap)

    $card = New-RoundRect $rowX $y $rowW $rowH 16
    $cb = New-Object System.Drawing.SolidBrush($PANEL)
    $g.FillPath($cb, $card); $cb.Dispose()
    $g.DrawPath((New-Object System.Drawing.Pen($BORDER, 2)), $card)

    # --- screenshot, cropped to fill the frame exactly ---
    $clip = New-RoundRect $rowX $y $frameW $frameH 16
    $savedClip = $g.Clip
    $g.SetClip($clip)
    $c = $s.Crop
    $img = [System.Drawing.Image]::FromFile($src[$i])
    $g.DrawImage($img,
        (New-Object System.Drawing.RectangleF($rowX, $y, $frameW, $frameH)),
        (New-Object System.Drawing.Rectangle($c[0], $c[1], $c[2], $c[3])),
        [System.Drawing.GraphicsUnit]::Pixel)
    $img.Dispose()
    $g.Clip = $savedClip
    # re-stroke only the left edge so the right corners stay square
    $inner = New-RoundRect ($rowX + 1) ($y + 1) ($frameW - 2) ($frameH - 2) 15
    $half = New-Object System.Drawing.Drawing2D.GraphicsPath
    $half.AddArc($rowX, $y, 32, 32, 180, 90)
    $half.AddLine($rowX, $y + 15, $rowX, $y + $frameH - 15)
    $half.AddArc($rowX, ($y + $frameH - 32), 32, 32, 90, 90)
    $half.AddLine($rowX + 15, ($y + $frameH), $rowX + $frameW, ($y + $frameH))
    $g.DrawPath((New-Object System.Drawing.Pen($BORDER, 2)), $half)
    $half.Dispose(); $inner.Dispose(); $clip.Dispose()

    # --- text column ---
    $tx = $rowX + $frameW + 44
    $tw = $rowW - $frameW - 44 - 36

    $badge = New-RoundRect $tx ($y + 30) 40 40 12
    $bb = New-Object System.Drawing.SolidBrush($ACCENT)
    $g.FillPath($bb, $badge); $bb.Dispose()
    $bsf = New-Object System.Drawing.StringFormat
    $bsf.Alignment = [System.Drawing.StringAlignment]::Center
    $bsf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $bbr = New-Object System.Drawing.SolidBrush($WHITE)
    $g.DrawString($s.N, $fStep, $bbr, (New-Object System.Drawing.RectangleF($tx, ($y + 30), 40, 40)), $bsf)
    $bsf.Dispose(); $bbr.Dispose(); $badge.Dispose()

    Draw-Text $g $s.Title $fCap ($tx + 56) ($y + 36) $TEXT
    Draw-Text $g $s.Cap  $fCap  $tx ($y + 112) $TEXT $tw
    Draw-Text $g $s.Sub  $fCapS $tx ($y + 200) $MUTED $tw
}

Save-Canvas $g $bmp (Join-Path $OutDir 'banner-steps.png')

Write-Host ''
Write-Host ('Done -> {0}' -f $OutDir) -ForegroundColor Green





