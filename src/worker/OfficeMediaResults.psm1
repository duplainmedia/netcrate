# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference = 'Stop'
function Invoke-OfficeMediaResult {
    param([Parameter(Mandatory)][ValidateSet('init','backup','snapshots','restore','check')][string]$Command,[string[]]$Arguments=@(),[switch]$AllowInitialize,[ValidateRange(0,3600)][int]$NativeTimeoutSeconds=0)
    if ($Command -eq 'init' -and -not $AllowInitialize) { throw 'Initialization is setup-only.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.Name -ine 'WORKER-PC\worker-user') { throw 'Run office requests as WORKER-PC\worker-user.' }
    $record=Get-Content -LiteralPath "C:\ProgramData\NetCrate\Office\results.dpapi.json" -Raw | ConvertFrom-Json
    if ($record.ProtectedForUserSid -ne $identity.User.Value -or $record.Repository -ne 'rest:https://backup.example:8000/sample-user/office-media-results/') { throw 'Results credential identity mismatch.' }
    $secure=$null; $transportSecure=$null; $process=$null; $plainBytes=$null; $worker=$null
    try {
        $machinePath="C:\ProgramData\NetCrate\Office\worker.dpapi"
        if(Test-Path -LiteralPath $machinePath){
            $plainBytes=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($machinePath),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
            $worker=[Text.Encoding]::UTF8.GetString($plainBytes)|ConvertFrom-Json
            if($worker.Repository -ne $record.Repository){throw 'Worker repository mismatch.'}
            $secure=ConvertTo-SecureString $worker.ResultsPassword -AsPlainText -Force
            $transportSecure=ConvertTo-SecureString $worker.RestPassword -AsPlainText -Force
            $transport=@{User=$worker.RestUsername}
        }else{
            $transport=Get-Content -LiteralPath 'C:\ProgramData\NetCrate\Backup\Credentials\transport.json' -Raw | ConvertFrom-Json
            $secure=ConvertTo-SecureString $record.PasswordDpapi
            $transportSecure=ConvertTo-SecureString $transport.PasswordDpapi
        }
        $psi=[Diagnostics.ProcessStartInfo]::new('C:\Program Files\NetCrate\Backup\restic.exe')
        $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
        $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
        foreach($name in @($psi.Environment.Keys)){if($name -like 'RESTIC_*'){$null=$psi.Environment.Remove($name)}}
        foreach($arg in @('--repo',$record.Repository,'--cache-dir',"C:\ProgramData\NetCrate\Office\ResultsCache",'--json',$Command)+$Arguments){$psi.ArgumentList.Add($arg)}
        $psi.Environment['RESTIC_PASSWORD']=[Net.NetworkCredential]::new('',$secure).Password
        $psi.Environment['RESTIC_REST_USERNAME']=$transport.User
        $psi.Environment['RESTIC_REST_PASSWORD']=[Net.NetworkCredential]::new('',$transportSecure).Password
        $process=[Diagnostics.Process]::new(); $process.StartInfo=$psi
        $null=$process.Start(); $psi.Environment.Clear()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if($NativeTimeoutSeconds -gt 0){
            if(-not $process.WaitForExit($NativeTimeoutSeconds*1000)){$process.Kill($true);$process.WaitForExit();throw 'Progress transport timeout; latest status retained; credentials suppressed.'}
        }else{$process.WaitForExit()}
        $text=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw "Results operation $Command failed (exit $($process.ExitCode)); credentials suppressed."}
        return $text
    } finally {
        if($secure){$secure.Dispose()};if($transportSecure){$transportSecure.Dispose()}
        if($process){$process.Dispose()};if($plainBytes){[Array]::Clear($plainBytes,0,$plainBytes.Length)};$record=$null;$transport=$null;$diagnostic=$null;$worker=$null
    }
}
Export-ModuleMember -Function Invoke-OfficeMediaResult
