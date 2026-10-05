<#
    Set-FolderIcon.ps1

    Assigns (or resets) a custom Explorer icon on a single folder.

    How Windows folder icons actually work:
      * A file named "desktop.ini" inside the folder, hidden + system.
      * It must contain a RELATIVE IconResource path, otherwise the icon
        breaks as soon as the folder is renamed or moved.
      * The folder itself must carry the System attribute so that the shell
        enables its Desktop.ini special handling.
      * Since the June 2026 security updates Windows ignores desktop.ini files
        it cannot prove are trusted (e.g. ones carrying Mark-of-the-Web).
        We therefore strip the zone identifier after writing.

    Safety design:
      * Runs as its own process. It never loads into Explorer's address space,
        so a bug here cannot crash or hang the shell.
      * Writes only inside the selected folder.
      * All writes are atomic (temp file + rename) so Explorer can never
        observe a half-written desktop.ini.
      * On any failure the previous desktop.ini / .ico bytes are restored.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $FolderPath,

    [switch] $Reset,

    # Use this image instead of showing the file picker. Useful for scripting.
    [string] $SourcePath,

    # Only re-notify the shell for this folder. Useful when the icon files are
    # already correct but an open Explorer window is showing a cached icon.
    [switch] $Refresh,

    # Show a confirmation dialog on success.
    [switch] $ShowSuccess,

    # Suppress all dialogs; report through the exit code and stderr instead.
    [switch] $NoDialogs
)

$ErrorActionPreference = 'Stop'

$IconFileName = 'folder-icon.ico'
$IniFileName  = 'desktop.ini'

# 256x256 is the real maximum for the .ico format; Explorer never scales a
# folder icon beyond that. 128 and 256 are stored as PNG payloads, the smaller
# frames as classic DIBs, which is what Windows itself writes.
$IconSizes = @(16, 24, 32, 48, 64, 128, 256)
$PngFromSize = 128

# Exactly what GDI+ can decode on Windows. Anything else has to be converted
# first, and the error message says so instead of leaking a GDI+ message.
$SupportedFormats = @('.ico', '.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff', '.emf', '.wmf')

$script:TmpFiles = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Native interop
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('FolderIconTool.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace FolderIconTool
{
    public static class Native
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        public static extern void SHChangeNotify(uint eventId, uint flags,
            [MarshalAs(UnmanagedType.LPWStr)] string item1, IntPtr item2);
    }
}
'@
}

$SHCNE_UPDATE          = [uint32]0x00002000
$SHCNE_UPDATEDIR       = [uint32]0x00001000
$SHCNE_ASSOCCHANGED    = [uint32]0x08000000
$SHCNF_IDLIST          = [uint32]0x00000000
$SHCNF_PATHW_FLUSH     = [uint32]0x00001005

function Send-ShellRefresh {
    param(
        [string] $Dir,
        [string] $File,

        # Also wipe the shell icon cache. Slower and causes every icon in every
        # open window to re-extract (a visible flicker), so this is reserved for
        # an explicit -Refresh rather than run on every change.
        [switch] $Heavy
    )

    # Order matters. The targeted notifications tell the shell which items
    # changed; ASSOCCHANGED tells it its icon lookups may be stale; then the
    # cache is rebuilt; and a second targeted notification makes already-open
    # Explorer windows re-query.
    try {
        if ($Dir)  { [FolderIconTool.Native]::SHChangeNotify($SHCNE_UPDATEDIR, $SHCNF_PATHW_FLUSH, $Dir,  [IntPtr]::Zero) }
        if ($File) { [FolderIconTool.Native]::SHChangeNotify($SHCNE_UPDATE,   $SHCNF_PATHW_FLUSH, $File, [IntPtr]::Zero) }
        [FolderIconTool.Native]::SHChangeNotify($SHCNE_ASSOCCHANGED, $SHCNF_IDLIST, $null, [IntPtr]::Zero)
    } catch {
        # Refresh is best-effort only. Never fail the operation over it.
    }

    # Rebuilds the shell icon cache without restarting Explorer. Nothing is
    # lost; icons simply re-extract, which can cause a one-second flicker.
    $ie4 = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
    if (Test-Path -LiteralPath $ie4) {
        $args2 = if ($Heavy) { @('-ClearIconCache', '-show') } else { @('-show') }
        foreach ($a in $args2) {
            try {
                Start-Process -FilePath $ie4 -ArgumentList $a -WindowStyle Hidden -Wait -ErrorAction Stop
            } catch { }
        }
    }

    try {
        if ($Dir) { [FolderIconTool.Native]::SHChangeNotify($SHCNE_UPDATEDIR, $SHCNF_PATHW_FLUSH, $Dir, [IntPtr]::Zero) }
    } catch { }
}

