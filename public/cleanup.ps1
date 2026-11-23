# win-clean - safe disk cleanup + disk usage report (Windows 10/11, Windows PowerShell 5.1)
# Run:  irm https://script-zip.vercel.app | iex
#
# Deletes ONLY data that Windows or the app recreates by itself: temp files, caches,
# crash dumps, the Windows Update download cache. Nothing is deleted until you type "y".
# NEVER touched (only reported, with the command to reclaim it if you decide to):
#   Documents/Desktop/Downloads, OneDrive, Windows.old, restore points / shadow copies,
#   pagefile/hiberfil, C:\Windows\Installer, WinSxS (only via Microsoft's DISM), WSL/Docker disks.
# Junctions/symlinks are never followed or deleted through. A transcript is saved to your Desktop.

& {
$ErrorActionPreference = 'Stop'

# --- CONFIG ---------------------------------------------------
$SelfUrl   = 'https://script-zip.vercel.app'   # used to relaunch as administrator
$TempDays  = 7     # temp/cache files must be untouched this many days (same rule as Disk Cleanup)
$DumpDays  = 7     # crash dumps / error reports
$MinGB     = 1     # report: hide folders smaller than this
$ScanDepth = 5     # report: folder depth to total up (C:\Users\me\AppData\Local = 4)
$NoTouch   = @('.net', 'Content.Outlook', 'Temp?_*')   # folders never cleaned (app extractions, Outlook/zip edits)
# --------------------------------------------------------------

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "PowerShell runs in $($ExecutionContext.SessionState.LanguageMode) mode here (company policy). This script needs FullLanguage." -ForegroundColor Red
    return
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Asking for administrator rights (UAC)...' -ForegroundColor Yellow
    if ($PSCommandPath) { $relaunch = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") }
    else                { $relaunch = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', "irm $SelfUrl | iex") }
    try { Start-Process powershell -Verb RunAs -ArgumentList $relaunch -ErrorAction Stop; return }
    catch { Write-Host 'Continuing WITHOUT admin: only your own files are cleaned and the report is partial.' -ForegroundColor Yellow }
}
try { $host.UI.RawUI.WindowTitle = 'win-clean' } catch {}

$Drive = $env:SystemDrive      # "C:"
$W     = $env:SystemRoot       # "C:\Windows"
$PD    = $env:ProgramData
$desk  = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $env:USERPROFILE }
$log   = [IO.Path]::Combine($desk, ('disk-report-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmm')))
try { Start-Transcript -Path $log | Out-Null } catch { $log = $null }

# ---------- helpers ----------
function Fmt([double]$b) {
    $s = if ($b -lt 0) { '-' } else { '' }; $b = [math]::Abs($b)
    if ($b -ge 1GB) { '{0}{1:N1} GB' -f $s, ($b / 1GB) } elseif ($b -ge 1MB) { '{0}{1:N0} MB' -f $s, ($b / 1MB) } else { '{0}{1:N0} KB' -f $s, ($b / 1KB) }
}
function Write-Header([string]$t) { Write-Host "`n  === $t ===" -ForegroundColor Cyan }
function Get-Free { (New-Object IO.DriveInfo $Drive).TotalFreeSpace }
function Test-Reparse([IO.FileSystemInfo]$i) { [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint) }
function Test-RebootPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

# Age = newest of write/creation time (extracted installers keep OLD write times but are new).
function Get-Age([IO.FileSystemInfo]$i) {
    $t = $i.LastWriteTime; if ($i.CreationTime -gt $t) { $t = $i.CreationTime }; $t
}

# Junction/symlink? Unknown reparse types count as links (= skipped).
function Test-Link([IO.FileSystemInfo]$i) {
    if (-not (Test-Reparse $i)) { return $false }
    try { return [bool](Get-Item -LiteralPath $i.FullName -Force).LinkType } catch { return $true }
}

