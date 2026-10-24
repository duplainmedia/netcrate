Set-StrictMode -Version Latest

function Invoke-NetCrateSoftwareProbe {
    param([string]$Path, [string]$Arguments, [int]$TimeoutMilliseconds = 10000)

    $start = [Diagnostics.ProcessStartInfo]::new($Path, $Arguments)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            throw [TimeoutException]::new('Software inspection timed out.')
        }
        if (-not $output.Wait(2000) -or -not $errors.Wait(2000)) {
            throw [TimeoutException]::new('Software inspection output timed out.')
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Result }
    } finally {
        $process.Dispose()
    }
}

function Resolve-NetCrateSoftware {
    param([Parameter(Mandatory)][string]$Name, [string]$PythonPath)

    $executables = @{
        PowerShell = 'pwsh.exe'
        Restic = 'restic.exe'
        FFmpeg = 'ffmpeg.exe'
        Python = 'python.exe'
        Pillow = 'python.exe'
    }
    $arguments = @{
        PowerShell = '-NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSVersion.ToString()"'
        Restic = 'version'
        FFmpeg = '-version'
        Python = '--version'
        Pillow = '-I -c "import PIL; print(PIL.__version__)"'
    }
    $paths = @($env:PATH -split ';')
    $paths += @([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';')
    $paths += @([Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';')
    $paths += @(
        (Join-Path $env:ProgramFiles 'PowerShell\7'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312')
    )
    $candidates = @()
    if ($Name -eq 'Pillow') {
        if ([string]::IsNullOrEmpty($PythonPath)) { return $null }
        $candidates = @($PythonPath)
    } else {
        foreach ($directory in @($paths | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Path]::IsPathRooted($directory)) { continue }
            $candidates += Join-Path $directory $executables[$Name]
        }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or $candidate -like '*\WindowsApps\*') { continue }
        try {
            $probe = Invoke-NetCrateSoftwareProbe -Path $candidate -Arguments $arguments[$Name]
            if ($probe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Output)) { continue }
            $text = [string]($probe.Output -split '\r?\n')[0]
            $valid = switch ($Name) {
                PowerShell { $text -match '^7\.' }
                Restic { $text -match '^restic 0\.19\.' }
                FFmpeg { $text -match '^ffmpeg version 9\.0\.' }
                Python { $text -match '^Python 3\.12\.' }
                Pillow { $text -match '^12\.3\.' }
            }
            if ($valid) { return [pscustomobject]@{ Path = $candidate; Version = $text.Trim() } }
        } catch [TimeoutException] { throw }
        catch { continue }
    }
    return $null
}

function Get-NetCrateSoftware {
    param(
        [Parameter(Mandatory)][ValidateSet('EditingComputer', 'BackupServer')][string]$Role,
        [scriptblock]$Resolver = ${function:Resolve-NetCrateSoftware}
    )

    $packages = @(
        @{ Name = 'PowerShell'; Purpose = 'Runs backup and transfer tasks.'; Id = 'Microsoft.PowerShell'; Version = '7.6.5.0' },
        @{ Name = 'Restic'; Purpose = 'Encrypts and checks your backups.'; Id = 'restic.restic'; Version = '0.19.1' }
    )
    if ($Role -eq 'BackupServer') {
        $packages += @(
            @{ Name = 'FFmpeg'; Purpose = 'Creates proxies and reads video information.'; Id = 'Gyan.FFmpeg'; Version = '9.0.1' },
            @{ Name = 'Python'; Purpose = 'Runs media processing.'; Id = ''; Version = '3.12' },
            @{ Name = 'Pillow'; Purpose = 'Creates contact sheets.'; Id = ''; Version = '12.3' }
        )
    }
    $pythonPath = $null
    foreach ($package in $packages) {
        $issue = ''
        try { $installed = & $Resolver $package.Name $pythonPath }
        catch [TimeoutException] { $installed = $null; $issue = 'probe-timeout' }
        if ($package.Name -eq 'Python' -and $installed) { $pythonPath = $installed.Path }
        [pscustomobject]@{
            Name = $package.Name
            Purpose = $package.Purpose
            Id = $package.Id
            PinnedVersion = $package.Version
            Available = $null -ne $installed
            Path = $(if ($installed) { $installed.Path } else { $null })
            Version = $(if ($installed) { $installed.Version } else { $null })
            Issue = $issue
        }
    }
}

