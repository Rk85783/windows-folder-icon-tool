<#
    Build-Release.ps1

    Assembles the install bundle that gets attached to a GitHub release.

    The zip is deliberately not the repository. It holds only what someone
    needs to install and run the tool, with the layout the scripts expect:
    Install.ps1 resolves assets\icon.ico relative to its own location, so the
    assets folder has to survive the extraction at the same depth.

    The artwork generators (Generate-Icon.ps1, Build-Banner.ps1) are left out
    on purpose - they rebuild assets\ from the repo's docs\ screenshots and
    have nothing to work from inside a bundle.

    No external dependencies: System.IO.Compression only.

    Outputs
        dist\windows-folder-icon-tool-v<version>.zip
#>

[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $OutDir,

    # Bare version, with or without a leading v.
    [string] $Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'

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
if (-not $OutDir)  { $OutDir = Join-Path $RepoRoot 'dist' }

$Version = $Version.TrimStart('v', 'V')
if ($Version -notmatch '^\d+\.\d+\.\d+') {
    throw "Version must look like 1.0.0, got '$Version'."
}

# --- what goes in the bundle ----------------------------------------------
# Order is the order they land in the archive listing.
$bundle = @(
    'Set-FolderIcon.ps1'
    'Install.ps1'
    'Uninstall.ps1'
    'assets\icon.ico'
    'README.md'
    'LICENSE'
)

Write-Host ''
Write-Host 'Folder Icon Tool - building release bundle' -ForegroundColor Cyan
Write-Host ("  version   : {0}" -f $Version) -ForegroundColor Cyan

# --- verify everything is present before staging anything ------------------
$missing = @()
foreach ($rel in $bundle) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel) -PathType Leaf)) {
        $missing += $rel
    }
}
if ($missing) {
    throw ("Missing from the repo, cannot build a bundle:`n  " + ($missing -join "`n  "))
}

# A zero-length or non-ICO assets\icon.ico would still produce a zip that
# installs, just with a broken context menu glyph. Catch it here instead.
$icoPath = Join-Path $RepoRoot 'assets\icon.ico'
$ico     = [System.IO.File]::ReadAllBytes($icoPath)
if ($ico.Length -lt 6 -or $ico[0] -ne 0x00 -or $ico[1] -ne 0x00 -or $ico[2] -ne 0x01) {
    throw "assets\icon.ico is not an ICO file (reserved bytes are wrong)."
}
$frameCount = [BitConverter]::ToUInt16($ico, 4)
if ($frameCount -lt 1) {
    throw "assets\icon.ico contains no frames."
}
Write-Host ("  icon      : {0} frames, {1} KB" -f $frameCount, [math]::Round($ico.Length / 1KB)) -ForegroundColor DarkGray

# --- stage, then zip --------------------------------------------------------
# $stage has to be outside the repo so the repo's own .gitignore cannot
# interfere and so the archive never picks up the archive.
$stage = Join-Path $env:TEMP ('fit-release-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    foreach ($rel in $bundle) {
        $dest = Join-Path $stage $rel
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $RepoRoot $rel) -Destination $dest -Force
    }

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    $zipName = 'windows-folder-icon-tool-v{0}.zip' -f $Version
    $zipPath = Join-Path $OutDir $zipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    # Contents at the archive root, no wrapping folder: extracting produces
    # Install.ps1 sitting next to assets\icon.ico exactly as in the repo.
    #
    # Entries are added by hand rather than through Compress-Archive or
    # ZipFile.CreateFromDirectory: both derive the entry name from the path
    # and, on .NET Framework, write the platform separator. That stores
    # assets\icon.ico. Windows Explorer tolerates it, but tools that follow
    # the ZIP spec - info-zip, Python zipfile, macOS Archive Utility - read it
    # as one flat file name with a literal backslash, so assets\ never becomes
    # a directory and the install breaks for anyone not on Windows.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in $bundle) {
            $entryName = $rel.Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                (Join-Path $stage $rel),
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $zip.Dispose()
    }

    # --- verify the archive, do not trust the writer -----------------------
    $expected = $bundle | ForEach-Object { $_.Replace('\', '/') } | Sort-Object
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $actual = $zip.Entries |
            ForEach-Object { $_.FullName } |
            Where-Object { $_ -notmatch '/$' } |
            Sort-Object

        # Guard the separator explicitly; the comparison below would report it
        # only as an opaque "missing" entry.
        $bad = $actual | Where-Object { $_ -match '\\' }
        if ($bad) {
            throw ("Archive uses backslash separators, which breaks non-Windows unzip:`n  " +
                   ($bad -join "`n  "))
        }

        $delta = Compare-Object -ReferenceObject $expected -DifferenceObject $actual
        if ($delta) {
            $report = ($delta | ForEach-Object { "  $($_.SideIndicator) $($_.InputObject)" }) -join "`n"
            throw "Archive contents do not match the expected bundle:`n$report"
        }
        Write-Host ("  verified  : {0} files in archive" -f $actual.Count) -ForegroundColor DarkGray
    }
    finally {
        $zip.Dispose()
    }

    $size = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash

    Write-Host ''
    Write-Host ("  archive   : {0}" -f $zipPath) -ForegroundColor Green
    Write-Host ("  size      : {0} KB" -f $size) -ForegroundColor Green
    Write-Host ("  sha256    : {0}" -f $hash) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Publish:' -ForegroundColor Cyan
    Write-Host ("  git tag -a v{0} -m ""Release v{0}""" -f $Version) -ForegroundColor DarkGray
    Write-Host ("  git push origin v{0}" -f $Version) -ForegroundColor DarkGray
    Write-Host ("  gh release create v{0} ""{1}"" --notes-file RELEASE-NOTES.md" -f $Version, $zipName) -ForegroundColor DarkGray
    Write-Host ''
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
