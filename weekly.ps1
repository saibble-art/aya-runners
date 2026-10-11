# AYA WEEKLY CHECK RUNNER
#
# Fridays. Builds the five-line weekly status from the vault plus live
# surfaces, writes the full report to Brain/notes/weekly/, sends ONE
# Telegram message. Unlike the sweep, this always sends: the weekly status
# is expected, so silence here is a failure, not politeness.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\weekly.ps1
#   add -DryRun to run without sending Telegram or writing the report

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
$promptF  = Join-Path $dir "prompts\weekly.md"
$claude   = "C:\Users\saraa\.local\bin\claude.exe"
$ayaLog   = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"
$weeklyDir = "C:\Users\saraa\OneDrive\Aya\Brain\notes\weekly"

function Log([string]$msg) {
    $line = "{0} | runner | weekly {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
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
if ([string]::IsNullOrWhiteSpace($tg) -or [string]::IsNullOrWhiteSpace($chat)) {
    Log "ABORT: Telegram credentials missing"; exit 1
}

if (-not (Test-Path -LiteralPath $claude))  { Log "ABORT: claude.exe missing"; exit 1 }
if (-not (Test-Path -LiteralPath $promptF)) { Log "ABORT: prompt missing"; exit 1 }
if (-not (Test-Path -LiteralPath $weeklyDir)) { New-Item -ItemType Directory -Path $weeklyDir -Force | Out-Null }

$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$prompt = (Get-Content -LiteralPath $promptF -Raw).Replace('{{NOW}}', $now)

# Same lane as the sweep, drafts off. Reading only; the runner delivers.
. "C:\Users\saraa\.aya\lane.ps1"
$tools = (Get-AyaAllowList -DraftsOn:$false) -join ','
$deny  = (Get-AyaDenyList  -DraftsOn:$false) -join ','

$raw = ""
try {
    $raw = $prompt | & $claude -p `
              --allowedTools $tools --disallowedTools $deny `
              --add-dir "C:\Users\saraa\OneDrive\Aya" `
              --permission-mode dontAsk --model sonnet 2>&1 | Out-String
} catch {
    Log "FINISH FAILED: claude invocation threw: $($_.Exception.Message)"
    exit 1
}

$json = $null
$m = [regex]::Match($raw, '(?s)\{.*\}')
if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { $json = $null } }
if (-not $json -or [string]::IsNullOrWhiteSpace($json.telegram)) {
    $snip = ($raw -replace '\s+', ' ')
    if ($snip.Length -gt 400) { $snip = $snip.Substring(0, 400) }
    Log "FINISH FAILED: no usable JSON. Model said: $snip"
    exit 1
}

# The desk version, written first so it exists even if the send fails.
$reportF = Join-Path $weeklyDir ((Get-Date -Format 'yyyy-MM-dd') + "-weekly.md")
if (-not $DryRun -and -not [string]::IsNullOrWhiteSpace($json.report_md)) {
    Set-Content -LiteralPath $reportF -Value $json.report_md -Encoding utf8
    Log "report written: $reportF"
}

if (-not $DryRun -and $json.log) {
    $l = "{0} | Aya | weekly check: {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $json.log
    Add-Content -LiteralPath $ayaLog -Value $l -Encoding utf8
}

if ($DryRun) {
    Log "FINISH DRYRUN | would have sent:"
    Write-Output "-----"
    Write-Output $json.telegram
    Write-Output "-----"
    exit 0
}

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
    Log "FINISH ok | weekly status sent | telegram message_id $($r.result.message_id)"
    exit 0
} else {
    $desc = "no detail: $rawErr"
    if ($r -and $r.description) { $desc = "$($r.error_code) $($r.description)" }
    Log "FINISH FAILED: telegram $desc | report still on disk at $reportF"
    exit 1
}
