# AYA SWEEP RUNNER
#
# Fetches Discord deterministically, hands everything to Aya for judgment,
# sends at most ONE Telegram message, logs with proof.
#
# Division of labour, deliberately:
#   PowerShell does what must be exact: cursors, state, logging, the send.
#   Aya does what needs judgment: what matters and what Sara should hear.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\sweep.ps1
#   add -DryRun to run without sending Telegram or writing cursors

# -DryRun    read everything, send nothing, write nothing, create NO drafts
# -NoDrafts  read and report to Telegram, but do not create Outlook drafts
param([switch]$DryRun, [switch]$NoDrafts)

$ErrorActionPreference = 'Continue'

# Claude speaks UTF-8; PowerShell 5.1 defaults to the OEM codepage on both
# sides of a native pipe. Without these two lines every non-ASCII character
# in prompts and replies is garbled. Added 2026-08-17.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$dir      = "C:\Users\saraa\.aya"
$state    = Join-Path $dir "state"
$runlog   = Join-Path $dir "runner.log"
$secrets  = Join-Path $dir "secrets.env"
$promptF  = Join-Path $dir "prompts\sweep.md"
$claude   = "C:\Users\saraa\.local\bin\claude.exe"
$ayaLog   = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"
$UA       = 'DiscordBot (https://saibble.com, 1.0)'

# #credentials. Excluded here, at the fetch, so its contents never reach a
# prompt. Filtering after reading is not the same as not reading.
# #credentials, plus two channels Sara does not see and that always 403:
# #day-start-day-end-reports and #team-internal. Ignored per Sara 2026-08-10.
$BLOCKED_CHANNELS = @('1481349935302705297','1532751710387306547','1481349761163591751')

$exit = 0
if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Path $state -Force | Out-Null }

