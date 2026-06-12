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
$DropboxMemberId = ""                                # Business/team: dbmid:... (auto-detected if blank)
# --------------------------------------------------------------

# Try to relaunch in a dedicated window (MAS-style). If the environment blocks
# spawning a new window (locked-down/corporate), just run in the current window --
# there are no popups, so a single window works fine either way.
if (-not $env:SCRIPTZIP_WINDOW) {
    try {
        Start-Process powershell -ArgumentList @(
            '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command',
            "`$env:SCRIPTZIP_WINDOW='1'; irm $SelfUrl | iex"
        ) -ErrorAction Stop
        return
    } catch {
        $env:SCRIPTZIP_WINDOW = '1'   # couldn't open a new window -> continue here
    }
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

# ---------- 4) Compress + upload EACH selected folder independently ----------
# One archive per folder, named exactly after the folder.

# Single-folder compressors ($1=Packages dir  $2=output  $3=folder name)
$compressGit = @'
set -e
PKG="$1"; OUT="$2"; F="$3"
REPO=$(git -C "$PKG/$F" rev-parse --show-toplevel 2>/dev/null) || {
  echo "ERROR: '$F' is not inside a git repository. Use 'full' mode for non-git folders." >&2; exit 1; }
d="$PKG/$F"
if [ "$d" = "$REPO" ]; then REL="."; else REL="${d#$REPO/}"; fi
git -C "$REPO" archive --format=zip -o "$OUT" HEAD "$REL"
ls -lh "$OUT" | awk '{print $5}'
'@
$compressFull = @'
set -e
PKG="$1"; OUT="$2"; F="$3"
if command -v pigz >/dev/null 2>&1; then
  tar -c -C "$PKG" "$F" | pigz > "$OUT"
else
  tar -czf "$OUT" -C "$PKG" "$F"
fi
ls -lh "$OUT" | awk '{print $5}'
'@

# Dropbox upload bash ($1=archive  $2=dest path); token/member via WSLENV.
$dropboxUpload = @'
set -e
ARCHIVE="$1"; DEST="$2"
TOKEN="$DROPBOX_TOKEN"
[ -n "$TOKEN" ] || { echo "ERROR: no Dropbox token in environment" >&2; exit 1; }
API="https://api.dropboxapi.com/2"
C="https://content.dropboxapi.com/2"

# Business/team token? Act as a specific member via Dropbox-API-Select-User.
SELECT=()
mid="$DROPBOX_MEMBER"
if [ -z "$mid" ]; then
  admin=$(curl -s -X POST "$API/team/token/get_authenticated_admin" -H "Authorization: Bearer $TOKEN" 2>/dev/null)
  mid=$(printf '%s' "$admin" | grep -o '"team_member_id": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"$/\1/')
fi
if [ -n "$mid" ]; then SELECT=(-H "Dropbox-API-Select-User: $mid"); fi

SIZE=$(stat -c%s "$ARCHIVE")
CHUNK_MB=140
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

resp=$(curl -s -X POST "$C/files/upload_session/start" \
  -H "Authorization: Bearer $TOKEN" "${SELECT[@]}" \
  -H 'Dropbox-API-Arg: {"close":false}' \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/dev/null)
sid=$(printf '%s' "$resp" | grep -o '"session_id": *"[^"]*"' | sed 's/.*"\(.*\)"$/\1/')
[ -n "$sid" ] || { echo "start failed: $resp" >&2; exit 1; }

i=0; offset=0
while [ "$offset" -lt "$SIZE" ]; do
  dd if="$ARCHIVE" of="$tmp" bs=1048576 skip=$((i*CHUNK_MB)) count=$CHUNK_MB 2>/dev/null
  n=$(stat -c%s "$tmp"); [ "$n" -gt 0 ] || break
  curl -sf -X POST "$C/files/upload_session/append_v2" \
    -H "Authorization: Bearer $TOKEN" "${SELECT[@]}" \
    -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"$sid\",\"offset\":$offset},\"close\":false}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$tmp" >/dev/null || { echo "append failed at offset $offset" >&2; exit 1; }
  offset=$((offset+n)); i=$((i+1))
  printf '\r  uploaded %s / %s bytes' "$offset" "$SIZE" >&2
done
echo >&2

curl -sf -X POST "$C/files/upload_session/finish" \
  -H "Authorization: Bearer $TOKEN" "${SELECT[@]}" \
  -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"$sid\",\"offset\":$SIZE},\"commit\":{\"path\":\"$DEST\",\"mode\":\"add\",\"autorename\":true,\"mute\":false}}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/dev/null | grep -o '"path_display": *"[^"]*"' | sed 's/.*"\(.*\)"$/\1/'
'@

$ext = if ($mode -eq 'git') { 'zip' } else { 'tar.gz' }
$compress = if ($mode -eq 'git') { $compressGit } else { $compressFull }

# Set up Dropbox env once for the whole batch.
$prevWslEnv = $env:WSLENV
if ($UploadTarget -eq 'dropbox') {
    $env:DROPBOX_TOKEN  = $DropboxToken
    $env:DROPBOX_MEMBER = $DropboxMemberId
    $env:WSLENV = (@($prevWslEnv, "DROPBOX_TOKEN/u", "DROPBOX_MEMBER/u") | Where-Object { $_ }) -join ':'
}

$summary = @()
try {
    foreach ($folder in $selected) {
        Write-Host ""
        Write-Host "==== $folder ====" -ForegroundColor Cyan
        $archive = "/tmp/$folder.$ext"
        $name    = "$folder.$ext"

        Write-Host ">> Compressing (mode: $mode)..." -ForegroundColor DarkCyan
        $size = Invoke-WslScript -Script $compress -WslArgs @($Packages, $archive, $folder)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  compression failed -> skipped" -ForegroundColor Red
            if ($mode -eq 'git') { Write-Host "  tip: try 'full' mode for non-git folders." -ForegroundColor Yellow }
            $summary += [pscustomobject]@{ Folder = $folder; Result = "compress failed"; Ok = $false }
            continue
        }
        Write-Host ("  size: " + ($size -join "")) -ForegroundColor DarkGray

        if ($UploadTarget -eq 'dropbox') {
            $dest = "$DropboxDestDir/$name"
            Write-Host ">> Uploading $name to Dropbox..." -ForegroundColor DarkCyan
            $result = Invoke-WslScript -Script $dropboxUpload -WslArgs @($archive, $dest)
        } else {
            Write-Host ">> Uploading $name to $BashUploadUrl..." -ForegroundColor DarkCyan
            $result = Invoke-WslScript -Script @'
set -e
curl -s --upload-file "$1" "$2/$3"
'@ -WslArgs @($archive, $BashUploadUrl, $name)
        }
        $clean = ($result | Where-Object { $_ }) -join ""
        if ($LASTEXITCODE -eq 0 -and $clean) {
            Write-Host ("  OK -> " + $clean) -ForegroundColor Green
            $summary += [pscustomobject]@{ Folder = $folder; Result = $clean; Ok = $true }
        } else {
            Write-Host "  upload failed" -ForegroundColor Red
            $summary += [pscustomobject]@{ Folder = $folder; Result = "upload failed"; Ok = $false }
        }
        Invoke-WslScript -Script 'rm -f "$1"' -WslArgs @($archive) | Out-Null
    }
} finally {
    if ($UploadTarget -eq 'dropbox') {
        Remove-Item Env:\DROPBOX_TOKEN  -ErrorAction SilentlyContinue
        Remove-Item Env:\DROPBOX_MEMBER -ErrorAction SilentlyContinue
        if ($null -ne $prevWslEnv) { $env:WSLENV = $prevWslEnv }
        else { Remove-Item Env:\WSLENV -ErrorAction SilentlyContinue }
    }
}

# ---------- Summary ----------
Write-Host ""
Write-Host "================ DONE ================" -ForegroundColor Green
foreach ($s in $summary) {
    $c = if ($s.Ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-34} {1}" -f $s.Folder, $s.Result) -ForegroundColor $c
}
Write-Host "=====================================" -ForegroundColor Green