# ---------------------------------------------------------------------------
# Dialogs
# ---------------------------------------------------------------------------

function Show-Message {
    param(
        [string] $Text,
        [System.Windows.Forms.MessageBoxIcon] $Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.MessageBoxButtons] $Buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    )
    if ($NoDialogs) {
        [Console]::Error.WriteLine($Text)
        return
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        $Text, 'Folder Icon Tool', $Buttons, $Icon)
}

function Select-SourceImage {
    if ($SourcePath) {
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            throw "Source image not found:`n$SourcePath"
        }
        return $SourcePath
    }

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dlg.Title       = 'Choose an image for this folder icon'
        $dlg.Filter      = 'Icon files (*.ico)|*.ico|Images (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff)|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|All files (*.*)|*.*'
        $dlg.CheckFileExists = $true
        $dlg.Multiselect  = $false
        $dlg.RestoreDirectory = $true
        $dlg.InitialDirectory = $FolderPath
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return $null
        }
        return $dlg.FileName
    } finally {
        $dlg.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Image loading
# ---------------------------------------------------------------------------

function Copy-ToArgbBitmap {
    param([System.Drawing.Image] $Image)

    $bmp = New-Object System.Drawing.Bitmap(
        $Image.Width, $Image.Height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            Set-HighQualityGraphics $g
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImageUnscaled($Image, 0, 0)
        } finally {
            $g.Dispose()
        }
    } catch {
        $bmp.Dispose()
        throw
    }
    return $bmp
}

