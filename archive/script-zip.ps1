# script-zip - run on Windows PowerShell:  irm https://script-zip.vercel.app | iex
#   1) compress & move folders   2) sync git bundles (meta repos)
# Heavy work runs in WSL; destination is Windows Downloads or Dropbox.

$ErrorActionPreference = "Stop"

# --- CONFIG ---------------------------------------------------
$SelfUrl         = "https://script-zip.vercel.app"   # used to relaunch in its own window
$Distro          = "polaris"
$Packages        = "/home/developer/projects/life2lifeJun26"                          # job 1: folders live here
$MetaRepo        = "/home/developer/projects/life2lifeJun26/health-gbp-main-master"   # job 2: meta repo root
$DropboxDestDir  = "/script-zip"                     # folder inside your Dropbox
$DropboxMemberId = ""                                # Business/team: dbmid:... (auto-detected if blank)
# --------------------------------------------------------------

# Relaunch in a dedicated window; fall back to the current one if blocked.
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

# Run a bash script inside WSL with positional args (base64 so nothing gets mangled).
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

# ---------- 1) Job ----------
Write-Host "`n  What do you want to do?" -ForegroundColor Cyan
Write-Host "    1. Compress & move folders"
Write-Host "    2. Sync git bundles (meta repos) -> laptop"
do { $j = Read-Host "  Pick 1 or 2" } while ($j -notin '1', '2')
$job = if ($j -eq '2') { 'sync' } else { 'compress' }

# ---------- 2) Destination (shared by both jobs) ----------
Write-Host "`n  Destination:" -ForegroundColor Cyan
Write-Host "    1. Local  - save to your Windows Downloads folder"
Write-Host "    2. Upload - upload to Dropbox"
do { $d = Read-Host "  Pick 1 or 2" } while ($d -notin '1', '2')
$destination = if ($d -eq '2') { 'upload' } else { 'local' }

# If Upload -> ask for the Dropbox token (masked)
$DropboxToken = $null
if ($destination -eq 'upload') {
    $sec = Read-Host "  Paste your Dropbox access token" -AsSecureString
    $DropboxToken = [System.Net.NetworkCredential]::new('', $sec).Password
    if (-not $DropboxToken) { Write-Host "No token entered. Aborted." -ForegroundColor Red; return }
}

# Windows Downloads: local target, and where l2l-have.txt is read for incremental sync.
try {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop
    $winDownloads = [Environment]::ExpandEnvironmentVariables($reg.'{374DE290-123F-4565-9164-39C4925E467B}')
} catch { $winDownloads = Join-Path $env:USERPROFILE 'Downloads' }
if (-not (Test-Path -LiteralPath $winDownloads)) { New-Item -ItemType Directory -Path $winDownloads -Force | Out-Null }

# Bash blocks. Compressor: $1=pkgDir $2=out $3=folder $4=chunkMB; echoes part basenames.
$compressGit = @'
set -e
set -o pipefail
PKG="$1"; OUT="$2"; F="$3"; CHUNK="$4"
REPO=$(git -C "$PKG/$F" rev-parse --show-toplevel 2>/dev/null) || {
  echo "ERROR: '$F' is not inside a git repository. Use 'full' mode for non-git folders." >&2; exit 1; }
d="$PKG/$F"
if [ "$d" = "$REPO" ]; then REL="."; else REL="${d#$REPO/}"; fi
rm -f "$OUT" "$OUT".* 2>/dev/null || true
if [ "$CHUNK" -gt 0 ]; then
  git -C "$REPO" archive --format=zip HEAD "$REL" | split -b "${CHUNK}M" -d -a 4 - "$OUT."
  for p in "$OUT".*; do basename "$p"; done
else
  git -C "$REPO" archive --format=zip -o "$OUT" HEAD "$REL"
  basename "$OUT"
fi
'@
$compressFull = @'
set -e
set -o pipefail
PKG="$1"; OUT="$2"; F="$3"; CHUNK="$4"
rm -f "$OUT" "$OUT".* 2>/dev/null || true
if command -v pigz >/dev/null 2>&1; then GZ=(pigz); else GZ=(gzip); fi
if [ "$CHUNK" -gt 0 ]; then
  tar -c -C "$PKG" "$F" | "${GZ[@]}" | split -b "${CHUNK}M" -d -a 4 - "$OUT."
  for p in "$OUT".*; do basename "$p"; done
else
  tar -c -C "$PKG" "$F" | "${GZ[@]}" > "$OUT"
  basename "$OUT"
