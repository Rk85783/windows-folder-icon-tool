<#
    Uninstall.ps1

    Removes the two context menu entries and, by default, the tool files
    themselves. Folders that already received an icon keep it: their
    desktop.ini and .ico are ordinary user data and are not touched.
#>

[CmdletBinding()]
param(
    # Leave the .ps1 files on disk.
    [switch] $KeepFiles
)

$ErrorActionPreference = 'Stop'

$keys = @(
    'HKCU:\Software\Classes\Directory\shell\SetFolderIcon',
    'HKCU:\Software\Classes\Directory\shell\ResetFolderIcon'
)

Write-Host ''
Write-Host 'Folder Icon Tool - uninstalling' -ForegroundColor Cyan

foreach ($k in $keys) {
    if (Test-Path -LiteralPath $k) {
        Remove-Item -LiteralPath $k -Recurse -Force
        Write-Host ("  removed : {0}" -f $k) -ForegroundColor DarkGreen
    }
}

if (-not $KeepFiles) {
    $root = Split-Path -Parent $PSCommandPath
    Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ps1', '.md' } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force
            Write-Host ("  removed : {0}" -f $_.Name) -ForegroundColor DarkGreen
        }
    try {
        Remove-Item -LiteralPath $root -Force -ErrorAction Stop
        Write-Host ("  removed : {0}" -f $root) -ForegroundColor DarkGreen
    } catch { }
}

Write-Host ''
Write-Host 'Done. Folders with custom icons keep them.' -ForegroundColor Cyan
Write-Host ''