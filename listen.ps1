# AYA LISTENER
#
# Aya, always on, holding a conversation instead of waking on a timer.
#
# This is NOT a second agent. Sara's own rule in IDENTITY.md is to absorb work
# into Aya rather than spawn agents, and a second agent would inherit exactly
# the same two delays anyway. Same Aya, second run mode:
#
#   listener  always on, conversational, answers Sara       <- this file
#   sweep     scheduled, unprompted, watches the world      <- sweep.ps1
#
# The two delays, addressed separately:
#   PICKUP   Telegram long-poll, timeout 25s. Sara's message arrives in ~1s
#            instead of waiting up to 10 minutes for a scheduled run.
#   REPLY    conversation continuity via --resume, so Aya does not re-read her
#            five identity files on every turn. First turn is slow, the rest
#            are a fraction of it.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\listen.ps1
#   Ctrl+C to stop. Stops cleanly and removes its heartbeat.

param([int]$PollSeconds = 25)

$ErrorActionPreference = 'Continue'

# Claude speaks UTF-8; PowerShell 5.1 defaults to the OEM codepage on both
# sides of a native pipe. Without these two lines every non-ASCII character
# in prompts and replies is garbled. Added 2026-08-17 after Sara received
# mojibake over Telegram.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$dir     = "C:\Users\saraa\.aya"
$state   = Join-Path $dir "state"
$runlog  = Join-Path $dir "runner.log"
$beatF   = Join-Path $state "listener-alive.txt"
$sessF   = Join-Path $state "listener-session.txt"
$promptF = Join-Path $dir "prompts\chat.md"
$claude  = "C:\Users\saraa\.local\bin\claude.exe"
$tasksF  = "C:\Users\saraa\OneDrive\Aya\TASKS.md"
$ayaLog  = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"

if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Path $state -Force | Out-Null }

# KILL SWITCH. Added 2026-08-10. While the resident listener is disabled, every
# instance (including anything that respawns it) exits instantly and harmlessly.
# The scheduled "Aya Inbox" task is the responder. Delete this flag file to
# re-enable the resident listener once its duplicate/hang issues are fully fixed.
if (Test-Path -LiteralPath (Join-Path $state "listener-disabled.txt")) { exit 0 }

function Log([string]$m) {
    $line = "{0} | runner | listen {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

. (Join-Path $dir "tg.ps1")
. (Join-Path $dir "lane.ps1")
$sec   = Get-AyaSecrets

# SINGLETON GUARD. Added 2026-08-10 after duplicate listeners fought over the
# Telegram cursor and one hung, leaving Sara without replies for a while.
# Exactly one listener may run. On startup:
#   - Heartbeat FRESH (< 75s): another listener is alive and healthy, so this
#     instance exits immediately. Whatever keeps respawning a listener becomes a
#     harmless no-op.
#   - Heartbeat STALE (>= 75s): the running listener hung or died, so this
#     instance takes over. That makes the respawner a self-healing supervisor.
# Either way it then kills any other listen.ps1 process so only one survives.
$mine = $PID
if (Test-Path -LiteralPath $beatF) {
    try {
        $b = [datetime]::Parse((Get-Content -LiteralPath $beatF -Raw).Trim())
        $ageSec = [math]::Round((New-TimeSpan -Start $b -End (Get-Date)).TotalSeconds)
        if ($ageSec -lt 75) {
            Log "another listener is alive (heartbeat ${ageSec}s old); exiting to avoid a duplicate"
            exit 0
        }
        Log "stale heartbeat (${ageSec}s); taking over from a hung or dead listener"
    } catch { }
}
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*listen.ps1*' -and $_.ProcessId -ne $mine } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
} catch { }

# DraftsOn TRUE here. This was $false until 2026-08-09 and it made no sense:
# the scheduled sweep could create Outlook drafts but Aya in conversation could
# not, so when Sara asked her to draft an email she correctly said she was
# unable and pasted the text into TASKS.md instead. Sara called that strange
# and she was right. Same agent, same rail, same capability.
#
# A draft is still not a send. outlook_send_mail and outlook_send_draft stay
# denied in lane.ps1 regardless of this flag.
$allow = (Get-AyaAllowList -DraftsOn:$true) -join ','
$deny  = (Get-AyaDenyList  -DraftsOn:$true) -join ','
$base  = Get-Content -LiteralPath $promptF -Raw

