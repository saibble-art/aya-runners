# TUBY RUNNER
#
# Weekly YouTube production, Tuesdays 4:00am. Rebuilt locally 2026-08-15
# after the Anthropic scheduled-task fleet was torn down 2026-08-08 and the
# build hold was lifted by Sara 2026-08-15.
#
# Writes the production package to OneDrive\Aya\Files\Tuby\<date>-<slug>\,
# appends the run log where Aya supervises, sends Sara ONE Telegram message.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\tuby.ps1
#   add -DryRun to run without writing the package or sending Telegram

param([switch]$DryRun)

$ErrorActionPreference = 'Continue'

# Claude speaks UTF-8; PowerShell 5.1 defaults to the OEM codepage on both
# sides of a native pipe. Without these two lines every non-ASCII character
# in prompts and replies is garbled. Added 2026-08-17.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$dir      = "C:\Users\saraa\.aya"
$runlog   = Join-Path $dir "runner.log"
$secrets  = Join-Path $dir "secrets.env"
$promptF  = Join-Path $dir "prompts\tuby.md"
$claude   = "C:\Users\saraa\.local\bin\claude.exe"
$ayaLog   = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"
$tubyLog  = "C:\Users\saraa\OneDrive\Aya\Brain\notes\agents\tuby-run-log.md"
$outRoot  = "C:\Users\saraa\OneDrive\Aya\Files\Tuby"

function Log([string]$msg) {
    $line = "{0} | runner | tuby {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

Log "START"

if (-not (Test-Path -LiteralPath $secrets)) { Log "ABORT: secrets.env missing"; exit 1 }
$e = @{}
foreach ($l in Get-Content -LiteralPath $secrets) {
    if ($l -match '^\s*#' -or $l -notmatch '=') { continue }
    $k, $v = $l -split '=', 2
    $e[$k.Trim()] = $v.Trim()
}
$tg   = $e['TELEGRAM_BOT_TOKEN']
$chat = $e['SARA_TELEGRAM_CHAT_ID']

if (-not (Test-Path -LiteralPath $claude))  { Log "ABORT: claude.exe missing"; exit 1 }
if (-not (Test-Path -LiteralPath $promptF)) { Log "ABORT: prompt missing"; exit 1 }
if (-not (Test-Path -LiteralPath $outRoot)) { New-Item -ItemType Directory -Path $outRoot -Force | Out-Null }

$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$prompt = (Get-Content -LiteralPath $promptF -Raw).Replace('{{NOW}}', $now)

# Tuby's lane, distinct from the sweep's: research needs the open web, and
# he reads the vault. He sends nothing, writes nothing himself (the runner
# writes his files), and never touches mail, CRM, calendars, or chat.
$allow = @(
    'Read', 'WebSearch', 'WebFetch'
    'mcp__claude_ai_Google_Drive__search_files'
    'mcp__claude_ai_Google_Drive__read_file_content'
) -join ','
$deny = @(
    'Bash','PowerShell','Write','Edit','NotebookEdit'
    'Agent','Workflow','Artifact','Skill','DesignSync'
    'RemoteTrigger','PushNotification','SendMessage'
    'Task*','Cron*','EnterWorktree','ExitWorktree','Monitor'
    'mcp__ghl__*'
    'mcp__claude_ai_Microsoft_365__*'
    'mcp__claude_ai_Google_Calendar__*'
    'mcp__claude_ai_Slack__*'
    'mcp__claude_ai_Gamma__*'
    'mcp__claude_ai_Higgsfield__*'
    'mcp__claude_ai_ClickUp__*'
    'mcp__claude_ai_Notion__*'
    'mcp__claude_ai_Gmail__*'
) -join ','

$raw = ""
try {
    $raw = $prompt | & $claude -p `
              --allowedTools $allow --disallowedTools $deny `
              --mcp-config "C:\Users\saraa\.aya\mcp-content.json" --strict-mcp-config `
              --add-dir "C:\Users\saraa\OneDrive\Aya" `
              --add-dir "C:\Users\saraa\OneDrive\Desktop\Sara's Obsidian" `
              --add-dir "G:\Claude Code\youtube-operating-system" `
              --permission-mode dontAsk --model opus 2>&1 | Out-String
} catch {
    Log "FINISH FAILED: claude invocation threw: $($_.Exception.Message)"
    exit 1
}

$json = $null
$m = [regex]::Match($raw, '(?s)\{.*\}')
if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { $json = $null } }
if (-not $json -or -not $json.files -or $json.files.Count -eq 0) {
    $snip = ($raw -replace '\s+', ' ')
    if ($snip.Length -gt 400) { $snip = $snip.Substring(0, 400) }
    Log "FINISH FAILED: no usable JSON package. Model said: $snip"
    # A missed run is a missed data point, never a zero. The run log says so.
    if (-not $DryRun) {
        Add-Content -LiteralPath $tubyLog -Encoding utf8 -Value ("- {0} | RUN FAILED, no package produced. See runner.log." -f (Get-Date -Format 'yyyy-MM-dd'))
    }
    exit 1
}

$slug = "$($json.topic_slug)".Trim() -replace '[^a-zA-Z0-9-]', '-'
if (-not $slug) { $slug = "untitled" }
$pkgDir = Join-Path $outRoot ((Get-Date -Format 'yyyy-MM-dd') + "-" + $slug)

if ($DryRun) {
    Log "FINISH DRYRUN | topic $slug | $($json.files.Count) file(s) would be written to $pkgDir"
    Write-Output $json.telegram
    exit 0
}

New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
foreach ($f in $json.files) {
    $name = "$($f.name)" -replace '[\\/:*?"<>|]', '-'
    if (-not $name) { continue }
    [System.IO.File]::WriteAllText((Join-Path $pkgDir $name), "$($f.content)", (New-Object System.Text.UTF8Encoding $false))
}
Log "package written: $pkgDir ($($json.files.Count) files)"

# Run log, the artifact Aya supervises.
Add-Content -LiteralPath $tubyLog -Encoding utf8 -Value ("- {0} | {1} | {2}" -f (Get-Date -Format 'yyyy-MM-dd'), $slug, "$($json.run_log)")
Add-Content -LiteralPath $ayaLog -Encoding utf8 -Value ("{0} | Tuby | weekly run: {1} | package: {2}" -f (Get-Date -Format 'yyyy-MM-dd'), "$($json.run_log)", $pkgDir)

# One Telegram message, always: a weekly production run Sara has to discover
# by accident is a failed handoff.
if (-not [string]::IsNullOrWhiteSpace($tg) -and -not [string]::IsNullOrWhiteSpace($chat)) {
    $msg = "$($json.telegram)".Trim()
    if (-not $msg) { $msg = "Tuby ran. This week's video package is drafted and filed, topic " + $slug + ". The checklist lists what needs you." }
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tg/sendMessage" -Method Post -TimeoutSec 30 `
             -Body @{ chat_id = $chat; text = $msg }
        if ($r.ok) { Log "FINISH ok | telegram message_id $($r.result.message_id)" } else { Log "FINISH ok but telegram failed: $($r.description)" }
    } catch { Log "FINISH ok but telegram failed: $($_.Exception.Message)" }
} else {
    Log "FINISH ok | telegram not configured"
}
exit 0
