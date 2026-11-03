#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectName,[Parameter(Mandatory)][string]$ProjectPath,[string]$Snapshot)
$ErrorActionPreference='Stop'
if([Security.Principal.WindowsIdentity]::GetCurrent().Name -ine 'WORKER-PC\worker-user'){throw 'Submit media requests under WORKER-PC\worker-user.'}
$root="C:\ProgramData\NetCrate\Office"
$restore=Join-Path $PSScriptRoot 'Restore-LocalProject.ps1'
$tools=Get-Content -LiteralPath "$root\tools.json" -Raw|ConvertFrom-Json
$projects=@(& $restore -Action List)
$candidates=@($projects|Where-Object{$_.ProjectPath -ceq $ProjectPath})
if($Snapshot){$candidates=@($candidates|Where-Object{$_.Snapshot.StartsWith($Snapshot,[StringComparison]::OrdinalIgnoreCase)})}
if(-not $candidates.Count){throw 'No backed-up project matches that exact path/snapshot.'}
$selected=$candidates|Sort-Object Time -Descending|Select-Object -First 1
$slug=($ProjectName.ToLowerInvariant()-replace '[^a-z0-9]+','-').Trim('-')
if(-not $slug){throw 'Project needs a usable name.'}
$slug=$slug.Substring(0,[Math]::Min(55,$slug.Length))
$pathHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ProjectPath))).Substring(0,10).ToLowerInvariant()
$jobId=$slug+'-'+$selected.Snapshot.Substring(0,12)+'-'+$pathHash+'-hprores-v2'
$jobRoot=Join-Path "$root\Jobs" $jobId
$queuePath=Join-Path "$root\Queue" ($jobId+'.json')
if(Test-Path -LiteralPath $queuePath){'Job already queued: '+$jobId;return}
New-Item -ItemType Directory -Path $jobRoot -Force|Out-Null
$originals=Join-Path $jobRoot 'originals'
$receiptPath=$originals+'.verification\verified.json'
if(-not(Test-Path -LiteralPath $receiptPath)){
    if(Test-Path -LiteralPath $originals){throw 'An incomplete restore is preserved here; inspect it before retrying.'}
    if(([IO.DriveInfo]::new('C:\')).AvailableFreeSpace -lt ([long]$selected.SnapshotBytes*3+50000000000)){throw 'Insufficient reserved office SSD space for originals and generated results.'}
    & $restore -Action Restore -Snapshot $selected.Snapshot -ProjectPath $ProjectPath -Destination $originals
}
$receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
if(-not $receipt.ResticContentVerification -or $receipt.SnapshotId -ne $selected.Snapshot -or $receipt.ProjectPath -ne $ProjectPath){throw 'Restore receipt does not match this request.'}
@{SnapshotId=$receipt.SnapshotId;SnapshotPath=$receipt.ProjectPath;RestoreDirectory=$originals;Files=$receipt.Files;Bytes=$receipt.Bytes;ResticVerifyPassed=$true}|ConvertTo-Json|Set-Content -LiteralPath "$jobRoot\restore-verification.json"
& $tools.Python "$($tools.Scripts)\inspect_media.py" --job-root $jobRoot
if($LASTEXITCODE -ne 0){throw 'Media inspection failed; job was not queued.'}
$request=[ordered]@{JobId=$jobId;ProjectName=$ProjectName;SnapshotId=$selected.Snapshot;SnapshotPath=$ProjectPath;ProxyRecipe='half-prores-v2';ProxyScaleDivisor=2;ProxyBitDepth=10;InventoryPath="$jobRoot\media-inventory.json";RestoreReport="$jobRoot\restore-verification.json";OutputPath="$jobRoot\Output";State='Queued';RequestedUtc=[DateTime]::UtcNow.ToString('o')}
$temporary=$queuePath+'.writing';$request|ConvertTo-Json|Set-Content -LiteralPath $temporary;Move-Item -LiteralPath $temporary -Destination $queuePath
'Queued '+$jobId+'. The worker generates/validates all videos, publishes encrypted results, and the source receiver downloads them automatically.'
