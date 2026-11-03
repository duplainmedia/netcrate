#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('Configuration', 'Credentials', 'Pairing', 'Protocol', 'Process', 'Workflow')) {
    Import-Module (Join-Path $PSScriptRoot ('../src/shared/NetCrate.' + $name + '.psm1'))
}
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Dependencies.psm1')
Import-Module (Join-Path $PSScriptRoot 'NetCrate.Repositories.psm1')

function Get-NetCratePrivateAddress {
    $addresses = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq 'Up' -and ($_.Name -match 'NetBird|wt0' -or $_.Description -match 'NetBird')
    } | ForEach-Object { $_.GetIPProperties().UnicastAddresses } | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() })
    if ($addresses.Count -ne 1) { throw 'Open NetBird, sign in on both computers with the same account, then try again.' }
    Assert-NetCratePrivateAddress $addresses[0]
    return $addresses[0]
}

function Assert-NetCratePrivateAddress([string]$Address) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { throw 'A private IPv4 address is required.' }
    $b = $ip.GetAddressBytes()
    if (-not ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127))) { throw 'Use the private network address shown in NetBird.' }
}

function Resolve-NetCrateNetworkAddress($State) {
    if (-not [string]::IsNullOrWhiteSpace($State.NetworkAddress)) {
        Assert-NetCratePrivateAddress $State.NetworkAddress
        $local = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object OperationalStatus -EQ Up |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } | ForEach-Object { $_.Address.ToString() })
        if ($State.NetworkAddress -cnotin $local) { throw 'This private address is not active on this computer. Connect your VPN or check the address, then try again.' }
        return $State.NetworkAddress
    }
    return Get-NetCratePrivateAddress
}

function Initialize-NetCrateEndpoint {
    param([string]$Root, [string]$Address, [string]$SourceAddress, $Tools, [switch]$Fixture, [int]$Port = 8200)
    if (-not $Fixture) { Assert-NetCratePrivateAddress $Address; Assert-NetCratePrivateAddress $SourceAddress; if ($Port -ne 8200) { throw 'Unsupported backup port.' } }
    elseif ($Address -cne '127.0.0.1' -or $SourceAddress -cne '127.0.0.1') { throw 'Fixtures must use loopback.' }
    $owner = Get-NetCrateOwner $Root
    $path = [IO.Path]::Combine($Root, 'endpoint.json')
    if ([IO.File]::Exists($path)) {
        $endpoint = Read-NetCrateJson $path
        if ($endpoint.Address -cne $Address -or $endpoint.SourceAddress -cne $SourceAddress) { throw 'The private network address changed. Existing keys were preserved. Reconnect NetBird before trying again.' }
        return $endpoint
    }
    $null = Set-NetCratePrivateDirectory ([IO.Path]::Combine($Root, 'TLS'))
    $keyPath = [IO.Path]::Combine($Root, 'Secrets', 'tls-identity.json')
    if ([IO.File]::Exists($keyPath)) { $tls = Unprotect-NetCrateRecord $Root 'tls-identity' }
    else {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=NetCrate ' + $owner.InstallationId,
                $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new(); $san.AddIpAddress([Net.IPAddress]::Parse($Address))
            $request.CertificateExtensions.Add($san.Build())
            $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
            $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(5))
            try { $tls = @{ Address = $Address; Certificate = $cert.ExportCertificatePem(); PrivateKey = $rsa.ExportPkcs8PrivateKeyPem() } }
            finally { $cert.Dispose() }
            Protect-NetCrateRecord $Root 'tls-identity' $tls
        } finally { $rsa.Dispose() }
    }
    if ($tls.Address -cne $Address) { throw 'The saved certificate uses another private address.' }
    [IO.File]::WriteAllText([IO.Path]::Combine($Root, 'TLS', 'server.pem'), $tls.Certificate)
    [IO.File]::WriteAllText([IO.Path]::Combine($Root, 'TLS', 'server-key.pem'), $tls.PrivateKey)
    $secret = Get-NetCrateRepositorySecrets $Root
    $hashed = Invoke-NetCrateProcess -FilePath $Tools.Python -Arguments @('-I', '-c', 'import bcrypt,sys; print(bcrypt.hashpw(sys.stdin.buffer.read(),bcrypt.gensalt(rounds=12)).decode())') -InputText $secret.TransportPassword
    if ($hashed.ExitCode -ne 0 -or $hashed.Output.Trim() -notmatch '^\$2b\$12\$') { throw 'The private backup login could not be created.' }
    [IO.File]::WriteAllText([IO.Path]::Combine($Root, 'TLS', 'htpasswd'), 'editing:' + $hashed.Output.Trim() + "`n")
    $endpoint = [pscustomobject]@{ Version = 1; Address = $Address; SourceAddress = $SourceAddress; Port = $Port
        CertificateSHA256 = (Get-NetCrateHash $tls.Certificate); Certificate = $tls.Certificate }
    Write-NetCrateJson $path $endpoint
    return $endpoint
}

