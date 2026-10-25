$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\src\shared\NetCrate.Configuration.psm1" -Force
Import-Module "$PSScriptRoot\..\..\src\shared\NetCrate.Protocol.psm1" -Force
$script:assertions = 0
function Assert($Value, $Message) { if (-not $Value) { throw $Message }; $script:assertions++ }
function Reject([scriptblock]$Action) { $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Assert $rejected 'An invalid protocol record was accepted.' }
$project = '/F/Video Projects/Project & One'
$snapshot = 'a' * 64
$recipe = (Get-NetCrateRecipe 'half-prores-v2').FingerprintRecipe
$id = Get-NetCrateRequestId -SnapshotId $snapshot -ProjectPath $project -Recipe $recipe
Assert ($id -cmatch '^[a-f0-9]{64}$') 'Request identity is invalid.'
Assert ($id -cne (Get-NetCrateRequestId $snapshot $project (Get-NetCrateRecipe 'quarter-prores-v1').FingerprintRecipe)) 'A recipe change reused the original request.'
$nodes = @(
    [pscustomobject]@{ type='file';path=($project+'/Camera/one.mov');size=100;content=@(('b'*64)) },
    [pscustomobject]@{ type='file';path=($project+'/Camera/two.mov');size=200;content=@(('c'*64)) }
)
$identity = Get-NetCrateFootageIdentity -ProjectPath $project -Nodes $nodes -Recipe $recipe
$reordered = Get-NetCrateFootageIdentity -ProjectPath $project -Nodes @($nodes[1],$nodes[0]) -Recipe $recipe
Assert ($identity.Fingerprint -ceq $reordered.Fingerprint -and $identity.Clips -eq 2 -and $identity.Bytes -eq 300) 'Node order changed footage identity.'
$nodes[1].content = @('d'*64)
Assert ($identity.Fingerprint -cne (Get-NetCrateFootageIdentity $project $nodes $recipe).Fingerprint) 'Changed footage retained identity.'
$collision = [pscustomobject]@{type='file';path=($project+'/camera/ONE.mov');size=100;content=@(('b'*64))}
Reject { Get-NetCrateFootageIdentity $project @($nodes[0],$collision) $recipe }
Reject { Get-NetCrateFootageIdentity $project @([pscustomobject]@{type='file';path=($project+'/../escape.mov');size=1;content=@(('b'*64))}) $recipe }
$settings = [pscustomobject]@{SourceComputer='EDIT-PC';WorkerComputer='BACKUP-PC';ActiveRoot='F:\Video Projects';SnapshotRoot='/F/Video Projects';Repositories=@{Primary=@{Uri='rest:https://backup.example:8200/editing/originals/'}}}
$request = [pscustomobject][ordered]@{Version=2;Kind='request';SourceComputer='EDIT-PC';Repository=$settings.Repositories.Primary.Uri;BackupExitCode=0;SnapshotId=$snapshot;ProjectPath=$project;CompletedUtc=[DateTime]::UtcNow.ToString('o');Recipe=$recipe;FootageFingerprint=$identity.Fingerprint}
$null = Test-NetCrateRequest -Request $request -RequestId $id -Settings $settings
$request.BackupExitCode = 3
Reject { Test-NetCrateRequest $request $id $settings }
$request.BackupExitCode = 0
$association = New-NetCrateAssociation -Request $request -Settings $settings -GenerationSnapshotId ('e'*64) -ResultSnapshotId ('f'*64) -CompletionSHA256 ('1'*64) -ResultManifestSHA256 ('2'*64)
$null = Test-NetCrateAssociation -Association $association -Request $request -Settings $settings
Assert ($association.RequestedSnapshotId -ceq $snapshot -and $association.GenerationSnapshotId -ceq ('e'*64)) 'Reused generation lost its original snapshot identity.'
$association.WorkerComputer = 'OTHER-PC'
Reject { Test-NetCrateAssociation $association $request $settings }
$request.PSObject.Properties.Remove('FootageFingerprint')
Reject { Test-NetCrateRequest $request $id $settings }
Write-Output "PASS: $script:assertions shared protocol assertions."
