#requires -Version 7.4
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot '../../install/NetCrate.SetupWire.cs'
if(-not (Test-Path $path)){throw 'The bounded setup TLS transport is missing.'}
Add-Type -Path $path
function Reject([scriptblock]$f){try{& $f|Out-Null}catch{return};throw 'Invalid frame unexpectedly accepted.'}
function Assert($c,$m){if(-not $c){throw $m}}
$wire=[NetCrate.SetupWire]
foreach($bad in @('{"v":1,"V":2}','{"a":{"kind":1,"kind":2}}','[]','{"v":}')){Reject {$wire::Validate($bad)}}
Reject {$wire::Validate('{"x":"'+('x'*131072)+'"}')}
foreach($bytes in @([byte[]](0,0,0,0),[byte[]](0,2,0,1),[byte[]](0,0,0,2,255,255),[byte[]](0,0,0,2,123))){Reject {$wire::Read([IO.MemoryStream]::new($bytes),1000)}}
$rsa=[Security.Cryptography.RSA]::Create(2048)
$certRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Fixture',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
$cert=$certRequest.CreateSelfSigned([datetimeoffset]::Now.AddDays(-1),[datetimeoffset]::Now.AddDays(1))
$der=$cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
$cert.Dispose()
$cert=[Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12($der,$null,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
[Array]::Clear($der)
$ip=[Net.IPAddress]::Loopback
$listener=[Net.Sockets.TcpListener]::new($ip,0)
$listener.Start(1)
try{
 $port=$listener.LocalEndpoint.Port
 $server=$wire::AcceptAsync($listener,'127.0.0.1',$cert)
 $client=$wire::Connect('127.0.0.1','127.0.0.1',$port)
 $incoming=$server.GetAwaiter().GetResult()
 try{
   Assert ($client.PresentedDER -ceq [Convert]::ToBase64String($cert.RawData)) 'TLS evidence did not capture the actual DER.'
   $wire::Write($client.Stream,'{"type":"request"}',15000)
   Assert (($wire::Read($incoming.Stream,15000)) -ceq '{"type":"request"}') 'Server frame differs.'
   $wire::Write($incoming.Stream,'{"type":"waiting"}',15000)
   Assert (($wire::Read($client.Stream,15000)) -ceq '{"type":"waiting"}') 'Client frame differs.'
   $elapsed=[Diagnostics.Stopwatch]::StartNew()
   Reject {$wire::Read($client.Stream,125)}
   Assert ($elapsed.ElapsedMilliseconds -lt 2500) 'Frame timeout exceeded the deadline.'
 } finally {$client.Dispose();$incoming.Dispose()}
 $wrong=$wire::AcceptAsync($listener,'127.0.0.2',$cert)
 Reject {$wire::Connect('127.0.0.1','127.0.0.1',$port)}
 Reject {$wrong.GetAwaiter().GetResult()}
 $idle=[Net.Sockets.TcpClient]::new()
 $idle.Connect($ip,$port);$watch=[Diagnostics.Stopwatch]::StartNew()
 Reject {$wire::AcceptAsync($listener,'127.0.0.1',$cert).GetAwaiter().GetResult()}
 Assert ($watch.Elapsed.TotalSeconds -lt 7) 'TLS handshake exceeded five seconds plus scheduling allowance.'
 $idle.Dispose()
} finally {$listener.Stop();$cert.Dispose();$rsa.Dispose()}
Write-Output 'PASS bounded TLS loopback, peer filtering, DER capture, collisions, invalid UTF-8, truncation, handshake and frame deadlines.'
