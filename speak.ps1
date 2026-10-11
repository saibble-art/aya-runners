# AYA, OUT LOUD
#
# Speaks through the machine's speakers instead of sending a Telegram voice
# note. Sara's objection, 2026-08-09: a voice note means she has to remember
# to open the chat and press play, which is not hearing something, it is being
# notified that a thing exists.
#
# This is the part of "just say it vocally" that needs no new dependency and no
# new vendor. Latency to speak is under a second because there is no upload,
# no download, and no message to open.
#
#   powershell -File speak.ps1 -Text "Zack replied about the portal."
#   powershell -File speak.ps1 -Text "..." -Chime      # short tone first
#
# Silent hours are respected: nothing is spoken outside SPEAK_START..SPEAK_END
# in secrets.env, because an agent that talks at 2am gets muted permanently.

param(
    [Parameter(Mandatory = $true)][string]$Text,
    [switch]$Chime,
    [switch]$Force,          # ignore silent hours
    [int]$Rate = 1
)

$ErrorActionPreference = 'Continue'
$runlog = "C:\Users\saraa\.aya\runner.log"
function Log([string]$m) {
    Add-Content -LiteralPath $runlog -Encoding utf8 `
        -Value ("{0} | runner | speak {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# ---------- silent hours ----------
$startH = 7; $endH = 21
$sf = "C:\Users\saraa\.aya\secrets.env"
if (Test-Path -LiteralPath $sf) {
    foreach ($l in Get-Content -LiteralPath $sf) {
        if ($l -match '^\s*SPEAK_START\s*=\s*(\d{1,2})') { $startH = [int]$Matches[1] }
        if ($l -match '^\s*SPEAK_END\s*=\s*(\d{1,2})')   { $endH   = [int]$Matches[1] }
    }
}
$h = (Get-Date).Hour
if (-not $Force -and ($h -lt $startH -or $h -ge $endH)) {
    Log "SUPPRESSED (silent hours $startH to $endH): $Text"
    exit 0
}

# ---------- is she even here ----------
# Speaking to an empty room is not delivery. If the session is locked, fall
# through silently and let the Telegram path carry it instead, so nothing is
# lost, it just arrives where she can see it later.
$locked = $false
try {
    $logon = (Get-Process logonui -ErrorAction SilentlyContinue)
    if ($logon) { $locked = $true }
} catch { }
if ($locked -and -not $Force) {
    Log "SUPPRESSED (session locked, Telegram carries it instead): $Text"
    exit 2
}

try {
    if ($Chime) {
        # Two short notes, deliberately unlike a Windows alert, so Sara learns
        # this specific sound means Aya is about to talk and can ignore it if
        # she is mid-thought.
        [console]::Beep(880, 90); Start-Sleep -Milliseconds 40; [console]::Beep(1180, 110)
    }
    # Michelle via voice.ps1, with the SAPI fallback built in there. Sara
    # called the old SAPI voice robotic and she was right, so it is now only
    # the offline safety net.
    . "C:\Users\saraa\.aya\voice.ps1"
    $r = New-AyaSpeech -Text $Text
    if (-not $r.ok) { Log "FAILED: no audio rendered"; exit 1 }
    $played = Invoke-AyaPlay -Path $r.path
    Remove-Item -LiteralPath $r.path -Force -ErrorAction SilentlyContinue
    if ($played) { Log "spoke aloud via $($r.engine): $Text"; exit 0 }
    Log "rendered via $($r.engine) but playback failed: $Text"
    exit 1
} catch {
    Log "FAILED to speak: $($_.Exception.Message)"
    exit 1
}
