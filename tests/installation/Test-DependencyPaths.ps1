#requires -Version 5.1
param([Parameter(Mandatory)][string]$TestRoot, [switch]$Child)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/src/shared/NetCrate.Configuration.psm1"
Import-Module "$repo/install/NetCrate.Dependencies.psm1"

if (-not $Child) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Launch the fixture with PowerShell 7.' }
    $full = Assert-NetCrateLocalPath $TestRoot
    if (Test-Path -LiteralPath $full) { throw 'Use a new fixture root.' }
    if ($full -match '(?i)OneDrive' -or $full -notmatch '(?i)[\\/](temp|_temp)[\\/]') { throw 'Use an ordinary Temp fixture.' }
    Import-Module "$repo/src/shared/NetCrate.Credentials.psm1"
    $null = Set-NetCratePrivateDirectory $full
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $relative = 'Modules/' + [char]0x65e5 + [char]0x672c + [char]0x8a9e + ' [set]/' + ('a'*70) + '/tool.bin'
    $archivePath = Join-Path $full 'fixture.zip'
    $zip = [IO.Compression.ZipFile]::Open($archivePath,'Create')
    try {
        $stream = $zip.CreateEntry($relative).Open()
        try { $bytes = [byte[]](0..255); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
    $unsafeArchives = @()
    foreach ($kind in @('traversal','collision','file-directory','link')) {
        $path = Join-Path $full ($kind + '.zip')
        $zip = [IO.Compression.ZipFile]::Open($path,'Create')
        try {
            $names = switch ($kind) {
                'traversal' { @('../escaped.txt') }
                'collision' { @('tool.bin','TOOL.bin') }
                'file-directory' { @('tool.bin/','tool.bin') }
                'link' { @('tool.bin') }
            }
            foreach ($name in $names) {
                $entry = $zip.CreateEntry($name)
                if ($kind -ceq 'link') { $entry.ExternalAttributes = 0xA000 -shl 16 }
                if (-not $name.EndsWith('/')) {
                    $stream = $entry.Open()
                    try { $stream.WriteByte(1) } finally { $stream.Dispose() }
                }
            }
        } finally { $zip.Dispose() }
        $unsafeArchives += @{Path=$path;Hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
    }
    $outside = Join-Path $full 'Outside'
    $null = [IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $outside 'sentinel.txt'),'preserved')
    foreach ($hostName in @('PS51','PS7')) {
        $hostRoot = Join-Path $full $hostName
        $null = [IO.Directory]::CreateDirectory($hostRoot)
        $longRoot = Join-Path $hostRoot ('p'*(145-$hostRoot.Length-1))
        $null = [IO.Directory]::CreateDirectory($longRoot)
        $linkParent = Join-Path $longRoot ('j'*112)
        $null = [IO.Directory]::CreateDirectory($linkParent)
        $link = Join-Path $linkParent 'link'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        Write-NetCrateJson (Join-Path $hostRoot 'fixture.json') @{
            LongRoot=$longRoot; Archive=$archivePath; Hash=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
            Relative=$relative; UnsafeArchives=$unsafeArchives; Link=$link; Outside=$outside
        }
        $hostExe = if ($hostName -ceq 'PS51') { "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" } else { (Get-Process -Id $PID).Path }
        & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -TestRoot $hostRoot -Child
        if ($LASTEXITCODE) { throw ($hostName + ' dependency-path fixture failed.') }
    }
    Write-Output 'PASS: real Windows PowerShell 5.1 and PowerShell 7 short/long dependency paths.'
    exit 0
}

$fixture = Read-NetCrateJson (Join-Path $TestRoot 'fixture.json')
# Replace only the external HTTPS response; WebClient still writes, verifies,
# preserves rejected files and publishes the real cache at the requested path.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
public sealed class FixtureDownloadCreator : IWebRequestCreate {
    public static byte[] Payload;
    public WebRequest Create(Uri uri) { return new FixtureDownloadRequest(uri); }
}
public sealed class FixtureDownloadRequest : WebRequest {
    readonly Uri uri;
    public FixtureDownloadRequest(Uri value) { uri = value; }
    public override WebResponse GetResponse() { return new FixtureDownloadResponse(uri); }
}
public sealed class FixtureDownloadResponse : WebResponse {
    readonly Uri uri;
    public FixtureDownloadResponse(Uri value) { uri = value; }
    public override long ContentLength { get { return FixtureDownloadCreator.Payload.Length; } }
    public override Uri ResponseUri { get { return uri; } }
    public override WebHeaderCollection Headers { get { return new WebHeaderCollection(); } }
    public override Stream GetResponseStream() { return new MemoryStream(FixtureDownloadCreator.Payload, false); }
}
'@ -IgnoreWarnings -WarningAction SilentlyContinue
[FixtureDownloadCreator]::Payload = [IO.File]::ReadAllBytes($fixture.Archive)
if (-not [Net.WebRequest]::RegisterPrefix('https://github.com/netcrate-fixture/',[FixtureDownloadCreator]::new())) { throw 'Fixture HTTPS response registration failed.' }
$script:assertions = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Reject([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Unsafe dependency path or archive was accepted.'
}
# Independent I/O in assertions supports deep paths even in the legacy host.
function NativePath([string]$Path) { '\\?\' + [IO.Path]::GetFullPath($Path) }
function Assert-Private([string]$Path) {
    $acl = Get-Acl -LiteralPath (NativePath $Path)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow') {
            Assert ($rule.IdentityReference.Value -cin @($owner,'S-1-5-18')) 'Private fixture file has broader access.'
        }
    }
}
$expectedHash = '40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880'
foreach ($caseRoot in @($fixture.LongRoot,(Join-Path $TestRoot 'Short'))) {
    $tools = Join-Path $caseRoot 'Tools'
    $package = [pscustomobject]@{Name='Fixture';Version='1.0';SHA256=$fixture.Hash;Executable=$fixture.Relative;Url='https://github.com/netcrate-fixture/unused.package'}
    $cacheRoot = Join-Path $caseRoot ('c'*112)
    $null = [IO.Directory]::CreateDirectory((NativePath $cacheRoot))
    $cachedArchive = Join-Path $cacheRoot ($fixture.Hash + '.package')
    Assert ((Get-NetCratePackageArchive $package $cacheRoot) -ceq $cachedArchive) 'Download did not publish its ordinary cache path.'
    Assert ((Get-FileHash -LiteralPath (NativePath $cachedArchive)).Hash.ToLowerInvariant() -ceq $fixture.Hash) 'Downloaded cache bytes differ.'
    Assert ((Get-NetCratePackageArchive $package $cacheRoot) -ceq $cachedArchive) 'Verified cache was not reused at its ordinary path.'
    [IO.File]::WriteAllText((NativePath $cachedArchive),'damaged archive')
    $null = Get-NetCratePackageArchive $package $cacheRoot
    Assert ((Get-FileHash -LiteralPath (NativePath $cachedArchive)).Hash.ToLowerInvariant() -ceq $fixture.Hash) 'Damaged cache was not replaced by verified bytes.'
    Assert (@([IO.Directory]::GetFiles((NativePath $cacheRoot),'*.rejected-*')).Count -eq 1) 'Rejected cache was not preserved.'
    Assert (@([IO.Directory]::GetFiles((NativePath $cacheRoot),'*.download')).Count -eq 0) 'Download retained temporary files.'
    $destination = Expand-NetCrateDependency $fixture.Archive $package $tools
    Assert ($destination -ceq ([IO.Path]::Combine($tools,'Fixture','1.0'))) 'A native path leaked into the package interface.'
    $file = [IO.Path]::Combine($destination,$fixture.Relative.Replace('/','\'))
    if ($caseRoot -ceq $fixture.LongRoot) { Assert ($file.Length -gt 260) 'Long-path fixture did not cross the legacy limit.' }
    Assert ((Get-FileHash -LiteralPath (NativePath $file)).Hash.ToLowerInvariant() -ceq $expectedHash) 'Installed bytes differ.'
    Assert-Private $file
    Assert ((Expand-NetCrateDependency $fixture.Archive $package $tools) -ceq $destination) 'Retry changed the package location.'
    [IO.File]::WriteAllText((NativePath $file),'damaged')
    $null = Expand-NetCrateDependency $fixture.Archive $package $tools
    Assert ((Get-FileHash -LiteralPath (NativePath $file)).Hash.ToLowerInvariant() -ceq $expectedHash) 'Repair did not restore verified bytes.'
    Assert (@([IO.Directory]::GetDirectories((NativePath (Split-Path $destination)),'*.damaged-*')).Count -eq 1) 'Repair did not preserve the damaged package.'
    $record = Join-Path (Join-Path $caseRoot ('r'*112)) 'state.json'
    Write-NetCrateJson $record @{Version=1;Text='first'}
    Write-NetCrateJson $record @{Version=1;Text='second'}
    Assert ((Read-NetCrateJson $record).Text -ceq 'second') 'Long-path JSON publication failed.'
    Assert-Private $record
    Assert (@([IO.Directory]::GetFiles((NativePath (Split-Path $record)),'*.writing')).Count -eq 0) 'JSON publication retained temporary files.'
    $package.SHA256 = '0'*64
    Reject { Expand-NetCrateDependency $fixture.Archive $package (Join-Path $caseRoot 'BadHash') }
    Assert (-not [IO.Directory]::Exists((NativePath (Join-Path $caseRoot 'BadHash')))) 'Unverified archive created a destination.'
    foreach ($bad in $fixture.UnsafeArchives) {
        $package.SHA256=$bad.Hash; $package.Executable='tool.bin'
        $badRoot = Join-Path (Join-Path $caseRoot 'Unsafe') ([IO.Path]::GetFileNameWithoutExtension($bad.Path))
        Reject { Expand-NetCrateDependency $bad.Path $package $badRoot }
        Assert (-not [IO.Directory]::Exists((NativePath (Join-Path $badRoot 'Fixture/1.0')))) 'Unsafe archive was published.'
        Assert (-not [IO.File]::Exists((NativePath (Join-Path $badRoot 'escaped.txt')))) 'Traversal escaped its staging directory.'
    }
}
Assert ($fixture.Link.Length -gt 260) 'Linked ancestor fixture did not cross the legacy limit.'
Reject { Assert-NetCrateLocalPath (Join-Path $fixture.Link 'new.json') }
Reject { Write-NetCrateJson (Join-Path $fixture.Link 'new.json') @{Version=1} }
$package.SHA256=$fixture.Hash; $package.Executable=$fixture.Relative
Reject { Expand-NetCrateDependency $fixture.Archive $package $fixture.Link }
foreach ($badPath in @(
    '\\server\share\tools', '\\?\C:\tools', ($TestRoot+'\..\escape'), ($TestRoot+'\file:stream'),
    ($TestRoot+'\CON\state.json'), ($TestRoot+'\AUX.txt'), ($TestRoot+'\COM1\state.json'),
    ($TestRoot+'\CONOUT$'), ($TestRoot+'\COM'+[char]0x00b2+'\state.json')
)) {
    Reject { Assert-NetCrateLocalPath $badPath }
}
Assert ([IO.File]::ReadAllText((Join-Path $fixture.Outside 'sentinel.txt')) -ceq 'preserved') 'Linked destination bytes changed.'
Assert (@([IO.Directory]::GetFileSystemEntries($fixture.Outside)).Count -eq 1) 'A linked destination received files.'
Write-Output ('PASS: PowerShell '+$PSVersionTable.PSVersion+' '+$script:assertions+' dependency, JSON, repair, link and permission assertions.')
