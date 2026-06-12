# ============================================================
#  script-zip  -  wizard to compress folders from packages/
#  Run on Windows PowerShell with:
#     irm https://YOUR-PROJECT.vercel.app | iex
# ============================================================
#
#  Flow:
#   1) Lists the folders inside packages/ (read from WSL)
#   2) Check the ones to compress       -> OK (Next)
#   3) Pick a mode                       -> OK (Next)
#        - git  : only Git-tracked files (NO node_modules, clean)
#        - full : EVERYTHING, includes node_modules and ignored files
#   4) Compresses INSIDE WSL (ext4, fast) and uploads -> link
#
#  Why inside WSL: the files live in Linux (\\wsl.localhost\polaris).
#  Reading them through the \\wsl.localhost\ 9P bridge from Windows is
#  extremely slow with many small files (node_modules). Running tar/git
#  natively on ext4 avoids the bridge entirely. The upload also runs
#  from inside WSL, so the 10 GB never crosses into Windows.
# ============================================================

$ErrorActionPreference = "Stop"

# --- CONFIG ---------------------------------------------------
$Distro    = "polaris"
$Packages  = "/home/developer/projects/life2life/health-gbp-main-master/packages"

# Where to upload:
#   "dropbox"    -> your Dropbox via the Dropbox HTTP API (NOTHING to install in WSL).
#   "bashupload" -> bashupload.com (50 GB, deleted after first download).
$UploadTarget = "dropbox"

# bashupload target
$BashUploadUrl = "https://bashupload.com"

# dropbox target -- direct API via curl, no install needed.
# The access token is PROMPTED at runtime (never stored: this script is public).
# Get one at https://www.dropbox.com/developers/apps -> your app -> Settings ->
# OAuth 2 -> Generated access token (needs scope files.content.write).
$DropboxDestDir = "/script-zip"   # folder inside your Dropbox to upload into
# --------------------------------------------------------------

# Run a bash script (via stdin) inside WSL, passing positional args.
# Strips CR so bash never chokes on '\r'.
function Invoke-WslScript {
    param([string]$Script, [string[]]$WslArgs)
    $clean = $Script -replace "`r", ""
    $clean | wsl -d $Distro -- bash -s -- @WslArgs
}

# ---------- 0) Sanity check: required tools inside WSL ----------
$check = Invoke-WslScript -Script @'
for t in git tar curl; do command -v "$t" >/dev/null 2>&1 || echo "MISSING:$t"; done
'@ -WslArgs @()
if ($check) {
    Write-Host "Missing tools inside WSL ($Distro):" -ForegroundColor Red
    $check | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "Install them, e.g.:  wsl -d $Distro -- sudo apt update && sudo apt install -y git curl" -ForegroundColor Yellow
    return
}

# ---------- Ask for the Dropbox token up front (masked input) ----------
$DropboxToken = $null
if ($UploadTarget -eq 'dropbox') {
    $sec = Read-Host "Paste your Dropbox access token" -AsSecureString
    $DropboxToken = [System.Net.NetworkCredential]::new('', $sec).Password
    if (-not $DropboxToken) { Write-Host "No token entered. Aborted." -ForegroundColor Red; return }
}

# ---------- 1) List folders in packages/ ----------
Write-Host ">> Listing folders in packages/ ..." -ForegroundColor Cyan
$folders = (Invoke-WslScript -Script @'
find "$1" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort
'@ -WslArgs @($Packages)) | ForEach-Object { $_.Trim() } | Where-Object { $_ }

if (-not $folders) {
    Write-Host "No folders found in $Packages" -ForegroundColor Red
    return
}

# ---------- 2) Checkbox selection (OK = Next) ----------
$hasGrid = [bool](Get-Command Out-GridView -ErrorAction SilentlyContinue)
$selected = $null
if ($hasGrid) {
    $selected = $folders |
        Out-GridView -Title "Check the folders to compress, then click OK (Next)" -PassThru
} else {
    Write-Host "Available folders:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $folders.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $folders[$i])
    }
    $ans = Read-Host "Numbers separated by comma (e.g. 1,3,4) or 'all'"
    if ($ans -eq 'all') {
        $selected = $folders
    } else {
        $selected = $ans -split ',' |
            ForEach-Object { ($_.Trim() -as [int]) - 1 } |
            Where-Object { $_ -ge 0 -and $_ -lt $folders.Count } |
            ForEach-Object { $folders[$_] }
    }
}
if (-not $selected) { Write-Host "Nothing selected. Aborted." -ForegroundColor Red; return }
Write-Host (">> Selected: " + ($selected -join ", ")) -ForegroundColor Green

# ---------- 3) Pick a mode (OK = Next) ----------
$modes = @(
    [pscustomobject]@{ Mode = "git";  Description = "Git-tracked files only (NO node_modules, clean, from HEAD)" }
    [pscustomobject]@{ Mode = "full"; Description = "EVERYTHING: includes node_modules and ignored files" }
)
$mode = $null
if ($hasGrid) {
    $pick = $modes | Out-GridView -Title "Pick a compression mode, then click OK (Next)" -PassThru
    $mode = $pick.Mode
} else {
    Write-Host "1) git  - Git-tracked files only (no node_modules)"
    Write-Host "2) full - EVERYTHING, includes node_modules"
    $mode = if ((Read-Host "Pick 1 or 2") -eq '2') { 'full' } else { 'git' }
}
if (-not $mode) { Write-Host "No mode picked. Aborted." -ForegroundColor Red; return }

