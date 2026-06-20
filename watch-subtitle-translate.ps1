param(
    [string]$ConfigPath = (Join-Path $env:APPDATA "PotPlayerSubtitleAutoTranslate\config.json"),
    [string]$Once = "",
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
    return (Join-Path $env:APPDATA "PotPlayerSubtitleAutoTranslate")
}

function Write-Log {
    param([string]$Message)
    $dir = Join-Path (Get-UserDataDir) "logs"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath (Join-Path $dir "watcher.log") -Value $line -Encoding UTF8
    Write-Host $line
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json

    $apiBaseUrl = [string](Get-Prop $cfg "apiBaseUrl" "")
    $apiKey = [string](Get-Prop $cfg "apiKey" "")
    $model = [string](Get-Prop $cfg "model" "")
    if ($apiBaseUrl.Trim().Length -eq 0) { throw "config.apiBaseUrl is required" }
    if ($apiKey.Trim().Length -eq 0) { throw "config.apiKey is required" }
    if ($model.Trim().Length -eq 0) { throw "config.model is required" }

    $apiBaseUrl = $apiBaseUrl.TrimEnd("/")
    $watchDirs = @()
    foreach ($dir in @(Get-Prop $cfg "watchDirs" @())) {
        $expanded = Expand-PathValue ([string]$dir)
        if (Test-Path -LiteralPath $expanded -PathType Container) {
            $watchDirs += $expanded
        }
    }

    return [pscustomobject]@{
        ApiBaseUrl = $apiBaseUrl
        ApiKey = $apiKey
        Model = $model
        TargetLanguage = [string](Get-Prop $cfg "targetLanguage" "Simplified Chinese")
        WatchDirs = $watchDirs
        Recursive = [bool](Get-Prop $cfg "recursive" $true)
        ScanIntervalSeconds = [int](Get-Prop $cfg "scanIntervalSeconds" 20)
        BatchSize = [int](Get-Prop $cfg "batchSize" 20)
        Temperature = [double](Get-Prop $cfg "temperature" 0.2)
        MaxTokens = [int](Get-Prop $cfg "maxTokens" 2000)
        RequestTimeoutSeconds = [int](Get-Prop $cfg "requestTimeoutSeconds" 120)
        RetryCount = [int](Get-Prop $cfg "retryCount" 2)
        TranslateExistingOnStart = [bool](Get-Prop $cfg "translateExistingOnStart" $false)
        WriteTranslated = [bool](Get-Prop $cfg "writeTranslated" $true)
        WriteBilingual = [bool](Get-Prop $cfg "writeBilingual" $true)
        TranslatedSuffix = [string](Get-Prop $cfg "translatedSuffix" "zh-CN")
        BilingualSuffix = [string](Get-Prop $cfg "bilingualSuffix" "bilingual")
    }
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
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

function Get-CacheKey {
    param($Config, [string]$Text)
    return Get-Sha256Text ("v1|{0}|{1}|{2}" -f $Config.Model, $Config.TargetLanguage, $Text)
}

function Normalize-SubtitleText {
    param([string]$Text, [string]$Format)
    $clean = $Text
    if ($Format -eq "ass") {
        $clean = $clean -replace "\{[^}]*\}", ""
        $clean = $clean -replace "\\[Nn]", " "
        $clean = $clean -replace "\\h", " "
    }
    else {
        $clean = $clean -replace "<[^>]+>", ""
    }
    $clean = $clean -replace "\s+", " "
    return $clean.Trim()
}

function Split-SubtitleLines {
    param([string]$Text)
    $trimmed = $Text.Trim()
    if ($trimmed.Length -eq 0) {
        return @("")
    }
    return @($trimmed -replace "`r`n", "`n" -replace "`r", "`n" -split "`n")
}

function ConvertTo-AssText {
    param([string]$Text)
    return (($Text.Trim() -replace "`r`n", "\N") -replace "`n", "\N" -replace "`r", "\N")
}

function Split-TextBlocks {
    param([string]$Content)
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    return @($normalized -split "\n[ \t]*\n")
}

function Read-TextFileSmart {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $strictUtf8.GetString($bytes)
    }
    catch {
        # Common subtitle encodings on Windows: Japanese, Simplified Chinese,
        # Korean, Traditional Chinese, and the current ANSI code page.
        $codePages = @(932, 936, 949, 950, [System.Text.Encoding]::Default.CodePage) | Select-Object -Unique
        foreach ($cp in $codePages) {
            try {
                return [System.Text.Encoding]::GetEncoding($cp).GetString($bytes)
            }
            catch {
            }
        }
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Write-Utf8BomText {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Parse-Srt {
    param([string]$Path)
    $content = Read-TextFileSmart $Path
    $blocks = Split-TextBlocks $content
    $cues = @()
    foreach ($block in $blocks) {
        $lines = @($block -split "`n")
        if ($lines.Count -eq 0) { continue }
        $timingIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "-->") {
                $timingIndex = $i
                break
            }
        }
        if ($timingIndex -lt 0 -or $timingIndex -ge ($lines.Count - 1)) {
            continue
        }
        $prefix = @($lines[0..$timingIndex])
        $textLines = @($lines[($timingIndex + 1)..($lines.Count - 1)])
        $text = ($textLines -join "`n").Trim()
        $cues += [pscustomobject]@{
            PrefixLines = $prefix
            TextLines = $textLines
            Text = $text
            PlainText = Normalize-SubtitleText $text "srt"
            Translation = ""
        }
    }
    return [pscustomobject]@{ Format = "srt"; Cues = $cues }
}

function Render-Srt {
    param($Doc, [string]$Mode)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($cue in $Doc.Cues) {
        foreach ($line in $cue.PrefixLines) { $out.Add($line) }
        if ($Mode -eq "translated") {
            foreach ($line in (Split-SubtitleLines $cue.Translation)) { $out.Add($line) }
        }
        else {
            foreach ($line in $cue.TextLines) { $out.Add($line) }
            if ($cue.Translation.Trim().Length -gt 0) {
                foreach ($line in (Split-SubtitleLines $cue.Translation)) { $out.Add($line) }
            }
        }
        $out.Add("")
    }
    return ($out -join "`r`n")
}

function Parse-Vtt {
    param([string]$Path)
    $content = Read-TextFileSmart $Path
    $blocks = Split-TextBlocks $content
    $header = @()
    $cues = @()
    foreach ($block in $blocks) {
        if ($block.Trim().Length -eq 0) { continue }
        $lines = @($block -split "`n")
        $timingIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "-->") {
                $timingIndex = $i
                break
            }
        }
        if ($timingIndex -lt 0) {
            $header += $lines
            continue
        }
        if ($timingIndex -ge ($lines.Count - 1)) {
            continue
        }
        $prefix = @($lines[0..$timingIndex])
        $textLines = @($lines[($timingIndex + 1)..($lines.Count - 1)])
        $text = ($textLines -join "`n").Trim()
        $cues += [pscustomobject]@{
            PrefixLines = $prefix
            TextLines = $textLines
            Text = $text
            PlainText = Normalize-SubtitleText $text "vtt"
            Translation = ""
        }
    }
    if ($header.Count -eq 0) {
        $header = @("WEBVTT")
    }
    return [pscustomobject]@{ Format = "vtt"; Header = $header; Cues = $cues }
}

