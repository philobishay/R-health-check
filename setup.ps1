<#
.SYNOPSIS
    Sets up the R: mirror check: installs it, saves the email sign-in, sends a test alert, schedules the checks.

.DESCRIPTION
    In PowerShell as Administrator, in this folder:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
    It
      1. copies check-mirror.ps1 to C:\ProgramData\MirrorCheck, where the scheduled checks run it from;
      2. shows what diskpart reports for the mirror and its disks, and whether the check finds a problem;
      3. asks for a Gmail address and its app password and saves them in C:\ProgramData\MirrorCheck\mail.xml,
         encrypted so that only your Windows account can read them (press Enter at the address to skip email);
      4. sends a test alert: a pop-up and, with email, a message whose subject starts with TEST ALERT;
      5. schedules the check daily at 9:00 and when you sign in, and an "all OK" email every four weeks.
    Run it again to change the address or the app password; it replaces the earlier setup.

.PARAMETER Drive      Letter of the mirrored volume (default R).
.PARAMETER Uninstall  Remove the scheduled checks and C:\ProgramData\MirrorCheck.
#>
param(
    [string]$Drive = "R",
    [switch]$Uninstall
)

# The check's functions, and $StateDir (C:\ProgramData\MirrorCheck)
. (Join-Path $PSScriptRoot "check-mirror.ps1") -Drive $Drive

$CheckTask = "Check $Drive mirror"
$OkTask = "Check $Drive mirror (OK email)"

function Install-Check {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $target = Join-Path $StateDir "check-mirror.ps1"
    Copy-Item -Path (Join-Path $PSScriptRoot "check-mirror.ps1") -Destination $target -Force -ErrorAction Stop
    Unblock-File -Path $target  # drop the "downloaded from the internet" mark
    return $target
}

function Show-DiskStatus {
    # The lines the check reads, as diskpart prints them
    $volumes = Invoke-DiskPart "list volume"
    $line = Get-VolumeLine $volumes $Drive
    if ($line) { Write-Host "      $($line.Trim())" } else { Write-Host "      (diskpart lists no volume ${Drive}:)" }
    foreach ($l in (Invoke-DiskPart "list disk") -split "`r?`n") {
        if ($l -match "^\s*\*?\s*Disk\s") { Write-Host "      $($l.Trim())" }
    }
}

function ConvertTo-Unspaced([Security.SecureString]$Secure) {
    # Google shows app passwords in groups of four; the spaces are not part of the password
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    return (ConvertTo-SecureString ($plain -replace "\s", "") -AsPlainText -Force)
}

function Read-MailSettings {
    Write-Host "      Gmail needs an app password, not your normal password: with 2-Step Verification on, create one"
    Write-Host "      at https://myaccount.google.com/apppasswords (any name, e.g. Mirror check)."
    while ($true) {
        $address = "$(Read-Host '      Gmail address (press Enter for no email)')".Trim()
        if (-not $address) { Write-Host "      No email: alerts are a pop-up and the log only."; return "" }
        if ($address -match "^[^@\s]+@[^@\s]+\.[^@\s]+$") { break }
        Write-Host "      That is not an email address."
    }
    while ($true) {
        $password = ConvertTo-Unspaced (Read-Host "      App password (16 letters; spaces don't matter)" -AsSecureString)
        if ($password.Length -gt 0) { break }
    }
    $file = Join-Path $StateDir "mail.xml"
    New-Object System.Management.Automation.PSCredential($address, $password) |
        Export-Clixml -Path $file -ErrorAction Stop
    Write-Host "      Saved in $file, encrypted so that only your Windows account can read it."
    return $address
}

function Get-LogLines {
    $log = Join-Path $StateDir "log.txt"
    if (Test-Path $log) { return @(Get-Content -Path $log) }
    return @()
}

function Invoke-TestAlert([string]$Script, [string]$Address) {
    # Runs the installed check the way the scheduled task does (a separate powershell.exe), plus -Test
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Script, "-Drive", $Drive, "-Test")
    if ($Address) { $arguments += @("-To", $Address) }
    & powershell.exe @arguments | Out-Host
}

