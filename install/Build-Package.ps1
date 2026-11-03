param([string]$Destination)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Version.psm1') -Force
$version = Get-NetCrateVersion $repo
$build = Join-Path $repo 'build'
$exe = Join-Path $build 'NetCrate.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Build the desktop application first.' }
Assert-NetCrateExecutable $exe $version
foreach ($document in @('VERSION', 'CHANGELOG.md')) { Copy-Item -LiteralPath (Join-Path $repo $document) -Destination $build -Force }
$items = @('NetCrate.exe', 'NetCrate.exe.config', 'NetCrate.ico', 'NetCrate.png', 'THIRD-PARTY.md', 'VERSION', 'CHANGELOG.md', 'install', 'src') | ForEach-Object { Join-Path $build $_ }
$aliasPath = $null
if (-not $Destination) { $Destination = Join-Path $build "NetCrate-$($version.Product)-Windows-x64.zip"; $aliasPath = Join-Path $build 'NetCrate-Windows-x64.zip' }
Compress-Archive -LiteralPath $items -DestinationPath $Destination -Force
if ($aliasPath) { Copy-Item -LiteralPath $Destination -Destination $aliasPath -Force }
Write-Output ([IO.Path]::GetFullPath($Destination))
