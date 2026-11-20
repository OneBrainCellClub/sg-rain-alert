<#
  Rain alert for Singapore -> Telegram
  Uses NEA open data (data.gov.sg):
    - 2-hour weather forecast per area (early warning)
    - real-time rainfall from rain gauge stations, 5-minute totals (raining now)
  Also answers the Telegram command /update with the current weather around home.

  Settings come from (later wins):
    config.example.json  ->  config.json (local, not in git)  ->  secrets.dat (local, encrypted)
    ->  environment variables (GitHub Actions secrets):
        TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, HOME_AREA, HOME_LAT, HOME_LON

  Usage:
    .\rain-alert.ps1                 # normal check: answer /update, send alerts if needed
    .\rain-alert.ps1 -ListAreas      # show the NEA area names
    .\rain-alert.ps1 -FindChatId     # after messaging your bot, prints your Telegram chat id
    .\rain-alert.ps1 -Test           # sends a test message and prints the current status
    .\rain-alert.ps1 -DryRun         # prints what would be sent, sends nothing
    .\rain-alert.ps1 -SetCommands    # adds /update to the bot's command menu in Telegram
#>
param(
    [switch]$ListAreas,
    [switch]$FindChatId,
    [switch]$Test,
    [switch]$DryRun,
    [switch]$SetCommands
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$statePath = Join-Path $here 'state.json'
$logPath   = Join-Path $here 'rain-alert.log'

$ForecastUrl = 'https://api-open.data.gov.sg/v2/real-time/api/two-hr-forecast'
$RainfallUrl = 'https://api-open.data.gov.sg/v2/real-time/api/rainfall'
$RainWords   = '(?i)rain|shower|drizzle|thunder'
$UpdateCmd   = '^/(update|weather|rain)(@\w+)?(\s|$)'

function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    if ($env:GITHUB_ACTIONS) { return }
    try {
        Add-Content -Path $logPath -Value $line -Encoding UTF8
        $lines = Get-Content $logPath
        if ($lines.Count -gt 2000) { $lines | Select-Object -Last 1000 | Set-Content $logPath -Encoding UTF8 }
    } catch {}
}

function Get-DistanceKm($lat1, $lon1, $lat2, $lon2) {
    $dLat = ($lat2 - $lat1) * [Math]::PI / 180
    $dLon = ($lon2 - $lon1) * [Math]::PI / 180
    $a = [Math]::Sin($dLat/2) * [Math]::Sin($dLat/2) +
         [Math]::Cos($lat1 * [Math]::PI / 180) * [Math]::Cos($lat2 * [Math]::PI / 180) *
         [Math]::Sin($dLon/2) * [Math]::Sin($dLon/2)
    return 6371.0 * 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))
}

function Get-NeaData($url) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            $res = Invoke-RestMethod -Uri $url -TimeoutSec 30
            if ($res.code -eq 0) { return $res.data }
            throw "NEA returned code $($res.code)"
        } catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Invoke-Telegram($method, $body) {
    $uri  = "https://api.telegram.org/bot$($cfg.telegramBotToken)/$method"
    $json = $body | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30
}

function Send-Telegram($text) {
    Invoke-Telegram 'sendMessage' @{ chat_id = "$($cfg.telegramChatId)"; text = $text; disable_web_page_preview = $true } | Out-Null
}

# ---------- -ListAreas (needs no settings) ----------
if ($ListAreas) {
    (Get-NeaData $ForecastUrl).area_metadata | ForEach-Object { $_.name }
    return
}

# ---------- load settings ----------
$cfg = [pscustomobject]@{}
foreach ($f in 'config.example.json', 'config.json') {
    $p = Join-Path $here $f
    if (Test-Path $p) {
        $c = Get-Content $p -Raw | ConvertFrom-Json
        foreach ($prop in $c.PSObject.Properties) {
            if ($null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                $cfg | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            }
        }
    }
}

# Local secrets, encrypted with Windows DPAPI (only your Windows account on this PC can read them)
$secretsPath = Join-Path $here 'secrets.dat'
if ((Test-Path $secretsPath) -and -not $env:GITHUB_ACTIONS) {
    $raw = Get-Content $secretsPath -Raw | ConvertFrom-Json
    foreach ($n in 'telegramBotToken', 'telegramChatId') {
        if ($raw.$n) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $raw.$n))
            try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
            $cfg | Add-Member -NotePropertyName $n -NotePropertyValue $plain -Force
        }
    }
}

# Environment variables (GitHub Actions secrets) win
$envMap = @{ telegramBotToken = 'TELEGRAM_BOT_TOKEN'; telegramChatId = 'TELEGRAM_CHAT_ID'; homeArea = 'HOME_AREA'; latitude = 'HOME_LAT'; longitude = 'HOME_LON' }
foreach ($k in $envMap.Keys) {
    $v = [Environment]::GetEnvironmentVariable($envMap[$k])
    if ($v) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $v.Trim() -Force }
}

