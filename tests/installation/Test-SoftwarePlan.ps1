#requires -Version 5.1
param([Parameter(Mandatory)][string]$TestRoot, [ValidateSet('All','License','Progress','Reuse','Stamp')][string]$ReviewCase='All')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action) { $caught=$false; try { & $Action | Out-Null } catch { $caught=$true }; Assert $caught 'Expected the operation to reject unsafe or unaccepted input.' }
Assert (-not (Test-Path -LiteralPath $TestRoot)) 'Use a fresh ordinary Temp fixture.'
Assert ($TestRoot -notmatch '(?i)OneDrive' -and $TestRoot -match '(?i)[\\/](temp|_temp)[\\/]') 'Use an ordinary Temp fixture outside OneDrive.'
$null = [IO.Directory]::CreateDirectory($TestRoot)
Import-Module (Join-Path $repo 'install/NetCrate.Dependencies.psm1') -Force
Import-Module (Join-Path $repo 'install/NetCrate.SoftwarePlan.psm1') -Force
$root = Join-Path $TestRoot 'Engine'; $bootstrap = Join-Path $TestRoot 'Setup/Bootstrap'; $folder = Join-Path $TestRoot 'Selected'
$arguments = @{Root=$root;BootstrapRoot=$bootstrap;Role='Source';BackupMode='Folder';Folder=$folder}
# Wrong role/mode selection or a missing bootstrap copy must change these literal matrices.
foreach ($case in @(
    @{Role='Source';Mode='Folder';Names='PowerShell,PowerShell,Restic'},
    @{Role='Source';Mode='Media';Names='PowerShell,PowerShell,Restic'},
    @{Role='Worker';Mode='Folder';Names='PowerShell,PowerShell,Restic,RestServer,Python,Bcrypt'},
    @{Role='Worker';Mode='Media';Names='PowerShell,PowerShell,Restic,RestServer,Python,FFmpeg,Pillow,Bcrypt'}
)) {
    $plan = Get-NetCrateSoftwarePlan -Root $root -BootstrapRoot $bootstrap -Role $case.Role -BackupMode $case.Mode -Folder $folder
    Assert (($plan.Packages.Name -join ',') -ceq $case.Names) 'The reviewed package matrix differs from required private software.'
    Assert ($plan.Version -eq 1 -and $plan.PlanId -cmatch '^[a-f0-9]{64}$') 'Plan identity is missing.'
    Assert ($plan.Packages[0].Scope -ceq 'Bootstrap' -and $plan.Packages[1].Scope -ceq 'Runtime') 'Both private PowerShell locations must be reviewed.'
    Assert ($plan.Packages[0].Destination -ceq (Join-Path $bootstrap 'Tools/PowerShell/7.6.5')) 'Bootstrap destination differs from acquisition.'
    Assert ($plan.Packages[1].Destination -ceq (Join-Path $root 'Tools/PowerShell/7.6.5')) 'Runtime destination differs from acquisition.'
    foreach ($package in $plan.Packages) {
        Assert ($package.Status -ceq 'Missing' -and $package.CacheStatus -ceq 'Missing') 'Fresh software should need acquisition.'
        Assert ($package.Purpose -and $package.Source.StartsWith('https://') -and $package.License -and $package.SHA256.Length -eq 64) 'Software approval metadata is incomplete.'
    }
    Assert ($plan.Changes.Count -eq $plan.Packages.Count) 'All missing packages should appear as remaining work.'
    if ($case.Role -ceq 'Worker' -and $case.Mode -ceq 'Media' -and $ReviewCase -cin @('All','License')) {
        Assert (($plan.Packages | Where-Object Name -CEQ 'Pillow').License -ceq 'MIT-CMU') 'Pillow approval uses a license different from the pinned 12.3.0 release.'
    }
}
$plan = Get-NetCrateSoftwarePlan @arguments
Assert (-not [IO.Directory]::Exists($root) -and -not [IO.Directory]::Exists($bootstrap) -and -not [IO.Directory]::Exists($folder)) 'Planning wrote to a selected path.'
Assert ((Get-NetCrateSoftwarePlan @arguments).PlanId -ceq $plan.PlanId) 'Identical choices produce different consent identities.'
Assert ((Assert-NetCrateSoftwarePlan @arguments -PlanId $plan.PlanId).PlanId -ceq $plan.PlanId) 'Accepted plan did not validate.'
Reject { Assert-NetCrateSoftwarePlan @arguments -PlanId ('0'*64) }
foreach ($change in @(@{Role='Worker'},@{BackupMode='Media'},@{Folder=(Join-Path $TestRoot 'Other')},@{Root=(Join-Path $TestRoot 'OtherEngine')},@{BootstrapRoot=(Join-Path $TestRoot 'OtherBootstrap')})) {
    $altered = $arguments.Clone(); foreach($key in $change.Keys){$altered[$key]=$change[$key]}
    Assert ((Get-NetCrateSoftwarePlan @altered).PlanId -cne $plan.PlanId) 'A changed selection retained consent.'
    Reject { Assert-NetCrateSoftwarePlan @altered -PlanId $plan.PlanId }
}
Write-Output ('PASS: PS '+$PSVersionTable.PSVersion+' catalog matrices, metadata, choice-bound consent and read-only planning.')

