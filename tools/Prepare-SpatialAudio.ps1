[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Atmos','NativeMat','DtsX','Pcm')][string]$Mode)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
Import-Module (Join-Path $PSScriptRoot 'SpatialAudio.Runtime.psm1') -Force
$runtime = Get-SalRuntime
$virtual = Find-SalVirtualEndpoint -Engine $runtime.Engine
Write-Host "虚拟端点：$($virtual.Endpoint.name) [$($virtual.Endpoint.id)]"
Write-Host "设备实例：$($virtual.InstanceId)"
Write-Host "识别方式：$($virtual.Selection)"
if (-not $virtual.InstanceId) { Write-Host '端点已识别；PnP 实例不可用时仍可配置端点，但不会重启未经确认的设备。' }
$settingsPath = Join-Path $runtime.Data 'product-settings.json'
$settings = @{}
if (Test-Path $settingsPath) {
    $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
    foreach ($property in $existing.PSObject.Properties) { $settings[$property.Name] = $property.Value }
}
$settings.virtualSinkEndpointId = $virtual.Endpoint.id
$settings.virtualSinkFriendlyName = $virtual.Endpoint.name
$settings | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
if ($Mode -eq 'Atmos' -and -not (Get-AppxPackage -Name '*DolbyAccess*')) {
    throw '当前用户尚未安装 Dolby Access。请安装并完成应用内配置，然后重试。'
}
if ($Mode -eq 'DtsX' -and -not (Get-AppxPackage | Where-Object { $_.Name -match '(?i)DTS.*(Sound|Unbound)' })) {
    throw '当前用户尚未安装 DTS Sound Unbound。请安装并完成应用内配置，然后重试。'
}
& (Join-Path $PSScriptRoot 'Set-SpatialProvider.ps1') -Mode $Mode `
    -EndpointFilter $virtual.Endpoint.id -DeviceInstanceId $virtual.InstanceId
Write-Host "$Mode 空间音效及载波已配置并验证。"
