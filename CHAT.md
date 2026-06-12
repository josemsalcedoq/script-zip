# Conversation — script-zip (log)

Saved context to continue the project. Date: 2026-06-12.

---

## Goal

Be able to **upload a large folder/file (~10 GB) to the internet** and get a
download link, ideally **single-use**, and also **serve a PowerShell script from
my own URL** so it can be run with the pattern:

```powershell
irm https://my-url | iex
```

(same as `irm https://get.activated.win | iex`).

Decision: **host the script on Vercel connected to Git.**

---

## 1. Upload a large folder/file and get a link

Folders must be **archived first** (these services take files, not folders).

### Services and limits (approx.)

| Service          | Limit   | One-time                | Notes                          |
|------------------|---------|-------------------------|--------------------------------|
| transfer.sh      | ~10 GB  | no (Max-Downloads hdr)  | flaky lately                   |
| oshi.at          | ~5 GB   | yes (`?autodestroy=1&dl=1`) | deletes after N downloads  |
| temp.sh          | ~4 GB   | yes (`Max-Downloads`)   |                                |
| **bashupload.com** | **50 GB** | **yes (deleted after 1st download, else 3 days)** | **best for ~10 GB** |

→ bashupload.com covers size + one-time. **Dropbox** (10 TB) is the other target — see 1.1.

```bash
curl --upload-file file.zip https://bashupload.com/file.zip
```

### 1.1 Dropbox target (10 TB) — direct API, NOTHING installed in WSL
Constraint from user: **install nothing in polaris**; just push the tar/zip to their
Dropbox; they handle the download themselves. So: no rclone. Use the **Dropbox HTTP API
directly with curl** (already present). File is ~10 GB, so the single-shot
`/files/upload` (150 MB cap) won't do — must use a **chunked upload session**:
`upload_session/start` (empty) → `append_v2` per 140 MB chunk → `finish` (commit at path).

Chunks read with `dd bs=1MB skip=i*140 count=140` into a temp file, posted with
`--data-binary @tmp`. Offset tracked in bytes for the cursor.

#### Token / auth — SECURITY DECISION (final)
- A public `irm|iex` script **cannot hold a secret**: Vercel serves script.ps1 as
  plaintext to anyone, so any embedded token = full access to the 10 TB Dropbox for
  whoever sees the URL. (User briefly chose to embed it; then switched to runtime prompt.)
- **Final approach: prompt for the token at runtime.** At the start of the script (when
  target = dropbox) it does `Read-Host -AsSecureString`, converts to plain, and passes it
  to WSL via the **environment (`WSLENV`)** — NOT as a process arg (so it's not visible in
  `ps`), then scrubs `$env:DROPBOX_TOKEN`/`$env:WSLENV` in a `finally`.
- bash side reads `TOKEN="$DROPBOX_TOKEN"`. Nothing stored, nothing in the repo.
- Generate a token: https://www.dropbox.com/developers/apps → app → Permissions tab
  (`files.content.write`, Submit) → Settings tab → OAuth 2 → Generated access token →
  Generate. These are short-lived (~4 h) → fine for a one-shot upload.
- App credentials (key/secret) were shared in chat → user advised they can rotate the
  app secret in the console anytime. NOT written to any repo file.
- For a non-expiring token: refresh-token flow (app key+secret+refresh token) — TODO,
  but that reintroduces a stored secret, so only via runtime prompt or a local file.

Script: `$UploadTarget = "dropbox" | "bashupload"` switches targets; `$DropboxDestDir`
sets the Dropbox folder (e.g. `/script-zip`).

### Notes
- Time depends on **upload bandwidth**. 10 GB at 20 Mbps ≈ 70 min.
- These services don't resume on drop → splitting helps (7z `-v4g`).
- If sensitive: **encrypt the archive** (7-Zip password) before uploading.
- `curl.exe` ships with Windows 10/11.

---

## 2. Serve the script with `irm | iex`

`irm` = `Invoke-RestMethod` (downloads the text) · `iex` = `Invoke-Expression`
(runs it). All that's needed is a URL returning **plain text** with the script.

### Decided: Vercel + Git
- Vercel connects to the repo; every push redeploys. Free.
- Key: serve the `.ps1` as `Content-Type: text/plain`.

Project layout:
```
script-zip/
├── public/
│   └── script.ps1
├── vercel.json        # text/plain + rewrite / -> /script.ps1
├── README.md
└── CHAT.md            # this file
```

Final usage: `irm https://YOUR-PROJECT.vercel.app | iex`
Pretty domain (optional): Project → Settings → Domains → `get.yourdomain.com`.

⚠️ `irm | iex` runs remote code blindly. Only run URLs you control/trust.