fi
'@
$compressNode = @'
set -e
set -o pipefail
PKG="$1"; OUT="$2"; F="$3"; CHUNK="$4"
cd "$PKG"
DIRS=()
while IFS= read -r -d '' dir; do DIRS+=("$dir"); done \
  < <(find "$F" -type d -name node_modules -prune -print0)
[ ${#DIRS[@]} -gt 0 ] || { echo "ERROR: no node_modules found under '$F'." >&2; exit 1; }
rm -f "$OUT" "$OUT".* 2>/dev/null || true
if command -v pigz >/dev/null 2>&1; then GZ=(pigz); else GZ=(gzip); fi
if [ "$CHUNK" -gt 0 ]; then
  tar -c "${DIRS[@]}" | "${GZ[@]}" | split -b "${CHUNK}M" -d -a 4 - "$OUT."
  for p in "$OUT".*; do basename "$p"; done
else
  tar -c "${DIRS[@]}" | "${GZ[@]}" > "$OUT"
  basename "$OUT"
fi
'@

# Bundle one repo: $1=metaRepo $2=out $3=rel $4=baseSha $5=full.
# Echoes basename on success; exit 0 + no output = no changes.
$bundleGen = @'
set -e
set -o pipefail
META="$1"; OUT="$2"; REL="$3"; BASE="$4"; FULL="$5"
cd "$META/$REL"
git fetch --all --prune --quiet 2>/dev/null || git fetch --prune --quiet
up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
[ -n "$up" ] || up=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || true)
if [ -z "$up" ]; then echo "ERROR: no remote branch for $REL" >&2; exit 1; fi
tip=$(git rev-parse --verify --quiet "$up^{commit}") || { echo "ERROR: cannot resolve $up" >&2; exit 1; }
rm -f "$OUT" 2>/dev/null || true
if [ -z "$FULL" ] && [ -n "$BASE" ] && git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  if [ "$BASE" = "$tip" ]; then exit 0; fi          # nothing new -> no part
  git bundle create "$OUT" "^$BASE" "$up" >/dev/null
else
  git bundle create "$OUT" --all >/dev/null
fi
basename "$OUT"
'@

# Dropbox upload ($1=archive  $2=dest path); token/member via WSLENV.
$dropboxUpload = @'
set -e
ARCHIVE="$1"; DEST="$2"
TOKEN="$DROPBOX_TOKEN"
[ -n "$TOKEN" ] || { echo "ERROR: no Dropbox token in environment" >&2; exit 1; }
API="https://api.dropboxapi.com/2"
C="https://content.dropboxapi.com/2"

SELECT=()
mid="$DROPBOX_MEMBER"
if [ -z "$mid" ]; then
  admin=$(curl -s -X POST "$API/team/token/get_authenticated_admin" -H "Authorization: Bearer $TOKEN" 2>/dev/null)
  mid=$(printf '%s' "$admin" | grep -o '"team_member_id": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"$/\1/')
fi
if [ -n "$mid" ]; then
  SELECT=(-H "Dropbox-API-Select-User: $mid")
  echo "  (team account -> acting as $mid)" >&2
else
  echo "  (no team member id; using token as a single account)" >&2
fi

SIZE=$(stat -c%s "$ARCHIVE")
CHUNK_MB=140
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

resp=$(curl -s -X POST "$C/files/upload_session/start" \
  -H "Authorization: Bearer $TOKEN" "${SELECT[@]}" \
  -H 'Dropbox-API-Arg: {"close":false}' \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/dev/null)
sid=$(printf '%s' "$resp" | grep -o '"session_id": *"[^"]*"' | sed 's/.*"\(.*\)"$/\1/')
if [ -z "$sid" ]; then
  echo "start failed: $resp" >&2
  case "$resp" in
    *Business*team*) echo "  HINT: team token but no member id was applied. Set \$DropboxMemberId (your dbmid:...) in the config, or grant the app a team scope so auto-detect works." >&2 ;;
  esac
  exit 1
fi

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

# Local copy: $1=archive $2=Windows dest dir (binary-safe via wslpath).
$localCopy = @'
set -e
ARCHIVE="$1"; WINDEST="$2"
DEST=$(wslpath -u "$WINDEST" 2>/dev/null) || { echo "ERROR: cannot map Windows path: $WINDEST" >&2; exit 1; }
mkdir -p "$DEST"
cp "$ARCHIVE" "$DEST/"
'@

