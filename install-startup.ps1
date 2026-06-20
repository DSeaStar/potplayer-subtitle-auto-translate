param(
    [string]$ConfigPath = (Join-Path $env:APPDATA "PotPlayerSubtitleAutoTranslate\config.json"),
    [string]$TaskName = "PotPlayer Subtitle Auto Translate"
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "watch-subtitle-translate.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Cannot find watcher script: $scriptPath"
}

$configDir = Split-Path -Parent $ConfigPath
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $example = Join-Path $PSScriptRoot "config.example.json"
    Copy-Item -LiteralPath $example -Destination $ConfigPath
    Write-Host "Created config template: $ConfigPath"
    Write-Host "Edit it before expecting translations to work."
}

$powershell = (Get-Command powershell.exe).Source
$args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$ConfigPath`""

$action = New-ScheduledTaskAction -Execute $powershell -Argument $args
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Watch PotPlayer-generated subtitles and translate them offline." -Force | Out-Null

Write-Host "Installed startup task: $TaskName"
Write-Host "Config path: $ConfigPath"
