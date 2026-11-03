#requires -Version 7.0
# REVIEW EXPORT: fictional deployment constants; see docs/CONFIGURATION.md.
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath 'C:\ProgramData\NetCrate\Office\deployment.pause'){return}
& "$PSScriptRoot\OfficeMedia-WorkerCore.ps1"
