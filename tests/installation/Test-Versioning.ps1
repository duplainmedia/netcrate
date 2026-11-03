param([string]$TestRoot = $env:TEMP)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$parent = (Resolve-Path -LiteralPath $TestRoot).Path.TrimEnd('\')
$fixture = Join-Path $parent ('NetCrate-Version-' + [guid]::NewGuid().ToString('N'))
if ([IO.Path]::GetDirectoryName($fixture) -cne $parent) { throw 'Unsafe fixture path.' }
function Check($condition, $message) { if (-not $condition) { throw $message } }
function Reject([scriptblock]$action, [string]$message) { $rejected = $false; try { & $action | Out-Null } catch { $rejected = $true }; Check $rejected $message }
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repo 'install') -Destination $fixture -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'build') -Destination $fixture -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION'), (Join-Path $repo 'CHANGELOG.md') -Destination $fixture
    Import-Module (Join-Path $fixture 'install/NetCrate.Version.psm1') -Force
    $version = Get-NetCrateVersion $fixture
    $exe = Join-Path $fixture 'build/NetCrate.exe'
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
    Check ($asm.GetName().Version.ToString() -ceq $version.Windows) 'Assembly version differs.'
    Check ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion -ceq $version.Windows) 'File version differs.'
    $info = $asm.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute], $false)
    Check ($info.Count -eq 1 -and $info[0].InformationalVersion -ceq $version.Product) 'Informational version differs.'
    Check ((Get-NetCrateManifestVersion $exe) -ceq $version.Windows) 'Embedded manifest differs.'
    Assert-NetCrateTag $version ('v' + $version.Product)
    Reject { Assert-NetCrateTag $version 'v0.1.2' } 'Mismatched tag accepted.'
    & (Join-Path $fixture 'install/Build-Package.ps1') | Out-Null
    $zip = Join-Path $fixture "build/NetCrate-$($version.Product)-Windows-x64.zip"
    $alias = Join-Path $fixture 'build/NetCrate-Windows-x64.zip'
    Check ((Get-FileHash $zip).Hash -ceq (Get-FileHash $alias).Hash) 'Compatibility archive differs.'
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($name in @('VERSION','CHANGELOG.md','NetCrate.exe','install/NetCrate.Version.psm1')) {
            Check ($null -ne $archive.GetEntry($name)) "Archive missing $name."
        }
        $entry = $archive.GetEntry('VERSION'); $reader = [IO.StreamReader]::new($entry.Open())
        try { Check ($reader.ReadToEnd().Trim() -ceq $version.Product) 'Archive VERSION differs.' } finally { $reader.Dispose() }
        $entry = $archive.GetEntry('CHANGELOG.md'); $reader = [IO.StreamReader]::new($entry.Open())
        try { Check ($reader.ReadToEnd() -ceq [IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md'))) 'Archive changelog differs.' } finally { $reader.Dispose() }
        $entry = $archive.GetEntry('NetCrate.exe'); $stream = $entry.Open(); $hasher = [Security.Cryptography.SHA256]::Create()
        try { $zipHash = [Convert]::ToHexString($hasher.ComputeHash($stream)); Check ($zipHash -ceq (Get-FileHash $exe).Hash) 'Archived executable differs.' } finally { $stream.Dispose(); $hasher.Dispose() }
    } finally { $archive.Dispose() }
    $explicit = Join-Path $fixture 'custom.zip'
    & (Join-Path $fixture 'install/Build-Package.ps1') -Destination $explicit | Out-Null
    Check (Test-Path -LiteralPath $explicit) 'Explicit destination missing.'
    $versionFile = Join-Path $fixture 'VERSION'
    [IO.File]::WriteAllText($versionFile, '0.1.2')
    Reject { & (Join-Path $fixture 'install/Build-Package.ps1') -Destination (Join-Path $fixture 'stale.zip') } 'Stale executable accepted.'
    foreach ($invalid in @('01.1.1','1.2','1.2.3.4','65535.1.1','999999999999999999.1.1')) {
        [IO.File]::WriteAllText($versionFile, $invalid)
        Reject { & (Join-Path $fixture 'install/Build-Package.ps1') -Destination (Join-Path $fixture 'invalid.zip') } "Invalid version accepted: $invalid"
    }
    [IO.File]::WriteAllText($versionFile, $version.Product)
    $badManifest = Join-Path $fixture 'bad.manifest'
    [IO.File]::WriteAllText($badManifest, '<?xml version="1.0" encoding="UTF-8"?><assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><assemblyIdentity version="0.1.2.0" processorArchitecture="amd64" name="NetCrate" type="win32"/></assembly>')
    $badSource = Join-Path $fixture 'bad.cs'
    [IO.File]::WriteAllText($badSource, "using System.Reflection; [assembly:AssemblyVersion(`"$($version.Windows)`")] [assembly:AssemblyFileVersion(`"$($version.Windows)`")] [assembly:AssemblyInformationalVersion(`"$($version.Product)`")] class Bad { static void Main() {} }")
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 "/out:$exe" "/win32manifest:$badManifest" $badSource
    Check ($LASTEXITCODE -eq 0) 'Bad-manifest fixture compilation failed.'
    Check ((Get-NetCrateManifestVersion $exe) -ceq '0.1.2.0') 'Bad manifest fixture not embedded.'
    Reject { & (Join-Path $fixture 'install/Build-Package.ps1') -Destination (Join-Path $fixture 'bad.zip') } 'Mismatched embedded manifest accepted.'
    Import-Module (Join-Path $repo 'install/NetCrate.Engine.psm1') -Force
    $installed = Join-Path $fixture 'installed'; New-Item -ItemType Directory $installed | Out-Null
    Copy-NetCrateApplication (Join-Path $repo 'build') $installed
    foreach ($name in @('VERSION','CHANGELOG.md')) { Check (Test-Path -LiteralPath (Join-Path $installed $name)) "Installed copy missing $name." }
    $legacy = Join-Path $fixture 'legacy'; $legacyInstalled = Join-Path $fixture 'legacy-installed'
    New-Item -ItemType Directory $legacy, $legacyInstalled | Out-Null
    Copy-Item -LiteralPath $exe -Destination $legacy
    Copy-NetCrateApplication $legacy $legacyInstalled
    Check (Test-Path -LiteralPath (Join-Path $legacyInstalled 'NetCrate.exe')) 'Legacy application copy failed.'
    Write-Output 'PASS: compiled version metadata, packaging, tags, stale and malformed versions, embedded manifest, and installed documents.'
} finally {
    if (([IO.Path]::GetDirectoryName($fixture) -ceq $parent) -and ([IO.Path]::GetFileName($fixture) -match '^NetCrate-Version-[a-f0-9]{32}$')) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