function Get-NetCrateServerArguments($Root) {
    $endpoint = Read-NetCrateJson ([IO.Path]::Combine($Root, 'endpoint.json'))
    $repos = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
    return @('--path', $repos.RepositoryRoot, '--listen', ($endpoint.Address + ':' + $endpoint.Port), '--private-repos', '--append-only',
        '--htpasswd-file', [IO.Path]::Combine($Root, 'TLS', 'htpasswd'), '--tls', '--tls-min-ver', '1.3',
        '--tls-cert', [IO.Path]::Combine($Root, 'TLS', 'server.pem'), '--tls-key', [IO.Path]::Combine($Root, 'TLS', 'server-key.pem'))
}

function Set-NetCrateOwnedTasks([string]$Root, $Tools) {
    $owner = Get-NetCrateOwner $Root
    $name = 'NetCrate-' + $owner.InstallationId
    $launch = Get-NetCrateTaskLaunch $Root $Tools
    $arguments = ($launch.Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existing -and ($existing.Description -cne ('NetCrate ' + $owner.InstallationId) -or $existing.Principal.UserId -ne $owner.UserSid)) { throw 'A task with this name belongs to another installation.' }
    $action = New-ScheduledTaskAction -Execute $Tools.PowerShell -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId $owner.UserSid -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $owner.UserSid
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description ('NetCrate ' + $owner.InstallationId)
    $null = Register-ScheduledTask -TaskName $name -InputObject $task -Force
    Start-ScheduledTask -TaskName $name
}

function Get-NetCrateTaskLaunch([string]$Root, $Tools) {
    $null = Assert-NetCrateLocalPath $Root
    return [pscustomobject]@{ FilePath = $Tools.PowerShell; Arguments = [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', [IO.Path]::Combine($Root, 'App', 'src', 'shared', 'Invoke-NetCrateRuntime.ps1'), '-Root', $Root) }
}

function Get-NetCrateFirewallLaunch([string]$Root) {
    $owner = Get-NetCrateOwner $Root
    $endpoint = Read-NetCrateJson ([IO.Path]::Combine($Root, 'endpoint.json'))
    $tools = Read-NetCrateJson ([IO.Path]::Combine($Root, 'tools.json'))
    $data = @{ InstallationId = $owner.InstallationId; LocalAddress = $endpoint.Address; SourceAddress = $endpoint.SourceAddress; Program = $tools.RestServer } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))
    $helper = [IO.File]::ReadAllText([IO.Path]::Combine($Root, 'App', 'install', 'Set-NetCrateFirewall.ps1'))
    $code = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($helper))
    $command = '$ErrorActionPreference="Stop"; try { $p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("' + $payload + '"))|ConvertFrom-Json; '
    $command += '& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("' + $code + '")))) -InstallationId $p.InstallationId -LocalAddress $p.LocalAddress -SourceAddress $p.SourceAddress -Program $p.Program; exit 0 } catch { exit 1 }'
    return [pscustomobject]@{ FilePath = [IO.Path]::Combine($env:WINDIR, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        Arguments = [string[]]@('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) }
}

function Copy-NetCrateApplication([string]$Source, [string]$Destination) {
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\').Equals([IO.Path]::GetFullPath($Destination).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return }
    $null = [IO.Directory]::CreateDirectory($Destination)
    foreach ($name in @('NetCrate.exe', 'NetCrate.exe.config', 'NetCrate.ico', 'NetCrate.png', 'THIRD-PARTY.md', 'VERSION', 'CHANGELOG.md', 'install', 'src')) {
        $from = [IO.Path]::Combine($Source, $name)
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $Destination -Recurse -Force }
    }
}

function Get-NetCrateInstallerCache([string]$Root) {
    $null = Get-NetCrateOwner $Root
    $path = Assert-NetCrateLocalPath ([IO.Path]::Combine([IO.Path]::GetDirectoryName($Root), 'PublicInstallers'))
    $null = [IO.Directory]::CreateDirectory($path)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($owner); $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($path), $acl)
    return $path
}

