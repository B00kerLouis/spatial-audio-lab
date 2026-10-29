[CmdletBinding()]
param([string]$InputFile = '')
$ErrorActionPreference = 'Stop'
if (-not $InputFile) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = 'Matroska movies (*.mkv;*.mka)|*.mkv;*.mka|All files|*.*'
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $InputFile = $dialog.FileName
    $dialog.Dispose()
}
& (Join-Path $PSScriptRoot 'SpatialAudioLab.Cinema.exe') play ([IO.Path]::GetFullPath($InputFile))
if ($LASTEXITCODE -ne 0) { throw "Cinema exited with code $LASTEXITCODE" }
