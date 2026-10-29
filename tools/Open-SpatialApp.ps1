[CmdletBinding()]
param([ValidateSet('Dolby','DtsX')][string]$App)
$pattern = if ($App -eq 'Dolby') { '(?i)Dolby.*Access' } else { '(?i)DTS.*(Sound|Unbound)' }
$package = Get-AppxPackage | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
if ($package) {
    $manifest = Get-AppxPackageManifest $package.PackageFullName
    $appId = @($manifest.Package.Applications.Application)[0].Id
    Start-Process "shell:AppsFolder\$($package.PackageFamilyName)!$appId"
} else {
    $query = if ($App -eq 'Dolby') { 'Dolby%20Access' } else { 'DTS%20Sound%20Unbound' }
    Start-Process "https://apps.microsoft.com/search?query=$query"
}
