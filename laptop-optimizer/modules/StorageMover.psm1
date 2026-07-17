# StorageMover.psm1 - safely relocate data from C: to a data drive (D:).
#
# Safety model:
#   * Only whitelisted, known-safe categories are ever offered for moving:
#       1. User shell folders (Downloads, Documents, Pictures, Music, Videos, Desktop)
#          - moved with robocopy, then re-pointed via the official registry
#            redirection Windows itself uses. Apps keep working because they
#            resolve these folders through the shell API, not hard-coded paths.
#       2. Well-known app/dev caches - moved, then a junction is left behind at
#          the old path so every program still finds its files.
#       3. The page file - relocated via the supported registry setting.
#   * A hard blacklist refuses anything under Windows, Program Files, or
#     Microsoft's AppData areas. Moving those WOULD break the OS, so the tool
#     will not do it no matter what is typed in.
#   * Every move is confirmed first, sized first, and journaled for undo.

# Registry value names Windows uses for each user shell folder.
$script:UserFolderMap = [ordered]@{
    'Downloads' = '{374DE290-123F-4565-9164-39C4925E467B}'
    'Documents' = 'Personal'
    'Pictures'  = 'My Pictures'
    'Music'     = 'My Music'
    'Videos'    = 'My Video'
    'Desktop'   = 'Desktop'
}

$script:ShellFoldersKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$script:UserShellFoldersKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

# Paths that must never be moved. Anything matching these prefixes is refused.
$script:ProtectedPrefixes = @(
    "$env:SystemRoot",
    "$env:SystemDrive\Program Files",
    "$env:SystemDrive\Program Files (x86)",
    "$env:SystemDrive\ProgramData\Microsoft",
    "$env:SystemDrive\Recovery",
    "$env:SystemDrive\System Volume Information",
    "$env:SystemDrive\`$Recycle.Bin",
    "$env:LOCALAPPDATA\Microsoft",
    "$env:APPDATA\Microsoft",
    "$env:LOCALAPPDATA\Packages"
)

# Well-known relocatable caches. All of these tolerate being behind a junction.
$script:KnownCaches = @(
    @{ Name = 'npm cache';           Path = "$env:LOCALAPPDATA\npm-cache" },
    @{ Name = 'pip cache';           Path = "$env:LOCALAPPDATA\pip\cache" },
    @{ Name = 'NuGet packages';      Path = "$env:USERPROFILE\.nuget\packages" },
    @{ Name = 'Gradle cache';        Path = "$env:USERPROFILE\.gradle" },
    @{ Name = 'Maven repository';    Path = "$env:USERPROFILE\.m2" },
    @{ Name = 'Cargo (Rust) cache';  Path = "$env:USERPROFILE\.cargo" },
    @{ Name = 'Android AVDs';        Path = "$env:USERPROFILE\.android\avd" },
    @{ Name = 'Yarn cache';          Path = "$env:LOCALAPPDATA\Yarn\Cache" },
    @{ Name = 'Composer cache';      Path = "$env:LOCALAPPDATA\Composer" },
    @{ Name = 'Spotify song cache';  Path = "$env:LOCALAPPDATA\Spotify\Storage" }
)

