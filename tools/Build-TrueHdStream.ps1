[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$manifest = Join-Path $PSScriptRoot 'TrueHdStream\Cargo.toml'
& cargo build --manifest-path $manifest --locked --release
if ($LASTEXITCODE -ne 0) { throw 'TrueHD streaming decoder build failed.' }
$destination = Join-Path $PSScriptRoot 'truehdd'
New-Item $destination -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'TrueHdStream\target\release\truehd-stream.exe') $destination -Force
& (Join-Path $destination 'truehd-stream.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'TrueHD streaming decoder failed its version check.' }
