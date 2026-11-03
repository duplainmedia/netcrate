param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\src\shared\NetCrate.Configuration.psm1" -Force
$script:assertions = 0
function Assert($Value, $Message) { if (-not $Value) { throw $Message }; $script:assertions++ }
function Reject([scriptblock]$Action) { $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Assert $rejected 'Invalid configuration was accepted.' }
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
$path = Join-Path $TestRoot 'settings.json'
$settings = [ordered]@{
    Version = 1; Role = 'Source'; InstallationId = ('1' * 32)
    SourceComputer = 'EDIT-PC'; WorkerComputer = 'BACKUP-PC'
    ActiveRoot = 'F:\Video Projects 日本語'; StateRoot = (Join-Path $TestRoot 'State')
    Recipe = 'half-prores-v2'; PollSeconds = 10
    Repositories = @{ Primary = @{ Uri = 'rest:https://backup.example:8200/editing/originals/'; Id = ('a' * 64) }; Results = @{ Uri = 'rest:https://backup.example:8200/editing/results/'; Id = ('b' * 64) } }
    Tools = @{ PowerShell = 'C:\Tools\pwsh.exe'; Restic = 'C:\Tools\restic.exe' }
}
function Save-Fixture { $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8 }
Save-Fixture
$loaded = Import-NetCrateSettings -LiteralPath $path -Role Source
Assert ($loaded.BackupMode -ceq 'Media') 'Legacy settings must keep media behavior.'
Assert ($loaded.ActiveRoot -ceq 'F:\Video Projects 日本語') 'Project root changed.'
Assert ($loaded.SnapshotRoot -ceq '/F/Video Projects 日本語') 'Snapshot root used another drive.'
Assert ((Get-NetCrateProjectPath -Settings $loaded -SnapshotPath '/F/Video Projects 日本語/Project & One') -ceq 'F:\Video Projects 日本語\Project & One') 'Project mapping changed.'
Reject { Get-NetCrateProjectPath -Settings $loaded -SnapshotPath '/F/Video Projects 日本語/Project/Nested' }
Reject { Get-NetCrateProjectPath -Settings $loaded -SnapshotPath '/F/Video Projects 日本語/../Other' }
Reject { Import-NetCrateSettings -LiteralPath $path -Role Worker }
$settings.ActiveRoot = 'F:\Video Projects\..\Other'; Save-Fixture
Reject { Import-NetCrateSettings -LiteralPath $path -Role Source }
$settings.ActiveRoot = 'F:\Video Projects'; $settings.Repositories.Primary.Uri = 'http://backup.example:8200/'; Save-Fixture
Reject { Import-NetCrateSettings -LiteralPath $path -Role Source }
$settings.Repositories.Primary.Uri = 'rest:https://user:secret@backup.example:8200/editing/originals/'; Save-Fixture
Reject { Import-NetCrateSettings -LiteralPath $path -Role Source }
$settings.Repositories.Primary.Uri = 'rest:https://backup.example:8200/editing/originals/'; $settings.Remove('Tools'); Save-Fixture
Reject { Import-NetCrateSettings -LiteralPath $path -Role Source }
Assert ((Get-NetCrateBackupPath $loaded 'f:\VIDEO PROJECTS 日本語' Folder) -ieq $loaded.ActiveRoot) 'Folder mode rejected its root.'
Assert ((Get-NetCrateBackupPath $loaded 'F:\Video Projects 日本語\Notes\November' Folder) -ceq 'F:\Video Projects 日本語\Notes\November') 'Folder mode rejected nested input.'
Reject { Get-NetCrateBackupPath $loaded 'F:\Video Projects 日本語 sibling\Notes' Folder }
Reject { Get-NetCrateBackupPath $loaded 'F:\Video Projects 日本語\Notes\November' Media }
$overlap = $loaded.PSObject.Copy(); $overlap.StateRoot = 'F:\Video Projects 日本語\Notes\State'
Reject { Get-NetCrateBackupPath $overlap 'F:\Video Projects 日本語\Notes' Folder }
$worker=$loaded.PSObject.Copy();$worker.Role='Worker';$worker.BackupMode='Folder'
$worker.Repositories=@{Primary=@{Uri=(Join-Path $TestRoot 'Primary');Id=('a'*64)};Results=@{Uri=(Join-Path $TestRoot 'Results');Id=('b'*64)}}
$worker.Tools=@{PowerShell='C:\Tools\pwsh.exe';Restic='C:\Tools\restic.exe';RestServer='C:\Tools\rest-server.exe';Python='C:\Tools\python.exe'}
Write-NetCrateJson $path $worker
Assert ((Import-NetCrateSettings $path Worker).BackupMode -ceq 'Folder') 'A Folder worker still requires video tools.'
$worker.BackupMode='Media';Write-NetCrateJson $path $worker
Reject { Import-NetCrateSettings $path Worker }
$worker.BackupMode='Unknown';Write-NetCrateJson $path $worker
Reject { Import-NetCrateSettings $path Worker }
Write-Output "PASS: $script:assertions shared configuration assertions."
