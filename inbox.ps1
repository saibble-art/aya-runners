# AYA INBOX
#
# The half that was missing until 2026-08-09. Aya could talk to Sara but had
# no way to hear her. This drains Sara's Telegram messages, files tasks into
# TASKS.md, answers questions, and replies.
#
# Cheap by design: if the inbox is empty it exits before any model call, so
# running every 10 minutes costs nothing when Sara is not talking.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\inbox.ps1
#   -DryRun   read the messages, call the model, write nothing, send nothing

param([switch]$DryRun)

$ErrorActionPreference = 'Continue'

# Claude speaks UTF-8; PowerShell 5.1 defaults to the OEM codepage on both
# sides of a native pipe. Without these two lines every non-ASCII character
# in prompts and replies is garbled. Added 2026-08-17.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$dir     = "C:\Users\saraa\.aya"
$state   = Join-Path $dir "state"
$runlog  = Join-Path $dir "runner.log"
$promptF = Join-Path $dir "prompts\inbox.md"
$claude  = "C:\Users\saraa\.local\bin\claude.exe"
$tasksF  = "C:\Users\saraa\OneDrive\Aya\TASKS.md"
$ayaLog  = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"

if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Path $state -Force | Out-Null }
function Log([string]$m) {
    $line = "{0} | runner | inbox {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

. (Join-Path $dir "tg.ps1")
. (Join-Path $dir "lane.ps1")
$sec = Get-AyaSecrets

# ---------- stand down if the listener is alive ----------
# Two processes draining one Telegram offset would each see half of Sara's
# messages and neither would know it. One writer per state file. The listener
# is the fast path; this scheduled run is the safety net for when it is not
# running. A heartbeat older than 2 minutes means the listener is gone.
$beatF = Join-Path $state "listener-alive.txt"
if (Test-Path -LiteralPath $beatF) {
    try {
        $beat = [datetime]::Parse((Get-Content -LiteralPath $beatF -Raw).Trim())
        if ((New-TimeSpan -Start $beat -End (Get-Date)).TotalMinutes -lt 2) { exit 0 }
        Log "listener heartbeat is stale ($($beat.ToString('HH:mm:ss'))), taking over"
    } catch { Log "listener heartbeat unreadable, taking over" }
}

# ---------- drain ----------
# NoClaim on a dry run, so testing does not consume real instructions.
if ($DryRun) { $in = Get-AyaUpdates -Secrets $sec -NoClaim } else { $in = Get-AyaUpdates -Secrets $sec }

if (-not $in.ok) { Log "FAILED to read Telegram: $($in.detail)"; exit 1 }

# The empty case is the common case. Exit before spending anything, and do not
# write a log line either, or the log becomes 90 identical entries a day and
# stops being readable.
if ($in.messages.Count -eq 0) { exit 0 }

Log "START | $($in.messages.Count) message(s) from Sara"
$said = ($in.messages | ForEach-Object { "[$($_.date)] $($_.text)" }) -join "`n"
foreach ($m in $in.messages) { Log "  heard: $($m.text)" }

# ---------- pull live Discord so Aya can answer team questions in chat ----------
# Until 2026-08-10 Aya in chat had no Discord and answered "no Discord tool
# available". Now every reply carries a fresh snapshot of every readable channel.
$discord = try { Get-AyaDiscordSnapshot -Secrets $sec -PerChannel 10 } catch { "Discord pull failed: $($_.Exception.Message)" }
Log "  pulled live Discord snapshot ($($discord.Length) chars)"

# ---------- working memory: recent conversation + recent log ----------
# The point of the vault is that a fresh process is current in seconds. That is
# only true if it READS the memory before it acts. This is that read step.
# Without it, every reply is a stranger who never opened the notebook, which is
# exactly why Sara had to keep repeating herself.
$threadF   = "C:\Users\saraa\OneDrive\Aya\Brain\conversations\thread.md"
$threadDir = Split-Path $threadF
if (-not (Test-Path -LiteralPath $threadDir)) { New-Item -ItemType Directory -Path $threadDir -Force | Out-Null }
$thread = ""
if (Test-Path -LiteralPath $threadF) {
    $tl = Get-Content -LiteralPath $threadF
    if ($tl.Count -gt 90) { $tl = $tl[-90..-1] }
    $thread = ($tl -join "`n")
}
$recentLog = ""
if (Test-Path -LiteralPath $ayaLog) {
    $ll = Get-Content -LiteralPath $ayaLog
    if ($ll.Count -gt 45) { $ll = $ll[-45..-1] }
    $recentLog = ($ll -join "`n")
}
Log "  loaded working memory (thread $($thread.Length) chars, log $($recentLog.Length) chars)"

# ---------- ask Aya ----------
$prompt = (Get-Content -LiteralPath $promptF -Raw).Replace('{{SARA_SAID}}', $said)
$prompt += "`n`n---`n`nLIVE DISCORD, pulled just now. Use this for any team or Discord question. You DO have Discord access, this is it. Never say you have no Discord tool.`n`n$discord"
$prompt += "`n`n---`n`nRECENT CONVERSATION with Sara, oldest first, newest last. This is your working memory of what the two of you have been doing. Read it so she never has to repeat herself. If a message refers back to something ('them', 'that', 'the one we discussed', 'like I said'), resolve it from here. Only ask her to clarify if it is genuinely not answerable from this thread or your log.`n`n$thread"
$prompt += "`n`n---`n`nYOUR RECENT LOG, oldest first, newest last. This is what actually happened across recent days. Read it before you ever say you do not know something or did not do something.`n`n$recentLog"

# DraftsOn TRUE so Aya can create Outlook drafts in conversation, the same as
# the listener. With it false she wrongly told Sara she could not draft an email.
$allow = (Get-AyaAllowList -DraftsOn:$true) -join ','
$deny  = (Get-AyaDenyList  -DraftsOn:$true) -join ','

$raw = ""
try {
    $raw = $prompt | & $claude -p `
              --allowedTools $allow --disallowedTools $deny `
              --add-dir "C:\Users\saraa\OneDrive\Aya" `
              --permission-mode dontAsk --model opus 2>&1 | Out-String
} catch { Log "FAILED: claude threw: $($_.Exception.Message)"; exit 1 }

$json = $null
$m = [regex]::Match($raw, '(?s)\{.*\}')
if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { $json = $null } }

if (-not $json) {
    $snip = ($raw -replace '\s+', ' '); if ($snip.Length -gt 400) { $snip = $snip.Substring(0, 400) }
    Log "FAILED: no parseable JSON. Model said: $snip"
    # Sara spoke and is waiting. Failing silently here is the worst option.
    if (-not $DryRun) {
        $null = Send-AyaText -Secrets $sec -Text "I got your message but could not process it this run. It is logged and I will not lose it. Try rephrasing, or tell Claude to check the runner log."
    }
    exit 1
}

# ---------- file the tasks ----------
# PowerShell writes TASKS.md, not Aya. She has no Write tool, deliberately, so
# the only path into her own task list is a structured return value the runner
# validates. That is what stops a stray sentence becoming a task.
$filed = 0
if ($json.tasks -and $json.tasks.Count -gt 0 -and -not $DryRun) {
    $lines = Get-Content -LiteralPath $tasksF
    foreach ($t in $json.tasks) {
        $section = "$($t.section)".Trim()
        if ([string]::IsNullOrWhiteSpace($section)) { $section = "This Week" }

        $note = "$($t.note)".Trim()
        $ven  = "$($t.venture)".Trim()
        if ([string]::IsNullOrWhiteSpace($ven)) { $ven = "Saibble" }
        # The format the productivity dashboard parses. Do not change it.
        $entry = "- [ ] **$("$($t.title)".Trim())**"
        if ($note) { $entry += " - $note" }
        $entry += " ($ven)"

        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^##\s+' + [regex]::Escape($section) + '\s*$')) { $idx = $i; break }
        }
        if ($idx -lt 0) {
            Log "  WARN: section '$section' not found, filing under This Week"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^##\s+This Week\s*$') { $idx = $i; break }
            }
        }
        if ($idx -lt 0) { Log "  ERROR: could not file '$($t.title)', no target section"; continue }

        # Insert at the END of the section, so newest sits at the bottom and
        # the order Sara already knows is preserved.
        $ins = $idx + 1
        while ($ins -lt $lines.Count -and $lines[$ins] -notmatch '^##\s') { $ins++ }
        while ($ins -gt $idx + 1 -and [string]::IsNullOrWhiteSpace($lines[$ins - 1])) { $ins-- }

        $lines = @($lines[0..($ins - 1)]) + @($entry) + @($lines[$ins..($lines.Count - 1)])
        $filed++
        Log "  filed [$section] $($t.title)"
    }
    Set-Content -LiteralPath $tasksF -Value $lines -Encoding utf8
} elseif ($json.tasks -and $json.tasks.Count -gt 0) {
    foreach ($t in $json.tasks) { Log "  DRYRUN would file [$($t.section)] $($t.title)" }
}

if ($json.facts_to_record) {
    foreach ($f in $json.facts_to_record) { Log "  fact from Sara: $f" }
}
if ($json.unclear) {
    foreach ($u in $json.unclear) { Log "  unclear: $u" }
}
if (-not $DryRun -and $json.log) {
    Add-Content -LiteralPath $ayaLog -Encoding utf8 `
        -Value ("{0} | Aya | inbox: {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $json.log)
}

# ---------- reply ----------
if ($DryRun) {
    Log "FINISH DRYRUN | filed nothing, sent nothing"
    Write-Output "----- would reply -----"; Write-Output $json.answers
    Write-Output "----- would speak -----"; Write-Output $json.voice_summary
    exit 0
}

$reply = "$($json.answers)".Trim()
if (-not $reply) { $reply = "Got it. Nothing to file and nothing to answer." }

$t = Send-AyaText -Secrets $sec -Text $reply
if ($t.ok) { Log "replied | $($t.detail)" } else { Log "reply FAILED | $($t.detail)" }

# ---------- capture the exchange into the vault ----------
# The write side of the memory loop. Everything the two of you do is retained,
# so the next fresh process reads it back instead of starting blind. This is
# what makes her aware of last week without Sara re-explaining.
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$exchange = "## $stamp`n`n**Sara:**`n$said`n`n**Aya:**`n$reply`n"
try { Add-Content -LiteralPath $threadF -Value $exchange -Encoding utf8 }
catch { Log "  thread append failed: $($_.Exception.Message)" }

# Voice second, so the text is already there to read if the audio fails.
# Sara asked for audio for the picture and text for the detail.
$spoken = "$($json.voice_summary)".Trim()
if ($spoken) {
    $v = Send-AyaVoice -Secrets $sec -Text $spoken
    if ($v.ok) { Log "spoke | $($v.detail)" } else { Log "voice FAILED | $($v.detail)" }
}

Log "FINISH ok | $filed task(s) filed"
if (-not $t.ok) { exit 1 }
exit 0