# Cleanup root must exist on the system drive, be at least C:\X\Y deep (a single named file may
# live one level up: C:\Windows\MEMORY.DMP), and NO folder in its path may be a link/redirect.
function Test-SafeRoot([string]$p, [int]$minParts) {
    try { $d = New-Object IO.DirectoryInfo $p } catch { return $false }
    if (-not $d.Exists) { return $false }
    if ($d.FullName.TrimEnd('\').Split('\').Count -lt $minParts) { return $false }
    if (-not $d.FullName.StartsWith("$Drive\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    for ($x = $d; $x.Parent; $x = $x.Parent) { if (Test-Reparse $x) { return $false } }
    $true
}

# Right before deleting: every folder between the file and the cleanup root is still a real folder
# (defeats a folder being swapped for a junction after the plan was measured).
function Test-Chain([string]$dir, [string]$root) {
    $x = New-Object IO.DirectoryInfo $dir
    while ($x -and $x.FullName.TrimEnd('\').Length -gt $root.Length) {
        if (-not $x.Exists -or (Test-Reparse $x)) { return $false }
        $x = $x.Parent
    }
    $true
}

function Test-NoTouch([string]$name) { foreach ($n in $NoTouch) { if ($name -like $n) { return $true } }; $false }

# Collect deletable files under one entry @{P=path; Pat='*'; Rec=$true}. Never descends into
# or returns reparse points or $NoTouch folders. Dirs come parent-first (reversed to prune).
function Get-Junk($e, [int]$days) {
    $pat = if ($e.Pat) { $e.Pat } else { '*' }
    $rec = $e.Rec -ne $false
    $min = if (-not $rec -and $pat -notmatch '[*?]') { 2 } else { 3 }
    $r = @{ Root = $null; Min = $min
            Files = New-Object System.Collections.Generic.List[IO.FileInfo]
            Dirs  = New-Object System.Collections.Generic.List[IO.DirectoryInfo] }
    if (-not (Test-SafeRoot $e.P $min)) { return $r }
    $r.Root = (New-Object IO.DirectoryInfo $e.P).FullName.TrimEnd('\')
    $cut = (Get-Date).AddDays(-$days)
    $stack = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $stack.Push((New-Object IO.DirectoryInfo $r.Root))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $kids = $d.GetFileSystemInfos() } catch { continue }
        foreach ($k in $kids) {
            if (Test-Reparse $k) { continue }
            if ($k -is [IO.DirectoryInfo]) {
                if ($rec -and -not (Test-NoTouch $k.Name)) { $stack.Push($k); if ((Get-Age $k) -lt $cut) { $r.Dirs.Add($k) } }
            } elseif ($k.Name -like $pat -and (Get-Age $k) -lt $cut) { $r.Files.Add($k) }
        }
    }
    $r
}

# Delete what Get-Junk found, re-checking path, links and age right before each delete.
function Remove-Junk($it) {
    $cut = (Get-Date).AddDays(-$it.Days); [long]$bytes = 0; $fail = 0
    foreach ($j in $it.Junk) {
        if (-not $j.Root -or -not (Test-SafeRoot $j.Root $j.Min)) { continue }
        foreach ($f in $j.Files) {
            $ro = $false
            try {
                $f.Refresh()
                if (-not $f.Exists -or (Test-Reparse $f) -or (Get-Age $f) -ge $cut) { continue }
                if (-not (Test-Chain $f.DirectoryName $j.Root)) { continue }
                $len = $f.Length; $ro = $f.IsReadOnly
                if ($ro) { $f.IsReadOnly = $false }
                $f.Delete(); $bytes += $len
            } catch {
                $fail++                                   # in use / no permission -> leave it as it was
                if ($ro) { try { $f.IsReadOnly = $true } catch {} }
            }
        }
        if ($it.Prune) {                                  # Delete() without args only removes EMPTY folders
            for ($i = $j.Dirs.Count - 1; $i -ge 0; $i--) {
                $d = $j.Dirs[$i]
                try { $d.Refresh(); if (-not (Test-Reparse $d) -and (Test-Chain $d.FullName $j.Root)) { $d.Delete() } } catch {}
            }
        }
    }
    @{ Bytes = $bytes; Failed = $fail }
}

function Get-SkipReason($it) {
    if ($it.Admin -and -not $isAdmin) { return 'needs admin' }
    if ($it.NoReboot -and (Test-RebootPending)) { return 'restart pending - reboot first' }
    if ($it.Need -and -not (Get-Command $it.Need -ErrorAction SilentlyContinue)) { return 'not available here' }
    if ($it.Proc -and (Get-Process -Name $it.Proc -ErrorAction SilentlyContinue)) { return $it.ProcMsg }
    if ($it.SameUser -and -not $sameUser) { return 'elevated as another account - empty it from Explorer' }
    $null
}

function ProfilePaths([string]$rel) { foreach ($p in $profiles) { [IO.Path]::Combine($p, $rel) } }
function BrowserCache([string]$userData) {
    foreach ($p in $profiles) {
        $ud = [IO.Path]::Combine($p, $userData)
        if (Test-Path -LiteralPath $ud) {
            Get-ChildItem -LiteralPath $ud -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { [IO.Path]::Combine($_.FullName, $c) }
            }
        }
    }
}

# Walk the whole drive once: totals per folder (up to $ScanDepth), root files, files >= 1 GB.
function Invoke-DiskScan([string]$root) {
    $sizes  = @{}
    $big    = New-Object System.Collections.Generic.List[IO.FileInfo]
    $rootF  = New-Object System.Collections.Generic.List[IO.FileInfo]
    $denied = New-Object System.Collections.Generic.List[string]
    [long]$total = 0; $n = 0
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@{ D = (New-Object IO.DirectoryInfo $root); Depth = 0; Anc = @() })
    while ($stack.Count -gt 0) {
        $e = $stack.Pop()
        try { $kids = $e.D.GetFileSystemInfos() } catch { $denied.Add($e.D.FullName); continue }
        foreach ($k in $kids) {
            if ($k -is [IO.DirectoryInfo]) {
                if (Test-Link $k) { continue }                       # don't count junction targets twice
                $depth = $e.Depth + 1
                $anc = $e.Anc; if ($depth -le $ScanDepth) { $anc = $anc + $k.FullName }
                $stack.Push(@{ D = $k; Depth = $depth; Anc = $anc })
            } else {
                if ([int]$k.Attributes -band 0x441000) { continue }  # OneDrive cloud-only: not on disk
                $len = $k.Length; $total += $len; $n++
                foreach ($a in $e.Anc) { $sizes[$a] = [long]$sizes[$a] + $len }
                if ($e.Depth -eq 0) { $rootF.Add($k) }
                if ($len -ge 1GB) { $big.Add($k) }
                if ($n % 5000 -eq 0) {
                    Write-Progress -Activity "Scanning $root" -Status ('{0:N0} files, {1} - {2}' -f $n, (Fmt $total), $e.D.FullName)
                }
            }
        }
    }
    Write-Progress -Activity "Scanning $root" -Completed
    @{ Sizes = $sizes; Big = $big; RootFiles = $rootF; Denied = $denied; Total = $total; Count = $n }
}

try {
Clear-Host
Write-Host '  win-clean  -  safe cleanup + disk report' -ForegroundColor Cyan
if (-not $isAdmin) { Write-Host '  (not admin)' -ForegroundColor Yellow }

$profiles = @()
try { $profiles = @(Get-CimInstance Win32_UserProfile -Filter 'Special = FALSE' | ForEach-Object { $_.LocalPath } | Where-Object { $_ }) } catch {}
if (-not $profiles) { $profiles = @($env:USERPROFILE) }

# Elevated with someone else's admin account? Then "this account" items would hit the wrong user.
$sameUser = $true
try { $u = (Get-CimInstance Win32_ComputerSystem).UserName; if ($u) { $sameUser = ($u -eq $me.Name) } } catch {}

$busyWU  = @('TiWorker', 'TrustedInstaller')
$busyMsg = 'Windows is installing updates - try later'

# ---------- 1) Plan ----------
$items = @(
    @{ Name = "Temp files (all users + Windows, $TempDays+ days old)"; Days = $TempDays; Prune = $true; On = $true
       Paths = @(ProfilePaths 'AppData\Local\Temp') + "$W\Temp" }
    @{ Name = "Internet cache (INetCache, $TempDays+ days old)"; Days = $TempDays; On = $true
       Paths = @(ProfilePaths 'AppData\Local\Microsoft\Windows\INetCache') }
    @{ Name = "Crash dumps & error reports ($DumpDays+ days old)"; Days = $DumpDays; Prune = $true; On = $true
       Paths = @(ProfilePaths 'AppData\Local\CrashDumps') + @(ProfilePaths 'AppData\Local\Microsoft\Windows\WER') + @(
               "$PD\Microsoft\Windows\WER\ReportArchive", "$PD\Microsoft\Windows\WER\ReportQueue", "$W\Minidump",
               @{ P = "$W\LiveKernelReports"; Pat = '*.dmp' }, @{ P = $W; Pat = 'MEMORY.DMP'; Rec = $false }) }
    @{ Name = 'Edge cache (not cookies/passwords/history)'; Days = 0; On = $true; Proc = 'msedge'
       ProcMsg = 'close Edge completely, incl. background/tray'
       Paths = @(BrowserCache 'AppData\Local\Microsoft\Edge\User Data') }
    @{ Name = 'Chrome cache (not cookies/passwords/history)'; Days = 0; On = $true; Proc = 'chrome'
       ProcMsg = 'close Chrome completely, incl. background/tray'
       Paths = @(BrowserCache 'AppData\Local\Google\Chrome\User Data') }
    @{ Name = 'Windows Update download cache'; Days = 0; Prune = $true; On = $true; Admin = $true; NoReboot = $true
       Proc = $busyWU; ProcMsg = $busyMsg; Services = @('wuauserv', 'bits')
       Paths = @("$W\SoftwareDistribution\Download") }
    @{ Name = 'Delivery Optimization cache'; Days = 0; On = $true; Admin = $true; Need = 'Delete-DeliveryOptimizationCache'
       Paths = @("$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache")
       Action = { Delete-DeliveryOptimizationCache -Force } }
    @{ Name = 'Recycle Bin (this account) - check it first!'; Days = 0; On = $false; SameUser = $true
       Paths = @("$Drive\`$Recycle.Bin\$($me.User.Value)")
       Action = { Clear-RecycleBin -DriveLetter $Drive.TrimEnd(':') -Force -ErrorAction SilentlyContinue } }
    @{ Name = 'Old Windows components (DISM, 5-20 min)'; On = $false; Admin = $true; NoReboot = $true
       Proc = $busyWU; ProcMsg = $busyMsg
       Action = {
           & "$W\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup
           if ($LASTEXITCODE -and $LASTEXITCODE -ne 3010) { throw "DISM exit code $LASTEXITCODE" }
       } }
)

Write-Host "`n  Measuring what can be cleaned (nothing is deleted yet)..." -ForegroundColor DarkGray
foreach ($it in $items) {
    $it.Skip = Get-SkipReason $it
    if ($it.Skip) { $it.On = $false }
    $it.Junk = @(); $it.Bytes = [long]0
    if ($it.Paths) {
        foreach ($p in $it.Paths) {
            if ($p -is [string]) { $p = @{ P = $p } }
            $j = Get-Junk $p $it.Days
            $it.Junk += $j
            foreach ($f in $j.Files) { $it.Bytes += $f.Length }
        }
    }
}

function Show-Plan {
    Write-Host ''
    [long]$sel = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $box   = if ($it.Skip) { '[-]' } elseif ($it.On) { '[x]' } else { '[ ]' }
        $size  = if ($it.Action -and $it.Bytes -eq 0) { '?' } else { Fmt $it.Bytes }
        $color = if ($it.Skip) { 'DarkGray' } elseif ($it.On) { 'White' } else { 'Gray' }
        $note  = if ($it.Skip) { "($($it.Skip))" } else { '' }
        Write-Host ('  {0,2}. {1} {2,-52} {3,9}  {4}' -f ($i + 1), $box, $it.Name, $size, $note) -ForegroundColor $color
        if ($it.On) { $sel += $it.Bytes }
    }
    Write-Host ('  Selected: about {0}' -f (Fmt $sel)) -ForegroundColor Green
}

while ($true) {
    Show-Plan
    try { $Host.UI.RawUI.FlushInputBuffer() } catch {}   # ignore keys pressed while measuring
    $a = (Read-Host "`n  y = clean the [x] items | numbers = toggle (e.g. 4,8) | r = report only | q = quit").Trim()
    if ($a -eq 'y') { break }
    if ($a -eq 'q') { return }
    if ($a -eq 'r') { foreach ($it in $items) { $it.On = $false }; break }
    foreach ($t in ($a -split '[,\s]+')) {
        $k = 0
        if ([int]::TryParse($t, [ref]$k) -and $k -ge 1 -and $k -le $items.Count -and -not $items[$k - 1].Skip) {
            $items[$k - 1].On = -not $items[$k - 1].On
        }
    }
}

# ---------- 2) Clean ----------
$free0 = Get-Free
$ran = $false
foreach ($it in ($items | Where-Object { $_.On })) {
    Write-Host ("  > {0} ... " -f $it.Name) -NoNewline
    $why = Get-SkipReason $it                              # things may have changed while the prompt waited
    if ($why) { Write-Host "skipped: $why" -ForegroundColor Yellow; continue }
    $ran = $true
    $stopped = @()
    try {
        foreach ($s in @($it.Services)) {
            if (-not $s) { continue }
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne 'Running') { continue }
            if (@($svc.DependentServices | Where-Object { $_.Status -eq 'Running' }).Count) { throw "service $s has running dependents" }
            $stopped += $s
            $svc.Stop(); $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        if ($it.Action) {
            $f = Get-Free; & $it.Action
            Write-Host ('~{0}' -f (Fmt ([math]::Max(0, (Get-Free) - $f)))) -ForegroundColor Green
        } else {
            $r = Remove-Junk $it
            $msg = Fmt $r.Bytes; if ($r.Failed) { $msg += "  ($($r.Failed) files in use, left alone)" }
            Write-Host $msg -ForegroundColor Green
        }
    } catch {
        Write-Host ("skipped: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    } finally {
        foreach ($s in $stopped) {
            try { Start-Service -Name $s }
            catch { Write-Host "  WARNING: service $s did not restart. Run  Start-Service $s  as admin, or reboot." -ForegroundColor Red }
        }
    }
}
if ($ran) { Write-Host ("`n  Free space gained: {0}" -f (Fmt ([math]::Max(0, (Get-Free) - $free0)))) -ForegroundColor Green }

# ---------- 3) Report ----------
Write-Host "`n  Scanning $Drive\ to see what uses the space (a few minutes)..." -ForegroundColor Cyan
$scan = Invoke-DiskScan "$Drive\"
$di = New-Object IO.DriveInfo $Drive
$used = $di.TotalSize - $di.TotalFreeSpace

Write-Header "Disk $Drive"
Write-Host ('  Size {0}   Used {1}   Free {2}   ({3:N0}% used)' -f (Fmt $di.TotalSize), (Fmt $used), (Fmt $di.TotalFreeSpace), (100 * $used / $di.TotalSize))

Write-Header 'System files and hidden space'
$desc = @{ 'pagefile.sys' = 'virtual memory, managed by Windows'; 'hiberfil.sys' = 'hibernation / Fast Startup'; 'swapfile.sys' = 'app swap file' }
foreach ($f in ($scan.RootFiles | Where-Object { $_.Length -ge 100MB } | Sort-Object Length -Descending)) {
    Write-Host ('  {0,9}  {1}  {2}' -f (Fmt $f.Length), $f.FullName, $desc[$f.Name])
}
$shadow = $null; $shadowN = $null
if ($isAdmin) {
    try {
        $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter = '$Drive'"
        $ss  = @(Get-CimInstance Win32_ShadowStorage | Where-Object { $_.DiffVolume.DeviceID -eq $vol.DeviceID })
        $shadow  = [long]($ss | Measure-Object -Property AllocatedSpace -Sum).Sum
        $shadowN = @(Get-CimInstance Win32_ShadowCopy | Where-Object { $_.VolumeName -eq $vol.DeviceID }).Count
    } catch {}
}
if ($null -ne $shadow) { Write-Host ('  {0,9}  Restore points / shadow copies ({1}) - inside System Volume Information' -f (Fmt $shadow), $shadowN) }
else { Write-Host '        ?    Restore points / shadow copies (needs admin to measure)' }
try { $rs = (Get-WindowsReservedStorageState).ReservedStorageState; Write-Host "             Reserved storage for updates: $rs (about 7 GB when Enabled, counted in files above)" } catch {}
$winOld = $scan.Sizes["$Drive\Windows.old"]
if ($winOld) { Write-Host ('  {0,9}  {1}\Windows.old - previous Windows installation' -f (Fmt $winOld), $Drive) }

Write-Header "Biggest folders (>= $MinGB GB)"
$min = [long]($MinGB * 1GB); $kids = @{}
foreach ($kv in $scan.Sizes.GetEnumerator()) {
    if ($kv.Value -lt $min) { continue }
    $parent = [IO.Path]::GetDirectoryName($kv.Key)
    if (-not $kids.ContainsKey($parent)) { $kids[$parent] = New-Object System.Collections.Generic.List[object] }
    $kids[$parent].Add($kv)
}
function Show-Tree([string]$parent, [string]$indent) {
    if (-not $kids.ContainsKey($parent)) { return }
    foreach ($kv in ($kids[$parent] | Sort-Object Value -Descending)) {
        Write-Host ('  {0,9}  {1}{2}' -f (Fmt $kv.Value), $indent, $kv.Key)
        Show-Tree $kv.Key ($indent + '   ')
    }
}
Show-Tree "$Drive\" ''

Write-Header 'Biggest files (>= 1 GB)'
foreach ($f in ($scan.Big | Sort-Object Length -Descending | Select-Object -First 25)) {
    Write-Host ('  {0,9}  {1}' -f (Fmt $f.Length), $f.FullName)
}

Write-Header 'Where the used space is'
$gap = $used - $scan.Total - [long]$shadow
Write-Host ('  {0,9}  readable files ({1:N0})' -f (Fmt $scan.Total), $scan.Count)
Write-Host ('  {0,9}  restore points / shadow copies{1}' -f (Fmt ([long]$shadow)), $(if ($null -eq $shadow) { ' (not measured)' } else { '' }))
Write-Host ('  {0,9}  the rest: {1} folders it could not open, NTFS metadata, protected system data' -f (Fmt $gap), $scan.Denied.Count)
Write-Host ('  {0,9}  = used on {1}' -f (Fmt $used), $Drive)
$scan.Denied | Select-Object -First 8 | ForEach-Object { Write-Host "             cannot open: $_" -ForegroundColor DarkGray }
Write-Host '  Sizes are logical sizes: hard links (WinSxS/System32, pnpm) are counted twice and compressed' -ForegroundColor DarkGray
Write-Host '  or sparse files look bigger than on disk. A negative "rest" means that overcount is larger.' -ForegroundColor DarkGray

Write-Header 'Reclaim more (NOT done by this script - your call / check with IT)'
$tips = 0
foreach ($v in ($scan.Big | Where-Object { $_.Extension -in '.vhdx', '.vhd', '.avhdx' })) {
    $tips++
    Write-Host ('  * Virtual disk {0}  {1}' -f (Fmt $v.Length), $v.FullName) -ForegroundColor Yellow
    if ($v.Name -eq 'ext4.vhdx') {
        Write-Host '    WSL disk: it grows but NEVER shrinks when you delete files inside Linux. To give space back:'
        Write-Host '      1) inside Linux delete what you do not need, then run:  sudo fstrim -av'
        Write-Host '      2) in PowerShell:  wsl --shutdown'
        Write-Host '      3) as admin:  diskpart  ->  select vdisk file="<path above>"  ->  attach vdisk readonly'
        Write-Host '                    ->  compact vdisk  ->  detach vdisk  ->  exit'
    } elseif ($v.FullName -match 'docker') {
        Write-Host '    Docker disk: run  docker system prune  (and  docker builder prune)  then compact it the same way as WSL.'
    }
}
$hib = $scan.RootFiles | Where-Object { $_.Name -eq 'hiberfil.sys' }
if ($hib -and $hib.Length -ge 2GB) {
    $tips++
    Write-Host ('  * hiberfil.sys {0}:  powercfg /h /type reduced  (keeps Fast Startup, smaller)  or  powercfg /h off  (no hibernation)' -f (Fmt $hib.Length)) -ForegroundColor Yellow
}
if ($shadow -ge 3GB) {
    $tips++
    Write-Host ('  * Restore points use {0}:  vssadmin list shadowstorage   then e.g.  vssadmin resize shadowstorage /for={1} /on={1} /maxsize=5%' -f (Fmt $shadow), $Drive) -ForegroundColor Yellow
    Write-Host '    (deletes the OLDEST restore points; a company backup agent may rely on them - ask IT)'
}
if ($winOld) {
    $tips++
    Write-Host '  * Windows.old: Settings > System > Storage > Temporary files > "Previous Windows installation(s)" (removes the rollback option)' -ForegroundColor Yellow
}
if (-not $tips) { Write-Host '  Nothing big outside normal files. Check the folder list above (Downloads, other user profiles, apps).' }

Write-Header 'Why Explorer and Settings disagree'
Write-Host '  Explorer shows the real free space. The Settings > Storage categories only add up what they'
Write-Host '  recognize, so they miss restore points, WSL/Docker virtual disks, other users'' profiles,'
Write-Host '  hiberfil/pagefile and folders Windows cannot read. "Where the used space is" adds it all up.'
} finally {
    if ($log) { try { Stop-Transcript | Out-Null; Write-Host "`n  Report saved to: $log" -ForegroundColor Green } catch {} }
}
}
