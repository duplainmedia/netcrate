function Test-WorkflowRemoteResult($Root, $Settings, $Association, [string]$RemotePath) {
    $lines = Invoke-WorkflowRestic $Root $Settings Results @('ls', '--json', '--long', '--recursive', $Association.ResultSnapshotId, $RemotePath)
    $nodes = @($lines -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.PSObject.Properties.Name -contains 'type' })
    $seen = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($node in $nodes) {
        if ($node.path -ceq $RemotePath -and $node.type -ceq 'dir') { continue }
        if (-not $node.path.StartsWith($RemotePath + '/', [StringComparison]::Ordinal) -or $node.type -cnotin @('file', 'dir')) { throw 'The result snapshot contains unsupported paths or links.' }
        $relative = Assert-NetCrateRelativePath $node.path.Substring($RemotePath.Length + 1)
        if ($seen.ContainsKey($relative)) { throw 'The result snapshot contains colliding names.' }
        $seen.Add($relative, $node)
    }
    foreach ($name in @('COMPLETE.json', 'Files-SHA256.csv')) {
        if (-not $seen.ContainsKey($name) -or $seen[$name].type -cne 'file' -or $seen[$name].size -gt 4MB) { throw 'The result metadata is missing or too large.' }
    }
    $completion = Invoke-WorkflowRestic $Root $Settings Results @('dump', $Association.ResultSnapshotId, ($RemotePath + '/COMPLETE.json'))
    $manifest = Invoke-WorkflowRestic $Root $Settings Results @('dump', $Association.ResultSnapshotId, ($RemotePath + '/Files-SHA256.csv'))
    # Exact metadata hashes are checked after restoring the validated file set.
    $complete = $completion | ConvertFrom-Json
    foreach ($field in @('JobId', 'GenerationSnapshotId', 'ProjectPath', 'Recipe', 'FootageFingerprint', 'ResultManifestSHA256')) {
        if ($complete.$field -cne $Association.$field) { throw 'The remote result does not match the requested footage.' }
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $expected.Add('COMPLETE.json'); $null = $expected.Add('Files-SHA256.csv')
    foreach ($row in @($manifest | ConvertFrom-Csv)) {
        $null = Assert-NetCrateRelativePath $row.Path
        if (-not $expected.Add($row.Path) -or $row.SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $row.Bytes -cnotmatch '^\d+$' -or
            -not $seen.ContainsKey($row.Path) -or $seen[$row.Path].type -cne 'file' -or $seen[$row.Path].size -ne [long]$row.Bytes) { throw 'The result file list differs from its manifest.' }
    }
    foreach ($entry in $seen.GetEnumerator()) {
        if ($entry.Value.type -ceq 'file' -and -not $expected.Contains($entry.Key)) { throw 'The result snapshot contains an undeclared file.' }
    }
}
