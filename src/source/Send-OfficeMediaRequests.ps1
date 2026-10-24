#requires -Version 5.1
[CmdletBinding()]
param([string]$ServiceRoot='C:\ProgramData\OfficeMediaSource')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
Import-Module "$ServiceRoot\Tools\OfficeMediaAuto.psm1" -Force
$config=Get-Content -LiteralPath "$ServiceRoot\config.json" -Raw|ConvertFrom-Json
$credential=$null;$plain=$null;$errorsCount=0;$sent=0
function Invoke-SendBackup([string]$Directory,[string]$Tag){
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$config.ResticExe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($key in @($psi.EnvironmentVariables.Keys)){if($key -like 'RESTIC_*'){$psi.EnvironmentVariables.Remove($key)}}
    $arguments=@('--repo',$credential.ResultsRepository,'--cache-dir',"$ServiceRoot\Cache",'--json','backup','--host','SOURCE-PC','--tag',$Tag,$Directory)
    $quoted=foreach($arg in $arguments){if($arg -match '["\r\n]' -or $arg.EndsWith('\')){throw 'Unsupported sender argument.'};'"'+$arg+'"'}
    $psi.Arguments=$quoted -join ' '
    $psi.EnvironmentVariables['RESTIC_PASSWORD']=$credential.ResultsPassword
    $psi.EnvironmentVariables['RESTIC_REST_USERNAME']=$credential.RestUsername
    $psi.EnvironmentVariables['RESTIC_REST_PASSWORD']=$credential.RestPassword
    $child=New-Object Diagnostics.Process;$child.StartInfo=$psi
    try{
        $null=$child.Start();$psi.EnvironmentVariables.Clear()
        $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.WaitForExit()
        $text=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult()
        if($child.ExitCode -ne 0){throw "Request transport failed (exit $($child.ExitCode)); credentials suppressed; retry retained."}
        $summary=@($text -split "`n"|Where-Object{$_.Trim()}|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.message_type -eq 'summary'})
        if($summary.Count -ne 1 -or $summary[0].snapshot_id -cnotmatch '^[a-f0-9]{64}$'){throw 'Sender snapshot summary missing.'}
        return $summary[0].snapshot_id
    }finally{$psi.EnvironmentVariables.Clear();$child.Dispose();$diagnostic=$null}
}
try{
    if($env:COMPUTERNAME -ine 'SOURCE-PC' -or $config.Repository -cne 'rest:http://backup.example:8000/sample-user/office-media-results/'){throw 'Sender identity or repository mismatch.'}
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($config.CredentialPath),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    $credential=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json
    if($credential.ResultsRepository -cne $config.Repository -or $credential.RestUsername -ne 'sample-user'){throw 'Existing receiver credential format or identity mismatch.'}
    # Relay existing receiver verification receipts without changing that receiver.
    foreach($file in (Get-ChildItem -LiteralPath $config.ReceiverState -File -Filter '*.json')){
        if($file.Name -cnotmatch '^[a-f0-9]{64}\.json$'){continue}
        try{
        if($file.Length -gt 32768 -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Invalid delivery receipt file.'}
        $receipt=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
        if($receipt.JobId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,100}$' -or $receipt.ResultSnapshot -cnotmatch '^[a-f0-9]{64}$' -or [int]$receipt.MediaFiles -le 0){continue}
        $id=Get-AutoHash ('delivery|'+$receipt.ResultSnapshot)
        $folder="$ServiceRoot\Outbox\$id"
        New-Item -ItemType Directory -Path $folder -Force|Out-Null
        if(-not(Test-Path -LiteralPath "$folder\delivery.json")){Write-AutoJson "$folder\delivery.json" @{Version=1;Kind='delivery';SourceComputer='SOURCE-PC';JobId=$receipt.JobId;ResultSnapshot=$receipt.ResultSnapshot;MediaFiles=[int]$receipt.MediaFiles;VerifiedUtc=$receipt.VerifiedUtc}}
        }catch{
            $errorsCount++
            Write-AutoJson "$ServiceRoot\State\retry-receipt-$($file.BaseName).json" @{State='RetryPending';Message='Delivery receipt unreadable; independent requests continue.';CheckedUtc=[DateTime]::UtcNow.ToString('o')}
        }
    }
    foreach($folder in (Get-ChildItem -LiteralPath "$ServiceRoot\Outbox" -Directory)){
        try{
            if($folder.Name -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid outbox item name.'}
            $checkpoint="$ServiceRoot\State\Sent\$($folder.Name).json"
            if(Test-Path -LiteralPath $checkpoint){continue}
            $files=@(Get-ChildItem -LiteralPath $folder.FullName -Force -File)
            if($files.Count -ne 1 -or $files[0].Name -notin @('request.json','delivery.json') -or $files[0].Length -gt 32768 -or $folder.Attributes -band [IO.FileAttributes]::ReparsePoint -or $files[0].Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Invalid outbox payload.'}
            $payload=Get-Content -LiteralPath $files[0].FullName -Raw|ConvertFrom-Json
            if($files[0].Name -eq 'request.json'){$null=Assert-AutoRequest $payload;$tag='office-media-request'}else{$tag='office-media-delivery'}
            $snapshot=Invoke-SendBackup $folder.FullName $tag
            Write-AutoJson $checkpoint @{SnapshotId=$snapshot;Kind=$payload.Kind;SentUtc=[DateTime]::UtcNow.ToString('o')}
            $sent++
        }catch{
            $errorsCount++
            $safeName=if($folder.Name -cmatch '^[a-f0-9]{64}$'){$folder.Name}else{'invalid-item'}
            Write-AutoJson "$ServiceRoot\State\retry-$safeName.json" @{State='RetryPending';Message=$_.Exception.Message;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
        }
    }
    Write-AutoJson "$ServiceRoot\State\status.json" @{State=$(if($errorsCount){'RetryPending'}else{'Ready'});SentThisRun=$sent;Errors=$errorsCount;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
    if($errorsCount){exit 1}
}catch{Write-AutoJson "$ServiceRoot\State\status.json" @{State='RetryPending';Message='Sender setup, credential access or transport failed; secrets suppressed. Requests retained for retry.';CheckedUtc=[DateTime]::UtcNow.ToString('o')};exit 1}
finally{if($plain){[Array]::Clear($plain,0,$plain.Length)};$credential=$null}
