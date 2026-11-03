param([Parameter(Mandatory)][string]$Repo,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
# Compile the exact packaged bytes into the desktop's trust boundary at build time.
$inputs=@(
    'install/Invoke-NetworkSetupHost.ps1','install/NetCrate.NetworkSetup.psm1','install/NetCrate.SetupWire.cs',
    'install/NetCrate.Engine.psm1','install/NetCrate.SetupPairing.ps1','install/NetCrate.Dependencies.psm1',
    'install/NetCrate.Repositories.psm1','install/Set-NetCrateFirewall.ps1','install/dependencies.json'
)
foreach($name in @('Configuration','Credentials','Pairing','Protocol','Process','Workflow')){$inputs+="src/shared/NetCrate.$name.psm1"}
foreach($name in @('Schedule','Queue','RemoteResult')){$inputs+="src/shared/NetCrate.$name.ps1"}
$lines=foreach($relative in $inputs){
    (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Repo $relative)).Hash+' '+$relative
}
[IO.File]::WriteAllLines($OutputPath,[string[]]$lines,[Text.UTF8Encoding]::new($false))
[IO.Path]::GetFullPath($OutputPath)
