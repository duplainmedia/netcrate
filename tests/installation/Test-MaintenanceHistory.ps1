#requires -Version 7.4
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($name in @('Configuration','Credentials','Maintenance')) { Import-Module "$repo/src/shared/NetCrate.$name.psm1" }
$full = Assert-NetCrateLocalPath $TestRoot
if (Test-Path -LiteralPath $full) { throw 'TestRoot must be a new directory.' }
if ($full -match '(?i)OneDrive' -or $full -notmatch '(?i)[\\/](temp|_temp)[\\/]') { throw 'Use a fresh ordinary Temp fixture.' }
$null = [IO.Directory]::CreateDirectory($full)
$script:assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function New-Case([string]$Name) {
    $root = Join-Path $full $Name
    $id = [guid]::NewGuid().ToString('N')
    $null = New-NetCrateIdentity $root $id Worker
    $requests = Set-NetCratePrivateDirectory (Join-Path $root 'Maintenance/Requests')
    return @{Root=$root; Id=$id; Requests=$requests}
}
function Add-Record($Case, [hashtable]$Fields, [int]$Order=0) {
    $id = [guid]::NewGuid().ToString('N')
    $record = [ordered]@{
        Version=1; InstallationId=$Case.Id; OperationId=$id
        Action='ApplyRetention'; State='NeedsAttention'
        CreatedUtc=([DateTimeOffset]'2020-01-01T00:00:00Z').AddSeconds($Order).ToString('o')
    }
    foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
    $path = Join-Path $Case.Requests ($id + '.json')
    [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    return $path
}
function Snapshot($Case) {
    $result = @{}
    foreach ($file in [IO.Directory]::EnumerateFiles($Case.Requests,'*.json')) {
        $result[$file] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($file)))
    }
    return $result
}
function Admit($Case) { Invoke-NetCrateMaintenanceRequest $Case.Root $Case.Id CheckStorage @{} }
function Assert-Preserved($Before, $After, [string[]]$Paths) {
    foreach ($path in $Paths) {
        Assert ($After.ContainsKey($path) -and $After[$path] -ceq $Before[$path]) 'Protected history was removed or changed.'
    }
}

$safeCases = @(
    @{State='NeedsAttention'},
    @{State='NeedsAttention';Step='Confirmed'},
    @{State='NeedsAttention';Step='Completed'},
    @{State='Failed'},
    @{State='Failed';Step='Confirmed'},
    @{State='Succeeded';Step='Completed'},
    @{Action='CheckStorage';State='NeedsAttention'},
    @{Action='PreviewRetention';State='Failed'}
)
for ($caseNumber=0; $caseNumber -lt $safeCases.Count; $caseNumber++) {
    $case = New-Case ('safe-' + $caseNumber)
    $oldest = ''
    for ($i=0; $i -lt 256; $i++) {
        $path = Add-Record $case $safeCases[$caseNumber] $i
        if ($i -eq 0) { $oldest = $path }
    }
    $before = Snapshot $case
    $reply = Admit $case
    $after = Snapshot $case
    Assert ($reply.State -ceq 'Queued') 'Harmless history prevented admission.'
    Assert ($after.Count -eq 256) 'History exceeded its capacity.'
    Assert (-not $after.ContainsKey($oldest)) 'The oldest safe record was not retired.'
    Assert ($after.ContainsKey((Join-Path $case.Requests ($reply.OperationId + '.json')))) 'The admitted request is missing.'
    Assert-Preserved $before $after @($before.Keys | Where-Object { $_ -cne $oldest })
}

$protectedCases = @(
    @{State='NeedsAttention';Step='ForgetStarted'},
    @{State='NeedsAttention';Step='ForgetVerified'},
    @{State='NeedsAttention';Step='PruneStarted'},
    @{State='Failed';Step='ForgetStarted'},
    @{State='Failed';Step='ForgetVerified'},
    @{State='Failed';Step='PruneStarted'},
    @{State='Succeeded';Step='ForgetStarted'},
    @{State='NeedsAttention';step='ForgetStarted'},
    @{State='NeedsAttention';Step='UnrecognizedStage'},
    @{State='NeedsAttention';Step=('Confirmed'+[char]0x00ad)},
    @{State='NeedsAttention';Step=$null},
    @{State='NeedsAttention';Step=42},
    @{State='NeedsAttention';Step=''},
    @{State='Queued'},
    @{State='Running';Step='Confirmed'},
    @{State='UnrecognizedState';Step='Confirmed'},
    @{Action='UnrecognizedAction';State='NeedsAttention'}
)
$mixed = New-Case 'mixed'
$protectedPaths = @()
foreach ($fields in $protectedCases) { $protectedPaths += Add-Record $mixed $fields -100 }
$oldestSafe = Add-Record $mixed @{State='NeedsAttention';Step='Confirmed'} 0
for ($i=$protectedPaths.Count+1; $i -lt 256; $i++) { $null = Add-Record $mixed @{Action='CheckStorage';State='Succeeded'} $i }
$before = Snapshot $mixed
$reply = Admit $mixed
$after = Snapshot $mixed
Assert ($reply.State -ceq 'Queued' -and $after.Count -eq 256) 'Mixed history did not admit a bounded request.'
Assert (-not $after.ContainsKey($oldestSafe)) 'Safe history was not selected ahead of protected journals.'
Assert-Preserved $before $after @($before.Keys | Where-Object { $_ -cne $oldestSafe })

$blocked = New-Case 'protected-only'
for ($i=0; $i -lt 256; $i++) { $null = Add-Record $blocked $protectedCases[$i % $protectedCases.Count] $i }
$before = Snapshot $blocked
$rejected = $false
try { $null = Admit $blocked } catch { $rejected = $true }
$after = Snapshot $blocked
Assert ($rejected -and $after.Count -eq 256) 'Fully protected history did not refuse admission.'
Assert-Preserved $before $after @($before.Keys)

$invalid = New-Case 'invalid-owner'
for ($i=0; $i -lt 255; $i++) { $null = Add-Record $invalid @{Action='CheckStorage';State='Succeeded'} $i }
$null = Add-Record $invalid @{InstallationId=('0'*32);State='NeedsAttention';Step='Confirmed'} 300
$before = Snapshot $invalid
$rejected = $false
try { $null = Admit $invalid } catch { $rejected = $true }
$after = Snapshot $invalid
Assert ($rejected -and $after.Count -eq 256) 'Invalid identity did not stop trimming before mutation.'
Assert-Preserved $before $after @($before.Keys)
Write-Output ('PASS: ' + $script:assertions + ' maintenance capacity, journal preservation and identity assertions.')
