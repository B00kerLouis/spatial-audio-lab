[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'tools/SpatialAudio.Runtime.psm1') -Force
$module = Get-Module SpatialAudio.Runtime
& $module {
    function Endpoint($id, $name, $channels = 2, $container = $null) {
        [pscustomobject]@{ id = $id; name = $name; maximumChannels48k = $channels; containerId = $container }
    }
    function Expect($endpoints, $devices, $id, $preferred = '', $pinned = $false) {
        $actual = Resolve-SalVirtualEndpoint -Endpoints $endpoints -Devices $devices -PreferredEndpointId $preferred -Pinned $pinned
        if ($actual.Endpoint.id -ne $id) { throw "Expected $id, got $($actual.Endpoint.id)" }
        $script:cases++
    }
    function Reject($endpoints, $devices, $preferred = '', $pinned = $false) {
        $failed = $false
        try { Resolve-SalVirtualEndpoint -Endpoints $endpoints -Devices $devices -PreferredEndpointId $preferred -Pinned $pinned | Out-Null }
        catch { $failed = $true }
        if (-not $failed) { throw 'Ambiguous/absent endpoint must fail, not choose another output.' }
        $script:cases++
    }
    $script:cases = 0
    $hisense = Endpoint 'virtual-hdmi' '1 - HISENSE (Virtual Audio Device (WDM) - Tablet Sample)' 12
    $spdif = Endpoint 'virtual-spdif' 'SPDIF (Virtual Audio Device (WDM) - Tablet Sample)' 2
    $physical = Endpoint 'physical-hdmi' 'HISENSE (NVIDIA High Definition Audio)' 8
    $vb = Endpoint 'vb-matrix' 'VBMatrix In 1 (VB-Audio Matrix VAIO)' 64
    $root1 = [pscustomobject]@{ InstanceId = 'ROOT\MEDIA\0004'; ContainerId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
    $root2 = [pscustomobject]@{ InstanceId = 'ROOT\MEDIA\0009'; ContainerId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
    # The reported desktop inventory: HISENSE exists, unrelated outputs are plentiful,
    # but PnP discovery is absent or returns more than one SysVAD root.
    Expect @($hisense, $spdif, $physical, $vb) @() 'virtual-hdmi'
    Expect @($hisense, $spdif, $physical, $vb) @($root1, $root2) 'virtual-hdmi'
    Expect @($hisense, $spdif) @($root1) 'virtual-hdmi'
    Reject @($physical, $vb) @()
    $second = Endpoint 'other-virtual' $hisense.name 12
    Reject @($hisense, $second) @($root1, $root2)
    Expect @($hisense, $second) @() 'other-virtual' 'other-virtual' $true
    Reject @($hisense) @() 'disconnected-pinned' $true
    Expect @($hisense) @() 'virtual-hdmi' 'disconnected-auto' $false
    $renamed = Endpoint 'renamed' 'My 12-channel virtual sink' 12 ('{' + $root1.ContainerId + '}')
    Expect @($renamed, $physical, $vb) @($root1) 'renamed'
    $zeroRoot = [pscustomobject]@{ InstanceId = 'ROOT\MEDIA\0004'; ContainerId = '00000000-0000-0000-0000-000000000000' }
    $zero = Endpoint 'zero' 'Unrelated speakers' 12 $zeroRoot.ContainerId
    Reject @($zero, $physical) @($zeroRoot)
    # Duplicate enumeration rows do not turn one real endpoint into two candidates.
    Expect @($hisense, $hisense) @($root1, $root2) 'virtual-hdmi'
    # Simulate PnP property queries; never touch live host devices in these tests.
    function Get-SalPnpProperty {
        param($InstanceId, $KeyName)
        if ($KeyName -eq 'DEVPKEY_Device_Parent' -and $InstanceId -like 'SWD\MMDEVAPI\*') { return 'ROOT\MEDIA\0009' }
        if ($KeyName -eq 'DEVPKEY_Device_HardwareIds' -and $InstanceId -eq 'ROOT\MEDIA\0009') { return 'Root\sysvad_ComponentizedAudioSample' }
    }
    $instance = Resolve-SalVirtualDeviceInstance $hisense @($root1, $root2)
    if ($instance -ne $root2.InstanceId) { throw 'The endpoint parent must win over duplicate roots.' }
    $script:cases++
    function Get-SalPnpProperty { param($InstanceId, $KeyName) return $null }
    if (Resolve-SalVirtualDeviceInstance $hisense @($root1, $root2)) { throw 'Never guess a device to restart.' }
    $script:cases++
    if ((Resolve-SalVirtualDeviceInstance $hisense @($root1)) -ne $root1.InstanceId) { throw 'Unique verified SysVAD root fallback failed.' }
    $script:cases++
    if (Resolve-SalVirtualDeviceInstance $physical @($root1)) { throw 'Do not associate physical HDMI with SysVAD.' }
    $script:cases++
    # Exercise the public discovery path, including JSON parsing and saved settings.
    $temporaryData = Join-Path ([IO.Path]::GetTempPath()) ('sal-endpoint-test-' + [guid]::NewGuid().ToString('N'))
    New-Item $temporaryData -ItemType Directory | Out-Null
    $script:fixtureJson = @($hisense, $spdif, $physical, $vb) | ForEach-Object { $_ | ConvertTo-Json -Compress }
    function Get-SalFixtureJson { param($Command) $global:LASTEXITCODE = 0; $script:fixtureJson }
    function Get-SalRuntime { [pscustomobject]@{ Data = $temporaryData } }
    function Get-SalVirtualDevices { @() }
    try {
        $actual = Find-SalVirtualEndpoint -Engine Get-SalFixtureJson
        if ($actual.Endpoint.id -ne 'virtual-hdmi' -or $actual.InstanceId) { throw 'Public discovery with unavailable PnP failed.' }
        $script:cases++
        @{ virtualSinkEndpointId = 'vb-matrix'; virtualSinkPinned = $true; unrelatedSetting = 'preserve-me' } |
            ConvertTo-Json | Set-Content (Join-Path $temporaryData 'product-settings.json') -Encoding UTF8
        $actual = Find-SalVirtualEndpoint -Engine Get-SalFixtureJson
        if ($actual.Endpoint.id -ne 'vb-matrix' -or $actual.InstanceId) { throw 'Pinned endpoint was not honored.' }
        $script:cases++
    } finally { Remove-Item $temporaryData -Recurse -Force }
    Write-Host "Virtual endpoint regression tests passed: $script:cases cases."
}
Remove-Module SpatialAudio.Runtime
