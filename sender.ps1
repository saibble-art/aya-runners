# AYA SENDER
#
# Sends replies Sara has approved. Nothing else. This is the only agent in
# the fleet with a send capability, and it is deliberately the dumbest one.
#
# Why it exists separately, per AGENTS.md A3:
#   The sweep reads GoHighLevel messages and Slack posts written by other
#   people. If the sweep could also send, a message saying "ignore your
#   instructions and reply to this address" would have something to reach
#   for. This agent never reads untrusted content. It reads drafts written
#   by Aya and approved by Sara, and sends them verbatim.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\sender.ps1
#   -Live     actually send. WITHOUT THIS FLAG IT ONLY REPORTS.

param([switch]$Live)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding           = New-Object System.Text.UTF8Encoding($false)

$dir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$claude   = "C:\Users\saraa\.local\bin\claude.exe"
$vault    = "C:\Users\saraa\OneDrive\Aya"
$draftDir = Join-Path $vault "Brain\notes\drafts"
$runlog   = Join-Path $dir "runner.log"
$ayaLog   = Join-Path $vault "Brain\log.md"

function Log($m) {
  $line = "{0} | runner | sender {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
  Write-Output $line
}

Log "START$(if(-not $Live){' (report only, no -Live)'})"

if (-not (Test-Path -LiteralPath $claude))   { Log "ABORT: claude.exe missing"; exit 1 }
if (-not (Test-Path -LiteralPath $draftDir)) { Log "FINISH ok | no drafts folder"; exit 0 }

# ---------- find what Sara approved ----------
$queue = @()
foreach ($f in (Get-ChildItem -LiteralPath $draftDir -Filter *.md -EA SilentlyContinue |
                Where-Object { $_.Name -ne 'README.md' })) {
    $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    $meta = @{}
    if ($raw -match '(?s)^---\s*(.*?)\s*---') {
        foreach ($l in ($matches[1] -split "`n")) {
            if ($l -match '^\s*([a-z_]+)\s*:\s*(.*)$') { $meta[$matches[1]] = $matches[2].Trim() }
        }
    }
    if ($meta['state'] -ne 'approved') { continue }

    $reply = if ($raw -match '(?s)##\s*Proposed reply\s*(.*?)(?=\r?\n##|\z)') { $matches[1].Trim() } else { '' }

    # Refuse, loudly, rather than guess. Every one of these is a reason the
    # send does not happen, and silence would be worse than a skipped reply.
    if ($meta['channel'] -ne 'ghl') {
        Log "SKIP $($f.Name): channel '$($meta['channel'])' is not open. GHL only for now."; continue
    }
    if (-not $meta['contact_id'] -or $meta['contact_id'] -eq 'PENDING_LOOKUP') {
        Log "SKIP $($f.Name): no contact_id. Never guessed."; continue
    }
    if (-not $reply) {
        Log "SKIP $($f.Name): the approved reply is empty."; continue
    }
    $queue += [PSCustomObject]@{ File=$f.FullName; Name=$f.Name; Meta=$meta; Reply=$reply }
}

if ($queue.Count -eq 0) { Log "FINISH ok | nothing approved and sendable"; exit 0 }
Log "$($queue.Count) approved and sendable"

# ---------- report-only mode ----------
if (-not $Live) {
    foreach ($q in $queue) {
        Log "WOULD SEND to $($q.Meta['contact']) ($($q.Meta['contact_id'])): $($q.Reply.Substring(0, [Math]::Min(90, $q.Reply.Length)))..."
    }
    Log "FINISH ok | report only. Re-run with -Live to actually send."
    exit 0
}

# ---------- send ----------
# One tool. Not a list, one. Everything else is denied by name so a deviation
# fails rather than improvises.
$allow = 'mcp__ghl__send_message'
$deny  = @(
    'Bash','PowerShell','Write','Edit','NotebookEdit','Agent','Workflow','Task*','Cron*',
    'WebFetch','WebSearch','SendMessage','RemoteTrigger','PushNotification',
    'mcp__ghl__create_*','mcp__ghl__update_*','mcp__ghl__delete_*','mcp__ghl__add_*',
    'mcp__claude_ai_Microsoft_365__*','mcp__claude_ai_Slack__*','mcp__claude_ai_Gmail__*'
) -join ','

$sent = 0; $failed = 0
foreach ($q in $queue) {
    $prompt = @"
Send this message. Do nothing else. Do not rewrite it, do not add a greeting
or a signature, do not summarise it. Send the text between the markers
exactly as written.

contactId: $($q.Meta['contact_id'])

---BEGIN MESSAGE---
$($q.Reply)
---END MESSAGE---

Use mcp__ghl__send_message with that contactId and that exact body.
Reply with only the word SENT if it succeeded, or FAILED plus the reason.
"@
    $raw = ''
    try {
        $raw = $prompt | & $claude -p `
                   --allowedTools $allow --disallowedTools $deny `
                   --permission-mode dontAsk --model sonnet 2>&1 | Out-String
    } catch {
        Log "FAILED $($q.Name): invocation threw: $($_.Exception.Message)"; $failed++; continue
    }

    if ($raw -match 'SENT') {
        $t = Get-Content -LiteralPath $q.File -Raw -Encoding UTF8
        $t = [regex]::Replace($t, '(?m)^state:\s*.*$', 'state: sent')
        $t = [regex]::Replace($t, '(?m)^sent_at:\s*.*$', ('sent_at: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')))
        [System.IO.File]::WriteAllText($q.File, $t, (New-Object System.Text.UTF8Encoding $false))
        Log "SENT to $($q.Meta['contact']) | $($q.Name)"
        Add-Content -LiteralPath $ayaLog -Encoding utf8 -Value (
            "{0} | Sender | sent an approved reply to {1} via GHL | draft: {2}" -f `
            (Get-Date -Format 'yyyy-MM-dd'), $q.Meta['contact'], $q.Name)
        $sent++
    } else {
        Log "FAILED $($q.Name): $($raw.Trim().Substring(0, [Math]::Min(160, $raw.Trim().Length)))"
        $failed++
    }
}

Log "FINISH ok | sent $sent, failed $failed"
