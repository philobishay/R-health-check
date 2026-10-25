# Tests for check-mirror.ps1 and setup.ps1, with the Windows-only commands stubbed (diskpart, disk health, SMART,
# email, pop-up, Task Scheduler). The diskpart output below is written by hand in diskpart's format, not recorded on
# a real PC. Run in this folder:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests.ps1
$ErrorActionPreference = "Stop"
$env:ProgramData = Join-Path ([IO.Path]::GetTempPath()) ("mirror-check-test-" + [guid]::NewGuid())  # never the real one
$env:USERDOMAIN = "DESKTOP"; $env:USERNAME = "user"; $env:COMPUTERNAME = "DESKTOP"
. (Join-Path $PSScriptRoot "check-mirror.ps1")
$fail = 0
function Assert($cond, $msg) { if ($cond) { Write-Output "ok   $msg" } else { Write-Output "FAIL $msg"; $script:fail++ } }
function Check { Invoke-Check 6>$null }  # without its console summary

foreach ($f in Get-ChildItem -Path $PSScriptRoot -Filter *.ps1) {
    $high = @([IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 }).Count
    Assert ($high -eq 0) "$($f.Name) is ASCII (Windows PowerShell 5.1 reads scripts as cp1252)"
}

$header = @"
Microsoft DiskPart version 10.0.22621.1

Copyright (C) Microsoft Corporation.
On computer: DESKTOP

  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info
  ----------  ---  -----------  -----  ----------  -------  ---------  --------
  Volume 0     E                       DVD-ROM         0 B  No Media
  Volume 1     C                NTFS   Partition    465 GB  Healthy    Boot
  Volume 2         Recovery     NTFS   Partition    529 MB  Healthy    Hidden
  Volume 3     D                NTFS   Partition    931 GB  Healthy    Pagefile
"@
$volOk      = $header + "`r`n  Volume 4     R   Mirror       NTFS   Mirror      3726 GB  Healthy`r`n"
$volFailed  = $header + "`r`n  Volume 4     R   Mirror       NTFS   Mirror      3726 GB  Failed Rd`r`n"
$volRebuild = $header + "`r`n  Volume 4     R   Mirror       NTFS   Mirror      3726 GB  Rebuild`r`n"
$volNone    = $header

$disks = @"
  Disk ###  Status         Size     Free     Dyn  Gpt
  --------  -------------  -------  -------  ---  ---
  Disk 0    Online          465 GB      0 B
  Disk 1    Online         3726 GB      0 B   *    *
  Disk 2    Online         3726 GB      0 B   *    *
  Disk 3    No Media           0 B      0 B
"@
$disksMissing = $disks -replace "  Disk 2    Online         3726 GB", "  Disk M0   Missing        3726 GB"
$disksErrors = $disks -replace "  Disk 2    Online   ", "  Disk 2    Errors   "

# --- reading diskpart
Assert ((Get-VolumeProblems $volOk "R").Count -eq 0) "healthy mirror: no problem"
$p = @(Get-VolumeProblems $volFailed "R"); Assert ($p.Count -eq 1 -and $p[0] -match "Failed Rd") "failed redundancy is reported: $p"
$p = @(Get-VolumeProblems $volRebuild "R"); Assert ($p.Count -eq 1 -and $p[0] -match "Rebuild") "rebuilding is reported"
$p = @(Get-VolumeProblems $volNone "R"); Assert ($p.Count -eq 1 -and $p[0] -match "not listed") "missing volume is reported"
Assert ((Get-VolumeProblems $volOk "D").Count -eq 0) "other letters work (D: healthy)"
Assert ((Get-DiskProblems $disks).Count -eq 0) "all disks online (card reader with no media ignored)"
$p = @(Get-DiskProblems $disksMissing); Assert ($p.Count -eq 1 -and $p[0] -match "M0.*Missing") "missing mirror disk is reported: $p"
$p = @(Get-DiskProblems $disksErrors); Assert ($p.Count -eq 1 -and $p[0] -match "Errors") "disk with errors is reported"

