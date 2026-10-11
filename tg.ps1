# Telegram, one implementation. Dot-sourced by heartbeat.ps1, sweep.ps1, inbox.ps1.
#
#   . C:\Users\saraa\.aya\tg.ps1
#   $s = Get-AyaSecrets
#   Send-AyaText  -Secrets $s -Text "..."
#   Send-AyaVoice -Secrets $s -Text "..." -Caption "..."
#   Get-AyaUpdates -Secrets $s        # returns Sara's new messages, claims the offset

# Discord snapshot for CONVERSATION. Until 2026-08-10 Aya in chat had no live
# Discord: the sweep fetched it every 30 min but chat could not reach it, so
# when Sara asked for a Discord update Aya said "no Discord tool available".
# This pulls the recent messages from every readable channel on demand and
# returns a formatted string the chat runner puts in front of Aya.
#
# #credentials (1481349935302705297) is never read. Blocked channels (403) are
# reported as blocked, not as empty, so silence is never mistaken for calm.
function Get-AyaDiscordSnapshot {
    param([hashtable]$Secrets, [int]$PerChannel = 12)
    $dc = $Secrets['DISCORD_BOT_TOKEN']
    if ([string]::IsNullOrWhiteSpace($dc)) { return "Discord not configured." }
    # Never read: #credentials (secrets). Ignored per Sara 2026-08-10 because she
    # does not see them herself and they always 403: #day-start-day-end-reports,
    # #team-internal. Skipped silently, never reported as blocked, never asked about.
    $BLOCKED = @('1481349935302705297','1532751710387306547','1481349761163591751')
    $h = @{ Authorization = "Bot $dc"; 'User-Agent' = 'DiscordBot (https://saibble.com, 1.0)' }
    $out = New-Object System.Collections.Generic.List[string]
    $noAccess = @()
    try {
        $guilds = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me/guilds" -Headers $h -TimeoutSec 20
        $out.Add("DISCORD SNAPSHOT as of $(Get-Date -Format 'yyyy-MM-dd HH:mm') Central. Live pull.")
        foreach ($g in $guilds) {
            $chans = Invoke-RestMethod -Uri "https://discord.com/api/v10/guilds/$($g.id)/channels" -Headers $h -TimeoutSec 20
            foreach ($c in ($chans | Where-Object { $_.type -eq 0 } | Sort-Object position)) {
                if ($BLOCKED -contains $c.id) { continue }
                try { $msgs = Invoke-RestMethod -Uri "https://discord.com/api/v10/channels/$($c.id)/messages?limit=$PerChannel" -Headers $h -TimeoutSec 20 }
                catch {
                    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) { $noAccess += "#$($c.name)" }
                    continue
                }
                $human = @($msgs | Where-Object { -not $_.author.bot -and -not [string]::IsNullOrWhiteSpace($_.content) } | Sort-Object { [decimal]$_.id })
                if ($human.Count -eq 0) { continue }
                $out.Add("")
                $out.Add("### #$($c.name)")
                foreach ($m in $human) {
                    $who = $m.author.global_name; if (-not $who) { $who = $m.author.username }
                    $txt = ($m.content -replace '\s+', ' '); if ($txt.Length -gt 500) { $txt = $txt.Substring(0,500) + ' [cut]' }
                    $when = ([datetimeoffset]$m.timestamp).ToLocalTime().ToString('MM-dd HH:mm')
                    $out.Add("- [$when] $who : $txt")
                }
            }
        }
        if ($noAccess.Count) { $out.Add(""); $out.Add("NO ACCESS (403, not empty, Sara must grant the bot View Channel + Read Message History): $($noAccess -join ', ')") }
    } catch {
        return "Discord could not be reached this run: $($_.Exception.Message)"
    }
    return ($out -join "`n")
}

