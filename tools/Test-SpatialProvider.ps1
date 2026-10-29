[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Atmos', 'NativeMat', 'DtsX', 'Pcm')]
    [string]$Mode,

    [string]$EndpointFilter = ''
)

$repoRoot = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repoRoot 'Engine\SpatialAudioLab.CLI.exe'
if (-not (Test-Path $exe)) { $exe = Join-Path $repoRoot 'build\SpatialAudioLab.CLI.exe' }
if (-not (Test-Path $exe)) {
    throw "找不到原生音频引擎： $exe"
}

Import-Module (Join-Path $PSScriptRoot 'SpatialAudio.Runtime.psm1') -Force
if (-not $EndpointFilter) { $EndpointFilter = (Find-SalVirtualEndpoint -Engine $exe).Endpoint.id }

$formatOutput = @(& $exe device-format $EndpointFilter 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
    throw "无法检查空间音效端点。`n$($formatOutput -join "`n")"
}
$currentFormat = $formatOutput | Where-Object { $_ -match '^\s*device current:' } |
    Select-Object -First 1
$mixFormat = $formatOutput | Where-Object { $_ -match '^\s*mix:' } |
    Select-Object -First 1
$formatMatches = if ($Mode -in @('Atmos', 'NativeMat')) {
    $currentFormat -match 'Dolby (MLP / MAT 1\.0|MAT 2\.)'
} elseif ($Mode -eq 'DtsX') {
    $currentFormat -match 'DTS:X E[12]'
} else {
    $currentFormat -match '12ch, 48000 Hz, 16 bit, block=24, mask=0x2D63F, PCM'
}
if (-not $formatMatches) {
    $wanted = if ($Mode -in @('Atmos', 'NativeMat')) {
        '家庭影院杜比全景声'
    } elseif ($Mode -eq 'DtsX') {
        '家庭影院 DTS:X'
    } else {
        '原生 PCM 7.1.4'
    }
    throw @"
当前载波与 $Mode 不符（$currentFormat）。
启动桥接前需先启用 '$wanted'。
"@
}

if ($Mode -eq 'NativeMat') {
    if ($mixFormat -notmatch '8ch, 48000 Hz, 32 bit, block=32, mask=0x63F, IEEE_FLOAT') {
        throw "原生 MAT 需要 7.1 共享混音格式 ($mixFormat)."
    }

    $endpointId = $formatOutput | Where-Object {
        $_ -match '^ID:\s*\{0\.0\.0\.00000000\}\.\{(?<Endpoint>[0-9a-f-]{36})\}'
    } | Select-Object -First 1
    if ($endpointId -notmatch '^ID:\s*\{0\.0\.0\.00000000\}\.\{(?<Endpoint>[0-9a-f-]{36})\}') {
        throw '无法取得原生 MAT 端点的注册表路径。'
    }

    $registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\' +
        "{$($Matches.Endpoint)}\Properties"
    $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
    $enabled = $properties.'{6737016f-5360-48ee-af05-e616c8ff27a7},2'
    if ($null -eq $enabled -or $enabled.Length -lt 9 -or $enabled[8] -ne 0) {
        throw '已选择 Dolby MAT 载波，但 Windows 空间音效仍未关闭。'
    }

    Write-Host '原生 MAT 已就绪，Windows 空间音效已关闭。'
    Write-Host $mixFormat
    Write-Host $currentFormat
    return
}

$spatialOutput = @(& $exe spatial-test 0.25 $EndpointFilter silence 2>&1 |
    ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
    throw @"
已选择 $Mode 载波，但空间音频客户端无法打开流。
$($spatialOutput -join "`n")
"@
}

$signature = $spatialOutput | Where-Object { $_ -match 'Native static mask:' } |
    Select-Object -First 1
$signatureMatches = if ($Mode -eq 'Pcm') {
    $signature -match 'dynamic objects:\s*0\b'
} else {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Audio.SpatialAudioDeviceConfiguration,Windows.Media.Audio,ContentType=WindowsRuntime] | Out-Null
    [Windows.Media.Audio.SpatialAudioFormatSubtype,Windows.Media.Audio,ContentType=WindowsRuntime] | Out-Null
    $endpointLine = $formatOutput | Where-Object { $_ -match '^ID:\s*(.+)$' } | Select-Object -First 1
    if ($endpointLine -notmatch '^ID:\s*(.+)$') { throw '无法确认空间音效端点 ID。' }
    [Windows.Media.Devices.MediaDevice,Windows.Media.Devices,ContentType=WindowsRuntime] | Out-Null
    $deviceId = [Windows.Media.Devices.MediaDevice]::GetDefaultAudioRenderId([Windows.Media.Devices.AudioDeviceRole]::Default)
    $configuration = [Windows.Media.Audio.SpatialAudioDeviceConfiguration]::GetForDeviceId($deviceId)
    $expected = if ($Mode -eq 'Atmos') { [Windows.Media.Audio.SpatialAudioFormatSubtype]::DolbyAtmosForHomeTheater } else { [Windows.Media.Audio.SpatialAudioFormatSubtype]::DTSXForHomeTheater }
    Write-Host "Windows 当前空间音效格式：$($configuration.ActiveSpatialAudioFormat)"
    ([string]$configuration.ActiveSpatialAudioFormat).Trim('{}') -eq ([string]$expected).Trim('{}') -and
        $signature -match 'dynamic objects:\s*[1-9][0-9]*'
}
if (-not $signatureMatches) {
    throw "载波已启用，但实际空间音效状态与 $Mode 不符（$signature）。"
}

Write-Host "$Mode 空间音效已就绪。"
Write-Host $currentFormat
Write-Host $signature
