# Register the listener (fast path) and the inbox (safety net).
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\install-listener.ps1
#
# Two tasks, on purpose:
#   Aya Listener  starts at logon, stays running, answers in seconds
#   Aya Inbox     every 10 min, stands down while the listener is alive
#
# The listener is not a scheduled job in the normal sense, it is a resident
# process. The inbox exists because a resident process can die and Sara should
# never lose a message just because a window closed.

$ErrorActionPreference = 'Stop'
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Limited

# ---------------- Listener ----------------
$name = "Aya Listener"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\Users\saraa\.aya\listen.ps1`""

# At logon, plus a delay so the MCP connectors have time to come up. The
# connector race is real: two identical runs two minutes apart, the first
# reached zero tools and the second reached all of them.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Delay = "PT2M"

# No ExecutionTimeLimit: this is meant to run forever.
# RestartCount brings it back if it crashes, which is the whole point of
# preferring a supervised task over Sara starting a script by hand.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Aya, resident. Telegram long-poll, conversational, replies in seconds. Writes a heartbeat to .aya\state\listener-alive.txt so Aya Inbox stands down while this is running." | Out-Null
Write-Output "Registered '$name' (at logon, 2 min delay, restarts on crash)"

# ---------------- Inbox, the safety net ----------------
$name2 = "Aya Inbox"
$action2 = New-ScheduledTaskAction -Execute "powershell.exe" `
           -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Users\saraa\.aya\inbox.ps1`""

# Every 10 minutes, 07:04 to 22:04, EVERY day. Tasks arrive on weekends too,
# unlike the sweep which is a weekday working-hours job.
$trigger2 = New-ScheduledTaskTrigger -Daily -At "07:04"
$trigger2.Repetition = (New-ScheduledTaskTrigger -Once -At "07:04" `
    -RepetitionInterval (New-TimeSpan -Minutes 10) `
    -RepetitionDuration (New-TimeSpan -Hours 15)).Repetition

$settings2 = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $name2 -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $name2 -Confirm:$false
}
Register-ScheduledTask -TaskName $name2 -Action $action2 -Trigger $trigger2 `
    -Settings $settings2 -Principal $principal `
    -Description "Safety net for Aya's Telegram inbox. Exits immediately if the listener heartbeat is fresh, so the two never drain the same message queue. Costs nothing when the inbox is empty: it exits before any model call." | Out-Null
Write-Output "Registered '$name2' (every 10 min, 07:04 to 22:04, daily)"

Write-Output ""
Get-ScheduledTask -TaskName "Aya *" | ForEach-Object {
    $i = Get-ScheduledTaskInfo -TaskName $_.TaskName
    "{0,-14} {1,-8} next {2}" -f $_.TaskName, $_.State, $i.NextRunTime
}
