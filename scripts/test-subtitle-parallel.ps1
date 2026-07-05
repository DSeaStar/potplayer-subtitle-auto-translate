param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "..\watch-subtitle-translate.ps1")
)

$ErrorActionPreference = "Stop"

$source = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
$prefix = ($source -split '(?m)^\$config = Read-Config', 2)[0]
. ([scriptblock]::Create($prefix))

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("potplayer-subtitle-parallel-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

function Get-UserDataDir {
    return $tempDir
}

try {
    $configPath = Join-Path $tempDir "config.json"
    $configJson = @'
{
  "apiBaseUrl": "https://example.invalid/v1",
  "apiKey": "top-level-key",
  "model": "cache-model",
  "modelPool": [
    { "model": "fast-a" },
    { "apiBaseUrl": "https://other.invalid/v1", "apiKey": "provider-key", "model": "fast-b" }
  ]
}
'@
    Set-Content -LiteralPath $configPath -Value $configJson -Encoding ASCII
    $readConfig = Read-Config $configPath
    if (@($readConfig.ModelPool).Count -ne 2) {
        throw "Expected Read-Config to expose two modelPool entries."
    }
    if ($readConfig.ModelPool[0].ApiBaseUrl -ne "https://example.invalid/v1" -or $readConfig.ModelPool[0].ApiKey -ne "top-level-key") {
        throw "Expected provider entries to inherit the top-level base URL and API key."
    }
    if ($readConfig.ModelPool[1].ApiBaseUrl -ne "https://other.invalid/v1" -or $readConfig.ModelPool[1].ApiKey -ne "provider-key") {
        throw "Expected provider-specific base URL and API key to be preserved."
    }

    function Invoke-TranslationBatch {
        throw "Sequential translation path was used."
    }

    function Invoke-TranslationBatchesParallel {
        param($Config, [object[]]$Batches, [scriptblock]$OnBatchCompleted)
        if ($Batches.Count -ne 2) {
            throw "Expected two pending batches, got $($Batches.Count)."
        }
        if ($Batches[0].ProviderIndex -ne 0 -or $Batches[1].ProviderIndex -ne 1) {
            throw "Expected batches to be distributed across provider indexes."
        }

        $results = @{}
        foreach ($batch in $Batches) {
            $translated = @()
            foreach ($text in $batch.Texts) {
                $translated += "T:$text"
            }
            $results[[int]$batch.Index] = $translated
            if ($null -ne $OnBatchCompleted) {
                & $OnBatchCompleted $batch $translated
            }
        }
        return $results
    }

    $config = [pscustomobject]@{
        Model = "cache-model"
        ApiBaseUrl = "https://example.invalid/v1"
        ApiKey = "top-level-key"
        TargetLanguage = "Simplified Chinese"
        BatchSize = 2
        MaxParallelRequests = 3
        ModelPool = @(
            [pscustomobject]@{ ApiBaseUrl = "https://example.invalid/v1"; ApiKey = "top-level-key"; Model = "fast-a" },
            [pscustomobject]@{ ApiBaseUrl = "https://other.invalid/v1"; ApiKey = "provider-key"; Model = "fast-b" }
        )
    }

    $doc = [pscustomobject]@{
        Cues = @(
            [pscustomobject]@{ PlainText = "one"; Translation = $null },
            [pscustomobject]@{ PlainText = "two"; Translation = $null },
            [pscustomobject]@{ PlainText = "three"; Translation = $null }
        )
    }

    Add-Translations $doc $config

    $actual = @($doc.Cues | ForEach-Object { $_.Translation }) -join "|"
    if ($actual -ne "T:one|T:two|T:three") {
        throw "Unexpected cue translations: $actual"
    }

    $cachePath = Join-Path $tempDir "cache\translation-cache.json"
    $cache = Read-JsonMap $cachePath
    if ($cache.Count -ne 3) {
        throw "Expected three cached translations, got $($cache.Count)."
    }

    $script:seenModels = @()
    function Invoke-TranslationBatch {
        param($Config, [string[]]$Texts)
        $script:seenModels += $Config.Model
        if ($Config.Model -eq "bad-model") {
            throw "simulated provider failure"
        }
        return @($Texts | ForEach-Object { "OK:$_" })
    }

    $fallbackConfig = [pscustomobject]@{
        ApiBaseUrl = "https://example.invalid/v1"
        ApiKey = "top-level-key"
        Model = "cache-model"
        TargetLanguage = "Simplified Chinese"
        RetryCount = 0
        Temperature = 0.2
        MaxTokens = 2000
        ModelPool = @(
            [pscustomobject]@{ ApiBaseUrl = "https://example.invalid/v1"; ApiKey = "top-level-key"; Model = "bad-model" },
            [pscustomobject]@{ ApiBaseUrl = "https://example.invalid/v1"; ApiKey = "top-level-key"; Model = "good-model" }
        )
    }
    $fallback = Invoke-TranslationBatchWithProviderFallback $fallbackConfig 0 @("x", "y")
    if ((@($fallback) -join "|") -ne "OK:x|OK:y") {
        throw "Expected fallback provider translations."
    }
    if ((@($script:seenModels) -join "|") -ne "bad-model|good-model") {
        throw "Expected provider fallback sequence, saw: $(@($script:seenModels) -join '|')"
    }

    $limitedLog = Limit-LogText (("x" * 700)) 80
    if ($limitedLog.Length -gt 130 -or $limitedLog -notmatch "truncated") {
        throw "Expected long log messages to be truncated."
    }

    Remove-Item -LiteralPath (Join-Path $tempDir "cache") -Recurse -Force -ErrorAction SilentlyContinue
    function Invoke-TranslationBatchesParallel {
        param($Config, [object[]]$Batches, [scriptblock]$OnBatchCompleted)
        if ($null -eq $OnBatchCompleted) {
            throw "Expected Add-Translations to provide an incremental completion callback."
        }
        & $OnBatchCompleted $Batches[0] @("first", "second")
        throw "simulated interruption after first batch"
    }

    $interruptedDoc = [pscustomobject]@{
        Cues = @(
            [pscustomobject]@{ PlainText = "alpha"; Translation = $null },
            [pscustomobject]@{ PlainText = "beta"; Translation = $null },
            [pscustomobject]@{ PlainText = "gamma"; Translation = $null }
        )
    }

    $interrupted = $false
    try {
        Add-Translations $interruptedDoc $config
    }
    catch {
        if ($_.Exception.Message -notmatch "simulated interruption") {
            throw
        }
        $interrupted = $true
    }
    if (-not $interrupted) {
        throw "Expected simulated interruption to abort Add-Translations."
    }

    $interruptedCache = Read-JsonMap (Join-Path $tempDir "cache\translation-cache.json")
    if ($interruptedCache.Count -ne 2) {
        throw "Expected first completed batch to be cached before interruption, got $($interruptedCache.Count)."
    }
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "subtitle_parallel_test_ok"
