param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\install\NetCrate.Dependencies.psm1" -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
$source = Join-Path $TestRoot 'Source'; New-Item -ItemType Directory -Path $source -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $source 'tool.txt'), 'synthetic tool')
$zip = Join-Path $TestRoot 'valid.zip'; [IO.Compression.ZipFile]::CreateFromDirectory($source, $zip)
$hash = (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
$package = [pscustomobject]@{Name='Fixture';Version='1.0';SHA256=$hash;Executable='tool.txt'}
$destination = Expand-NetCrateDependency -Archive $zip -Package $package -ToolsRoot (Join-Path $TestRoot 'Tools')
if (-not (Test-Path -LiteralPath (Join-Path $destination 'tool.txt'))) { throw 'The verified archive was not installed.' }
$again = Expand-NetCrateDependency -Archive $zip -Package $package -ToolsRoot (Join-Path $TestRoot 'Tools')
if ($again -cne $destination) { throw 'Retry changed the installed package path.' }
function Reject([scriptblock]$Action) { $rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'An unsafe dependency was accepted.'} }
[IO.File]::WriteAllText((Join-Path $destination 'tool.txt'), 'damaged tool')
$repaired = Expand-NetCrateDependency -Archive $zip -Package $package -ToolsRoot (Join-Path $TestRoot 'Tools')
if ([IO.File]::ReadAllText((Join-Path $repaired 'tool.txt')) -cne 'synthetic tool') { throw 'The owned damaged package was not repaired.' }
if (@(Get-ChildItem -LiteralPath (Split-Path $destination) -Directory -Filter '*.damaged-*').Count -ne 1) { throw 'Repair did not preserve the damaged package.' }
$package.SHA256 = '0' * 64
Reject { Expand-NetCrateDependency -Archive $zip -Package $package -ToolsRoot (Join-Path $TestRoot 'Other') }
$badZip = Join-Path $TestRoot 'traversal.zip'; $archive=[IO.Compression.ZipFile]::Open($badZip,'Create')
try { $entry=$archive.CreateEntry('../escaped.txt');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('synthetic')}finally{$writer.Dispose()} }finally{$archive.Dispose()}
$package.SHA256 = (Get-FileHash -LiteralPath $badZip).Hash.ToLowerInvariant()
Reject { Expand-NetCrateDependency -Archive $badZip -Package $package -ToolsRoot (Join-Path $TestRoot 'Traversal') }
if (Test-Path -LiteralPath (Join-Path $TestRoot 'escaped.txt')) { throw 'Archive traversal wrote outside its target.' }
Write-Output 'PASS: dependency integrity, bounded archive paths and idempotent installation.'
