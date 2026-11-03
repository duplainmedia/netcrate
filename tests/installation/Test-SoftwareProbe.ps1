param([Parameter(Mandatory)][string]$FixtureExecutable)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\install\NetCrate.Preparation.psm1') -Force
$module = Get-Module NetCrate.Preparation
& $module {
    param($Fixture)
    $finished = Invoke-NetCrateSoftwareProbe -Path $Fixture -Arguments '--finish' -TimeoutMilliseconds 2000
    if ($finished.ExitCode -ne 0) { throw 'The successful software probe failed.' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try { $null = Invoke-NetCrateSoftwareProbe -Path $Fixture -Arguments '--hang' -TimeoutMilliseconds 200 }
    catch [TimeoutException] { $timedOut = $true }
    if (-not $timedOut -or $timer.Elapsed.TotalSeconds -gt 5) { throw 'The software probe did not stop at its deadline.' }
} $FixtureExecutable
Write-Output 'PASS: real software probe success and bounded process timeout.'