---

## 3. Real case: the folder lives in WSL

Fixed path to share (UNC from Windows):
`\\wsl.localhost\polaris\home\developer\projects\life2life\health-gbp-main-master\packages`

- WSL distro: **`polaris`**
- Equivalent Linux path: `/home/developer/projects/life2life/health-gbp-main-master/packages`

### Two-worlds model (Windows ↔ WSL)
- **Windows**: runs PowerShell + `irm|iex`, shows the wizard UI. Orchestrates only.
- **WSL (polaris, Linux/ext4)**: files live here; `find`/`git`/`tar`/`curl` run here
  as native Linux processes.

**Key decision:** `\\wsl.localhost\` goes through the 9P/Plan9 bridge and is VERY slow
(worse with many small files like `node_modules`). So we do NOT compress from Windows
over the UNC path. PowerShell only orchestrates; all the work (tar + git + curl) runs
**inside WSL** via `wsl.exe`. The upload also runs inside WSL, so the 10 GB never
crosses into Windows — it goes straight from Linux to the internet (WSL2 NAT).

This directly answers "it's network / UNC / Linux, will it work?" → **yes**, because
the design treats the files as Linux files and never uses the slow Windows bridge.

Requirements: `wsl.exe` present; distro `polaris` boots; `git`/`tar`/`curl` installed
inside it (script checks); WSL2 outbound internet (default on).

## 3.1 Wizard (current script.ps1)

`packages/` contains several folders. The script is a wizard:
1. Lists the folders inside `packages/` (via `find` in WSL).
2. **Checkbox** selection (`Out-GridView -PassThru`, OK = Next; console fallback).
3. Pick a **mode** (OK = Next):
   - `git`  → `git archive` = Git-tracked files only (**no** node_modules, clean).
   - `full` → `tar` (+ `pigz` if present) = **EVERYTHING**, includes node_modules.
4. Compresses inside WSL and uploads to bashupload → prints the link.

### `git archive` clarification (corrected misunderstanding)
- `-o` / `--output` = **output file name**, NOT "origin".
- What gets included is decided by the **tree-ish**: `HEAD` (last local commit),
  `origin/main` (what's on origin), a branch/tag.
- `git archive` **only includes tracked files** → automatically excludes node_modules
  and anything ignored. That's the "clean" mode.
- `git archive` CANNOT include node_modules/ignored files → for "everything" use `tar`.

| Mode | Command | node_modules |
|---|---|---|
| Clean | `git archive --format=zip -o out.zip HEAD <subfolder>` | ❌ no |
| Everything | `tar czf out.tar.gz <subfolder>` | ✅ yes |

Note: git mode archives **HEAD** (last commit), not the working tree — uncommitted
changes to tracked files won't be reflected. Switch the tree-ish to `origin/main`
if you want "what's on origin" instead.

### Technical details of the script
- bash scripts are passed via **stdin to `wsl bash -s --`** with positional args
  (avoids nested-quoting hell). `\r` is stripped so bash doesn't choke.
- `git archive` runs from the repo root (`git rev-parse --show-toplevel`) using
  pathspecs `packages/<folder>` computed from the relative prefix.
- Step 0 checks `git`/`tar`/`curl` exist inside WSL and bails with an apt hint if not.
- `full` mode uses `pigz` (multi-core gzip) when available — much faster on 10 GB.

### Verified facts
- bashupload.com: up to **50 GB**, **one-time** (deleted after first download, else 3 days).
  Sources: https://github.com/IO-Technologies/bashupload , https://bashupload.com/

---

## Status / TODO

- [x] Project scaffolded in `Documents/projects/script-zip`
- [x] `vercel.json` with `text/plain` + root rewrite
- [x] Flow defined: **upload** selected folders from `packages` in WSL (`polaris`)
- [x] `script.ps1` = wizard (list → checkbox → git/full mode → compress in WSL → upload)
- [x] Everything translated to English
- [x] Verified bashupload limits (50 GB, one-time)
- [ ] Test the script locally in Windows PowerShell
  - [ ] Confirm `Out-GridView` exists (5.1 yes; PS7 uses console fallback)
  - [ ] Confirm distro name with `wsl -l -v`
  - [ ] Confirm `curl` installed inside WSL
- [x] Dropbox: app created (key/secret provided by user)
- [ ] Dropbox: enable scope files.content.write, generate access token (paste at runtime)
- [ ] Create GitHub repo + connect to Vercel
- [ ] (Optional) custom domain
- [ ] (Optional) refresh-token flow for a permanent (non-4h) Dropbox token
- [ ] (Optional) encrypt the archive before upload if sensitive
