#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$failures=New-Object 'Collections.Generic.List[string]'
function Check([string]$Name,[scriptblock]$Body) {
    try { & $Body; Write-Output ('PASS '+$Name) } catch { $failures.Add($Name+': '+$_.Exception.Message); Write-Output ('FAIL '+$Name+': '+$_.Exception.Message) }
}
function Assert([bool]$Condition,[string]$Message) {if(-not $Condition){throw $Message}}
$helper=Join-Path $PSScriptRoot 'OfficeMedia.Common.ps1'
if(Test-Path -LiteralPath $helper){. $helper}
$fixture=Join-Path $env:TEMP ('OfficeMediaTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    Check 'Restic resolves without a PATH alias' {
        $exe=Join-Path $fixture 'restic.exe'; [IO.File]::WriteAllBytes($exe,[byte[]]@(77,90))
        $path=Resolve-OfficeResticExecutable -PreferredPath $exe
        Assert ($path -eq $exe) 'Explicit existing executable was not used.'
    }
    Check 'Missing explicit Restic binary is rejected' {
        $rejected=$false
        try {$null=Resolve-OfficeResticExecutable -PreferredPath (Join-Path $fixture 'missing.exe')} catch {$rejected=$true}
        Assert $rejected 'Missing explicit executable was accepted.'
    }
    $root=Join-Path $fixture 'results';New-Item -ItemType Directory -Path $root | Out-Null
    $old='a'*64;$new='b'*64;$job='shadow-lawn';$base=Join-Path $root $job
    Check 'First publication uses the job folder' {
        Assert ((Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId $job -SnapshotId $old) -eq $base) 'Unexpected first destination.'
    }
    New-Item -ItemType Directory -Path $base | Out-Null
    @{ResultSnapshot=$old}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $base 'DELIVERY.json')
    'existing media'|Set-Content -LiteralPath (Join-Path $base 'keep.txt')
    Check 'Republished snapshot cannot reuse older delivered media' {
        $destination=Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId $job -SnapshotId $new
        Assert ($destination -ne $base) 'New snapshot reused the old result directory.'
        Assert (-not(Test-Path -LiteralPath $destination)) 'New publication destination unexpectedly exists.'
        Assert ((Get-Content -LiteralPath (Join-Path $base 'keep.txt')) -eq 'existing media') 'Existing delivery was altered.'
    }
    Check 'Same snapshot resumes a promoted delivery without replacement' {
        Assert ((Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId $job -SnapshotId $old) -eq $base) 'Same snapshot did not resume its directory.'
    }
    Check 'Job path traversal is rejected' {
        $rejected=$false
        try {$null=Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId '..\escape' -SnapshotId $new} catch {$rejected=$true}
        Assert $rejected 'Job path traversal was accepted.'
    }
    Check 'Unidentified existing delivery is preserved and rejected' {
        $unknown=Join-Path $root 'unknown';New-Item -ItemType Directory -Path $unknown | Out-Null
        $rejected=$false
        try {$null=Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId 'unknown' -SnapshotId $new} catch {$rejected=$true}
        Assert $rejected 'Existing unidentified directory was accepted.'
        Assert (Test-Path -LiteralPath $unknown) 'Unknown directory was removed.'
    }
    Check 'Versioned directory cannot impersonate another snapshot' {
        $version=Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId $job -SnapshotId $new
        New-Item -ItemType Directory -Path $version | Out-Null
        @{ResultSnapshot=$old}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $version 'DELIVERY.json')
        $rejected=$false
        try {$null=Resolve-OfficeDeliveryDestination -OutputRoot $root -JobId $job -SnapshotId $new} catch {$rejected=$true}
        Assert $rejected 'Wrong snapshot marker was accepted in the new version directory.'
    }
} finally {
    $resolved=(Resolve-Path -LiteralPath $fixture).ProviderPath
    $temporary=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^OfficeMediaTests-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($failures.Count){throw ($failures -join "`n")}
Write-Output 'All receiver regression checks passed.'
