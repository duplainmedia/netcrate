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
 static int assertions;
 static void Assert(bool value,string message){if(!value)throw new Exception(message);assertions++;}
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
  File.Delete(proxy);Job missing=new JobReader(settings).Read().Jobs.Single();
  Assert(missing.Phase!="Proxies ready"&&missing.Attention,"Removed media still reported ready.");
  File.WriteAllText(proxy,"proxy");
  Put(Path.Combine(state,"Queue","new.json"),new{Project=project,State="NeedsAttention",Sample=false,SnapshotId="",RequestId="",Id="new",CreatedUtc=DateTime.UtcNow.AddSeconds(1).ToString("o"),UpdatedUtc=DateTime.UtcNow.ToString("o")});
  Job pending=new JobReader(settings).Read().Jobs.Single();
  Assert(pending.ResultFolder==destination&&pending.Attention,"Later failed backup hid previous verified proxies.");
  using(System.Diagnostics.Process self=System.Diagnostics.Process.GetCurrentProcess())
   Put(Path.Combine(state,"runtime-status.json"),new{State="Running",ProcessId=self.Id,ProcessStartedUtc=self.StartTime.ToUniversalTime().ToString("o"),UpdatedUtc=DateTime.UtcNow.AddHours(-1).ToString("o")});
  Assert(!new JobReader(settings).Read().ServiceAttention,"Live long job reported connection failure.");
  string ordinary=Path.Combine(projects,"Documents","November");
  Put(Path.Combine(state,"Queue","ordinary.json"),new{Project=ordinary,BackupMode="Folder",BackupCompletedUtc="2026-11-02T20:00:00Z",MediaState="Off",State="Ready",Sample=false,SnapshotId=new string('e',64),RequestId="",Id="ordinary",CreatedUtc="2026-11-02T19:00:00Z",UpdatedUtc="2026-11-02T20:00:00Z"});
  Job folder=new JobReader(settings).Read().Jobs.SingleOrDefault(j=>j.ProjectPath==ordinary);
  Assert(folder!=null&&folder.BackupCompleted&&!folder.Active&&folder.Phase=="Backed up","An ordinary nested backup required media receipts to appear completed.");
  Put(Path.Combine(state,"Queue","root.json"),new{Project=projects,BackupMode="Folder",BackupCompletedUtc="2026-11-02T20:00:00Z",MediaState="Off",State="Ready",Sample=false,SnapshotId=new string('f',64),RequestId="",Id="root",CreatedUtc="2026-11-02T19:00:00Z",UpdatedUtc="2026-11-02T20:00:00Z"});
  Assert(new JobReader(settings).Read().Jobs.Any(j=>j.ProjectPath==projects&&j.Phase=="Backed up"),"The configured root backup was hidden.");
  string mediaFailure=Path.Combine(projects,"Media publication offline");
  Put(Path.Combine(state,"Queue","media-failure.json"),new{Project=mediaFailure,BackupMode="Media",BackupCompletedUtc="2026-11-02T20:00:00Z",MediaState="NeedsAttention",State="NeedsAttention",Sample=false,SnapshotId=new string('9',64),RequestId="",Id="media-failure",CreatedUtc="2026-11-02T19:00:00Z",UpdatedUtc="2026-11-02T20:00:00Z"});
  Job mediaJob=new JobReader(settings).Read().Jobs.Single(j=>j.ProjectPath==mediaFailure);
  Assert(mediaJob.BackupCompleted&&mediaJob.BackupCompletedUtc==new DateTime(2026,11,2,20,0,0,DateTimeKind.Utc)&&mediaJob.MediaState=="NeedsAttention","Offline media publication hid a successful original backup.");
  Put(Path.Combine(state,"Queue","later.json"),new{Project=ordinary,BackupMode="Folder",BackupCompletedUtc="",MediaState="Off",State="NeedsAttention",Sample=false,SnapshotId="",RequestId="",Id="later",CreatedUtc="2026-11-03T19:00:00Z",UpdatedUtc="2026-11-03T20:00:00Z"});
  Job later=new JobReader(settings).Read().Jobs.Single(j=>j.ProjectPath==ordinary);
  Assert(later.BackupCompleted&&later.BackupCompletedUtc==folder.BackupCompletedUtc&&later.LastAttemptUtc==new DateTime(2026,11,3,19,0,0,DateTimeKind.Utc)&&later.AttemptState=="NeedsAttention","Latest failure hid earlier original or attempt time.");
  Assert(later.BackupStatus.Contains("2026")&&later.BackupStatus.Contains("Last successful original")&&later.BackupStatus.Contains("Latest attempt"),"Dashboard omitted separate full dates.");
  string legacy=Path.Combine(projects,"Legacy");
  Put(Path.Combine(state,"Queue","legacy.json"),new{Project=legacy,BackupMode="Folder",State="Ready",Sample=false,SnapshotId=new string('8',64),RequestId="",Id="legacy",CreatedUtc="2024-01-01T00:00:00Z",UpdatedUtc="2026-11-02T20:00:00Z"});
  Job old=new JobReader(settings).Read().Jobs.Single(j=>j.ProjectPath==legacy);
  Assert(old.BackupCompleted&&old.BackupCompletedUtc==DateTime.MinValue&&old.BackupStatus.Contains("time unknown"),"Legacy original invented a completion time.");
  Put(Path.Combine(state,"Queue","later.json"),new{Project=ordinary,BackupMode="Folder",BackupCompletedUtc="",MediaState="Off",State="Queued",Sample=false,SnapshotId="",RequestId="",Id="later",CreatedUtc="2026-11-03T19:00:00Z",UpdatedUtc="2026-11-03T20:00:00Z"});
  later=new JobReader(settings).Read().Jobs.Single(j=>j.ProjectPath==ordinary);
  Assert(later.BackupCompleted&&later.BackupCompletedUtc==folder.BackupCompletedUtc&&later.Active&&later.AttemptState=="Queued","Queued attempt replaced earlier successful originals.");
  Put(Path.Combine(state,"Queue","media-failure.json"),new{Project=mediaFailure,BackupMode="Media",BackupCompletedUtc="2026-11-02T20:00:00Z",MediaState="Pending",State="WaitingForProxies",Sample=false,SnapshotId=new string('9',64),RequestId="",Id="media-failure",CreatedUtc="2026-11-02T19:00:00Z",UpdatedUtc="2026-11-02T20:00:00Z"});
  mediaJob=new JobReader(settings).Read().Jobs.Single(j=>j.ProjectPath==mediaFailure);
  Assert(mediaJob.BackupCompleted&&mediaJob.BackupStatus.Contains("Media: Pending")&&mediaJob.BackupCompletedUtc==new DateTime(2026,11,2,20,0,0,DateTimeKind.Utc),"Pending media hid original completion.");
  TimeZoneInfo cachedZone=TimeZoneInfo.Local;new JobReader(settings).Read();
  Assert(!Object.ReferenceEquals(cachedZone,TimeZoneInfo.Local),"Long-lived dashboard retained its cached local time zone.");
  Put(Path.Combine(state,"runtime-status.json"),new{State="NeedsAttention",Code="schedule-admission",Message="private fixture diagnostics"});
  Dashboard schedulerError=new JobReader(settings).Read();
  Assert(schedulerError.ServiceAttention&&schedulerError.ServiceMessage.Contains("state-folder access")&&!schedulerError.ServiceMessage.Contains("private fixture"),"Scheduler storage error was hidden behind a connection hint or exposed raw diagnostics.");
  Console.WriteLine("PASS: "+assertions+" guided backup monitor assertions.");
 }
 static string Hash(string path){using(SHA256 hash=SHA256.Create())return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(path))).Replace("-","").ToLowerInvariant();}
}
