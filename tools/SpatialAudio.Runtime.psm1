function Get-SalRuntime {
    $root = Split-Path $PSScriptRoot -Parent
    $engine = Join-Path $root 'Engine\SpatialAudioLab.CLI.exe'
    if (-not (Test-Path $engine)) { $engine = Join-Path $root 'build\SpatialAudioLab.CLI.exe' }
    if (-not (Test-Path $engine)) { throw "找不到原生音频引擎：$engine" }
    $data = if (Test-Path (Join-Path $root 'portable.flag')) { Join-Path $root 'Data' } else { Join-Path $env:LOCALAPPDATA 'SpatialAudioLab' }
    New-Item (Join-Path $data 'Logs') -ItemType Directory -Force | Out-Null
    [pscustomobject]@{ Root = $root; Engine = $engine; Data = $data }
}

function Find-SalVirtualEndpoint {
    param([Parameter(Mandatory)][string]$Engine)
    $json = @(& $Engine list-endpoints-json)
    if ($LASTEXITCODE -ne 0) { throw '无法枚举 Windows 音频端点。' }
    $endpoints = @($json | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
    $roots = @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $ids = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data
        $ids -contains 'Root\sysvad_ComponentizedAudioSample'
    })
    $candidates = @()
    foreach ($device in $roots) {
        $container = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction SilentlyContinue).Data
        foreach ($endpoint in $endpoints) {
            if ($container -and $endpoint.containerId -and ([string]$endpoint.containerId).Trim('{}') -eq ([string]$container).Trim('{}')) {
                $candidates += [pscustomobject]@{ Endpoint = $endpoint; InstanceId = $device.InstanceId }
            }
        }
    }
    if (-not $candidates.Count) {
        $known = @($endpoints | Where-Object { $_.name -match '(?i)SpatialAudioLab Virtual Sink|HISENSE.*Virtual Audio|Virtual Audio.*HISENSE' })
        if ($known.Count -eq 1 -and $roots.Count -eq 1) {
            $candidates = @([pscustomobject]@{ Endpoint = $known[0]; InstanceId = $roots[0].InstanceId })
        }
    }
    $hdmi = @($candidates | Where-Object { $_.Endpoint.name -match '(?i)HISENSE|HDMI|SpatialAudioLab Virtual Sink' })
    if ($hdmi.Count -eq 1) { return $hdmi[0] }
    $pcm714 = @($candidates | Where-Object { $_.Endpoint.maximumChannels48k -ge 12 })
    if ($pcm714.Count -eq 1) { return $pcm714[0] }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    $inventory = $endpoints | ForEach-Object { "$($_.name) [$($_.id)]" }
    throw "未找到唯一的 SpatialAudioLab 虚拟输出端点。请先安装并启用包内的测试驱动。`n$($inventory -join "`n")"
}
Export-ModuleMember -Function Get-SalRuntime,Find-SalVirtualEndpoint
