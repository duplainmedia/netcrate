using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace NetCrate {
 public partial class JobReader {
  static string FileHash(string path) {
   using(SHA256 hash=SHA256.Create())using(FileStream stream=File.OpenRead(path))
    return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
  }
  void ReadGuidedJobs() {
   if(String.IsNullOrEmpty(settings.StateRoot))return;
   var runtime=ReadJson(Path.Combine(settings.StateRoot,"runtime-status.json"));
   if(runtime!=null&&(S(runtime,"State")=="NeedsAttention"||!ProcessAlive(runtime))) {
    view.ServiceAttention=true;view.ServiceMessage="Check that both computers are on, signed in to Windows and connected to NetBird. NetCrate will retry automatically.";
   }
   if(settings.Role=="Worker") {
    foreach(string path in Files(Path.Combine(settings.StateRoot,"WorkerJobs"),"*.json")) {
     var data=ReadJson(path);if(data==null)continue;Job job=Get(FromSelector(S(data,"ProjectPath")));if(job==null||T(data,"UpdatedUtc")<job.UpdatedUtc)continue;
     string state=S(data,"State");job.SnapshotId=S(data,"SnapshotId");job.UpdatedUtc=T(data,"UpdatedUtc");job.Active=state=="Processing";
     job.Attention=state=="NeedsAttention";job.BackupCompleted=Hex(job.SnapshotId);job.Phase=job.Attention?"Proxy generation needs attention":job.Active?"Generating proxies":state=="Delivered"?"Proxies delivered":"Results published";
     job.Detail=job.Attention?"Check free space and the job log. NetCrate will retry automatically.":job.Active?"Processing the footage backup.":state=="Delivered"?"The Editing Computer verified the returned files.":"Waiting for the Editing Computer to verify the returned files.";
     string output=S(data,"Output");if(!String.IsNullOrEmpty(output)&&SafeFolders.IsUnder(output,settings.OutputRoot)&&SafeFolders.NoLinks(output))job.ResultFolder=output;
    }
    return;
   }
   foreach(string file in Files(Path.Combine(settings.StateRoot,"Queue"),"*.json").OrderBy(p=>T(ReadJson(p),"CreatedUtc"))) {
    var queue=ReadJson(file);if(queue==null||B(queue,"Sample"))continue;
    Job job=Get(FromSource(S(queue,"Project")));if(job==null)continue;
    DateTime when=T(queue,"CreatedUtc");if(when<job.SourceUtc)continue;
    job.SourceUtc=when;job.UpdatedUtc=T(queue,"UpdatedUtc");job.Revision=S(queue,"Id");job.SnapshotId=S(queue,"SnapshotId");
    job.BackupCompleted=Hex(job.SnapshotId);job.BackupVerified=false;job.Active=true;job.Attention=false;job.Progress=-1;
    string state=S(queue,"State");
    job.Phase=state=="BackingUp"?"Backing up":state=="WaitingForProxies"||state=="Ready"?"Waiting for proxies":state=="NeedsAttention"?"Backup needs attention":"Backup queued";
    job.Detail="Keep both computers on and signed in. NetCrate retries interrupted work automatically.";job.Attention=state=="NeedsAttention";
    string requestId=S(queue,"RequestId");if(!Hex(requestId))continue;
    var progress=ReadJson(Path.Combine(settings.StateRoot,"JobProgress",requestId+".json"));
    if(progress!=null&&S(progress,"SnapshotId")==job.SnapshotId) {
     job.Phase=S(progress,"State")=="NeedsAttention"?"Server needs attention":"Generating proxies";job.Attention=S(progress,"State")=="NeedsAttention";
     job.Detail=job.Attention?"Check the Backup Server's job status. NetCrate will retry automatically.":"The Backup Server is processing this project's footage.";
    }
    var request=ReadJson(Path.Combine(settings.StateRoot,"Requests",requestId+".json"));
    var receipt=ReadJson(Path.Combine(settings.StateRoot,"Receipts",requestId+".json"));
    if(receipt!=null&&S(receipt,"State")=="NeedsAttention") {job.Phase="Returned files unavailable";job.Attention=true;job.Active=false;job.Detail="Some returned files are missing or changed. Your backup remains available.";}
    if(request==null||receipt==null||S(receipt,"State")!="Ready"||S(receipt,"RequestId")!=requestId||S(receipt,"RequestedSnapshotId")!=job.SnapshotId||S(request,"SnapshotId")!=job.SnapshotId)continue;
    string result=S(receipt,"ResultSnapshotId"),destination=S(receipt,"LocalPath");if(!Hex(result))continue;
    string expected=Path.Combine(job.ProjectPath,"Proxies","NetCrate",result);
    if(!String.Equals(destination,expected,StringComparison.OrdinalIgnoreCase)||!SafeFolders.NoLinks(destination))continue;
    var association=receipt.ContainsKey("Association")?receipt["Association"] as IDictionary<string,object>:null;var complete=ReadJson(Path.Combine(destination,"COMPLETE.json"));
    if(association==null||complete==null||S(association,"RequestId")!=requestId||S(association,"RequestedSnapshotId")!=job.SnapshotId||S(association,"ResultSnapshotId")!=result||
      S(association,"WorkerComputer")!=settings.WorkerComputer||S(association,"SourceComputer")!=settings.SourceComputer||S(association,"Recipe")!=S(request,"Recipe")||
      S(association,"JobId")!="auto-"+S(request,"FootageFingerprint")||S(association,"ProjectPath")!=S(request,"ProjectPath")||
      S(complete,"GenerationSnapshotId")!=S(association,"GenerationSnapshotId")||S(complete,"Recipe")!=S(request,"Recipe")||S(complete,"FootageFingerprint")!=S(request,"FootageFingerprint"))continue;
    try {
     if(FileHash(Path.Combine(destination,"COMPLETE.json"))!=S(association,"CompletionSHA256")||FileHash(Path.Combine(destination,"Files-SHA256.csv"))!=S(association,"ResultManifestSHA256"))continue;
     if(!FilesAvailable(destination,(int)N(complete,"Clips"))) {job.Phase="Returned files unavailable";job.Attention=true;job.Active=false;job.Detail="Some returned files are missing or changed. Your backup remains available.";continue;}
    }catch(IOException){continue;}catch(UnauthorizedAccessException){continue;}
    job.Phase="Proxies ready";job.Active=false;job.Attention=false;job.BackupVerified=true;job.Progress=100;job.ResultFolder=destination;job.ResultSnapshot=result;
    job.ProxyFiles=(int)N(complete,"Clips");job.ContactSheets=job.ProxyFiles;job.UpdatedUtc=T(receipt,"VerifiedUtc");
    job.Detail=job.ProxyFiles+" proxies and "+job.ContactSheets+" contact sheets returned and verified.";
    job.AvailableVersions=Directories(Path.GetDirectoryName(destination)).Count(p=>Hex(Path.GetFileName(p)));
   }
  }
  static bool FilesAvailable(string root,int clips) {
   string manifest=Path.Combine(root,"Files-SHA256.csv");if(new FileInfo(manifest).Length>4194304)return false;
   var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);int rows=0;
   foreach(string line in File.ReadLines(manifest).Skip(1)) {
    var match=System.Text.RegularExpressions.Regex.Match(line,"^(?:\"([^\"]*)\"|([^\",]*)),([0-9]+),([a-f0-9]{64})$");
    if(!match.Success)return false;string relative=match.Groups[1].Success?match.Groups[1].Value:match.Groups[2].Value;
    string path=Path.GetFullPath(Path.Combine(root,relative.Replace('/',Path.DirectorySeparatorChar)));
    long bytes;if(!Int64.TryParse(match.Groups[3].Value,out bytes)||!SafeFolders.IsUnder(path,root)||!SafeFolders.NoLinks(path)||!seen.Add(path)||!File.Exists(path)||new FileInfo(path).Length!=bytes)return false;
    rows++;
   }
   return rows==2*clips+1;
  }
 }
}
