# Register the Aya weekly check as a scheduled task.
#
# Fridays at 15:00, the machine's own time. Accepted by Sara 2026-08-08;
# scheduled 2026-08-14 after the first Friday arrived with nothing to run it.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\install-weekly.ps1
#
# Uninstall:  Unregister-ScheduledTask -TaskName "Aya Weekly" -Confirm:$false

$ErrorActionPreference = 'Stop'
$name   = "Aya Weekly"
$script = "C:\Users\saraa\.aya\weekly.ps1"
if (-not (Test-Path -LiteralPath $script)) { throw "missing $script" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At "15:00"

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Write-Output "Task '$name' exists. Replacing."
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Aya's weekly status. Five sections per IDENTITY.md, full report to Brain/notes/weekly/, one Telegram message, always sent. Log: C:\Users\saraa\.aya\runner.log" | Out-Null

Write-Output "Registered '$name'."
$t = Get-ScheduledTask -TaskName $name
$i = Get-ScheduledTaskInfo -TaskName $name
Write-Output ""
Write-Output "State    : $($t.State)"
Write-Output "Next run : $($i.NextRunTime)"
