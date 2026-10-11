# Register the Aya heartbeat as a real Windows scheduled task.
#
# Daily at 06:07. Off-minute on purpose, not 06:00.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\install-heartbeat.ps1
#
# Uninstall:  Unregister-ScheduledTask -TaskName "Aya Heartbeat" -Confirm:$false

$ErrorActionPreference = 'Stop'
$name   = "Aya Heartbeat"
$script = "C:\Users\saraa\.aya\heartbeat.ps1"

if (-not (Test-Path -LiteralPath $script)) { throw "missing $script" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

$trigger = New-ScheduledTaskTrigger -Daily -At "06:07"

# StartWhenAvailable: if the machine was asleep or off at 06:07, run as soon
#   as it is available instead of skipping the day. A skipped day would look
#   identical to a dead runner, which is the exact confusion this job exists
#   to prevent.
# WakeToRun: wake the machine rather than miss it.
# RestartCount: transient network failure should not cost the day's heartbeat.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

# Interactive logon type, deliberately. "Run whether user is logged on or not"
# would require storing Sara's Windows password, and the connectors are
# authenticated in her user profile anyway. Trade-off: the desktop must be
# logged in. That is the known limitation of running on this machine, and it
# is the thing that would push the runner to n8n later.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Limited

$existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if ($existing) {
    Write-Output "Task '$name' exists. Replacing."
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Aya's dead man's switch. One Telegram message daily plus a connector probe. Its ABSENCE is the alarm. See C:\Users\saraa\.aya\runner.log" | Out-Null

Write-Output "Registered '$name'."
$t = Get-ScheduledTask -TaskName $name
$i = Get-ScheduledTaskInfo -TaskName $name
Write-Output ""
Write-Output "State      : $($t.State)"
Write-Output "Next run   : $($i.NextRunTime)"
Write-Output "Last run   : $($i.LastRunTime)"
Write-Output "Last result: $($i.LastTaskResult)"
