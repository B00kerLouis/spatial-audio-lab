[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$required = @('SpatialAudioLab.Studio.exe', 'SpatialAudioLab.Cinema.exe', 'SpatialAudioLab.Cinema.Engine.exe', 'default.ini', 'coreclr.dll',
    'Engine\SpatialAudioLab.CLI.exe', 'Tools\truehdd\truehd-stream.exe',
    'Tools\mpv\mpv.exe', 'Tools\ffmpeg\bin\ffprobe.exe', 'Tools\ffmpeg\bin\ffmpeg.exe',
    'Driver\Package\TabletAudioSample.sys', 'Driver\Package\ComponentizedAudioSample.inf',
    'Driver\Package\sysvad.cat', 'Driver\devcon.exe', 'Driver\SpatialAudioLab-Test.cer',
    'portable.flag', 'build-manifest.json', 'README.txt')
foreach ($file in $required) {
    if (-not (Test-Path (Join-Path $PackageRoot $file) -PathType Leaf)) { throw "Package is missing $file" }
}
foreach ($assembly in 'WindowsBase.dll', 'System.Drawing.dll', 'Microsoft.VisualBasic.dll') {
    $desktop = Join-Path $repoRoot "build-publish\SpeakerLayoutEditor\$assembly"
    $packaged = Join-Path $PackageRoot $assembly
    if ((Get-FileHash $desktop -Algorithm SHA256).Hash -ne (Get-FileHash $packaged -Algorithm SHA256).Hash) {
        throw "The WPF implementation was replaced by a Core runtime facade: $assembly"
    }
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
    $help = @(& (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') --help)
    $help | Write-Host
    if ($LASTEXITCODE -ne 0 -or ($help -join "`n") -notmatch 'inspect') { throw 'Cinema command forwarding lost its help output.' }
    $fixture = Join-Path $repoRoot 'third_party\truehdd-src\truehd\tests\assets\fba_atmos_obj.mlp'
    $media = Join-Path $smoke 'atmos-smoke.mka'
    & (Join-Path $smoke 'Tools\ffmpeg\bin\ffmpeg.exe') -v error -y -f truehd -i $fixture -c:a copy -strict -2 $media
    if ($LASTEXITCODE -ne 0) { throw 'Creating the TrueHD container smoke input failed.' }
    $inspection = @(& (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') inspect $media)
    $inspection | Write-Host
    if ($LASTEXITCODE -ne 0 -or ($inspection -join "`n") -notmatch 'TrueHdAtmos') { throw 'Cinema did not forward the real Atmos inspection output.' }
    $decoded = @(& (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') decode-test $media)
    $decoded | Write-Host
    if ($LASTEXITCODE -ne 0 -or ($decoded -join "`n") -notmatch 'TrueHdAtmos') { throw 'The packaged TrueHD-to-Cinema rendering output was lost.' }
    $launchedAt = Get-Date
    $stdout = Join-Path $smoke 'studio.stdout.txt'
    $stderr = Join-Path $smoke 'studio.stderr.txt'
    $studio = Start-Process (Join-Path $smoke 'SpatialAudioLab.Studio.exe') -PassThru `
        -WorkingDirectory $smoke -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try {
        $deadline = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Seconds 1
            $studio.Refresh()
        } while (-not $studio.HasExited -and $studio.MainWindowTitle -notlike '*SpatialAudioLab Studio*' -and (Get-Date) -lt $deadline)
        if ($studio.HasExited -or $studio.MainWindowTitle -notlike '*SpatialAudioLab Studio*') {
            Write-Host "Studio PID=$($studio.Id), exited=$($studio.HasExited), title=$($studio.MainWindowTitle)"
            if ($studio.HasExited) { Write-Host "Studio exit code=$($studio.ExitCode)" }
            Get-Content $stdout, $stderr -ErrorAction SilentlyContinue | Write-Host
            Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $launchedAt } -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -in '.NET Runtime', 'Application Error', 'Windows Error Reporting' } |
                Select-Object -First 8 | ForEach-Object { Write-Host $_.Message }
            throw 'Self-contained Studio failed to create its main window within 30 seconds.'
        }
        foreach ($directory in 'Profiles', 'Logs', 'Cache') {
            if (-not (Test-Path (Join-Path $smoke "Data\$directory"))) { throw "Portable data directory was not created: $directory" }
        }
        Write-Host "Studio smoke window: $($studio.MainWindowTitle)"
    } finally {
        if (-not $studio.HasExited) { $studio.Kill(); $studio.WaitForExit() }
    }
    $cinema = Start-Process (Join-Path $smoke 'SpatialAudioLab.Cinema.exe') -PassThru -WorkingDirectory $smoke
    try {
        $deadline = (Get-Date).AddSeconds(30)
        do { Start-Sleep -Seconds 1; $cinema.Refresh() }
        while (-not $cinema.HasExited -and $cinema.MainWindowTitle -notlike '*Cinema*影院*' -and (Get-Date) -lt $deadline)
        if ($cinema.HasExited -or $cinema.MainWindowTitle -notlike '*Cinema*影院*') { throw 'Cinema graphical launcher did not open.' }
        Write-Host "Cinema GUI smoke window: $($cinema.MainWindowTitle)"
    } finally { if (-not $cinema.HasExited) { $cinema.Kill($true); $cinema.WaitForExit() } }
    & python (Join-Path $PSScriptRoot 'Test-PcmInput.py') --engine (Join-Path $smoke 'Engine\SpatialAudioLab.CLI.exe') --profile (Join-Path $smoke 'default.ini')
    if ($LASTEXITCODE -ne 0) { throw 'Direct Cinema PCM pipe mapping test failed.' }
    Write-Host 'Complete Windows package smoke test passed, including actual TrueHD object rendering.'
} finally { Remove-Item $smoke -Recurse -Force }
