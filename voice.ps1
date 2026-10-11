# AYA'S VOICE. One definition, used by speak.ps1 and tg.ps1.
#
# Sara picked Michelle 2026-08-09, asked for a little faster and more upbeat.
# Tune the three numbers below and everything that speaks changes at once.
#
# Two engines, deliberately:
#   edge-tts  Microsoft neural voices. Free, no API key, genuinely natural.
#             Needs network.
#   SAPI      Windows' 2013 voice. Robotic, and Sara said so. But it is
#             offline and cannot fail, so it is the fallback rather than the
#             default. A robotic warning beats silence.
#
#   . C:\Users\saraa\.aya\voice.ps1
#   $f = New-AyaSpeech -Text "..." -Path "out.mp3"    # returns @{ok; engine; path}
#   Invoke-AyaPlay -Path $f.path                       # play through speakers

# ---------------- the dial ----------------
$script:AYA_VOICE  = 'en-US-MichelleNeural'
$script:AYA_RATE   = '+12%'   # Sara: "a little faster". Default was -10%.
$script:AYA_PITCH  = '+8Hz'   # Sara: "upbeat". Pitch does more for this than rate.
$script:AYA_VOLUME = '+0%'

$script:AYA_PY = "C:\Users\saraa\AppData\Local\Programs\Python\Python313\python.exe"

function Get-AyaVoiceSettings {
    return [pscustomobject]@{
        Voice = $script:AYA_VOICE; Rate = $script:AYA_RATE
        Pitch = $script:AYA_PITCH; Volume = $script:AYA_VOLUME
    }
}

# Renders speech to a file. Returns the engine actually used, so callers can
# log which one spoke rather than assuming the good one did.
function New-AyaSpeech {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Path,
        [string]$Voice  = $script:AYA_VOICE,
        [string]$Rate   = $script:AYA_RATE,
        [string]$Pitch  = $script:AYA_PITCH,
        [switch]$ForceSapi
    )
    if (-not $Path) { $Path = Join-Path $env:TEMP ("aya-" + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + ".mp3") }

    if (-not $ForceSapi -and (Test-Path -LiteralPath $script:AYA_PY)) {
        try {
            # --text is passed as one argument. Long or quote-heavy text through
            # PowerShell to a native exe gets mangled, which is how a curl call
            # once turned into "could not resolve host", so anything awkward
            # goes via a temp file instead.
            $tf = Join-Path $env:TEMP ("aya-tts-in-" + [guid]::NewGuid().ToString('N') + ".txt")
            Set-Content -LiteralPath $tf -Value $Text -Encoding utf8 -NoNewline
            & $script:AYA_PY -m edge_tts --voice $Voice --rate=$Rate --pitch=$Pitch `
                --file $tf --write-media $Path 2>&1 | Out-Null
            Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
            if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 1KB) {
                return @{ ok = $true; engine = "edge-tts/$Voice"; path = $Path }
            }
        } catch { }
    }

    # Fallback. WAV, not MP3, because SAPI cannot write MP3.
    try {
        $wav = [System.IO.Path]::ChangeExtension($Path, '.wav')
        Add-Type -AssemblyName System.Speech
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $names = $s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }
        if ($names -contains 'Microsoft Zira Desktop') { $s.SelectVoice('Microsoft Zira Desktop') }
        $s.Rate = 2
        $s.SetOutputToWaveFile($wav)
        $s.Speak($Text)
        $s.Dispose()
        if (Test-Path -LiteralPath $wav) { return @{ ok = $true; engine = 'SAPI/Zira (fallback, network down)'; path = $wav } }
    } catch { }

    return @{ ok = $false; engine = 'none'; path = $null }
}

# Plays a file through the default audio device and BLOCKS until it finishes.
# Blocking matters: the caller needs to know it was heard, not queued, and two
# overlapping utterances are unintelligible.
function Invoke-AyaPlay {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        if ([System.IO.Path]::GetExtension($Path) -ieq '.wav') {
            $p = New-Object System.Media.SoundPlayer $Path
            $p.PlaySync()
            return $true
        }
        # MP3 needs MediaPlayer. It opens asynchronously, so wait for NaturalDuration
        # to populate before trusting it, then wait out the clip.
        Add-Type -AssemblyName PresentationCore
        $mp = New-Object System.Windows.Media.MediaPlayer
        $mp.Open([uri]$Path)
        $spin = 0
        while (-not $mp.NaturalDuration.HasTimeSpan -and $spin -lt 100) { Start-Sleep -Milliseconds 50; $spin++ }
        if (-not $mp.NaturalDuration.HasTimeSpan) { $mp.Close(); return $false }
        $ms = $mp.NaturalDuration.TimeSpan.TotalMilliseconds
        $mp.Play()
        Start-Sleep -Milliseconds ([int]$ms + 350)
        $mp.Stop(); $mp.Close()
        return $true
    } catch { return $false }
}
