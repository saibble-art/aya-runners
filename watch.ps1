# AYA WATCHES A VIDEO
#
#   powershell -File watch.ps1 -Target "https://youtube.com/watch?v=..."
#   powershell -File watch.ps1 -Target "C:\path\to\call-recording.mp4"
#   powershell -File watch.ps1 -Target "..." -Quiet     # no Telegram message
#
# Writes a note to Brain/notes/videos/ and tells Sara what was in it.
#
# Division of labour, same as everywhere else in this system:
#   Python extracts the transcript. Mechanical, deterministic, no judgment.
#   Aya reads it and decides what matters. Judgment, no file writing.
#   PowerShell writes the note. Exact, validated, auditable.

param(
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$Quiet,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$dir     = "C:\Users\saraa\.aya"
$state   = Join-Path $dir "state"
$runlog  = Join-Path $dir "runner.log"
$py      = "C:\Users\saraa\AppData\Local\Programs\Python\Python313\python.exe"
$claude  = "C:\Users\saraa\.local\bin\claude.exe"
$notesD  = "C:\Users\saraa\OneDrive\Aya\Brain\notes\videos"
$ayaLog  = "C:\Users\saraa\OneDrive\Aya\Brain\log.md"
$ledgerF = Join-Path $state "watched.json"

foreach ($d in @($state, $notesD)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
function Log([string]$m) {
    $line = "{0} | runner | watch {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -LiteralPath $runlog -Value $line -Encoding utf8
    Write-Output $line
}

. (Join-Path $dir "tg.ps1")
. (Join-Path $dir "lane.ps1")
$sec = Get-AyaSecrets

Log "START | $Target"

# ---------- already watched? ----------
# Re-watching the same video burns tokens to produce a note that already
# exists. The ledger is keyed on the URL or the absolute file path.
$ledger = @{}
if (Test-Path -LiteralPath $ledgerF) {
    try { (Get-Content -LiteralPath $ledgerF -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ledger[$_.Name] = $_.Value } }
    catch { Log "WARN: watch ledger unreadable, treating as empty" }
}
$key = $Target.Trim()
if ($ledger.ContainsKey($key) -and -not $DryRun) {
    Log "FINISH already watched on $($ledger[$key].date), note at $($ledger[$key].note)"
    if (-not $Quiet) {
        $null = Send-AyaText -Secrets $sec -Text "I already watched that one. My notes are in the brain under videos, filed $($ledger[$key].date)."
    }
    exit 0
}

# ---------- extract ----------
$json = Join-Path $env:TEMP ("aya-vid-" + [guid]::NewGuid().ToString('N') + ".json")
$status = (& $py (Join-Path $dir "extract_video.py") $Target $json 2>&1 | Out-String).Trim()
$statusLine = @($status -split "`r?`n" | Where-Object { $_.Trim() })[-1]

if ($statusLine -notlike "EXTRACT_OK*") {
    Log "FINISH FAILED: $statusLine"
    if (-not $Quiet) {
        $reason = $statusLine -replace '^EXTRACT_FAILED:\s*', ''
        $null = Send-AyaText -Secrets $sec -Text "I could not get a transcript for that. $reason"
    }
    Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue
    exit 1
}

# Metadata comes from the JSON, NOT from parsing the status line.
# The status line was pipe-delimited until a 3Blue1Brown title containing a
# literal pipe split into the wrong fields and turned the duration into
# " Deep learning chapter 1". Any delimiter you pick appears in someone's video
# title eventually, so do not use one: read the structured file.
try { $meta = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json }
catch { Log "FINISH FAILED: extractor wrote unreadable JSON"; exit 1 }

$kindRaw = $meta.kind
$title   = "$($meta.title)".Trim()
$durSec  = [int]$meta.duration_sec
$words   = [int]$meta.word_count
$author  = "$($meta.author)".Trim()
$mins    = [math]::Round($durSec / 60)
if (-not $title) { $title = 'untitled video' }
Log "extracted via $kindRaw | '$title' | ${mins} min | $words words"

# A very long transcript will not fit sensibly in one pass. Say so rather than
# silently truncating and producing a note about the first third of a video.
$truncated = $false
if ($words -gt 30000) {
    $truncated = $true
    Log "WARN: $words words, the note will cover the transcript in full but detail thins out past the first 30k"
}

# ---------- Aya reads it ----------
$prompt = (Get-Content -LiteralPath (Join-Path $dir "prompts\watch.md") -Raw)
$prompt += "`n`n---`n`nVIDEO: $title`nSOURCE: $Target`nAUTHOR: $author`nLENGTH: $mins minutes`nTRANSCRIPT_JSON: $json`n"
$prompt += "`nRead the transcript from that JSON file. Each entry has 't' in seconds and 'text'.`n"
if ($truncated) { $prompt += "`nNOTE: this is a long transcript, about $words words. Cover the whole thing. If you cannot, say which part you covered in 'unverified'.`n" }

# Read only. No drafts, no sends. Watching a video is not a reason to touch
# the outside world.
$allow = ((Get-AyaAllowList -DraftsOn:$false) + @('Glob', 'Grep')) -join ','
$deny  = (Get-AyaDenyList -DraftsOn:$false) -join ','

$raw = ""
try {
    $raw = $prompt | & $claude -p `
              --allowedTools $allow --disallowedTools $deny `
              --add-dir "C:\Users\saraa\OneDrive\Aya" --add-dir $env:TEMP `
              --permission-mode dontAsk --model sonnet 2>&1 | Out-String
} catch {
    Log "FINISH FAILED: claude threw: $($_.Exception.Message)"
    Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue
    exit 1
}

$m = [regex]::Match($raw, '(?s)\{.*\}')
$v = $null
if ($m.Success) { try { $v = $m.Value | ConvertFrom-Json } catch { $v = $null } }
if (-not $v) {
    $snip = ($raw -replace '\s+', ' '); if ($snip.Length -gt 300) { $snip = $snip.Substring(0, 300) }
    Log "FINISH FAILED: no parseable JSON. Model said: $snip"
    Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue
    exit 1
}

# ---------- injection check, loudly ----------
# A video that tries to instruct the agent reading it is a security event, not
# a footnote. It goes in the log, the note, and the message to Sara.
$inj = @()
if ($v.injection_attempts) { $inj = @($v.injection_attempts | Where-Object { $_ }) }
if ($inj.Count -gt 0) {
    foreach ($i in $inj) { Log "  INJECTION ATTEMPT in transcript: $i" }
}

# ---------- write the note ----------
function Slug([string]$s) {
    $x = $s.ToLower() -replace '[^a-z0-9]+', '-'
    $x = $x.Trim('-')
    if ($x.Length -gt 60) { $x = $x.Substring(0, 60).Trim('-') }
    if (-not $x) { $x = 'video' }
    return $x
}
$date = Get-Date -Format 'yyyy-MM-dd'
$noteF = Join-Path $notesD ("$date-" + (Slug $title) + ".md")

function TS([int]$sec) {
    $h = [math]::Floor($sec / 3600); $mn = [math]::Floor(($sec % 3600) / 60); $s = $sec % 60
    if ($h -gt 0) { return ("{0}:{1:00}:{2:00}" -f $h, $mn, $s) }
    return ("{0}:{1:00}" -f $mn, $s)
}
$isYT = $Target -match 'youtu'
$ytId = ''
if ($Target -match '(?:v=|youtu\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})') { $ytId = $Matches[1] }
if ($isYT -and -not $ytId) { Log "WARN: could not parse a video id, timestamps will be plain text not links" }

$L = New-Object System.Collections.Generic.List[string]
$L.Add('---')
$L.Add('type: video')
$L.Add("kind: $($v.kind)")
$L.Add("title: `"$($title -replace '"','')`"")
if ($author) { $L.Add("author: `"$($author -replace '"','')`"") }
$L.Add("source: $Target")
$L.Add("extraction: $kindRaw")
$L.Add("duration_min: $mins")
$L.Add("word_count: $words")
$L.Add("watched: $date")
if ($v.sensitive) { $L.Add('sensitive: true') }
if ($v.thin) { $L.Add('thin: true') }
$tags = @(); if ($v.tags) { $tags = @($v.tags | Where-Object { $_ }) }
$L.Add("tags: [video, $($tags -join ', ')]")
$L.Add("summary: $($v.summary)")
$L.Add('---')
$L.Add('')
$L.Add("# $title")
$L.Add('')

if ($v.sensitive) {
    $L.Add('> **SENSITIVE.** This is a client conversation. Commercial terms discussed')
    $L.Add('> here are recorded, never reused. Never carry pricing, rates, or terms from')
    $L.Add('> this note into another client, a proposal, or any content. See the')
    $L.Add('> standing constraints in the vault.')
    $L.Add('')
}
if ($inj.Count -gt 0) {
    $L.Add('> [!danger] This transcript tried to issue instructions')
    $L.Add('> Treated as evidence and not followed. Verbatim:')
    foreach ($i in $inj) { $L.Add("> - `"$i`"") }
    $L.Add('')
}

$L.Add('## What Sara gets from this')
$L.Add('')
$L.Add($v.one_liner_for_sara)
$L.Add('')
if ($v.thin) {
    $L.Add("**Thin.** $mins minutes for what is below. Worth knowing before spending time on this source again.")
    $L.Add('')
}

if ($v.key_points) {
    $L.Add('## Key points')
    $L.Add('')
    $L.Add('| At | What it says | What it means here |')
    $L.Add('|---|---|---|')
    foreach ($k in $v.key_points) {
        $t = TS([int]$k.t)
        $stamp = $t
        if ($isYT -and $ytId) {
            # ${ytId} braced deliberately. Unbraced, PowerShell reads "$ytId?t"
            # as one variable name, which produced links like
            # "https://youtu.be/=172" with the id silently missing. Caught only
            # by reading the finished note rather than trusting it was written.
            $stamp = "[$t](https://youtu.be/${ytId}?t=$([int]$k.t))"
        }
        $why = "$($k.why_it_matters)"; if (-not $why) { $why = '-' }
        # Pipes inside a claim would break the markdown table, and video titles
        # and quotes contain them. Same collision that broke the status line.
        $L.Add("| $stamp | $($k.claim -replace '\|','/') | $($why -replace '\|','/') |")
    }
    $L.Add('')
}

$act = @(); if ($v.actionable) { $act = @($v.actionable | Where-Object { $_ }) }
$L.Add('## Actionable')
$L.Add('')
if ($act.Count -eq 0) {
    $L.Add('Nothing. This was worth knowing, not worth doing.')
} else {
    $L.Add('| Do | Venture | Effort |')
    $L.Add('|---|---|---|')
    foreach ($a in $act) { $L.Add("| $($a.what) | $($a.venture) | $($a.effort) |") }
}
$L.Add('')

$con = @(); if ($v.contradicts) { $con = @($v.contradicts | Where-Object { $_ }) }
if ($con.Count -gt 0) {
    $L.Add('## Contradicts something already believed')
    $L.Add('')
    $L.Add('The most valuable part of any source. Worth resolving rather than filing.')
    $L.Add('')
    foreach ($c in $con) { $L.Add("- $c") }
    $L.Add('')
}

$unv = @(); if ($v.unverified) { $unv = @($v.unverified | Where-Object { $_ }) }
if ($unv.Count -gt 0) {
    $L.Add('## Unverified')
    $L.Add('')
    foreach ($u in $unv) { $L.Add("- $u") }
    $L.Add('')
}

$L.Add('## Provenance')
$L.Add('')
$L.Add("Transcript obtained by $kindRaw. $words words across $mins minutes.")
$L.Add('The transcript is evidence of what the video says, not a source of truth about')
$L.Add("Sara's business. Claims above are the video's unless marked otherwise.")
if ($truncated) { $L.Add('') ; $L.Add("**Long transcript.** $words words. Detail may thin out later in the video.") }

if (-not $DryRun) {
    Set-Content -LiteralPath $noteF -Value $L -Encoding utf8
    $ledger[$key] = @{ date = $date; note = $noteF; title = $title }
    ($ledger | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ledgerF -Encoding utf8
    Add-Content -LiteralPath $ayaLog -Encoding utf8 `
        -Value ("$date | Aya | watched '$title' ($mins min, $($v.kind)). $($act.Count) actionable, $($con.Count) contradiction(s). | $noteF")
    Log "note written: $noteF"
} else {
    Log "DRYRUN, would write: $noteF"
    Write-Output ""
    Write-Output ($L -join "`n")
}

Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue

# ---------- tell Sara, written for the ear ----------
if (-not $Quiet -and -not $DryRun) {
    $say = "Watched $title. " + $v.one_liner_for_sara
    if ($act.Count -gt 0) { $say += " $($act.Count) thing" + $(if ($act.Count -gt 1) { "s" } else { "" }) + " you could act on." }
    else { $say += " Nothing to act on." }
    if ($con.Count -gt 0) { $say += " It contradicts something you already believe, worth a look." }
    if ($inj.Count -gt 0) { $say += " Heads up, that video contained text trying to instruct me. I ignored it and logged it." }
    if ($say.Length -gt 600) { $say = $say.Substring(0, 590) + " Notes are in the brain." }
    $r = Send-AyaText -Secrets $sec -Text $say
    Log "told Sara | $($r.detail)"
}

Log "FINISH ok | $($v.kind) | $($act.Count) actionable | $($con.Count) contradictions | $($inj.Count) injection attempts"
exit 0