function Render-Vtt {
    param($Doc, [string]$Mode)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Doc.Header) { $out.Add($line) }
    $out.Add("")
    foreach ($cue in $Doc.Cues) {
        foreach ($line in $cue.PrefixLines) { $out.Add($line) }
        if ($Mode -eq "translated") {
            foreach ($line in (Split-SubtitleLines $cue.Translation)) { $out.Add($line) }
        }
        else {
            foreach ($line in $cue.TextLines) { $out.Add($line) }
            if ($cue.Translation.Trim().Length -gt 0) {
                foreach ($line in (Split-SubtitleLines $cue.Translation)) { $out.Add($line) }
            }
        }
        $out.Add("")
    }
    return ($out -join "`r`n")
}

function Parse-Ass {
    param([string]$Path)
    $content = Read-TextFileSmart $Path
    $lines = @($content -replace "`r`n", "`n" -replace "`r", "`n" -split "`n")
    $inEvents = $false
    $fields = @()
    $textIndex = -1
    $cues = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match "^\s*\[Events\]\s*$") {
            $inEvents = $true
            continue
        }
        if ($line -match "^\s*\[.+\]\s*$" -and $line -notmatch "^\s*\[Events\]\s*$") {
            $inEvents = $false
            continue
        }
        if (-not $inEvents) { continue }

        if ($line -match "^\s*Format\s*:\s*(.+)$") {
            $fields = @($Matches[1].Split(",") | ForEach-Object { $_.Trim() })
            for ($f = 0; $f -lt $fields.Count; $f++) {
                if ($fields[$f].Equals("Text", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $textIndex = $f
                    break
                }
            }
            continue
        }

        if ($line -match "^\s*Dialogue\s*:\s*(.*)$" -and $textIndex -ge 0 -and $fields.Count -gt $textIndex) {
            $payload = $Matches[1]
            $parts = @($payload -split ",", $fields.Count)
            if ($parts.Count -le $textIndex) { continue }
            $text = [string]$parts[$textIndex]
            $cues += [pscustomobject]@{
                LineIndex = $i
                Parts = $parts
                Text = $text
                PlainText = Normalize-SubtitleText $text "ass"
                Translation = ""
            }
        }
    }

    return [pscustomobject]@{ Format = "ass"; Lines = $lines; Fields = $fields; TextIndex = $textIndex; Cues = $cues }
}