# Identifies a file by its magic bytes. GDI+ only says "Parameter is not
# valid" for everything it cannot decode, so a format check up front is what
# lets the error name the real problem.
function Get-ImageFormatHint {
    param([string] $Path)

    $head = New-Object byte[] 64
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $read = $fs.Read($head, 0, $head.Length)
    } finally {
        $fs.Dispose()
    }
    if ($read -le 0) { return 'empty' }

    $ascii = [System.Text.Encoding]::ASCII.GetString($head, 0, $read)

    if ($read -ge 12 -and $ascii.Substring(0, 4) -eq 'RIFF') {
        $kind = $ascii.Substring(8, 4)
        switch ($kind) {
            'WEBP' { return 'webp' }
            'WAVE' { return 'wave' }
            'AVI ' { return 'avi' }
        }
    }
    if ($read -ge 12 -and $ascii.Substring(4, 4) -eq 'ftyp') {
        $brand = $ascii.Substring(8, 4)
        if ($brand.StartsWith('avi'))      { return 'avif' }
        if ($brand.StartsWith('qt'))       { return 'mov' }
        if ($brand -match '^(hei|mif|msf)') { return 'heic' }
        return 'heif'
    }
    if ($ascii.Substring(0, [Math]::Min(5, $read)) -eq '%PDF-') { return 'pdf' }

    if ($read -ge 8 -and $head[0] -eq 0x89 -and $head[1] -eq 0x50 -and $head[2] -eq 0x4E -and $head[3] -eq 0x47) { return 'png' }
    if ($read -ge 3 -and $head[0] -eq 0xFF -and $head[1] -eq 0xD8 -and $head[2] -eq 0xFF) { return 'jpeg' }
    if ($read -ge 4 -and $ascii.Substring(0, 4) -eq 'GIF8') { return 'gif' }
    if ($read -ge 2 -and $ascii.Substring(0, 2) -eq 'BM')  { return 'bmp' }
    if ($read -ge 4 -and $head[0] -eq 0x00 -and $head[1] -eq 0x00 -and $head[2] -eq 0x01 -and $head[3] -eq 0x00) { return 'ico' }
    if ($read -ge 4 -and $head[0] -eq 0xD7 -and $head[1] -eq 0xCD -and $head[2] -eq 0xC6 -and $head[3] -eq 0x9A) { return 'wmf' }
    if ($read -ge 4 -and $head[0] -eq 0x01 -and $head[1] -eq 0x00 -and $head[2] -eq 0x00 -and $head[3] -eq 0x00) { return 'emf' }
    if ($read -ge 4 -and (
        ($head[0] -eq 0x49 -and $head[1] -eq 0x49 -and $head[2] -eq 0x2A -and $head[3] -eq 0x00) -or
        ($head[0] -eq 0x4D -and $head[1] -eq 0x4D -and $head[2] -eq 0x00 -and $head[3] -eq 0x2A))) { return 'tiff' }

    # Text-based formats: check for a BOM or leading whitespace first.
    $text = $ascii.TrimStart([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
    if ($text.StartsWith('<?xml') -or $text.StartsWith('<!DOCTYPE') -or $text.StartsWith('<svg')) { return 'svg' }

    return $null
}

function Get-FormatAdvice {
    param([string] $Hint, [string] $Name)

    $convert = "`n`nConvert it to PNG or JPEG, then try again."
    switch ($Hint) {
        'svg'   { return "$Name is an SVG image. Windows folder icons need a raster image, and SVG is vector art, so it cannot be used directly.$convert`n`nQuickest route: open it in a browser and save a screenshot." }
        'webp'  { return "$Name is a WebP image, which Windows cannot decode.$convert" }
        'heic'  { return "$Name is a HEIC/HEIF image. These usually come from an iPhone camera roll, and Windows cannot decode them.$convert`n`nOpen it in the Photos app and use Export." }
        'heif'  { return "$Name is a HEIF image, which Windows cannot decode.$convert" }
        'avif'  { return "$Name is an AVIF image, which Windows cannot decode.$convert" }
        'pdf'   { return "$Name is a PDF document, not an image.`n`nExport it to PNG, or screenshot the part you want." }
        'wave'  { return "$Name is a WAV audio file." }
        'avi'   { return "$Name is a video file." }
        'mov'   { return "$Name is a video file." }
        'empty' { return "$Name is empty (0 bytes)." }
        default { return $null }
    }
}

function Open-SourceImage {
    param([string] $Path)

    $name = [System.IO.Path]::GetFileName($Path)
    $ext  = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    $hint = Get-ImageFormatHint -Path $Path
    $advice = Get-FormatAdvice -Hint $hint -Name $name
    if ($advice) { throw $advice }

    $failed = "$name could not be read as an image.`n`n" +
              "Supported formats: " + ($SupportedFormats -join ', ') + ".`n`n" +
              "The file may be corrupt, or it may not really be the format its extension claims."

    if ($ext -eq '.ico') {
        try {
            $ico = New-Object System.Drawing.Icon($Path, 256, 256)
        } catch {
            throw "$failed`n`nIt has an .ico extension but is not a readable icon file."
        }
        try {
            $bmp = $ico.ToBitmap()
        } catch {
            throw $failed
        } finally {
            $ico.Dispose()
        }
        # Normalise whatever GDI+ handed back into a plain 32bpp ARGB bitmap
        # with an explicitly transparent background.
        try {
            return (Copy-ToArgbBitmap $bmp)
        } catch {
            throw $failed
        } finally {
            $bmp.Dispose()
        }
    }

    # Read through a memory stream and copy out, so no file handle is left
    # open on the user's original picture.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    try {
        try {
            $img = [System.Drawing.Image]::FromStream($ms, $true, $true)
        } catch {
            throw $failed
        }
        try {
            return (Copy-ToArgbBitmap $img)
        } catch {
            throw $failed
        } finally {
            $img.Dispose()
        }
    } finally {
        $ms.Dispose()
    }
}