# Sara sends voice notes. Until 2026-08-09 Aya could speak but not listen,
# which is a strange shape for a chief of staff.
#
# Downloads the voice file from Telegram and transcribes it locally with
# faster-whisper. Local on purpose: she talks about clients and revenue, and
# that audio should not leave the machine.
function Get-AyaTranscript {
    param([hashtable]$Secrets, [string]$FileId, [int]$Duration = 0)

    $py = "C:\Users\saraa\AppData\Local\Programs\Python\Python313\python.exe"
    $script = "C:\Users\saraa\.aya\transcribe.py"
    if (-not (Test-Path -LiteralPath $py) -or -not (Test-Path -LiteralPath $script)) {
        return @{ ok = $false; text = $null; detail = "transcriber not installed" }
    }
    # A very long note is more likely a misfire than an instruction, and
    # transcribing it would block the listener for a long time.
    if ($Duration -gt 300) {
        return @{ ok = $false; text = $null; detail = "voice note is ${Duration}s, too long to transcribe inline" }
    }

    $tok = $Secrets['TELEGRAM_BOT_TOKEN']
    try {
        $f = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tok/getFile?file_id=$FileId" -TimeoutSec 30
        if (-not $f.ok) { return @{ ok = $false; text = $null; detail = "getFile: $($f.description)" } }
        $ext = [System.IO.Path]::GetExtension($f.result.file_path)
        if (-not $ext) { $ext = ".oga" }
        $local = Join-Path $env:TEMP ("aya-in-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + $ext)
        Invoke-WebRequest -Uri "https://api.telegram.org/file/bot$tok/$($f.result.file_path)" `
            -OutFile $local -TimeoutSec 90 | Out-Null
    } catch {
        return @{ ok = $false; text = $null; detail = "download failed: $($_.Exception.Message)" }
    }

    # Two attempts in two separate processes. transcribe.py already retries
    # internally and falls back to tiny.en, but if the whole Python process
    # dies (the 2026-08-12 mkl_malloc failures killed it outright), only a
    # fresh process helps. The audio file is kept until both attempts are
    # done, because deleting it after attempt one made a retry impossible.
    $out = ""
    foreach ($attempt in 1, 2) {
        try { $out = (& $py $script $local 2>&1 | Out-String).Trim() }
        catch { $out = "TRANSCRIBE_FAILED: $($_.Exception.Message)" }

        # Keep only the last non-empty line. The library prints progress noise
        # on first run while it downloads the model, and that noise is not
        # speech.
        $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -gt 0) { $out = $lines[-1].Trim() }

        if ($out -and $out -notlike "TRANSCRIBE_FAILED*") { break }
        if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
    }
    Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue

    if (-not $out -or $out -like "TRANSCRIBE_FAILED*") {
        return @{ ok = $false; text = $null; detail = $out }
    }
    return @{ ok = $true; text = $out; detail = "transcribed ${Duration}s" }
}

# Downloads any Telegram file to disk and returns the path.
#
# The Bot API caps getFile downloads at 20MB. That is a Telegram limit, not
# something to work around, so callers check the size first and tell Sara to
# use the Inbox folder for anything bigger. A training recording will always be
# bigger.
function Get-AyaTelegramFile {
    param([hashtable]$Secrets, [string]$FileId, [string]$Dir = "")
    if (-not $Dir) { $Dir = Join-Path $env:TEMP "aya-media" }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $tok = $Secrets['TELEGRAM_BOT_TOKEN']
    try {
        $f = Invoke-RestMethod -Uri "https://api.telegram.org/bot$tok/getFile?file_id=$FileId" -TimeoutSec 30
        if (-not $f.ok) { return @{ ok = $false; path = $null; detail = "getFile: $($f.description)" } }
        $ext = [System.IO.Path]::GetExtension($f.result.file_path)
        if (-not $ext) { $ext = ".bin" }
        $local = Join-Path $Dir ("tg-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + $ext)
        Invoke-WebRequest -Uri "https://api.telegram.org/file/bot$tok/$($f.result.file_path)" `
            -OutFile $local -TimeoutSec 300 | Out-Null
        if (-not (Test-Path -LiteralPath $local)) { return @{ ok = $false; path = $null; detail = "download produced no file" } }
        return @{ ok = $true; path = $local; detail = "$([math]::Round((Get-Item $local).Length/1MB,1))MB" }
    } catch {
        return @{ ok = $false; path = $null; detail = $_.Exception.Message }
    }
}

function Get-AyaSecrets {
    $f = "C:\Users\saraa\.aya\secrets.env"
    if (-not (Test-Path -LiteralPath $f)) { throw "secrets.env missing" }
    $e = @{}
    foreach ($l in Get-Content -LiteralPath $f) {
        if ($l -match '^\s*#' -or $l -notmatch '=') { continue }
        $k, $v = $l -split '=', 2
        $e[$k.Trim()] = $v.Trim()
    }
    return $e
}

# Invoke-RestMethod, never curl.exe. PowerShell mangles native-exe arguments,
# which once surfaced as "could not resolve host" while DNS was perfectly fine.
# $_.ErrorDetails.Message is where PowerShell 5.1 puts the response body on a
# 4xx, and that body is the whole diagnosis.
function Send-AyaText {
    param([hashtable]$Secrets, [string]$Text)
    $r = $null; $err = $null
    try {
        $r = Invoke-RestMethod -Method Post -TimeoutSec 30 `
             -Uri "https://api.telegram.org/bot$($Secrets['TELEGRAM_BOT_TOKEN'])/sendMessage" `
             -Body @{ chat_id = $Secrets['SARA_TELEGRAM_CHAT_ID']; text = $Text }
    } catch {
        $err = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $r = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $err = $_.ErrorDetails.Message }
        }
    }
    if ($r -and $r.ok) { return @{ ok = $true;  detail = "message_id $($r.result.message_id)" } }
    if ($r -and $r.description) { return @{ ok = $false; detail = "$($r.error_code) $($r.description)" } }
    return @{ ok = $false; detail = "no detail: $err" }
}

