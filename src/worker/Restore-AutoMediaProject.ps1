#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
param([Parameter(Mandatory)][string]$JobPath)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\NetCrate\Office'
Import-Module "$PSScriptRoot\OfficeMediaPrimary.psm1" -Force
Import-Module "$PSScriptRoot\OfficeMediaAuto.psm1" -Force
$job=Get-Content -LiteralPath $JobPath -Raw|ConvertFrom-Json
if($job.JobId -cnotmatch '^auto-[a-f0-9]{64}$'){throw 'Invalid automatic job ID.'}
$jobRoot="$root\Jobs\$($job.JobId)"
if($job.OutputPath -cne "$jobRoot\Output" -or $job.InventoryPath -cne "$jobRoot\media-inventory.json" -or $job.RestoreReport -cne "$jobRoot\restore-verification.json"){throw 'Automatic job paths differ from derived destinations.'}
$identity=Get-Content -LiteralPath "$jobRoot\footage.json" -Raw|ConvertFrom-Json
if($identity.Fingerprint -cne $job.FootageFingerprint -or $identity.Clips -le 0){throw 'Footage identity does not match job.'}
$null=Assert-AutoProjectPath $job.SnapshotPath
$destination="$jobRoot\originals"
foreach($base in @($jobRoot,$destination)){
    $cursor=$base
    while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse restore path rejected.'};$cursor=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))}
}
$reportValid=$false
if(Test-Path -LiteralPath $job.RestoreReport){
    try{
        $report=Get-Content -LiteralPath $job.RestoreReport -Raw|ConvertFrom-Json
        $reportValid=$report.ResticVerifyPassed -eq $true -and $report.SnapshotId -ceq $job.SnapshotId -and $report.SnapshotPath -ceq $job.SnapshotPath -and $report.RestoreDirectory -ceq $destination -and $report.Files -eq $identity.Clips -and $report.Bytes -eq $identity.Bytes -and $report.SHA256Manifest -ceq "$jobRoot\originals-sha256.csv" -and (Test-Path -LiteralPath $report.SHA256Manifest)
    }catch{$reportValid=$false}
}
if(-not $reportValid){
    try{Set-OfficeProgress $job.JobId 'RestoringOriginals'}catch{}
    if(([IO.DriveInfo]::new('C:\')).AvailableFreeSpace -lt ([long]$identity.Bytes*3+50GB)){throw 'Automatic job paused: insufficient SSD reserve.'}
    $includes=@($identity.Files|ForEach-Object{'/'+$_.RelativePath})
    $includes|Set-Content -LiteralPath "$jobRoot\videos.include.txt"
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    $null=Invoke-PrimaryRead @('restore',($job.SnapshotId+':'+$job.SnapshotPath),'--target',$destination,'--verify','--overwrite','if-changed','--include-file',"$jobRoot\videos.include.txt",'--sparse')
    $actual=@(Get-ChildItem -LiteralPath $destination -File -Recurse -Force)
    if($actual.Count -ne $identity.Clips){throw 'Restored footage count differs from snapshot metadata.'}
    $expected=@{};foreach($file in $identity.Files){$expected[$file.RelativePath.Replace('/','\')]=$file}
    $manifest=foreach($file in $actual){
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse restored file rejected.'}
        $relative=[IO.Path]::GetRelativePath($destination,$file.FullName)
        if(-not $expected.ContainsKey($relative) -or $file.Length -ne [long]$expected[$relative].Bytes){throw 'Restored footage path or size mismatch.'}
        [pscustomobject]@{RelativePath=$relative;Bytes=$file.Length;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash}
    }
    $manifest|Export-Csv -LiteralPath "$jobRoot\originals-sha256.csv" -NoTypeInformation
    Write-AutoJson $job.RestoreReport @{SnapshotId=$job.SnapshotId;SnapshotPath=$job.SnapshotPath;RestoreDirectory=$destination;Files=$actual.Count;VideoFiles=$actual.Count;Bytes=$identity.Bytes;SHA256Manifest="$jobRoot\originals-sha256.csv";ResticVerifyPassed=$true;VerifiedUtc=[DateTime]::UtcNow.ToString('o')}
}
$tools=Get-Content -LiteralPath "$root\tools.json" -Raw|ConvertFrom-Json
try{Set-OfficeProgress $job.JobId 'Probing'}catch{}
& $tools.Python "$($tools.Scripts)\inspect_media.py" --job-root $jobRoot
if($LASTEXITCODE -ne 0){throw 'Automatic media inspection failed.'}