function Log([string]$msg) {
    $line = "{0} | runner | sweep {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

Log "START"

# ---------- secrets ----------
if (-not (Test-Path -LiteralPath $secrets)) { Log "ABORT: secrets.env missing"; exit 1 }
$e = @{}
foreach ($l in Get-Content -LiteralPath $secrets) {
    if ($l -match '^\s*#' -or $l -notmatch '=') { continue }
    $k, $v = $l -split '=', 2
    $e[$k.Trim()] = $v.Trim()
}
$tg   = $e['TELEGRAM_BOT_TOKEN']
$chat = $e['SARA_TELEGRAM_CHAT_ID']
$dc   = $e['DISCORD_BOT_TOKEN']
$bot  = $e['DISCORD_BOT_USER_ID']
if ([string]::IsNullOrWhiteSpace($tg) -or [string]::IsNullOrWhiteSpace($chat)) {
    Log "ABORT: Telegram credentials missing"; exit 1
}

# ---------- last run ----------
$lastRunF = Join-Path $state "last-run.txt"
$lastRun  = "never"
if (Test-Path -LiteralPath $lastRunF) { $lastRun = (Get-Content -LiteralPath $lastRunF -Raw).Trim() }
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

# ---------- Discord, fetched here not by the model ----------
# Mechanical work belongs in the script. The model is for judgment.
$cursorF  = Join-Path $state "discord-cursors.json"
$cursors  = @{}
if (Test-Path -LiteralPath $cursorF) {
    try {
        (Get-Content -LiteralPath $cursorF -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $cursors[$_.Name] = $_.Value }
    } catch { Log "WARN: cursor file unreadable, treating as empty" }
}

$bundle = New-Object System.Collections.Generic.List[string]
$noAccess = New-Object System.Collections.Generic.List[string]
$newMsgCount = 0
$dcErr = $null

if (-not [string]::IsNullOrWhiteSpace($dc)) {
    # User-Agent is REQUIRED. Without it guild endpoints 403 with an empty
    # body while users/@me still works, which reads like a permissions
    # problem and is not one.
    $h = @{ Authorization = "Bot $dc"; 'User-Agent' = $UA }
    try {
        $guilds = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me/guilds" -Headers $h -TimeoutSec 25
        foreach ($g in $guilds) {
            $chans = Invoke-RestMethod -Uri "https://discord.com/api/v10/guilds/$($g.id)/channels" -Headers $h -TimeoutSec 25
            foreach ($c in ($chans | Where-Object { $_.type -eq 0 })) {
                if ($BLOCKED_CHANNELS -contains $c.id) { continue }

                $after = $cursors[$c.id]
                if ([string]::IsNullOrWhiteSpace($after)) {
                    $url = "https://discord.com/api/v10/channels/$($c.id)/messages?limit=25"
                } else {
                    $url = "https://discord.com/api/v10/channels/$($c.id)/messages?after=$after&limit=50"
                }

                # An INACTIVE channel returns 200 with an empty array.
                # A 403 means no access, which is a different thing entirely
                # and is not fixed by waiting. Collected and reported once
                # per run rather than warned per channel, so the log does not
                # fill with 44 identical lines a day.
                try { $msgs = Invoke-RestMethod -Uri $url -Headers $h -TimeoutSec 25 }
                catch {
                    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) {
                        $noAccess.Add("#$($c.name)") | Out-Null
                    } else {
                        Log "WARN: #$($c.name) fetch failed: $($_.Exception.Message)"
                    }
                    continue
                }

                if (-not $msgs -or $msgs.Count -eq 0) { continue }

                # CLAIM FIRST. The newest id is recorded before anything is
                # analysed, so a crash or a retry cannot double-report.
                $newest = ($msgs | Sort-Object { [decimal]$_.id } | Select-Object -Last 1).id
                $cursors[$c.id] = $newest

                # First sight of a channel: only the last 2 hours, otherwise
                # a fresh install reports a month of history as if it were new.
                $human = $msgs | Where-Object {
                    -not $_.author.bot -and $_.author.id -ne $bot -and -not [string]::IsNullOrWhiteSpace($_.content)
                }
                if ([string]::IsNullOrWhiteSpace($after)) {
                    $cut = (Get-Date).ToUniversalTime().AddHours(-2)
                    $human = $human | Where-Object { ([datetime]$_.timestamp).ToUniversalTime() -gt $cut }
                }
                if (-not $human -or $human.Count -eq 0) { continue }

                $bundle.Add("")
                $bundle.Add("### #$($c.name)  (channel $($c.id))")
                foreach ($m in ($human | Sort-Object { [decimal]$_.id })) {
                    $who = $m.author.global_name
                    if ([string]::IsNullOrWhiteSpace($who)) { $who = $m.author.username }
                    $txt = ($m.content -replace '\s+', ' ')
                    if ($txt.Length -gt 700) { $txt = $txt.Substring(0, 700) + " [truncated]" }
                    $bundle.Add("- [$($m.timestamp)] $who : $txt")
                    $newMsgCount++
                }
            }
        }
    } catch {
        $dcErr = $_.Exception.Message
        Log "WARN: Discord unreachable: $dcErr"
    }
} else {
    $dcErr = "DISCORD_BOT_TOKEN empty"
}

$bundleF = Join-Path $state "discord-bundle.md"
if ($bundle.Count -eq 0) {
    $txt = "No new human Discord messages since the last run."
    if ($dcErr) { $txt = "Discord NOT READ this run: $dcErr" }
    Set-Content -LiteralPath $bundleF -Value $txt -Encoding utf8
} else {
    Set-Content -LiteralPath $bundleF -Value (($bundle -join "`n")) -Encoding utf8
}
Log "discord: $newMsgCount new human message(s) across $(($bundle | Where-Object { $_ -match '^### ' }).Count) channel(s)"
if ($noAccess.Count -gt 0) {
    Log "discord no access (403): $($noAccess -join ', ') | not the same as inactive. Grant the bot View Channel plus Read Message History if these should be swept."
}