# The session id is what makes turn two fast. It is dropped on any parse
# failure, because a poisoned session is worse than a slow first turn.
$session = $null
if (Test-Path -LiteralPath $sessF) { $session = (Get-Content -LiteralPath $sessF -Raw).Trim() }

Log "START | listening, long-poll ${PollSeconds}s"

# Say what she can actually do. The first version of this said "talk to me
# normally", Sara reasonably sent a voice note, and Aya had to admit she could
# not hear it. A greeting that overstates the capability is the same mistake as
# a file that documents a feature nobody built.
$hasStt = (Test-Path -LiteralPath "C:\Users\saraa\.aya\transcribe.py") -and
          (Test-Path -LiteralPath "C:\Users\saraa\AppData\Local\Programs\Python\Python313\python.exe")
if ($hasStt) {
    $greet = "I am listening. Text or voice notes both work now, and I answer in seconds instead of waiting for the next sweep."
} else {
    $greet = "I am listening. Text only for now, I cannot hear voice notes yet. I answer in seconds instead of waiting for the next sweep."
}
$null = Send-AyaText -Secrets $sec -Text $greet

# Writes TASKS.md on Aya's behalf. She has no Write tool by design, so the only
# route into her task list is a structured return the runner validates.
function Add-Task {
    param($Task)
    $lines = Get-Content -LiteralPath $tasksF
    $section = "$($Task.section)".Trim(); if (-not $section) { $section = "This Week" }
    $note = "$($Task.note)".Trim()
    $ven  = "$($Task.venture)".Trim(); if (-not $ven) { $ven = "Saibble" }
    $entry = "- [ ] **$("$($Task.title)".Trim())**"
    if ($note) { $entry += " - $note" }
    $entry += " ($ven)"

    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^##\s+' + [regex]::Escape($section) + '\s*$')) { $idx = $i; break }
    }
    if ($idx -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s+This Week\s*$') { $idx = $i; break } }
    }
    if ($idx -lt 0) { return $false }
    $ins = $idx + 1
    while ($ins -lt $lines.Count -and $lines[$ins] -notmatch '^##\s') { $ins++ }
    while ($ins -gt $idx + 1 -and [string]::IsNullOrWhiteSpace($lines[$ins - 1])) { $ins-- }
    $lines = @($lines[0..($ins - 1)]) + @($entry) + @($lines[$ins..($lines.Count - 1)])
    Set-Content -LiteralPath $tasksF -Value $lines -Encoding utf8
    return $true
}

# Replaces the note on an existing task instead of filing a near-duplicate.
# Added 2026-08-09 after Sara refined one job across four messages and got four
# tasks. Matching is on a distinctive slice of the title, and it refuses to act
# when the match is ambiguous, because editing the wrong task silently is worse
# than adding a duplicate loudly.
function Update-Task {
    param([string]$MatchTitle, [string]$Note, [string]$Section)

    $lines = Get-Content -LiteralPath $tasksF
    $needle = "$MatchTitle".Trim()
    if ($needle.Length -lt 8) { return "match_title too short to be safe: '$needle'" }

    $hits = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*- \[[ xX]\]' -and $lines[$i] -like "*$needle*") { $hits += $i }
    }
    if ($hits.Count -eq 0) { return "no task matched '$needle'" }
    if ($hits.Count -gt 1) { return "'$needle' matched $($hits.Count) tasks, refusing to guess which" }

    $idx = $hits[0]
    # Keep the original title and venture, replace only the note. The title is
    # what Sara recognises; the note is what changes as a job progresses.
    $title = ''
    if ($lines[$idx] -match '\*\*(.+?)\*\*') { $title = $Matches[1] }
    $ven = 'Saibble'
    if ($lines[$idx] -match '\(([^()]+)\)\s*$') { $ven = $Matches[1] }
    $box = '- [ ]'
    if ($lines[$idx] -match '^\s*- \[[xX]\]') { $box = '- [x]' }

    $new = "$box **$title**"
    if ("$Note".Trim()) { $new += " - $("$Note".Trim())" }
    $new += " ($ven)"
    $lines[$idx] = $new
    Set-Content -LiteralPath $tasksF -Value $lines -Encoding utf8
    return $null
}

