#requires -Version 7.4
param([string]$ToolsRoot,[string]$BridgeScript,[string]$TestRoot=(Join-Path $env:TEMP ('NC-routing-'+[guid]::NewGuid().ToString('N').Substring(0,8))))
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($name in @('Configuration','Credentials')){Import-Module "$repo/src/shared/NetCrate.$name.psm1"}
if(Test-Path $TestRoot){throw 'Use a fresh Temp fixture.'}
$package=Join-Path $TestRoot Package;$setup=Join-Path $TestRoot Setup;$root=Join-Path $TestRoot Engine;$storage=Join-Path $TestRoot Storage
foreach($path in @($package,$setup,$storage)){ $null=[IO.Directory]::CreateDirectory($path) }
Copy-Item "$repo/install" $package -Recurse
if($BridgeScript){Copy-Item -LiteralPath $BridgeScript -Destination (Join-Path $package install/Invoke-SetupAction.ps1) -Force}
$null=[IO.Directory]::CreateDirectory((Join-Path $package src));Copy-Item "$repo/src/shared" (Join-Path $package src) -Recurse
Copy-Item "$repo/VERSION" $package
$planner=Join-Path $package install/NetCrate.SoftwarePlan.psm1
[IO.File]::AppendAllText($planner,"`nfunction Get-NetCrateSoftwarePlan { [IO.File]::AppendAllText('"+(Join-Path $TestRoot planner-called)+"','called'); throw 'Full planner forbidden for ordinary action.' }`nExport-ModuleMember -Function Get-NetCrateSoftwarePlan`n")
$id='7'*32;$null=New-NetCrateIdentity $root $id Worker
Write-NetCrateJson (Join-Path $root prepared.json) @{Role='Worker';InstallationId=$id;Folder=$storage;BackupMode='Folder'}
$bootstrap=Join-Path $setup Bootstrap/Tools/PowerShell/7.6.5
$null=[IO.Directory]::CreateDirectory((Split-Path $bootstrap))
$runtime=if($ToolsRoot){Join-Path $ToolsRoot PowerShell/7.6.5}else{$PSHOME}
Copy-Item $runtime $bootstrap -Recurse
if(-not $ToolsRoot){
 # CI's already-installed host is a generated stamped handoff fixture; this
 # routing check acquires no packages. Native runs use the supplied pinned tools.
 $catalog=Get-Content (Join-Path $package install/dependencies.json) -Raw|ConvertFrom-Json
 $psPackage=$catalog.Packages|Where-Object Name -CEQ PowerShell
 Write-NetCrateJson (Join-Path $bootstrap .netcrate-package.json) @{Version=1;Name='PowerShell';PackageVersion=$psPackage.Version;ArchiveSHA256=$psPackage.SHA256;Files=@(@{Path='pwsh.exe';SHA256=(Get-FileHash (Join-Path $bootstrap pwsh.exe)).Hash.ToLowerInvariant()})}
}
$inputFile=Join-Path $setup action.json
Write-NetCrateJson $inputFile @{Version=1;InstallationId=$id;Role='BackupServer'}
$problems=@()
foreach($hostPath in @((Join-Path $env:WINDIR System32/WindowsPowerShell/v1.0/powershell.exe),(Join-Path $runtime pwsh.exe))){
 $sentinel=Join-Path $TestRoot planner-called
 if([IO.File]::Exists($sentinel)){[IO.File]::Delete($sentinel)}
 $raw=& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $package install/Invoke-SetupAction.ps1) -Action StorageStatus -InputFile $inputFile
 $result=($raw -join "`n")|ConvertFrom-Json
 if(Test-Path $sentinel){$problems+=('Ordinary StorageStatus ran the full package planner on '+$hostPath);continue}
 if(-not $result.Succeeded){$problems+=('Actual StorageStatus routing failed: '+$result.Message);continue}
 Write-Output ('PASS actual StorageStatus route without full planner: '+$hostPath)
}
if($problems.Count){throw ($problems -join "`n")}
$exe=Join-Path $bootstrap pwsh.exe
$changed=[IO.File]::Open($exe,'Append','Write','None')
try{$changed.WriteByte(0)}finally{$changed.Dispose()}
$raw=& (Join-Path $env:WINDIR System32/WindowsPowerShell/v1.0/powershell.exe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $package install/Invoke-SetupAction.ps1) -Action StorageStatus -InputFile $inputFile
$result=($raw -join "`n")|ConvertFrom-Json
if($result.Succeeded -or $result.Code -cne 'approval-needed' -or [IO.File]::Exists($sentinel)){throw 'Changed bootstrap was executed, planned in full, or acquired without approval.'}
Write-Output 'PASS targeted PS5 handoff rejects changed bootstrap without full planning or acquisition.'