function Set-HighQualityGraphics {
    param([System.Drawing.Graphics] $Graphics)

    $Graphics.CompositingMode     = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
    $Graphics.CompositingQuality  = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $Graphics.InterpolationMode    = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $Graphics.SmoothingMode        = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $Graphics.PixelOffsetMode      = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
}

# Very large sources are stepped down once first. Downscaling 6000px straight
# to 16px in a single pass produces heavy aliasing; two passes do not.
function Get-PreScaledImage {
    param([System.Drawing.Image] $Image)

    $maxDim = [Math]::Max($Image.Width, $Image.Height)
    if ($maxDim -le 1024) {
        return $Image
    }

    $scale = 1024.0 / $maxDim
    $nw = [int][Math]::Max(1, [Math]::Round($Image.Width * $scale))
    $nh = [int][Math]::Max(1, [Math]::Round($Image.Height * $scale))

    $bmp = New-Object System.Drawing.Bitmap($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        Set-HighQualityGraphics $g
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($Image, 0, 0, $nw, $nh)
    } catch {
        $g.Dispose()
        $bmp.Dispose()
        throw
    }
    $g.Dispose()
    return $bmp
}

# ---------------------------------------------------------------------------
# .ico encoding
# ---------------------------------------------------------------------------

function Get-DibPayload {
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap] $Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $locked = $Bitmap.LockBits(
        $rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $locked.Stride
        $needsFlip = $stride -ge 0
        $stride = [Math]::Abs($stride)
        $rowBytes = $w * 4
        $src = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $src, 0, $src.Length)
    } finally {
        $Bitmap.UnlockBits($locked)
    }

    # ICO stores DIBs bottom-up.
    $xor = New-Object byte[] ($rowBytes * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $destRow = if ($needsFlip) { $h - 1 - $y } else { $y }
        [Array]::Copy($src, ($y * $stride), $xor, ($destRow * $rowBytes), $rowBytes)
    }

    # 32bpp icons carry their alpha in the XOR data; the AND mask is all zero,
    # exactly as Windows writes it.
    $maskStride = [int]([Math]::Ceiling($w / 32.0) * 4)
    $mask = New-Object byte[] ($maskStride * $h)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $bw.Write([uint32]40)                                    # biSize
        $bw.Write([int32]$w)                                    # biWidth
        $bw.Write([int32]($h * 2))                              # biHeight (XOR + AND)
        $bw.Write([uint16]1)                                    # biPlanes
        $bw.Write([uint16]32)                                   # biBitCount
        $bw.Write([uint32]0)                                    # biCompression = BI_RGB
        $bw.Write([uint32]($xor.Length + $mask.Length))          # biSizeImage
        $bw.Write([int32]0)                                     # biXPelsPerMeter
        $bw.Write([int32]0)                                     # biYPelsPerMeter
        $bw.Write([uint32]0)                                    # biClrUsed
        $bw.Write([uint32]0)                                    # biClrImportant
        $bw.Write($xor)
        $bw.Write($mask)
        $bw.Flush()
        return $ms.ToArray()
    } finally {
        $bw.Dispose()
        $ms.Dispose()
    }
}

function Get-PngPayload {
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap] $Bitmap)

    $ms = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return $ms.ToArray()
    } finally {
        $ms.Dispose()
    }
}

