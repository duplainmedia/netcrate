#requires -Version 7.4
param([Parameter(Mandatory)][ValidatePattern('^nc-setup-[a-f0-9]{32}$')][string]$PipeName,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
$context=$null;$pipe=$null
try {
    Import-Module (Join-Path $PSScriptRoot 'NetCrate.NetworkSetup.psm1') -DisableNameChecking
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,'InOut','Asynchronous',[Security.Principal.TokenImpersonationLevel]::Identification)
    $pipe.Connect(5000)
    while($pipe.IsConnected) {
        $command=[NetCrate.SetupWire]::ReadOwnerCommandAsync($pipe)
        while(-not $command.IsCompleted){
            if($context -and $context.Active){
                if([datetime]::UtcNow -ge $context.Until -or ($context.GuardianClosed -and $context.GuardianClosed.IsCompleted)){Stop-NetCrateNetworkSession $context}
                elseif($context.Listener -and $context.Listener.Pending()){$null=Invoke-NetCrateNetworkExchange $context -ReceiveOnly}
            }
            Start-Sleep -Milliseconds 100
        }
        $request=$command.GetAwaiter().GetResult() | ConvertFrom-Json
        try {
            if(-not $context){$context=New-NetCrateNetworkContext $Root $request.State}
            $context.OwnerPipe=$pipe
            $context.LeaseId=$request.Lease
            switch -CaseSensitive ($request.Action) {
                'Inspect' {
                    $status=Get-NetCrateNetworkStatus $context
                    $discovery=Get-NetCrateDiscovery
                    $status.Peers=$discovery.Peers
                    if(-not $status.LocalAddress){$status.LocalAddress=$discovery.LocalAddress}
                }
                'Start' {Start-NetCrateNetworkSession $context $request.Request;$status=Get-NetCrateNetworkStatus $context}
                'Poll' {$status=Invoke-NetCrateNetworkExchange $context}
                'Reset' {$status=Reset-NetCrateNetworkPending $context}
                'Confirm' {$status=Confirm-NetCrateNetworkSession $context $request.Code}
                default {throw 'Unknown setup command.'}
            }
        } catch {
            # Pipe results are a closed, nonsecret status shape. Never forward
            # generic exceptions from crypto, repository tools or peer input.
            if($context -and $request.Action -cne 'Start'){Stop-NetCrateNetworkSession $context}
            $message=switch ($request.Action) {
                'Start' {'Check both private IPv4 addresses, the selected peer and the Windows firewall approval. If replacing a pending identity, choose Start again.'}
                'Confirm' {'The current codes or identity could not be confirmed. Check the other computer and retry the same connection.'}
                'Poll' {'The exchange could not be verified. Check both computers, the selected private addresses and the certificate, then retry.'}
                'Reset' {'Setup could not replace this pairing. Check for an active lease or a completed connection on either computer.'}
                default {'Check the prepared installation and private network.'}
            }
            if($request.Action -ceq 'Start' -and $context -and $context.Active){
                $status=Get-NetCrateNetworkStatus $context
                $status.Message='The requested start was refused. The original peer and lease are still active.'
            } else {
                $status=@{Phase='Failed';Message=$message;ComparisonCode='';LocalAddress='';PeerAddress='';Peers=@()}
            }
        }
        [NetCrate.SetupWire]::Write($pipe,($status|ConvertTo-Json -Depth 6 -Compress),15000)
    }
} catch {exit 1}
finally {if($context){Stop-NetCrateNetworkSession $context};if($pipe){$pipe.Dispose()}}
