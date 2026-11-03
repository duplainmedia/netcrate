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
$module=Get-Module NetCrate.Dependencies
& $module {
 param($fixture)
 # Downloads and extraction are covered above. Substitute only those external boundaries;
 # run the real selection and Python post-extraction setup below.
 $download=(Get-Command Get-NetCratePackageArchive).ScriptBlock; $expand=(Get-Command Expand-NetCrateDependency).ScriptBlock
 try {
  function script:Get-NetCratePackageArchive { param($Package,$CacheRoot) if($Package.Name -in @('FFmpeg','Pillow')){throw 'Folder preparation attempted to acquire video software.'};return 'fixture.zip' }
  function script:Expand-NetCrateDependency { param($Archive,$Package,$ToolsRoot) $path=[IO.Path]::Combine($ToolsRoot,$Package.Name);$null=[IO.Directory]::CreateDirectory($path);return $path }
  $tools=Install-NetCrateTools Worker $fixture -BackupMode Folder
  if($tools.PSObject.Properties.Name -contains 'FFmpeg' -or $tools.PSObject.Properties.Name -contains 'FFprobe' -or $tools.PSObject.Properties.Name -contains 'Pillow'){throw 'Folder preparation retained media tools.'}
  if(-not $tools.Python -or -not $tools.Bcrypt -or -not $tools.RestServer){throw 'Transport prerequisites were omitted.'}
  $pth=[IO.Path]::Combine([IO.Path]::GetDirectoryName($tools.Python),'Lib','site-packages','netcrate.pth')
  if([IO.File]::ReadAllLines($pth).Count -ne 1 -or [IO.File]::ReadAllText($pth).Trim() -cne $tools.Bcrypt){throw 'Folder Python setup still depends on Pillow.'}
 } finally { Set-Item Function:script:Get-NetCratePackageArchive $download;Set-Item Function:script:Expand-NetCrateDependency $expand }
} (Join-Path $TestRoot 'FolderTools')
Write-Output 'PASS: actual Folder worker tool selection and Python transport-only post-extraction setup.'
