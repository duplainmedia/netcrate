$ErrorActionPreference='Stop'
$compiler='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$framework=Split-Path $compiler;$wpf=Join-Path $framework 'WPF'
& (Join-Path $PSScriptRoot 'Build-BrandAssets.ps1')
& $compiler /nologo /codepage:65001 /target:exe /out:"$PSScriptRoot\AppTests.exe" /r:System.Web.Extensions.dll "$PSScriptRoot\AppModel.cs" "$PSScriptRoot\ProgressModel.cs" "$PSScriptRoot\VersionModel.cs" "$PSScriptRoot\AppTests.cs"
if($LASTEXITCODE -ne 0){throw 'Model test compilation failed.'}
& "$PSScriptRoot\AppTests.exe"
if($LASTEXITCODE -ne 0){throw 'Model tests failed.'}
$references=@('/r:System.Web.Extensions.dll','/r:System.Drawing.dll','/r:System.Windows.Forms.dll',('/r:'+(Join-Path $wpf 'PresentationFramework.dll')),('/r:'+(Join-Path $wpf 'PresentationCore.dll')),('/r:'+(Join-Path $wpf 'WindowsBase.dll')),('/r:'+(Join-Path $framework 'System.Xaml.dll')))
& $compiler /nologo /codepage:65001 /target:winexe /platform:x64 /out:"$PSScriptRoot\NetCrate.exe" /win32manifest:"$PSScriptRoot\App.manifest" /win32icon:"$PSScriptRoot\NetCrate.ico" @references "$PSScriptRoot\BrandInfo.cs" "$PSScriptRoot\AppModel.cs" "$PSScriptRoot\ProgressModel.cs" "$PSScriptRoot\VersionModel.cs" "$PSScriptRoot\App.cs" "$PSScriptRoot\WindowView.cs"
if($LASTEXITCODE -ne 0){throw 'Windows app compilation failed.'}
@'
<?xml version="1.0" encoding="utf-8"?>
<configuration><startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8"/></startup><runtime><AppContextSwitchOverrides value="Switch.System.Windows.DoNotScaleForDpiChanges=false"/></runtime></configuration>
'@|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'NetCrate.exe.config') -Encoding UTF8
'Built native Windows app.'