function Test-Missing($v) { -not $v -or "$v" -match 'PASTE|secret|stored encrypted' }
if (Test-Missing $cfg.telegramBotToken) { throw "Telegram bot token is not set (config.json, secrets.dat or TELEGRAM_BOT_TOKEN)." }

# ---------- -FindChatId ----------
if ($FindChatId) {
    $upd = Invoke-RestMethod "https://api.telegram.org/bot$($cfg.telegramBotToken)/getUpdates"
    $chats = $upd.result | ForEach-Object { $_.message.chat } | Where-Object { $_ } | Sort-Object id -Unique
    if (-not $chats) { Write-Host "No messages found. Send any message to your bot in Telegram, then run this again." }
    $chats | ForEach-Object { Write-Host ("chat id: {0}   ({1} {2}{3})" -f $_.id, $_.first_name, $_.last_name, $_.title) }
    return
}

# ---------- -SetCommands ----------
if ($SetCommands) {
    Invoke-Telegram 'setMyCommands' @{ commands = @(@{ command = 'update'; description = 'Current weather and rain around home' }) } | Out-Null
    Write-Host "Added /update to the bot's command menu."
    return
}

if (Test-Missing $cfg.telegramChatId) { throw "Telegram chat id is not set (config.json, secrets.dat or TELEGRAM_CHAT_ID)." }
if (Test-Missing $cfg.homeArea)       { throw "Home area is not set (config.json or HOME_AREA)." }

$homeArea     = "$($cfg.homeArea)"
$nearbyKm     = if ($cfg.nearbyAreaRadiusKm)  { [double]$cfg.nearbyAreaRadiusKm }  else { 6 }
$stationKm    = if ($cfg.rainStationRadiusKm) { [double]$cfg.rainStationRadiusKm } else { 3 }
$minRainMm    = if ($cfg.minRainMm)           { [double]$cfg.minRainMm }           else { 0.2 }
$sendAllClear = if ($null -ne $cfg.sendAllClear) { [bool]$cfg.sendAllClear } else { $true }

# ---------- fetch forecast ----------
$fc = Get-NeaData $ForecastUrl
$homeMeta = $fc.area_metadata | Where-Object { $_.name -eq $homeArea }
if (-not $homeMeta) { throw "Home area '$homeArea' is not an NEA area name. Run .\rain-alert.ps1 -ListAreas." }

$lat = if (-not (Test-Missing $cfg.latitude))  { [double]$cfg.latitude }  else { [double]$homeMeta.label_location.latitude }
$lon = if (-not (Test-Missing $cfg.longitude)) { [double]$cfg.longitude } else { [double]$homeMeta.label_location.longitude }

$item      = $fc.items | Select-Object -First 1
$period    = $item.valid_period.text
$forecasts = @{}
foreach ($x in $item.forecasts) { $forecasts[$x.area] = $x.forecast }

$homeForecast = $forecasts[$homeArea]
$homeRain     = $homeForecast -match $RainWords

$nearbyAreas = foreach ($a in $fc.area_metadata) {
    if ($a.name -eq $homeArea) { continue }
    $d = Get-DistanceKm $lat $lon $a.label_location.latitude $a.label_location.longitude
    if ($d -le $nearbyKm) { [pscustomobject]@{ Name = $a.name; Forecast = $forecasts[$a.name]; Km = $d } }
}
$nearbyAreas = @($nearbyAreas | Sort-Object Km)
$nearbyRain  = @($nearbyAreas | Where-Object { $_.Forecast -match $RainWords })

# ---------- fetch live rainfall ----------
$rf = Get-NeaData $RainfallUrl
$reading = $rf.readings | Select-Object -First 1
$readingTime = ([datetimeoffset]::Parse($reading.timestamp)).ToOffset([timespan]::FromHours(8)).ToString('h:mm tt')
$values = @{}
foreach ($v in $reading.data) { $values[$v.stationId] = [double]$v.value }

$stations = foreach ($s in $rf.stations) {
    $d = Get-DistanceKm $lat $lon $s.location.latitude $s.location.longitude
    if ($d -le $stationKm -and $values.ContainsKey($s.id)) { [pscustomobject]@{ Name = $s.name; Mm = $values[$s.id]; Km = $d } }
}
$stations    = @($stations | Sort-Object Km)
$wetStations = @($stations | Where-Object { $_.Mm -ge $minRainMm })

# ---------- alert level ----------
# 0 = dry, 1 = rain forecast in nearby areas, 2 = rain forecast for your area, 3 = raining now near you
$level = 0
if ($nearbyRain.Count -gt 0)  { $level = 1 }
if ($homeRain)                { $level = 2 }
if ($wetStations.Count -gt 0) { $level = 3 }
$levelText = @('No rain expected nearby', 'Rain forecast in nearby areas', 'Rain forecast for your area', 'Raining near your house now')

