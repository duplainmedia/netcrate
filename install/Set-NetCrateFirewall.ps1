#requires -Version 5.1
#requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$InstallationId, [Parameter(Mandatory)][string]$LocalAddress,
    [Parameter(Mandatory)][string]$SourceAddress, [Parameter(Mandatory)][string]$Program)
$ErrorActionPreference = 'Stop'
function Assert-PrivateAddress([string]$Address) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { throw 'Invalid private address.' }
    $b = $ip.GetAddressBytes()
    if (-not ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127))) { throw 'Invalid private address.' }
}
Assert-PrivateAddress $LocalAddress
Assert-PrivateAddress $SourceAddress
if ($InstallationId -cnotmatch '^[a-f0-9]{32}$' -or $Program -notmatch '^[A-Za-z]:\\' -or
    $Program -match '["\x00-\x1f]|(^|[\\/])\.{1,2}([\\/]|$)' -or [IO.Path]::GetFileName($Program) -cne 'rest-server.exe') { throw 'Invalid firewall binding.' }
$addresses = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object OperationalStatus -EQ Up |
    ForEach-Object { $_.GetIPProperties().UnicastAddresses } | ForEach-Object { $_.Address.ToString() })
if ($LocalAddress -cnotin $addresses) { throw 'The private address is not assigned to this computer.' }
$name = 'NetCrate-' + $InstallationId
$existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.Group -cne $name) { throw 'The existing firewall rule belongs to another application.' }
    $null = Set-NetFirewallRule -Name $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8200 -LocalAddress $LocalAddress -RemoteAddress $SourceAddress -Program $Program -Profile Any
} else {
    $null = New-NetFirewallRule -Name $name -DisplayName 'NetCrate private backup connection' -Group $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8200 -LocalAddress $LocalAddress -RemoteAddress $SourceAddress -Program $Program -Profile Any
}
