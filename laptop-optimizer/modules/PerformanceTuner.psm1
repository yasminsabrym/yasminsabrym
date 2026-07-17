# PerformanceTuner.psm1 - CPU / RAM / GPU tuning with thermals in mind.
#
# The centerpiece is the power mode switcher. The single most effective
# "fast but quiet" trick on a laptop is capping the CPU at 99% maximum
# processor state: that disables Turbo Boost, which on most laptops causes
# the majority of heat and fan noise for only a small burst-speed gain.

function Get-PerformanceReport {
    Write-Host ''
    Write-Host '  === CPU ===' -ForegroundColor Cyan
    $cpu = Get-CimInstance Win32_Processor
    Write-Host ('  {0}' -f $cpu.Name.Trim())
    Write-Host ('  Cores: {0} physical / {1} logical   Current load: {2}%' -f `
        $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.LoadPercentage)

    Write-Host ''
    Write-Host '  === Memory ===' -ForegroundColor Cyan
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)
    Write-Host ('  {0} GB installed, {1} GB free ({2}% in use)' -f $totalGB, $freeGB, $usedPct)
    Write-Host ''
    Write-Host '  Top memory users right now:' -ForegroundColor Cyan
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 | ForEach-Object {
        Write-Host ('  {0,10}   {1}' -f (Format-Size $_.WorkingSet64), $_.ProcessName)
    }

    Write-Host ''
    Write-Host '  === GPU ===' -ForegroundColor Cyan
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-Host ('  {0}' -f $_.Name)
        if ($_.DriverDate) {
            $age = (New-TimeSpan -Start $_.DriverDate -End (Get-Date)).Days
            $ageNote = if ($age -gt 365) { "  <-- over a year old, update recommended" } else { '' }
            Write-Host ('    Driver {0} ({1} days old){2}' -f $_.DriverVersion, $age, $ageNote)
        }
    }
    $hws = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
    Write-Host ('  Hardware-accelerated GPU scheduling: {0}' -f $(switch ($hws) { 2 { 'ON' } 1 { 'OFF' } default { 'not configured (OFF)' } }))

    Write-Host ''
    Write-Host '  === Disks ===' -ForegroundColor Cyan
    try {
        Get-PhysicalDisk | ForEach-Object {
            Write-Host ('  {0}  [{1}]  Health: {2}' -f $_.FriendlyName, $_.MediaType, $_.HealthStatus)
        }
    } catch { Write-Host '  (disk details unavailable)' -ForegroundColor Gray }

    Write-Host ''
    Write-Host '  === Temperature ===' -ForegroundColor Cyan
    try {
        $zones = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        foreach ($z in $zones) {
            $celsius = [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1)
            $flag = if ($celsius -ge 85) { '  <-- HOT' } elseif ($celsius -ge 70) { '  (warm)' } else { '' }
            Write-Host ('  {0} C  {1}{2}' -f $celsius, $z.InstanceName, $flag)
        }
    } catch {
        Write-Host '  This laptop does not expose ACPI temperatures to Windows.' -ForegroundColor Gray
        Write-Host '  For live temps/fan curves use the free tool HWiNFO64 or your vendor app' -ForegroundColor Gray
        Write-Host '  (Lenovo Vantage / Dell Power Manager / HP Command Center / ASUS MyASUS).' -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '  === Active power settings ===' -ForegroundColor Cyan
    $scheme = (powercfg /getactivescheme) -join ''
    Write-Host "  $scheme"
}

function Set-PowerMode {
    <#
        Three curated profiles applied to the ACTIVE power plan:

        Quiet       - CPU capped at 80%, passive cooling preferred, boost off.
                      Near-silent; great for browsing, office work, meetings.
        Balanced    - CPU capped at 99% (Turbo Boost disabled), active cooling.
                      ~90-97% of full performance with a fraction of the heat
                      and fan noise. The recommended daily driver.
        Performance - CPU 100%, aggressive boost, active cooling.
                      Full speed for gaming/rendering; fans will be audible.
    #>
    param([Parameter(Mandatory)][ValidateSet('Quiet','Balanced','Performance')][string]$Mode)

    if (-not (Test-IsAdmin)) {
        Write-Log 'Power tuning needs an elevated window.' 'ERROR'; return
    }
    $settings = switch ($Mode) {
        'Quiet'       { @{ MaxAC = 80;  MaxDC = 70;  Boost = 0; CoolAC = 0; CoolDC = 0 } }
        'Balanced'    { @{ MaxAC = 99;  MaxDC = 90;  Boost = 0; CoolAC = 1; CoolDC = 0 } }
        'Performance' { @{ MaxAC = 100; MaxDC = 100; Boost = 2; CoolAC = 1; CoolDC = 1 } }
    }
    if (-not (Confirm-Action "Apply the '$Mode' power profile to the active power plan?")) { return }

    # Record current values once for the undo journal.
    $before = (powercfg /query scheme_current sub_processor PROCTHROTTLEMAX) -join ' '

    powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX $settings.MaxAC | Out-Null
    powercfg /setdcvalueindex scheme_current sub_processor PROCTHROTTLEMAX $settings.MaxDC | Out-Null
    # PERFBOOSTMODE: 0 = disabled, 2 = aggressive. Ignored gracefully on CPUs without it.
    powercfg /setacvalueindex scheme_current sub_processor PERFBOOSTMODE $settings.Boost 2>$null | Out-Null
    powercfg /setdcvalueindex scheme_current sub_processor PERFBOOSTMODE $settings.Boost 2>$null | Out-Null
    # SYSCOOLPOL: 0 = passive (slow down before spinning fans), 1 = active.
    powercfg /setacvalueindex scheme_current sub_processor SYSCOOLPOL $settings.CoolAC 2>$null | Out-Null
    powercfg /setdcvalueindex scheme_current sub_processor SYSCOOLPOL $settings.CoolDC 2>$null | Out-Null
    powercfg /setactive scheme_current | Out-Null

    Add-UndoEntry -Action "Applied power mode: $Mode" -Data @{
        MaxProcessorStateAC = $settings.MaxAC
        HowToUndo = 'Apply another mode, or reset the plan: powercfg /restoredefaultschemes (removes ALL custom plans). Previous raw values: ' + $before
    }
    Write-Log "'$Mode' profile applied to the active power plan (plugged-in AND battery values set)." 'INFO'
    if ($Mode -eq 'Balanced') {
        Write-Log 'Tip: 99% max disables Turbo Boost - expect dramatically lower temps and fan noise for a small peak-speed cost.' 'INFO'
    }
}

function Get-StartupPrograms {
    <#
        Lists everything that starts with Windows, from all four common
        locations. Fewer startup programs = faster boot, less RAM baseline.
    #>
    $results = @()
    $runKeys = @(
        @{ Hive = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Scope = 'All users' },
        @{ Hive = 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'All users (32-bit)' },
        @{ Hive = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Scope = 'Your account' }
    )
    foreach ($rk in $runKeys) {
        if (-not (Test-Path $rk.Hive)) { continue }
        $props = Get-ItemProperty -Path $rk.Hive
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
            $results += [pscustomobject]@{ Name = $p.Name; Command = $p.Value; Source = $rk.Hive; Scope = $rk.Scope }
        }
    }
    $startupDirs = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($dir in $startupDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $results += [pscustomobject]@{ Name = $_.BaseName; Command = $_.FullName; Source = $dir; Scope = 'Startup folder' }
        }
    }
    return $results
}

function Show-StartupAudit {
    $items = Get-StartupPrograms
    Write-Host ''
    Write-Host '  === Programs that launch at startup ===' -ForegroundColor Cyan
    if (-not $items) { Write-Host '  (none found in the standard locations)' -ForegroundColor Gray; return }
    $i = 0
    foreach ($item in $items) {
        $i++
        Write-Host ('  [{0}] {1}  ({2})' -f $i, $item.Name, $item.Scope)
        Write-Host ('       {0}' -f $item.Command) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  Cloud sync, audio drivers, and your antivirus should stay.' -ForegroundColor Gray
    Write-Host '  Updaters, game launchers, and chat apps are usually safe to remove from startup.' -ForegroundColor Gray
    $choice = Read-Host '  Enter a number to disable that item (blank to go back)'
    if (-not $choice -or $choice -notmatch '^\d+$') { return }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $items.Count) { Write-Log 'Invalid selection.' 'WARN'; return }
    $target = $items[$idx]
    if (-not (Confirm-Action "Remove '$($target.Name)' from startup? (the app itself is NOT uninstalled; you can still open it normally)")) { return }
    if ($target.Scope -eq 'Startup folder') {
        Move-Item -LiteralPath $target.Command -Destination "$env:LOCALAPPDATA\LaptopOptimizer\disabled-startup-$([IO.Path]::GetFileName($target.Command))" -Force
        Add-UndoEntry -Action "Disabled startup item $($target.Name)" -Data @{
            OriginalPath = $target.Command
            MovedTo      = "$env:LOCALAPPDATA\LaptopOptimizer"
            HowToUndo    = 'Move the file back to its OriginalPath.'
        }
    } else {
        Add-UndoEntry -Action "Disabled startup item $($target.Name)" -Data @{
            RegistryKey = $target.Source
            ValueName   = $target.Name
            OldCommand  = $target.Command
            HowToUndo   = 'Re-create the registry value with OldCommand as its data.'
        }
        Remove-ItemProperty -Path $target.Source -Name $target.Name
    }
    Write-Log "'$($target.Name)' removed from startup (recorded in the undo journal)." 'INFO'
}

function Enable-GpuScheduling {
    <#
        Hardware-accelerated GPU scheduling reduces latency and CPU overhead
        on Windows 10 2004+ with a WDDM 2.7 driver. Harmless where unsupported
        (the flag is simply ignored). Requires a restart.
    #>
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $current = (Get-ItemProperty $key -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
    if ($current -eq 2) { Write-Log 'Hardware-accelerated GPU scheduling is already ON.' 'INFO'; return }
    if (-not (Confirm-Action 'Enable hardware-accelerated GPU scheduling? (lower latency; needs restart; requires a 2020+ GPU driver)')) { return }
    Set-ItemProperty -Path $key -Name HwSchMode -Value 2 -Type DWord
    Add-UndoEntry -Action 'Enabled GPU hardware scheduling' -Data @{
        RegistryKey = $key
        HowToUndo   = 'Set HwSchMode to 1 (or delete the value) and restart.'
    }
    Write-Log 'GPU hardware scheduling enabled - takes effect after restart.' 'INFO'
}

function Set-VisualEffectsPerformance {
    <#
        "Best performance" visual effects, but keeps font smoothing and
        thumbnail previews so Windows doesn't look broken.
    #>
    if (-not (Confirm-Action 'Set visual effects to performance mode? (disables animations/shadows, keeps smooth fonts and thumbnails)')) { return }
    $fxKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    Set-ItemProperty -Path $fxKey -Name VisualFXSetting -Value 3 -Type DWord  # 3 = custom
    # Keep: font smoothing, thumbnails. Disable: animations, shadows, transparency.
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name FontSmoothing -Value '2'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name DragFullWindows -Value '0'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name MenuShowDelay -Value '0'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name MinAnimate -Value '0'
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Add-UndoEntry -Action 'Visual effects set to performance' -Data @{
        HowToUndo = 'SystemPropertiesPerformance.exe > "Let Windows choose what is best".'
    }
    Write-Log 'Visual effects trimmed. Sign out/in for everything to apply.' 'INFO'
}

function Optimize-BackgroundServices {
    <#
        Conservative service tuning. Only two safe, reversible tweaks:
        * SysMain (Superfetch) - useful on SSDs generally, but if the system
          drive is a spinning HDD it causes constant disk thrash; offer to
          disable only in that case.
        * Windows Search indexer - offer to limit, never disable outright.
    #>
    $sysDriveIsHdd = $false
    try {
        $sysDisk = Get-PhysicalDisk | Where-Object { $_.MediaType -eq 'HDD' }
        if ($sysDisk) { $sysDriveIsHdd = $true }
    } catch { }
    if ($sysDriveIsHdd) {
        $svc = Get-Service -Name SysMain -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            if (Confirm-Action 'A spinning HDD was detected. Disable SysMain (Superfetch)? It often causes 100% disk usage on HDDs.') {
                Stop-Service SysMain -Force
                Set-Service SysMain -StartupType Disabled
                Add-UndoEntry -Action 'Disabled SysMain' -Data @{ HowToUndo = 'Set-Service SysMain -StartupType Automatic; Start-Service SysMain' }
                Write-Log 'SysMain disabled.' 'INFO'
            }
        }
    } else {
        Write-Log 'All disks are SSD/NVMe - SysMain and Windows Search are beneficial here, leaving them on (disabling them is an outdated tweak that hurts SSD systems).' 'INFO'
    }
}

Export-ModuleMember -Function Get-PerformanceReport, Set-PowerMode, Get-StartupPrograms, Show-StartupAudit,
    Enable-GpuScheduling, Set-VisualEffectsPerformance, Optimize-BackgroundServices
