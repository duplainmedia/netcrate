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
Write-Output "PASS: $script:assertions shared configuration assertions."
