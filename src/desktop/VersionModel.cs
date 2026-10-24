using System;
using System.IO;
using System.Linq;
using System.Collections;
using System.Collections.Generic;
namespace NetCrate {
 public partial class JobReader {
  Dictionary<string,IDictionary<string,object>> replacementRequests;
  Dictionary<string,DateTime> receiptTimes;
  HashSet<string> invalidReplacements;
  void ReadReplacementRequests(){
   replacementRequests=new Dictionary<string,IDictionary<string,object>>(StringComparer.OrdinalIgnoreCase);receiptTimes=new Dictionary<string,DateTime>(StringComparer.OrdinalIgnoreCase);invalidReplacements=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   var data=ReadJson(Path.Combine(settings.BackupRecords,"proxy-replacement-requests.json"));object entries;
   if(data==null||N(data,"Version")!=1||!data.TryGetValue("Projects",out entries)||!(entries is IEnumerable)||entries is string)return;
   foreach(object item in (IEnumerable)entries){
    var entry=item as IDictionary<string,object>;if(entry==null)continue;string project=FromSource(S(entry,"ProjectPath"));string[] baselines=Strings(entry,"BaselineResultSnapshots").ToArray();DateTime requested=T(entry,"RequestedUtc");
    if(project==null||!Hex(S(entry,"SourceSnapshotId"))||baselines.Length==0||baselines.Length>32||baselines.Any(x=>!Hex(x))||requested==DateTime.MinValue||requested>DateTime.UtcNow.AddMinutes(2)||S(entry,"TargetDescription").Length>200)continue;
    replacementRequests[project]=entry;
   }
  }
  IDictionary<string,object> Replacement(Job job){IDictionary<string,object> entry;return replacementRequests.TryGetValue(job.Id,out entry)&&S(entry,"SourceSnapshotId")==job.SnapshotId?entry:null;}
  bool Baseline(IDictionary<string,object> entry,string snapshot){return entry!=null&&Strings(entry,"BaselineResultSnapshots").Contains(snapshot,StringComparer.Ordinal);}
  bool ExpectedJob(Job job,IDictionary<string,object> receipt){var entry=Replacement(job);return entry!=null&&S(entry,"ExpectedJobId").Length>0&&S(entry,"ExpectedJobId")==S(receipt,"JobId");}
  bool AcceptReplacement(Job job,string snapshot,IDictionary<string,object> receipt,IDictionary<string,object> complete){
   var entry=Replacement(job);if(entry==null||Baseline(entry,snapshot)||S(entry,"ExpectedJobId").Length==0)return true;
   if(!ExpectedJob(job,receipt))return false;
   bool valid=S(complete,"proxy_recipe")==S(entry,"ExpectedRecipe")&&N(complete,"proxy_scale_divisor")==N(entry,"ExpectedScaleDivisor")&&N(complete,"proxy_bit_depth")==N(entry,"ExpectedBitDepth")&&S(complete,"proxy_pixel_format")==S(entry,"ExpectedPixelFormat")&&N(complete,"proxy_files")==N(entry,"ExpectedClipCount")&&N(complete,"contact_sheets")==N(entry,"ExpectedClipCount");
   if(!valid)invalidReplacements.Add(job.Id);return valid;
  }
  string RecipeLabel(IDictionary<string,object> complete){return S(complete,"proxy_recipe")=="half-prores-v2"&&N(complete,"proxy_scale_divisor")==2&&N(complete,"proxy_bit_depth")==10&&S(complete,"proxy_pixel_format")=="yuv422p10le"?" Half-resolution, 10-bit 4:2:2 ProRes Proxy (half-prores-v2).":"";}
  bool PreferVerifiedVersion(Job job,string snapshot,DateTime when){
   var entry=Replacement(job);bool incomingNew=entry!=null&&!Baseline(entry,snapshot),existingNew=entry!=null&&Hex(job.ResultSnapshot)&&!Baseline(entry,job.ResultSnapshot);DateTime previous;
   if(job.ResultFolder!=null&&(existingNew&&!incomingNew||(existingNew==incomingNew&&receiptTimes.TryGetValue(job.Id,out previous)&&previous>when)))return false;
   receiptTimes[job.Id]=when;return true;
  }
  void ApplyReplacementRequests(Dictionary<string,Job> officeStates){
   foreach(Job job in jobs.Values){
    var entry=Replacement(job);if(entry==null||!job.BackupCompleted)continue;
    if(Hex(job.ResultSnapshot)&&!Baseline(entry,job.ResultSnapshot)){
     job.Detail="New verified version ("+job.ResultSnapshot.Substring(0,8)+"). "+job.Detail+" Previous versions are retained.";continue;
    }
    string availability=String.IsNullOrEmpty(job.ResultFolder)?"Previous deliveries have not been removed.":"The previous verified proxies remain available.";
    string target="Target: "+S(entry,"TargetDescription").TrimEnd('.')+". ";
    job.Active=true;job.Attention=false;job.Progress=-1;job.EtaSeconds=null;job.EtaScope=null;job.OfficeProgress=false;job.ProgressStale=false;job.Phase="Replacement requested";job.Detail=target+"Waiting for WORKER-PC replacement status. "+availability;job.UpdatedUtc=T(entry,"RequestedUtc");job.Revision=job.SnapshotId+"|replacement|"+S(entry,"RequestedUtc");
    if(invalidReplacements.Contains(job.Id)){job.Active=false;job.Attention=true;job.Phase="Replacement needs attention";job.Detail=target+"The delivered replacement metadata does not match the requested recipe or clip counts. "+availability;continue;}
    Job pending;
    if(!officeStates.TryGetValue(job.Id,out pending)||String.IsNullOrEmpty(pending.OfficeJobId)||String.IsNullOrEmpty(pending.OfficeAttemptId)||(pending.OfficeJobId==S(entry,"BaselineOfficeJobId")&&pending.OfficeAttemptId==S(entry,"BaselineOfficeAttemptId")))continue;
    if(S(entry,"ExpectedJobId").Length>0&&pending.OfficeJobId!=S(entry,"ExpectedJobId"))continue;
    job.Active=pending.Active;job.Attention=pending.Attention;job.OfficeProgress=true;job.ProgressStale=pending.ProgressStale;job.Progress=pending.Progress;job.EtaSeconds=pending.EtaSeconds;job.EtaScope=pending.EtaScope;job.Revision=pending.Revision;job.UpdatedUtc=pending.UpdatedUtc;
    job.Phase=pending.Phase=="Generating proxies"?"Generating replacement":pending.Phase=="Waiting for download"?"Awaiting replacement":pending.Attention?"Replacement needs attention":pending.Phase;
    job.Detail=target+pending.Detail+" "+availability;
   }
  }
 }
}
