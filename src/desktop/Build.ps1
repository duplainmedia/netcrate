param([string]$TestRoot = $env:TEMP)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output = Join-Path $repo 'build'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$framework = Split-Path $compiler
$wpf = Join-Path $framework 'WPF'

function Build-Test {
    param([string]$Name, [string[]]$Sources, [string[]]$Arguments = @(), [string[]]$References = @())
    $exe = Join-Path $output ($Name + '.exe')
    & $compiler /nologo /codepage:65001 /target:exe /r:System.Web.Extensions.dll "/out:$exe" @References @Sources
    if ($LASTEXITCODE -ne 0) { throw "$Name compilation failed." }
    & $exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed." }
}

$state = Join-Path $PSScriptRoot 'setup\SetupState.cs'
$store = Join-Path $PSScriptRoot 'setup\JsonSetupStore.cs'
$service = Join-Path $PSScriptRoot 'setup\ISetupService.cs'
$settings = Join-Path $PSScriptRoot 'Settings.cs'
$models = @($settings, $store, $state) + @('AppModel.cs', 'ProgressModel.cs', 'VersionModel.cs', 'GuidedModel.cs' | ForEach-Object { Join-Path $PSScriptRoot $_ })
Build-Test 'AppTests' ($models + (Join-Path $PSScriptRoot 'AppTests.cs'))
Build-Test 'GuidedModelTests' ($models + (Join-Path $repo 'tests\desktop\GuidedModelTests.cs')) @((Join-Path $TestRoot ('G-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))
Build-Test 'SetupTests' @($state, $service, (Join-Path $PSScriptRoot 'setup\SetupController.cs'), (Join-Path $repo 'tests\desktop\SetupTests.cs'))
$inspection = Join-Path $PSScriptRoot 'setup\InspectionProcess.cs'
Build-Test 'SetupStorageTests' @($state, $store, $service, $inspection, (Join-Path $PSScriptRoot 'setup\WindowsSetupService.cs'), (Join-Path $repo 'tests\desktop\SetupStorageTests.cs')) @($TestRoot, (Join-Path $repo 'install'))
Build-Test 'SettingsTests' @($settings, $state, $store, (Join-Path $repo 'tests\desktop\SettingsTests.cs')) @($TestRoot)
Build-Test 'InspectionTests' @($inspection, (Join-Path $repo 'tests\desktop\InspectionTests.cs'))

& (Join-Path $PSScriptRoot 'Build-BrandAssets.ps1')
$references = @(
    '/r:System.Web.Extensions.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
    ('/r:' + (Join-Path $wpf 'PresentationFramework.dll')),
    ('/r:' + (Join-Path $wpf 'PresentationCore.dll')),
    ('/r:' + (Join-Path $wpf 'WindowsBase.dll')),
    ('/r:' + (Join-Path $wpf 'UIAutomationProvider.dll')),
    ('/r:' + (Join-Path $wpf 'UIAutomationTypes.dll')),
    ('/r:' + (Join-Path $framework 'System.Xaml.dll'))
)
$sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' -File | Where-Object Name -ne 'AppTests.cs' | Select-Object -ExpandProperty FullName)
$sources += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'setup') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
$viewSources = @((Join-Path $PSScriptRoot 'Theme.cs')) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'setup') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
Build-Test 'SetupViewTests' ($viewSources + (Join-Path $repo 'tests\desktop\SetupViewTests.cs')) @() $references
$app = Join-Path $output 'NetCrate.exe'
& $compiler /nologo /codepage:65001 /target:winexe /platform:x64 "/out:$app" "/win32manifest:$PSScriptRoot\App.manifest" "/win32icon:$PSScriptRoot\NetCrate.ico" @references @sources
if ($LASTEXITCODE -ne 0) { throw 'Windows app compilation failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'NetCrate.ico') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Assets\NetCrate-AppIcon.png') -Destination (Join-Path $output 'NetCrate.png') -Force
New-Item -ItemType Directory -Path (Join-Path $output 'install') -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $repo 'install') -File | Copy-Item -Destination (Join-Path $output 'install') -Force
foreach ($folder in @('shared', 'worker')) {
    $target = Join-Path $output ('src\' + $folder)
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $repo ('src\' + $folder)) -File | Copy-Item -Destination $target -Force
}
if (Test-Path -LiteralPath (Join-Path $repo 'THIRD-PARTY.md')) {
    Copy-Item -LiteralPath (Join-Path $repo 'THIRD-PARTY.md') -Destination $output -Force
}
@'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8"/></startup>
  <runtime><AppContextSwitchOverrides value="Switch.System.Windows.DoNotScaleForDpiChanges=false"/></runtime>
</configuration>
'@ | Set-Content -LiteralPath ($app + '.config') -Encoding UTF8
Write-Output "Built $app"