function Remove-Task([string]$Name) {
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
}

function Register-Checks([string]$Address) {
    $script = Join-Path $StateDir "check-mirror.ps1"
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $run = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Drive $Drive"
    if ($Address) { $run += " -To $Address" }
    # Interactive: runs while you are signed in, as you, because only your account can read mail.xml
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $triggers = @((New-ScheduledTaskTrigger -Daily -At 9am), (New-ScheduledTaskTrigger -AtLogOn -User $user))
    Register-ScheduledTask -TaskName $CheckTask -Principal $principal -Trigger $triggers -Force -ErrorAction Stop `
        -Action (New-ScheduledTaskAction -Execute "powershell.exe" -Argument $run) | Out-Null
    if ($Address) {
        $every4Weeks = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Sunday -At 10am
        Register-ScheduledTask -TaskName $OkTask -Principal $principal -Trigger $every4Weeks -Force -ErrorAction Stop `
            -Action (New-ScheduledTaskAction -Execute "powershell.exe" -Argument "$run -Heartbeat") | Out-Null
    } else {
        Remove-Task $OkTask
    }
}

function Invoke-Setup {
    if (-not (Test-Administrator)) {
        Write-Host "Run this in PowerShell as Administrator (right-click Start, then Terminal (Admin))."
        return 1
    }
    if ($Uninstall) {
        Remove-Task $CheckTask
        Remove-Task $OkTask
        Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed the tasks '$CheckTask' and '$OkTask' and the folder $StateDir."
        return 0
    }

    Write-Host "1/5  Installing the check"
    $script = Install-Check
    Write-Host "      $script"
    Write-Host "      (C:\ProgramData is hidden in File Explorer: type the path into the address bar to open it.)"

    Write-Host "2/5  What diskpart reports"
    Show-DiskStatus
    $problems = @(Get-Problems $Drive)
    if ($problems.Count -eq 0) {
        Write-Host "      The check finds no problem."
    } else {
        foreach ($p in $problems) { Write-Host "      PROBLEM: $p" -ForegroundColor Yellow }
        Write-Host "      If Disk Management shows the mirror as Healthy, the check misreads this PC: send these lines" `
            -ForegroundColor Yellow
        Write-Host "      to whoever maintains the script. Setup goes on, so alerts work in the meantime." `
            -ForegroundColor Yellow
    }

    Write-Host "3/5  Email"
    $address = Read-MailSettings

    Write-Host "4/5  Test alert: a pop-up appears; click OK to go on."
    $seen = (Get-LogLines).Count
    Invoke-TestAlert $script $address
    if ($address) {
        $mail = @(Get-LogLines | Select-Object -Skip $seen | Where-Object { $_ -match "  email (sent|failed)" })
        if ($mail.Count -gt 0 -and $mail[-1] -match "email sent") {
            Write-Host "      Gmail accepted the test email: look for 'TEST ALERT' in $address (or its spam folder)."
        } else {
            $why = if ($mail.Count -gt 0) { $mail[-1] } else { "no email result in the log" }
            Write-Host "      The email failed: $why" -ForegroundColor Yellow
            Write-Host "      Check the address and the app password, then run setup again. The pop-up and the log" `
                -ForegroundColor Yellow
            Write-Host "      work in the meantime." -ForegroundColor Yellow
        }
    }

    Write-Host "5/5  Scheduling (Task Scheduler, Task Scheduler Library)"
    Register-Checks $address
    Write-Host "      '$CheckTask': daily at 9:00 and when you sign in."
    if ($address) { Write-Host "      '$OkTask': an all-OK email every 4 weeks (Sundays 10:00)." }
    Write-Host "      Both run only while you are signed in. Log: $(Join-Path $StateDir 'log.txt')"
    Write-Host "Done."
    return 0
}

if ($MyInvocation.InvocationName -ne ".") {
    try { $code = Invoke-Setup } catch { Write-Host "Setup stopped: $_" -ForegroundColor Red; $code = 1 }
    exit $code
}
