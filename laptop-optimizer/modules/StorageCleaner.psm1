# StorageCleaner.psm1 - reclaim space on C: by deleting only regenerable data.
#
# Everything cleaned here is cache/temp data Windows or apps rebuild on demand.
# Personal files are never touched. Each target is sized and confirmed first.

function Get-StorageReport {
    Write-Host ''
    Write-Host '  === Drives ===' -ForegroundColor Cyan
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        $used = $_.Size - $_.FreeSpace
        $pct = if ($_.Size -gt 0) { [math]::Round($used / $_.Size * 100) } else { 0 }
        Write-Host ('  {0}  {1,10} used of {2,10}  ({3}% full, {4} free)' -f `
            $_.DeviceID, (Format-Size $used), (Format-Size $_.Size), $pct, (Format-Size $_.FreeSpace))
    }
    Write-Host ''
    Write-Host '  === Largest folders on C: (top level) ===' -ForegroundColor Cyan
    Write-Host '  Measuring... (first run can take a minute)' -ForegroundColor Gray
    $roots = Get-ChildItem -Path "$env:SystemDrive\" -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('System Volume Information', '$Recycle.Bin') }
    $sized = foreach ($r in $roots) {
        [pscustomobject]@{ Name = $r.FullName; Bytes = (Get-FolderSizeBytes -Path $r.FullName) }
    }
    $sized | Sort-Object Bytes -Descending | Select-Object -First 8 | ForEach-Object {
        Write-Host ('  {0,10}   {1}' -f (Format-Size $_.Bytes), $_.Name)
    }
    Write-Host ''
    Write-Host '  === Largest folders in your user profile ===' -ForegroundColor Cyan
    $profRoots = Get-ChildItem -Path $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue
    $profSized = foreach ($r in $profRoots) {
        [pscustomobject]@{ Name = $r.FullName; Bytes = (Get-FolderSizeBytes -Path $r.FullName) }
    }
    $profSized | Sort-Object Bytes -Descending | Select-Object -First 8 | ForEach-Object {
        Write-Host ('  {0,10}   {1}' -f (Format-Size $_.Bytes), $_.Name)
    }
}

function Get-CleanupTargets {
    # Name / Path / Description of caches that are always safe to delete.
    $targets = @(
        @{ Name = 'User temp files';            Path = $env:TEMP;
           Note = 'Temp files of your apps; rebuilt automatically.' },
        @{ Name = 'Windows temp files';         Path = "$env:SystemRoot\Temp";
           Note = 'System temp files; rebuilt automatically.' },
        @{ Name = 'Windows Update cache';       Path = "$env:SystemRoot\SoftwareDistribution\Download";
           Note = 'Already-installed update packages; Windows re-downloads if ever needed.' },
        @{ Name = 'Delivery Optimization';      Path = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache";
           Note = 'Peer-to-peer update sharing cache.' },
        @{ Name = 'Thumbnail cache';            Path = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer";
           Note = 'Explorer picture thumbnails; rebuilt as you browse folders.'; Filter = 'thumbcache_*.db' },
        @{ Name = 'Crash dumps / error reports'; Path = "$env:LOCALAPPDATA\CrashDumps";
           Note = 'Old crash diagnostics.' },
        @{ Name = 'Windows error reporting';    Path = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue";
           Note = 'Queued error reports.' },
        @{ Name = 'DirectX shader cache';       Path = "$env:LOCALAPPDATA\D3DSCache";
           Note = 'GPU shader cache; rebuilt on demand (first game launch may be slower once).' }
    )
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t.Path) {
            $t.Bytes = Get-FolderSizeBytes -Path $t.Path
        } else {
            $t.Bytes = 0
        }
    }
    return $targets
}

function Invoke-SafeCleanup {
    $targets = Get-CleanupTargets
    Write-Host ''
    Write-Host '  === Reclaimable space (only regenerable cache/temp data) ===' -ForegroundColor Cyan
    $total = 0
    foreach ($t in $targets) {
        $total += $t.Bytes
        Write-Host ('  {0,-28} {1,10}   {2}' -f $t.Name, (Format-Size $t.Bytes), $t.Note)
    }
    Write-Host ('  {0,-28} {1,10}' -f 'TOTAL', (Format-Size $total)) -ForegroundColor Green
    if (-not (Confirm-Action 'Clean all of the above? (Recycle Bin is asked about separately)')) {
        Write-Log 'Cleanup skipped.' 'INFO'; return
    }

    # Windows Update cache needs its services paused while deleting.
    $wuTarget = $targets | Where-Object { $_.Name -eq 'Windows Update cache' }
    if ($wuTarget -and $wuTarget.Bytes -gt 0) {
        Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue
    }
    foreach ($t in $targets) {
        if ($t.Bytes -eq 0) { continue }
        try {
            if ($t.Filter) {
                Get-ChildItem -LiteralPath $t.Path -Filter $t.Filter -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } else {
                Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Cleaned: $($t.Name)" 'INFO'
        } catch {
            Write-Log "Partially cleaned $($t.Name) (some files in use - normal)." 'WARN'
        }
    }
    Start-Service -Name wuauserv, bits -ErrorAction SilentlyContinue

    if (Confirm-Action 'Also empty the Recycle Bin? (permanently deletes its contents)') {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log 'Recycle Bin emptied.' 'INFO'
    }
    Write-Log 'Cleanup finished.' 'INFO'
}

function Invoke-ComponentCleanup {
    <#
        DISM component store cleanup - removes superseded Windows Update
        components. Microsoft's supported deep clean; typically frees 2-6 GB.
    #>
    Write-Host '  This runs: DISM /Online /Cleanup-Image /StartComponentCleanup'
    Write-Host '  It is Microsoft-supported, safe, and usually frees 2-6 GB, but takes 5-20 minutes.'
    if (-not (Confirm-Action 'Run Windows component store cleanup now?')) { return }
    Write-Log 'Running DISM component cleanup (please wait, this is slow)...' 'ACTION'
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Component store cleanup completed.' 'INFO'
    } else {
        Write-Log "DISM finished with exit code $LASTEXITCODE - check the output above." 'WARN'
    }
}

function Enable-StorageSense {
    <#
        Turns on Storage Sense so Windows keeps temp files and old Recycle Bin
        contents under control automatically going forward.
    #>
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    if (-not (Confirm-Action 'Enable Storage Sense (automatic ongoing cleanup of temp files + 30-day-old Recycle Bin items)?')) { return }
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name '01' -Value 1 -Type DWord   # master switch
    Set-ItemProperty -Path $key -Name '04' -Value 1 -Type DWord   # delete temp files apps aren't using
    Set-ItemProperty -Path $key -Name '08' -Value 1 -Type DWord   # recycle bin cleanup enabled
    Set-ItemProperty -Path $key -Name '256' -Value 30 -Type DWord # recycle bin: older than 30 days
    Add-UndoEntry -Action 'Enabled Storage Sense' -Data @{
        RegistryKey = $key
        HowToUndo   = 'Set value "01" to 0, or toggle it off in Settings > System > Storage.'
    }
    Write-Log 'Storage Sense enabled (temp files + 30-day Recycle Bin policy).' 'INFO'
}

function Set-HibernationReduced {
    <#
        C:\hiberfil.sys is typically 40% of RAM (e.g. 6.4 GB on a 16 GB laptop).
        "Reduced" mode keeps Fast Startup working but halves the file.
        Full hibernation ("save session and power off completely") stops working;
        Sleep and Fast Startup are unaffected.
    #>
    $hiber = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    if (-not $hiber) {
        Write-Log 'Hibernation file not present - nothing to do.' 'INFO'; return
    }
    Write-Host ('  Current hiberfil.sys size: {0}' -f (Format-Size $hiber.Length))
    Write-Host '  Reduced mode keeps Fast Startup but disables full "Hibernate" from the power menu.'
    if (-not (Confirm-Action 'Shrink the hibernation file to reduced mode?')) { return }
    & powercfg /hibernate /type reduced
    Add-UndoEntry -Action 'Reduced hibernation file' -Data @{
        HowToUndo = 'Run: powercfg /hibernate /type full'
    }
    Write-Log 'Hibernation file set to reduced mode.' 'INFO'
}

Export-ModuleMember -Function Get-StorageReport, Get-CleanupTargets, Invoke-SafeCleanup,
    Invoke-ComponentCleanup, Enable-StorageSense, Set-HibernationReduced
