function Get-SalRuntime {
    $root = Split-Path $PSScriptRoot -Parent
    $engine = Join-Path $root 'Engine\SpatialAudioLab.CLI.exe'
    if (-not (Test-Path $engine)) { $engine = Join-Path $root 'build\SpatialAudioLab.CLI.exe' }
    if (-not (Test-Path $engine)) { throw "找不到原生音频引擎：$engine" }
    $data = if (Test-Path (Join-Path $root 'portable.flag')) { Join-Path $root 'Data' } else { Join-Path $env:LOCALAPPDATA 'SpatialAudioLab' }
    New-Item (Join-Path $data 'Logs') -ItemType Directory -Force | Out-Null
    [pscustomobject]@{ Root = $root; Engine = $engine; Data = $data }
}

function Get-SalPnpProperty {
    param([string]$InstanceId, [string]$KeyName)
    try { (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop).Data }
    catch { return $null }
}

function Get-SalVirtualDevices {
    # PnpDevice can be unavailable in remote sessions; CIM supplies a second inventory.
    $devices = @()
    try { $devices = @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction Stop) } catch { }
    $found = @{}
    foreach ($device in $devices) {
        $ids = @(Get-SalPnpProperty $device.InstanceId 'DEVPKEY_Device_HardwareIds')
        if ($ids -contains 'Root\sysvad_ComponentizedAudioSample') {
            $found[$device.InstanceId] = [pscustomobject]@{
                InstanceId = $device.InstanceId
                ContainerId = Get-SalPnpProperty $device.InstanceId 'DEVPKEY_Device_ContainerId'
            }
        }
    }
    if (-not $found.Count) {
        try {
            foreach ($device in @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='MEDIA'" -ErrorAction Stop)) {
                if ($device.HardwareID -contains 'Root\sysvad_ComponentizedAudioSample' -and $device.Present -ne $false) {
                    $found[$device.PNPDeviceID] = [pscustomobject]@{
                        InstanceId = $device.PNPDeviceID
                        ContainerId = Get-SalPnpProperty $device.PNPDeviceID 'DEVPKEY_Device_ContainerId'
                    }
                }
            }
        } catch { Write-Verbose "CIM 设备查询不可用：$_" }
    }
    @($found.Values)
}

function Test-SalContainerMatch {
    param($First, $Second)
    $a = ([string]$First).Trim('{}')
    $b = ([string]$Second).Trim('{}')
    return $a -and $b -and $a -ne '00000000-0000-0000-0000-000000000000' -and $a -eq $b
}

