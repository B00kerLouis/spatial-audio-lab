[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Atmos', 'NativeMat', 'DtsX', 'Pcm')]
    [string]$Mode,

    [string]$EndpointFilter = '',

    [string]$DeviceInstanceId = '',

    [ValidateRange(5, 30)]
    [int]$TimeoutSeconds = 15
)

$repoRoot = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repoRoot 'Engine\SpatialAudioLab.CLI.exe'
if (-not (Test-Path $exe)) { $exe = Join-Path $repoRoot 'build\SpatialAudioLab.CLI.exe' }
$preflight = Join-Path $PSScriptRoot 'Test-SpatialProvider.ps1'
Import-Module (Join-Path $PSScriptRoot 'SpatialAudio.Runtime.psm1') -Force
if (-not $EndpointFilter -or -not $DeviceInstanceId) {
    $virtual = Find-SalVirtualEndpoint -Engine $exe
    if (-not $EndpointFilter) { $EndpointFilter = $virtual.Endpoint.id }
    if (-not $DeviceInstanceId) { $DeviceInstanceId = $virtual.InstanceId }
}

$atmosFormat = [Guid]'A289735D-FA3E-4E35-9D7D-B6F896ACB2E7'
$dtsXFormat = [Guid]'10201B4A-3322-4967-BF40-2CAA9BAFCA44'

if (-not (Test-Path $exe)) {
    throw "找不到原生音频引擎： $exe"
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Media.Audio.SpatialAudioDeviceConfiguration,Windows.Media.Audio,ContentType=WindowsRuntime] |
    Out-Null
[Windows.Media.Audio.SetDefaultSpatialAudioFormatResult,Windows.Media.Audio,ContentType=WindowsRuntime] |
    Out-Null
[Windows.Media.Devices.MediaDevice,Windows.Media.Devices,ContentType=WindowsRuntime] | Out-Null

if (-not ('SpatialRegistryAccess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class SpatialRegistryAccess {
    static readonly IntPtr HKEY_LOCAL_MACHINE =
        new IntPtr(unchecked((long)0x80000002));

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegOpenKeyEx(IntPtr key, string subKey, uint options,
                                    uint desiredAccess, out IntPtr result);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegQueryValueEx(IntPtr key, string name, IntPtr reserved,
                                       out uint type, byte[] data, ref uint size);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegSetValueEx(IntPtr key, string name, uint reserved,
                                     uint type, byte[] data, int size);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegDeleteValue(IntPtr key, string name);

    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(IntPtr key);

    public static byte[] GetBinary(string subKey, string name) {
        IntPtr key;
        int error = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, 0x0001, out key);
        if (error != 0) throw new Win32Exception(error);
        try {
            uint type;
            uint size = 0;
            error = RegQueryValueEx(key, name, IntPtr.Zero, out type, null, ref size);
            if (error == 2) return null;
            if (error != 0) throw new Win32Exception(error);
            if (type != 3) throw new InvalidOperationException(
                "The spatial endpoint property is not REG_BINARY.");
            byte[] data = new byte[size];
            error = RegQueryValueEx(key, name, IntPtr.Zero, out type, data, ref size);
            if (error != 0) throw new Win32Exception(error);
            return data;
        } finally {
            RegCloseKey(key);
        }
    }

    public static void SetBinary(string subKey, string name, byte[] data) {
        IntPtr key;
        int error = RegOpenKeyEx(HKEY_LOCAL_MACHINE, subKey, 0, 0x0002, out key);
        if (error != 0) throw new Win32Exception(error);
        try {
            if (data == null) {
                error = RegDeleteValue(key, name);
                if (error == 2) return;
            } else {
                error = RegSetValueEx(key, name, 0, 3, data, data.Length);
            }
            if (error != 0) throw new Win32Exception(error);
        } finally {
            RegCloseKey(key);
        }
    }

    public static byte[] FromHex(string hex) {
        if ((hex.Length & 1) != 0) throw new ArgumentException("Invalid hex string.");
        byte[] result = new byte[hex.Length / 2];
        for (int index = 0; index < result.Length; ++index)
            result[index] = Convert.ToByte(hex.Substring(index * 2, 2), 16);
        return result;
    }
}
'@
}

function Wait-WinRtOperation($Operation, [Type]$ResultType) {
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1
        } | Select-Object -First 1
    if ($null -eq $asTask) {
        throw '无法加载 Windows 异步音频接口。'
    }
    $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.GetAwaiter().GetResult()
}

