# script-zip

Serve a PowerShell script from Vercel (synced with Git) so it can be run with:

```powershell
irm https://YOUR-PROJECT.vercel.app | iex
```

The script is a wizard that compresses selected folders from a `packages/` directory
**living inside WSL** and uploads the archive, returning a one-time download link.

## Layout

```
script-zip/
├── public/
│   └── script.ps1     # the wizard that gets served and executed
├── vercel.json        # forces Content-Type text/plain and maps / -> /script.ps1
├── README.md
└── CHAT.md            # design notes / conversation log
```

## How it works (Windows + WSL)

Two separate worlds:

- **Windows** runs PowerShell (`irm | iex`) and shows the wizard UI. It only orchestrates.
- **WSL (`polaris`, Linux/ext4)** is where the files live and where `find`, `git`,
  `tar` and `curl` actually run, as native Linux processes.

The script never touches the slow `\\wsl.localhost\` 9P bridge. It calls `wsl.exe` to
run everything inside Linux, so the 10 GB never crosses into Windows — even the upload
runs from inside WSL straight to the internet.

### Wizard steps
1. Lists the folders inside `packages/`.
2. Checkbox selection (`Out-GridView`, OK = Next; console fallback if unavailable).
3. Pick a mode (OK = Next):
   - `git`  → `git archive` = only Git-tracked files (no `node_modules`, clean).
   - `full` → `tar` (with `pigz` if present) = everything, including `node_modules`.
4. Compresses inside WSL and uploads → prints the link.

## Deploy

1. Create a GitHub repo and push this folder:
   ```bash
   git init
   git add .
   git commit -m "init script-zip"
   git branch -M main
   git remote add origin https://github.com/YOUR_USER/script-zip.git
   git push -u origin main
   ```
2. On [vercel.com](https://vercel.com) → **Add New Project** → import the repo → Deploy.
   Every `git push` redeploys automatically.

## Usage

```powershell
# clean URL (thanks to the / -> /script.ps1 rewrite)
irm https://YOUR-PROJECT.vercel.app | iex
```

Optional custom domain: Project → Settings → Domains → `get.yourdomain.com`, then
`irm https://get.yourdomain.com | iex`.

## Notes

- `vercel.json` forces `Content-Type: text/plain` — required so `iex` gets code, not HTML.
- `Cache-Control: no-store` so script changes show up immediately.
- ⚠️ `irm | iex` runs remote code blindly: only run URLs you control / trust.
- Upload target is set in the config block (`$UploadTarget`):
  - `bashupload` — bashupload.com, up to 50 GB, one-time (deleted after first download).
  - `dropbox` — your Dropbox via the **direct Dropbox HTTP API** (chunked upload session),
    nothing installed in WSL. You handle the download.
- 🔐 **The Dropbox token is never stored** — this script is served publicly from Vercel.
  When `$UploadTarget = "dropbox"`, the script **prompts for the token at runtime** (masked
  input) and passes it to WSL via the environment (`WSLENV`), never as a process argument;
  it's scrubbed afterwards. Generate a token at https://www.dropbox.com/developers/apps →
  your app → Settings → OAuth 2 → Generated access token (scope `files.content.write`).
  App Console tokens are short-lived (~4 h), fine for a one-shot upload.
- Before running, confirm the distro name with `wsl -l -v` and that `git`/`curl` are
  installed inside it (the script checks and tells you if not).
```