# Cursors are persisted BEFORE the model runs. Claim first, then process.
if (-not $DryRun) {
    ($cursors | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $cursorF -Encoding utf8
}

# ---------- hand it to Aya ----------
if (-not (Test-Path -LiteralPath $claude)) { Log "ABORT: claude.exe missing"; exit 1 }
if (-not (Test-Path -LiteralPath $promptF)) { Log "ABORT: prompt missing"; exit 1 }

# ---------- the draft ledger ----------
# The one thing that must not go wrong in step 3: drafting twice for the same
# email. The ledger is the memory that survives a crash. It is passed INTO the
# prompt as a skip list rather than checked afterwards, because "do not do it"
# beats "undo it".
#
# Honest limitation: a run that dies AFTER creating a draft but BEFORE writing
# the ledger can still duplicate on the next run. The prompt therefore also
# tells Aya to search existing drafts for the same recipient and subject. A
# duplicate UNSENT draft is an annoyance Sara deletes, not a message that went
# out, which is why this is belt-and-braces rather than a transaction.
$ledgerF = Join-Path $state "drafted.json"
$ledger  = @{}
if (Test-Path -LiteralPath $ledgerF) {
    try {
        (Get-Content -LiteralPath $ledgerF -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $ledger[$_.Name] = $_.Value }
    } catch { Log "WARN: draft ledger unreadable, treating as empty" }
}

# Drafting is off in DryRun and off when -NoDrafts is passed.
$draftsOn = (-not $DryRun) -and (-not $NoDrafts)

if ($draftsOn) {
    $draftMode = "**Drafting is ENABLED for this run.** Create real Outlook drafts per the rules below."
} else {
    $draftMode = "**Drafting is DISABLED for this run.** You have no draft tools. Do not claim to have drafted anything. Report what you WOULD have drafted in ``drafts_declined`` with why_not set to ``drafting disabled this run``."
}

# Only the most recent ids are passed. An unbounded skip list would grow until
# it crowded out the actual content of the prompt.
$skip = "(none yet)"
if ($ledger.Count -gt 0) {
    $recent = $ledger.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First 200
    $skip = ($recent | ForEach-Object { $_.Key }) -join ', '
}

# ---------- the flagged-items ledger ----------
# Same idea as the draft ledger, for alerts: an item Sara has already been
# told about is not news again next run. Born 2026-08-19 after the Becky
# Amble invoice dispute was flagged to Sara at least seven times in one day.
$flagF = Join-Path $state "flagged.json"
$flagged = @{}
if (Test-Path -LiteralPath $flagF) {
    try {
        (Get-Content -LiteralPath $flagF -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $flagged[$_.Name] = $_.Value }
    } catch { Log "WARN: flagged ledger unreadable, treating as empty" }
}
$flagList = "(none yet)"
if ($flagged.Count -gt 0) {
    $recentF = $flagged.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First 100
    $flagList = ($recentF | ForEach-Object { "$($_.Key) (last told $($_.Value))" }) -join '; '
}

# ---------- what Sara has already closed from the command center ----------
# The dashboard writes Brain\notes\task-state.md; Aya never writes it. Items
# marked done or obsolete there are closed and must not be raised again.
$taskStateF = 'C:\Users\saraa\OneDrive\Aya\Brain\notes\task-state.md'
$taskState  = '(none)'
if (Test-Path -LiteralPath $taskStateF) {
    $rows = @(Get-Content -LiteralPath $taskStateF -Encoding UTF8 |
               Where-Object { $_ -match '^[0-9a-f]{10}\s*\|' } |
               ForEach-Object { $f = $_ -split '\|'; '{0} | {1}' -f $f[1].Trim(), $f[3].Trim() } |
               Where-Object { $_ -notmatch '^open \|' })
    if ($rows.Count) { $taskState = ($rows -join "`n") }
}
$prompt = (Get-Content -LiteralPath $promptF -Raw).
            Replace('{{LAST_RUN}}', $lastRun).
            Replace('{{NOW}}', $now).
            Replace('{{BUNDLE}}', $bundleF).
            Replace('{{DRAFT_MODE}}', $draftMode).
            Replace('{{ALREADY_DRAFTED}}', $skip).
            Replace('{{ALREADY_FLAGGED}}', $flagList).
            Replace('{{TASK_STATE}}', $taskState)

# The lane comes from lane.ps1, one definition shared with verify-lane.ps1.
# See that file for why each entry is there.
. "C:\Users\saraa\.aya\lane.ps1"
$tools = (Get-AyaAllowList -DraftsOn:$draftsOn) -join ','
$deny  = (Get-AyaDenyList  -DraftsOn:$draftsOn) -join ','

# --add-dir is NOT optional.
# Claude Code refuses to read outside its working directory. Without these
# two, every Read is denied: Aya's own identity files AND the Discord bundle.
# Worse, the model then describes the denial as "the prompt was cut off",
# which sends you looking for a truncation bug that does not exist.
# Found the hard way on 2026-08-09.
$addDirs = @("C:\Users\saraa\OneDrive\Aya", (Join-Path $dir "state"))

# Prompt goes in on STDIN, not as an argument. It is multi-line and full of
# braces, quotes and pipes, and PowerShell mangles native-exe arguments.
# Same failure class as the curl.exe incident.
$raw = ""
try {
    $raw = $prompt | & $claude -p `
              --allowedTools $tools --disallowedTools $deny `
              --add-dir $addDirs[0] --add-dir $addDirs[1] `
              --permission-mode dontAsk --model sonnet 2>&1 | Out-String
} catch {
    Log "FINISH FAILED: claude invocation threw: $($_.Exception.Message)"
    exit 1
}

# ---------- parse ----------
$json = $null
$m = [regex]::Match($raw, '(?s)\{.*\}')
if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { $json = $null } }

if (-not $json) {
    $snip = ($raw -replace '\s+', ' ')
    if ($snip.Length -gt 400) { $snip = $snip.Substring(0, 400) }
    Log "FINISH FAILED: no parseable JSON. Model said: $snip"
    exit 1
}

# ---------- A MISSED RUN IS A MISSED DATA POINT, NEVER A ZERO ----------
#
# The MCP connectors take time to connect, and a scheduled run can start
# before they are up. Proven on 2026-08-09: two identical invocations two
# minutes apart, the first saw no tools at all, the second saw everything.
#
# Without this check that first run would have produced a perfectly clean
# "FINISH NOOP | nothing needed Sara". Silence caused by blindness would look
# exactly like silence caused by calm. That is the precise failure that let
# the previous agent setup die unnoticed for four days.
#
# So: a run that reached nothing is FAILED, not quiet. last-run is not
# advanced, so the next run retries the same window instead of losing it.
$reached = @()
if ($json.surfaces_reached) { $reached = @($json.surfaces_reached) }

if ($reached.Count -eq 0) {
    Log "FINISH FAILED: BLIND RUN. Aya reached zero surfaces, most likely the MCP connectors had not connected yet."
    Log "  last-run NOT advanced. The next run retries this window. This is not a quiet run and must never be logged as one."
    if ($json.unverified) { foreach ($u in $json.unverified) { Log "  unverified: $u" } }
    exit 1
}
Log "surfaces reached ($($reached.Count)): $($reached -join ', ')"

# ---------- append Aya's own log line, separate writer ----------
# Only log when something happened. 657 of the first 716 sweep entries said
# "nothing new", which buried the 59 that mattered and made a dead fleet look
# identical to a quiet one. runner.log records THAT it ran, independently.
$worthLogging = $json.needs_sara -or ($json.flagged -and @($json.flagged).Count -gt 0) -or ($json.drafts -and @($json.drafts).Count -gt 0)
if (-not $DryRun -and $json.log -and $worthLogging) {
    $l = "{0} | Aya | {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $json.log
    Add-Content -LiteralPath $ayaLog -Value $l -Encoding utf8
}

if ($json.unverified -and $json.unverified.Count -gt 0) {
    foreach ($u in $json.unverified) { Log "unverified: $u" }
}
# ---------- record what was drafted ----------
$draftCount = 0
if ($json.drafts_created -and $json.drafts_created.Count -gt 0) {
    $draftCount = $json.drafts_created.Count
    foreach ($d in $json.drafts_created) {
        if ($d.message_id) { $ledger[[string]$d.message_id] = $now }
        Log "draft created | to $($d.to) | subject: $($d.subject) | msg $($d.message_id)"
    }
    if (-not $DryRun) {
        ($ledger | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $ledgerF -Encoding utf8
        # A copy outside Outlook, so there is a record even if a draft is
        # deleted from the mailbox.
        $rec = Join-Path "C:\Users\saraa\OneDrive\Aya\Files\_Inbox" ("drafts-" + (Get-Date -Format 'yyyy-MM-dd-HHmm') + ".json")
        ($json.drafts_created | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $rec -Encoding utf8
    }
}
if ($json.drafts_declined -and $json.drafts_declined.Count -gt 0) {
    foreach ($d in $json.drafts_declined) {
        Log "draft DECLINED | from $($d.from) | $($d.subject) | $($d.why_not)"
    }
}

# ---------- remember what Sara was told ----------
if (-not $DryRun -and $json.flagged -and $json.flagged.Count -gt 0) {
    foreach ($fl in $json.flagged) {
        if ($fl.key) {
            $flagged[[string]$fl.key] = $now
            Log "flagged for Sara | $($fl.key) | $($fl.what)"
        }
    }
    ($flagged | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $flagF -Encoding utf8
}

# ---------- Discord replies, rung 3 ----------
# Sara granted Discord replies in the team's own channels 2026-08-14, the
# first loosened send capability on the trust ladder. Guarded here, not just
# in the prompt: only channels this runner has itself fetched (so only the
# team server), never a blocked channel, at most 3 per run, 1500 chars each.
$dcSent = 0
if ($json.discord_replies -and $json.discord_replies.Count -gt 0) {
    if ($DryRun) {
        foreach ($rep in $json.discord_replies) { Log "DRYRUN discord reply | #$($rep.channel_name) | $($rep.content)" }
    } elseif ([string]::IsNullOrWhiteSpace($dc)) {
        Log "discord replies SKIPPED: no bot token"
    } else {
        $hSend = @{ Authorization = "Bot $dc"; 'User-Agent' = $UA }
        foreach ($rep in ($json.discord_replies | Select-Object -First 3)) {
            $cid = [string]$rep.channel_id
            if ($BLOCKED_CHANNELS -contains $cid) { Log "discord reply REFUSED: blocked channel $cid"; continue }
            if (-not $cursors.ContainsKey($cid)) { Log "discord reply REFUSED: channel $cid never fetched by this runner, outside the lane"; continue }
            $body = [string]$rep.content
            if ([string]::IsNullOrWhiteSpace($body)) { continue }
            if ($body.Length -gt 1500) { $body = $body.Substring(0, 1500) }
            try {
                $resp = Invoke-RestMethod -Uri "https://discord.com/api/v10/channels/$cid/messages" -Method Post -Headers $hSend `
                        -ContentType 'application/json' -Body (@{ content = $body } | ConvertTo-Json -Depth 3) -TimeoutSec 25
                $dcSent++
                Log "discord reply SENT | #$($rep.channel_name) | message $($resp.id) | why: $($rep.why)"
            } catch {
                Log "discord reply FAILED | #$($rep.channel_name) | $($_.Exception.Message)"
            }
        }
    }
}