function Render-Ass {
    param($Doc, [string]$Mode)
    $lines = @($Doc.Lines)
    foreach ($cue in $Doc.Cues) {
        $parts = @($cue.Parts)
        if ($Mode -eq "translated") {
            $parts[$Doc.TextIndex] = ConvertTo-AssText $cue.Translation
        }
        else {
            $translated = ConvertTo-AssText $cue.Translation
            if ($translated.Length -gt 0) {
                $parts[$Doc.TextIndex] = ([string]$cue.Text) + "\N" + $translated
            }
        }
        $lines[$cue.LineIndex] = "Dialogue: " + ($parts -join ",")
    }
    return ($lines -join "`r`n")
}

function Read-SubtitleDocument {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".srt" { return Parse-Srt $Path }
        ".vtt" { return Parse-Vtt $Path }
        ".ass" { return Parse-Ass $Path }
        default { throw "Unsupported subtitle format: $ext" }
    }
}

function Render-SubtitleDocument {
    param($Doc, [string]$Mode)
    switch ($Doc.Format) {
        "srt" { return Render-Srt $Doc $Mode }
        "vtt" { return Render-Vtt $Doc $Mode }
        "ass" { return Render-Ass $Doc $Mode }
        default { throw "Unsupported parsed subtitle format: $($Doc.Format)" }
    }
}

function ConvertFrom-ModelJsonArray {
    param([string]$Content)
    $text = $Content.Trim()
    if ($text -match '^```') {
        $text = $text -replace '^```[a-zA-Z0-9_-]*\s*', ''
        $text = $text -replace '\s*```$', ''
    }

    try {
        $parsed = $text | ConvertFrom-Json
        if ($parsed -is [System.Array]) {
            return $parsed
        }
        return @($parsed)
    }
    catch {
        $match = [regex]::Match($text, "\[[\s\S]*\]")
        if ($match.Success) {
            $parsed = $match.Value | ConvertFrom-Json
            if ($parsed -is [System.Array]) {
                return $parsed
            }
            return @($parsed)
        }
        throw
    }
}

function Read-WebResponseUtf8 {
    param($Response)
    $stream = $Response.GetResponseStream()
    $memory = New-Object System.IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
        }
        return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $memory.Dispose()
    }
}

