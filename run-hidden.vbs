' Aya hidden launcher. Runs a PowerShell script with NO visible window.
' Task Scheduler running powershell.exe directly flashes a console window each
' time (annoying when the inbox fires every 2 minutes). wscript's Run with
' window style 0 starts PowerShell fully hidden, so nothing pops up.
'
' Usage:  wscript.exe run-hidden.vbs "C:\path\to\script.ps1" [args...]
Dim sh, cmd, i
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
For i = 0 To WScript.Arguments.Count - 1
  cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
' 0 = hidden window, False = do not wait
sh.Run cmd, 0, False