# --- Send-Report logs whether the email went out (no pop-up here: on Windows it would really show)
function Import-Clixml {
    New-Object System.Management.Automation.PSCredential("me@gmail.com", (ConvertTo-SecureString "x" -AsPlainText -Force))
}
$script:mails = @(); $script:mailFails = $false
function Send-MailMessage {
    [CmdletBinding()] param($From, $To, $Subject, $Body, $SmtpServer, $Port, [switch]$UseSsl, $Credential)
    if ($script:mailFails) { throw "535 5.7.8 Username and Password not accepted" }
    $script:mails += [pscustomobject]@{ From = $From; To = $To; Subject = $Subject; Server = "${SmtpServer}:$Port"; Tls = [bool]$UseSsl }
}
$log = Join-Path $StateDir "log.txt"
$To = "alerts@example.com"
Send-Report -Subject "S1" -Body "B1"
$m = $script:mails[0]
Assert ($script:mails.Count -eq 1 -and $m.From -eq "me@gmail.com" -and $m.To -eq "alerts@example.com" -and $m.Server -eq "smtp.gmail.com:587" -and $m.Tls) "email goes from the saved Gmail address to -To over TLS"
Assert ((Get-Content $log -Raw) -match "email sent to alerts@example.com") "a sent email is logged"
$script:mailFails = $true
Send-Report -Subject "S2" -Body "B2"
Assert ((Get-Content $log -Raw) -match "email failed: 535") "a failed email is logged with the reason"
$script:mailFails = $false; $To = ""
Send-Report -Subject "S3" -Body "B3"
Assert ($script:mails.Count -eq 1 -and (Get-Content $log -Raw) -match "S3") "without -To: logged, no email"

# --- the whole check, with the Windows-only commands stubbed
function Test-Administrator { $true }
$script:vol = $volOk; $script:dsk = $disks
function Invoke-DiskPart([string]$Command) { if ($Command -eq "list volume") { $script:vol } else { $script:dsk } }
function Get-PhysicalDisk { @([pscustomobject]@{FriendlyName="WDC A"; HealthStatus="Healthy"; OperationalStatus=@("OK")},
                             [pscustomobject]@{FriendlyName="WDC B"; HealthStatus="Healthy"; OperationalStatus=@("OK")}) }
function Get-CimInstance { throw "not supported here" }
$script:sent = @()
function Send-Report([string]$Subject, [string]$Body, [switch]$Popup) { $script:sent += [pscustomobject]@{S=$Subject; B=$Body; P=[bool]$Popup} }

Assert ((Check) -eq 0 -and $script:sent.Count -eq 0) "all healthy: exit 0, nothing sent"
$Heartbeat = $true; $script:sent = @()
Assert ((Check) -eq 0 -and $script:sent.Count -eq 1 -and $script:sent[0].S -match "Disks OK" -and -not $script:sent[0].P) "heartbeat sends an OK email, no pop-up"
$Heartbeat = $false; $script:vol = $volFailed; $script:dsk = $disksMissing; $script:sent = @()
$code = Check
Assert ($code -eq 1 -and $script:sent.Count -eq 1 -and $script:sent[0].P -and $script:sent[0].S -eq "DISK PROBLEM on DESKTOP (R:)") "failure: exit 1, one alert with pop-up"
Assert ($script:sent[0].B -match "Failed Rd" -and $script:sent[0].B -match "Missing") "alert lists both the mirror and the disk problem"
$Test = $true; $script:sent = @()
Assert ((Check) -eq 1 -and $script:sent[0].S -match "^DISK PROBLEM" -and $script:sent[0].B -match "TEST ALERT") "-Test with a real problem: the subject says DISK PROBLEM"
$script:vol = $volOk; $script:dsk = $disks; $script:sent = @()
Assert ((Check) -eq 1 -and $script:sent[0].S -eq "TEST ALERT: mirror check on DESKTOP (R:)" -and $script:sent[0].P) "-Test alone: TEST ALERT subject, pop-up"
$Test = $false
function Get-PhysicalDisk { @([pscustomobject]@{FriendlyName="WDC B"; HealthStatus=1; OperationalStatus=@("Predictive Failure")}) }
$script:sent = @()
Assert ((Check) -eq 1 -and $script:sent[0].B -match "WDC B") "a physical disk warning (as code 1) is reported"
function Get-PhysicalDisk { @() }
function Get-CimInstance { @([pscustomobject]@{InstanceName="IDE\DiskWDC_B"; PredictFailure=$true}) }
$script:sent = @()
Assert ((Check) -eq 1 -and $script:sent[0].B -match "SMART") "SMART failure prediction is reported"
function Test-Administrator { $false }
function Get-CimInstance { throw "x" }
$script:sent = @()
Assert ((Check) -eq 1 -and $script:sent[0].B -match "administrator") "not elevated: says so instead of passing silently"

