#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')

function Invoke-NetCrateProcess {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 3600, [string]$OutputFile, [AllowNull()][string]$InputText = $null)
    if (-not [IO.File]::Exists($FilePath) -or -not [IO.Path]::IsPathRooted($FilePath)) { throw 'A required NetCrate tool is unavailable.' }
    $start = [Diagnostics.ProcessStartInfo]::new($FilePath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $null -ne $InputText
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -match '^(?i:RESTIC_|RCLONE_|AWS_|AZURE_|B2_|GOOGLE_|PYTHONPATH$|PYTHONHOME$|HTTPS?_PROXY$|ALL_PROXY$)') { $null = $start.Environment.Remove($key) }
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $writer = $null
    $output = [Text.StringBuilder]::new()
    if ($OutputFile) {
        $null = Assert-NetCrateLocalPath $OutputFile
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputFile))
        $stream = [IO.FileStream]::new($OutputFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
    }
    try {
        $null = $process.Start()
        $start.Environment.Clear()
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText); $process.StandardInput.Close() }
        $errors = $process.StandardError.ReadToEndAsync()
        $lineTask = $process.StandardOutput.ReadLineAsync()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $process.Kill($true); throw 'The operation timed out. Its work was retained for retry.' }
            if (-not $lineTask.IsCompleted) { Start-Sleep -Milliseconds 40; continue }
            $line = $lineTask.GetAwaiter().GetResult()
            if ($null -eq $line) { break }
            if ($writer) {
                $writer.WriteLine($line)
                if ($line -match '"message_type"\s*:\s*"summary"') { $null = $output.AppendLine($line) }
            } else {
                $null = $output.AppendLine($line)
                if ($output.Length -gt 67108864) { $process.Kill($true); throw 'The tool returned more metadata than expected.' }
            }
            $lineTask = $process.StandardOutput.ReadLineAsync()
        }
        $remaining = [Math]::Max(1, [int](($TimeoutSeconds - $watch.Elapsed.TotalSeconds) * 1000))
        if (-not $process.WaitForExit($remaining)) { $process.Kill($true); throw 'The operation timed out.' }
        if (-not $errors.Wait(5000)) { throw 'The tool did not close its diagnostic output.' }
        $diagnostic = $errors.GetAwaiter().GetResult()
        foreach ($key in $Environment.Keys) {
            if ($key -match 'PASSWORD|TOKEN|SECRET') { $diagnostic = $diagnostic.Replace([string]$Environment[$key], '[redacted]') }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.ToString(); Diagnostic = $diagnostic }
    } finally {
        if ($writer) { $writer.Dispose() }
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch [InvalidOperationException] { }
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-NetCrateProcess
