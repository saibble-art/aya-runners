# AYA HEARTBEAT
#
# One job. One message a day. No intelligence.
#
# Its purpose is NOT to be useful. Its purpose is to be MISSED.
# Aya's sweep is silent when there is no news, which makes a working sweep
# and a dead sweep look identical. This is the one job that is never silent,
# so its absence is the alarm.
#
# It also probes whether a scheduled run can still reach the connectors,
# because that is the failure that killed the previous fleet quietly.
#
# Run:  powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\heartbeat.ps1

$ErrorActionPreference = 'Continue'
$dir     = "C:\Users\saraa\.aya"
$secrets = Join-Path $dir "secrets.env"
$runlog  = Join-Path $dir "runner.log"
$claude  = "C:\Users\saraa\.local\bin\claude.exe"
$stamp   = Get-Date -Format 'yyyy-MM-dd HH:mm'
$exit    = 0

function Log([string]$msg) {
    $line = "{0} | runner | {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

# The runner logs that it STARTED, independently of anything the agent does.
# A start with no finish is a visible crash. That is the whole point.
Log "heartbeat START"

# --- secrets ---
if (-not (Test-Path -LiteralPath $secrets)) {
    Log "heartbeat ABORT: secrets.env missing"
    exit 1
}
$e = @{}
foreach ($line in Get-Content -LiteralPath $secrets) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $e[$k.Trim()] = $v.Trim()
}
$tg   = $e['TELEGRAM_BOT_TOKEN']
$chat = $e['SARA_TELEGRAM_CHAT_ID']
if ([string]::IsNullOrWhiteSpace($tg) -or [string]::IsNullOrWhiteSpace($chat)) {
    Log "heartbeat ABORT: TELEGRAM_BOT_TOKEN or SARA_TELEGRAM_CHAT_ID empty"
    exit 1
}

# --- connector probe ---
# Named with the CLI's tool prefixes, which are NOT the same as the
# desktop app's. Desktop uses uuid prefixes, CLI uses mcp__claude_ai_*.
# Getting this wrong reports FAIL on a working connector. Cost us one
# false alarm on 2026-08-08.
$probe = "unknown"
if (Test-Path -LiteralPath $claude) {
    $tools = @(
        'mcp__claude_ai_Microsoft_365__get_me'
        'mcp__claude_ai_Google_Calendar__list_calendars'
        'mcp__claude_ai_Slack__slack_search_channels'
        'mcp__ghl__get_location'
    ) -join ','
    $prompt = 'Probe. Call each once: Microsoft 365 get_me, Google Calendar list_calendars, Slack slack_search_channels with query "general", GoHighLevel get_location. Then output ONE line only, exact format: OUTLOOK=<ok|FAIL> GCAL=<ok|FAIL> SLACK=<ok|FAIL> GHL=<ok|FAIL>. FAIL for anything that errors. No other text.'
    try {
        $raw = & $claude -p $prompt --allowedTools $tools --permission-mode dontAsk --model sonnet 2>&1
        $hit = ($raw | Select-String -Pattern 'OUTLOOK=' | Select-Object -First 1)
        if ($hit) { $probe = $hit.Line.Trim() } else { $probe = "no probe line returned" }
    } catch {
        $probe = "probe threw: $($_.Exception.Message)"
    }
} else {
    $probe = "claude.exe not found at $claude"
}
Log "probe: $probe"

# --- is Aya's sweep alive? ---
# The heartbeat reports on the sweep without depending on it. Two writers.
$ayaLog = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"
$sweep  = "sweep not built yet"
if (Test-Path -LiteralPath $ayaLog) {
    $last = Get-Content -LiteralPath $ayaLog | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' } | Select-Object -Last 1
    if ($last) {
        $d = ($last -split '\|')[0].Trim()
        try {
            $age = (New-TimeSpan -Start ([datetime]::ParseExact($d, 'yyyy-MM-dd', $null)) -End (Get-Date)).Days
            $sweep = "Aya's last log entry: $d ($age days ago)"
        } catch { $sweep = "Aya's last log entry: $d" }
    }
}

# --- the message ---
$body = @"
AYA HEARTBEAT
$stamp

Runner is alive on $env:COMPUTERNAME.

Connectors: $probe
$sweep

This message means the scheduler works. If it stops arriving, the runner is dead, whether or not Aya has been quiet.
"@

# Invoke-RestMethod, NOT curl.exe.
#
# The obvious move is curl, because PowerShell 5.1 throws on any 4xx and
# turns Telegram's actual explanation into a bare "(400) Bad Request".
# But PowerShell mangles arguments passed to native curl.exe: a quoted
# --data-urlencode became "could not resolve host", which reads like a
# network outage and is not one. Cost us a run on 2026-08-08.
#
# The fix for the hidden-body problem without curl is $_.ErrorDetails.Message,
# which PowerShell 5.1 populates with the raw response body on HTTP errors.
$ok = $false
$r  = $null
$rawErr = $null
try {
    $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tg/sendMessage" `
         -Method Post -TimeoutSec 30 `
         -Body @{ chat_id = $chat; text = $body }
    $ok = $r.ok
} catch {
    $rawErr = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        try { $r = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $rawErr = $_.ErrorDetails.Message }
    }
}

if ($ok) {
    Log "heartbeat FINISH ok | telegram message_id $($r.result.message_id)"
} else {
    $desc = "no response detail: $rawErr"
    if ($r -and $r.description) { $desc = "$($r.error_code) $($r.description)" }
    Log "heartbeat FINISH FAILED: telegram $desc"

    # The one failure worth naming explicitly, because the fix is not obvious
    # and the message is cryptic. A bot may never open a conversation with a
    # user. The user has to send it something first.
    if ($desc -match 'chat not found') {
        Log "  FIX: open Telegram, find the bot, press Start or send /start once."
        Log "  Until then Telegram will refuse every message, and the chat id is not the problem."
    }
    if ($desc -match 'blocked') {
        Log "  FIX: the bot is blocked in Telegram. Unblock it."
    }

    # If Telegram is the only channel and Telegram is down, the heartbeat
    # cannot announce its own failure. That is a single point of failure
    # carried over from the old fleet. The log line and the non-zero exit
    # are the fallback until a second channel exists.
    $exit = 1
}

exit $exit