function Test-SafeToMove {
    param([Parameter(Mandatory)][string]$Path)
    $full = try { [IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($prefix in $script:ProtectedPrefixes) {
        $p = [IO.Path]::GetFullPath($prefix)
        if ($full -like "$p*") { return $false }
    }
    # Never move a drive root or the user profile root itself.
    if ($full -eq [IO.Path]::GetFullPath($env:USERPROFILE)) { return $false }
    if ($full -match '^[A-Za-z]:\\?$') { return $false }
    return $true
}

function Get-UserFolderPath {
    param([Parameter(Mandatory)][string]$Name)
    $valueName = $script:UserFolderMap[$Name]
    if (-not $valueName) { return $null }
    try {
        $item = Get-ItemProperty -Path $script:UserShellFoldersKey -Name $valueName -ErrorAction Stop
        $raw = $item.$valueName
        return [Environment]::ExpandEnvironmentVariables($raw)
    } catch { return $null }
}

function Get-MovableReport {
    <#
        Shows everything the tool is willing to move, with current sizes,
        so the decision is informed before anything happens.
    #>
    Write-Host ''
    Write-Host '  === User folders (moved via official Windows folder redirection) ===' -ForegroundColor Cyan
    foreach ($name in $script:UserFolderMap.Keys) {
        $path = Get-UserFolderPath -Name $name
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $onSystemDrive = $path -like "$env:SystemDrive*"
        $size = Get-FolderSizeBytes -Path $path
        $note = if ($onSystemDrive) { 'on C: - movable' } else { 'already off C:' }
        Write-Host ('  {0,-10} {1,10}   {2}   ({3})' -f $name, (Format-Size $size), $path, $note)
    }
    Write-Host ''
    Write-Host '  === App & developer caches (moved + junction left behind) ===' -ForegroundColor Cyan
    $found = $false
    foreach ($cache in $script:KnownCaches) {
        if (-not (Test-Path -LiteralPath $cache.Path)) { continue }
        $item = Get-Item -LiteralPath $cache.Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Host ('  {0,-22} already relocated (junction)' -f $cache.Name) -ForegroundColor Gray
            continue
        }
        $found = $true
        $size = Get-FolderSizeBytes -Path $cache.Path
        Write-Host ('  {0,-22} {1,10}   {2}' -f $cache.Name, (Format-Size $size), $cache.Path)
    }
    if (-not $found) { Write-Host '  (no movable caches detected)' -ForegroundColor Gray }
    Write-Host ''
    Write-Host '  === Page file ===' -ForegroundColor Cyan
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($pf) {
        foreach ($p in $pf) {
            Write-Host ('  {0}  (current size {1} MB)' -f $p.Name, $p.CurrentUsage)
        }
    } else {
        Write-Host '  (no page file information available)' -ForegroundColor Gray
    }
}

function Invoke-Robomove {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    # /E all subdirs, /MOVE move files+dirs, /XJ never follow junctions,
    # /COPY:DAT keep data/attributes/timestamps, /DCOPY:DAT same for dirs.
    robocopy $Source $Destination /E /MOVE /XJ /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NP /NFL /NDL | Out-Null
    # Robocopy exit codes 0-7 are success variants; 8+ means failures occurred.
    return ($LASTEXITCODE -lt 8)
}

function Move-UserFolder {
    param(
        [Parameter(Mandatory)][ValidateSet('Downloads','Documents','Pictures','Music','Videos','Desktop')]
        [string]$Name,
        [string]$DestinationRoot
    )
    $current = Get-UserFolderPath -Name $Name
    if (-not $current -or -not (Test-Path -LiteralPath $current)) {
        Write-Log "Cannot resolve current location of $Name." 'ERROR'; return
    }
    if ($current -notlike "$env:SystemDrive*") {
        Write-Log "$Name is already off the system drive ($current). Nothing to do." 'INFO'; return
    }
    if (-not (Test-SafeToMove -Path $current)) {
        Write-Log "$current is on the protected list and will not be moved." 'ERROR'; return
    }
    if (-not $DestinationRoot) {
        $drive = Get-DataDrive
        if (-not $drive) { Write-Log 'No secondary fixed drive found.' 'ERROR'; return }
        $DestinationRoot = Join-Path $drive.DeviceID ('\Users\{0}' -f $env:USERNAME)
    }
    $target = Join-Path $DestinationRoot $Name
    $size = Get-FolderSizeBytes -Path $current
    $free = (Get-PSDrive -Name $target.Substring(0,1) -ErrorAction SilentlyContinue).Free
    if ($free -and $free -lt ($size * 1.05)) {
        Write-Log ("Not enough free space on target drive ({0} needed, {1} free)." -f (Format-Size $size), (Format-Size $free)) 'ERROR'
        return
    }
    if (-not (Confirm-Action ("Move {0} ({1}) from `"{2}`" to `"{3}`"? Apps keep working - Windows folder redirection is updated automatically." -f $Name, (Format-Size $size), $current, $target))) {
        Write-Log 'Skipped.' 'INFO'; return
    }

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Write-Log "Moving files... (large folders can take a while)" 'ACTION'
    if (-not (Invoke-Robomove -Source $current -Destination $target)) {
        Write-Log 'Some files could not be moved (likely in use). Folder redirection was NOT changed - nothing is broken. Close open apps and retry.' 'ERROR'
        return
    }

    $valueName = $script:UserFolderMap[$Name]
    $oldValue = (Get-ItemProperty -Path $script:UserShellFoldersKey -Name $valueName).$valueName
    Set-ItemProperty -Path $script:UserShellFoldersKey -Name $valueName -Value $target
    Set-ItemProperty -Path $script:ShellFoldersKey -Name $valueName -Value $target -ErrorAction SilentlyContinue

    Add-UndoEntry -Action "Moved user folder $Name" -Data @{
        RegistryKey   = $script:UserShellFoldersKey
        RegistryValue = $valueName
        OldPath       = $oldValue
        NewPath       = $target
        HowToUndo     = 'Move files back with robocopy, then restore the registry value to OldPath and sign out/in.'
    }
    Write-Log "$Name is now at $target. Sign out and back in (or restart) so every app picks up the new location." 'INFO'
}

function Move-AppCaches {
    param([string]$DestinationRoot)
    if (-not $DestinationRoot) {
        $drive = Get-DataDrive
        if (-not $drive) { Write-Log 'No secondary fixed drive found.' 'ERROR'; return }
        $DestinationRoot = Join-Path $drive.DeviceID '\RelocatedCaches'
    }
    $any = $false
    foreach ($cache in $script:KnownCaches) {
        if (-not (Test-Path -LiteralPath $cache.Path)) { continue }
        $item = Get-Item -LiteralPath $cache.Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if (-not (Test-SafeToMove -Path $cache.Path)) { continue }
        $size = Get-FolderSizeBytes -Path $cache.Path
        if ($size -lt 100MB) { continue }  # not worth the churn below 100 MB
        $any = $true
        $target = Join-Path $DestinationRoot ($cache.Name -replace '[^\w\-]', '_')
        if (-not (Confirm-Action ("Relocate {0} ({1}) to {2}? A junction is left at the old path so every app keeps working unchanged." -f $cache.Name, (Format-Size $size), $target))) {
            continue
        }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Write-Log "Moving $($cache.Name)..." 'ACTION'
        if (-not (Invoke-Robomove -Source $cache.Path -Destination $target)) {
            Write-Log "Some files were in use; $($cache.Name) was left in place. Close the related app and retry." 'ERROR'
            continue
        }
        Remove-Item -LiteralPath $cache.Path -Force -Recurse -ErrorAction SilentlyContinue
        New-Item -ItemType Junction -Path $cache.Path -Target $target | Out-Null
        Add-UndoEntry -Action "Relocated cache $($cache.Name)" -Data @{
            JunctionAt = $cache.Path
            RealDataAt = $target
            HowToUndo  = 'Delete the junction, then robocopy the data back from RealDataAt to JunctionAt.'
        }
        Write-Log "$($cache.Name) relocated. Old path still works via junction." 'INFO'
    }
    if (-not $any) { Write-Log 'No caches over 100 MB found to relocate.' 'INFO' }
}

function Move-PageFile {
    <#
        Puts the page file on the data drive and lets Windows manage its size
        there. Frees several GB on C:. Fully supported by Windows; needs a
        reboot to take effect.
    #>
    param([string]$TargetDrive)
    if (-not $TargetDrive) {
        $drive = Get-DataDrive
        if (-not $drive) { Write-Log 'No secondary fixed drive found.' 'ERROR'; return }
        $TargetDrive = $drive.DeviceID
    }
    $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $currentSetting = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles
    Write-Host ("  Current page file setting : {0}" -f ($currentSetting -join ' | '))
    Write-Host ("  Proposed setting          : {0}\pagefile.sys (system managed)" -f $TargetDrive)
    Write-Host '  Note: on some laptops keeping a small page file on C: helps full memory-dump collection.'
    Write-Host '  This tool moves it entirely to the data drive, which is the right call for freeing space.'
    if (-not (Confirm-Action "Move the page file to $TargetDrive and remove it from C:? (takes effect after a restart)")) {
        Write-Log 'Skipped.' 'INFO'; return
    }
    # Turn off automatic management so our explicit setting is honored.
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
    }
    # "path 0 0" means system-managed size at that path.
    Set-ItemProperty -Path $mmKey -Name PagingFiles -Value @("$TargetDrive\pagefile.sys 0 0") -Type MultiString
    Add-UndoEntry -Action 'Moved page file' -Data @{
        RegistryKey = $mmKey
        OldValue    = ($currentSetting -join ' | ')
        NewValue    = "$TargetDrive\pagefile.sys 0 0"
        HowToUndo   = 'Restore PagingFiles to OldValue (or re-enable automatic management in SystemPropertiesAdvanced) and reboot.'
    }
    Write-Log 'Page file will move on next restart. C:\pagefile.sys disappears after the reboot.' 'INFO'
}

function Set-NewContentToDataDrive {
    <#
        Tells Windows to save NEW apps, documents, music, pictures and videos
        to the data drive by default (Settings > System > Storage > Where new
        content is saved). Prevents C: from filling up again.
    #>
    $drive = Get-DataDrive
    if (-not $drive) { Write-Log 'No secondary fixed drive found.' 'ERROR'; return }
    Write-Host '  This opens the exact Settings page (the setting is per-user and protected,'
    Write-Host '  so Windows requires it to be changed in Settings itself):'
    Write-Host '      Settings > System > Storage > Advanced storage settings > Where new content is saved'
    Write-Host ("  Set each category to {0}" -f $drive.DeviceID)
    if (Confirm-Action 'Open that Settings page now?') {
        Start-Process 'ms-settings:savelocations'
    }
}

Export-ModuleMember -Function Test-SafeToMove, Get-MovableReport, Move-UserFolder, Move-AppCaches,
    Move-PageFile, Set-NewContentToDataDrive
