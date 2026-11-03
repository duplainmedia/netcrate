#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Configuration.psm1')
Import-Module (Join-Path $PSScriptRoot '../../install/NetCrate.Engine.psm1') -DisableNameChecking
if(-not ('NetCrate.EndpointJob' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace NetCrate {
 public sealed class EndpointJob : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcessUserTimeLimit,PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass,SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct Counters { public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic BasicLimitInformation; public Counters IoInfo; public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int type,ref Extended info,uint length);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  IntPtr handle;
  public EndpointJob(Process process) {
   handle=CreateJobObject(IntPtr.Zero,null);if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
   try {var info=new Extended();info.BasicLimitInformation.LimitFlags=0x2000;
    if(!SetInformationJobObject(handle,9,ref info,(uint)Marshal.SizeOf(typeof(Extended))) || !AssignProcessToJobObject(handle,process.Handle))throw new Win32Exception(Marshal.GetLastWin32Error());
   } catch {Dispose();throw;}
  }
  public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}GC.SuppressFinalize(this);}
  ~EndpointJob(){Dispose();}
 }
}
"@
}
function Start-NetCrateOwnedEndpoint($State,[string]$Root,$Settings) {
    if($State.Process -and -not $State.Process.HasExited){return}
    if($State.Process){$State.Process.Dispose();$State.Process=$null}
    if($State.Job){$State.Job.Dispose();$State.Job=$null}
    $start=[Diagnostics.ProcessStartInfo]::new($Settings.Tools.RestServer)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($argument in (Get-NetCrateServerArguments $Root)){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($start)
    try {
        $job=[NetCrate.EndpointJob]::new($process);$State.Process=$process;$State.Job=$job
        $endpoint=Read-NetCrateJson ([IO.Path]::Combine($Root,'endpoint.json')) -MaximumBytes 16384
        $address=[Net.IPAddress]::Parse($endpoint.Address);$watch=[Diagnostics.Stopwatch]::StartNew();$ready=$false
        while($watch.Elapsed.TotalSeconds -lt 15){
            if($process.HasExited){throw 'The private endpoint exited during startup.'}
            $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -eq $endpoint.Port -and ($_.Address.Equals($address) -or $_.Address.Equals([Net.IPAddress]::Any) -or $_.Address.Equals([Net.IPAddress]::IPv6Any))})
            if($listeners.Count){Start-Sleep -Milliseconds 500;if(-not $process.HasExited){$ready=$true;break}}
            Start-Sleep -Milliseconds 100
        }
        if(-not $ready){throw 'The private endpoint did not start listening.'}
    } catch {
        if(-not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose();$State.Process=$null
        if($State.Job){$State.Job.Dispose();$State.Job=$null}
        throw 'The private endpoint could not be safely started.'
    }
}
function Stop-NetCrateOwnedEndpoint($State,[string]$Root) {
    $endpoint=Read-NetCrateJson ([IO.Path]::Combine($Root,'endpoint.json')) -MaximumBytes 16384
    if($State.Process){
        if(-not $State.Process.HasExited){$State.Process.Kill($true);if(-not $State.Process.WaitForExit(30000)){throw 'The private endpoint did not stop.'}}
        $State.Process.Dispose();$State.Process=$null
    }
    if($State.Job){$State.Job.Dispose();$State.Job=$null}
    $address=[Net.IPAddress]::Parse($endpoint.Address)
    $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -eq $endpoint.Port -and ($_.Address.Equals($address) -or $_.Address.Equals([Net.IPAddress]::Any) -or $_.Address.Equals([Net.IPAddress]::IPv6Any))})
    if($listeners.Count){throw 'The private endpoint is still listening. Storage maintenance was not started.'}
}
Export-ModuleMember -Function Start-NetCrateOwnedEndpoint, Stop-NetCrateOwnedEndpoint
