# Installs or updates Raid Loot Controller for WoW: Forever.
# Windows PowerShell 5.1 or later, no modules. Re-run it to update.
# The release's Install-RaidLootController.bat carries this whole file,
# so players download one file and double-click it.
#
# -WowPath  a WoW folder (the root or the Forever folder); skips the search.
# -ZipPath  a local zip instead of the download (for testing).
# -NoPause  do not wait for Enter at the end.
param(
    [string]$WowPath,
    [string]$ZipPath,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads crawl on 5.1
$Url = 'https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip'
$Addon = 'RaidLootController'

function Say([string]$text) { Write-Host $text }

function Finish([int]$code) {
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit $code
}

# A game folder is one with the game's exe in it (Wow.exe, WowB.exe, WowT.exe...).
function Test-GameDir([string]$dir) {
    [bool](Get-ChildItem -LiteralPath $dir -Filter 'Wow*.exe' -File -ErrorAction SilentlyContinue)
}

# Rank a flavor folder: 1 = Forever for sure, 2 = beta name only, 0 = not Forever.
# .flavor.info names the product ("wowf" is Forever); when present it wins.
function Get-ForeverRank([string]$dir) {
    $info = Join-Path $dir '.flavor.info'
    if (Test-Path -LiteralPath $info) {
        if ((Get-Content -LiteralPath $info -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }) -contains 'wowf') { return 1 }
        return 0
    }
    switch ((Split-Path $dir -Leaf).ToLowerInvariant()) {
        '_forever_' { return 1 }
        '_classic_beta_' { return 2 }
    }
    return 0
}

# Every Forever folder under one WoW root (or the folder itself if it is one).
function Find-Flavors([string]$dir) {
    $found = @()
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $found }
    $dir = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\', '/')
    $dirs = @($dir) + @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '_*_' } | ForEach-Object { $_.FullName })
    foreach ($d in $dirs) {
        $rank = Get-ForeverRank $d
        if ($rank -gt 0 -and (Test-GameDir $d)) {
            $found += New-Object PSObject -Property @{ Path = $d; Rank = $rank }
        }
    }
    return $found
}