# --- setup.ps1 (reloads the check's functions, so the stubs that matter are set again below)
. (Join-Path $PSScriptRoot "setup.ps1")
function Test-Administrator { $true }
function Invoke-DiskPart([string]$Command) { if ($Command -eq "list volume") { $script:vol } else { $script:dsk } }
function Unblock-File { [CmdletBinding()] param($Path) }
$script:answers = New-Object System.Collections.Queue
function Read-Host {
    [CmdletBinding()] param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString)
    $a = $script:answers.Dequeue()
    if (-not $AsSecureString) { return $a }
    if ($a -eq "") { return (New-Object Security.SecureString) }
    return (ConvertTo-SecureString $a -AsPlainText -Force)
}
$script:alerts = @()
function Invoke-TestAlert([string]$Script, [string]$Address) {
    $script:alerts += [pscustomobject]@{ Script = $Script; Address = $Address }
    if (-not $Address) { return }
    $line = if ($script:mailFails) { "email failed: 535 5.7.8 Username and Password not accepted" } else { "email sent to $Address" }
    Add-Content -Path (Join-Path $StateDir "log.txt") -Value "$(Get-Date -Format s)  $line`r`n"
}
$script:tasks = @{}
function New-ScheduledTaskPrincipal { [CmdletBinding()] param($UserId, $LogonType, $RunLevel)
    [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
function New-ScheduledTaskTrigger { [CmdletBinding()] param([switch]$Daily, [switch]$Weekly, [switch]$AtLogOn, $At, $User, $WeeksInterval, $DaysOfWeek)
    [pscustomobject]@{ Daily = [bool]$Daily; Weekly = [bool]$Weekly; AtLogOn = [bool]$AtLogOn; At = "$At"; User = $User; Weeks = $WeeksInterval } }
function New-ScheduledTaskAction { [CmdletBinding()] param($Execute, $Argument) [pscustomobject]@{ Execute = $Execute; Argument = $Argument } }
function Register-ScheduledTask { [CmdletBinding()] param($TaskName, $Principal, $Trigger, $Action, [switch]$Force)
    $script:tasks[$TaskName] = [pscustomobject]@{ Principal = $Principal; Trigger = @($Trigger); Action = $Action }
    [pscustomobject]@{ TaskName = $TaskName } }
function Get-ScheduledTask { [CmdletBinding()] param($TaskName) if ($script:tasks.ContainsKey($TaskName)) { [pscustomobject]@{ TaskName = $TaskName } } }
function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess = $true)] param($TaskName) $script:tasks.Remove($TaskName) }
function Setup {
    $out = @(Invoke-Setup 6>&1)
    $codes = @($out | Where-Object { $_ -is [int] })
    $other = @($out | Where-Object { $_ -isnot [int] -and $_ -isnot [System.Management.Automation.InformationRecord] })
    $text = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $(if ($codes.Count -eq 1 -and $other.Count -eq 0) { $codes[0] } else { "leaked: $out" }); Text = $text }
}
function Plain([Security.SecureString]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

Assert ((Plain (ConvertTo-Unspaced (ConvertTo-SecureString "abcd efgh ijkl mnop" -AsPlainText -Force))) -eq "abcdefghijklmnop") "app password: Google's spaces are dropped"

$script:vol = $volOk; $script:dsk = $disks; $script:mailFails = $false
foreach ($a in @("not-an-address", "me@gmail.com", "abcd efgh ijkl mnop")) { $script:answers.Enqueue($a) }
$r = Setup
$installed = Join-Path $StateDir "check-mirror.ps1"
Assert ($r.Code -eq 0) "setup returns 0 and nothing else: $($r.Code)"
Assert ((Test-Path $installed) -and (Get-Content $installed -Raw) -eq (Get-Content (Join-Path $PSScriptRoot "check-mirror.ps1") -Raw)) "the check is copied to ProgramData\MirrorCheck"
Assert ($r.Text -match "Volume 4     R   Mirror" -and $r.Text -match "Disk 2    Online" -and $r.Text -match "finds no problem") "diskpart's lines for R: and the disks are shown, and the verdict"
Assert ($r.Text -match "not an email address") "a mistyped address is asked again"
$cred = Microsoft.PowerShell.Utility\Import-Clixml -Path (Join-Path $StateDir "mail.xml")
Assert ($cred.UserName -eq "me@gmail.com" -and (Plain $cred.Password) -eq "abcdefghijklmnop") "mail.xml holds the address and the app password without spaces"
Assert ($script:alerts.Count -eq 1 -and $script:alerts[0].Script -eq $installed -and $script:alerts[0].Address -eq "me@gmail.com") "the test alert runs the installed check with the address"
Assert ($r.Text -match "Gmail accepted the test email") "a sent test email is confirmed"
$t = $script:tasks["Check R mirror"]
Assert ($null -ne $t -and $t.Action.Execute -eq "powershell.exe" -and $t.Action.Argument -eq "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installed`" -Drive R -To me@gmail.com") "daily task runs the installed check with the address: $($t.Action.Argument)"
Assert ($t.Principal.UserId -eq "DESKTOP\user" -and $t.Principal.LogonType -eq "Interactive" -and $t.Principal.RunLevel -eq "Highest") "tasks run as you, signed in, elevated"
Assert ($t.Trigger.Count -eq 2 -and $t.Trigger[0].Daily -and $t.Trigger[0].At -eq "9am" -and $t.Trigger[1].AtLogOn -and $t.Trigger[1].User -eq "DESKTOP\user") "daily at 9:00 and at your sign-in"
$ok = $script:tasks["Check R mirror (OK email)"]
Assert ($null -ne $ok -and $ok.Action.Argument -eq "$($t.Action.Argument) -Heartbeat" -and $ok.Trigger[0].Weekly -and $ok.Trigger[0].Weeks -eq 4) "OK email every 4 weeks"

$script:mailFails = $true
foreach ($a in @("me@gmail.com", "wrong")) { $script:answers.Enqueue($a) }
$r = Setup
Assert ($r.Code -eq 0 -and $r.Text -match "The email failed: .*535" -and $r.Text -match "run setup again") "a failed test email is reported with the reason; setup still schedules"
$script:mailFails = $false

$script:answers.Enqueue("")
$r = Setup
Assert ($r.Code -eq 0 -and $r.Text -match "No email" -and $script:tasks["Check R mirror"].Action.Argument -notmatch "-To" -and -not $script:tasks.ContainsKey("Check R mirror (OK email)")) "no email: pop-up and log only, OK-email task removed"

$script:vol = $volFailed
$script:answers.Enqueue("")
$r = Setup
Assert ($r.Code -eq 0 -and $r.Text -match "PROBLEM: Volume R: .*Failed Rd" -and $r.Text -match "misreads") "a problem found during setup is shown, with what to do if Disk Management disagrees"
$script:vol = $volOk

function Test-Administrator { $false }
$before = $script:alerts.Count
$r = Setup
Assert ($r.Code -eq 1 -and $r.Text -match "as Administrator" -and $script:alerts.Count -eq $before) "not elevated: stops and says how to open an Administrator window"
function Test-Administrator { $true }

$script:tasks["Check R mirror (OK email)"] = "x"
$Uninstall = $true
$r = Setup
$Uninstall = $false
Assert ($r.Code -eq 0 -and $script:tasks.Count -eq 0 -and -not (Test-Path $StateDir)) "-Uninstall removes both tasks and the folder"

Remove-Item -Path $env:ProgramData -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Output "$fail FAILED"; exit 1 } else { Write-Output "all passed" }
