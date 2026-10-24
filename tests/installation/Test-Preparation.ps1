param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\install\NetCrate.Preparation.psm1') -Force
function Assert($Value, $Message) { if (-not $Value) { throw $Message } }

$missing = { param($Name) return $null }
$catalog = @(Get-NetCrateSoftware -Role EditingComputer -Resolver $missing)
Assert ($catalog.Count -eq 2) 'The editing computer was asked to install worker-only software.'
Assert (@($catalog | Where-Object Available).Count -eq 0) 'Missing software was reported as available.'
$worker = @(Get-NetCrateSoftware -Role BackupServer -Resolver $missing)
Assert ($worker.Count -eq 5) 'Worker dependencies are missing from the preparation plan.'
$calls = [Collections.Generic.List[string]]::new()
$runner = { param($Package) $calls.Add($Package.Id); return 0 }.GetNewClosure()
$changed = $false
$resolver = { param($Name) if ($calls.Count -gt 0) { return [pscustomobject]@{Path='C:\Test Tools\tool.exe'; Version='test'} }; return $null }.GetNewClosure()
$plan = Invoke-NetCratePreparation -Role EditingComputer -StateRoot $TestRoot -Resolver $missing -Installer $runner -WhatIf
Assert ($calls.Count -eq 0 -and -not (Test-Path -LiteralPath $TestRoot)) 'Planning changed this computer.'
$result = Invoke-NetCratePreparation -Role EditingComputer -StateRoot $TestRoot -Resolver $resolver -Installer $runner
Assert ($result.Succeeded -and $calls.Count -eq 1) 'Preparation did not recheck software after installation.'
$prior = $calls.Count
$result = Invoke-NetCratePreparation -Role EditingComputer -StateRoot $TestRoot -Resolver $resolver -Installer $runner
Assert ($result.Succeeded -and $calls.Count -eq $prior) 'Retry reinstalled available software.'
$failed = Invoke-NetCratePreparation -Role BackupServer -StateRoot $TestRoot -Resolver $missing -Installer { param($Package) 1223 }
Assert (-not $failed.Succeeded -and $failed.Code -eq 'approval-denied') 'Declined approval was treated as success.'
$falseInstall = Invoke-NetCratePreparation -Role EditingComputer -StateRoot $TestRoot -Resolver $missing -Installer { param($Package) 0 }
Assert (-not $falseInstall.Succeeded) 'Installer exit zero bypassed a failed software recheck.'
Write-Output 'PASS: preparation planning, role dependencies, retry, approval denial and software recheck.'
