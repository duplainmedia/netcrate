param([Parameter(Mandatory)][string]$TestRoot,[Parameter(Mandatory)][string]$PythonExe,[Parameter(Mandatory)][string]$ResticExe)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$repo/src/shared/NetCrate.Process.psm1"
$null=[IO.Directory]::CreateDirectory($TestRoot)
$child="$TestRoot/streams.py"
@"
import sys, time, os, threading
mode, pid = sys.argv[1:]
open(pid, 'w').write(str(os.getpid()))
if mode == 'stdout':
    for _ in range(70*128): sys.stdout.write('x'*8192)
    sys.stdout.flush(); time.sleep(30)
elif mode == 'stderr':
    sys.stderr.write('e'*(2*1024*1024)); sys.stderr.flush(); time.sleep(30)
elif mode == 'both':
    t=threading.Thread(target=lambda: (sys.stderr.write('e'*(512*1024)), sys.stderr.flush()))
    t.start(); sys.stdout.write('o'*(2*1024*1024)); sys.stdout.flush(); t.join()
elif mode == 'stdin':
    sys.stdout.write(sys.stdin.read()); sys.stderr.write('canary')
elif mode == 'hang':
    time.sleep(30)
"@ | Set-Content -LiteralPath $child -Encoding utf8
$n=0
function Check($condition,$message){if(-not $condition){throw $message};$script:n++}
function Failure([string]$Mode,[string]$Expected,[string]$Log='') {
 $pidFile="$TestRoot/$Mode-$([guid]::NewGuid().ToString('N')).pid";$watch=[Diagnostics.Stopwatch]::StartNew();$message=''
 try{Invoke-NetCrateProcess $PythonExe @('-I','-X','utf8',$child,$Mode,$pidFile) -TimeoutSeconds $(if($Mode -eq 'hang'){1}else{20}) -OutputFile $Log|Out-Null}catch{$message=$_.Exception.Message}
 Check ($message -match $Expected) "Expected $Mode to fail with $Expected, got: $message"
 $nativeId=[int][IO.File]::ReadAllText($pidFile)
 Check (-not (Get-Process -Id $nativeId -ErrorAction SilentlyContinue)) "$Mode left its native child running."
 Check ($watch.Elapsed.TotalSeconds -lt 25) "$Mode did not stop promptly."
}
Failure stdout 'more metadata'
Failure stderr 'more diagnostic'
Failure stdout 'line.*limit|more metadata' "$TestRoot/streamed.jsonl"
$pidFile="$TestRoot/both.pid"
$r=Invoke-NetCrateProcess $PythonExe @('-I','-X','utf8',$child,'both',$pidFile) -TimeoutSeconds 10
Check (@($r).Count -eq 1 -and $r.ExitCode -eq 0 -and $r.Output.Length -eq 2MB -and $r.Diagnostic.Length -eq 512KB) 'Simultaneous stdout/stderr were truncated or deadlocked.'
Failure hang 'timed out'
$r=Invoke-NetCrateProcess $PythonExe @('-I','-X','utf8',$child,'stdin',"$TestRoot/stdin.pid") @{RESTIC_PASSWORD='canary'} -InputText '日本語 café' -TimeoutSeconds 5
Check (@($r).Count -eq 1 -and $r.Output -ceq '日本語 café' -and $r.Diagnostic -ceq '[redacted]') 'Async stdin leaked task values, corrupted Unicode or exposed a diagnostic secret.'
$repository="$TestRoot/originals";$file="$TestRoot/binary.bin";$out="$TestRoot/recovered.bin";$envs=@{RESTIC_PASSWORD=('process-fixture-'+[guid]::NewGuid().ToString('N'))}
[IO.File]::WriteAllBytes($file,[byte[]](0..255))
$r=Invoke-NetCrateProcess $ResticExe @('--repo',$repository,'--no-cache','init') $envs
Check ($r.ExitCode -eq 0) 'Native repository fixture init failed.'
$r=Invoke-NetCrateProcess $ResticExe @('--repo',$repository,'--no-cache','backup','--json','--',$file) $envs -OutputFile "$TestRoot/backup.jsonl"
$summary=$r.Output|ConvertFrom-Json
Check ($r.ExitCode -eq 0 -and $summary.message_type -ceq 'summary' -and $summary.snapshot_id -cmatch '^[a-f0-9]{64}$') 'Streamed backup lost its summary.'
$full=[IO.Path]::GetFullPath($file);$selector='/'+$full.Substring(0,1)+$full.Substring(2).Replace('\','/')
$r=Invoke-NetCrateProcess $ResticExe @('--repo',$repository,'--no-cache','dump',$summary.snapshot_id,$selector,'--target',$out) $envs
Check ($r.ExitCode -eq 0 -and (Get-FileHash -LiteralPath $file).Hash -ceq (Get-FileHash -LiteralPath $out).Hash) 'Native binary target was decoded or changed.'
Write-Output "PASS: $n bounded process stream, overflow/timeout kill, simultaneous-stream and native binary-target assertions."
