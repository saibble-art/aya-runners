# Register the Aya sweep as a scheduled task.
#
# Every 30 minutes, 07:03 to 18:03, weekdays. Central, the machine's own time.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\install-sweep.ps1
#
# Uninstall:  Unregister-ScheduledTask -TaskName "Aya Sweep" -Confirm:$false

$ErrorActionPreference = 'Stop'
$name   = "Aya Sweep"
$script = "C:\Users\saraa\.aya\sweep.ps1"
if (-not (Test-Path -LiteralPath $script)) { throw "missing $script" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

# 07:03 not 07:00. Weekdays only, per IDENTITY.md.
$trigger = New-ScheduledTaskTrigger -Weekly `
           -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At "07:03"

# Repeat every 30 minutes for 11 hours, so the last run lands at 18:03.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At "07:03" `
    -RepetitionInterval (New-TimeSpan -Minutes 30) `
    -RepetitionDuration (New-TimeSpan -Hours 11)).Repetition

# MultipleInstances IgnoreNew is load bearing. A sweep can take two minutes.
# Two sweeps sharing one cursor file would break at-most-once, which is the
# rule that stops Sara being told the same thing twice.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -MultipleInstances IgnoreNew

# Interactive, so no Windows password has to be stored. The desktop must be
# logged in. That limitation is what would push the runner to n8n later.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Write-Output "Task '$name' exists. Replacing."
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Aya's sweep. Outlook, Discord, Slack, both calendars, compared against TASKS.md. Quiet rule: says nothing unless Sara is needed. Drafts only, sends nothing outbound. Log: C:\Users\saraa\.aya\runner.log" | Out-Null

Write-Output "Registered '$name'."
$t = Get-ScheduledTask -TaskName $name
$i = Get-ScheduledTaskInfo -TaskName $name
Write-Output ""
Write-Output "State    : $($t.State)"
Write-Output "Next run : $($i.NextRunTime)"
Write-Output "Repeat   : every 30 min for 11 hours from 07:03, Mon to Fri"
