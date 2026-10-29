[CmdletBinding()]
param([string]$InputFile = '', [ValidateRange(0,1)][double]$Gain = 1, [ValidateRange(-5000,5000)][double]$AvDelayMilliseconds = 0)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$cinema = Join-Path $repoRoot 'build\SpatialAudioLab\SpatialAudioLab.Cinema.exe'
if (-not (Test-Path $cinema)) { throw "找不到影院程序：$cinema。请先构建或下载完整 Windows 包。" }
$start = @{ FilePath = $cinema }
if ($InputFile) { $start.ArgumentList = @(('"' + [IO.Path]::GetFullPath($InputFile) + '"'), '--gain', $Gain.ToString([Globalization.CultureInfo]::InvariantCulture), '--av-delay-ms', $AvDelayMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)) }
Start-Process @start
