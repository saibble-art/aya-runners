# Register Max's weekly Sassy and Secure content drop as a scheduled task.
#
# Sundays 4:30am, the machine's own time, matching the retired fleet slot so
# the package is waiting when the week starts.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\install-max.ps1
#
# Uninstall:  Unregister-ScheduledTask -TaskName "Aya Max" -Confirm:$false

$ErrorActionPreference = 'Stop'
$name   = "Aya Max"
$script = "C:\Users\saraa\.aya\max.ps1"
if (-not (Test-Path -LiteralPath $script)) { throw "missing $script" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "04:30"

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
    -Description "Max's weekly Sassy and Secure content drop: next lesson, four community posts, image prompts, preview. Never publishes. Package to OneDrive\Aya\Files\Max, run log to Brain\notes\agents\max-run-log.md. Log: C:\Users\saraa\.aya\runner.log" | Out-Null

Write-Output "Registered '$name'."
$t = Get-ScheduledTask -TaskName $name
$i = Get-ScheduledTaskInfo -TaskName $name
Write-Output "State    : $($t.State)"
Write-Output "Next run : $($i.NextRunTime)"
