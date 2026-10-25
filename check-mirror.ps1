<#
.SYNOPSIS
    Checks a Windows mirrored volume (Disk Management "Mirrored volume" on dynamic disks) and the disks behind it,
    and raises an alert when anything is wrong.

.DESCRIPTION
    Checks, in order:
      1. diskpart "list volume": the mirror's status must be Healthy. Disk Management's "Failed Redundancy" shows
         here as "Failed Rd"; "Rebuild" means it is copying onto a replaced disk.
      2. diskpart "list disk": every disk must be Online (a disk that stops responding shows as Missing).
      3. Get-PhysicalDisk: no disk may report Warning or Unhealthy.
      4. The drives' own failure prediction (SMART), where Windows can read it.
    On a problem: an email (if -To is given), a pop-up when you are signed in, and a line in
    C:\ProgramData\MirrorCheck\log.txt. Needs administrator rights, because diskpart does.

    setup.ps1 in this folder installs and schedules it (README.md).

.PARAMETER Drive      Letter of the mirrored volume (default R).
.PARAMETER To         Email address for alerts. Uses the Gmail address and app password saved in mail.xml by setup.
.PARAMETER SmtpServer Mail server (default smtp.gmail.com, port 587 with TLS).
.PARAMETER Heartbeat  Email even when everything is fine, so you know the check still runs.
.PARAMETER Test       Add a made-up problem, to test the email and the pop-up (the real checks run too).
#>
param(
    [string]$Drive = "R",
    [string]$To,
    [string]$SmtpServer = "smtp.gmail.com",
    [int]$Port = 587,
    [switch]$Heartbeat,
    [switch]$Test
)

$StateDir = Join-Path $env:ProgramData "MirrorCheck"

function Get-VolumeLine([string]$ListVolume, [string]$Letter) {
    # A diskpart line looks like:  Volume 4     R   Mirror       NTFS   Mirror      3726 GB  Healthy
    return $ListVolume -split "`r?`n" | Where-Object { $_ -match "^\s*\*?\s*Volume\s+\d+\s+$Letter\s" } |
        Select-Object -First 1
}

function Get-VolumeProblems([string]$ListVolume, [string]$Letter) {
    $line = Get-VolumeLine $ListVolume $Letter
    if (-not $line) { return @("Volume ${Letter}: not listed by diskpart") }
    if ($line -notmatch "\sHealthy\b") { return @("Volume ${Letter}: $($line.Trim())") }
    return @()
}

function Get-DiskProblems([string]$ListDisk) {
    # Lines look like:  Disk 1    Online         3726 GB      0 B        *    (a lost mirror disk: Disk M0  Missing)
    $out = @()
    foreach ($line in $ListDisk -split "`r?`n") {
        if ($line -notmatch "^\s*\*?\s*Disk\s+(\S+)\s+(.+)$") { continue }
        if ($Matches[1] -eq "###") { continue }  # the header row
        $rest = $Matches[2]
        # card readers without a card show "No Media"; anything mentioning errors is a problem
        if ($rest -match "^(Online|No Media)\b" -and $rest -notmatch "Error") { continue }
        $out += "Disk $($Matches[1]): $($line.Trim())"
    }
    return $out
}

function Get-PhysicalDiskProblems {
    $out = @()
    foreach ($d in @(Get-PhysicalDisk)) {
        if ("$($d.HealthStatus)" -in @("Warning", "Unhealthy", "1", "2")) {  # names or their codes
            $out += "Physical disk '$($d.FriendlyName)': health $($d.HealthStatus) ($($d.OperationalStatus -join ', '))"
        }
    }
    return $out
}

function Get-SmartProblems {
    $out = @()
    try {
        $all = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
        foreach ($s in $all) {
            if ($s.PredictFailure) { $out += "The drive predicts its own failure (SMART): $($s.InstanceName)" }
        }
    } catch {
        # not every drive or controller reports this; the checks above still run
    }
    return $out
}

function Invoke-DiskPart([string]$Command) {
    $file = Join-Path $env:TEMP "check-mirror-diskpart.txt"
    Set-Content -Path $file -Value $Command -Encoding ASCII
    try { return ((& diskpart.exe /s $file) -join "`n") }
    finally { Remove-Item -Path $file -ErrorAction SilentlyContinue }
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Problems([string]$Letter) {
    $problems = @()
    if (Test-Administrator) {
        $problems += @(Get-VolumeProblems (Invoke-DiskPart "list volume") $Letter)
        $problems += @(Get-DiskProblems (Invoke-DiskPart "list disk"))
    } else {
        $problems += "The mirror was not checked: check-mirror.ps1 must run as administrator (diskpart needs it)."
    }
    $problems += @(Get-PhysicalDiskProblems)
    $problems += @(Get-SmartProblems)
    return $problems
}

function Send-Report([string]$Subject, [string]$Body, [switch]$Popup) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $log = Join-Path $StateDir "log.txt"
    Add-Content -Path $log -Value "$(Get-Date -Format s)  $Subject`r`n$Body`r`n"
    if ($To) {
        try {
            $cred = Import-Clixml -Path (Join-Path $StateDir "mail.xml")
            # Gmail requires TLS 1.2, which older .NET Framework defaults leave out
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
                [Net.SecurityProtocolType]::Tls12
            Send-MailMessage -From $cred.UserName -To $To -Subject $Subject -Body $Body -SmtpServer $SmtpServer `
                -Port $Port -UseSsl -Credential $cred -ErrorAction Stop
            Add-Content -Path $log -Value "$(Get-Date -Format s)  email sent to $To`r`n"
        } catch {
            Add-Content -Path $log -Value "$(Get-Date -Format s)  email failed: $_`r`n"
        }
    }
    if ($Popup) {
        try { (New-Object -ComObject WScript.Shell).Popup($Body, 0, $Subject, 0x30) | Out-Null } catch { }
    }
}

function Invoke-Check {
    $real = @(Get-Problems $Drive)
    $problems = $real
    if ($Test) { $problems += "TEST ALERT from check-mirror.ps1: nothing is actually wrong." }
    $computer = $env:COMPUTERNAME
    if ($problems.Count -gt 0) {
        $body = ($problems -join "`r`n") + "`r`n`r`nIf a disk failed: copy anything irreplaceable off ${Drive}: " +
            "now, then replace the failed disk and re-add the mirror in Disk Management."
        $subject = "DISK PROBLEM on $computer (${Drive}:)"
        if ($real.Count -eq 0) { $subject = "TEST ALERT: mirror check on $computer (${Drive}:)" }
        Write-Host $body
        Send-Report -Subject $subject -Body $body -Popup
        return 1
    }
    Write-Host "OK: the ${Drive}: mirror and all disks are healthy."
    if ($Heartbeat) {
        Send-Report -Subject "Disks OK on $computer (${Drive}:)" -Body "The ${Drive}: mirror and all disks are healthy."
    }
    return 0
}

# Run the check unless this file is being dot-sourced (setup and tests load the functions without running them).
if ($MyInvocation.InvocationName -ne ".") { exit (Invoke-Check) }
