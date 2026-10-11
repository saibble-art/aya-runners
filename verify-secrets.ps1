# Aya secrets verifier.
#
# Checks that secrets.env exists, is locked down, and that the tokens in it
# actually work. NEVER prints a secret value. Prints shape and length only.
#
#   powershell -ExecutionPolicy Bypass -File C:\Users\saraa\.aya\verify-secrets.ps1

$ErrorActionPreference = 'Stop'
$dir  = "C:\Users\saraa\.aya"
$file = Join-Path $dir "secrets.env"

function Mask([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return "(empty)" }
    if ($v.Length -le 8) { return ("*" * $v.Length) + "  [len $($v.Length)]" }
    return $v.Substring(0,4) + ("*" * ($v.Length - 8)) + $v.Substring($v.Length - 4) + "  [len $($v.Length)]"
}

Write-Output "=== Aya secrets check ==="
Write-Output ""

if (-not (Test-Path -LiteralPath $file)) {
    Write-Output "secrets.env NOT FOUND."
    Write-Output ""
    Write-Output "Create it:"
    Write-Output "   copy `"$dir\secrets.env.template`" `"$file`""
    Write-Output "Then open it in Notepad and paste the values."
    exit 1
}

# --- 1. Is the folder outside OneDrive ---
if ($dir -match 'OneDrive') { Write-Output "FAIL  This folder is inside OneDrive. Secrets must not sync." }
else { Write-Output "PASS  Outside OneDrive, so nothing syncs to the cloud." }

# --- 2. Who can read it ---
$acl = (Get-Acl -LiteralPath $file).Access |
       Where-Object { $_.IdentityReference -notmatch 'NT AUTHORITY\\SYSTEM' } |
       ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
$others = $acl | Where-Object { $_ -notmatch [regex]::Escape($env:USERNAME) -and $_ -notmatch 'BUILTIN\\Administrators' }
if ($others) { Write-Output "WARN  Readable by: $($others -join ', ')  Run the lockdown block at the bottom of this file." }
else { Write-Output "PASS  Readable only by you and Administrators." }

# --- 3. Parse ---
$env_ = @{}
foreach ($line in Get-Content -LiteralPath $file) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $env_[$k.Trim()] = $v.Trim()
}

Write-Output ""
Write-Output "--- Values present (masked) ---"
foreach ($k in @('TELEGRAM_BOT_TOKEN','SARA_TELEGRAM_CHAT_ID','DISCORD_BOT_TOKEN','DISCORD_BOT_USER_ID','DISCORD_GUILD_ID','OPENROUTER_API_KEY')) {
    "{0,-24} {1}" -f $k, (Mask $env_[$k])
}

# --- 4. Shape check on the Telegram token ---
Write-Output ""
Write-Output "--- Shape ---"
$tg = $env_['TELEGRAM_BOT_TOKEN']
if ([string]::IsNullOrWhiteSpace($tg)) { Write-Output "SKIP  TELEGRAM_BOT_TOKEN is empty." }
elseif ($tg -match '^\d{8,10}:[A-Za-z0-9_-]{35}$') { Write-Output "PASS  Telegram token has the right shape." }
else { Write-Output "FAIL  Telegram token shape is wrong. Expected digits, a colon, then 35 characters. Check for a stray space or a truncated paste." }

# --- 5. Does it actually work. This is the truth gate. ---
Write-Output ""
Write-Output "--- Live check (proof, not a claim) ---"
if ([string]::IsNullOrWhiteSpace($tg)) {
    Write-Output "SKIP  No token to test."
} else {
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tg/getMe" -Method Get -TimeoutSec 20
        if ($r.ok) {
            Write-Output "PASS  Token is live. Bot id $($r.result.id), username @$($r.result.username), name '$($r.result.first_name)'"
            if ($r.result.username -ne 'Aya_CoS_bot') {
                Write-Output "NOTE  Username is @$($r.result.username), not @Aya_CoS_bot. Rename in BotFather with /setname and /setusername if you still want that."
            }
            if ($r.result.id -eq 8685340124) {
                Write-Output "FAIL  This is the OLD bot id (8685340124), the one whose token leaked. The token was not regenerated. Go back to BotFather and use /revoke."
            } else {
                Write-Output "PASS  Bot id differs from the leaked one, so this is a new credential."
            }
        } else { Write-Output "FAIL  Telegram replied but not ok: $($r.description)" }
    } catch {
        Write-Output "FAIL  Telegram rejected the token or the call failed: $($_.Exception.Message)"
        Write-Output "      A 401 Unauthorized means the token is wrong or already revoked."
    }
}

$dc = $env_['DISCORD_BOT_TOKEN']
if ([string]::IsNullOrWhiteSpace($dc)) {
    Write-Output "SKIP  DISCORD_BOT_TOKEN is empty. Fine for now, needed at step 2."
} else {
    try {
        # Discord requires a real User-Agent. Without it, guild-scoped
        # endpoints 403 with an empty body while users/@me still works,
        # which reads exactly like a permissions problem and is not one.
        # Cost us a false alarm on 2026-08-08.
        $h = @{ Authorization = "Bot $dc"; 'User-Agent' = 'DiscordBot (https://saibble.com, 1.0)' }
        $me = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me" -Headers $h -TimeoutSec 20
        Write-Output "PASS  Discord token is live. Bot $($me.username), id $($me.id)"
        $g = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me/guilds" -Headers $h -TimeoutSec 20
        if (-not $g -or $g.Count -eq 0) {
            Write-Output "FAIL  The bot is in NO server. It has to be invited before it can read anything."
        } else {
            Write-Output "PASS  Bot is in $($g.Count) server(s):"
            $g | ForEach-Object { "        $($_.name)   id $($_.id)" }
            Write-Output ""
            Write-Output "      Channels it can read (this is the list you did not have to type):"
            foreach ($srv in $g) {
                try {
                    $ch = Invoke-RestMethod -Uri "https://discord.com/api/v10/guilds/$($srv.id)/channels" -Headers $h -TimeoutSec 20
                    $ch | Where-Object { $_.type -eq 0 } | Sort-Object position | ForEach-Object { "        #$($_.name)   id $($_.id)" }
                } catch { "        (could not list channels for $($srv.name): $($_.Exception.Message))" }
            }
        }
    } catch {
        Write-Output "FAIL  Discord rejected the token: $($_.Exception.Message)"
    }
}

Write-Output ""
Write-Output "=== done. No secret value was printed above. ==="

# --- Lockdown block. Run these two lines once if the ACL check warned. ---
# icacls "C:\Users\saraa\.aya" /inheritance:r /grant:r "$env:USERNAME:(OI)(CI)F" /grant:r "Administrators:(OI)(CI)F"
# icacls "C:\Users\saraa\.aya\secrets.env" /inheritance:r /grant:r "$env:USERNAME:F"
