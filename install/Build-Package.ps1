param([string]$Destination = (Join-Path $PSScriptRoot '../build/NetCrate-Windows-x64.zip'))
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))
if (-not (Test-Path -LiteralPath "$build/NetCrate.exe")) { throw 'Build the desktop application first.' }
$items = @('NetCrate.exe', 'NetCrate.exe.config', 'NetCrate.ico', 'NetCrate.png', 'THIRD-PARTY.md', 'install', 'src') | ForEach-Object { Join-Path $build $_ }
Compress-Archive -LiteralPath $items -DestinationPath $Destination -Force
Write-Output ([IO.Path]::GetFullPath($Destination))
