# script-zip

Serve PowerShell scripts from Vercel (synced with Git) so they can be run with `irm | iex`.

```powershell
irm https://script-zip.vercel.app | iex
```

## Layout

```
script-zip/
├── public/
│   └── cleanup.ps1    # served at / : safe disk cleanup + disk usage report
├── archive/
│   └── script-zip.ps1 # old WSL compress/upload wizard (not served, kept for later)
├── meta-sync/         # laptop helpers for the old wizard
├── vercel.json        # forces Content-Type text/plain and maps / -> /cleanup.ps1
└── CHAT.md            # design notes for the old wizard
```

## cleanup.ps1 (win-clean)

For Windows 10/11 (Windows PowerShell 5.1). Asks for admin (UAC); without admin it still
cleans your own files and gives a partial report.

1. **Measures** what can be cleaned and shows a checklist with sizes. Nothing is deleted yet.
   Type numbers to toggle items, Enter to clean, `r` for report only.
2. **Cleans** only things Windows or the app recreates by itself:
   - Temp files of every user + `C:\Windows\Temp` — only files untouched for 7+ days
     (same rule as Disk Cleanup; newest of creation/write time, so freshly extracted
     installers are never touched).
   - Internet cache (INetCache), 7+ days.
   - Crash dumps and Windows Error Reporting files, 7+ days.
   - Edge / Chrome cache (not cookies, passwords or history) — skipped while the browser runs.
   - Windows Update download cache — skipped while a restart is pending or updates install;
     services are always restarted.
   - Delivery Optimization cache (official cmdlet).
   - Off by default: Recycle Bin, DISM `/StartComponentCleanup` (Microsoft's own, no `/ResetBase`).
3. **Reports** where the space on `C:` goes: disk totals, pagefile/hiberfil, restore points
   (shadow copies), reserved storage, Windows.old, a tree of folders ≥ 1 GB, files ≥ 1 GB,
   WSL/Docker virtual disks, space no readable file explains, and commands to reclaim the
   big items yourself.

Never touched: Documents/Desktop/Downloads, OneDrive, Windows.old, restore points,
pagefile/hiberfil, `C:\Windows\Installer`, WinSxS (except through DISM), WSL/Docker disks,
anything behind a junction or symlink. A transcript is saved to
`C:\Users\Public\Documents\disk-report-<date>.txt`.

## Deploy

Vercel project `script-zip` is connected to this repo; every push to `main` redeploys.

- `vercel.json` forces `Content-Type: text/plain` — required so `iex` gets code, not HTML.
- `Cache-Control: no-store` so script changes show up immediately.
- ⚠️ `irm | iex` runs remote code blindly: only run URLs you control / trust.