function Invoke-ChatCompletionUtf8 {
    param($Config, [string]$Body)
    $uri = "$($Config.ApiBaseUrl)/chat/completions"
    $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($uri)
    $request.Method = "POST"
    $request.Accept = "application/json"
    $request.ContentType = "application/json; charset=utf-8"
    $request.UserAgent = "PotPlayerSubtitleAutoTranslate/1.0"
    $request.Timeout = $Config.RequestTimeoutSeconds * 1000
    $request.ReadWriteTimeout = $Config.RequestTimeoutSeconds * 1000
    $request.Headers["Authorization"] = "Bearer $($Config.ApiKey)"

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $request.ContentLength = $bodyBytes.Length
    $requestStream = $request.GetRequestStream()
    try {
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    finally {
        $requestStream.Dispose()
    }

    $response = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $text = Read-WebResponseUtf8 $response
        $status = [int]$response.StatusCode
        if ($status -lt 200 -or $status -ge 300) {
            throw "HTTP ${status}: $text"
        }
        return $text | ConvertFrom-Json
    }
    catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $errorText = Read-WebResponseUtf8 $_.Exception.Response
            throw "HTTP error: $errorText"
        }
        throw
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Invoke-TranslationBatch {
    param($Config, [string[]]$Texts)
    if ($Texts.Count -eq 0) { return @() }

    $systemPrompt = @"
You are a subtitle translation engine.
Translate each input subtitle cue into $($Config.TargetLanguage).
Return only a valid JSON array of strings.
The output array must have exactly the same length and order as the input array.
Keep translations concise and natural for on-screen subtitles.
Preserve names, numbers, punctuation intent, and terminology.
Do not add explanations, indexes, markdown, or extra fields.
"@

    $messages = @(
        @{ role = "system"; content = $systemPrompt },
        @{ role = "user"; content = ($Texts | ConvertTo-Json -Depth 5 -Compress) }
    )

    $body = @{
        model = $Config.Model
        messages = $messages
        temperature = $Config.Temperature
        max_tokens = $Config.MaxTokens
        stream = $false
    } | ConvertTo-Json -Depth 10 -Compress

    $lastError = $null
    for ($attempt = 0; $attempt -le $Config.RetryCount; $attempt++) {
        try {
            $response = Invoke-ChatCompletionUtf8 $Config $body
            $content = [string]$response.choices[0].message.content
            $items = @(ConvertFrom-ModelJsonArray $content)
            if ($items.Count -ne $Texts.Count) {
                throw "Translation count mismatch. Expected $($Texts.Count), got $($items.Count)."
            }
            return @($items | ForEach-Object { [string]$_ })
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Config.RetryCount) {
                Start-Sleep -Seconds ([Math]::Min(10, 2 + $attempt * 2))
            }
        }
    }
    throw $lastError
}

function Add-Translations {
    param($Doc, $Config)
    $cacheDir = Join-Path (Get-UserDataDir) "cache"
    $cachePath = Join-Path $cacheDir "translation-cache.json"
    $cache = Read-JsonMap $cachePath
    $pending = [ordered]@{}

    foreach ($cue in $Doc.Cues) {
        if ($cue.PlainText.Trim().Length -eq 0) {
            $cue.Translation = ""
            continue
        }
        $key = Get-CacheKey $Config $cue.PlainText
        if ($cache.ContainsKey($key)) {
            $cue.Translation = $cache[$key]
        }
        elseif (-not $pending.Contains($key)) {
            $pending[$key] = $cue.PlainText
        }
    }

    $keys = @($pending.Keys)
    for ($offset = 0; $offset -lt $keys.Count; $offset += $Config.BatchSize) {
        $take = [Math]::Min($Config.BatchSize, $keys.Count - $offset)
        $batchKeys = @($keys[$offset..($offset + $take - 1)])
        $texts = @($batchKeys | ForEach-Object { [string]$pending[$_] })
        Write-Log ("Translating batch {0}-{1} of {2}" -f ($offset + 1), ($offset + $take), $keys.Count)
        $translated = Invoke-TranslationBatch $Config $texts
        for ($i = 0; $i -lt $batchKeys.Count; $i++) {
            $cache[$batchKeys[$i]] = [string]$translated[$i]
        }
        Save-JsonMap $cache $cachePath
    }

    foreach ($cue in $Doc.Cues) {
        if ($cue.PlainText.Trim().Length -eq 0) { continue }
        $key = Get-CacheKey $Config $cue.PlainText
        $cue.Translation = $cache[$key]
    }
}

function Get-OutputPath {
    param([string]$Path, [string]$Suffix)
    $dir = Split-Path -Parent $Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    return (Join-Path $dir "$base.$Suffix$ext")
}