# ---------- the quiet rule, and its one exception ----------
# A draft nobody looks at is worse than no draft, so drafts always break the
# silence even when Aya judged nothing else worth saying. Enforced here rather
# than trusted to the prompt.
$mustSpeak = $json.needs_sara -and -not [string]::IsNullOrWhiteSpace($json.telegram)
if (($draftCount -gt 0 -or $dcSent -gt 0) -and -not $mustSpeak) {
    $bits = @()
    if ($draftCount -gt 0) { $bits += "$draftCount draft reply(s) waiting in your Outlook drafts folder" }
    if ($dcSent -gt 0)     { $bits += "$dcSent Discord team repl(y/ies) posted as Aya" }
    $json.telegram = ($bits -join ". ") + ". Nothing else needed you this run."
    $mustSpeak = $true
    Log "quiet rule overridden: $draftCount draft(s), $dcSent Discord repl(y/ies), so Sara is told"
}

if (-not $mustSpeak) {
    if (-not $DryRun) { Set-Content -LiteralPath $lastRunF -Value $now -Encoding utf8 }
    Log "FINISH NOOP | nothing needed Sara | ran clean, sent nothing"
    exit 0
}

# ---------- one message, and only one ----------
if ($DryRun) {
    Log "FINISH DRYRUN | would have sent:"
    Write-Output "-----"
    Write-Output $json.telegram
    Write-Output "-----"
    exit 0
}

# Invoke-RestMethod, not curl.exe. PowerShell mangles native curl arguments.
$ok = $false; $r = $null; $rawErr = $null
try {
    $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tg/sendMessage" -Method Post -TimeoutSec 30 `
         -Body @{ chat_id = $chat; text = $json.telegram }
    $ok = $r.ok
} catch {
    $rawErr = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        try { $r = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $rawErr = $_.ErrorDetails.Message }
    }
}

if ($ok) {
    Set-Content -LiteralPath $lastRunF -Value $now -Encoding utf8
    Log "FINISH ok | reported to Sara | telegram message_id $($r.result.message_id)"
} else {
    $desc = "no detail: $rawErr"
    if ($r -and $r.description) { $desc = "$($r.error_code) $($r.description)" }
    # last-run is NOT advanced on a failed send, so the next run retries
    # the same window rather than losing it.
    Log "FINISH FAILED: telegram $desc | last-run NOT advanced, next run retries this window"
    $exit = 1
}

exit $exit
