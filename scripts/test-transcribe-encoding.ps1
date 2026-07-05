param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "..\watch-video-transcribe.ps1")
)

$ErrorActionPreference = "Stop"

$source = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
$prefix = ($source -split '(?m)^\$config = Read-Config', 2)[0]
. ([scriptblock]::Create($prefix))

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("potplayer-transcribe-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
try {
    $path = Join-Path $tempDir "sample.srt"
    $sample = [string]([char]0x3054) + [string]([char]0x8996) + [string]([char]0x8074)
    $text = "1`r`n00:00:01,000 --> 00:00:02,000`r`n$sample`r`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)

    Repair-SubtitleEncoding $path | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "Expected generated subtitles to be rewritten with a UTF-8 BOM."
    }

    $utf8BomStrict = New-Object System.Text.UTF8Encoding($true, $true)
    $roundTrip = $utf8BomStrict.GetString($bytes)
    if (-not $roundTrip.Contains($sample)) {
        throw "Expected Japanese text to round-trip after encoding repair."
    }

    $videoPath = Join-Path $tempDir "video.mp4"
    [System.IO.File]::WriteAllBytes($videoPath, [byte[]](1, 2, 3, 4))
    $mockWhisper = Join-Path $tempDir "mock-whisper.ps1"
    $mockSource = @'
param([string]$VideoPath)
$sample = [string]([char]0x3054) + [string]([char]0x8996) + [string]([char]0x8074)
$outPath = Join-Path (Split-Path -Parent $VideoPath) (([System.IO.Path]::GetFileNameWithoutExtension($VideoPath)) + ".srt")
$text = "1`r`n00:00:01,000 --> 00:00:02,000`r`n$sample`r`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outPath, $text, $utf8NoBom)
Write-Output "Operation finished in: 0:00:01"
exit 1
'@
    Set-Content -LiteralPath $mockWhisper -Value $mockSource -Encoding ASCII

    $config = [pscustomobject]@{
        WhisperExe = $mockWhisper
        Model = "mock"
        ModelDir = ""
        VideoExtensions = @(".mp4")
        SubtitleExtensions = @(".srt")
        OutputFormat = "srt"
        OutputDir = "source"
        Language = ""
        Device = ""
        ComputeType = "auto"
        StandardAsia = $false
        BeepOff = $false
        SkipExisting = $false
        ExtraArgs = @()
        StableSeconds = 0
    }

    $status = Invoke-VideoTranscription $videoPath $config
    if ($status -ne "done") {
        throw "Expected transcription to succeed when a subtitle is created despite a non-zero whisper exit."
    }

    $createdPath = Join-Path $tempDir "video.srt"
    $createdBytes = [System.IO.File]::ReadAllBytes($createdPath)
    if ($createdBytes.Length -lt 3 -or $createdBytes[0] -ne 0xEF -or $createdBytes[1] -ne 0xBB -or $createdBytes[2] -ne 0xBF) {
        throw "Expected subtitles from non-zero whisper exits to be repaired before returning."
    }
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "transcribe_encoding_test_ok"