function New-MultiSizeIcon {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [int[]] $Sizes = @(16, 24, 32, 48, 64, 128, 256),
        [int] $PngFromSize = 128
    )

    $work = Get-PreScaledImage -Image $Source
    try {
        $frames = New-Object System.Collections.Generic.List[byte[]]
        $meta   = New-Object System.Collections.Generic.List[object]

        foreach ($size in $Sizes) {
            $bmp = New-Object System.Drawing.Bitmap(
                $size, $size,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $bmp.SetResolution(96, 96)
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                try {
                    Set-HighQualityGraphics $g
                    $g.Clear([System.Drawing.Color]::Transparent)

                    # Fit inside the square, preserve aspect ratio, pad the
                    # remainder transparently. Nothing is distorted or cropped.
                    $scale = [Math]::Min($size / $work.Width, $size / $work.Height)
                    $dw = [int][Math]::Round($work.Width  * $scale)
                    $dh = [int][Math]::Round($work.Height * $scale)
                    if ($dw -lt 1) { $dw = 1 }
                    if ($dh -lt 1) { $dh = 1 }
                    $dx = [int][Math]::Floor(($size - $dw) / 2)
                    $dy = [int][Math]::Floor(($size - $dh) / 2)

                    $g.DrawImage(
                        $work,
                        (New-Object System.Drawing.Rectangle($dx, $dy, $dw, $dh)),
                        0, 0, $work.Width, $work.Height,
                        [System.Drawing.GraphicsUnit]::Pixel)
                } finally {
                    $g.Dispose()
                }

                if ($size -ge $PngFromSize) {
                    $payload = Get-PngPayload -Bitmap $bmp
                } else {
                    $payload = Get-DibPayload -Bitmap $bmp
                }

                $frames.Add($payload)
                $meta.Add([pscustomobject]@{ Width = $size; Length = $payload.Length })
            } finally {
                $bmp.Dispose()
            }
        }

        # ICONDIR + ICONDIRENTRY[] + payload blob
        $fs = [System.IO.File]::Create($Destination)
        $bw = New-Object System.IO.BinaryWriter($fs)
        try {
            $count = $frames.Count
            $bw.Write([uint16]0)   # idReserved
            $bw.Write([uint16]1)   # idType = 1 (icon)
            $bw.Write([uint16]$count)

            $offset = 6 + (16 * $count)
            for ($i = 0; $i -lt $count; $i++) {
                $entry = $meta[$i]
                # Width/height are single bytes, and 0 means 256.
                $dim = if ($entry.Width -ge 256) { 0 } else { $entry.Width }
                $bw.Write([byte]$dim)
                $bw.Write([byte]$dim)
                $bw.Write([byte]0)          # bColorCount
                $bw.Write([byte]0)          # bReserved
                $bw.Write([uint16]1)        # wPlanes
                $bw.Write([uint16]32)       # wBitCount
                $bw.Write([uint32]$entry.Length)
                $bw.Write([uint32]$offset)
                $offset += $entry.Length
            }

            foreach ($frame in $frames) {
                $bw.Write($frame)
            }
            $bw.Flush()
        } finally {
            $bw.Dispose()
            $fs.Dispose()
        }
    } finally {
        if ($work -ne $Source) { $work.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# desktop.ini
# ---------------------------------------------------------------------------

function Get-DesktopIniText {
    param([string] $IconName)
    # Relative resource path: this is what makes the icon survive a rename,
    # a move, or being copied to another drive. An absolute path would break.
    return @(
        '[.ShellClassInfo]'
        "IconResource=./$IconName,0"
        'ConfirmFileOp=0'
        'NoSharing=1'
        '[ViewState]'
        'Mode='
        'Vid='
        'FolderType=Generic'
        ''
    ) -join "`r`n"
}

function Get-BlankDesktopIniText {
    return @(
        '[ViewState]'
        'Mode='
        'Vid='
        'FolderType=Generic'
        ''
    ) -join "`r`n"
}

# Returns the icon file name referenced by an existing desktop.ini, if any.
function Get-ReferencedIconName {
    param([string] $IniPath)

    if (-not (Test-Path -LiteralPath $IniPath)) { return $null }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($IniPath)) {
            if ($line -match '^\s*IconResource\s*=\s*(.+?)\s*,\s*-?\d+\s*$') {
                $value = $Matches[1].Trim().Trim('"')
                # Only same-folder relative references are ours to clean up.
                if ($value -notmatch '[:\\/]' -or $value -match '^[.]{1,2}[\\/]') {
                    return [System.IO.Path]::GetFileName($value)
                }
                return $null
            }
            if ($line -match '^\s*IconFile\s*=\s*(.+?)\s*$') {
                $value = $Matches[1].Trim().Trim('"')
                if ($value -notmatch '[:\\/]' -or $value -match '^[.]{1,2}[\\/]') {
                    return [System.IO.Path]::GetFileName($value)
                }
                return $null
            }
        }
    } catch {
        return $null
    }
    return $null
}

