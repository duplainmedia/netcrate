# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\..\..\src\worker\OfficeMediaPrimary.psm1" -Force
foreach($command in @(@('init'),@('backup','x'),@('cat','key',('a'*64)),@('cat','snapshot','latest'))){
    $rejected=$false
    try{Invoke-PrimaryRead -Arguments $command}catch{if($_.Exception.Message -like 'Read-only*'){$rejected=$true}else{throw}}
    if(-not $rejected){throw 'Unsafe primary command was not rejected before loading a key.'}
}
'PASS: unsafe primary commands rejected before credential loading.'
