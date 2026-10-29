[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator and run this script again.'
}
& (Join-Path $PSScriptRoot 'devcon.exe') remove 'Root\sysvad_ComponentizedAudioSample'
if ($LASTEXITCODE -notin 0, 1) { throw "Device removal failed: $LASTEXITCODE" }
Get-WindowsDriver -Online | Where-Object {
    (Split-Path $_.OriginalFileName -Leaf) -in 'ComponentizedAudioSample.inf', 'ComponentizedAudioSampleExtension.inf', 'ComponentizedApoSample.inf'
} | ForEach-Object {
    & pnputil.exe /delete-driver $_.Driver /uninstall /force
    if ($LASTEXITCODE -notin 0, 3010) { throw "Driver package removal failed: $($_.Driver)" }
}
$cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $PSScriptRoot 'SpatialAudioLab-Test.cer'))
foreach ($store in 'Root', 'TrustedPublisher') {
    $path = "Cert:\LocalMachine\$store\$($cert.Thumbprint)"
    if (Test-Path $path) { Remove-Item $path }
}
