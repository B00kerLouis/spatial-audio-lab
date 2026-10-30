[CmdletBinding()]
param(
    [string]$DriverRoot = '',
    [string]$SymbolsRoot = '',
    [string]$Destination = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $DriverRoot) { $DriverRoot = Join-Path $repoRoot 'build-driver' }
if (-not $SymbolsRoot) { $SymbolsRoot = Join-Path $repoRoot 'driver/windows-driver-samples/audio/sysvad' }
if (-not $Destination) { $Destination = Join-Path $repoRoot 'build-submission' }
if (Test-Path $Destination) { throw "Submission stage already exists: $Destination" }
$stage = Join-Path $Destination 'VirtualSink'
New-Item $stage -ItemType Directory -Force | Out-Null
$package = Join-Path $DriverRoot 'Package'
Get-ChildItem $package -File | Where-Object { $_.Extension -in '.sys', '.dll', '.inf', '.cat' } | Copy-Item -Destination $stage
foreach ($binary in Get-ChildItem $stage -File | Where-Object { $_.Extension -in '.sys', '.dll' }) {
    $pdbName = $binary.BaseName + '.pdb'
    $symbol = Get-ChildItem $SymbolsRoot -Filter $pdbName -File -Recurse |
        Where-Object { $_.FullName -match '(?i)[\\/]x64[\\/].*Release[\\/]|[\\/]Release[\\/].*x64[\\/]' } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $symbol) { throw "Missing x64 Release symbols for $($binary.Name). Do not submit incomplete symbols." }
    Copy-Item $symbol.FullName $stage
}
$cabName = 'SpatialAudioLab-VirtualSink-x64-unsigned-submission.cab'
$ddf = @('.OPTION EXPLICIT', '.Set CabinetFileCountThreshold=0', '.Set FolderFileCountThreshold=0',
    '.Set FolderSizeThreshold=0', '.Set MaxCabinetSize=0', '.Set MaxDiskFileCount=0', '.Set MaxDiskSize=0',
    '.Set CompressionType=MSZIP', '.Set Cabinet=on', '.Set Compress=on',
    ".Set CabinetNameTemplate=$cabName", ".Set DiskDirectoryTemplate=`"$Destination`"", '.Set DestinationDir=VirtualSink')
foreach ($file in Get-ChildItem $stage -File | Sort-Object Name) { $ddf += '"' + $file.FullName + '" "' + $file.Name + '"' }
$ddfPath = Join-Path $Destination 'submission.ddf'
$ddf | Set-Content $ddfPath -Encoding ascii
& makecab.exe /F $ddfPath
if ($LASTEXITCODE -ne 0) { throw 'Creating the Microsoft signing submission CAB failed.' }
$cab = Join-Path $Destination $cabName
if (-not (Test-Path $cab)) { throw 'Submission CAB was not created.' }
$manifest = [ordered]@{
    commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    signingStatus = 'UnsignedSubmissionCab-TestSignedPayload-NotMicrosoftSigned'
    files = @(Get-ChildItem $stage -File | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Destination 'submission-manifest.json') -Encoding utf8
Copy-Item (Join-Path $repoRoot 'docs/DRIVER-SIGNING.md') (Join-Path $Destination 'README.md')
$cabHash = (Get-FileHash $cab -Algorithm SHA256).Hash.ToLowerInvariant()
"$cabHash  $cabName" | Set-Content "$cab.sha256" -Encoding ascii
Write-Host "Prepared unsigned submission CAB (not a Microsoft-signed installable release): $cab"