function Install-NetCrateSoftware {
    param([Parameter(Mandatory)]$Package)

    if ([string]::IsNullOrEmpty($Package.Id)) { return 50 }
    $winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { return 51 }
    # WinGet checks the installer hash from its manifest. Do not bypass hash or security checks.
    & $winget.Source install --id $Package.Id --exact --version $Package.PinnedVersion --source winget --silent --disable-interactivity --accept-package-agreements --accept-source-agreements *> $null
    return $LASTEXITCODE
}

function Invoke-NetCratePreparation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('EditingComputer', 'BackupServer')][string]$Role,
        [Parameter(Mandatory)][string]$StateRoot,
        [scriptblock]$Resolver = ${function:Resolve-NetCrateSoftware},
        [scriptblock]$Installer = ${function:Install-NetCrateSoftware}
    )

    $software = @(Get-NetCrateSoftware -Role $Role -Resolver $Resolver)
    if ($WhatIfPreference) {
        return [pscustomobject]@{ Succeeded = $false; Code = 'plan'; Message = 'Software installation plan only.'; Software = $software }
    }
    foreach ($item in $software) {
        if ($item.Issue -eq 'probe-timeout') {
            return [pscustomobject]@{ Succeeded = $false; Code = 'probe-timeout'; Message = 'A software check took too long. Close other installers, then choose Try again.'; Software = $software }
        }
        if ($item.Available) { continue }
        $current = @(Get-NetCrateSoftware -Role $Role -Resolver $Resolver)
        $checkedItem = $current | Where-Object Name -EQ $item.Name
        if ($checkedItem.Issue -eq 'probe-timeout') {
            return [pscustomobject]@{ Succeeded = $false; Code = 'probe-timeout'; Message = 'A software check took too long. Close other installers, then choose Try again.'; Software = $current }
        }
        if ($checkedItem.Available) { continue }
        if (-not $PSCmdlet.ShouldProcess($item.Name, 'Install required software')) { continue }
        $code = & $Installer $item
        if ($code -notin @(0, -1978335189)) {
            $reason = switch ($code) {
                1223 { 'approval-denied' }
                -1978335205 { 'approval-denied' }
                50 { 'runtime-review-needed' }
                51 { 'app-installer-needed' }
                default { 'install-failed' }
            }
            $message = switch ($reason) {
                'approval-denied' { 'Windows approval was declined. Choose Try again when you are ready.' }
                'runtime-review-needed' { 'Automatic installation of the media runtime is not available in this development build yet.' }
                'app-installer-needed' { 'Install Microsoft App Installer, then choose Try again.' }
                default { 'Software installation did not finish. Check your internet connection, then choose Try again.' }
            }
            return [pscustomobject]@{ Succeeded = $false; Code = $reason; Message = $message; Software = @(Get-NetCrateSoftware -Role $Role -Resolver $Resolver) }
        }
        $afterInstall = @(Get-NetCrateSoftware -Role $Role -Resolver $Resolver)
        if (-not ($afterInstall | Where-Object Name -EQ $item.Name).Available) {
            return [pscustomobject]@{ Succeeded = $false; Code = 'software-unavailable'; Message = 'The installed software could not be checked. Restart NetCrate and choose Try again.'; Software = @(Get-NetCrateSoftware -Role $Role -Resolver $Resolver) }
        }
    }
    $software = @(Get-NetCrateSoftware -Role $Role -Resolver $Resolver)
    if (@($software | Where-Object { -not $_.Available }).Count) {
        return [pscustomobject]@{ Succeeded = $false; Code = 'software-unavailable'; Message = 'Required software is still missing. Choose Try again.'; Software = $software }
    }
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $checkpoint = [ordered]@{ Version = 1; Role = $Role; CheckedUtc = [DateTime]::UtcNow.ToString('o'); Stage = 'SoftwareAvailable' }
    $temporary = Join-Path $StateRoot ('software-' + [guid]::NewGuid().ToString('N') + '.writing')
    $path = Join-Path $StateRoot 'software.json'
    try {
        $checkpoint | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject]@{ Succeeded = $true; Code = 'ok'; Message = 'Required software is available.'; Software = $software }
}

Export-ModuleMember -Function Get-NetCrateSoftware, Invoke-NetCratePreparation
