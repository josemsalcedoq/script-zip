# ============================================================
#  script-zip  -  pick folders, compress inside WSL, upload
#  Run on Windows PowerShell with:
#     irm https://script-zip.vercel.app | iex
# ============================================================
#  Relaunches into its own dedicated window (MAS-style), then:
#   1) lists folders inside $Packages (read from WSL)
#   2) in-console checkbox menu to pick folders
#   3) pick a mode: git (tracked only) or full (everything incl node_modules)
#   4) compresses INSIDE WSL (ext4, fast) and uploads -> link / Dropbox
#  All heavy work runs natively in Linux; the bytes never cross to Windows.
# ============================================================

$ErrorActionPreference = "Stop"

# --- CONFIG ---------------------------------------------------
$SelfUrl        = "https://script-zip.vercel.app"   # used to relaunch in its own window
$Distro         = "polaris"
$Packages       = "/home/developer/projects/life2life"
$UploadTarget   = "dropbox"                          # "dropbox" | "bashupload"
$BashUploadUrl  = "https://bashupload.com"
$DropboxDestDir = "/script-zip"                      # folder inside your Dropbox
# --------------------------------------------------------------

# Relaunch in a dedicated window (MAS-style): one clean console, no popups.
# The fresh window re-fetches and runs the script with the marker set.
if (-not $env:SCRIPTZIP_WINDOW) {
    Start-Process powershell -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command',
        "`$env:SCRIPTZIP_WINDOW='1'; irm $SelfUrl | iex"
    )
    return
}
try { $host.UI.RawUI.WindowTitle = 'script-zip' } catch {}

# Run a bash script inside WSL, passing positional args. The script is base64-encoded
# (ASCII, survives any pipe/encoding) and decoded in WSL, so Windows PowerShell can't
# mangle multi-line text piped to wsl.exe.
function Invoke-WslScript {
    param([string]$Script, [string[]]$WslArgs)
    $clean = $Script -replace "`r", ""
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($clean))
    $quoted = ""
    if ($WslArgs) {
        $quoted = ($WslArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    }
    wsl -d $Distro -- bash -c "echo $b64 | base64 -d | bash -s -- $quoted"
}

Clear-Host
Write-Host "  script-zip" -ForegroundColor Cyan
Write-Host "  $Packages`n" -ForegroundColor DarkGray

# ---------- 0) Sanity check: required tools inside WSL ----------
$check = Invoke-WslScript -Script @'
for t in git tar curl; do command -v "$t" >/dev/null 2>&1 || echo "MISSING:$t"; done
'@ -WslArgs @()
if ($check) {
    Write-Host "Missing tools inside WSL ($Distro):" -ForegroundColor Red
    $check | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "Install, e.g.:  wsl -d $Distro -- sudo apt update && sudo apt install -y git curl" -ForegroundColor Yellow
    return
}

# ---------- Ask for the Dropbox token up front (masked) ----------
$DropboxToken = $null
if ($UploadTarget -eq 'dropbox') {
    $sec = Read-Host "Paste your Dropbox access token" -AsSecureString
    $DropboxToken = [System.Net.NetworkCredential]::new('', $sec).Password
    if (-not $DropboxToken) { Write-Host "No token entered. Aborted." -ForegroundColor Red; return }
}

