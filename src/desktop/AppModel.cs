using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Diagnostics;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace NetCrate {
 public class Settings {
  public string BackupRecords{get;set;} public string RunsRoot{get;set;} public string Outbox{get;set;}
  public string SourceState{get;set;} public string ReceiverState{get;set;} public string ActiveRoot{get;set;} public string OutputRoot{get;set;} public string ProgressState{get;set;}
  public static Settings Local(){string user=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);return new Settings{BackupRecords=Path.Combine(user,@"OneDrive\Documents\Sample Studio\backup-records"),RunsRoot=Path.Combine(user,@"AppData\Local\OfficeBackup\Runs"),Outbox=@"C:\ProgramData\OfficeMediaSource\Outbox",SourceState=@"C:\ProgramData\OfficeMediaSource\State",ReceiverState=@"C:\ProgramData\OfficeMediaClient\State",ProgressState=@"C:\ProgramData\OfficeMediaProgress\State",ActiveRoot=@"D:\Video Projects",OutputRoot=@"D:\OfficeMediaResults"};}
 }
 public class Job {
  public string Id{get;set;} public string Project{get;set;} public string ProjectPath{get;set;} public string SnapshotId{get;set;}
  public string Phase{get;set;} public string Detail{get;set;} public string ResultFolder{get;set;} public string ResultSnapshot{get;set;} public string Revision{get;set;}
  public bool Active{get;set;} public bool Attention{get;set;} public bool BackupCompleted{get;set;} public bool BackupVerified{get;set;}
  public double Progress{get;set;} public long Bytes{get;set;} public long Files{get;set;} public int ProxyFiles{get;set;} public int ContactSheets{get;set;}
  public DateTime UpdatedUtc{get;set;} public DateTime SourceUtc{get;set;}
  public bool OfficeProgress{get;set;} public bool ProgressStale{get;set;} public double? EtaSeconds{get;set;} public string EtaScope{get;set;}
  public string OfficeJobId{get;set;} public string OfficeAttemptId{get;set;} public int AvailableVersions{get;set;}
  internal Job Copy(){return (Job)MemberwiseClone();}
  public Job(){Progress=-1;Phase="Waiting for status";Detail="";SnapshotId="";Revision="";ResultSnapshot="";}
 }
 public class Dashboard {
  public List<Job> Jobs{get;set;} public bool ServiceAttention{get;set;} public string ServiceMessage{get;set;} public string Activity{get;set;} public string SenderChecked{get;set;} public string ProgressChecked{get;set;} public int UnreadableFiles{get;set;}
  public Dashboard(){Jobs=new List<Job>();ServiceMessage="";Activity="";SenderChecked="";ProgressChecked="";}
 }
 public static class SafeFolders {
  public static bool IsUnder(string path,string root){try{return Path.GetFullPath(path).StartsWith(Path.GetFullPath(root).TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase);}catch{return false;}}
  public static bool NoLinks(string path){try{for(string p=Path.GetFullPath(path);!String.IsNullOrEmpty(p);p=Path.GetDirectoryName(p.TrimEnd('\\'))){if((Directory.Exists(p)||File.Exists(p))&&(File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)return false;}return true;}catch{return false;}}
  public static bool CanOpen(string path,Settings s){return Directory.Exists(path)&&(IsUnder(path,s.ActiveRoot)||IsUnder(path,s.OutputRoot))&&NoLinks(path);}
 }
 public partial class JobReader {
  readonly Settings settings;readonly JavaScriptSerializer json=new JavaScriptSerializer{MaxJsonLength=2097152};Dashboard view;Dictionary<string,Job> jobs;HashSet<string> excluded;
  public JobReader(Settings s){settings=s;}
  static string S(IDictionary<string,object> d,string k){object v;return d!=null&&d.TryGetValue(k,out v)&&v!=null?Convert.ToString(v,System.Globalization.CultureInfo.InvariantCulture):"";}
  static long N(IDictionary<string,object> d,string k){long n;return Int64.TryParse(S(d,k),out n)?n:0;}
  static bool B(IDictionary<string,object> d,string k){return S(d,k).Equals("True",StringComparison.OrdinalIgnoreCase);}
  static DateTime T(IDictionary<string,object> d,string k){DateTime n;return DateTime.TryParse(S(d,k),null,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out n)?n:DateTime.MinValue;}
  static bool Hex(string s){return s!=null&&System.Text.RegularExpressions.Regex.IsMatch(s,"^[a-f0-9]{64}$");}
  static IEnumerable<string> Strings(IDictionary<string,object>d,string k){object o;if(d!=null&&d.TryGetValue(k,out o)&&o is IEnumerable&&!(o is string))foreach(object v in (IEnumerable)o)yield return Convert.ToString(v);}
  IDictionary<string,object> ReadJson(string path){try{if(!File.Exists(path))return null;FileInfo f=new FileInfo(path);if(f.Length>262144||(f.Attributes&FileAttributes.ReparsePoint)!=0){view.UnreadableFiles++;return null;}using(FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))using(StreamReader reader=new StreamReader(stream))return json.DeserializeObject(reader.ReadToEnd()) as IDictionary<string,object>;}catch{view.UnreadableFiles++;return null;}}
  IEnumerable<string> Files(string root,string pattern){try{return Directory.Exists(root)?Directory.GetFiles(root,pattern):new string[0];}catch{view.UnreadableFiles++;return new string[0];}}
  IEnumerable<string> Directories(string root){try{return Directory.Exists(root)?Directory.GetDirectories(root):new string[0];}catch{view.UnreadableFiles++;return new string[0];}}
  string ProjectPath(string name){if(String.IsNullOrWhiteSpace(name)||name=="."||name==".."||name.IndexOfAny(new[]{'\\','/',':','*','?','"','<','>','|','\r','\n'})>=0||name.EndsWith(".")||name.EndsWith(" ")||excluded.Contains(name))return null;return Path.Combine(settings.ActiveRoot,name);}
  string FromSelector(string selector){const string prefix="/D/Video Projects/";return selector.StartsWith(prefix,StringComparison.Ordinal)?ProjectPath(selector.Substring(prefix.Length)):null;}
  string FromSource(string path){try{string full=Path.GetFullPath(path).TrimEnd('\\');return String.Equals(Path.GetDirectoryName(full),Path.GetFullPath(settings.ActiveRoot).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)?ProjectPath(Path.GetFileName(full)):null;}catch{return null;}}
  Job Get(string path){if(path==null)return null;Job job;if(!jobs.TryGetValue(path,out job)){job=new Job{Id=path,ProjectPath=path,Project=Path.GetFileName(path),UpdatedUtc=DateTime.MinValue,SourceUtc=DateTime.MinValue};jobs.Add(path,job);}return job;}
  IDictionary<string,object> Tail(string path,string type){if(!SafeFolders.IsUnder(path,settings.RunsRoot)&&!SafeFolders.IsUnder(path,settings.BackupRecords))return null;try{if(!path.EndsWith(".backup.jsonl",StringComparison.OrdinalIgnoreCase)||!File.Exists(path)||(File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)return null;string text;using(FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){stream.Seek(Math.Max(0,stream.Length-131072),SeekOrigin.Begin);using(StreamReader r=new StreamReader(stream,Encoding.UTF8))text=r.ReadToEnd();}IDictionary<string,object> last=null;foreach(string line in text.Split('\n'))try{var d=json.DeserializeObject(line) as IDictionary<string,object>;if(S(d,"message_type")==type)last=d;}catch{}return last;}catch{return null;}}
  static bool ProcessAlive(IDictionary<string,object> run){try{using(Process p=Process.GetProcessById((int)N(run,"ProcessId"))){if(p.HasExited)return false;DateTime start=T(run,"ProcessStartedUtc");return start!=DateTime.MinValue&&Math.Abs((p.StartTime.ToUniversalTime()-start).TotalSeconds)<2;}}catch{return false;}}
  public Dashboard Read(){
   view=new Dashboard();jobs=new Dictionary<string,Job>(StringComparer.OrdinalIgnoreCase);excluded=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   foreach(string name in Strings(ReadJson(Path.Combine(settings.BackupRecords,"office-backup-queue-control.json")),"ExcludedProjects"))excluded.Add(name);
   ReadReplacementRequests();
   foreach(string path in Files(settings.BackupRecords,"*.backup-result.json")){
    var d=ReadJson(path);if(d==null)continue;Job j=Get(FromSource(S(d,"Source")));if(j==null)continue;
    j.SnapshotId=S(d,"SnapshotId");j.SourceUtc=T(d,"BackupFinishedUtc");if(j.SourceUtc==DateTime.MinValue)j.SourceUtc=T(d,"VerifiedUtc");j.UpdatedUtc=T(d,"VerifiedUtc");
    j.BackupVerified=S(d,"Status")=="Verified"&&Hex(j.SnapshotId);j.BackupCompleted=j.BackupVerified;j.Phase=j.BackupVerified?"Backup verified":"Backup in progress";j.Active=!j.BackupVerified;j.Files=N(d,"VerifiedFileCount");j.Bytes=N(d,"VerifiedBytes");j.Revision=j.SnapshotId;j.Detail=j.BackupVerified?"Original footage passed full restore and checksum verification.":"Reading the existing backup record.";
   }
   foreach(string path in Files(settings.RunsRoot,"*.media-success.json")){
    var d=ReadJson(path);if(d==null||N(d,"BackupExitCode")!=0||!Hex(S(d,"SnapshotId")))continue;
    foreach(string selector in Strings(d,"ProjectPaths")){Job j=Get(FromSelector(selector));if(j==null||T(d,"CreatedUtc")<j.SourceUtc)continue;string snapshot=S(d,"SnapshotId");if(j.SnapshotId!=snapshot)j.BackupVerified=false;j.SnapshotId=snapshot;j.SourceUtc=T(d,"CreatedUtc");j.UpdatedUtc=T(d,"UpdatedUtc");j.BackupCompleted=true;j.Active=true;j.Attention=S(d,"State")=="RetryPending";j.Revision=snapshot;j.Phase=j.Attention?"Request needs attention":"Request queued";j.Detail=j.Attention?"Backup succeeded; its media request is waiting for a successful retry.":"Backup completed. Preparing the automatic office request.";var summary=Tail(S(d,"BackupLog"),"summary");if(summary!=null){j.Files=N(summary,"total_files_processed");j.Bytes=N(summary,"total_bytes_processed");}}
   }
   foreach(string path in Files(settings.RunsRoot,"*.backup-status.json")){
    var d=ReadJson(path);if(d==null)continue;DateTime when=T(d,"StartedUtc");string log=S(d,"LogPath");var summary=Tail(log,"summary");var progress=Tail(log,"status");var media=ReadJson(path.Substring(0,path.Length-".backup-status.json".Length)+".media-success.json");bool hookFailed=summary!=null&&media!=null&&S(media,"SnapshotId")==S(summary,"snapshot_id")&&S(media,"State")=="RetryPending";if(media==null&&S(d,"MediaHookState")=="Failed")hookFailed=true;
    foreach(string selector in Strings(d,"ProjectPaths")){Job j=Get(FromSelector(selector));if(j==null||when<j.SourceUtc||(S(d,"State")=="Completed"&&summary!=null&&j.SnapshotId==S(summary,"snapshot_id")&&!hookFailed))continue;
     j.SourceUtc=when;j.UpdatedUtc=T(d,"UpdatedUtc");j.Revision=S(d,"RunId");j.BackupVerified=false;j.BackupCompleted=false;j.SnapshotId="";j.Active=false;j.Attention=false;j.ResultFolder=null;j.Progress=-1;
     string state=S(d,"State");if(state=="Running"&&ProcessAlive(d)){j.Active=true;j.Phase="Backing up footage";j.Detail="Uploading original footage to WORKER-PC.";double p;if(progress!=null&&Double.TryParse(S(progress,"percent_done"),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out p)){j.Progress=Math.Max(0,Math.Min(100,p*100));j.Files=N(progress,"files_done");j.Bytes=N(progress,"bytes_done");j.Detail=j.Files+" files processed";}}
     else if(state=="Completed"&&summary!=null&&Hex(S(summary,"snapshot_id"))){j.SnapshotId=S(summary,"snapshot_id");j.Revision=j.SnapshotId;j.BackupCompleted=true;j.Active=!hookFailed;j.Attention=hookFailed;j.Phase=hookFailed?"Request needs attention":"Preparing office request";j.Detail=hookFailed?"Footage backup succeeded, but the media request could not be queued. Check the office connection and run the project launcher again.":"Footage backup completed successfully.";j.Files=N(summary,"total_files_processed");j.Bytes=N(summary,"total_bytes_processed");}
     else{bool interrupted=state=="Running"||state=="Interrupted";j.Attention=true;j.Phase=interrupted?"Backup interrupted":"Backup needs attention";j.Detail=interrupted?"The backup process stopped before completion. Run the project launcher again.":"The backup did not complete successfully. Check NetBird and the office connection, then run the project launcher again.";}
    }
   }
   foreach(string dir in Directories(settings.Outbox)){
    if(!Hex(Path.GetFileName(dir)))continue;var request=ReadJson(Path.Combine(dir,"request.json"));if(request==null||S(request,"Kind")!="request"||N(request,"BackupExitCode")!=0||!Hex(S(request,"SnapshotId")))continue;
    Job j=Get(FromSelector(S(request,"ProjectPath")));if(j==null)continue;DateTime when=T(request,"CompletedUtc");if(j.SourceUtc==DateTime.MinValue){j.SourceUtc=when;j.UpdatedUtc=when;j.SnapshotId=S(request,"SnapshotId");j.BackupCompleted=true;j.Revision=j.SnapshotId;}
    if(j.Attention||j.Phase=="Backing up footage"||j.SnapshotId!=S(request,"SnapshotId"))continue;
    var sent=ReadJson(Path.Combine(settings.SourceState,"Sent",Path.GetFileName(dir)+".json"));j.Active=true;j.Progress=-1;j.Phase=sent==null?"Request queued":"Waiting for office results";j.Detail=sent==null?"The sender will retry automatically when WORKER-PC is reachable.":"WORKER-PC received the request. Encoding progress is not available on this computer yet.";
   }
   ApplyOfficeProgress();
   var officeStates=jobs.Values.Where(j=>j.OfficeProgress).ToDictionary(j=>j.Id,j=>j.Copy(),StringComparer.OrdinalIgnoreCase);
   foreach(string path in Files(settings.ReceiverState,"*.json")){
    string id=Path.GetFileNameWithoutExtension(path);if(!Hex(id))continue;var receipt=ReadJson(path);if(receipt==null||S(receipt,"ResultSnapshot")!=id)continue;
    string destination=S(receipt,"Destination");if(!SafeFolders.IsUnder(destination,settings.ActiveRoot)&&!SafeFolders.IsUnder(destination,settings.OutputRoot))continue;
    if(!SafeFolders.NoLinks(destination))continue;var complete=ReadJson(Path.Combine(destination,"COMPLETE.json"));if(complete==null||!B(complete,"verified")||!Hex(S(complete,"snapshot_id"))||N(receipt,"MediaFiles")!=N(complete,"proxy_files")+N(complete,"contact_sheets")||N(complete,"proxy_files")<=0)continue;
    List<Job> candidates=jobs.Values.Where(j=>j.SnapshotId==S(complete,"snapshot_id")&&j.BackupCompleted&&(SafeFolders.IsUnder(destination,Path.Combine(j.ProjectPath,"Proxies"))||j.Project==S(complete,"project")||ExpectedJob(j,receipt))).ToList();
    if(candidates.Count!=1)continue;Job job=candidates[0];if(!SafeFolders.IsUnder(destination,Path.Combine(job.ProjectPath,"Proxies"))&&!SafeFolders.IsUnder(destination,settings.OutputRoot))continue;
    DateTime delivered=T(receipt,"VerifiedUtc");if(delivered==DateTime.MinValue||delivered>DateTime.UtcNow.AddMinutes(2)||!AcceptReplacement(job,id,receipt,complete))continue;
    job.AvailableVersions++;if(!PreferVerifiedVersion(job,id,delivered))continue;
    job.Phase="Proxies ready";job.Active=false;job.Attention=false;job.Progress=100;job.OfficeProgress=false;job.ProgressStale=false;job.EtaSeconds=null;job.BackupCompleted=true;job.ResultFolder=destination;job.ResultSnapshot=id;job.ProxyFiles=(int)N(complete,"proxy_files");job.ContactSheets=(int)N(complete,"contact_sheets");job.UpdatedUtc=delivered;job.Detail=job.ProxyFiles+" proxies and "+job.ContactSheets+" contact sheets downloaded and checksum-verified."+RecipeLabel(complete);
   }
   ApplyReplacementRequests(officeStates);
   var sender=ReadJson(Path.Combine(settings.SourceState,"status.json"));var receiver=ReadJson(Path.Combine(settings.ReceiverState,"status.json"));
   if(sender!=null){DateTime checkedAt=T(sender,"CheckedUtc");if(checkedAt!=DateTime.MinValue)view.SenderChecked="Sender checked "+checkedAt.ToLocalTime().ToString("h:mm tt");if(S(sender,"State")=="RetryPending"||N(sender,"Errors")>0){view.ServiceAttention=true;view.ServiceMessage=String.IsNullOrEmpty(S(sender,"Message"))?"The request sender is retrying an office connection or delivery acknowledgement.":S(sender,"Message");}}
   if(receiver!=null&&S(receiver,"State")=="RetryPending"){view.ServiceAttention=true;view.ServiceMessage="The results receiver needs attention. "+S(receiver,"Message");}
   if(receiver!=null&&S(receiver,"State")=="Receiving")view.Activity="Downloading and verifying generated media from WORKER-PC.";
   ApplyProgressReaderHealth();
   view.Jobs=jobs.Values.OrderByDescending(j=>j.Attention).ThenByDescending(j=>j.Active).ThenByDescending(j=>j.UpdatedUtc).ToList();return view;
  }
 }
 public class Notice{public string Key{get;set;}public string Title{get;set;}public string Message{get;set;}}
 public class NotificationMemory {
  public bool Initialized{get;set;}public bool Enabled{get;set;}public Dictionary<string,bool> Seen{get;set;}public List<Notice> Pending{get;set;}public string LastServiceProblem{get;set;}
  public NotificationMemory(){Seen=new Dictionary<string,bool>();Pending=new List<Notice>();Enabled=true;LastServiceProblem="";}
  public List<Notice> Observe(Dashboard view){List<Notice> notices=new List<Notice>();foreach(Job j in view.Jobs){if(j.BackupCompleted)Add("backup|"+j.Id+"|"+j.SnapshotId,new Notice{Title="Footage backup completed",Message=j.Project+" is backed up to WORKER-PC."},notices);if(j.Phase=="Proxies ready")Add("media|"+j.Id+"|"+j.ResultSnapshot,new Notice{Title="Proxies and contact sheets are ready",Message=j.Project+": "+j.ProxyFiles+" proxies and "+j.ContactSheets+" contact sheets downloaded and verified."},notices);if(j.Attention)Add("attention|"+j.Id+"|"+j.Revision+"|"+j.Phase,new Notice{Title=j.Phase,Message=j.Project+". "+j.Detail},notices);}string service=view.ServiceAttention?view.ServiceMessage:"";if(Initialized&&Enabled&&service.Length>0&&service!=LastServiceProblem)Add("service|"+DateTime.UtcNow.Ticks,new Notice{Title="Office media needs attention",Message=service},notices);LastServiceProblem=service;Initialized=true;return notices;}
  void Add(string key,Notice notice,List<Notice> notices){if(Seen==null)Seen=new Dictionary<string,bool>();if(Pending==null)Pending=new List<Notice>();if(Seen.ContainsKey(key)||Pending.Any(n=>n.Key==key))return;notice.Key=key;if(Initialized&&Enabled){Pending.Add(notice);notices.Add(notice);}else Seen[key]=true;}
  public void MarkDelivered(string key){if(String.IsNullOrEmpty(key))return;if(Seen==null)Seen=new Dictionary<string,bool>();Seen[key]=true;if(Pending!=null)Pending.RemoveAll(n=>n.Key==key);}
  public void SetEnabled(bool enabled){Enabled=enabled;if(!enabled&&Pending!=null)foreach(Notice n in Pending.ToArray())MarkDelivered(n.Key);}
 }
}