function Resolve-SalVirtualEndpoint {
    param([object[]]$Endpoints, [object[]]$Devices, [string]$PreferredEndpointId = '', [bool]$Pinned = $false)
    $knownPattern = '(?i)SpatialAudioLab Virtual Sink|HISENSE.*Virtual Audio|Virtual Audio.*HISENSE'
    $candidates = @($Endpoints | Where-Object {
        $endpoint = $_
        ($endpoint.name -match $knownPattern) -or
        ($endpoint.name -match '(?i)Virtual Audio Device.*Tablet Sample') -or
        @($Devices | Where-Object { Test-SalContainerMatch $_.ContainerId $endpoint.containerId }).Count
    } | Sort-Object id -Unique)
    if ($PreferredEndpointId) {
        $preferred = @($Endpoints | Where-Object { $_.id -eq $PreferredEndpointId })
        if ($Pinned -and $preferred.Count -ne 1) {
            throw "手动指定的 Windows 捕获端点不在线：$PreferredEndpointId。请在 Studio 的实时桥接页刷新并重新选择端点。"
        }
        if ($preferred.Count -eq 1 -and ($Pinned -or @($candidates | Where-Object { $_.id -eq $PreferredEndpointId }).Count)) {
            return [pscustomobject]@{ Endpoint = $preferred[0]; Selection = 'SavedEndpoint' }
        }
    }
    # Endpoint recognition does not depend on PnP/container availability. In particular,
    # a unique HISENSE virtual endpoint is valid even if roots are absent or duplicated.
    $known = @($candidates | Where-Object { $_.name -match $knownPattern })
    if ($known.Count -eq 1) { return [pscustomobject]@{ Endpoint = $known[0]; Selection = 'VirtualEndpointName' } }
    if ($known.Count -gt 1) { $candidates = $known }
    $pcm714 = @($candidates | Where-Object { $_.maximumChannels48k -ge 12 })
    if ($pcm714.Count -eq 1) { return [pscustomobject]@{ Endpoint = $pcm714[0]; Selection = 'Pcm714Capability' } }
    $hdmi = @($candidates | Where-Object { $_.name -match '(?i)HISENSE|HDMI|SpatialAudioLab Virtual Sink' })
    if ($hdmi.Count -eq 1) { return [pscustomobject]@{ Endpoint = $hdmi[0]; Selection = 'VirtualHdmi' } }
    if ($candidates.Count -eq 1) { return [pscustomobject]@{ Endpoint = $candidates[0]; Selection = 'SingleVirtualEndpoint' } }
    $inventory = $Endpoints | ForEach-Object { "$($_.name) [48k最大声道=$($_.maximumChannels48k)] [$($_.id)]" }
    throw "无法唯一确定 Windows 捕获端点（虚拟候选 $($candidates.Count)，PnP 设备 $($Devices.Count)）。请在 Studio 的实时桥接页选择 HISENSE 虚拟声卡；已列出的端点无需重复安装驱动。`n$($inventory -join "`n")"
}

function Resolve-SalVirtualDeviceInstance {
    param($Endpoint, [object[]]$Devices)
    # Follow the actual endpoint's parent chain before using a shared container.
    $current = 'SWD\MMDEVAPI\' + $Endpoint.id
    $visited = @{}
    for ($depth = 0; $depth -lt 16 -and $current -and -not $visited.ContainsKey($current); $depth++) {
        $visited[$current] = $true
        $ids = @(Get-SalPnpProperty $current 'DEVPKEY_Device_HardwareIds')
        if ($ids -contains 'Root\sysvad_ComponentizedAudioSample') { return $current }
        $current = [string](Get-SalPnpProperty $current 'DEVPKEY_Device_Parent')
    }
    $matching = @($Devices | Where-Object { Test-SalContainerMatch $_.ContainerId $Endpoint.containerId })
    if ($matching.Count -eq 1) { return $matching[0].InstanceId }
    # Only the known virtual name can use the unique verified SysVAD root fallback.
    if ($Devices.Count -eq 1 -and $Endpoint.name -match '(?i)SpatialAudioLab Virtual Sink|Virtual Audio.*Tablet Sample') {
        return $Devices[0].InstanceId
    }
    return ''
}

function Find-SalVirtualEndpoint {
    param([Parameter(Mandatory)][string]$Engine)
    $json = @(& $Engine list-endpoints-json)
    if ($LASTEXITCODE -ne 0) { throw '无法枚举 Windows 音频端点。' }
    $endpoints = @($json | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
    $devices = @(Get-SalVirtualDevices)
    $settings = $null
    $runtime = Get-SalRuntime
    $settingsPath = Join-Path $runtime.Data 'product-settings.json'
    if (Test-Path $settingsPath) { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json }
    $selection = Resolve-SalVirtualEndpoint -Endpoints $endpoints -Devices $devices `
        -PreferredEndpointId ([string]$settings.virtualSinkEndpointId) -Pinned ([bool]$settings.virtualSinkPinned)
    $instance = Resolve-SalVirtualDeviceInstance -Endpoint $selection.Endpoint -Devices $devices
    Write-Verbose "端点识别：$($selection.Selection)，PnP 根设备数：$($devices.Count)，实例：$instance"
    [pscustomobject]@{ Endpoint = $selection.Endpoint; InstanceId = $instance; Selection = $selection.Selection }
}
Export-ModuleMember -Function Get-SalRuntime,Find-SalVirtualEndpoint
