[CmdletBinding()]
param()

$repoRoot = Split-Path $PSScriptRoot -Parent
$buildRoot = Join-Path $repoRoot 'build-native'
$publishRoot = Join-Path $repoRoot 'build'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw 'vswhere.exe was not found. Install Visual Studio 2022 with the C++ workload.'
}
$visualStudio = & $vswhere -latest -products '*' -property installationPath
if (-not $visualStudio) {
    throw 'Visual Studio 2022 was not found.'
}
$devCmd = Join-Path $visualStudio 'Common7\Tools\VsDevCmd.bat'
New-Item -ItemType Directory -Path $buildRoot, $publishRoot -Force | Out-Null

$sources = @(
    'asio_renderer.cpp',
    'audio_platform.cpp',
    'bridge_meter.cpp',
    'capture_commands.cpp',
    'dolby_probe.cpp',
    'dtsx_analysis.cpp',
    'layout_mix.cpp',
    'media_foundation_probe.cpp',
    'mat_analysis.cpp',
    'mat_capture_client.cpp',
    'mat_format.cpp',
    'mat_pipeline.cpp',
    'multi_endpoint_renderer.cpp',
    'pcm_queue.cpp',
    'pcm_stdin_renderer.cpp',
    'pcm_pipeline.cpp',
    'speaker_layout.cpp',
    'spatial_audio_sample.cpp',
    'wave_io.cpp'
) | ForEach-Object { '"..\src\' + $_ + '"' }

$asioFlags = ''
$asioLibraries = ''
if ($env:SAL_ASIO_SDK_ROOT) {
    $asioCommon = Join-Path $env:SAL_ASIO_SDK_ROOT 'common'
    if (-not (Test-Path (Join-Path $asioCommon 'iasiodrv.h'))) {
        throw 'SAL_ASIO_SDK_ROOT must contain common/iasiodrv.h'
    }
    $asioFlags = '/DSAL_ENABLE_ASIO=1 /I"' + $asioCommon + '"'
    $asioLibraries = 'advapi32.lib user32.lib'
}

$compile = @(
    'cl /nologo /std:c++20 /EHsc /W4 /permissive- /utf-8',
    '/DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN',
    $asioFlags,
    ($sources -join ' '),
    '/Fe:SpatialAudioLab.CLI.exe',
    '/link ole32.lib runtimeobject.lib windowsapp.lib uuid.lib avrt.lib propsys.lib mmdevapi.lib',
    'mf.lib mfplat.lib mfreadwrite.lib mfuuid.lib',
    $asioLibraries
) -join ' '
$command = '"' + $devCmd + '" -arch=x64 -host_arch=x64 >nul && cd /d "' +
    $buildRoot + '" && ' + $compile

& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw "SpatialAudioLab CLI build failed: $LASTEXITCODE"
}
Copy-Item (Join-Path $buildRoot 'SpatialAudioLab.CLI.exe') `
    (Join-Path $publishRoot 'SpatialAudioLab.CLI.exe') -Force -ErrorAction Stop
Write-Host "Built: $(Join-Path $publishRoot 'SpatialAudioLab.CLI.exe')"