function Get-RootGuesses {
    $roots = @()
    $keys = 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
    'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft'
    foreach ($k in $keys) {
        $p = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).InstallPath
        if ($p) { $roots += $p; $roots += (Split-Path $p.TrimEnd('\') -Parent) }
    }
    $uninstall = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($k in $uninstall) {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*World of Warcraft*' -and $_.InstallLocation } |
            ForEach-Object { $roots += $_.InstallLocation; $roots += (Split-Path $_.InstallLocation.TrimEnd('\') -Parent) }
    }
    if ($env:OS -eq 'Windows_NT') {
        foreach ($drive in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
            $d = $drive.RootDirectory.FullName
            foreach ($sub in 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft',
                'Games\World of Warcraft', 'World of Warcraft', 'Battle.net\World of Warcraft') {
                $roots += (Join-Path $d $sub)
            }
        }
    }
    return $roots
}

function Find-AllFlavors([string[]]$roots) {
    $seen = @{}
    $all = @()
    foreach ($r in $roots) {
        foreach ($f in Find-Flavors $r) {
            $key = $f.Path.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $all += $f }
        }
    }
    # Sure Forever folders first; drop beta-name guesses when a sure one exists.
    $sure = @($all | Where-Object { $_.Rank -eq 1 })
    if ($sure.Count) { return $sure }
    return @($all)
}

function Select-GameDir {
    if ($WowPath) {
        $c = @(Find-AllFlavors @($WowPath))
        if (-not $c.Count) { Say "No WoW: Forever game folder found in $WowPath"; Finish 1 }
    } else {
        Say 'Looking for WoW: Forever...'
        $c = @(Find-AllFlavors (Get-RootGuesses))
    }
    while (-not $c.Count) {
        Say 'Could not find WoW: Forever.'
        Say 'In Battle.net, pick WoW: Forever, click the gear, then Show in Explorer.'
        $p = (Read-Host 'Paste that folder path here (or press Enter to quit)').Trim('"', ' ')
        if (-not $p) { Finish 1 }
        $c = @(Find-AllFlavors @($p))
        if (-not $c.Count) {
            # The pasted folder may be the Forever folder of an unknown name.
            if ((Test-Path -LiteralPath $p -PathType Container) -and (Test-GameDir $p)) {
                $c = @(New-Object PSObject -Property @{ Path = (Resolve-Path -LiteralPath $p).ProviderPath; Rank = 1 })
            } else { Say 'No game found there.' }
        }
    }
    if ($c.Count -eq 1) { return $c[0].Path }
    Say 'Found more than one WoW: Forever folder:'
    for ($i = 0; $i -lt $c.Count; $i++) { Say ('  {0}. {1}' -f ($i + 1), $c[$i].Path) }
    while ($true) {
        $n = 0
        $a = Read-Host "Type a number (1-$($c.Count))"
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $c.Count) { return $c[$n - 1].Path }
    }
}

# Deletes a folder. A junction or symlink (say, a linked dev checkout) loses
# only the link: recursing into it would delete the files it points at.
function Remove-Folder([string]$p) {
    if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        [IO.Directory]::Delete($p) # not recursive: removes the link alone
        Say "Removed the link $p (the folder it pointed to is untouched)."
    } else {
        Remove-Item -LiteralPath $p -Recurse -Force
    }
}

# A run started by Start-Elevated below picks up the folder found before.
$hand = Join-Path ([IO.Path]::GetTempPath()) 'rlc-install-wowpath.txt'
if (-not $WowPath -and (Test-Path -LiteralPath $hand) -and
    (Get-Item -LiteralPath $hand).LastWriteTime -gt (Get-Date).AddMinutes(-10)) {
    $WowPath = (Get-Content -LiteralPath $hand -TotalCount 1).Trim()
}
Remove-Item -LiteralPath $hand -Force -ErrorAction SilentlyContinue

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run this installer again as administrator (one Windows "Yes" prompt).
function Start-Elevated([string]$gameDir) {
    Set-Content -LiteralPath $hand -Value $gameDir
    $self = if ($env:RLC_SELF) { $env:RLC_SELF } else { $PSCommandPath }
    # The player already said Run once: without this, Windows asks again in
    # a window that opens behind this one, and the install seems to hang.
    Unblock-File -LiteralPath $self -ErrorAction SilentlyContinue
    if ($self -like '*.ps1') {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"")
    } else {
        Start-Process -FilePath $self -Verb RunAs
    }
}

$game = Select-GameDir
$addons = Join-Path (Join-Path $game 'Interface') 'AddOns'
Say "Game folder: $game"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('rlc-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    if ($ZipPath) {
        $zip = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
    } else {
        Say 'Downloading the latest version...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $tmp 'RaidLootController.zip'
        Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
    }
    $out = Join-Path $tmp 'unzipped'
    Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
    $src = Join-Path $out $Addon
    $toc = Join-Path $src "$Addon.toc"
    if (-not (Test-Path -LiteralPath $toc)) { throw "The download is not a Raid Loot Controller zip ($Addon.toc missing)." }
    $ver = (Select-String -LiteralPath $toc -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1)
    if ($ver) { $ver = $ver.Matches[0].Groups[1].Value.Trim() }

    # Copy beside the old folder first, so a failed copy leaves the old one working.
    # AddOns itself may be a link: it is only ever written into, never deleted.
    New-Item -ItemType Directory -Path $addons -Force | Out-Null
    $dest = Join-Path $addons $Addon
    $staging = "$dest.new"
    if (Test-Path -LiteralPath $staging) { Remove-Folder $staging }
    Copy-Item -LiteralPath $src -Destination $staging -Recurse
    $updated = Test-Path -LiteralPath $dest
    if ($updated) { Remove-Folder $dest } # stale files go; WTF is never touched
    Rename-Item -LiteralPath $staging -NewName $Addon

    if ($updated) { Say "Updated Raid Loot Controller $ver." } else { Say "Installed Raid Loot Controller $ver." }
    Say "Folder: $dest"
    Say 'If the game is open, type /reload in chat. Your settings are kept.'
    $code = 0
} catch {
    $denied = $_.Exception -is [UnauthorizedAccessException] -or
        $_.Exception.InnerException -is [UnauthorizedAccessException]
    Say "Install failed: $($_.Exception.Message)"
    $code = 1
    if ($denied -and -not (Test-Admin)) {
        Say 'Windows needs permission to write to the game folder.'
        $a = Read-Host 'Press Enter to try again as administrator (or type N to quit)'
        if ($a -notmatch '^\s*n') {
            try {
                Start-Elevated $game
                Say 'Carrying on in the new window.'
                $NoPause = $true
            } catch {
                Remove-Item -LiteralPath $hand -Force -ErrorAction SilentlyContinue
                Say 'Not allowed. Right-click the installer and pick Run as administrator.'
            }
        }
    } else {
        Say 'Close the game and try again, or install the zip by hand.'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Finish $code