# ---------- 1) List folders ----------
Write-Host ">> Listing folders in $Packages ..." -ForegroundColor Cyan
$folders = @((Invoke-WslScript -Script @'
find "$1" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort
'@ -WslArgs @($Packages)) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $folders) { Write-Host "No folders found in $Packages" -ForegroundColor Red; return }

# ---------- 2) In-console checkbox menu (no popups) ----------
$chosen = @{}
while ($true) {
    Clear-Host
    Write-Host "  Select folders to compress  ($Packages)`n" -ForegroundColor Cyan
    for ($i = 0; $i -lt $folders.Count; $i++) {
        $mark  = if ($chosen[$i]) { "[x]" } else { "[ ]" }
        $color = if ($chosen[$i]) { "Green" } else { "Gray" }
        Write-Host ("   {0} {1,2}. {2}" -f $mark, ($i + 1), $folders[$i]) -ForegroundColor $color
    }
    Write-Host "`n  numbers toggle (e.g. 1,3)   a = all   n = none   Enter = confirm" -ForegroundColor DarkGray
    $k = Read-Host "  >"
    if ($k -eq '') { break }
    elseif ($k -eq 'a') { for ($i = 0; $i -lt $folders.Count; $i++) { $chosen[$i] = $true } }
    elseif ($k -eq 'n') { $chosen = @{} }
    else {
        foreach ($tok in ($k -split '[,\s]+' | Where-Object { $_ })) {
            $idx = ($tok -as [int]) - 1
            if ($idx -ge 0 -and $idx -lt $folders.Count) { $chosen[$idx] = -not $chosen[$idx] }
        }
    }
}
$selected = @(for ($i = 0; $i -lt $folders.Count; $i++) { if ($chosen[$i]) { $folders[$i] } })
if (-not $selected) { Write-Host "Nothing selected. Aborted." -ForegroundColor Red; return }
Write-Host (">> Selected: " + ($selected -join ", ")) -ForegroundColor Green

# ---------- 3) Pick a mode (in-console menu) ----------
Write-Host "`n  Compression mode:" -ForegroundColor Cyan
Write-Host "    1. git  - tracked files only (no node_modules, clean)"
Write-Host "    2. full - EVERYTHING, includes node_modules"
do { $m = Read-Host "  Pick 1 or 2" } while ($m -notin '1', '2')
$mode = if ($m -eq '2') { 'full' } else { 'git' }

# ---------- 4) Compress inside WSL ----------
if ($mode -eq 'git') {
    $archive = "/tmp/packages-export.zip"
    $name    = "packages-export.zip"
    # Derive the repo from the FIRST selected folder, so it works at any level.
    $compress = @'
set -e
PKG="$1"; OUT="$2"; shift 2
first="$1"
REPO=$(git -C "$PKG/$first" rev-parse --show-toplevel 2>/dev/null) || {
  echo "ERROR: '$first' is not inside a git repository. Use 'full' mode for non-git folders." >&2; exit 1; }
PATHS=()
for f in "$@"; do
  d="$PKG/$f"
  if [ "$d" = "$REPO" ]; then PATHS+=("."); else PATHS+=("${d#$REPO/}"); fi
done
git -C "$REPO" archive --format=zip -o "$OUT" HEAD "${PATHS[@]}"
ls -lh "$OUT" | awk '{print $5}'
'@
} else {
    $archive = "/tmp/packages-export.tar.gz"
    $name    = "packages-export.tar.gz"
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
if ($LASTEXITCODE -ne 0) {
    Write-Host "Compression failed. Nothing was uploaded." -ForegroundColor Red
    if ($mode -eq 'git') { Write-Host "Tip: try 'full' mode (works for any folder, includes node_modules)." -ForegroundColor Yellow }
    return
}
Write-Host (">> Archive size: " + ($size -join "")) -ForegroundColor Cyan

# ---------- 5) Upload ----------
if ($UploadTarget -eq 'dropbox') {
    $dest = "$DropboxDestDir/$name"
    Write-Host ">> Uploading to Dropbox via API (chunked, nothing installed)..." -ForegroundColor Cyan
    # Token passes through the environment (WSLENV), NOT as an arg (not visible in `ps`).
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
        $uploadOk = ($LASTEXITCODE -eq 0)
    } finally {
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
    $uploadOk = ($LASTEXITCODE -eq 0)
    $banner = "DOWNLOAD LINK"
}

$clean = ($result | Where-Object { $_ }) -join ""
if (-not $uploadOk -or -not $clean) {
    Write-Host "Upload failed." -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "============ $banner ============" -ForegroundColor Green
    Write-Host $clean -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green
}

# Cleanup temp archive
Invoke-WslScript -Script 'rm -f "$1"' -WslArgs @($archive) | Out-Null
