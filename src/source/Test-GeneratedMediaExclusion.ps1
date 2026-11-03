#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLauncher.Common.ps1')
$fixture=Join-Path $env:TEMP ('GeneratedExclusionTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
function Assert($condition,$message){if(-not $condition){throw $message}}
try {
    $active=Join-Path $fixture 'Video Projects';$project=Join-Path $active 'Example';$generated=Join-Path $project 'Proxies\job\Camera'
    New-Item -ItemType Directory -Path $generated -Force|Out-Null
    'original clip'|Set-Content -LiteralPath (Join-Path $project 'original.mp4')
    'generated proxy'|Set-Content -LiteralPath (Join-Path $generated 'original_Proxy.mov')
    @{Kind='OfficeGeneratedMedia';Version=1}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $project 'Proxies\.office-generated-media')
    $plan=Get-FolderMediaPlan -FolderPath $project -ActiveRoot $active
    Assert ($plan.VideoFiles -eq 1 -and $plan.TotalFiles -eq 1) 'The BAT counted downloaded proxies as source footage.'
    $arguments=@(Get-OfficeBackupArguments -Arguments @('--tag','project:Example','--',$project))
    Assert ($arguments -contains '--exclude-if-present') 'Primary backup lacks its generated-media exclusion.'
    $restic='C:\Users\sample-user\AppData\Local\Microsoft\WinGet\Packages\restic.restic_Microsoft.Winget.Source_8wekyb3d8bbwe\restic_0.19.1_windows_amd64.exe'
    $repo=Join-Path $fixture 'disposable-repository';$prior=$env:RESTIC_PASSWORD
    try {
        $env:RESTIC_PASSWORD='disposable-local-test-only'
        & $restic --repo $repo init 2>&1|Out-Null;if($LASTEXITCODE -ne 0){throw 'Disposable Restic setup failed.'}
        & $restic --repo $repo --json backup @arguments 2>&1|Out-Null;if($LASTEXITCODE -ne 0){throw 'Disposable Restic backup failed.'}
        $nodes=@(& $restic --repo $repo ls --json --recursive latest|ForEach-Object{$_|ConvertFrom-Json}|Where-Object type -eq 'file')
        $media=@($nodes|Where-Object{[IO.Path]::GetExtension($_.path) -in @('.mp4','.mov')})
        Assert ($media.Count -eq 1 -and $media[0].path.Replace('\','/').EndsWith('/original.mp4')) ('Restic did not retain only source footage: '+($nodes.path -join ', '))
        Assert (@($nodes|Where-Object{$_.path -like '*Proxy.mov'}).Count -eq 0) 'A generated proxy entered the footage backup.'
    } finally {$env:RESTIC_PASSWORD=$prior}
    'PASS: launcher skips generated trees; a real disposable Restic backup contains only original footage.'
} finally {
    $resolved=(Resolve-Path -LiteralPath $fixture).ProviderPath
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^GeneratedExclusionTest-[a-f0-9]{32}$'){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
