using System;
using System.IO;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
namespace NetCrate {
 public partial class JobReader {
  void ApplyProgressReaderHealth(){
   if(String.IsNullOrEmpty(settings.ProgressState))return;var status=ReadJson(Path.Combine(settings.ProgressState,"status.json"));if(status==null)return;DateTime time=T(status,"CheckedUtc");if(time!=DateTime.MinValue)view.ProgressChecked="Office progress checked "+time.ToLocalTime().ToString("h:mm:ss tt");
   if(S(status,"State")=="RetryPending"||(jobs.Values.Any(j=>j.Active)&&time!=DateTime.MinValue&&(DateTime.UtcNow-time).TotalSeconds>60))view.Activity="Live office progress is temporarily unavailable. Jobs continue independently; waiting for fresh status.";
  }
  static double? Number(IDictionary<string,object> d,string key){double n;return Double.TryParse(S(d,key),NumberStyles.Float,CultureInfo.InvariantCulture,out n)&&!Double.IsNaN(n)&&!Double.IsInfinity(n)?(double?)n:null;}
  void ApplyOfficeProgress(){
   if(String.IsNullOrEmpty(settings.ProgressState))return;
   Dictionary<string,string> stages=new Dictionary<string,string>{{"Queued","Queued at WORKER-PC"},{"RestoringOriginals","Restoring footage"},{"Probing","Inspecting clips"},{"GeneratingProxies","Generating proxies"},{"GeneratingContactSheets","Creating contact sheets"},{"Verifying","Verifying generated media"},{"Publishing","Publishing results"},{"Complete","Waiting for download"},{"Failed","Office job needs attention"}};
   foreach(string file in Files(Path.Combine(settings.ProgressState,"Jobs"),"*.json")){
    string id=Path.GetFileNameWithoutExtension(file);if(!Hex(id))continue;var p=ReadJson(file);if(p==null||N(p,"Version")!=1||S(p,"Kind")!="office-media-progress"||S(p,"WorkerComputer")!=settings.WorkerComputer||S(p,"SourceComputer")!=settings.SourceComputer||S(p,"RequestId")!=id||!Hex(S(p,"SourceSnapshotId")))continue;
    string project=FromSelector(S(p,"ProjectPath"));Job j;if(project==null||!jobs.TryGetValue(project,out j)||j.SnapshotId!=S(p,"SourceSnapshotId")||!j.BackupCompleted)continue;
    var replacement=Replacement(j);if(replacement!=null&&S(replacement,"ExpectedJobId").Length>0&&S(p,"JobId")!=S(replacement,"ExpectedJobId"))continue;
    var request=ReadJson(Path.Combine(settings.Outbox,id,"request.json"));if(request==null||S(request,"SnapshotId")!=j.SnapshotId||S(request,"ProjectPath")!=S(p,"ProjectPath")||!File.Exists(Path.Combine(settings.SourceState,"Sent",id+".json")))continue;
    string stage=S(p,"Stage");if(!stages.ContainsKey(stage))continue;DateTime when=T(p,"UpdatedUtc");if(when==DateTime.MinValue||when>DateTime.UtcNow.AddMinutes(2))continue;
    j.OfficeProgress=true;j.OfficeJobId=S(p,"JobId");j.OfficeAttemptId=S(p,"AttemptId");j.EtaSeconds=null;j.Progress=-1;j.ProgressStale=(DateTime.UtcNow-when).TotalSeconds>90&&stage!="Complete"&&stage!="Failed";j.Active=stage!="Failed";j.Attention=stage=="Failed";j.Revision=j.SnapshotId+"|"+S(p,"AttemptId");j.UpdatedUtc=when;
    if(j.ProgressStale){j.Phase="Office status delayed";j.Detail="Waiting for fresh WORKER-PC status. Last update: "+when.ToLocalTime().ToString("h:mm:ss tt")+". The previous ETA is hidden.";continue;}
    j.Phase=stages[stage];long clips=N(p,"TotalClips"),proxies=N(p,"ProxyFilesCompleted"),sheets=N(p,"ContactSheetsCompleted");j.Detail=clips>0?proxies+" of "+clips+" proxies; "+sheets+" of "+clips+" contact sheets completed.":"WORKER-PC is preparing this job.";
    string clip=S(p,"CurrentClip");if(clip.Length>0&&clip.Length<=1024&&!System.Text.RegularExpressions.Regex.IsMatch(clip,@"^[/\\]|:|(^|[/\\])\.\.?($|[/\\])|[\x00-\x1f]"))j.Detail+=" Current clip: "+clip+".";
    if(stage=="Failed")j.Detail="WORKER-PC reported a generation failure. "+S(p,"Message");if(stage=="Complete")j.Detail="WORKER-PC finished publishing. Waiting for this computer to download and verify the results.";
    double? done=Number(p,"StageCompletedUnits"),total=Number(p,"StageTotalUnits");if(done.HasValue&&total.HasValue&&done.Value>=0&&total.Value>0&&done.Value<=total.Value)j.Progress=100*done.Value/total.Value;
    double? eta=Number(p,"EtaSeconds"),sample=Number(p,"EtaSampleSeconds");string scope=S(p,"EtaScope");if(stage!="Queued"&&stage!="Complete"&&stage!="Failed"&&eta.HasValue&&eta.Value>=0&&eta.Value<=2592000&&sample.HasValue&&sample.Value>=30&&(scope=="phase"||scope=="generation")&&S(p,"EtaBasis").Length>0){j.EtaSeconds=Math.Max(0,eta.Value-Math.Max(0,(DateTime.UtcNow-when).TotalSeconds));j.EtaScope=scope;}
    if(j.EtaSeconds.HasValue)j.Detail+=" ETA covers "+(j.EtaScope=="phase"?"this stage":"office generation")+", before source download verification.";
   }
  }
 }
}
