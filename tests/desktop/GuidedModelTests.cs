using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Security.Cryptography;
using NetCrate;

class GuidedModelTests {
 static JavaScriptSerializer json=new JavaScriptSerializer();
 static void Put(string path,object value){Directory.CreateDirectory(Path.GetDirectoryName(path));File.WriteAllText(path,json.Serialize(value));}
 static void Assert(bool value,string message){if(!value)throw new Exception(message);}
 public static void Main(string[] args){
  string root=Path.GetFullPath(args[0]),state=Path.Combine(root,"Editing"),projects=Path.Combine(root,"Projects"),project=Path.Combine(projects,"First project");
  Settings settings=Settings.FromRoots(projects,state);settings.SourceComputer="EDITING";settings.WorkerComputer="BACKUP";
  string snapshot=new string('a',64),request=new string('b',64),result=new string('c',64),fingerprint=new string('d',64),recipe="half-prores-v2|test";
  string destination=Path.Combine(project,"Proxies","NetCrate",result),selector=settings.SnapshotRoot+"/First project";
  Put(Path.Combine(state,"Queue","one.json"),new{Project=project,State="WaitingForProxies",Sample=false,SnapshotId=snapshot,RequestId=request,Id="one",CreatedUtc=DateTime.UtcNow.ToString("o"),UpdatedUtc=DateTime.UtcNow.ToString("o")});
  Put(Path.Combine(state,"Requests",request+".json"),new{SnapshotId=snapshot,ProjectPath=selector,Recipe=recipe,FootageFingerprint=fingerprint});
  Assert(new JobReader(settings).Read().Jobs.Single().Phase=="Waiting for proxies","A queued backup was not visible.");
  Put(Path.Combine(destination,"COMPLETE.json"),new{GenerationSnapshotId=snapshot,Recipe=recipe,FootageFingerprint=fingerprint,Clips=1});
  Directory.CreateDirectory(Path.Combine(destination,"Proxies"));Directory.CreateDirectory(Path.Combine(destination,"Contact sheets"));
  string proxy=Path.Combine(destination,"Proxies","a.mov"),sheet=Path.Combine(destination,"Contact sheets","a.jpg"),index=Path.Combine(destination,"media_index.json");
  File.WriteAllText(proxy,"proxy");File.WriteAllText(sheet,"sheet");File.WriteAllText(index,"[]");
  File.WriteAllText(Path.Combine(destination,"Files-SHA256.csv"),"Path,Bytes,SHA256\nProxies/a.mov,5,"+Hash(proxy)+"\nContact sheets/a.jpg,5,"+Hash(sheet)+"\nmedia_index.json,2,"+Hash(index)+"\n");
  var association=new Dictionary<string,object>{{"RequestId",request},{"RequestedSnapshotId",snapshot},{"GenerationSnapshotId",snapshot},{"ResultSnapshotId",result},{"SourceComputer","EDITING"},{"WorkerComputer","BACKUP"},{"Recipe",recipe},{"JobId","auto-"+fingerprint},{"ProjectPath",selector},{"CompletionSHA256",Hash(Path.Combine(destination,"COMPLETE.json"))},{"ResultManifestSHA256",Hash(Path.Combine(destination,"Files-SHA256.csv"))}};
  string receiptPath=Path.Combine(state,"Receipts",request+".json");
  var receipt=new Dictionary<string,object>{{"State","Ready"},{"RequestId",request},{"RequestedSnapshotId",snapshot},{"ResultSnapshotId",result},{"LocalPath",destination},{"Association",association},{"VerifiedUtc",DateTime.UtcNow.ToString("o")}};
  Put(receiptPath,receipt);
  Assert(new JobReader(settings).Read().Jobs.Single().Phase=="Proxies ready","A verified generation was not visible.");
  association["WorkerComputer"]="OTHER";Put(receiptPath,receipt);
  Assert(new JobReader(settings).Read().Jobs.Single().Phase!="Proxies ready","A receipt from another worker claimed readiness.");
  association["WorkerComputer"]="BACKUP";Put(receiptPath,receipt);string completeBefore=File.ReadAllText(Path.Combine(destination,"COMPLETE.json"));File.AppendAllText(Path.Combine(destination,"COMPLETE.json")," ");
  Assert(new JobReader(settings).Read().Jobs.Single().Phase!="Proxies ready","Changed completion metadata claimed readiness.");
  File.WriteAllText(Path.Combine(destination,"COMPLETE.json"),completeBefore);
  int failures=0;
  File.Delete(proxy);Job missing=new JobReader(settings).Read().Jobs.Single();
  if(missing.Phase=="Proxies ready"||!missing.Attention){Console.WriteLine("FAIL: removed media still reported ready");failures++;}
  File.WriteAllText(proxy,"proxy");
  Put(Path.Combine(state,"Queue","new.json"),new{Project=project,State="NeedsAttention",Sample=false,SnapshotId="",RequestId="",Id="new",CreatedUtc=DateTime.UtcNow.AddSeconds(1).ToString("o"),UpdatedUtc=DateTime.UtcNow.ToString("o")});
  Job pending=new JobReader(settings).Read().Jobs.Single();
  if(pending.ResultFolder!=destination||!pending.Attention){Console.WriteLine("FAIL: later failed backup hid previous verified proxies");failures++;}
  using(System.Diagnostics.Process self=System.Diagnostics.Process.GetCurrentProcess())
   Put(Path.Combine(state,"runtime-status.json"),new{State="Running",ProcessId=self.Id,ProcessStartedUtc=self.StartTime.ToUniversalTime().ToString("o"),UpdatedUtc=DateTime.UtcNow.AddHours(-1).ToString("o")});
  if(new JobReader(settings).Read().ServiceAttention){Console.WriteLine("FAIL: live long job reported connection failure");failures++;}
  Assert(failures==0,"Guided monitor repair regressions failed.");
  Console.WriteLine("PASS: 7 guided backup monitor assertions.");
 }
 static string Hash(string path){using(SHA256 hash=SHA256.Create())return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(path))).Replace("-","").ToLowerInvariant();}
}
