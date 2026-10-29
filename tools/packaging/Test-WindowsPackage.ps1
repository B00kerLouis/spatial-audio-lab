[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$required = @('SpatialAudioLab.Studio.exe', 'SpatialAudioLab.Cinema.exe', 'coreclr.dll',
    'Engine\SpatialAudioLab.CLI.exe', 'Tools\truehdd\truehd-stream.exe',
    'Tools\mpv\mpv.exe', 'Tools\ffmpeg\bin\ffprobe.exe', 'Tools\ffmpeg\bin\ffmpeg.exe',
    'Driver\Package\TabletAudioSample.sys', 'Driver\Package\ComponentizedAudioSample.inf',
    'Driver\Package\sysvad.cat', 'Driver\devcon.exe', 'Driver\SpatialAudioLab-Test.cer',
    'portable.flag', 'build-manifest.json', 'README.txt')
foreach ($file in $required) {
    if (-not (Test-Path (Join-Path $PackageRoot $file) -PathType Leaf)) { throw "Package is missing $file" }
}
if (Get-ChildItem $PackageRoot -Recurse -Include '*.pfx', '*.pvk') { throw 'Package contains private keys.' }
# Run from a clean directory outside the checkout; no developer runtime layout is used.
$smoke = Join-Path ([IO.Path]::GetTempPath()) "sal-package-$([guid]::NewGuid().ToString('N'))"
Copy-Item $PackageRoot $smoke -Recurse
try {
    & (Join-Path $smoke 'Tools\truehdd\truehd-stream.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'TrueHD helper did not launch.' }
    & (Join-Path $smoke 'Tools\mpv\mpv.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'mpv did not launch.' }
    & (Join-Path $smoke 'Tools\ffmpeg\bin\ffprobe.exe') -version
    if ($LASTEXITCODE -ne 0) { throw 'ffprobe did not launch.' }
    & (Join-Path $smoke 'Engine\SpatialAudioLab.CLI.exe') list-asio-json
    if ($LASTEXITCODE -ne 0) { throw 'ASIO-enabled CLI did not launch.' }
    & (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') --help
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained Cinema did not launch.' }
    $fixture = Join-Path $repoRoot 'third_party\truehdd-src\truehd\tests\assets\fba_atmos_obj.mlp'
    $media = Join-Path $smoke 'atmos-smoke.mka'
    & (Join-Path $smoke 'Tools\ffmpeg\bin\ffmpeg.exe') -v error -y -f truehd -i $fixture -c:a copy -strict -2 $media
    if ($LASTEXITCODE -ne 0) { throw 'Creating the TrueHD container smoke input failed.' }
    & (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') inspect $media
    if ($LASTEXITCODE -ne 0) { throw 'Cinema did not recognize the real Atmos stream.' }
    & (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') decode-test $media
    if ($LASTEXITCODE -ne 0) { throw 'The packaged TrueHD-to-Cinema rendering path failed.' }
    $studio = Start-Process (Join-Path $smoke 'SpatialAudioLab.Studio.exe') -PassThru
    try {
        Start-Sleep -Seconds 5
        $studio.Refresh()
        if ($studio.HasExited -or $studio.MainWindowTitle -notlike '*SpatialAudioLab Studio*') {
            throw 'Self-contained Studio failed to create its main window.'
        }
        foreach ($directory in 'Profiles', 'Logs', 'Cache') {
            if (-not (Test-Path (Join-Path $smoke "Data\$directory"))) { throw "Portable data directory was not created: $directory" }
        }
        Write-Host "Studio smoke window: $($studio.MainWindowTitle)"
    } finally {
        if (-not $studio.HasExited) { $studio.Kill(); $studio.WaitForExit() }
    }
    Write-Host 'Complete Windows package smoke test passed, including actual TrueHD object rendering.'
} finally { Remove-Item $smoke -Recurse -Force }
