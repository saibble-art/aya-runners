# MORNING BRIEF RUNNER
#
# Weekdays 6:30am. Revives the retired Cowork Morning Brief (80 issues,
# April to July 2026) inside Aya. Writes the full brief to
# Brain\notes\daily\, sends ONE Telegram summary.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\brief.ps1
#   add -DryRun to run without writing or sending

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
$promptF  = Join-Path $dir "prompts\brief.md"
$claude   = "C:\Users\saraa\.local\bin\claude.exe"
$ayaLog   = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"
$dailyDir = "C:\Users\saraa\OneDrive\Aya\Brain\notes\daily"

function Log([string]$msg) {
    $line = "{0} | runner | brief {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
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
if (-not (Test-Path -LiteralPath $dailyDir)) { New-Item -ItemType Directory -Path $dailyDir -Force | Out-Null }

$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$prompt = (Get-Content -LiteralPath $promptF -Raw).Replace('{{NOW}}', $now)

$allow = @('Read', 'WebSearch', 'WebFetch') -join ','
$deny = @(
    'Bash','PowerShell','Write','Edit','NotebookEdit'
    'Agent','Workflow','Artifact','Skill','DesignSync'
    'RemoteTrigger','PushNotification','SendMessage'
    'Task*','Cron*','EnterWorktree','ExitWorktree','Monitor'
    'mcp__ghl__*','mcp__claude_ai_Microsoft_365__*','mcp__claude_ai_Google_Calendar__*'
    'mcp__claude_ai_Slack__*','mcp__claude_ai_Gamma__*','mcp__claude_ai_Higgsfield__*'
    'mcp__claude_ai_ClickUp__*','mcp__claude_ai_Notion__*','mcp__claude_ai_Gmail__*'
    'mcp__claude_ai_Google_Drive__*'
) -join ','

$raw = ""
try {
    $raw = $prompt | & $claude -p `
              --allowedTools $allow --disallowedTools $deny `
              --mcp-config "C:\Users\saraa\.aya\mcp-content.json" --strict-mcp-config `
              --add-dir "C:\Users\saraa\OneDrive\Aya" `
              --permission-mode dontAsk --model sonnet 2>&1 | Out-String
} catch {
    Log "FINISH FAILED: claude invocation threw: $($_.Exception.Message)"
    exit 1
}

$json = $null
$m = [regex]::Match($raw, '(?s)\{.*\}')
if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { $json = $null } }
if (-not $json -or [string]::IsNullOrWhiteSpace($json.report_md)) {
    $snip = ($raw -replace '\s+', ' ')
    if ($snip.Length -gt 400) { $snip = $snip.Substring(0, 400) }
    Log "FINISH FAILED: no usable JSON. Model said: $snip"
    exit 1
}

$reportF = Join-Path $dailyDir ((Get-Date -Format 'yyyy-MM-dd') + "-morning-brief.md")

if ($DryRun) {
    Log "FINISH DRYRUN | would write $reportF"
    Write-Output $json.telegram
    exit 0
}

Set-Content -LiteralPath $reportF -Value $json.report_md -Encoding utf8
Log "brief written: $reportF"
if ($json.log) {
    Add-Content -LiteralPath $ayaLog -Encoding utf8 -Value ("{0} | Aya | morning brief: {1}" -f (Get-Date -Format 'yyyy-MM-dd'), "$($json.log)")
}

if (-not [string]::IsNullOrWhiteSpace($tg) -and -not [string]::IsNullOrWhiteSpace($chat)) {
    $msg = "$($json.telegram)".Trim()
    if (-not $msg) { $msg = "Morning brief is written and filed in the daily notes." }
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tg/sendMessage" -Method Post -TimeoutSec 30 `
             -Body @{ chat_id = $chat; text = $msg }
        if ($r.ok) { Log "FINISH ok | telegram message_id $($r.result.message_id)" } else { Log "FINISH ok but telegram failed: $($r.description)" }
    } catch { Log "FINISH ok but telegram failed: $($_.Exception.Message)" }
}
exit 0