# ---------- 4) Compress inside WSL + upload ----------
if ($mode -eq 'git') {
    $archive = "/tmp/packages-export.zip"
    $name    = "packages-export.zip"
    # $1=Packages dir  $2=output  $3..=selected folder names
    # git archive only includes tracked files from HEAD -> node_modules excluded.
    $compress = @'
set -e
PKG="$1"; OUT="$2"; shift 2
REPO=$(git -C "$PKG" rev-parse --show-toplevel)
PREFIX=${PKG#$REPO/}
PATHS=()
for f in "$@"; do PATHS+=("$PREFIX/$f"); done
git -C "$REPO" archive --format=zip -o "$OUT" HEAD "${PATHS[@]}"
ls -lh "$OUT" | awk '{print $5}'
'@
} else {
    $archive = "/tmp/packages-export.tar.gz"
    $name    = "packages-export.tar.gz"
    # Uses pigz (multi-core gzip) when available, otherwise plain gzip.
    $compress = @'
set -e
PKG="$1"; OUT="$2"; shift 2
if command -v pigz >/dev/null 2>&1; then
  tar -c -C "$PKG" "$@" | pigz > "$OUT"
else
  tar -czf "$OUT" -C "$PKG" "$@"
fi
ls -lh "$OUT" | awk '{print $5}'
'@
}

Write-Host ">> Compressing (mode: $mode) inside WSL..." -ForegroundColor Cyan
$size = Invoke-WslScript -Script $compress -WslArgs (@($Packages, $archive) + $selected)
Write-Host (">> Archive size: " + ($size -join "")) -ForegroundColor Cyan

if ($UploadTarget -eq 'dropbox') {
    $dest = "$DropboxDestDir/$name"
    Write-Host ">> Uploading to Dropbox via API (chunked, nothing installed)..." -ForegroundColor Cyan
    # Pass the token through the environment (WSLENV), NOT as an argument, so it
    # never shows up in the WSL process list. $1=archive  $2=dropbox dest path.
    $prevWslEnv = $env:WSLENV
    $env:DROPBOX_TOKEN = $DropboxToken
    $env:WSLENV = (@($prevWslEnv, "DROPBOX_TOKEN/u") | Where-Object { $_ }) -join ':'
    try {
        $result = Invoke-WslScript -Script @'
set -e
ARCHIVE="$1"; DEST="$2"
TOKEN="$DROPBOX_TOKEN"
[ -n "$TOKEN" ] || { echo "ERROR: no Dropbox token in environment" >&2; exit 1; }
C="https://content.dropboxapi.com/2"
SIZE=$(stat -c%s "$ARCHIVE")
CHUNK_MB=140
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

# 1) start an empty upload session
resp=$(curl -s -X POST "$C/files/upload_session/start" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Dropbox-API-Arg: {"close":false}' \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/dev/null)
sid=$(printf '%s' "$resp" | grep -o '"session_id": *"[^"]*"' | sed 's/.*"\(.*\)"$/\1/')
[ -n "$sid" ] || { echo "start failed: $resp" >&2; exit 1; }

# 2) append the file in chunks
i=0; offset=0
while [ "$offset" -lt "$SIZE" ]; do
  dd if="$ARCHIVE" of="$tmp" bs=1048576 skip=$((i*CHUNK_MB)) count=$CHUNK_MB 2>/dev/null
  n=$(stat -c%s "$tmp"); [ "$n" -gt 0 ] || break
  curl -sf -X POST "$C/files/upload_session/append_v2" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"$sid\",\"offset\":$offset},\"close\":false}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$tmp" >/dev/null || { echo "append failed at offset $offset" >&2; exit 1; }
  offset=$((offset+n)); i=$((i+1))
  printf '\r  uploaded %s / %s bytes' "$offset" "$SIZE" >&2
done
echo >&2

# 3) finish -> commit at DEST, print the stored path
curl -sf -X POST "$C/files/upload_session/finish" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"$sid\",\"offset\":$SIZE},\"commit\":{\"path\":\"$DEST\",\"mode\":\"add\",\"autorename\":true,\"mute\":false}}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/dev/null | grep -o '"path_display": *"[^"]*"' | sed 's/.*"\(.*\)"$/\1/'
'@ -WslArgs @($archive, $dest)
    } finally {
        # scrub the token from the Windows environment no matter what
        Remove-Item Env:\DROPBOX_TOKEN -ErrorAction SilentlyContinue
        if ($null -ne $prevWslEnv) { $env:WSLENV = $prevWslEnv }
        else { Remove-Item Env:\WSLENV -ErrorAction SilentlyContinue }
    }
    $banner = "UPLOADED TO DROPBOX"
} else {
    Write-Host ">> Uploading to $BashUploadUrl (one-time download)..." -ForegroundColor Cyan
    $result = Invoke-WslScript -Script @'
set -e
curl -s --upload-file "$1" "$2/$3"
'@ -WslArgs @($archive, $BashUploadUrl, $name)
    $banner = "DOWNLOAD LINK"
}

Write-Host ""
Write-Host "============ $banner ============" -ForegroundColor Green
Write-Host (($result | Where-Object { $_ }) -join "")
Write-Host "=================================" -ForegroundColor Green

# Cleanup
Invoke-WslScript -Script 'rm -f "$1"' -WslArgs @($archive) | Out-Null
