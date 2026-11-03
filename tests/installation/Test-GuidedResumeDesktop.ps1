#requires -Version 7.4
param([string]$TestRoot=(Join-Path $env:TEMP ('NC-final-ui-'+[guid]::NewGuid().ToString('N').Substring(0,8))))
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$null=[IO.Directory]::CreateDirectory($TestRoot)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$framework=Split-Path $compiler;$wpf=Join-Path $framework WPF
$references=@('/r:System.Web.Extensions.dll','/r:System.Drawing.dll','/r:System.Windows.Forms.dll')
foreach($dll in @('PresentationFramework','PresentationCore','WindowsBase','UIAutomationProvider','UIAutomationTypes')){$references+='/r:'+(Join-Path $wpf ($dll+'.dll'))}
$references+='/r:'+(Join-Path $framework System.Xaml.dll)
$sources=@((Join-Path $repo src/desktop/Theme.cs),(Join-Path $repo src/desktop/RestoreView.cs))
$sources+=@(Get-ChildItem (Join-Path $repo src/desktop/setup) -Filter '*.cs' -File|ForEach-Object FullName)
$sources+=Join-Path $repo tests/desktop/WizardFlowTests.cs
$exe=Join-Path $TestRoot WizardFlowTests.exe
& $compiler /nologo /debug /codepage:65001 "/out:$exe" @references @sources
if($LASTEXITCODE){throw 'Wizard fixture compilation failed.'}
& $exe
if($LASTEXITCODE){throw 'Wizard fixture failed.'}
