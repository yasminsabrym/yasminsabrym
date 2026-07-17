<#
    LaptopOptimizer - safe storage, admin, and performance tuning for Windows laptops.

    Run from an elevated PowerShell window:
        Set-ExecutionPolicy -Scope Process Bypass -Force
        .\LaptopOptimizer.ps1

    Design rules baked into every module:
      * Nothing changes without showing you what/why and asking Y/N first.
      * System-critical paths are blacklisted and cannot be moved or deleted.
      * Every change is written to an undo journal (option U shows it).
      * A System Restore point is offered at the start of each session.
#>

[CmdletBinding()]
param(
    # Skip the self-elevation prompt (used internally after relaunch).
    [switch]$Elevated
)

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Self-elevate -----------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Requesting administrator rights (UAC prompt)...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"", '-Elevated'
        )
        exit
    } catch {
        Write-Host 'Elevation was declined. Running with limited features (reports only).' -ForegroundColor Yellow
    }
}

# --- Load modules -----------------------------------------------------------
$moduleDir = Join-Path $scriptRoot 'modules'
foreach ($m in 'Common', 'StorageMover', 'StorageCleaner', 'AdminGuard', 'PerformanceTuner') {
    Import-Module (Join-Path $moduleDir "$m.psm1") -Force
}
Initialize-OptimizerState

# --- Banner + one-time safety offer ----------------------------------------
Clear-Host
Write-Host ''
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '     LAPTOP OPTIMIZER  -  safe by default'       -ForegroundColor Cyan
Write-Host '  =============================================' -ForegroundColor Cyan
Write-Host '  Every change: previewed, confirmed, journaled.'
Write-Host ''

if (Test-IsAdmin) {
    if (Confirm-Action 'Create a System Restore point before this session? (recommended once per day)') {
        New-SafetyRestorePoint | Out-Null
    }
} else {
    Write-Log 'Not elevated - move/tune actions will be blocked, reports still work.' 'WARN'
}

# --- Menu -------------------------------------------------------------------
function Show-Menu {
    Write-Host ''
    Write-Host '  ------------- REPORTS -------------' -ForegroundColor DarkCyan
    Write-Host '   1) System & performance report (CPU, RAM, GPU, temps, disks)'
    Write-Host '   2) Storage report (drive usage, biggest folders)'
    Write-Host '   3) What can safely move from C: to D: (with sizes)'
    Write-Host '   4) Admin rights & account security report'
    Write-Host ''
    Write-Host '  ---------- FREE UP C: DRIVE -------' -ForegroundColor DarkCyan
    Write-Host '   5) Move a user folder (Downloads/Documents/...) to D:'
    Write-Host '   6) Relocate app & developer caches to D: (junction-safe)'
    Write-Host '   7) Move the page file to D:'
    Write-Host '   8) Clean regenerable temp/cache files'
    Write-Host '   9) Deep clean Windows component store (DISM)'
    Write-Host '  10) Shrink hibernation file (keeps Fast Startup)'
    Write-Host '  11) Enable Storage Sense (automatic ongoing cleanup)'
    Write-Host '  12) Save NEW content to D: by default (opens Settings)'
    Write-Host ''
    Write-Host '  --------- SECURE ADMIN RIGHTS -----' -ForegroundColor DarkCyan
    Write-Host '  13) Harden admin account (UAC, built-in accounts, rogue admins)'
    Write-Host ''
    Write-Host '  ------ PERFORMANCE & THERMALS -----' -ForegroundColor DarkCyan
    Write-Host '  14) Power mode: QUIET       (silent, cool, ~80% speed)'
    Write-Host '  15) Power mode: BALANCED    (recommended: ~95% speed, no turbo heat/fan roar)'
    Write-Host '  16) Power mode: PERFORMANCE (full speed, fans allowed)'
    Write-Host '  17) Startup programs audit (trim autostart bloat)'
    Write-Host '  18) Enable GPU hardware scheduling'
    Write-Host '  19) Visual effects: performance mode'
    Write-Host '  20) Background services check (HDD-aware)'
    Write-Host ''
    Write-Host '   U) Show undo journal        R) Create restore point        Q) Quit'
    Write-Host ''
}

while ($true) {
    Show-Menu
    $choice = (Read-Host '  Choose an option').Trim().ToUpper()
    switch ($choice) {
        '1'  { Get-PerformanceReport }
        '2'  { Get-StorageReport }
        '3'  { Get-MovableReport }
        '4'  { Get-AdminReport }
        '5'  {
            $name = Read-Host '  Which folder? (Downloads / Documents / Pictures / Music / Videos / Desktop)'
            if ($name -in @('Downloads','Documents','Pictures','Music','Videos','Desktop')) {
                Move-UserFolder -Name $name
            } else { Write-Log 'Unknown folder name.' 'WARN' }
        }
        '6'  { Move-AppCaches }
        '7'  { Move-PageFile }
        '8'  { Invoke-SafeCleanup }
        '9'  { Invoke-ComponentCleanup }
        '10' { Set-HibernationReduced }
        '11' { Enable-StorageSense }
        '12' { Set-NewContentToDataDrive }
        '13' { Protect-AdminAccount }
        '14' { Set-PowerMode -Mode Quiet }
        '15' { Set-PowerMode -Mode Balanced }
        '16' { Set-PowerMode -Mode Performance }
        '17' { Show-StartupAudit }
        '18' { Enable-GpuScheduling }
        '19' { Set-VisualEffectsPerformance }
        '20' { Optimize-BackgroundServices }
        'U'  { Show-UndoJournal }
        'R'  { New-SafetyRestorePoint | Out-Null }
        'Q'  { Write-Host '  Bye!' -ForegroundColor Cyan; break }
        default { Write-Log 'Unknown option.' 'WARN' }
    }
    if ($choice -eq 'Q') { break }
    Write-Host ''
    Read-Host '  Press Enter to return to the menu' | Out-Null
    Clear-Host
}
