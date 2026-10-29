[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$lock = Get-Content (Join-Path $repoRoot 'packaging\runtime-dependencies.json') -Raw | ConvertFrom-Json
$cache = Join-Path $repoRoot 'build-dependencies'
New-Item $cache -ItemType Directory -Force | Out-Null
foreach ($name in 'mpv', 'ffmpeg') {
    $dependency = $lock.$name
    $archive = Join-Path $cache "$name.7z"
    if (-not (Test-Path $archive) -or (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dependency.sha256) {
        Invoke-WebRequest $dependency.url -OutFile $archive
    }
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dependency.sha256) {
        throw "SHA-256 mismatch for $name"
    }
    $extracted = Join-Path $cache $name
    New-Item $extracted -ItemType Directory -Force | Out-Null
    & 7z x -y "-o$extracted" $archive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $name" }
}
$mpv = Join-Path $Destination 'Tools\mpv'
$ffmpeg = Join-Path $Destination 'Tools\ffmpeg'
$licenses = Join-Path $Destination 'Licenses'
New-Item $mpv, $ffmpeg, $licenses -ItemType Directory -Force | Out-Null
foreach ($file in 'mpv.exe', 'mpv.com', 'd3dcompiler_43.dll') {
    Copy-Item (Join-Path $cache "mpv\$file") $mpv
}
Copy-Item (Join-Path $cache 'mpv\mpv') $mpv -Recurse -Force
$ffmpegRoot = Join-Path $cache 'ffmpeg\ffmpeg-9.0.2-essentials_build'
Copy-Item (Join-Path $ffmpegRoot 'bin') $ffmpeg -Recurse -Force
Copy-Item (Join-Path $ffmpegRoot 'LICENSE') (Join-Path $licenses 'FFmpeg-LICENSE.txt')
Copy-Item (Join-Path $ffmpegRoot 'README.txt') (Join-Path $licenses 'FFmpeg-README.txt')
foreach ($file in 'Copyright', 'LICENSE.GPL', 'LICENSE.LGPL') {
    Invoke-WebRequest "https://raw.githubusercontent.com/mpv-player/mpv/e471496c56f0f49c133bd88b50aed62b845f1909/$file" `
        -OutFile (Join-Path $licenses "mpv-$file.txt")
}
Copy-Item (Join-Path $repoRoot 'packaging\runtime-dependencies.json') $Destination
