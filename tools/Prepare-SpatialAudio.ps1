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
$settingsPath = Join-Path $runtime.Data 'product-settings.json'
$settings = @{ virtualSinkEndpointId = $virtual.Endpoint.id; virtualSinkFriendlyName = $virtual.Endpoint.name }
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
