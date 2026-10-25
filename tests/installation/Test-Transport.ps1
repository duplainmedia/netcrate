param([Parameter(Mandatory)][string]$TestRoot, [Parameter(Mandatory)][string]$ResticExe,
    [Parameter(Mandatory)][string]$PythonExe, [Parameter(Mandatory)][string]$RestServerExe)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../../install/NetCrate.Engine.psm1" -Force
Import-Module "$PSScriptRoot/../../install/NetCrate.Repositories.psm1"
foreach ($name in @('Configuration', 'Credentials', 'Workflow')) { Import-Module "$PSScriptRoot/../../src/shared/NetCrate.$name.psm1" }
$worker = Join-Path $TestRoot 'Server'; $source = Join-Path $TestRoot 'Editing'
$storage = Join-Path $TestRoot 'Storage'; $null = New-Item -ItemType Directory -Path $storage
$null = New-NetCrateIdentity $worker ('3' * 32) Worker
$null = New-NetCrateIdentity $source ('4' * 32) Source
$bindings = Initialize-NetCrateRepositories $worker $storage $ResticExe
$tools = @{ Python = $PythonExe; Restic = $ResticExe }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$endpoint = Initialize-NetCrateEndpoint $worker '127.0.0.1' '127.0.0.1' $tools -Fixture -Port $port
Write-Output 'Created disposable repository and TLS identity.'
[IO.File]::WriteAllText("$source/server.pem", $endpoint.Certificate)
Protect-NetCrateRecord $source 'paired-secrets' (Get-NetCrateRepositorySecrets $worker)
Write-Output 'Protected synthetic transport credentials.'
$settings = [pscustomobject]@{ Role = 'Source'; Tools = $tools; Repositories = @{
    Primary = @{ Uri = "rest:https://127.0.0.1:$port/editing/originals/"; Id = $bindings.PrimaryId }
    Results = @{ Uri = "rest:https://127.0.0.1:$port/editing/results/"; Id = $bindings.ResultsId } } }
$start = [Diagnostics.ProcessStartInfo]::new($RestServerExe); $start.UseShellExecute = $false; $start.CreateNoWindow = $true
$start.RedirectStandardError = $true; $start.RedirectStandardOutput = $true
foreach ($arg in (Get-NetCrateServerArguments $worker)) { $start.ArgumentList.Add($arg) }
$process = [Diagnostics.Process]::Start($start)
Write-Output 'Started fixture server.'
$diagnostics = $process.StandardError.ReadToEndAsync(); $output = $process.StandardOutput.ReadToEndAsync()
try {
    $connected = $false
    for ($i=0; $i -lt 3; $i++) {
        if ($process.HasExited) { throw ('The fixture server exited: ' + $diagnostics.GetAwaiter().GetResult() + $output.GetAwaiter().GetResult()) }
        try { $config = Invoke-WorkflowRestic $source $settings Primary @('cat', 'config') | ConvertFrom-Json; $connected = $true; break } catch { Start-Sleep -Milliseconds 150 }
    }
    if (-not $connected -or $config.id -cne $bindings.PrimaryId) { throw 'The authenticated HTTPS endpoint did not return its pinned repository.' }
    $result = Invoke-WorkflowRestic $source $settings Results @('cat', 'config') | ConvertFrom-Json
    if ($result.id -cne $bindings.ResultsId) { throw 'The result repository identity changed.' }
    [IO.File]::WriteAllText("$source/server.pem", 'invalid certificate')
    $rejected = $false; try { Invoke-WorkflowRestic $source $settings Primary @('cat', 'config') | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'An untrusted TLS certificate was accepted.' }
    Write-Output 'PASS: actual authenticated TLS connection, separate repository identities and certificate rejection.'
} finally {
    if (-not $process.HasExited) { $process.Kill($true) }; $process.WaitForExit(); $process.Dispose()
    [IO.File]::WriteAllText("$worker/transport-test.log", $diagnostics.GetAwaiter().GetResult())
}
