#requires -Version 7.4
param([Parameter(Mandatory)][ValidateSet('Export','Save','ListBackups','ListBackupChildren','RestoreSelection')][string]$Action,
    [Parameter(Mandatory)][string]$StateRoot,[string]$Destination,[string]$ResticExe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
try {
    Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Configuration.psm1') -WarningAction SilentlyContinue
    $null=Assert-NetCrateLocalPath $StateRoot
    if($Action -cin @('Export','Save')) {
        Import-Module (Join-Path $PSScriptRoot 'NetCrate.Repositories.psm1') -WarningAction SilentlyContinue
        if($Action -ceq 'Export') {
            # This stdout belongs exclusively to IRecoveryTransferService, never the generic bridge.
            [Console]::Write((Get-NetCrateRecoveryDocument $StateRoot))
        } else {
            Export-NetCrateRecovery $StateRoot $Destination
            [Console]::Write((@{Succeeded=$true;SavedPath=$Destination}|ConvertTo-Json -Compress))
        }
    } else {
        # Dedicated binary stdin frames avoid plaintext in files, arguments or generic input records.
        $inputStream=[Console]::OpenStandardInput()
        function Read-RecoveryFrame([int]$Limit) {
            $header=[byte[]]::new(4);$inputStream.ReadExactly($header,0,4)
            $length=[BitConverter]::ToInt32($header,0)
            if($length -lt 1 -or $length -gt $Limit){throw 'Invalid private recovery frame.'}
            $bytes=[byte[]]::new($length)
            try {$inputStream.ReadExactly($bytes,0,$length);return [Text.UTF8Encoding]::new($false,$true).GetString($bytes)}
            finally {[Array]::Clear($bytes,0,$bytes.Length)}
        }
        $contents=Read-RecoveryFrame 32768
        $jsonOptions=@{}
        if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$jsonOptions.DateKind='String'}
        $document=[System.Text.Json.JsonDocument]::Parse($contents)
        try { & (Get-Module NetCrate.Configuration) { param($Element) Assert-NetCrateJsonMembers $Element } $document.RootElement } finally {$document.Dispose()}
        $recovery=$contents|ConvertFrom-Json @jsonOptions;$contents=$null
        $selection=Read-RecoveryFrame 8192
        $document=[System.Text.Json.JsonDocument]::Parse($selection)
        try { & (Get-Module NetCrate.Configuration) { param($Element) Assert-NetCrateJsonMembers $Element } $document.RootElement } finally {$document.Dispose()}
        $request=$selection|ConvertFrom-Json @jsonOptions;$selection=$null
        $allowed=@('RepositoryPath','SnapshotId','RelativePath','DestinationParent','Cursor','BrowseDeadlineUtc')
        if(@($request.PSObject.Properties.Name|Where-Object {$_ -cnotin $allowed}).Count){throw 'Unsupported private recovery selection.'}
        foreach($property in $request.PSObject.Properties){if($null -ne $property.Value -and ($property.Value -isnot [string] -or $property.Value.Length -gt 2048)){throw 'Invalid private recovery selection.'}}
        if($recovery.Version -ne 1 -or $recovery.Kind -cne 'netcrate-recovery' -or $recovery.Primary.Id -cnotmatch '^[a-f0-9]{64}$' -or $recovery.Results.Id -cnotmatch '^[a-f0-9]{64}$' -or
            $recovery.Primary.Password -isnot [string] -or $recovery.Primary.Password.Length -lt 1 -or $recovery.Primary.Password.Length -gt 1024 -or
            $recovery.Results.Password -isnot [string] -or $recovery.Results.Password.Length -lt 1 -or $recovery.Results.Password.Length -gt 1024){throw 'Invalid pasted recovery document.'}
        $request|Add-Member -NotePropertyName RecoveryDocument -NotePropertyValue $recovery
        Import-Module (Join-Path $PSScriptRoot '../src/shared/NetCrate.Restore.psm1') -WarningAction SilentlyContinue
        $result=Invoke-NetCrateRestoreAction $Action $request $StateRoot $ResticExe
        [Console]::Write(($result|ConvertTo-Json -Depth 8 -Compress))
    }
    exit 0
} catch {
    # Never relay exception messages, input excerpts, native stderr or recovery contents.
    [Console]::Write('{"Succeeded":false,"Code":"recovery-transfer-failed","Message":"Recovery details could not be transferred. Check the recovery details, folder and matching repository, then try again."}')
    exit 1
} finally {
    $contents=$null;$recovery=$null;$request=$null;$selection=$null
}
