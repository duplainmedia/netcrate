# All queue writers share this short lock. Native backup work runs after release.
function Invoke-NetCrateAdmissionLock([string]$Root, [scriptblock]$Action) {
    $key = Get-NetCrateHash ([IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant())
    $mutex = [Threading.Mutex]::new($false, ('Local\NetCrate-Admission-' + $key))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'The backup queue is busy. Try again shortly.' }
        & $Action
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Get-NetCrateScheduleOccurrence([DateTime]$Date, [string]$TimeOfDay, [TimeZoneInfo]$Zone) {
    if ($TimeOfDay -cnotmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'Choose a daily time in HH:mm format.' }
    $local = [DateTime]::SpecifyKind($Date.Date.Add([TimeSpan]::ParseExact($TimeOfDay, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)), [DateTimeKind]::Unspecified)
    while ($Zone.IsInvalidTime($local)) { $local = $local.AddMinutes(1) }
    $offset = if ($Zone.IsAmbiguousTime($local)) { $Zone.GetAmbiguousTimeOffsets($local) | Sort-Object -Descending | Select-Object -First 1 } else { $Zone.GetUtcOffset($local) }
    return [DateTimeOffset]::new($local, $offset).ToUniversalTime()
}

function Get-NetCrateScheduleNext($Record, [DateTimeOffset]$Now, [TimeZoneInfo]$Zone) {
    $date = [TimeZoneInfo]::ConvertTime($Now, $Zone).Date
    # Cursor is a high-water local date, including after zone changes or rollback.
    if ($Record.LastOccurrence -and $date.ToString('yyyy-MM-dd') -cle $Record.LastOccurrence) { $date = [DateTime]::ParseExact($Record.LastOccurrence, 'yyyy-MM-dd', $null).AddDays(1) }
    $effective = [DateTimeOffset]$Record.EffectiveUtc
    for ($i=0; $i -lt 3700; $i++) {
        $due = Get-NetCrateScheduleOccurrence $date $Record.TimeOfDay $Zone
        if ($due -gt $Now -and $due -gt $effective) { return $due.ToString('o') }
        $date = $date.AddDays(1)
    }
    throw 'The next backup date could not be calculated.'
}

function Get-NetCrateSchedules([string]$Root, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    $directory = [IO.Path]::Combine($Root, 'Schedules')
    if (-not [IO.Directory]::Exists($directory)) { return }
    $files = @([IO.Directory]::EnumerateFiles($directory, '*.json'))
    if ($files.Count -gt 256) { throw 'There are too many backup schedules.' }
    foreach ($file in $files) {
        $record = Read-NetCrateJson $file -MaximumBytes 8192
        if ($record.Version -ne 1 -or $record.Id -cnotmatch '^[a-f0-9]{64}$') { throw 'A backup schedule is invalid.' }
        $record | Add-Member NextDueUtc $(if ($record.Enabled) { Get-NetCrateScheduleNext $record $Now $Zone } else { '' }) -Force
        $record | Add-Member TimeZone $Zone.Id -Force
        $record
    }
}

function Save-NetCrateSchedule([string]$Root, $Settings, [string]$Project, [string]$TimeOfDay, [bool]$Enabled,
    [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    $path = Get-NetCrateBackupPath $Settings $Project (Get-NetCrateBackupMode $Settings)
    if (-not [IO.Directory]::Exists($path)) { throw 'The folder is not available.' }
    $null = Get-NetCrateScheduleOccurrence $Now.Date $TimeOfDay $Zone
    Invoke-NetCrateAdmissionLock $Root {
        $directory = [IO.Path]::Combine($Root, 'Schedules'); $null = [IO.Directory]::CreateDirectory($directory)
        $id = Get-NetCrateHash $path.ToUpperInvariant(); $file = [IO.Path]::Combine($directory, $id + '.json')
        $old = if ([IO.File]::Exists($file)) { Read-NetCrateJson $file } else { $null }
        if (-not $old -and @([IO.Directory]::EnumerateFiles($directory,'*.json')).Count -ge 256) { throw 'There are too many backup schedules.' }
        $record = [pscustomobject][ordered]@{ Version=1; Id=$id; Project=$path; TimeOfDay=$TimeOfDay; Enabled=$Enabled
            Revision=$(if ($old) { [int]$old.Revision+1 } else { 1 }); EffectiveUtc=$Now.ToString('o')
            LastOccurrence=$(if ($old) { $old.LastOccurrence } else { '' }); Status='' }
        Write-NetCrateJson $file $record
        Get-NetCrateSchedules $Root $Now $Zone | Where-Object Id -CEQ $id
    }
}

function Disable-NetCrateSchedule([string]$Root, $Settings, [string]$Project) {
    $path = Get-NetCrateBackupPath $Settings $Project (Get-NetCrateBackupMode $Settings)
    Invoke-NetCrateAdmissionLock $Root {
        $file = [IO.Path]::Combine($Root, 'Schedules', (Get-NetCrateHash $path.ToUpperInvariant()) + '.json')
        $record = Read-NetCrateJson $file; $record.Enabled=$false; $record.Revision=[int]$record.Revision+1
        Write-NetCrateJson $file $record
    }
}

function Invoke-NetCrateSchedules([string]$Root, $Settings, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local) {
    foreach ($schedule in @(Get-NetCrateSchedules $Root $Now $Zone)) {
        Invoke-NetCrateAdmissionLock $Root {
            $file = [IO.Path]::Combine($Root, 'Schedules', $schedule.Id + '.json')
            $record = Read-NetCrateJson $file # edit/disable may have won the lock
            if (-not $record.Enabled) { return }
            $date = [TimeZoneInfo]::ConvertTime($Now, $Zone).Date
            $due = Get-NetCrateScheduleOccurrence $date $record.TimeOfDay $Zone
            if ($due -gt $Now) { $date=$date.AddDays(-1); $due=Get-NetCrateScheduleOccurrence $date $record.TimeOfDay $Zone }
            $day=$date.ToString('yyyy-MM-dd')
            if ($due -le [DateTimeOffset]$record.EffectiveUtc -or ($record.LastOccurrence -and $day -cle $record.LastOccurrence)) { return }
            try {
                $null=Add-NetCrateBackupQueue $Root $Settings $record.Project -OccurrenceId ($record.Id + '-' + $record.Revision + '-' + $day) -LocalDate $day -Now $Now
                $record.LastOccurrence=$day; $record.Status='Last scheduled backup queued'
            } catch { $record.Status='Folder unavailable' }
            Write-NetCrateJson $file $record
        }
    }
}
