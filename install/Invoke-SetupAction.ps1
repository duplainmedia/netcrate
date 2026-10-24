#requires -Version 5.1
param(
    [Parameter(Mandatory)][ValidateSet('Inspect', 'Prepare')][string]$Action,
    [Parameter(Mandatory)][string]$InputFile
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    if ((Get-Item -LiteralPath $InputFile).Length -gt 32768) { throw 'Invalid setup input.' }
    $inputState = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
    if ($inputState.Version -ne 1 -or $inputState.Role -notin @('EditingComputer', 'BackupServer')) { throw 'Invalid setup role.' }
    $stateRoot = Join-Path (Split-Path -Parent $InputFile) 'Preparation'
    Import-Module (Join-Path $PSScriptRoot 'NetCrate.Preparation.psm1') -Force
    if ($Action -eq 'Inspect') {
        $software = @(Get-NetCrateSoftware -Role $inputState.Role)
        $missing = @($software | Where-Object { -not $_.Available }).Count
        $result = [pscustomobject]@{ Succeeded = $missing -eq 0; Code = $(if ($missing) { 'software-missing' } else { 'ok' }); Message = $(if ($missing) { 'Choose Prepare this computer to install the available required software.' } else { 'Required software is available.' }); Software = $software }
        if (@($software | Where-Object Issue -EQ 'probe-timeout').Count) {
            $result.Code = 'probe-timeout'
            $result.Message = 'A software check took too long. Close other installers, then choose Try again.'
        }
    } else {
        $result = Invoke-NetCratePreparation -Role $inputState.Role -StateRoot $stateRoot -Confirm:$false
    }
    $result | ConvertTo-Json -Depth 6 -Compress
} catch {
    [pscustomobject]@{ Succeeded = $false; Code = 'preparation-failed'; Message = 'This computer could not be prepared. Restart NetCrate and choose Try again.'; Software = @() } | ConvertTo-Json -Compress
    exit 1
}
