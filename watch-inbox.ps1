# AYA WATCHES THE INBOX FOLDER
#
# Sara drops a video in Files\_Inbox and Aya watches it. No size limit, no API,
# no base64, no vendor.
#
# This is the path that actually works for her own recordings:
#   Telegram        capped at 20MB by the Bot API. Fine for a clip.
#   Google Drive    download_file_content returns base64 through the context
#                   window, so a real video blows the limit. Not viable.
#   This folder     no limit. And it lives in OneDrive, so she can drop a file
#                   from her phone and it arrives here on its own.
#
#   powershell -File watch-inbox.ps1
#   -DryRun   list what it would watch and stop

param([switch]$DryRun)

$ErrorActionPreference = 'Continue'
$dir    = "C:\Users\saraa\.aya"
$runlog = Join-Path $dir "runner.log"
$inbox  = "C:\Users\saraa\OneDrive\Aya\Files\_Inbox"
$done   = "C:\Users\saraa\OneDrive\Aya\Files\_Archive\watched"

# Audio counts. A recorded call is usually m4a or mp3, not video, and the
# pipeline treats them identically because only the audio ever mattered.
$EXT = @('.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi', '.wmv', '.m4a', '.mp3', '.wav', '.oga', '.ogg', '.aac', '.flac')

function Log([string]$m) {
    $line = "{0} | runner | inbox-watch {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

if (-not (Test-Path -LiteralPath $inbox)) { New-Item -ItemType Directory -Path $inbox -Force | Out-Null }

$files = @(Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
           Where-Object { $EXT -contains $_.Extension.ToLower() })

# The quiet case is the common case. Exit before logging, or this becomes 90
# identical lines a day and the log stops being readable.
if ($files.Count -eq 0) { exit 0 }

Log "START | $($files.Count) media file(s) in the inbox"

foreach ($f in $files) {
    # OneDrive sync and a long upload both mean a file can be present but still
    # growing. Watching a half-written file produces a note about the first
    # third of a video, which is worse than waiting.
    $len1 = $f.Length
    Start-Sleep -Seconds 3
    $cur = Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $cur) { Log "  $($f.Name) vanished, skipping"; continue }
    if ($cur.Length -ne $len1) {
        Log "  $($f.Name) is still growing ($len1 to $($cur.Length) bytes), leaving it for the next run"
        continue
    }

    # A OneDrive placeholder is a stub on disk with the real bytes in the cloud.
    # Reading it would either fail or hang, so trigger the download and move on.
    if ($cur.Attributes -band [System.IO.FileAttributes]::Offline) {
        Log "  $($f.Name) is a OneDrive placeholder, not downloaded locally yet. Leaving it."
        continue
    }

    $mb = [math]::Round($cur.Length / 1MB, 1)
    Log "  watching $($f.Name) (${mb}MB)"
    if ($DryRun) { continue }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $dir "watch.ps1") -Target $cur.FullName | Out-Null
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        # Move it out so the next run does not reconsider it. The ledger in
        # watch.ps1 also guards against this, but a file left in an inbox
        # forever is its own kind of mess.
        if (-not (Test-Path -LiteralPath $done)) { New-Item -ItemType Directory -Path $done -Force | Out-Null }
        $dest = Join-Path $done $f.Name
        $n = 1
        while (Test-Path -LiteralPath $dest) {
            $dest = Join-Path $done ("{0} ({1}){2}" -f $f.BaseName, $n, $f.Extension); $n++
        }
        try { Move-Item -LiteralPath $cur.FullName -Destination $dest -Force; Log "  archived to $dest" }
        catch { Log "  WARN: watched but could not archive: $($_.Exception.Message)" }
    } else {
        # Left in place deliberately. A failed extraction is worth retrying
        # after whatever broke is fixed, and a silently deleted input is not
        # recoverable.
        Log "  FAILED on $($f.Name), exit $code. Left in the inbox for a retry."
    }
}

Log "FINISH"
exit 0
