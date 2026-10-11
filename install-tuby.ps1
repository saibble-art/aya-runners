# Register Tuby's weekly production run as a scheduled task.
#
# Tuesdays 4:00am, the machine's own time, matching the retired cloud
# schedule. Registered 2026-08-15 when Sara lifted the build hold.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\install-tuby.ps1
#
# Uninstall:  Unregister-ScheduledTask -TaskName "Aya Tuby" -Confirm:$false

$ErrorActionPreference = 'Stop'
$name   = "Aya Tuby"
$script = "C:\Users\saraa\.aya\tuby.ps1"
if (-not (Test-Path -LiteralPath $script)) { throw "missing $script" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Tuesday -At "04:00"

# A full production run reads the strategy, researches five lanes, and
# writes a script. 45 minutes is generous; the median should be far less.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 45) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Write-Output "Task '$name' exists. Replacing."
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Tuby's weekly YouTube production run. Research to publish checklist, never publishes. Package to OneDrive\Aya\Files\Tuby, run log to Brain\notes\agents\tuby-run-log.md, one Telegram summary. Log: C:\Users\saraa\.aya\runner.log" | Out-Null

Write-Output "Registered '$name'."
$t = Get-ScheduledTask -TaskName $name
$i = Get-ScheduledTaskInfo -TaskName $name
Write-Output "State    : $($t.State)"
Write-Output "Next run : $($i.NextRunTime)"
