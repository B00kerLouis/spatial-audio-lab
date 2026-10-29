[CmdletBinding()]
param([string]$InputFile = '')
$ErrorActionPreference = 'Stop'
$start = @{ FilePath = (Join-Path $PSScriptRoot 'SpatialAudioLab.Cinema.exe') }
if ($InputFile) { $start.ArgumentList = '"' + [IO.Path]::GetFullPath($InputFile) + '"' }
Start-Process @start
