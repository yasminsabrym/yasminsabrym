# AdminGuard.psm1 - verify and harden your admin rights.
#
# What "full admin" honestly means on Windows:
#   * Membership in the local Administrators group + UAC elevation IS full
#     admin. There is no higher user tier to unlock.
#   * SYSTEM and TrustedInstaller sit above admins BY DESIGN - they protect
#     Windows' own files from being corrupted (including by malware running
#     as admin). Removing that protection would make the laptop less safe,
#     not more, so this tool does not attempt it.
#   * "Cannot be overridden" is achieved by: being the only admin, keeping
#     UAC on, having a strong password, and enabling BitLocker (so an
#     attacker with physical access can't reset your password offline).
#     Those are exactly the checks below.

function Get-AdminReport {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($me)
    $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Write-Host ''
    Write-Host '  === Your account ===' -ForegroundColor Cyan
    Write-Host ('  Signed in as        : {0}' -f $me.Name)
    Write-Host ('  Running elevated    : {0}' -f $(if ($elevated) { 'YES - full admin token active' } else { 'NO' }))

    # Local Administrators group membership.
    Write-Host ''
    Write-Host '  === Members of the Administrators group ===' -ForegroundColor Cyan
    $admins = @()
    try {
        $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
        foreach ($a in $admins) {
            $marker = ''
            if ($me.Name -like "*\$($a.Name.Split('\')[-1])" -or $a.Name -eq $me.Name) { $marker = '   <-- you' }
            Write-Host ('  {0}  ({1}){2}' -f $a.Name, $a.ObjectClass, $marker)
        }
    } catch {
        # Fallback for systems where Get-LocalGroupMember fails on orphaned SIDs.
        (net localgroup Administrators) | Select-Object -Skip 6 |
            Where-Object { $_ -and $_ -notmatch 'command completed' } |
            ForEach-Object { Write-Host "  $_" }
    }

    # UAC configuration.
    $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = (Get-ItemProperty -Path $polKey -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
    $consent = (Get-ItemProperty -Path $polKey -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
    Write-Host ''
    Write-Host '  === Account protection (what makes your admin rights hard to override) ===' -ForegroundColor Cyan
    Write-Host ('  UAC enabled              : {0}' -f $(if ($lua -eq 1) { 'YES (good - blocks silent elevation)' } else { 'NO (risky!)' }))
    Write-Host ('  UAC prompt level         : {0}' -f $(switch ($consent) {
        0 { 'Elevate silently (WEAK)' } 1 { 'Prompt for credentials on secure desktop' }
        2 { 'Prompt for consent on secure desktop (strong)' } 5 { 'Prompt for consent (default)' }
        default { "value $consent" } }))

    # Built-in Administrator should stay disabled - it's a common takeover path.
    try {
        $builtin = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-500' }
        if ($builtin) {
            Write-Host ('  Built-in Administrator   : {0}' -f $(if ($builtin.Enabled) { 'ENABLED (should be disabled)' } else { 'disabled (good)' }))
        }
        $guest = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-501' }
        if ($guest) {
            Write-Host ('  Guest account            : {0}' -f $(if ($guest.Enabled) { 'ENABLED (should be disabled)' } else { 'disabled (good)' }))
        }
        $myLocal = Get-LocalUser | Where-Object { $_.Name -eq $env:USERNAME }
        if ($myLocal) {
            Write-Host ('  Your account enabled     : {0}' -f $myLocal.Enabled)
            Write-Host ('  Password required        : {0}' -f $myLocal.PasswordRequired)
            Write-Host ('  Password last set        : {0}' -f $myLocal.PasswordLastSet)
        }
    } catch {
        Write-Host '  (local account details unavailable - likely a Microsoft/AAD account; that is fine)' -ForegroundColor Gray
    }

    # BitLocker - the real "cannot be overridden" protection.
    try {
        $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        Write-Host ('  BitLocker on C:          : {0}' -f $blv.ProtectionStatus)
        if ($blv.ProtectionStatus -ne 'On') {
            Write-Host '     Without disk encryption, anyone with physical access can reset your' -ForegroundColor Yellow
            Write-Host '     password from a USB stick. Enabling BitLocker closes that door.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host '  BitLocker on C:          : not available on this edition (Windows Home uses "Device encryption" in Settings)' -ForegroundColor Gray
    }

    if (-not $elevated) {
        Write-Host ''
        Write-Log 'You are an admin but this window is not elevated. Re-run the tool "as administrator" to see the full picture.' 'WARN'
    }
}

function Protect-AdminAccount {
    <#
        Applies the hardening that actually makes admin rights resilient:
        1. Ensures UAC is ON (prevents programs elevating without your consent).
        2. Disables the built-in Administrator and Guest accounts if enabled.
        3. Reports any OTHER admin accounts so you can demote unexpected ones.
        It intentionally does NOT disable UAC, take ownership of Windows files,
        or run as TrustedInstaller - those would weaken the system.
    #>
    if (-not (Test-IsAdmin)) {
        Write-Log 'This action needs an elevated window. Restart the tool as administrator.' 'ERROR'
        return
    }
    $polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # 1. UAC on.
    $lua = (Get-ItemProperty -Path $polKey -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
    if ($lua -ne 1) {
        if (Confirm-Action 'UAC is OFF. Turn it back on? (strongly recommended - this is what stops silent takeovers)') {
            Set-ItemProperty -Path $polKey -Name EnableLUA -Value 1 -Type DWord
            Add-UndoEntry -Action 'Enabled UAC' -Data @{ RegistryKey = $polKey; Value = 'EnableLUA=1'; HowToUndo = 'Not recommended, but set EnableLUA back to 0 and reboot.' }
            Write-Log 'UAC enabled (takes effect after restart).' 'INFO'
        }
    } else {
        Write-Log 'UAC is already on. Good.' 'INFO'
    }

    # 2. Built-in Administrator / Guest.
    try {
        $builtin = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-500' }
        if ($builtin -and $builtin.Enabled) {
            if (Confirm-Action "The hidden built-in Administrator account is ENABLED. Disable it? (your own admin rights are unaffected)") {
                Disable-LocalUser -SID $builtin.SID
                Add-UndoEntry -Action 'Disabled built-in Administrator' -Data @{ HowToUndo = 'Enable-LocalUser -Name Administrator' }
                Write-Log 'Built-in Administrator disabled.' 'INFO'
            }
        }
        $guest = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-501' }
        if ($guest -and $guest.Enabled) {
            if (Confirm-Action 'The Guest account is ENABLED. Disable it?') {
                Disable-LocalUser -SID $guest.SID
                Add-UndoEntry -Action 'Disabled Guest account' -Data @{ HowToUndo = 'Enable-LocalUser -Name Guest' }
                Write-Log 'Guest account disabled.' 'INFO'
            }
        }
    } catch {
        Write-Log 'Could not manage local accounts (Microsoft/AAD-joined device or Home edition limits). Skipping.' 'WARN'
    }

    # 3. Flag other admins.
    try {
        $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
        $others = $admins | Where-Object {
            $_.Name -notlike "*\$env:USERNAME" -and
            $_.SID.Value -notlike '*-500' -and
            $_.ObjectClass -eq 'User'
        }
        if ($others) {
            Write-Host ''
            Write-Log 'Other user accounts also have admin rights:' 'WARN'
            $others | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
            Write-Host '    If you do not recognize one, demote it with:' -ForegroundColor Yellow
            Write-Host '    Remove-LocalGroupMember -Group Administrators -Member "<name>"' -ForegroundColor Yellow
            Write-Host '    (This tool will not auto-remove accounts - a wrong removal could lock someone out.)' -ForegroundColor Gray
        } else {
            Write-Log 'No unexpected admin user accounts found.' 'INFO'
        }
    } catch { }

    Write-Host ''
    Write-Host '  Final pieces only you can do:' -ForegroundColor Cyan
    Write-Host '   * Use a strong password/PIN (Settings > Accounts > Sign-in options).'
    Write-Host '   * Turn on BitLocker/Device encryption so the password cannot be reset offline.'
    Write-Host '   * Note: SYSTEM/TrustedInstaller staying above admins is intentional Windows design -'
    Write-Host '     it is what protects the OS (and your admin account) from tampering.'
}

Export-ModuleMember -Function Get-AdminReport, Protect-AdminAccount