# ---------------------------------------------------------------------------
# Atomic file helpers
# ---------------------------------------------------------------------------

function Clear-FileAttributes {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
        } catch {
            # Read-only/system bits we could not clear are not fatal here.
        }
    }
}

function Write-FileAtomically {
    param(
        [string] $Destination,
        [byte[]] $Content
    )

    $dir = Split-Path -Parent $Destination
    $tmp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
    $script:TmpFiles.Add($tmp)

    [System.IO.File]::WriteAllBytes($tmp, $Content)

    # Overwrite in one step so the shell never reads a partial file.
    Clear-FileAttributes -Path $Destination
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
    $script:TmpFiles.Remove($tmp) | Out-Null
}

function Remove-TempArtifacts {
    param([string] $Dir)

    while ($script:TmpFiles.Count -gt 0) {
        $item = $script:TmpFiles[0]
        $script:TmpFiles.RemoveAt(0)
        try {
            if (Test-Path -LiteralPath $item) {
                Clear-FileAttributes -Path $item
                Remove-Item -LiteralPath $item -Force -ErrorAction Stop
            }
        } catch { }
    }

    # Sweep leftovers from an earlier run that was killed mid-write.
    try {
        Get-ChildItem -LiteralPath $Dir -Force -Filter '*.tmp' -ErrorAction Stop |
            Where-Object { $_.Name -like '.desktop.ini.*' -or $_.Name -like ".$IconFileName.*" } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
            }
    } catch { }
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function Assert-SafeTarget {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "The folder no longer exists:`n$Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw 'That path is a file, not a folder.'
    }

    $full = $item.FullName.TrimEnd('\')

    # Drive roots are out of scope: their icons are owned by the shell.
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full -ieq $root) {
        throw 'Drive roots cannot take a custom icon.'
    }

    $protected = @(
        $env:SystemRoot,
        ${env:ProgramFiles},
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Join-Path $env:SystemDrive 'System Volume Information'),
        (Join-Path $env:SystemDrive ('$Recycle.Bin'))
    ) | Where-Object { $_ }

    foreach ($p in $protected) {
        $pf = $p.TrimEnd('\')
        if ($full -ieq $pf -or $full.StartsWith($pf + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "This is a protected Windows location and will not be modified:`n$full"
        }
    }

    return $full
}

function Get-MutexName {
    param([string] $Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::Unicode.GetBytes($Path.ToLowerInvariant()))
        return 'Local\FolderIconTool_' + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16))
    } finally {
        $sha.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# The file picker needs an STA thread. The registered command always passes
# -STA; if this is a manual run without it, relaunch once in the right mode.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $self = $PSCommandPath
    $relaunch = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $self + '"'),
        '-FolderPath', ('"' + $FolderPath + '"')
    )
    if ($Reset)       { $relaunch += '-Reset' }
    if ($Refresh)     { $relaunch += '-Refresh' }
    if ($SourcePath)  { $relaunch += @('-SourcePath', ('"' + $SourcePath + '"')) }
    if ($ShowSuccess) { $relaunch += '-ShowSuccess' }
    if ($NoDialogs)   { $relaunch += '-NoDialogs' }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $relaunch -WindowStyle Hidden
    return
}