function Initialize-NetCrateComputer([string]$Root, $State, [string]$AppRoot) {
    $mode = Get-NetCrateBackupMode $State
    $folder = Assert-NetCrateLocalPath $State.Folder
    if ($Root.StartsWith($folder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $folder.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $folder.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose a project or backup folder separate from the NetCrate application folder.'
    }
    $role = if ($State.Role -ceq 'EditingComputer') { 'Source' } else { 'Worker' }
    $null = New-NetCrateIdentity $Root $State.InstallationId $role
    $preparedPath = [IO.Path]::Combine($Root, 'prepared.json')
    if ([IO.File]::Exists($preparedPath)) {
        $prior = Read-NetCrateJson $preparedPath
        if (-not $prior.Folder.Equals($State.Folder,[StringComparison]::OrdinalIgnoreCase) -or (Get-NetCrateBackupMode $prior) -cne $mode) { throw 'This installation already uses another folder or backup mode. Its files were preserved.' }
    }
    $tools = Install-NetCrateTools $role $Root -BackupMode $mode
    Write-NetCrateJson ([IO.Path]::Combine($Root, 'tools.json')) $tools
    if ($role -ceq 'Worker') { $null = Initialize-NetCrateRepositories $Root $State.Folder $tools.Restic }
    $app = [IO.Path]::Combine($Root, 'App')
    Copy-NetCrateApplication $AppRoot $app
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Programs'), 'NetCrate.lnk'))
    $shortcut.TargetPath = [IO.Path]::Combine($app, 'NetCrate.exe'); $shortcut.WorkingDirectory = $app; $shortcut.Save()
    Write-NetCrateJson $preparedPath @{ Version = 1; Role = $role; Folder = $State.Folder; BackupMode = $mode; InstallationId = $State.InstallationId }
}

function New-NetCrateRuntimeSettings($Root, $Prepared, $Request, $WorkerComputer, $Repositories, $Tools) {
    $owner = Get-NetCrateOwner $Root
    $workRoot = $Root
    if ($owner.Role -ceq 'Worker') {
        $binding = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
        $workRoot = Set-NetCratePrivateDirectory ([IO.Path]::Combine($binding.RepositoryRoot, 'Processing'))
    }
    return [pscustomobject][ordered]@{ Version = 1; Role = $owner.Role; InstallationId = $owner.InstallationId
        BackupMode = $(if ($owner.Role -ceq 'Worker') { Get-NetCrateBackupMode $Prepared } else { Get-NetCrateBackupMode $Request })
        SourceBackupMode = (Get-NetCrateBackupMode $Request)
        SourceComputer = $Request.SourceComputer; WorkerComputer = $WorkerComputer; ActiveRoot = $Request.ProjectRoot
        SnapshotRoot = (Get-NetCrateSnapshotRoot $Request.ProjectRoot); StateRoot = $Root; Recipe = 'half-prores-v2'; PollSeconds = 5
        Repositories = $Repositories; Tools = $Tools; WorkRoot = $workRoot }
}

function Test-NetCrateConnectionPayload($Payload, $Request, $Reply) {
    if ($Payload.SourceId -cne $Request.RecipientId -or $Payload.ServerId -cne $Reply.ServerId -or $Payload.RequestId -cne $Request.RequestId -or
        $Payload.ProjectRoot -cne $Request.ProjectRoot -or $Payload.SourceComputer -cne $Request.SourceComputer -or
        $Payload.CertificateSHA256 -cne (Get-NetCrateHash $Payload.Certificate) -or $Payload.CertificateSHA256 -cne $Reply.CertificateSHA256) { throw 'The reply does not match this computer and project folder.' }
    if ($Request.Version -eq 2 -and ($Payload.BackupMode -cne $Request.BackupMode -or $Payload.ServerBackupMode -cnotin @('Folder','Media') -or ($Request.BackupMode -ceq 'Media' -and $Payload.ServerBackupMode -ceq 'Folder'))) { throw 'The reply does not match the requested backup mode.' }
    Assert-NetCratePrivateAddress $Payload.Address
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($Payload.Certificate)
    try { if ($cert.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(1)) { throw 'The backup certificate expired.' } } finally { $cert.Dispose() }
    foreach ($name in @('Primary', 'Results')) {
        $leaf = if ($name -ceq 'Primary') { 'originals' } else { 'results' }
        if ($Payload.Repositories.$name.Uri -cne ('rest:https://' + $Payload.Address + ':8200/editing/' + $leaf + '/') -or
            $Payload.Repositories.$name.Id -cnotmatch '^[a-f0-9]{64}$' -or $Payload.($name + 'Password').Length -lt 40) { throw 'The reply contains an invalid backup binding.' }
    }
    if ($Payload.TransportPassword.Length -lt 40 -or $Payload.Repositories.Primary.Id -ceq $Payload.Repositories.Results.Id) { throw 'The private backup login is invalid.' }
}

function Invoke-NetCrateSetupAction {
    param([string]$Action, $State, [string]$Root, [string]$AppRoot)
    $message = ''; $code = ''; $stage = ''
    if ($Action -ceq 'Prepare') { Initialize-NetCrateComputer $Root $State $AppRoot; $message = 'This computer is prepared. Tasks run while you are signed in to Windows.' }
    elseif ($Action -ceq 'Inspect') {
        $ready = [IO.File]::Exists([IO.Path]::Combine($Root, 'prepared.json'))
        if (-not $ready) { return @{ Succeeded = $false; Code = 'prepare-needed'; Message = 'Choose Prepare this computer to install the required software.' } }
        $owner = Get-NetCrateOwner $Root
        if ($owner.InstallationId -cne $State.InstallationId) { throw 'Open the setup for the existing NetCrate installation.' }
        $prepared = Read-NetCrateJson ([IO.Path]::Combine($Root, 'prepared.json'))
        $expectedRole = if ($State.Role -ceq 'EditingComputer') { 'Source' } else { 'Worker' }
        if ($owner.Role -cne $expectedRole -or $prepared.Role -cne $expectedRole) { throw 'This installation uses the other computer role. Go back and select its original role.' }
        if (-not $prepared.Folder.Equals($State.Folder, [StringComparison]::OrdinalIgnoreCase)) { throw 'This installation already uses another folder. Go back and select the original folder; existing backups were preserved.' }
        if ((Get-NetCrateBackupMode $prepared) -cne (Get-NetCrateBackupMode $State)) { throw 'This installation uses another backup mode. Select its original mode; existing backups were preserved.' }
        $tools = Read-NetCrateJson ([IO.Path]::Combine($Root, 'tools.json'))
        foreach ($name in @('PowerShell', 'Restic')) { if (-not [IO.File]::Exists($tools.$name)) { throw 'A required tool is missing. Choose Prepare this computer to repair it.' } }
        $message = 'This computer is prepared.'
    } else {
        $owner = Get-NetCrateOwner $Root
        if ($owner.InstallationId -cne $State.InstallationId) { throw 'The setup does not belong to this installation.' }
        $prepared = Read-NetCrateJson ([IO.Path]::Combine($Root, 'prepared.json'))
        $expectedRole = if ($State.Role -ceq 'EditingComputer') { 'Source' } else { 'Worker' }
        if ($owner.Role -cne $expectedRole -or $prepared.Role -cne $expectedRole -or (Get-NetCrateBackupMode $State) -cne (Get-NetCrateBackupMode $prepared) -or -not $prepared.Folder.Equals($State.Folder,[StringComparison]::OrdinalIgnoreCase)) { throw 'The setup choices differ from this prepared installation.' }
        $tools = Read-NetCrateJson ([IO.Path]::Combine($Root, 'tools.json'))
        switch -Exact ($Action) {
            'Network' {
                $exe = [IO.Path]::Combine($env:ProgramFiles, 'NetBird', 'netbird-ui.exe')
                if (-not [IO.File]::Exists($exe)) {
                    $package = (Get-NetCrateDependencyCatalog).NetBird
                    $msi = Get-NetCratePackageArchive $package (Get-NetCrateInstallerCache $Root)
                    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"' + $msi + '"')) -Verb RunAs -WindowStyle Hidden -PassThru -Wait
                    if ($process.ExitCode -notin @(0, 3010)) { throw 'NetBird installation did not finish. Choose Open NetBird to try again.' }
                }
                $null = Start-Process -FilePath $exe -WindowStyle Hidden
                $message = 'Sign in to NetBird with the same account on both computers, then return here.'
            }
            'SaveRecovery' { Export-NetCrateRecovery $Root $State.Path; $message = 'Recovery details were saved. Keep a copy on another computer or removable drive.' }
            'ExportConnection' {
                if ($owner.Role -ceq 'Source') {
                    $wire = New-NetCratePairingRequest $Root $env:COMPUTERNAME $prepared.Folder (Resolve-NetCrateNetworkAddress $State) -BackupMode (Get-NetCrateBackupMode $prepared)
                    $code = $wire.DeviceCode; $stage = 'RequestSaved'; $message = 'Open this file on the Backup Server. Compare the device code shown there with this code.'
                } else {
                    $pending = Unprotect-NetCrateRecord $Root 'inbound-request'
                    $endpoint = Read-NetCrateJson ([IO.Path]::Combine($Root, 'endpoint.json'))
                    $repos = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
                    $secret = Get-NetCrateRepositorySecrets $Root
                    $remote = @{}
                    foreach ($name in @('Primary', 'Results')) {
                        $leaf = if ($name -ceq 'Primary') { 'originals' } else { 'results' }
                        $remote[$name] = @{ Uri = ('rest:https://' + $endpoint.Address + ':8200/editing/' + $leaf + '/'); Id = $repos.($name + 'Id') }
                    }
                    $payload = @{ SourceId = $pending.Request.RecipientId; ServerId = $owner.InstallationId; RequestId = $pending.Request.RequestId
                        SourceComputer = $pending.Request.SourceComputer; ProjectRoot = $pending.Request.ProjectRoot; WorkerComputer = $env:COMPUTERNAME
                        Address = $endpoint.Address; Certificate = $endpoint.Certificate; CertificateSHA256 = $endpoint.CertificateSHA256; Repositories = $remote
                        PrimaryPassword = $secret.PrimaryPassword; ResultsPassword = $secret.ResultsPassword; TransportPassword = $secret.TransportPassword }
                    $wire = New-NetCratePairingReply $Root $payload
                    $code = $wire.ConnectionCode; $stage = 'ReplySaved'; $message = 'Open this reply on the Editing Computer. Compare the connection code shown there with this code.'
                }
                $target = Assert-NetCrateLocalPath $State.Path
                $bytes = [Text.Encoding]::UTF8.GetBytes(($wire | ConvertTo-Json -Depth 24))
                $file = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
            }
            'ImportConnection' {
                $wire = Read-NetCrateJson $State.Path -MaximumBytes 131072
                if ($owner.Role -ceq 'Source') { $result = Import-NetCratePairingReply $Root $wire; $code = $result.ConnectionCode; $stage = 'ReplyImported' }
                else { $result = Import-NetCratePairingRequest $Root $wire -BackupMode (Get-NetCrateBackupMode $prepared); $code = $result.DeviceCode; $stage = 'RequestImported' }
                $message = 'Compare this code with the code on your other computer. Choose Codes match only if they are identical.'
            }
            'ConfirmConnection' {
                if ($owner.Role -ceq 'Worker') {
                    $pending = Unprotect-NetCrateRecord $Root 'inbound-request'
                    Confirm-NetCratePairingRequest $Root $pending.Request.RequestId $State.PairingCode
                    $endpoint = Initialize-NetCrateEndpoint $Root (Resolve-NetCrateNetworkAddress $State) $pending.Request.NetworkAddress $tools
                    $repos = Read-NetCrateJson ([IO.Path]::Combine($Root, 'repositories.json'))
                    $bindings = @{}
                    foreach ($name in @('Primary', 'Results')) {
                        $leaf = if ($name -ceq 'Primary') { 'originals' } else { 'results' }
                        $bindings[$name] = @{ Uri = $repos.($name + 'Path'); RemoteUri = ('rest:https://' + $endpoint.Address + ':8200/editing/' + $leaf + '/'); Id = $repos.($name + 'Id') }
                    }
                    $settings = New-NetCrateRuntimeSettings $Root $prepared $pending.Request $env:COMPUTERNAME $bindings $tools
                    Protect-NetCrateRecord $Root 'runtime-peer' @{ PublicKey = $pending.Request.PublicKey }
                    Write-NetCrateJson ([IO.Path]::Combine($Root, 'settings.json')) $settings
                    $launch = Get-NetCrateFirewallLaunch $Root
                    $process = Start-Process -FilePath $launch.FilePath -ArgumentList $launch.Arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
                    if ($process.ExitCode -ne 0) { throw 'Windows did not allow the private backup connection. Choose Codes match to try again.' }
                    Set-NetCrateOwnedTasks $Root $tools
                    $stage = 'RequestConfirmed'; $message = 'Save the reply file, then open it on the Editing Computer.'
                } else {
                    $pending = Unprotect-NetCrateRecord $Root 'pending-reply'
                    $request = (Unprotect-NetCrateRecord $Root 'outbound-request').Request
                    Test-NetCrateConnectionPayload $pending.Payload $request $pending.Reply
                    $null = Confirm-NetCratePairingReply $Root $State.PairingCode
                    $settings = New-NetCrateRuntimeSettings $Root $prepared $request $pending.Payload.WorkerComputer $pending.Payload.Repositories $tools
                    Protect-NetCrateRecord $Root 'runtime-peer' @{ PublicKey = $pending.Reply.ServerPublicKey }
                    [IO.File]::WriteAllText([IO.Path]::Combine($Root, 'server.pem'), $pending.Payload.Certificate)
                    Write-NetCrateJson ([IO.Path]::Combine($Root, 'settings.json')) $settings
                    Set-NetCrateOwnedTasks $Root $tools
                    $stage = 'Paired'; $message = 'The codes were accepted. Choose Check connection.'
                }
            }
            'CheckConnection' {
                $settings = Import-NetCrateSettings ([IO.Path]::Combine($Root, 'settings.json')) $owner.Role
                if ($owner.Role -ceq 'Source') {
                    foreach ($name in @('Primary', 'Results')) {
                        $config = Invoke-WorkflowRestic $Root $settings $name @('cat', 'config') | ConvertFrom-Json
                        if ($config.id -cne $settings.Repositories.$name.Id) { throw 'The backup storage identity changed. The connection was not accepted.' }
                    }
                    $peer = Unprotect-NetCrateRecord $Root 'paired-peer'
                    $ack = [ordered]@{ Version = 1; Kind = 'pairing-ack'; RequestId = $peer.Request.RequestId; SourceId = $owner.InstallationId; ServerId = $peer.Reply.ServerId }
                    Write-WorkflowRecord $Root $settings pairing-ack (Get-NetCrateHash $peer.Request.RequestId) $ack
                } else {
                    $pending = Unprotect-NetCrateRecord $Root 'inbound-request'
                    $acks = @(Read-WorkflowRecords $Root $settings pairing-ack $settings.SourceComputer | Where-Object {
                        $_.Version -eq 1 -and $_.Kind -ceq 'pairing-ack' -and $_.RequestId -ceq $pending.Request.RequestId -and $_.SourceId -ceq $pending.Request.RecipientId -and $_.ServerId -ceq $owner.InstallationId
                    })
                    if (-not $acks.Count) { throw 'On the Editing Computer, compare the connection code and choose Check connection. Then try again here.' }
                }
                $message = 'Both backup repositories are connected.'
            }
            'CheckSample' {
                if ($owner.Role -ceq 'Worker') { throw 'Start the sample check on the Editing Computer. Keep this computer on and signed in.' }
                $settings = Import-NetCrateSettings ([IO.Path]::Combine($Root, 'settings.json')) Source
                $queue = Add-NetCrateBackupQueue $Root $settings -Sample
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while ($watch.Elapsed.TotalMinutes -lt 20) {
                    $status = Read-NetCrateJson $queue
                    if ($status.State -ceq 'Ready') { $message = if ($settings.BackupMode -ceq 'Folder') { 'The sample backup passed restored-file verification.' } else { 'The sample backup and returned proxy passed verification.' }; break }
                    if ($status.State -ceq 'NeedsAttention') { throw 'The sample could not finish. Check that both computers are on and connected to NetBird, then try again.' }
                    Start-Sleep -Seconds 2
                }
                if (-not $message) { throw 'The sample is still waiting for the Backup Server. Keep both computers on, then choose Run sample check again.' }
                Write-NetCrateJson ([IO.Path]::Combine($Root, 'sample-verified.json')) @{ Version = 1; VerifiedUtc = [DateTime]::UtcNow.ToString('o') }
            }
            'Finish' {
                $settings = Import-NetCrateSettings ([IO.Path]::Combine($Root, 'settings.json')) $owner.Role
                if ($owner.Role -ceq 'Source' -and -not [IO.File]::Exists([IO.Path]::Combine($Root, 'sample-verified.json'))) { throw 'Run the sample check before finishing setup.' }
                Write-NetCrateJson ([IO.Path]::Combine([IO.Path]::GetDirectoryName($Root), 'settings.json')) $settings
                $message = 'Setup is complete.'
            }
            default { throw 'Unsupported setup action.' }
        }
    }
    return @{ Succeeded = $true; Code = 'ok'; Message = $message; PairingCode = $code; PairingStage = $stage }
}

Export-ModuleMember -Function Get-NetCratePrivateAddress, Assert-NetCratePrivateAddress, Initialize-NetCrateEndpoint,
    Get-NetCrateServerArguments, Invoke-NetCrateSetupAction, Test-NetCrateConnectionPayload, Get-NetCrateTaskLaunch, Get-NetCrateFirewallLaunch, Copy-NetCrateApplication, Get-NetCrateInstallerCache
