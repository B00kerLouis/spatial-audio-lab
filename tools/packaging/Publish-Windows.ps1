[CmdletBinding()]
param([string]$Destination = '')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Destination) { $Destination = Join-Path $repoRoot 'build-package\SpatialAudioLab-ASIO-win-x64' }
if (Test-Path $Destination) { throw "Package stage already exists: $Destination" }
New-Item $Destination -ItemType Directory -Force | Out-Null
# Desktop implementations (notably WindowsBase) must replace Core runtime facades.
foreach ($project in 'DolbyPlayer', 'CinemaLauncher', 'SpeakerLayoutEditor') {
    $published = Join-Path $repoRoot "build-publish\$project"
    & dotnet publish (Join-Path $repoRoot "tools\$project") -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=false -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -o $published
    if ($LASTEXITCODE -ne 0) { throw "Publication failed: $project" }
    Copy-Item (Join-Path $published '*') $Destination -Recurse -Force
    $runtimeNotices = Join-Path $Destination "Licenses\DotNet-$project"
    New-Item $runtimeNotices -ItemType Directory -Force | Out-Null
    Get-ChildItem $published -File | Where-Object { $_.Name -match '^(?i:license|thirdpartynotices)' } |
        Copy-Item -Destination $runtimeNotices
}
$engine = Join-Path $Destination 'Engine'
$decoder = Join-Path $Destination 'Tools\truehdd'
$licenses = Join-Path $Destination 'Licenses'
$examples = Join-Path $Destination 'Examples'
$tools = Join-Path $Destination 'Tools'
New-Item $engine, $decoder, $licenses, $examples -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $repoRoot 'build-windows\SpatialAudioLab.CLI.exe') $engine
Copy-Item (Join-Path $repoRoot 'tools\truehdd\truehd-stream.exe') $decoder
Copy-Item (Join-Path $repoRoot 'build-driver') (Join-Path $Destination 'Driver') -Recurse
& (Join-Path $PSScriptRoot 'Get-RuntimeDependencies.ps1') -Destination $Destination
Copy-Item (Join-Path $repoRoot 'third_party\Cavern\LICENSE.md') (Join-Path $licenses 'Cavern-LICENSE.md')
Copy-Item (Join-Path $repoRoot 'third_party\Cavern\docs\NuGet Licence.md') (Join-Path $licenses 'Cavern-NuGet-LICENSE.md')
Copy-Item (Join-Path $repoRoot 'third_party\truehdd-src\LICENSE') (Join-Path $licenses 'TrueHD-LICENSE.txt')
Copy-Item (Join-Path $repoRoot 'tools\TrueHdStream\LICENSE') (Join-Path $licenses 'TrueHD-Stream-LICENSE.txt')
Copy-Item (Join-Path $repoRoot 'driver\windows-driver-samples\LICENSE') (Join-Path $licenses 'Microsoft-Driver-Samples-LICENSE.txt')
Copy-Item (Join-Path $repoRoot '.asio-sdk\LICENSE.txt') (Join-Path $licenses 'ASIO-SDK-LICENSE.txt')
Invoke-WebRequest 'https://raw.githubusercontent.com/naudio/NAudio/v2.2.1/license.txt' -OutFile (Join-Path $licenses 'NAudio-LICENSE.txt')
$rust = & cargo metadata --manifest-path (Join-Path $repoRoot 'tools\TrueHdStream\Cargo.toml') --locked --format-version 1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Reading Rust dependency licenses failed.' }
foreach ($crate in $rust.packages) {
    $crateRoot = Split-Path $crate.manifest_path -Parent
    $texts = @(Get-ChildItem $crateRoot -File | Where-Object { $_.Name -match '^(?i:license|copying|copyright|notice)' })
    if ($texts.Count) {
        $crateDestination = Join-Path $licenses "Rust\$($crate.name)-$($crate.version)"
        New-Item $crateDestination -ItemType Directory -Force | Out-Null
        $texts | Copy-Item -Destination $crateDestination
    }
}
foreach ($file in 'LICENSE-APACHE', 'LICENSE-MIT', 'COPYRIGHT') {
    Invoke-WebRequest "https://raw.githubusercontent.com/rust-lang/rust/1.99.0/$file" -OutFile (Join-Path $licenses "Rust-$file.txt")
}
Copy-Item (Join-Path $repoRoot 'configs\*.ini') $examples
Copy-Item (Join-Path $repoRoot 'configs\dante-714.ini') (Join-Path $Destination 'default.ini')
Copy-Item (Join-Path $repoRoot 'docs\ASIO.md') $Destination
Copy-Item (Join-Path $repoRoot 'packaging\README-WINDOWS.txt') (Join-Path $Destination 'README.txt')
Copy-Item (Join-Path $repoRoot 'packaging\Install-Driver.ps1') (Join-Path $Destination 'Driver')
Copy-Item (Join-Path $repoRoot 'packaging\Uninstall-Driver.ps1') (Join-Path $Destination 'Driver')
Copy-Item (Join-Path $repoRoot 'docs\DRIVER-SIGNING.md') (Join-Path $Destination 'Driver')
Copy-Item (Join-Path $repoRoot 'packaging\Start-Cinema.ps1') $Destination
foreach ($script in 'Set-SpatialProvider.ps1', 'Test-SpatialProvider.ps1', 'New-AsioLayout.py', 'Prepare-SpatialAudio.ps1', 'Diagnose-SpatialAudio.ps1', 'SpatialAudio.Runtime.psm1', 'Open-SpatialApp.ps1') {
    Copy-Item (Join-Path $repoRoot "tools\$script") $tools
}
# DevCon and optional APOs use the MSVC runtime. Carry the compiler's redistributable DLLs.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -property installationPath
$crt = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC') -Filter Microsoft.VC*.CRT -Directory -Recurse |
    Where-Object { $_.FullName -match '[\\/]x64[\\/]' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'MSVC redistributable runtime DLLs were not found.' }
Copy-Item (Join-Path $crt.FullName '*.dll') (Join-Path $Destination 'Driver')
Copy-Item (Join-Path $crt.FullName '*.dll') (Join-Path $Destination 'Driver\Package')
New-Item (Join-Path $Destination 'portable.flag') -ItemType File | Out-Null
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
$manifest = [ordered]@{
    commit = $commit
    platform = 'win-x64'
    selfContained = $true
    asioSdkCommit = '496a0765b8bb9c26f764f22f9a9712a937177db2'
    truehdCommit = (& git -C (Join-Path $repoRoot 'third_party\truehdd-src') rev-parse HEAD).Trim()
    cavernCommit = (& git -C (Join-Path $repoRoot 'third_party\Cavern') rev-parse HEAD).Trim()
    source = "https://github.com/B00kerLouis/spatial-audio-lab/tree/$commit"
    components = @('Studio', 'Cinema', 'CLI with ASIO/WASAPI', 'TrueHD streaming decoder', 'Virtual Sink test driver', 'mpv', 'FFmpeg')
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Destination 'build-manifest.json') -Encoding utf8NoBOM
Get-ChildItem $Destination -Recurse -Filter '*.pdb' | Remove-Item
if (Get-ChildItem $Destination -Recurse -Include '*.pfx', '*.pvk') { throw 'Private keys must never be distributed.' }
Write-Host "Published complete Windows package: $Destination"