$mutex = $null
$heldMutex = $false
$folder = $null
$backup = $null

try {
    $folder = Assert-SafeTarget -Path $FolderPath

    $mutex = New-Object System.Threading.Mutex($false, (Get-MutexName -Path $folder))
    try {
        $heldMutex = $mutex.WaitOne(0)
    } catch [System.Threading.AwaitableException] {
        $heldMutex = $false
    }

    if (-not $heldMutex) {
        # Another copy of this tool is already working on this exact folder.
        return
    }

    Remove-TempArtifacts -Dir $folder

    if ($Refresh) {
        # Nothing to write: just make the shell re-read this folder's icon.
        # This is the heavy variant, since reaching for it means the previous
        # refresh was not enough.
        Send-ShellRefresh -Dir $folder -File (Join-Path $folder $IniFileName) -Heavy
        if ($ShowSuccess) {
            Show-Message "Icon cache cleared and folder re-notified.`n`n$folder`n`nIf the window still shows the old icon, press F5 or reopen it."
        }
        return
    }

    $iniPath = Join-Path $folder $IniFileName
    $icoPath = Join-Path $folder $IconFileName

    # Snapshot everything we are about to touch.
    $priorIconName = Get-ReferencedIconName -IniPath $iniPath
    $backup = @{
        FolderAttributes = [System.IO.File]::GetAttributes($folder)
        IniExisted       = (Test-Path -LiteralPath $iniPath)
        IniBytes         = $null
        IniAttributes    = $null
        IcoExisted       = (Test-Path -LiteralPath $icoPath)
        IcoBytes         = $null
        IcoAttributes    = $null
    }
    if ($backup.IniExisted) {
        $backup.IniBytes      = [System.IO.File]::ReadAllBytes($iniPath)
        $backup.IniAttributes = [System.IO.File]::GetAttributes($iniPath)
    }
    if ($backup.IcoExisted) {
        $backup.IcoBytes      = [System.IO.File]::ReadAllBytes($icoPath)
        $backup.IcoAttributes = [System.IO.File]::GetAttributes($icoPath)
    }

    if ($Reset) {
        # ---- Reset to the default folder icon ----
        Clear-FileAttributes -Path $icoPath
        if (Test-Path -LiteralPath $icoPath) {
            Remove-Item -LiteralPath $icoPath -Force
        }
        if ($priorIconName -and $priorIconName -ne $IconFileName) {
            $orphan = Join-Path $folder $priorIconName
            Clear-FileAttributes -Path $orphan
            if (Test-Path -LiteralPath $orphan) {
                Remove-Item -LiteralPath $orphan -Force
            }
        }

        $text = Get-BlankDesktopIniText
        Write-FileAtomically -Destination $iniPath -Content ([System.Text.Encoding]::ASCII.GetBytes($text))
        [System.IO.File]::SetAttributes($iniPath,
            [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Archive)

        # Drop the folder back to a normal, non-system folder.
        [System.IO.File]::SetAttributes($folder, $backup.FolderAttributes -band (-bnot [System.IO.FileAttributes]::System))

        Send-ShellRefresh -Dir $folder -File $iniPath

        if ($ShowSuccess) {
            Show-Message "Default icon restored.`n`n$folder"
        }
        return
    }

    # ---- Set a new icon ----
    $source = Select-SourceImage
    if (-not $source) {
        return   # cancelled: leave everything exactly as it was
    }

    $image = Open-SourceImage -Path $source
    try {
        $tmpIco = Join-Path $folder ('.' + $IconFileName + '.' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
        $script:TmpFiles.Add($tmpIco)
        New-MultiSizeIcon -Source $image -Destination $tmpIco -Sizes $IconSizes -PngFromSize $PngFromSize
        $icoBytes = [System.IO.File]::ReadAllBytes($tmpIco)
    } finally {
        $image.Dispose()
        try {
            if (Test-Path -LiteralPath $tmpIco) { Remove-Item -LiteralPath $tmpIco -Force }
        } catch { }
        $script:TmpFiles.Remove($tmpIco) | Out-Null
    }

    if ($icoBytes.Length -lt 100) {
        throw 'The generated icon file came out empty.'
    }

    # Enable the shell's Desktop.ini handling for this folder (MS documents
    # `attrib +s` for exactly this).
    [System.IO.File]::SetAttributes($folder,
        $backup.FolderAttributes -bor [System.IO.FileAttributes]::System)

    Write-FileAtomically -Destination $icoPath -Content $icoBytes
    [System.IO.File]::SetAttributes($icoPath,
        [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Archive)

    $text = Get-DesktopIniText -IconName $IconFileName
    Write-FileAtomically -Destination $iniPath -Content ([System.Text.Encoding]::ASCII.GetBytes($text))
    [System.IO.File]::SetAttributes($iniPath,
        [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Archive)

    # Post-June-2026 hardening: Windows ignores a desktop.ini that carries a
    # Mark-of-the-Web, treating the folder as never customised. Locally created
    # files have none, but strip it if something upstream added one.
    try { Unblock-File -LiteralPath $iniPath -ErrorAction Stop } catch { }

    # Now that the change is committed, drop an icon left over from a previous
    # differently-named file so the folder never accumulates junk.
    if ($priorIconName -and $priorIconName -ne $IconFileName) {
        $orphan = Join-Path $folder $priorIconName
        try {
            Clear-FileAttributes -Path $orphan
            if (Test-Path -LiteralPath $orphan) { Remove-Item -LiteralPath $orphan -Force }
        } catch { }
    }

    Send-ShellRefresh -Dir $folder -File $iniPath

    if ($ShowSuccess) {
        $kb = [Math]::Round($icoBytes.Length / 1KB, 1)
        Show-Message ("Icon applied.`n`n{0}`n{1} sizes (16-256 px), {2} KB" -f $folder, ($IconSizes -join ', '), $kb)
    }
}
catch {
    # Roll back so a failed or interrupted run cannot leave a broken icon.
    if ($backup) {
        try {
            $iniPath = Join-Path $folder $IniFileName
            $icoPath = Join-Path $folder $IconFileName

            Clear-FileAttributes -Path $iniPath
            if ($backup.IniExisted) {
                [System.IO.File]::WriteAllBytes($iniPath, $backup.IniBytes)
                [System.IO.File]::SetAttributes($iniPath, $backup.IniAttributes)
            } elseif (Test-Path -LiteralPath $iniPath) {
                Remove-Item -LiteralPath $iniPath -Force
            }

            Clear-FileAttributes -Path $icoPath
            if ($backup.IcoExisted) {
                [System.IO.File]::WriteAllBytes($icoPath, $backup.IcoBytes)
                [System.IO.File]::SetAttributes($icoPath, $backup.IcoAttributes)
            } elseif (Test-Path -LiteralPath $icoPath) {
                Remove-Item -LiteralPath $icoPath -Force
            }

            [System.IO.File]::SetAttributes($folder, $backup.FolderAttributes)
            Send-ShellRefresh -Dir $folder -File $iniPath
        } catch { }
    }

    if (Test-Path -LiteralPath $FolderPath) {
        Remove-TempArtifacts -Dir $FolderPath
    }

    Show-Message ("Could not set the icon.`n`n" + $_.Exception.Message) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
finally {
    if ($folder -and (Test-Path -LiteralPath $folder)) {
        Remove-TempArtifacts -Dir $folder
    }
    if ($heldMutex -and $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($mutex) { $mutex.Dispose() }
}