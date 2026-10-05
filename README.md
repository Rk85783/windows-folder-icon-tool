# windows-folder-icon-tool

Give any Windows folder its own icon, from the right-click menu.

Pick an image, and the folder keeps that icon — through renames, moves, and
copies to other drives. No install, no admin rights, no dependencies.

![MIT](https://img.shields.io/badge/license-MIT-green)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-%23512BD4)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)

---

## Why this exists

Windows has supported custom folder icons since Win 95, but the feature is
barely discoverable and the underlying mechanism is undocumented folklore. The
existing tools also tend to install machine-wide, need administrator rights,
or — since the **June 2026 security update** — silently stop working.

This one is deliberately minimal and portable:

- **No installer, no admin.** Four text files and two keys under `HKCU`.
  It works on locked-down machines where other tools cannot be installed.
- **Correct on post-June-2026 Windows.** See [the security update
  note](#the-june-2026-security-update) — this is the part most tools have
  not caught up with.
- **Cannot crash Explorer.** The context menu launches a separate process; no
  code is ever loaded into the shell's address space.
- **Interrupt-safe.** Atomic writes plus rollback, verified by killing the
  process at seven different points mid-run.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or later (ships with Windows)
- .NET Framework 4.x (ships with Windows)

No modules to install. Nothing is downloaded.

## Install

```powershell
git clone git@github-personal:Rk85783/windows-folder-icon-tool.git
cd windows-folder-icon-tool
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

`Install.ps1` registers two context-menu entries and does not copy anything —
the scripts run straight from wherever you cloned them.

To install into `%LOCALAPPDATA%\Programs\FolderIconTool` instead, copy the
folder there first and then run `Install.ps1`.

## Use

Right-click any folder → **Set Folder Icon** → choose an image.

Right-click again → **Reset Folder Icon** restores the default.

| Works | Does not |
|---|---|
| `.ico` `.png` `.jpg` `.jpeg` `.bmp` `.gif` `.tif` `.tiff` `.emf` `.wmf` | `.svg` `.webp` `.heic` `.avif` `.pdf` camera RAW |

SVG is the common failure: it is vector art and Windows cannot rasterise it
for an icon. Open it in a browser and save a screenshot. The tool sniffs the
real format from the file's magic bytes, so a `.webp` renamed to `.png` is
still reported accurately rather than failing cryptically.

Two more limitations worth knowing:

- **Animated GIF → first frame only.** GDI+ does not step through frames.
- **Multi-page TIFF → first page only.**

### Scripting

```powershell
$s = "$env:LOCALAPPDATA\Programs\FolderIconTool\Set-FolderIcon.ps1"

# Skip the file picker
powershell -NoProfile -STA -ExecutionPolicy Bypass -File $s `
  -FolderPath 'D:\Projects\my-app' -SourcePath 'D:\logo.png'

# Re-notify the shell only; writes nothing
powershell -NoProfile -STA -ExecutionPolicy Bypass -File $s `
  -FolderPath 'D:\Projects\my-app' -Refresh
```

| Switch | Effect |
|---|---|
| `-FolderPath` | target folder (required) |
| `-SourcePath` | use this image instead of showing the picker |
| `-Reset` | restore the default icon |
| `-Refresh` | clear the icon cache and re-notify the shell; writes nothing |
| `-ShowSuccess` | show a confirmation dialog |
| `-NoDialogs` | suppress dialogs, report via exit code and stderr |

## What it does to a folder

Adds two hidden files and sets the folder's `System` attribute, which is what
makes Windows honour a folder's `desktop.ini` at all.

| File | Purpose |
|---|---|
| `desktop.ini` | points Explorer at the icon, using a **relative** path |
| `folder-icon.ico` | the icon itself |

Nothing outside the folder you picked is ever modified. Drive roots and
protected locations such as `C:\Windows` are refused outright.

Those files are hidden **by design** — Windows' own documented approach. To
see them, turn on Explorer → View → Show → **"Hide protected operating system
files"**.

Re-running overwrites the same `folder-icon.ico` and refreshes `desktop.ini`.
If a differently-named icon was left by an older tool, that file is deleted,
so a folder never accumulates junk.

## The generated .ico

The `.ico` format stores width and height in a **single byte per dimension**,
where `0` means 256. So **256×256 is the true maximum**, and Explorer never
scales a folder icon beyond it — a 512×512 `.ico` is not representable at all.
Sources larger than that are downscaled with bicubic filtering and a
transparent background, so they still look sharp.

Frames included: **16, 24, 32, 48, 64, 128, 256** px. The 128 and 256 frames
are stored as PNG payloads and the smaller ones as classic DIBs, which is what
Windows itself writes.

Non-square images are scaled to fit and padded with transparency — nothing is
distorted and nothing is cropped.

## Design notes

* **It cannot break Explorer.** The menu entry launches a separate process.
  No code is ever loaded into Explorer's address space.
* **Per-user.** Everything lives under `HKCU`, so no administrator rights are
  required and removal is a single registry key.
* **Interrupt-safe.** All writes go to a temp file and are then renamed into
  place, so Explorer never reads a half-written `desktop.ini`. If the process
  is killed mid-run, `finally` restores the previous bytes.
* **Single instance per folder.** A named mutex serialises concurrent runs.
* **No Explorer restart.** Refresh uses `SHChangeNotify` (targeted
  `SHCNE_UPDATEDIR`, then a global `SHCNE_ASSOCCHANGED`) plus
  `ie4uinit -show`. The full `ie4uinit -ClearIconCache` is deliberately *not*
  run on a normal change — it wipes the shell's icon cache database and forces
  every icon in every open window to re-extract, which looks like a flicker.
  It is reserved for `-Refresh`, where you already know the light refresh was
  not enough.

### The June 2026 security update

Since the June 2026 updates, Windows ignores a `desktop.ini` whose source it
cannot establish as trusted — notably files carrying a Mark-of-the-Web, which
arrive via browser downloads, remote/WebDAV locations, or untrusted network
paths. The symptom is a custom icon that silently stops appearing, with no
error anywhere.

The tool writes `desktop.ini` locally, so no zone identifier exists, and it
runs `Unblock-File` on it anyway as a safeguard.

If you copy a customised folder off a USB drive or a network share and the
icon disappears, that trust check is the reason — not this tool. Microsoft's
own remedies are to add the source to Trusted Sites, remove the zone
identifier with `Unblock-File`, or set the `Allow the use of remote paths in
file shortcut icons` policy.

## Troubleshooting

**Icon does not change.**
Nearly always the shell icon cache, not the tool. The files are written
correctly — an open Explorer window is showing a cached icon.

1. Click the folder's window and press `F5`.
2. Navigate to another drive and back.
3. Ask for a refresh without re-picking the image. This is the heavy variant,
   so it clears the icon cache too:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\Programs\FolderIconTool\Set-FolderIcon.ps1" `
  -FolderPath 'D:\Projects\my-app' -Refresh
```

F5 in an Explorer window afterwards is enough — no sign-out required.

**The menu entry is missing.**
Re-run `Install.ps1`. Confirm the key exists:

```powershell
Get-ItemProperty 'HKCU:\Software\Classes\Directory\shell\SetFolderIcon'
```

**Menu entry visible but nothing happens.**
Run the script by hand to see the error — add `-ShowSuccess` for a
confirmation, or `-NoDialogs` to get it on stderr with a real exit code.

**Network or removable drives.**
Custom icons there depend on the trust rules above, and some formats (FAT32,
WebDAV) handle hidden and system attributes differently.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

This removes both registry entries and the script files. Folders that already
have an icon keep it — that is ordinary user data, not part of the install. To
clear those first, right-click each folder → **Reset Folder Icon**.

## Author

Made by **Rohit Kumar Mahor** — [GitHub](https://github.com/Rk85783) ·
[LinkedIn](https://www.linkedin.com/in/rohit-kumar-mahor-8761a31b6/)

Found a bug or have an idea? Open an issue.

## License

MIT — see [LICENSE](LICENSE).

Folder icons, `desktop.ini` and the `SHCNE_*` notification constants are
documented Windows behaviour. No Microsoft or other vendor assets are
included in this repository.
