#requires -Version 5.1
$ErrorActionPreference='Stop'
$helper=Join-Path $PSScriptRoot 'FolderLauncher.Common.ps1'
if(Test-Path -LiteralPath $helper){. $helper}
$root=Join-Path $env:TEMP ('FolderLauncherTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $active=Join-Path $root 'Video Projects';$project=Join-Path $active 'Project & sample ! 100% (v1)';$camera=Join-Path $project 'Camera'
    New-Item -ItemType Directory -Path $camera -Force | Out-Null
    'synthetic clip'|Set-Content -LiteralPath (Join-Path $project 'one.MOV')
    'synthetic clip'|Set-Content -LiteralPath (Join-Path $camera 'two.mp4')
    'notes'|Set-Content -LiteralPath (Join-Path $camera 'notes.txt')
    $plan=Get-FolderMediaPlan -FolderPath $project -ActiveRoot $active
    if($plan.ProjectPath -ne $project -or $plan.VideoFiles -ne 2 -or $plan.TotalFiles -ne 3){throw 'Project folder and recursive video discovery were incorrect.'}
    foreach($invalid in @($active,$camera,$root)){
        $blocked=$false;try{$null=Get-FolderMediaPlan -FolderPath $invalid -ActiveRoot $active}catch{$blocked=$true};if(-not $blocked){throw 'Parent, nested or outside folder was accepted.'}
    }
    $blocked=$false;try{$null=Get-FolderMediaPlan -FolderPath $project -ActiveRoot $active -ExcludedProjects @('Project & sample ! 100% (v1)')}catch{$blocked=$true};if(-not $blocked){throw 'Excluded project was accepted.'}
    $empty=Join-Path $active 'Empty';New-Item -ItemType Directory -Path $empty|Out-Null
    $blocked=$false;try{$null=Get-FolderMediaPlan -FolderPath $empty -ActiveRoot $active}catch{$blocked=$true};if(-not $blocked){throw 'A folder without supported clips was accepted.'}
    'PASS: exact project scope, recursive clips, special characters, outside/nested/root rejection, exclusions and empty folder handling.'
} finally {
    $resolved=(Resolve-Path -LiteralPath $root).ProviderPath;$parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^FolderLauncherTest-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
