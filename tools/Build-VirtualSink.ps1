[CmdletBinding()]
param([string]$Destination = '')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $Destination) { $Destination = Join-Path $repoRoot 'build-driver' }
$sampleRoot = Join-Path $repoRoot 'driver\windows-driver-samples'
& git -C $sampleRoot submodule update --init --depth 1 wil
if ($LASTEXITCODE -ne 0) { throw 'WIL checkout failed.' }
& (Join-Path $PSScriptRoot 'Initialize-SpatialAudioLab.ps1') -Component Driver
# Restore only the x64 packages referenced by this pinned sample revision.
[xml]$packages = Get-Content (Join-Path $sampleRoot 'packages.config')
@($packages.packages.package) | Where-Object { $_.id -match '(?i)arm64' } |
    ForEach-Object { [void]$packages.packages.RemoveChild($_) }
$restoreRoot = Join-Path $repoRoot 'build-driver-restore'
New-Item $restoreRoot -ItemType Directory -Force | Out-Null
$restoreFile = Join-Path $restoreRoot 'packages.config'
$packages.Save($restoreFile)
& nuget restore $restoreFile -PackagesDirectory (Join-Path $sampleRoot 'packages') -NonInteractive
if ($LASTEXITCODE -ne 0) { throw 'WDK NuGet restore failed.' }
$sysvad = Join-Path $sampleRoot 'audio\sysvad'
$buildOptions = @('/m:1', '/t:Build', '/p:Configuration=Release', '/p:Platform=x64',
    '/p:SpectreMitigation=false', '/p:SignMode=Off', '/p:PreferredToolArchitecture=x64', '/v:minimal')
& msbuild (Join-Path $sysvad 'EndpointsCommon\EndpointsCommon.vcxproj') @buildOptions
if ($LASTEXITCODE -ne 0) { throw 'Virtual Sink common library build failed.' }
& msbuild (Join-Path $sysvad 'Package\package.vcxproj') @buildOptions
if ($LASTEXITCODE -ne 0) { throw 'Virtual Sink package build failed.' }
& msbuild (Join-Path $sampleRoot 'setup\devcon\devcon.vcxproj') @buildOptions
if ($LASTEXITCODE -ne 0) { throw 'DevCon build failed.' }
Write-Host 'Locating Virtual Sink package and signing tools...'
$driver = Get-ChildItem $sysvad -Filter TabletAudioSample.sys -Recurse |
    Where-Object { $_.FullName -match '(?i)[\\/]package[\\/]' } | Select-Object -First 1
if (-not $driver) { throw 'The driver package was not produced.' }
$packageRoot = $driver.Directory.FullName
$kit = Join-Path $sampleRoot 'packages\Microsoft.Windows.WDK.x64.10.0.28000.1839'
$signtool = Get-ChildItem (Join-Path $sampleRoot 'packages') -Filter signtool.exe -Recurse |
    Where-Object { $_.FullName -match '(?i)[\\/]x64[\\/]' } | Select-Object -First 1
$inf2cat = Get-ChildItem $kit -Filter inf2cat.exe -Recurse | Select-Object -First 1
$devcon = Get-ChildItem (Join-Path $sampleRoot 'setup\devcon') -Filter devcon.exe -Recurse |
    Where-Object { $_.FullName -match '(?i)[\\/]x64[\\/]Release[\\/]' } | Select-Object -First 1
if (-not $signtool -or -not $inf2cat -or -not $devcon) { throw 'Signing tools or the compiled DevCon are missing.' }
Write-Host 'Creating the nonexportable CI test-signing certificate...'
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=B00kerLouis SpatialAudioLab Test Driver' `
    -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy NonExportable -HashAlgorithm SHA256
New-Item $Destination -ItemType Directory -Force | Out-Null
$certificatePath = Join-Path $Destination 'SpatialAudioLab-Test.cer'
Export-Certificate -Cert $cert -FilePath $certificatePath | Out-Null
# The machine store avoids the interactive per-user Root trust warning in CI.
& certutil.exe -f -silent -addstore Root $certificatePath
if ($LASTEXITCODE -ne 0) { throw 'Trusting the temporary CI signing certificate failed.' }
Write-Host 'Signing driver binaries...'
foreach ($binary in Get-ChildItem $packageRoot -File | Where-Object { $_.Extension -in '.sys', '.dll' }) {
    & $signtool.FullName sign /s My /sha1 $cert.Thumbprint /fd SHA256 $binary.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $($binary.Name)" }
}
& $inf2cat.FullName "/driver:$packageRoot" /os:10_X64 /uselocaltime
if ($LASTEXITCODE -ne 0) { throw 'Virtual Sink catalog generation failed.' }
foreach ($catalog in Get-ChildItem $packageRoot -Filter '*.cat') {
    & $signtool.FullName sign /s My /sha1 $cert.Thumbprint /fd SHA256 $catalog.FullName
    if ($LASTEXITCODE -ne 0) { throw "Catalog signing failed: $($catalog.Name)" }
    & $signtool.FullName verify /pa $catalog.FullName
    if ($LASTEXITCODE -ne 0) { throw "Catalog signature verification failed: $($catalog.Name)" }
}
$destinationPackage = Join-Path $Destination 'Package'
New-Item $destinationPackage -ItemType Directory -Force | Out-Null
Get-ChildItem $packageRoot -File | Where-Object { $_.Extension -in '.sys', '.dll', '.inf', '.cat' } |
    Copy-Item -Destination $destinationPackage -Force
Copy-Item $devcon.FullName (Join-Path $Destination 'devcon.exe')
foreach ($name in 'TabletAudioSample.sys', 'KeywordDetectorContosoAdapter.dll', 'ComponentizedAudioSample.inf', 'sysvad.cat') {
    if (-not (Test-Path (Join-Path $destinationPackage $name))) { throw "Missing driver package member: $name" }
}
if (Get-ChildItem $Destination -Recurse -Include '*.pfx', '*.pvk') { throw 'Private keys must never be packaged.' }
Write-Host "Built and test-signed Virtual Sink: $Destination"