function Invoke-SpatialPreflight {
    param([string]$RequestedMode)

    try {
        $output = @(& $preflight -Mode $RequestedMode `
            -EndpointFilter $EndpointFilter 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Ready = $true; Output = $output }
    } catch {
        return [pscustomobject]@{ Ready = $false; Output = @("$_") }
    }
}

function Wait-SpatialPreflight {
    param([string]$RequestedMode)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $result = $null
    do {
        $result = Invoke-SpatialPreflight $RequestedMode
        if ($result.Ready) { return $result }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $result
}

function Get-SpatialConfiguration([bool]$RequireSupported = $true) {
    $deviceId = [Windows.Media.Devices.MediaDevice]::GetDefaultAudioRenderId(
        [Windows.Media.Devices.AudioDeviceRole]::Default)
    if ([string]::IsNullOrWhiteSpace($deviceId)) {
        throw 'Windows 未返回默认输出端点。'
    }
    $configuration = [Windows.Media.Audio.SpatialAudioDeviceConfiguration]::GetForDeviceId(
        $deviceId)
    if ($null -eq $configuration -or ($RequireSupported -and -not $configuration.IsSpatialAudioSupported)) {
        throw "默认端点尚未提供空间音效能力： $deviceId"
    }
    [pscustomobject]@{ DeviceId = $deviceId; Configuration = $configuration }
}

function Set-WindowsSpatialFormat([Guid]$Format) {
    $spatial = Get-SpatialConfiguration
    $operation = $spatial.Configuration.SetDefaultSpatialAudioFormatAsync($Format.ToString("D"))
    Wait-WinRtOperation $operation `
        ([Windows.Media.Audio.SetDefaultSpatialAudioFormatResult])
}

function Get-EndpointRegistrySubKey([string]$DeviceId) {
    if ($DeviceId -notmatch '(?i)\{0\.0\.0\.00000000\}\.\{(?<Endpoint>[0-9a-f-]{36})\}') {
        throw "无法取得端点 GUID： $DeviceId"
    }
    "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\" +
        "{$($Matches.Endpoint)}\Properties"
}

function Set-Bytes([byte[]]$Destination, [int]$Offset, [byte[]]$Source) {
    [Array]::Copy($Source, 0, $Destination, $Offset, $Source.Length)
}

function Get-SpatialRegistryTemplate([string]$RequestedMode) {
    $guid = if ($RequestedMode -eq 'Atmos') {
        '5D7389A23EFA354E9D7DB6F896ACB2E7'
    } else {
        '4A1B201022336749BF402CAA9BAFCA44'
    }
    $objectState = if ($RequestedMode -eq 'Atmos') {
        'FE1F0C000100000014000000'
    } else {
        'FEFF0F000100000020000000'
    }
    $carrierSubtype = if ($RequestedMode -eq 'Atmos') { '0C030000' } else { '0B010000' }

    [pscustomobject]@{
        Enabled = [SpatialRegistryAccess]::FromHex('02000000010000000100')
        Active = [SpatialRegistryAccess]::FromHex(
            '41000000010000000200005A' + $guid + $objectState +
            'A0400000A0400000A0400000000000000000000000000000F0410000' +
            'B442000007430000344200003442000007430000803F0000803F0000' +
            '803F0000803F0000803F0000803F0000803F0000803F96433B3FBF' +
            '0E1C3F0000803FBF0E1C3FD39FFD3ED39FFD3E0000803F00000000' +
            '00000000')
        Provider = [SpatialRegistryAccess]::FromHex(
            '41000000010000000200005A010000000000000001000000' +
            $guid + $guid +
            '00000000000000000000000000000000010000000000000001000000')
        Selection = [SpatialRegistryAccess]::FromHex(
            '41000000010000000000000000000000' + $guid)
        Carrier = [SpatialRegistryAccess]::FromHex(
            '4100000001000000FEFF080000EE020000E02E001000100016001000' +
            '3F060000' + $carrierSubtype + 'EA0C1000800000AA00389B71')
    }
}

function Write-NativePcmRegistryState(
        [string]$RegistrySubKey,
        [string[]]$ValueNames,
        [hashtable]$Original) {
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[0],
        [SpatialRegistryAccess]::FromHex('02000000010000000000'))
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[1],
        [SpatialRegistryAccess]::FromHex('410000000100000000'))

    $providerBytes = [Math]::Max(88, $Original[$ValueNames[2]].Length)
    $providerState = New-Object byte[] $providerBytes
    Set-Bytes $providerState 0 `
        ([SpatialRegistryAccess]::FromHex('41000000010000000200005A'))
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[2], $providerState)

    $selection = New-Object byte[] 32
    Set-Bytes $selection 0 `
        ([SpatialRegistryAccess]::FromHex('41000000010000000000000000000000'))
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[3], $selection)
}