$statusText = @(
    "Area: $homeArea"
    "Forecast $($period): $homeForecast"
    $(if ($nearbyRain.Count) { "Nearby rain forecast:`n" + (($nearbyRain | ForEach-Object { "  - {0}: {1} ({2:N1} km)" -f $_.Name, $_.Forecast, $_.Km }) -join "`n") } else { "Nearby areas: no rain forecast" })
    $(if ($wetStations.Count) { "Rain gauges reporting rain (5 min to $readingTime):`n" + (($wetStations | ForEach-Object { "  - {0}: {1} mm ({2:N1} km)" -f $_.Name, $_.Mm, $_.Km }) -join "`n") } else { "Rain gauges within $stationKm km ($($stations.Count)): dry" })
) -join "`n"

$pumpLine = switch ($level) { 0 { 'Pump: not needed right now.' } 1 { 'Pump: consider switching it on.' } default { 'Pump: switch it ON.' } }
$updateText = @(
    "Weather near $homeArea now"
    "Status: $($levelText[$level])"
    ""
    "Forecast $($period): $homeForecast"
    ""
    "Nearby areas:"
    ($nearbyAreas | ForEach-Object { "  {0} {1}: {2} ({3:N1} km)" -f $(if ($_.Forecast -match $RainWords) { '!' } else { '-' }), $_.Name, $_.Forecast, $_.Km })
    ""
    "Rain gauges, last 5 min to $($readingTime):"
    $(if (-not $stations.Count) { "  (none within $stationKm km)" })
    ($stations | ForEach-Object { "  {0} {1}: {2} mm ({3:N1} km)" -f $(if ($_.Mm -ge $minRainMm) { '!' } else { '-' }), $_.Name, $_.Mm, $_.Km })
    ""
    $pumpLine
) | Where-Object { $null -ne $_ }
$updateText = ($updateText | ForEach-Object { $_ }) -join "`n"

# ---------- previous state ----------
$lastLevel = 0
if (Test-Path $statePath) {
    try { $lastLevel = [int](Get-Content $statePath -Raw | ConvertFrom-Json).level } catch {}
}

$msg = $null
if ($level -gt $lastLevel) {
    switch ($level) {
        1 { $msg = "Rain may be coming. Rain is forecast in nearby areas.`n`n$statusText`n`nConsider switching the pump on." }
        2 { $msg = "RAIN FORECAST for $homeArea ($period).`n`n$statusText`n`nSwitch the pump on now." }
        3 { $msg = "IT IS RAINING near your house now.`n`n$statusText`n`nMake sure the pump is on!" }
    }
} elseif ($level -eq 0 -and $lastLevel -gt 0 -and $sendAllClear) {
    $msg = "All clear. No rain forecast or detected near $homeArea now.`n`n$statusText`n`nYou can switch the pump off once the yard has drained."
}

if ($DryRun) {
    Write-Host "Alert level now: $level (last sent level: $lastLevel)`n"
    Write-Host "--- /update reply ---`n$updateText"
    Write-Host "`n--- alert that would be sent ---"
    Write-Host $(if ($msg) { $msg } else { '(none, nothing changed)' })
    return
}

if ($Test) {
    Send-Telegram "Test message from your rain alert.`n`n$updateText"
    Write-Host "Test message sent to Telegram.`n`n$updateText"
    return
}

# ---------- answer /update commands sent since the last run ----------
try {
    $upd = Invoke-RestMethod "https://api.telegram.org/bot$($cfg.telegramBotToken)/getUpdates?timeout=0" -TimeoutSec 30
    $results = @($upd.result)
    if ($results.Count) {
        $asked = $results | Where-Object {
            $m = if ($_.message) { $_.message } else { $_.channel_post }
            $m -and "$($m.chat.id)" -eq "$($cfg.telegramChatId)" -and "$($m.text)" -match $UpdateCmd
        }
        if ($asked) {
            Send-Telegram $updateText
            Write-Log "answered /update"
        }
        # Tell Telegram these updates are handled so they are not answered again
        $maxId = ($results | Measure-Object -Property update_id -Maximum).Maximum
        Invoke-RestMethod "https://api.telegram.org/bot$($cfg.telegramBotToken)/getUpdates?offset=$($maxId + 1)&timeout=0" -TimeoutSec 30 | Out-Null
    }
} catch {
    Write-Log "could not check Telegram commands: $($_.Exception.Message)"
}

# ---------- automatic alert ----------
if ($msg) {
    Send-Telegram $msg
    Write-Log "level $lastLevel -> $level : alert sent"
} else {
    Write-Log "level $level (no change) | forecast: $homeForecast | wet gauges: $($wetStations.Count)"
}

@{ level = $level; updated = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $statePath -Encoding UTF8
