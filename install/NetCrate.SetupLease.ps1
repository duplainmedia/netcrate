# PowerShell 5.1. Runs under the public Windows interpreter, including when
# another administrator approves UAC. The command embeds this reviewed code
# and public scope only. It never loads the user's private state or runtime.
function Test-NetCrateLeaseAddress([string]$Address) {
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $ip.ToString() -cne $Address){return $false}
    $b=$ip.GetAddressBytes()
    return ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127))
}
function Get-NetCrateLeaseDescription($Binding) {
    return ('NetCrateSetup1|'+$Binding.Lease+'|'+$Binding.LocalAddress+'|'+$Binding.PeerAddress)
}
function Test-NetCrateOwnedSetupRule($Rule,[string]$InstallationId,[string]$Program) {
    $name='NetCrate-Setup-'+$InstallationId
    if(-not $Rule -or $Rule.Name -cne $name -or $Rule.Group -cne $name -or $Rule.Direction -ne 'Inbound' -or $Rule.Action -ne 'Allow'){return $false}
    $parts=$Rule.Description -split '\|'
    if($parts.Length -ne 4 -or $parts[0] -cne 'NetCrateSetup1' -or $parts[1] -cnotmatch '^[a-f0-9]{32}$' -or
        -not (Test-NetCrateLeaseAddress $parts[2]) -or -not (Test-NetCrateLeaseAddress $parts[3]) -or $parts[2] -ceq $parts[3]){return $false}
    $address=$Rule | Get-NetFirewallAddressFilter
    $port=$Rule | Get-NetFirewallPortFilter
    $app=$Rule | Get-NetFirewallApplicationFilter
    return ((@($address.LocalAddress) -join ',') -ceq $parts[2] -and (@($address.RemoteAddress) -join ',') -ceq $parts[3] -and
        (@($port.LocalPort) -join ',') -ceq '8201' -and (@($port.RemotePort) -join ',') -ceq 'Any' -and $port.Protocol -eq 'TCP' -and $app.Program -ieq $Program)
}
function Open-NetCrateSetupRule($Binding) {
    $name='NetCrate-Setup-'+$Binding.InstallationId
    $existing=Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if($existing) {
        if(-not (Test-NetCrateOwnedSetupRule $existing $Binding.InstallationId $Binding.Program)){throw 'A different rule uses the setup name.'}
        Remove-NetFirewallRule -InputObject $existing
    }
    $null=New-NetFirewallRule -Name $name -DisplayName 'NetCrate temporary private setup' -Group $name -Description (Get-NetCrateLeaseDescription $Binding) -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8201 -LocalAddress $Binding.LocalAddress -RemoteAddress $Binding.PeerAddress -Program $Binding.Program -Profile Any
}
function Close-NetCrateSetupRule($Binding) {
    $name='NetCrate-Setup-'+$Binding.InstallationId
    $owned=Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if($owned -and $owned.Description -ceq (Get-NetCrateLeaseDescription $Binding) -and (Test-NetCrateOwnedSetupRule $owned $Binding.InstallationId $Binding.Program)){Remove-NetFirewallRule -InputObject $owned}
}
function Test-NetCrateIndependentGuardian {
    if(-not ('NetCrate.LeaseJob' -as [type])){
        Add-Type -Name LeaseJob -Namespace NetCrate -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll",SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool inJob);'
    }
    $self=[Diagnostics.Process]::GetCurrentProcess()
    try {
        $inJob=$false
        return ([NetCrate.LeaseJob]::IsProcessInJob($self.Handle,[IntPtr]::Zero,[ref]$inJob) -and -not $inJob)
    } finally {$self.Dispose()}
}
function Assert-NetCrateGuardianProgram($Parent) {
    # Alternate administrators may lack direct read access to the installing
    # account's Engine. Impersonate only to hash the live helper's executable.
    if(-not ('NetCrate.LeaseImage' -as [type])){
        Add-Type -Name LeaseImage -Namespace NetCrate -MemberDefinition '
            [System.Runtime.InteropServices.DllImport("advapi32.dll",SetLastError=true)]
            static extern bool OpenProcessToken(IntPtr process,uint access,out Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token);
            public static string Hash(System.Diagnostics.Process process){
                string path=process.MainModule.FileName;
                Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token;
                if(!OpenProcessToken(process.Handle,10,out token))throw new System.ComponentModel.Win32Exception();
                using(token)
                using(System.Security.Principal.WindowsIdentity.Impersonate(token.DangerousGetHandle()))
                using(var input=new System.IO.FileStream(path,System.IO.FileMode.Open,System.IO.FileAccess.Read,System.IO.FileShare.Read))
                using(var sha=System.Security.Cryptography.SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(input)).Replace("-","");
            }'
    }
    if([NetCrate.LeaseImage]::Hash($Parent) -cne '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'){throw 'The active helper program differs from its pinned release.'}
}
function Invoke-NetCrateLeaseGuardian($Binding) {
    $ErrorActionPreference='Stop'
    $env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
    if(-not (Test-NetCrateIndependentGuardian)){throw 'The elevated guardian must run independently of the desktop job.'}
    if($Binding.InstallationId -cnotmatch '^[0-9a-f]{32}$' -or $Binding.Lease -cnotmatch '^[0-9a-f]{32}$' -or
        -not (Test-NetCrateLeaseAddress $Binding.LocalAddress) -or -not (Test-NetCrateLeaseAddress $Binding.PeerAddress) -or
        $Binding.LocalAddress -ceq $Binding.PeerAddress){throw 'Invalid setup scope.'}
    $assigned=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object OperationalStatus -EQ Up |
        ForEach-Object {$_.GetIPProperties().UnicastAddresses} | ForEach-Object {$_.Address.ToString()})
    if($Binding.LocalAddress -cnotin $assigned){throw 'The selected private address is offline.'}
    $parent=[Diagnostics.Process]::GetProcessById([int]$Binding.HelperPid)
    $null=$parent.Handle
    if($parent.StartTime.ToUniversalTime().Ticks.ToString() -cne $Binding.StartTicks -or $parent.MainModule.FileName -ine $Binding.Program -or
        $Binding.Program -notmatch '^[A-Za-z]:\\[^"\x00-\x1f]*\\Tools\\PowerShell\\7\.6\.5\\pwsh\.exe$'){throw 'The setup helper identity changed.'}
    Assert-NetCrateGuardianProgram $parent
    $name='NetCrate-Setup-'+$Binding.InstallationId
    $mutex=[Threading.Mutex]::new($false,('Global\'+$name+'-Guardian'))
    $held=$false;$created=$false;$pipe=$null
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        try {$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Another setup lease is active.'}
        Open-NetCrateSetupRule $Binding
        $created=$true
        $rule=Get-NetFirewallRule -Name $name
        if(-not (Test-NetCrateOwnedSetupRule $rule $Binding.InstallationId $Binding.Program)){throw 'The setup firewall scope differs.'}
        $pipe=[IO.Pipes.NamedPipeClientStream]::new('.','nc-lease-'+$Binding.Lease,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Identification)
        $pipe.Connect(5000);$pipe.WriteByte(1)
        $one=New-Object byte[] 1
        $stop=$pipe.ReadAsync($one,0,1)
        while(-not $stop.IsCompleted -and -not $parent.WaitForExit(200) -and $watch.Elapsed.TotalMinutes -lt 15){}
    } finally {
        try {
            if($created) {
                Close-NetCrateSetupRule $Binding
            }
        } finally {
            if($pipe){$pipe.Dispose()}; if($held){$mutex.ReleaseMutex()}; $mutex.Dispose(); $parent.Dispose()
        }
    }
}