function Set-NativePcmDeviceFormat {
    $output = @(& $exe set-pcm714-format $EndpointFilter 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "无法协商原生 PCM 7.1.4 格式。`n$($output -join "`n")"
    }
    $output | ForEach-Object { if ($_ -ne '') { Write-Host $_ } }
}

function Set-SpatialCodecDeviceFormat([string]$RequestedMode) {
    $codec = if ($RequestedMode -eq 'NativeMat') {
        'mat10'
    } elseif ($RequestedMode -eq 'Atmos') {
        'atmos'
    } else {
        'dtsx'
    }
    $output = @(& $exe set-codec-format $codec $EndpointFilter 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "无法协商 $RequestedMode 设备与混音格式。`n" +
            ($output -join "`n")
    }
    $output | ForEach-Object { if ($_ -ne '') { Write-Host $_ } }
}

function Get-SpatialRegistryMode(
        [hashtable]$Values,
        [string[]]$ValueNames) {
    $enabled = $Values[$ValueNames[0]]
    if ($enabled.Length -lt 9 -or $enabled[8] -eq 0) { return 'Pcm' }

    $carrier = $Values[$ValueNames[4]]
    if ($carrier.Length -lt 36) { return $null }
    switch ([BitConverter]::ToUInt32($carrier, 32)) {
        0x030C { return 'Atmos' }
        0x010B { return 'DtsX' }
        default { return $null }
    }
}

function Write-SpatialRegistryState(
        [string]$RegistrySubKey,
        [string[]]$ValueNames,
        [string]$RequestedMode) {
    $values = Get-SpatialRegistryTemplate $RequestedMode
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[0], $values.Enabled)
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[1], $values.Active)
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[2], $values.Provider)
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[3], $values.Selection)
    [SpatialRegistryAccess]::SetBinary($RegistrySubKey, $ValueNames[4], $values.Carrier)
}

function Wait-SpatialEndpoint {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        & $exe set-default $EndpointFilter *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "端点 '$EndpointFilter' 在重启后未恢复。"
}

function Restart-AudioServices {
    Write-Host '正在重新启动 Windows 音频服务。'
    Stop-Service Audiosrv -Force -ErrorAction Stop
    Stop-Service AudioEndpointBuilder -Force -ErrorAction Stop
    Start-Service AudioEndpointBuilder -ErrorAction Stop
    Start-Service Audiosrv -ErrorAction Stop
    Wait-SpatialEndpoint
}