# Sara asked for audio so she gets the picture while away from her desk.
# Windows SAPI, deliberately: free, offline, no API key, no per-message cost,
# and it cannot fail because a vendor is down. The voice is not beautiful. It
# is for "what needs me right now" in a car, not for publishing.
#
# ffmpeg is not installed, so there is no ogg/opus encode. Telegram accepts
# the WAV on sendVoice anyway and renders a playable bubble, verified
# 2026-08-09. If ffmpeg ever lands, encode to ogg/opus for a smaller file.
function Send-AyaVoice {
    param([hashtable]$Secrets, [string]$Text, [string]$Caption = "")

    # Voice comes from voice.ps1, one definition. Sara chose Michelle on
    # 2026-08-09 and asked for faster and more upbeat, so the rate and pitch
    # live there and every channel that speaks changes together.
    . "C:\Users\saraa\.aya\voice.ps1"
    $r = New-AyaSpeech -Text $Text
    if (-not $r.ok) { return @{ ok = $false; detail = "tts produced no file" } }
    $wav = $r.path
    $engine = $r.engine

    $bytes = [System.IO.File]::ReadAllBytes($wav)
    $L1 = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $bd = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("--$bd$LF Content-Disposition: form-data; name=`"chat_id`"$LF$LF$($Secrets['SARA_TELEGRAM_CHAT_ID'])$LF".Replace("$LF ", $LF))
    if ($Caption) {
        [void]$sb.Append("--$bd$LF")
        [void]$sb.Append("Content-Disposition: form-data; name=`"caption`"$LF$LF$Caption$LF")
    }
    [void]$sb.Append("--$bd$LF")
    $fname = "aya" + [System.IO.Path]::GetExtension($wav)
    [void]$sb.Append("Content-Disposition: form-data; name=`"voice`"; filename=`"$fname`"$LF")
    [void]$sb.Append("Content-Type: application/octet-stream$LF$LF")
    [void]$sb.Append($L1.GetString($bytes))
    [void]$sb.Append("$LF--$bd--$LF")

    $r = $null; $err = $null
    try {
        $r = Invoke-RestMethod -Method Post -TimeoutSec 90 `
             -Uri "https://api.telegram.org/bot$($Secrets['TELEGRAM_BOT_TOKEN'])/sendVoice" `
             -ContentType "multipart/form-data; boundary=$bd" `
             -Body ($L1.GetBytes($sb.ToString()))
    } catch {
        $err = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $r = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $err = $_.ErrorDetails.Message }
        }
    }
    Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue

    if ($r -and $r.ok) { return @{ ok = $true;  detail = "voice message_id $($r.result.message_id) via $engine" } }
    if ($r -and $r.description) { return @{ ok = $false; detail = "$($r.error_code) $($r.description)" } }
    return @{ ok = $false; detail = "no detail: $err" }
}

# Inbound. This is the half that was missing until 2026-08-09: Aya could talk
# to Sara but had no way to hear her.
#
# CLAIMS THE OFFSET BEFORE RETURNING. Telegram deletes an update once you
# acknowledge it with a higher offset, so the offset must be persisted before
# the caller does anything with the messages. A crash after processing but
# before claiming would otherwise replay the same instruction forever.
function Get-AyaUpdates {
    param([hashtable]$Secrets, [switch]$NoClaim)

    $offFile = "C:\Users\saraa\.aya\state\telegram-offset.txt"
    $offset = 0
    if (Test-Path -LiteralPath $offFile) {
        $raw = (Get-Content -LiteralPath $offFile -Raw).Trim()
        if ($raw -match '^\d+$') { $offset = [int]$raw }
    }

    $url = "https://api.telegram.org/bot$($Secrets['TELEGRAM_BOT_TOKEN'])/getUpdates?timeout=0&allowed_updates=[`"message`"]"
    if ($offset -gt 0) { $url += "&offset=$offset" }

    try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 30 }
    catch { return @{ ok = $false; detail = $_.Exception.Message; messages = @() } }
    if (-not $r.ok) { return @{ ok = $false; detail = $r.description; messages = @() } }

    $mine = @()
    $maxId = $offset - 1
    foreach ($u in $r.result) {
        if ($u.update_id -gt $maxId) { $maxId = $u.update_id }
        if (-not $u.message) { continue }
        # Only Sara. A bot that acts on messages from anyone who finds it is
        # an open command channel.
        if ([string]$u.message.chat.id -ne [string]$Secrets['SARA_TELEGRAM_CHAT_ID']) { continue }
        $text = $u.message.text
        if ([string]::IsNullOrWhiteSpace($text)) {
            if ($u.message.caption) { $text = $u.message.caption }
            elseif ($u.message.voice -or $u.message.audio) {
                $v = $u.message.voice; if (-not $v) { $v = $u.message.audio }
                $t = Get-AyaTranscript -Secrets $Secrets -FileId $v.file_id -Duration $v.duration
                if ($t.ok) {
                    # Marked as transcribed so Aya knows it came through speech
                    # and can allow for a misheard word rather than treating it
                    # as something Sara typed and meant exactly.
                    $text = "[voice note, transcribed] " + $t.text
                } else {
                    $text = "[Sara sent a voice note, $($v.duration)s, and transcription failed: $($t.detail). Tell her plainly that this one did not come through and ask her to resend or type it.]"
                }
            }
            else { continue }
        }
        $mine += [pscustomobject]@{
            update_id = $u.update_id
            date      = ([datetimeoffset]::FromUnixTimeSeconds($u.message.date)).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
            text      = $text.Trim()
        }
    }

    if (-not $NoClaim -and $maxId -ge $offset) {
        Set-Content -LiteralPath $offFile -Value ([string]($maxId + 1)) -Encoding utf8
    }
    return @{ ok = $true; detail = "$($mine.Count) message(s) from Sara"; messages = $mine }
}