# Long content out of TASKS.md and into a real file. An email draft or a PRD
# pasted into a task note breaks the line-based format the dashboard parses.
function Write-AyaDoc {
    param($Doc)
    $inbox = "C:\Users\saraa\OneDrive\Aya\Files\_Inbox"
    if (-not (Test-Path -LiteralPath $inbox)) { New-Item -ItemType Directory -Path $inbox -Force | Out-Null }
    $name = "$($Doc.filename)".Trim()
    if (-not $name) { $name = "note-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".md" }
    $name = ($name -replace '[\\/:*?"<>|]', '-')
    if ($name -notmatch '\.\w{2,4}$') { $name += '.md' }
    $p = Join-Path $inbox ((Get-Date -Format 'yyyy-MM-dd') + "-" + $name)
    $body = "# $($Doc.title)`n`nDrafted by Aya $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Nothing has been sent.`n`n---`n`n$($Doc.body)`n"
    Set-Content -LiteralPath $p -Value $body -Encoding utf8
    return $p
}

try {
    while ($true) {
        # Heartbeat. inbox.ps1 checks this and stands down while the listener
        # is alive, so two processes never drain the same Telegram offset.
        # One writer per state file, the rule that survived the old fleet.
        Set-Content -LiteralPath $beatF -Value (Get-Date -Format 'o') -Encoding utf8

        # Long poll. Telegram holds the request open until a message arrives
        # or the timeout expires, so this costs one idle HTTP call per 25s and
        # returns within about a second of Sara hitting send.
        $tok = $sec['TELEGRAM_BOT_TOKEN']
        $off = 0
        $offF = Join-Path $state "telegram-offset.txt"
        if (Test-Path -LiteralPath $offF) {
            $raw = (Get-Content -LiteralPath $offF -Raw).Trim()
            if ($raw -match '^\d+$') { $off = [int]$raw }
        }
        $url = "https://api.telegram.org/bot$tok/getUpdates?timeout=$PollSeconds&allowed_updates=[`"message`"]"
        if ($off -gt 0) { $url += "&offset=$off" }

        try { $r = Invoke-RestMethod -Uri $url -TimeoutSec ($PollSeconds + 15) }
        catch { Log "poll error, retrying: $($_.Exception.Message)"; Start-Sleep -Seconds 5; continue }
        if (-not $r.ok -or -not $r.result -or $r.result.Count -eq 0) { continue }

        $maxId = $off - 1
        $msgs = @()
        foreach ($u in $r.result) {
            if ($u.update_id -gt $maxId) { $maxId = $u.update_id }
            if (-not $u.message) { continue }
            if ([string]$u.message.chat.id -ne [string]$sec['SARA_TELEGRAM_CHAT_ID']) { continue }
            $txt = $u.message.text
            if (-not $txt -and $u.message.caption) { $txt = $u.message.caption }
            # A video or a file sent straight to Telegram. The Bot API caps
            # downloads at 20MB, which is fine for a clip and useless for a
            # training recording, so the size limit is stated plainly rather
            # than discovered as a mystery failure.
            if (-not $txt -and ($u.message.video -or $u.message.document -or $u.message.video_note)) {
                $f = $u.message.video
                if (-not $f) { $f = $u.message.video_note }
                if (-not $f) { $f = $u.message.document }
                $mb = [math]::Round(($f.file_size / 1MB), 1)
                if ($f.file_size -gt 19MB) {
                    Log "  video sent, ${mb}MB, over the 20MB Telegram bot limit"
                    $txt = "[Sara sent a video of ${mb}MB. Telegram's bot API caps downloads at 20MB so you cannot fetch it. Tell her plainly: put the file in her Aya Files\_Inbox folder instead and you will pick it up, no size limit. Do not suggest Telegram again for a file this size.]"
                } else {
                    Log "  video sent, ${mb}MB, downloading"
                    $dl = Get-AyaTelegramFile -Secrets $sec -FileId $f.file_id
                    if ($dl.ok) {
                        Log "  dispatching watcher for $($dl.path)"
                        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', 'C:\Users\saraa\.aya\watch.ps1', '-Target', $dl.path
                        )
                        $null = Send-AyaText -Secrets $sec -Text "Got the video, ${mb} megabytes. Watching it now, I will message you with the notes."
                        continue
                    }
                    $txt = "[Sara sent a video but the download failed: $($dl.detail). Tell her and suggest the Files\_Inbox folder instead.]"
                }
            }
            if (-not $txt -and ($u.message.voice -or $u.message.audio)) {
                $vn = $u.message.voice; if (-not $vn) { $vn = $u.message.audio }
                Log "  voice note, $($vn.duration)s, transcribing"
                $tr = Get-AyaTranscript -Secrets $sec -FileId $vn.file_id -Duration $vn.duration
                if ($tr.ok) {
                    Log "  transcript: $($tr.text)"
                    $txt = "[voice note, transcribed] " + $tr.text
                } else {
                    Log "  transcription FAILED: $($tr.detail)"
                    $txt = "[Sara sent a voice note, $($vn.duration)s, and transcription failed: $($tr.detail). Tell her plainly and ask her to resend or type it.]"
                }
            }
            if ($txt) { $msgs += $txt.Trim() }
        }
        # Claim before processing. Telegram drops an update once acknowledged,
        # so a crash after replying but before claiming would replay forever.
        if ($maxId -ge $off) { Set-Content -LiteralPath $offF -Value ([string]($maxId + 1)) -Encoding utf8 }
        if ($msgs.Count -eq 0) { continue }

        $said = $msgs -join "`n"
        Log "heard: $said"

        # ---------- a video link short-circuits the conversation ----------
        # Watching takes about 45 seconds. Blocking the listener for that long
        # would delay every other message, so watch.ps1 is launched detached
        # and sends its own summary when it finishes. Sara gets an immediate
        # acknowledgement rather than a minute of silence.
        #
        # YouTube and Google Drive both handled. A Drive link only works if the
        # file is shared "anyone with the link"; a private one fails in the
        # watcher, which then tells Sara to use the Inbox folder. The
        # acknowledgement here is honest about that rather than promising a
        # result it may not deliver.
        $vidMatch = [regex]::Match($said, '(https?://\S*(?:youtube\.com|youtu\.be|drive\.google\.com)/\S+)')
        if ($vidMatch.Success) {
            $url = $vidMatch.Groups[1].Value.TrimEnd('.', ',', ')', ']')
            $isDrive = $url -match 'drive\.google\.com'
            Log "video link detected ($([string]$(if($isDrive){'drive'}else{'youtube'}))), dispatching watcher: $url"
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', 'C:\Users\saraa\.aya\watch.ps1',
                '-Target', $url
            )
            if ($isDrive) {
                $null = Send-AyaText -Secrets $sec -Text "Trying that Drive video now. If it is shared publicly I will send you the notes shortly. If it is private I cannot reach it, and I will tell you to drop the file in your Aya inbox folder instead."
            } else {
                $null = Send-AyaText -Secrets $sec -Text "Watching that now. I will message you when I have the notes."
            }
            continue
        }

        $t0 = [Diagnostics.Stopwatch]::StartNew()

        # First turn carries the full briefing. Later turns are just her words,
        # because the session already holds her files and the conversation.
        if ($session) { $send = $said } else { $send = $base.Replace('{{SARA_SAID}}', $said) }

        $args = @('-p', '--allowedTools', $allow, '--disallowedTools', $deny,
                  '--add-dir', 'C:\Users\saraa\OneDrive\Aya',
                  '--permission-mode', 'dontAsk', '--model', 'sonnet',
                  '--output-format', 'json')
        if ($session) { $args += @('--resume', $session) }

        $raw = ""
        try { $raw = $send | & $claude @args 2>&1 | Out-String }
        catch { Log "claude threw: $($_.Exception.Message)" }

        # A dead --resume session fails in seconds with an error line instead
        # of a reply envelope. Found 2026-08-17: the stored session had
        # expired, every one of Sara's messages got the raw error text back,
        # and it read as garbage. So: if the envelope does not parse while a
        # session was used, drop the session and retry once fresh.
        $envOk = $false
        try { $probe = $raw | ConvertFrom-Json; if ($probe.result) { $envOk = $true } } catch {}
        if (-not $envOk -and $session) {
            $snip = ($raw -replace '\s+', ' '); if ($snip.Length -gt 200) { $snip = $snip.Substring(0, 200) }
            Log "resume failed, dropping session and retrying fresh | $snip"
            $session = $null
            Remove-Item -LiteralPath $sessF -Force -ErrorAction SilentlyContinue
            $args = @('-p', '--allowedTools', $allow, '--disallowedTools', $deny,
                      '--add-dir', 'C:\Users\saraa\OneDrive\Aya',
                      '--permission-mode', 'dontAsk', '--model', 'sonnet',
                      '--output-format', 'json')
            $send = $base.Replace('{{SARA_SAID}}', $said)
            try { $raw = $send | & $claude @args 2>&1 | Out-String }
            catch { Log "fresh retry threw: $($_.Exception.Message)" }
        }

        # --output-format json wraps the reply and carries the session id, which
        # is how continuity is kept without a session file per turn.
        # NEVER send Sara raw output that failed to parse: an error dump is
        # worse than an honest failure notice.
        $reply = $null; $newSession = $null
        try {
            $env = $raw | ConvertFrom-Json
            $reply = $env.result
            $newSession = $env.session_id
        } catch {
            $snip = ($raw -replace '\s+', ' '); if ($snip.Length -gt 300) { $snip = $snip.Substring(0, 300) }
            Log "unparseable claude output, not forwarding | $snip"
        }

        if ($newSession) { Set-Content -LiteralPath $sessF -Value $newSession -Encoding utf8; $session = $newSession }

        # Aya answers in JSON so tasks can be filed. If she answered in prose
        # instead, send the prose rather than dropping it. Something is always
        # better than silence when Sara is waiting.
        $json = $null
        $m = [regex]::Match([string]$reply, '(?s)\{.*\}')
        if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { $json = $null } }

        $filed = 0
        # Updates run BEFORE adds, so a job that already exists gets amended
        # rather than duplicated by an add in the same turn.
        if ($json -and $json.tasks_update) {
            foreach ($u in $json.tasks_update) {
                $err = Update-Task -MatchTitle $u.match_title -Note $u.note -Section $u.section
                if ($err) { Log "  update FAILED: $err" } else { Log "  updated: $($u.match_title)" }
            }
        }
        if ($json -and $json.tasks) {
            foreach ($task in $json.tasks) { if (Add-Task -Task $task) { $filed++; Log "  filed [$($task.section)] $($task.title)" } }
        }
        if ($json -and $json.documents) {
            foreach ($d in $json.documents) {
                if (-not "$($d.body)".Trim()) { continue }
                $p = Write-AyaDoc -Doc $d
                Log "  wrote document: $p"
            }
        }
        if ($json -and $json.facts_to_record) { foreach ($f in $json.facts_to_record) { Log "  fact: $f" } }
        if ($json -and $json.log) {
            Add-Content -LiteralPath $ayaLog -Encoding utf8 -Value ("{0} | Aya | chat: {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $json.log)
        }

        $answer = ""
        if ($json -and $json.answers) { $answer = "$($json.answers)".Trim() }
        if (-not $answer) { $answer = ([string]$reply).Trim() }
        if (-not $answer) { $answer = "I did not manage to form a reply. It is in the log." }

        $sendRes = Send-AyaText -Secrets $sec -Text $answer
        $t0.Stop()
        $secs = [math]::Round($t0.Elapsed.TotalSeconds, 1)
        Log "replied in ${secs}s | $($sendRes.detail) | $filed task(s) filed"

        # Voice only when she asked for it or it is worth hearing. Speaking
        # every turn during a back-and-forth would be noise.
        if ($json -and $json.voice_summary -and "$($json.voice_summary)".Trim()) {
            $v = Send-AyaVoice -Secrets $sec -Text "$($json.voice_summary)".Trim()
            if ($v.ok) { Log "  spoke | $($v.detail)" } else { Log "  voice FAILED | $($v.detail)" }
        }
    }
}
finally {
    Remove-Item -LiteralPath $beatF -Force -ErrorAction SilentlyContinue
    Log "STOP | listener down, heartbeat removed, inbox.ps1 takes over on its schedule"
    $null = Send-AyaText -Secrets $sec -Text "Listener stopped. I will still pick up messages on the scheduled run, within about 10 minutes."
}