$workItems = @()
if ($job -eq 'compress') {
    Write-Host "`n>> Listing folders in $Packages ..." -ForegroundColor Cyan
    $folders = @((Invoke-WslScript -Script @'
find "$1" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort
'@ -WslArgs @($Packages)) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $folders) { Write-Host "No folders found in $Packages" -ForegroundColor Red; return }

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

    Write-Host "`n  Compression mode:" -ForegroundColor Cyan
    Write-Host "    1. git          - git-tracked files only (no node_modules, clean)"
    Write-Host "    2. full         - EVERYTHING, includes node_modules"
    Write-Host "    3. node_modules - ONLY the node_modules folders"
    do { $m = Read-Host "  Pick 1, 2 or 3" } while ($m -notin '1', '2', '3')
    $mode = switch ($m) { '2' { 'full' } '3' { 'node_modules' } default { 'git' } }

    Write-Host "`n  Archive size:" -ForegroundColor Cyan
    Write-Host "    1. Complete - a single archive per folder"
    Write-Host "    2. Chunked  - split into fixed-size parts"
    do { $z = Read-Host "  Pick 1 or 2" } while ($z -notin '1', '2')
    $chunkMb = 0
    if ($z -eq '2') {
        do {
            $cs = Read-Host "  Chunk size in MB (Enter = 1900)"
            if (-not $cs) { $cs = '1900' }
        } while (-not ($cs -as [int]) -or [int]$cs -le 0)
        $chunkMb = [int]$cs
        Write-Host "  Note: chunking only makes files individually movable; peak /tmp use is still ~ full archive size." -ForegroundColor DarkGray
    }

    $ext      = if ($mode -eq 'git') { 'zip' } else { 'tar.gz' }
    $compress = switch ($mode) { 'full' { $compressFull } 'node_modules' { $compressNode } default { $compressGit } }
    $workItems = $selected
}
else {
    Write-Host "`n>> Discovering repos under $MetaRepo ..." -ForegroundColor Cyan
    $repoRels = @((Invoke-WslScript -Script @'
cd "$1" 2>/dev/null || exit 1
[ -d ".git" ] && echo .
for d in packages/*/; do [ -d "${d}.git" ] && echo "${d%/}"; done
'@ -WslArgs @($MetaRepo)) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $repoRels) { Write-Host "No git repos under $MetaRepo" -ForegroundColor Red; return }
    Write-Host (">> Found " + $repoRels.Count + " repos") -ForegroundColor Green

    $haveMap = @{}
    $haveFile = Join-Path $winDownloads 'l2l-have.txt'
    if (Test-Path -LiteralPath $haveFile) {
        Get-Content -LiteralPath $haveFile | ForEach-Object {
            $p = (($_ -replace '\s+', ' ').Trim()) -split ' '
            if ($p.Count -ge 2 -and $p[0]) { $haveMap[$p[0]] = $p[1] }
        }
        Write-Host (">> Incremental (l2l-have.txt: " + $haveMap.Count + " repos known)") -ForegroundColor DarkCyan
    } else {
        Write-Host ">> Full bundles (no l2l-have.txt in Downloads)" -ForegroundColor Yellow
    }
    $workItems = $repoRels
}

$localTarget = if ($job -eq 'sync') { Join-Path $winDownloads 'l2l-bundles' } else { $winDownloads }
$dropDir     = if ($job -eq 'sync') { "$DropboxDestDir/l2l-bundles" } else { $DropboxDestDir }
if ($destination -eq 'local') { Write-Host ">> Local target: $localTarget" -ForegroundColor DarkGray }

$prevWslEnv = $env:WSLENV
if ($destination -eq 'upload') {
    $env:DROPBOX_TOKEN  = $DropboxToken
    $env:DROPBOX_MEMBER = $DropboxMemberId
    $env:WSLENV = (@($prevWslEnv, "DROPBOX_TOKEN/u", "DROPBOX_MEMBER/u") | Where-Object { $_ }) -join ':'
}

$summary = @()
try {
    foreach ($item in $workItems) {
        if ($job -eq 'compress') {
            $name      = $item
            $out       = "/tmp/$name.$ext"
            $sizeLabel = if ($chunkMb -gt 0) { "chunked ${chunkMb}MB" } else { "complete" }
            $label     = "compress (mode: $mode, $sizeLabel)"
        } else {
            $rel   = $item
            $name  = if ($rel -eq '.') { '_root' } else { ($rel -split '/')[-1] }
            $out   = "/tmp/$name.bundle"
            $base  = if ($haveMap.ContainsKey($name)) { $haveMap[$name] } else { "" }
            $label = if ($base) { "bundle (incremental)" } else { "bundle (full)" }
        }

        Write-Host ""
        Write-Host "==== $name ====" -ForegroundColor Cyan
        Write-Host ">> Building $label ..." -ForegroundColor DarkCyan

        if ($job -eq 'compress') {
            $parts = @(Invoke-WslScript -Script $compress -WslArgs @($Packages, $out, $name, "$chunkMb") |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            $parts = @(Invoke-WslScript -Script $bundleGen -WslArgs @($MetaRepo, $out, $rel, $base, "") |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $code = $LASTEXITCODE

        if ($code -ne 0) {
            Write-Host "  build failed -> skipped" -ForegroundColor Red
            if ($job -eq 'compress' -and $mode -eq 'git') { Write-Host "  tip: try 'full' mode for non-git folders." -ForegroundColor Yellow }
            $summary += [pscustomobject]@{ Name = $name; Result = "build failed"; Ok = $false }
            continue
        }
        if (-not $parts) {
            if ($job -eq 'sync') {
                Write-Host "  no changes" -ForegroundColor DarkGray
                $summary += [pscustomobject]@{ Name = $name; Result = "sin cambios"; Ok = $true }
            } else {
                Write-Host "  produced nothing -> skipped" -ForegroundColor Red
                $summary += [pscustomobject]@{ Name = $name; Result = "build failed"; Ok = $false }
            }
            continue
        }
        Write-Host ("  produced " + $parts.Count + " part(s)") -ForegroundColor DarkGray

        $allOk    = $true
        $lastDest = ""
        foreach ($part in $parts) {
            $archive = "/tmp/$part"
            if ($destination -eq 'upload') {
                Write-Host ">> Uploading $part to Dropbox..." -ForegroundColor DarkCyan
                $result = Invoke-WslScript -Script $dropboxUpload -WslArgs @($archive, "$dropDir/$part")
                $clean = ($result | Where-Object { $_ }) -join ""
                if ($LASTEXITCODE -eq 0 -and $clean) {
                    Write-Host ("  OK -> " + $clean) -ForegroundColor Green
                    $lastDest = $clean
                } else {
                    Write-Host "  upload failed: $part" -ForegroundColor Red
                    $allOk = $false
                }
            } else {
                Write-Host ">> Saving $part to $localTarget ..." -ForegroundColor DarkCyan
                $null = Invoke-WslScript -Script $localCopy -WslArgs @($archive, $localTarget)
                if ($LASTEXITCODE -eq 0) {
                    $lastDest = Join-Path $localTarget $part
                    Write-Host ("  OK -> " + $lastDest) -ForegroundColor Green
                } else {
                    Write-Host "  save failed: $part" -ForegroundColor Red
                    $allOk = $false
                }
            }
        }

        Invoke-WslScript -Script 'rm -f "$1" "$1".*' -WslArgs @($out) | Out-Null

        if ($job -eq 'compress' -and $chunkMb -gt 0) {
            $reassemble = if ($ext -eq 'zip') { "cat $name.zip.* > $name.zip" }
                          else { "cat $name.tar.gz.* | tar xzf -" }
            Write-Host ("  reassemble (in WSL/Linux): " + $reassemble) -ForegroundColor DarkGray
            $res = if ($allOk) { "$($parts.Count) parts -> $name.$ext.*" } else { "partial/failed" }
        } else {
            $res = if ($allOk) { $lastDest } else { "failed" }
        }
        $summary += [pscustomobject]@{ Name = $name; Result = $res; Ok = $allOk }
    }
} finally {
    if ($destination -eq 'upload') {
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
    Write-Host ("  {0,-34} {1}" -f $s.Name, $s.Result) -ForegroundColor $c
}
Write-Host "=====================================" -ForegroundColor Green
if ($job -eq 'sync') {
    if ($destination -eq 'local') {
        Write-Host "Bundles in: $localTarget" -ForegroundColor Cyan
        Write-Host "Move that folder to the laptop and run laptop-import.sh." -ForegroundColor Cyan
        Write-Host "No trace in WSL (/tmp cleaned). Delete the Downloads copy after moving." -ForegroundColor DarkGray
    } else {
        Write-Host "Bundles uploaded to Dropbox: $dropDir" -ForegroundColor Cyan
        Write-Host "Download that folder on the laptop and run laptop-import.sh." -ForegroundColor Cyan
        Write-Host "No trace on the VDI: nothing kept locally, /tmp cleaned." -ForegroundColor DarkGray
    }
}
