# Common.psm1 - shared helpers: logging, confirmation, undo journal, safety checks.
# Compatible with Windows PowerShell 5.1 (ships with Windows 10/11).

$script:LogDir   = Join-Path $env:LOCALAPPDATA 'LaptopOptimizer'
$script:LogFile  = Join-Path $script:LogDir 'optimizer.log'
$script:UndoFile = Join-Path $script:LogDir 'undo-journal.json'

function Initialize-OptimizerState {
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level = 'INFO'
    )
    Initialize-OptimizerState
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        'WARN'   { Write-Host $Message -ForegroundColor Yellow }
        'ERROR'  { Write-Host $Message -ForegroundColor Red }
        'ACTION' { Write-Host $Message -ForegroundColor Cyan }
        default  { Write-Host $Message }
    }
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-Action {
    <#
        Every change in this toolkit goes through this gate.
        Returns $true only when the user explicitly types Y.
    #>
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "  $Message" -ForegroundColor Yellow
    $answer = Read-Host '  Proceed? (Y/N)'
    return ($answer -match '^[Yy]')
}

function Format-Size {
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-FolderSizeBytes {
    <#
        Fast folder size using robocopy in list-only mode; falls back to
        Get-ChildItem if robocopy output cannot be parsed.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $output = robocopy $Path 'NULL' /L /E /XJ /NFL /NDL /NJH /R:0 /W:0 /BYTES 2>$null
        foreach ($line in $output) {
            if ($line -match '^\s*Bytes\s*:\s*([\d\.]+)') {
                return [double]$Matches[1]
            }
        }
    } catch { }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    } catch { return 0 }
}

function Add-UndoEntry {
    <#
        Appends a reversal record to the undo journal so every change the
        toolkit makes is documented and reversible by hand if needed.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Data
    )
    Initialize-OptimizerState
    $entries = @()
    if (Test-Path $script:UndoFile) {
        try { $entries = @(Get-Content $script:UndoFile -Raw | ConvertFrom-Json) } catch { $entries = @() }
    }
    $entry = [pscustomobject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Action    = $Action
        Data      = $Data
    }
    $entries = @($entries) + $entry
    $entries | ConvertTo-Json -Depth 6 | Set-Content -Path $script:UndoFile -Encoding UTF8
    Write-Log "Undo journal updated: $Action" 'INFO'
}

function Show-UndoJournal {
    if (-not (Test-Path $script:UndoFile)) {
        Write-Host '  No changes recorded yet.' -ForegroundColor Gray
        return
    }
    $entries = @(Get-Content $script:UndoFile -Raw | ConvertFrom-Json)
    foreach ($e in $entries) {
        Write-Host ('  [{0}] {1}' -f $e.Timestamp, $e.Action) -ForegroundColor Cyan
        $e.Data.PSObject.Properties | ForEach-Object {
            Write-Host ('      {0} = {1}' -f $_.Name, $_.Value) -ForegroundColor Gray
        }
    }
    Write-Host ''
    Write-Host "  Journal file: $script:UndoFile" -ForegroundColor Gray
}

function New-SafetyRestorePoint {
    <#
        Creates a System Restore point before any session that changes the
        system. Windows throttles restore points to one per 24h by default;
        that case is reported as a warning, not a failure.
    #>
    param([string]$Description = 'LaptopOptimizer session')
    try {
        Write-Log 'Creating a System Restore point (this can take a minute)...' 'ACTION'
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created.' 'INFO'
        return $true
    } catch {
        Write-Log "Could not create a restore point: $($_.Exception.Message)" 'WARN'
        Write-Log 'This usually means System Restore is disabled or a point was created in the last 24h. Continuing.' 'WARN'
        return $false
    }
}

function Get-DataDrive {
    <#
        Finds the best destination drive (default D:) - any fixed, writable
        drive that is not the system drive.
    #>
    $systemDrive = $env:SystemDrive.TrimEnd(':')
    $candidates = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
        Where-Object { $_.DeviceID.TrimEnd(':') -ne $systemDrive } |
        Sort-Object -Property @{Expression = { $_.DeviceID -ne 'D:' }}, DeviceID
    return $candidates | Select-Object -First 1
}

Export-ModuleMember -Function Initialize-OptimizerState, Write-Log, Test-IsAdmin, Confirm-Action,
    Format-Size, Get-FolderSizeBytes, Add-UndoEntry, Show-UndoJournal, New-SafetyRestorePoint, Get-DataDrive