$recoveryPlan = Get-NetCrateSoftwarePlan @arguments -RecoveryOnly
Assert (($recoveryPlan.Packages.Name -join ',') -ceq 'PowerShell,Restic') 'Independent recovery should acquire only bootstrap PowerShell and Restic.'
Assert (@($recoveryPlan.Packages | Where-Object Scope -CNE 'Bootstrap').Count -eq 0) 'Recovery plan included a runtime copy.'
Assert ($recoveryPlan.Packages[1].Destination -ceq (Join-Path $bootstrap 'Tools/Restic/0.19.1')) 'Recovery Restic is outside bootstrap.'
Assert ($recoveryPlan.PlanId -cne $plan.PlanId) 'Recovery purpose retained setup approval.'
Reject { Assert-NetCrateSoftwarePlan @arguments -RecoveryOnly -PlanId $plan.PlanId }
Assert ((Assert-NetCrateSoftwarePlan @arguments -RecoveryOnly -PlanId $recoveryPlan.PlanId).PlanId -ceq $recoveryPlan.PlanId) 'Recovery acceptance did not validate.'
Write-Output 'PASS: separate consent identity for bootstrap-only independent recovery.'

# A copied real module/catalog lets fixture package identities change without touching the checked-in catalog.
$copy = Join-Path $TestRoot 'Module'; $null=[IO.Directory]::CreateDirectory((Join-Path $copy 'install')); $null=[IO.Directory]::CreateDirectory((Join-Path $copy 'src/shared'))
foreach($name in @('NetCrate.Dependencies.psm1','NetCrate.SoftwarePlan.psm1','dependencies.json')){[IO.File]::Copy((Join-Path $repo ('install/'+$name)),(Join-Path $copy ('install/'+$name)))}
[IO.File]::Copy((Join-Path $repo 'src/shared/NetCrate.Configuration.psm1'),(Join-Path $copy 'src/shared/NetCrate.Configuration.psm1'))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$catalogPath = Join-Path $copy 'install/dependencies.json'; $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
$payload = Join-Path $TestRoot 'payload.zip'; $zip=[IO.Compression.ZipFile]::Open($payload,'Create')
try { foreach($package in $catalog.Packages){$stream=$zip.CreateEntry($package.Executable).Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('generated '+$package.Name);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}} } finally {$zip.Dispose()}
$fixtureHash = (Get-FileHash -LiteralPath $payload).Hash.ToLowerInvariant()
foreach($package in $catalog.Packages){$package.SHA256=$fixtureHash;$package.Url='https://github.com/netcrate-software-fixture/'+$package.Name+'.zip'}
[IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8))
Remove-Module NetCrate.SoftwarePlan,NetCrate.Dependencies -Force
Import-Module (Join-Path $copy 'install/NetCrate.Dependencies.psm1') -Force
Import-Module (Join-Path $copy 'install/NetCrate.SoftwarePlan.psm1') -Force
$fixturePlan = Get-NetCrateSoftwarePlan @arguments
Assert ($fixturePlan.PlanId -cne $plan.PlanId) 'Changed package identities retained catalog approval.'
foreach($field in @('SHA256','Url','Version','Executable')) {
    $saved=$catalog.Packages[0].$field
    $catalog.Packages[0].$field = switch($field) { 'SHA256' {'0'*64}; 'Url' {'https://github.com/netcrate-software-fixture/changed.zip'}; 'Version' {'7.6.6'}; 'Executable' {'changed.exe'} }
    [IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8))
    Assert ((Get-NetCrateSoftwarePlan @arguments).PlanId -cne $fixturePlan.PlanId) ('Changed package '+$field+' retained consent.')
    Reject { Assert-NetCrateSoftwarePlan @arguments -PlanId $fixturePlan.PlanId }
    $catalog.Packages[0].$field=$saved
    [IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8))
}
$cache = Join-Path $root 'Downloads'; $null=[IO.Directory]::CreateDirectory($cache)
$cachePath=Join-Path $cache ($fixtureHash+'.package');[IO.File]::Copy($payload,$cachePath)
$cachedPlan = Get-NetCrateSoftwarePlan @arguments
Assert ($cachedPlan.Packages[0].Status -ceq 'Missing' -and $cachedPlan.Packages[1].Status -ceq 'Cached') 'Bootstrap and runtime caches were conflated.'
Assert ($cachedPlan.PlanId -ceq $fixturePlan.PlanId) 'A verified cache invalidated identity-bound consent.'
$events=[Collections.Generic.List[object]]::new();$progress={param($record)$events.Add($record);'callback noise'}
$package=$catalog.Packages[0]
$archive=Get-NetCratePackageArchive $package $cache -Progress $progress
Assert ($archive -is [string] -and $archive -ceq $cachePath) 'Callback output polluted the package archive return value.'
Assert (($events.Phase -join ',') -ceq 'Checking,Verifying,Reused') 'Cache progress ordering was dishonest.'
$events.Clear()
$directory=Expand-NetCrateDependency $archive $package (Join-Path $root 'Tools') -Progress $progress
Assert ($directory -is [string]) 'Callback output polluted extraction.'
Assert (($events.Phase -join ',') -ceq 'Checking,Verifying,Extracting,Ready') 'Extraction progress ordering was dishonest.'
$readyPlan=Get-NetCrateSoftwarePlan @arguments
Assert ($readyPlan.Packages[1].Status -ceq 'Reused' -and $readyPlan.Changes.Count -eq 2) 'Verified installed software was not reused in the plan.'
$before=[IO.File]::ReadAllBytes((Join-Path $directory '.netcrate-package.json'))
[IO.File]::WriteAllText((Join-Path $directory 'pwsh.exe'),'damaged')
$damagedPlan=Get-NetCrateSoftwarePlan @arguments
Assert ($damagedPlan.Packages[1].Status -ceq 'Repair') 'Damaged software was presented as reusable.'
Assert ([IO.File]::ReadAllText((Join-Path $directory 'pwsh.exe')) -ceq 'damaged') 'Planning repaired software without approval.'
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $directory '.netcrate-package.json'))) -ceq [Convert]::ToBase64String($before)) 'Planning rewrote the installation stamp.'
$events.Clear();$null=Expand-NetCrateDependency $archive $package (Join-Path $root 'Tools') -Progress $progress
$events.Clear();$null=Expand-NetCrateDependency $archive $package (Join-Path $root 'Tools') -Progress $progress
Assert (($events.Phase -join ',') -ceq 'Checking,Verifying,Reused') 'Reuse progress was not reported.'
if ($ReviewCase -cin @('All','Stamp')) {
    foreach($kind in @('empty','missing-executable','duplicate')) {
        $stampPath=Join-Path $directory '.netcrate-package.json';$stamp=[IO.File]::ReadAllText($stampPath)|ConvertFrom-Json
        $stamp.Files = switch($kind) { 'empty' {@()}; 'missing-executable' {@($stamp.Files | Where-Object Path -CNE 'pwsh.exe')}; 'duplicate' {@($stamp.Files)+@($stamp.Files[0])} }
        [IO.File]::WriteAllText($stampPath,($stamp|ConvertTo-Json -Depth 8))
        $untrustedText=[IO.File]::ReadAllText($stampPath)
        $preservedBefore=@([IO.Directory]::GetDirectories([IO.Path]::GetDirectoryName($directory),'*.damaged-*'))
        Assert ((Get-NetCrateSoftwarePlan @arguments).Packages[1].Status -ceq 'Repair') 'Planner accepted incomplete installed evidence.'
        $events.Clear();$null=Expand-NetCrateDependency $archive $package (Join-Path $root 'Tools') -Progress $progress
        Assert ($events.Phase -notcontains 'Reused') ('Installer reused '+$kind+' evidence which the plan rejected.')
        $preservedAfter=@([IO.Directory]::GetDirectories([IO.Path]::GetDirectoryName($directory),'*.damaged-*') | Where-Object {$preservedBefore -cnotcontains $_})
        Assert ($preservedAfter.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $preservedAfter[0] '.netcrate-package.json')) -ceq $untrustedText) 'Repair did not preserve the rejected stamp and folder.'
        Assert ((Get-NetCrateSoftwarePlan @arguments).Packages[1].Status -ceq 'Reused') 'Repair did not establish the same verified evidence the plan requires.'
    }
    $validStamp=[IO.File]::ReadAllText($stampPath);$stamp=$validStamp|ConvertFrom-Json;$stamp.Name='OtherIdentity'
    [IO.File]::WriteAllText($stampPath,($stamp|ConvertTo-Json -Depth 8));$untrustedText=[IO.File]::ReadAllText($stampPath)
    Reject { Expand-NetCrateDependency $archive $package (Join-Path $root 'Tools') -Progress $progress }
    Assert ([IO.File]::ReadAllText($stampPath) -ceq $untrustedText) 'A different-identity folder was changed during attempted repair.'
    [IO.File]::WriteAllText($stampPath,$validStamp)
    Write-Output 'PASS: planner and extractor agree on empty, incomplete and duplicate stamp repair.'
}
$bad=$package.PSObject.Copy();$bad.SHA256='0'*64
$events.Clear();Reject { Expand-NetCrateDependency $archive $bad (Join-Path $root 'OtherTools') -Progress $progress }
Assert ($events[$events.Count-1].Phase -ceq 'Failed') 'Failed verification did not preserve a terminal progress row.'
foreach($record in $events){Assert (($record.PSObject.Properties.Name -join ',') -ceq 'Name,Version,Phase,Completed,Total') 'Arbitrary data leaked through progress.';Assert ($record.Completed -ge 0 -and $record.Total -ge $record.Completed) 'Progress counts were invalid.'}
# A broken observer must not turn successful verification/install into an application failure.
$null=Get-NetCratePackageArchive $package $cache -Progress {throw 'observer secret'}
[IO.File]::WriteAllText($cachePath,'bad cache')
$corruptPlan=Get-NetCrateSoftwarePlan @arguments
Assert ($corruptPlan.Packages[2].Status -ceq 'Repair' -and $corruptPlan.Packages[2].CacheStatus -ceq 'Repair') 'Corrupt cache should need repair.'
Assert ([IO.File]::ReadAllText($cachePath) -ceq 'bad cache') 'Planning replaced a corrupt cache.'
Write-Output 'PASS: real cache, extraction, installed-file verification, repair planning and bounded progress.'

