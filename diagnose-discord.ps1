# Diagnose why the Discord bot cannot list channels.
# Prints permissions and roles only. Never prints the token.

$ErrorActionPreference = 'Continue'
$file = "C:\Users\saraa\.aya\secrets.env"
$e = @{}
foreach ($line in Get-Content -LiteralPath $file) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $e[$k.Trim()] = $v.Trim()
}
$h = @{ Authorization = "Bot $($e['DISCORD_BOT_TOKEN'])" }

# Discord permission bits that matter for a read-only sweep
$BITS = [ordered]@{
    'ADMINISTRATOR'        = [uint64]8
    'VIEW_CHANNEL'         = [uint64]1024
    'SEND_MESSAGES'        = [uint64]2048
    'READ_MESSAGE_HISTORY' = [uint64]65536
    'MANAGE_CHANNELS'      = [uint64]16
}

Write-Output "=== Discord bot diagnosis ==="
Write-Output ""

$guilds = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me/guilds" -Headers $h -TimeoutSec 20
foreach ($g in $guilds) {
    Write-Output "Server : $($g.name)"
    Write-Output "Id     : $($g.id)"
    Write-Output "Owner  : $($g.owner)"
    $p = [uint64]$g.permissions
    Write-Output "Perms  : $p"
    if ($p -eq 0) {
        Write-Output "         >>> ZERO PERMISSIONS. This is the problem."
    }
    foreach ($k in $BITS.Keys) {
        $has = ($p -band $BITS[$k]) -ne 0
        "         {0,-22} {1}" -f $k, $(if ($has) { "YES" } else { "no" })
    }
    Write-Output ""

    # Can the bot see itself as a member, and what roles does it hold
    try {
        $me = Invoke-RestMethod -Uri "https://discord.com/api/v10/guilds/$($g.id)/members/$($e['DISCORD_BOT_USER_ID'])" -Headers $h -TimeoutSec 20
        Write-Output "Member : yes. Roles held: $($me.roles.Count)"
        if ($me.roles.Count -eq 0) { Write-Output "         >>> The bot holds NO role, so it inherits only @everyone." }
    } catch {
        Write-Output "Member lookup failed: $($_.Exception.Message)"
    }

    # Retry the channel list and capture the exact Discord error body
    try {
        $ch = Invoke-RestMethod -Uri "https://discord.com/api/v10/guilds/$($g.id)/channels" -Headers $h -TimeoutSec 20
        Write-Output "Channels: $($ch.Count) returned"
        $ch | Where-Object { $_.type -eq 0 } | Sort-Object position | ForEach-Object { "         #$($_.name)  id $($_.id)" }
    } catch {
        $resp = $_.Exception.Response
        $body = ""
        if ($resp) {
            try { $body = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch {}
        }
        Write-Output "Channels: FAILED"
        Write-Output "         HTTP  : $([int]$resp.StatusCode) $($resp.StatusCode)"
        Write-Output "         Body  : $body"
    }
    Write-Output ""
}

# The invite URL that fixes a permissions problem, read only
$readOnly = 1024 + 65536          # VIEW_CHANNEL + READ_MESSAGE_HISTORY
$withSend = 1024 + 65536 + 2048   # plus SEND_MESSAGES, for trust ladder rung 3
$id = $e['DISCORD_BOT_USER_ID']
Write-Output "--- Re-invite URLs (same bot, adds permissions) ---"
Write-Output "Read only  : https://discord.com/api/oauth2/authorize?client_id=$id&scope=bot&permissions=$readOnly"
Write-Output "With replies: https://discord.com/api/oauth2/authorize?client_id=$id&scope=bot&permissions=$withSend"