function Restart-SpatialDevice {
    $restartOutput = @(& pnputil.exe /restart-device $DeviceInstanceId 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "无法重启设备 $DeviceInstanceId。`n$($restartOutput -join "`n")"
    }
    $restartOutput | ForEach-Object { if ($_ -ne '') { Write-Host $_ } }

    Wait-SpatialEndpoint
}

function Set-SpatialRegistryFallback([string]$RequestedMode) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "请以管理员身份运行 Studio，再配置 $RequestedMode 空间音效。"
    }

    $spatial = Get-SpatialConfiguration $false
    $registrySubKey = Get-EndpointRegistrySubKey $spatial.DeviceId
    $valueNames = @(
        '{6737016f-5360-48ee-af05-e616c8ff27a7},2',
        '{fd8a7b27-0b18-4025-ab1c-bdd6b32e1604},2',
        '{908dba32-edff-4c28-8e45-c918561f6748},2',
        '{8a845654-d6c3-4cd7-b4eb-243d4bd99032},2',
        '{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0'
    )
    $original = @{}
    foreach ($name in $valueNames) {
        $original[$name] = [SpatialRegistryAccess]::GetBinary($registrySubKey, $name)
    }
    $runtime = Get-SalRuntime
    $backup = @{}
    foreach ($key in $valueNames) { $backup[$key] = if ($original[$key]) { [Convert]::ToBase64String($original[$key]) } else { $null } }
    $backupPath = Join-Path $runtime.Data ('Logs\spatial-state-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    @{ endpoint = $spatial.DeviceId; values = $backup } | ConvertTo-Json -Depth 4 | Set-Content $backupPath -Encoding UTF8
    Write-Host "原始端点状态备份：$backupPath"
    $originalMode = Get-SpatialRegistryMode $original $valueNames

    try {
        if ($RequestedMode -eq 'Pcm') {
            Write-NativePcmRegistryState $registrySubKey $valueNames $original
            Write-Host '正在为原生 PCM 7.1.4 重建音频服务。'
            Restart-AudioServices
            Set-NativePcmDeviceFormat
        } elseif ($RequestedMode -eq 'NativeMat') {
            Write-Host '正在设置 MAT 载波并关闭 Windows 空间音效。'
            Set-SpatialCodecDeviceFormat $RequestedMode
            Write-NativePcmRegistryState $registrySubKey $valueNames $original
            Write-Host '正在为原生 MAT 重建音频服务。'
            Restart-AudioServices
        } else {
            Write-Host "正在关闭当前空间音效，再切换至 $RequestedMode。"
            Write-NativePcmRegistryState $registrySubKey $valueNames $original
            Restart-AudioServices
            Set-SpatialCodecDeviceFormat $RequestedMode
            Write-SpatialRegistryState $registrySubKey $valueNames $RequestedMode
            Write-Host "正在为 $RequestedMode 重建音频服务。"
            Restart-AudioServices
        }

        $verified = Wait-SpatialPreflight $RequestedMode
        if (-not $verified.Ready) {
            Write-Warning '音频服务重启后仍未就绪，正在重新枚举虚拟设备。'
            if ($RequestedMode -in @('Pcm', 'NativeMat')) {
                Write-NativePcmRegistryState $registrySubKey $valueNames $original
            } else {
                Write-SpatialRegistryState $registrySubKey $valueNames $RequestedMode
            }
            if ($RequestedMode -eq 'NativeMat') {
                Set-SpatialCodecDeviceFormat $RequestedMode
                Write-NativePcmRegistryState $registrySubKey $valueNames $original
            }
            Restart-SpatialDevice
            if ($RequestedMode -eq 'Pcm') {
                Set-NativePcmDeviceFormat
            }
            $verified = Wait-SpatialPreflight $RequestedMode
            if (-not $verified.Ready) {
                throw "$RequestedMode 未能就绪。`n$($verified.Output -join "`n")"
            }
        }
        $verified.Output | Write-Host
    } catch {
        $failure = "$_"
        Write-Warning "$RequestedMode 启用失败，正在恢复原有端点状态。"
        foreach ($name in $valueNames) {
            [SpatialRegistryAccess]::SetBinary($registrySubKey, $name, $original[$name])
        }
        try {
            Restart-AudioServices
            if ($originalMode -eq 'Pcm') { Set-NativePcmDeviceFormat }
        } catch {
            try { Restart-SpatialDevice } catch { Write-Warning "恢复后重启设备失败： $_" }
        }
        throw $failure
    }
}

& $exe set-default $EndpointFilter
if ($LASTEXITCODE -ne 0) {
    throw "无法将 '$EndpointFilter' 设为默认输出： $LASTEXITCODE"
}

$alreadyReady = Invoke-SpatialPreflight $Mode
if ($alreadyReady.Ready) {
    $alreadyReady.Output | Write-Host
    if ($Mode -eq 'NativeMat') {
        Write-Host '原生 MAT 模式已启用。'
    } elseif ($Mode -eq 'Pcm') {
        Write-Host '原生 PCM 7.1.4 已启用。'
    } else {
        Write-Host "$Mode 空间音效已启用。"
    }
    return
}

if ($Mode -in @('Pcm', 'NativeMat')) {
    Set-SpatialRegistryFallback $Mode
    if ($Mode -eq 'Pcm') {
        Write-Host '已选择并验证原生 PCM 7.1.4。'
    } else {
        Write-Host '已选择并验证原生 MAT。'
    }
    return
}

# Negotiate a supported encoded carrier before asking Windows to enable its spatial provider.
Set-SpatialCodecDeviceFormat $Mode

$targetFormat = if ($Mode -eq 'Atmos') { $atmosFormat } else { $dtsXFormat }
$result = $null
try {
    $result = Set-WindowsSpatialFormat $targetFormat
    Write-Host "Windows 空间音效请求结果： $($result.Status)"
} catch {
    Write-Host "Windows 空间音效请求失败： $_"
}

if ($null -ne $result -and $result.Status -eq 'Succeeded') {
    $verified = Wait-SpatialPreflight $Mode
    if ($verified.Ready) {
        $verified.Output | Write-Host
        Write-Host "已选择并验证 $Mode 空间音效。"
        return
    }
}

Set-SpatialRegistryFallback $Mode
Write-Host "已选择并验证 $Mode 空间音效。"
