# Windows Folder Icon Tool v1.0.0

First public release. Give any Windows folder its own icon from the
right-click menu.

## Install

1. Download `windows-folder-icon-tool-v1.0.0.zip` and extract it anywhere.
2. Right-click `Install.ps1` and choose **Run with PowerShell**.
3. Right-click any folder and pick **Set Folder Icon**.

`Install.ps1` registers under `HKCU` only, so it needs no administrator
rights and touches nothing outside the two `HKCU\Software\Classes\Directory`
keys. To remove it, run `Uninstall.ps1`; icons you already applied to your
folders are left alone, so reset those first with **Reset Folder Icon**.

## What it does

Writes `desktop.ini` and a multi-size `folder-icon.ico` into the chosen
folder. The `IconResource` path is relative, so the icon survives renaming
the folder, moving it, and copying it to another drive.

## Notes for this release

- Registers the menu under `HKCU`, and removes the stale machine-wide entries
  left behind by an earlier tool whose executables no longer exist (that step
  is skipped unless the installer is elevated).
- `Install.ps1` locates `assets\icon.ico` relative to itself, so the bundle
  works from any folder and under any account.
- Accepts `.ico .png .jpg .jpeg .bmp .gif .tif .tiff .emf .wmf`, detected
  from the file's magic bytes rather than its extension, so a mislabelled
  file gets a readable error instead of a GDI+ message.
- Rewrites are atomic (temp file plus rename) and rolled back on failure, and
  a per-folder named mutex stops two invocations colliding.
- `-Reset` removes the icon files and leaves no dangling `IconResource`.
- Icon changes are notified per-folder (`SHCNE_UPDATEDIR` / `SHCNE_UPDATE`)
  without restarting Explorer. `-Refresh` additionally clears the shell icon
  cache when an open window is showing a stale icon.

## Known limitations

- Windows ignores `desktop.ini` files carrying Mark-of-the-Web, so a custom
  icon can silently stop appearing on a folder downloaded from the internet.
  The tool strips the zone identifier after writing; if the folder's trust
  settings still block it, that is the cause.
- Icon rendering depends on the shell icon cache. If a folder looks unchanged
  right after a change, F5 or reopen the window; `-Refresh` clears the cache.
- Only `.ico` files can carry more than 256x256, so Explorer never scales a
  folder icon beyond that size.
- FAT32 folders do not support `desktop.ini`-based custom icons.
- Windows 11 hides the classic context menu behind **Show more options**;
  both menu entries are registered on the classic list.

## SHA-256

```
25F663CF0E8568986D41DB1852F9076462D1797EE2388DE9D18A123F748993D3  windows-folder-icon-tool-v1.0.0.zip
```

Verify after download:

```powershell
Get-FileHash .\windows-folder-icon-tool-v1.0.0.zip -Algorithm SHA256
```

MIT licensed. Copyright (c) 2026 Rohit Kumar Mahor.