function Test-GeneratedOutputName {
    param([string]$Path, $Config)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $suffixes = @($Config.TranslatedSuffix, $Config.BilingualSuffix, "zh", "zh-CN", "bilingual", "translated")
    foreach ($suffix in $suffixes) {
        if ($base.EndsWith(".$suffix", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Wait-FileStable {
    param([string]$Path)
    $lastLength = -1
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $false
        }
        $item = Get-Item -LiteralPath $Path
        $length = $item.Length
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $stream.Close()
        }
        catch {
            Start-Sleep -Seconds 1
            continue
        }
        if ($length -eq $lastLength) {
            return $true
        }
        $lastLength = $length
        Start-Sleep -Seconds 1
    }
    return $false
}

function Convert-SubtitleFile {
    param([string]$Path, $Config, [switch]$Force)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@(".srt", ".vtt", ".ass") -notcontains $ext) { return }
    if (Test-GeneratedOutputName $Path $Config) { return }

    $translatedPath = Get-OutputPath $Path $Config.TranslatedSuffix
    $bilingualPath = Get-OutputPath $Path $Config.BilingualSuffix
    if (-not $Force -and (Test-Path -LiteralPath $translatedPath) -and (Test-Path -LiteralPath $bilingualPath)) {
        Write-Log "Skipping already translated file: $Path"
        return
    }

    if (-not (Wait-FileStable $Path)) {
        Write-Log "Skipping unstable file: $Path"
        return
    }

    Write-Log "Reading subtitle: $Path"
    $doc = Read-SubtitleDocument $Path
    if ($doc.Cues.Count -eq 0) {
        Write-Log "No subtitle cues found: $Path"
        return
    }

    Add-Translations $doc $Config

    if ($Config.WriteTranslated) {
        Write-Utf8BomText $translatedPath (Render-SubtitleDocument $doc "translated")
        Write-Log "Wrote translated subtitle: $translatedPath"
    }
    if ($Config.WriteBilingual) {
        Write-Utf8BomText $bilingualPath (Render-SubtitleDocument $doc "bilingual")
        Write-Log "Wrote bilingual subtitle: $bilingualPath"
    }
}

function Get-CandidateSubtitleFiles {
    param($Config)
    $all = @()
    foreach ($dir in $Config.WatchDirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $items = Get-ChildItem -LiteralPath $dir -File -Recurse:$Config.Recursive -ErrorAction SilentlyContinue |
            Where-Object { @(".srt", ".vtt", ".ass") -contains $_.Extension.ToLowerInvariant() }
        $all += $items
    }
    return @($all | Sort-Object FullName -Unique)
}

function Watch-Subtitles {
    param($Config)
    if ($Config.WatchDirs.Count -eq 0) {
        throw "No existing watch directories. Edit config.watchDirs."
    }

    $statePath = Join-Path (Get-UserDataDir) "watch-state.json"
    $state = Read-JsonMap $statePath
    $firstRun = ($state.Count -eq 0)

    Write-Log "Watcher started"
    foreach ($dir in $Config.WatchDirs) {
        Write-Log "Watching: $dir"
    }

    while ($true) {
        try {
            $files = Get-CandidateSubtitleFiles $Config
            foreach ($file in $files) {
                if (Test-GeneratedOutputName $file.FullName $Config) { continue }
                $path = $file.FullName
                $ticks = [string]$file.LastWriteTimeUtc.Ticks

                if ($firstRun -and -not $Config.TranslateExistingOnStart) {
                    $state[$path] = $ticks
                    continue
                }

                if (-not $state.ContainsKey($path) -or $state[$path] -ne $ticks) {
                    try {
                        Convert-SubtitleFile $path $Config
                    }
                    catch {
                        Write-Log ("Error translating {0}: {1}" -f $path, $_.Exception.Message)
                    }
                    $state[$path] = $ticks
                    Save-JsonMap $state $statePath
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
    Convert-SubtitleFile (Expand-PathValue $Once) $config -Force
    exit 0
}

if ($NoWatch) {
    exit 0
}

Watch-Subtitles $config