# Substitute only HTTPS transport; acquisition, hash checks, extraction and role installation stay real.
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Net;
public sealed class SoftwareFixtureCreator : IWebRequestCreate {
 public static byte[] Payload; public static int Requests; public static bool Offline;
 public WebRequest Create(Uri uri) { Requests++; if(Offline) throw new WebException("Generated fixture is offline"); return new SoftwareFixtureRequest(uri); }
}
public sealed class SoftwareFixtureRequest : WebRequest {
 readonly Uri uri; public SoftwareFixtureRequest(Uri value) { uri=value; }
 public override WebResponse GetResponse(){return new SoftwareFixtureResponse(uri);}
}
public sealed class SoftwareFixtureResponse : WebResponse {
 readonly Uri uri; public SoftwareFixtureResponse(Uri value){uri=value;}
 public override long ContentLength { get {return SoftwareFixtureCreator.Payload.Length;} }
 public override Uri ResponseUri { get{return uri;} }
 public override WebHeaderCollection Headers {get{return new WebHeaderCollection();}}
 public override Stream GetResponseStream(){return new MemoryStream(SoftwareFixtureCreator.Payload,false);}
}
'@ -IgnoreWarnings -WarningAction SilentlyContinue
[SoftwareFixtureCreator]::Payload=[IO.File]::ReadAllBytes($payload)
Assert ([Net.WebRequest]::RegisterPrefix('https://github.com/netcrate-software-fixture/',[SoftwareFixtureCreator]::new())) 'Fixture HTTPS registration failed.'
$events.Clear();$tools=Install-NetCrateTools -Root (Join-Path $TestRoot 'Install') -Role Worker -BackupMode Folder -Progress $progress
Assert ($tools.PSObject.Properties.Name -notcontains 'FFmpeg' -and $tools.PSObject.Properties.Name -notcontains 'Pillow' -and $tools.RestServer -and $tools.Bcrypt) 'Folder install diverged from reviewed software.'
Assert (($events.Phase -contains 'Downloading') -and ($events.Phase -contains 'Ready')) 'Installer did not forward package progress.'
foreach($record in $events){Assert (($record.PSObject.Properties.Name -join ',') -ceq 'Name,Version,Phase,Completed,Total') 'Acquisition leaked arbitrary progress data.'}
if ($ReviewCase -cin @('All','Progress')) {
    foreach($name in @('PowerShell','Restic','RestServer','Python','Bcrypt')) {
        $records=@($events | Where-Object Name -CEQ $name)
        Assert (@($records | Where-Object Completed -EQ 1).Count -eq 1) ('Combined install prematurely completed '+$name+' before extraction.')
        Assert ($records[$records.Count-1].Completed -eq 1 -and $records[$records.Count-1].Phase -ceq 'Ready') 'Combined installation did not finish at Ready.'
    }
    $recoveryEvents=[Collections.Generic.List[object]]::new()
    $null=Install-NetCrateRecoveryTools -Root (Join-Path $TestRoot 'RecoveryInstall') -Progress {param($record)$recoveryEvents.Add($record)}
    foreach($name in @('PowerShell','Restic')) { Assert (@($recoveryEvents | Where-Object {$_.Name -ceq $name -and $_.Completed -eq 1}).Count -eq 1) 'Recovery install completion regressed after acquisition.' }
    Write-Output 'PASS: combined normal/recovery streams complete each package only after extraction.'
}
if ($ReviewCase -cin @('All','Reuse')) {
    $recoveryRoot=Join-Path $TestRoot 'RecoveryReuse';$null=Install-NetCrateRecoveryTools -Root $recoveryRoot
    # Delete only the precisely named generated cache files; leave installed evidence untouched.
    foreach($downloads in @((Join-Path $TestRoot 'Install/Downloads'),(Join-Path $recoveryRoot 'Downloads'))) {
        foreach($file in [IO.Directory]::GetFiles($downloads,'*.package')) {[IO.File]::Delete($file)}
    }
    $requestCount=[SoftwareFixtureCreator]::Requests;[SoftwareFixtureCreator]::Offline=$true
    $events.Clear();$null=Install-NetCrateTools -Root (Join-Path $TestRoot 'Install') -Role Worker -BackupMode Folder -Progress $progress
    $null=Install-NetCrateRecoveryTools -Root $recoveryRoot -Progress $progress
    Assert ([SoftwareFixtureCreator]::Requests -eq $requestCount) 'Verified installed packages attempted needless offline acquisition.'
    Assert ($events.Phase -notcontains 'Downloading' -and $events.Phase -notcontains 'Extracting' -and @($events|Where-Object Phase -CEQ 'Reused').Count -eq 7) 'Direct verified reuse was not reported truthfully.'
    Write-Output 'PASS: verified normal/recovery installations work offline with missing archive caches.'
}
Write-Output 'PASS: real generated package acquisition and Folder install progress forwarding.'
