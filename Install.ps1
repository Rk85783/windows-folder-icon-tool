<#
    Install.ps1

    Registers the two right-click entries under HKCU (per-user, no admin
    needed) and removes the stale machine-wide entries left behind by an
    earlier tool whose executables no longer exist.

    Nothing outside the keys listed below is modified.
#>

[CmdletBinding()]
param(
    # Keep the script files when unregistering.
    [switch] $KeepDeadMachineKeys
)

$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $PSCommandPath
$setScript = Join-Path $toolRoot 'Set-FolderIcon.ps1'

if (-not (Test-Path -LiteralPath $setScript)) {
    throw "Set-FolderIcon.ps1 not found next to this installer:`n$toolRoot"
}

function New-ContextMenuEntry {
    param(
        [string] $KeyName,
        [string] $Label,
        [string] $MenuIcon,
        [string[]] $ExtraArgs
    )

    $key = "HKCU:\Software\Classes\Directory\shell\$KeyName"
    $cmd = Join-Path $key 'command'

    New-Item -Path $cmd -Force | Out-Null

    # %V is the full path of the folder that was right-clicked.
    $arguments = @(
        '-NoProfile'
        '-STA'
        '-WindowStyle', 'Hidden'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"' + $setScript + '"')
        '-FolderPath', '"%V"'
    ) + $ExtraArgs

    $commandLine = 'powershell.exe ' + ($arguments -join ' ')

    Set-ItemProperty -Path $key -Name '(default)' -Value $Label -Type String
    Set-ItemProperty -Path $key -Name 'Icon'    -Value $MenuIcon -Type String
    Set-ItemProperty -Path $cmd -Name '(default)' -Value $commandLine -Type String

    Write-Host ("  registered : {0}  ->  {1}" -f $Label, $commandLine) -ForegroundColor DarkGreen
}

Write-Host ''
Write-Host 'Folder Icon Tool - installing' -ForegroundColor Cyan
Write-Host ("  location : {0}" -f $toolRoot)
Write-Host ''

# HKCU\Software\Classes\Directory\shell applies to a folder that was
# right-clicked. It deliberately does not touch the folder-background menu,
# so the existing "New / Paste / Properties" items are untouched.
Write-Host 'Context menu entries (current user):' -ForegroundColor Cyan
New-ContextMenuEntry -KeyName 'SetFolderIcon'   -Label 'Set Folder Icon'   -MenuIcon 'shell32.dll,16769' -ExtraArgs @()
New-ContextMenuEntry -KeyName 'ResetFolderIcon' -Label 'Reset Folder Icon' -MenuIcon 'shell32.dll,131'   -ExtraArgs @('-Reset')

# --- cleanup of the broken entries from a previous tool -------------------
$deadKeys = @(
    'HKLM:\SOFTWARE\Classes\Directory\shell\Change Folder Image',
    'HKLM:\SOFTWARE\Classes\Directory\shell\Remove Folder Image'
)

Write-Host ''
Write-Host 'Stale machine-wide entries:' -ForegroundColor Cyan

if ($KeepDeadMachineKeys) {
    foreach ($k in $deadKeys) {
        if (Test-Path -LiteralPath $k) { Write-Host ("  kept      : {0}" -f $k) -ForegroundColor DarkYellow }
    }
}
else {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    foreach ($k in $deadKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        if (-not $isAdmin) {
            Write-Host ("  skipped   : {0}  (needs administrator)" -f (Split-Path -Leaf $k)) -ForegroundColor DarkYellow
            continue
        }
        try {
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
            Write-Host ("  removed   : {0}  (its executable no longer existed)" -f (Split-Path -Leaf $k)) -ForegroundColor DarkGreen
        } catch {
            Write-Host ("  FAILED    : {0}  {1}" -f (Split-Path -Leaf $k), $_.Exception.Message) -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host 'Done. Right-click any folder to see "Set Folder Icon".' -ForegroundColor Cyan
Write-Host 'If a menu looks stale, press F5 or reopen Explorer.' -ForegroundColor DarkGray
Write-Host ''