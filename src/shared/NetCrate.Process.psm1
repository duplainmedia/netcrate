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
    if ($start.RedirectStandardInput) { $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false) }
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
        # Read both pipes in fixed character chunks: neither an unterminated line nor
        # an undrained diagnostic pipe may allocate an unbounded managed string.
        $maximumOutput=67108864; $maximumDiagnostic=1048576; $maximumLogLine=1048576
        $diagnostics=[Text.StringBuilder]::new();$pending=[Text.StringBuilder]::new()
        $stdoutBuffer=[char[]]::new(8192);$stderrBuffer=[char[]]::new(8192)
        $stdout=$process.StandardOutput.ReadAsync($stdoutBuffer,0,$stdoutBuffer.Length)
        $stderr=$process.StandardError.ReadAsync($stderrBuffer,0,$stderrBuffer.Length)
        $stdin=$null
        if($null -ne $InputText){$stdin=$process.StandardInput.WriteAsync($InputText)}
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while($null -ne $stdout -or $null -ne $stderr -or -not $process.HasExited) {
            if($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw 'The operation timed out. Its work was retained for retry.'}
            $progressed=$false
            if($null -ne $stdin -and $stdin.IsCompleted){$null=$stdin.GetAwaiter().GetResult();$process.StandardInput.Close();$stdin=$null}
            if($null -ne $stdout -and $stdout.IsCompleted) {
                $count=$stdout.GetAwaiter().GetResult();$progressed=$true
                if($count -eq 0){$stdout=$null}
                else {
                    $chunk=[string]::new($stdoutBuffer,0,$count)
                    if($writer) {
                        $writer.Write($chunk)
                        $parts=$chunk.Split("`n")
                        for($i=0;$i -lt $parts.Length;$i++) {
                            if($pending.Length+$parts[$i].Length -gt $maximumLogLine){throw 'The tool returned a line exceeding the metadata limit.'}
                            $null=$pending.Append($parts[$i])
                            if($i -lt $parts.Length-1) {
                                if($pending.ToString() -match '"message_type"\s*:\s*"summary"') {
                                    if($output.Length+$pending.Length+1 -gt $maximumOutput){throw 'The tool returned more metadata than expected.'}
                                    $null=$output.AppendLine($pending.ToString().TrimEnd("`r"))
                                }
                                $null=$pending.Clear()
                            }
                        }
                    } else {
                        if($output.Length+$count -gt $maximumOutput){throw 'The tool returned more metadata than expected.'}
                        $null=$output.Append($chunk)
                    }
                    $stdout=$process.StandardOutput.ReadAsync($stdoutBuffer,0,$stdoutBuffer.Length)
                }
            }
            if($null -ne $stderr -and $stderr.IsCompleted) {
                $count=$stderr.GetAwaiter().GetResult();$progressed=$true
                if($count -eq 0){$stderr=$null}
                else {
                    if($diagnostics.Length+$count -gt $maximumDiagnostic){throw 'The tool returned more diagnostic output than expected.'}
                    $null=$diagnostics.Append($stderrBuffer,0,$count)
                    $stderr=$process.StandardError.ReadAsync($stderrBuffer,0,$stderrBuffer.Length)
                }
            }
            if(-not $progressed) {
                $waiting=[Collections.Generic.List[Threading.Tasks.Task]]::new()
                if($null -ne $stdout){$waiting.Add($stdout)}
                if($null -ne $stderr){$waiting.Add($stderr)}
                if($waiting.Count){$null=[Threading.Tasks.Task]::WaitAny($waiting.ToArray(),50)}
                else{$null=$process.WaitForExit(10)}
            }
        }
        if($writer -and $pending.Length -and $pending.ToString() -match '"message_type"\s*:\s*"summary"') {
            if($output.Length+$pending.Length -gt $maximumOutput){throw 'The tool returned more metadata than expected.'}
            $null=$output.AppendLine($pending.ToString())
        }
        $diagnostic=$diagnostics.ToString()
        foreach ($key in $Environment.Keys) {
            if ($key -match 'PASSWORD|TOKEN|SECRET' -and [string]$Environment[$key]) { $diagnostic = $diagnostic.Replace([string]$Environment[$key], '[redacted]') }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.ToString(); Diagnostic = $diagnostic }
    } finally {
        if ($writer) { $writer.Dispose() }
        try { if (-not $process.HasExited) { $process.Kill($true); $null=$process.WaitForExit(5000) } } catch [InvalidOperationException] { }
        $process.Dispose()
    }
}

Export-ModuleMember -Function Invoke-NetCrateProcess
