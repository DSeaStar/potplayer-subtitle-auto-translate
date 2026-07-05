param(
    [string]$ConfigPath = (Join-Path $env:APPDATA "PotPlayerSubtitleAutoTranscribe\config.json"),
    [string]$Once = "",
    [switch]$Force,
    [switch]$NoWatch
)

$ErrorActionPreference = "Stop"

function Get-Prop {
    param($Object, [string]$Name, $Default)
    if ($null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Expand-PathValue {
    param([string]$Path)
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-UserDataDir {
    return (Join-Path $env:APPDATA "PotPlayerSubtitleAutoTranscribe")
}

function Write-Log {
    param([string]$Message)
    $dir = Join-Path (Get-UserDataDir) "logs"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath (Join-Path $dir "watcher.log") -Value $line -Encoding UTF8
    Write-Host $line
}

function Set-NativeUtf8Output {
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = $encoding
        $script:OutputEncoding = $encoding
    }
    catch {
        Write-Log ("Unable to switch native output decoding to UTF-8: {0}" -f $_.Exception.Message)
    }
}

function Repair-SubtitleEncoding {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return "missing"
    }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@(".srt", ".ass", ".ssa", ".vtt") -notcontains $ext) {
        return "skipped"
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return "unchanged"
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes)
    }
    catch {
        Write-Log "Leaving subtitle encoding unchanged because it is not valid UTF-8: $Path"
        return "unchanged"
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $text, $utf8Bom)
    Write-Log "Normalized subtitle encoding to UTF-8 BOM: $Path"
    return "normalized"
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $whisperExe = Expand-PathValue ([string](Get-Prop $cfg "whisperExe" ""))
    $model = Expand-PathValue ([string](Get-Prop $cfg "model" ""))
    if (-not (Test-Path -LiteralPath $whisperExe -PathType Leaf)) {
        throw "whisperExe not found: $whisperExe"
    }
    if ($model.Trim().Length -eq 0) {
        throw "config.model is required"
    }

    $watchDirs = @()
    foreach ($dir in @(Get-Prop $cfg "watchDirs" @())) {
        $expanded = Expand-PathValue ([string]$dir)
        if (Test-Path -LiteralPath $expanded -PathType Container) {
            $watchDirs += $expanded
        }
    }

    return [pscustomobject]@{
        WhisperExe = $whisperExe
        Model = $model
        ModelDir = Expand-PathValue ([string](Get-Prop $cfg "modelDir" ""))
        WatchDirs = $watchDirs
        Recursive = [bool](Get-Prop $cfg "recursive" $true)
        ScanIntervalSeconds = [int](Get-Prop $cfg "scanIntervalSeconds" 30)
        StableSeconds = [int](Get-Prop $cfg "stableSeconds" 60)
        TranscribeExistingOnStart = [bool](Get-Prop $cfg "transcribeExistingOnStart" $false)
        VideoExtensions = @((Get-Prop $cfg "videoExtensions" @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v", ".ts", ".m2ts")) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        SubtitleExtensions = @((Get-Prop $cfg "subtitleExtensions" @(".srt", ".ass", ".ssa", ".vtt")) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        OutputFormat = [string](Get-Prop $cfg "outputFormat" "srt")
        OutputDir = [string](Get-Prop $cfg "outputDir" "source")
        Language = [string](Get-Prop $cfg "language" "")
        Device = [string](Get-Prop $cfg "device" "")
        ComputeType = [string](Get-Prop $cfg "computeType" "auto")
        StandardAsia = [bool](Get-Prop $cfg "standardAsia" $true)
        BeepOff = [bool](Get-Prop $cfg "beepOff" $true)
        SkipExisting = [bool](Get-Prop $cfg "skipExisting" $true)
        ExtraArgs = @((Get-Prop $cfg "extraArgs" @()) | ForEach-Object { [string]$_ })
    }
}

function Read-JsonMap {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($raw.Trim().Length -eq 0) {
        return $map
    }
    $obj = $raw | ConvertFrom-Json
    foreach ($prop in $obj.PSObject.Properties) {
        $map[$prop.Name] = [string]$prop.Value
    }
    return $map
}

function Save-JsonMap {
    param([hashtable]$Map, [string]$Path)
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-TemporaryDownloadName {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    $tempSuffixes = @(".crdownload", ".part", ".tmp", ".!qB", ".aria2", ".download")
    foreach ($suffix in $tempSuffixes) {
        if ($name.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-MatchingSubtitleFiles {
    param([string]$VideoPath, $Config)
    $dir = Split-Path -Parent $VideoPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    $matches = @()
    foreach ($ext in $Config.SubtitleExtensions) {
        $matches += Get-ChildItem -LiteralPath $dir -File -Filter "$base*$ext" -ErrorAction SilentlyContinue
    }
    return @($matches | Sort-Object FullName -Unique)
}

function Test-SubtitleExists {
    param([string]$VideoPath, $Config)
    return ((Get-MatchingSubtitleFiles $VideoPath $Config).Count -gt 0)
}

function Test-FileStable {
    param([System.IO.FileInfo]$File, $Config)
    if ((Get-Date).ToUniversalTime().Subtract($File.LastWriteTimeUtc).TotalSeconds -lt $Config.StableSeconds) {
        return $false
    }

    $firstLength = $File.Length
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $File.FullName -PathType Leaf)) {
        return $false
    }
    $fresh = Get-Item -LiteralPath $File.FullName
    if ($fresh.Length -ne $firstLength) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-WhisperArgs {
    param([string]$VideoPath, $Config)
    $args = @(
        $VideoPath,
        "--model", $Config.Model,
        "--output_dir", $Config.OutputDir,
        "--output_format", $Config.OutputFormat,
        "--compute_type", $Config.ComputeType
    )

    if ($Config.ModelDir.Trim().Length -gt 0) {
        $args += @("--model_dir", $Config.ModelDir.Trim())
    }
    if ($Config.Language.Trim().Length -gt 0) {
        $args += @("--language", $Config.Language.Trim())
    }
    if ($Config.Device.Trim().Length -gt 0) {
        $args += @("--device", $Config.Device.Trim())
    }
    if ($Config.StandardAsia) {
        $args += "--standard_asia"
    }
    if ($Config.BeepOff) {
        $args += "--beep_off"
    }
    if ($Config.SkipExisting) {
        $args += "--skip"
    }
    foreach ($arg in $Config.ExtraArgs) {
        if ($arg.Trim().Length -gt 0) {
            $args += $arg
        }
    }
    return $args
}

function Invoke-VideoTranscription {
    param([string]$VideoPath, $Config, [switch]$Force)
    if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
        throw "Video not found: $VideoPath"
    }
    $file = Get-Item -LiteralPath $VideoPath
    if ($Config.VideoExtensions -notcontains $file.Extension.ToLowerInvariant()) {
        Write-Log "Skipping unsupported file: $VideoPath"
        return "skipped"
    }
    if (Test-TemporaryDownloadName $VideoPath) {
        Write-Log "Skipping temporary download file: $VideoPath"
        return "pending"
    }
    if (-not $Force -and (Test-SubtitleExists $VideoPath $Config)) {
        Write-Log "Skipping video with existing subtitle: $VideoPath"
        return "skipped"
    }
    if (-not (Test-FileStable $file $Config)) {
        Write-Log "Skipping unstable video file: $VideoPath"
        return "pending"
    }

    $before = @(Get-MatchingSubtitleFiles $VideoPath $Config | ForEach-Object { $_.FullName })
    $args = Get-WhisperArgs $VideoPath $Config
    Write-Log "Starting transcription: $VideoPath"
    Write-Log ("Whisper args: " + ($args -join " "))

    Set-NativeUtf8Output
    $output = & $Config.WhisperExe @args 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        if ([string]$line -ne "") {
            Write-Log "whisper: $line"
        }
    }
    $joinedOutput = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $reportedError = ($joinedOutput -match "Unknown model|Traceback|error:|Exception")

    $after = @(Get-MatchingSubtitleFiles $VideoPath $Config | ForEach-Object { $_.FullName })
    $created = @($after | Where-Object { $before -notcontains $_ })
    if ($created.Count -gt 0) {
        foreach ($subtitle in $created) {
            Repair-SubtitleEncoding $subtitle | Out-Null
            Write-Log "Created subtitle: $subtitle"
        }
    }

    if ($reportedError) {
        throw "Whisper reported an error. Check watcher.log for details."
    }
    if ($exitCode -ne 0) {
        if ($created.Count -gt 0) {
            Write-Log "Whisper exited with code $exitCode after creating subtitle; keeping created output."
            return "done"
        }
        throw "Whisper exited with code $exitCode"
    }
    if ($created.Count -eq 0) {
        Write-Log "Transcription finished; no subtitle was created for: $VideoPath"
        return "skipped"
    }
    return "done"
}

function Get-CandidateVideoFiles {
    param($Config)
    $all = @()
    foreach ($dir in $Config.WatchDirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $items = Get-ChildItem -LiteralPath $dir -File -Recurse:$Config.Recursive -ErrorAction SilentlyContinue |
            Where-Object { $Config.VideoExtensions -contains $_.Extension.ToLowerInvariant() -and -not (Test-TemporaryDownloadName $_.FullName) }
        $all += $items
    }
    return @($all | Sort-Object FullName -Unique)
}

function Watch-Videos {
    param($Config)
    if ($Config.WatchDirs.Count -eq 0) {
        throw "No existing watch directories. Edit config.watchDirs."
    }

    $statePath = Join-Path (Get-UserDataDir) "watch-state.json"
    $state = Read-JsonMap $statePath
    $firstRun = ($state.Count -eq 0)

    Write-Log "Video transcription watcher started"
    foreach ($dir in $Config.WatchDirs) {
        Write-Log "Watching: $dir"
    }

    while ($true) {
        try {
            $files = Get-CandidateVideoFiles $Config
            foreach ($file in $files) {
                $path = $file.FullName
                $stamp = "{0}:{1}" -f $file.LastWriteTimeUtc.Ticks, $file.Length

                if ($firstRun -and -not $Config.TranscribeExistingOnStart) {
                    $state[$path] = $stamp
                    continue
                }

                if (-not $state.ContainsKey($path) -or $state[$path] -ne $stamp) {
                    $status = "failed"
                    try {
                        $status = Invoke-VideoTranscription $path $Config
                    }
                    catch {
                        Write-Log ("Error transcribing {0}: {1}" -f $path, $_.Exception.Message)
                        if ($_.Exception.Message -match "Unknown cover type") {
                            $status = "skipped"
                        }
                    }
                    if ($status -eq "done" -or $status -eq "skipped") {
                        $state[$path] = $stamp
                        Save-JsonMap $state $statePath
                    }
                }
            }

            if ($firstRun) {
                Save-JsonMap $state $statePath
                $firstRun = $false
            }
        }
        catch {
            Write-Log ("Watcher loop error: {0}" -f $_.Exception.Message)
        }
        Start-Sleep -Seconds $Config.ScanIntervalSeconds
    }
}

$config = Read-Config $ConfigPath

if ($Once.Trim().Length -gt 0) {
    Invoke-VideoTranscription (Expand-PathValue $Once) $config -Force:$Force
    exit 0
}

if ($NoWatch) {
    exit 0
}

Watch-Videos $config
