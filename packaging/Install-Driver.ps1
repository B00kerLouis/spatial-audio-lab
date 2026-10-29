[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator and run this script again.'
}
$cert = Join-Path $PSScriptRoot 'SpatialAudioLab-Test.cer'
foreach ($store in 'Root', 'TrustedPublisher') {
    Import-Certificate -FilePath $cert -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
}
Push-Location (Join-Path $PSScriptRoot 'Package')
try {
    & (Join-Path $PSScriptRoot 'devcon.exe') install ComponentizedAudioSample.inf 'Root\sysvad_ComponentizedAudioSample'
    if ($LASTEXITCODE -notin 0, 1) { throw "Driver installation failed: $LASTEXITCODE" }
} finally { Pop-Location }
$parameters = 'HKLM:\SYSTEM\CurrentControlSet\Services\sysvad_componentizedaudiosample\Parameters'
New-Item $parameters -Force | Out-Null
New-ItemProperty $parameters -Name DoNotCreateDataFiles -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host 'Virtual Sink installed. Restart if Windows requests it. See README.txt for the test-signing boot procedure.'
