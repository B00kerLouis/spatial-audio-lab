[CmdletBinding()]
param([switch]$RepairAppRegistration)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'SpatialAudio.Runtime.psm1') -Force
$runtime = Get-SalRuntime
$log = Join-Path $runtime.Data 'Logs\spatial-audio-diagnostics.txt'
Start-Transcript -Path $log -Force | Out-Null
try {
    Write-Host 'SpatialAudioLab 空间音效诊断'
    Write-Host '已加载的音频端点（含容器及 48k 声道能力）：'
    & $runtime.Engine list-endpoints-json
    Write-Host 'SysVAD PnP 根设备：'
    & (Get-Module SpatialAudio.Runtime) { Get-SalVirtualDevices | Format-List }
    Get-AppxPackage | Where-Object { $_.Name -match '(?i)Dolby.*Access|DTS.*(Sound|Unbound)' } | ForEach-Object {
        $_ | Select-Object Name,Version,Status,PackageFamilyName | Format-List
        if ($RepairAppRegistration) {
            Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $_.InstallLocation 'AppxManifest.xml') -ErrorAction Stop
            Write-Host "已重新注册：$($_.Name)"
        }
    }
    $virtual = Find-SalVirtualEndpoint -Engine $runtime.Engine
    Write-Host "目标端点：$($virtual.Endpoint.name)"
    Write-Host "识别方式：$($virtual.Selection)，设备实例：$($virtual.InstanceId)"
    & $runtime.Engine device-format $virtual.Endpoint.id
    & $runtime.Engine jack-info $virtual.Endpoint.id
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Audio.SpatialAudioDeviceConfiguration,Windows.Media.Audio,ContentType=WindowsRuntime] | Out-Null
    [Windows.Media.Audio.SpatialAudioFormatSubtype,Windows.Media.Audio,ContentType=WindowsRuntime] | Out-Null
    $configuration = [Windows.Media.Audio.SpatialAudioDeviceConfiguration]::GetForDeviceId($virtual.Endpoint.id)
    Write-Host "空间音效支持：$($configuration.IsSpatialAudioSupported)"
    Write-Host "当前格式：$($configuration.ActiveSpatialAudioFormat)"
    Write-Host "默认格式：$($configuration.DefaultSpatialAudioFormat)"
    foreach ($name in 'DolbyAtmosForHomeTheater','DTSXForHomeTheater') {
        $format = [Windows.Media.Audio.SpatialAudioFormatSubtype]::$name
        Write-Host "$name 端点支持：$($configuration.IsSpatialAudioFormatSupported($format))"
    }
} catch { Write-Host "诊断信息：$_" } finally { Stop-Transcript | Out-Null }
Write-Host "诊断报告：$log"
