using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using NetCrate;
using NetCrate.Setup;
class RestoreViewTests {
 static int n;static void Check(bool v,string m){if(!v)throw new Exception(m);n++;}
 [STAThread] static void Main(){
  Application app=new Application(); Fake service=new Fake();
  RestoreBrowser browser=new RestoreBrowser(service,new RestoreRequest { RecoveryFile="C:\\offline\\recovery.json",RepositoryPath="D:\\originals" });
  browser.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
  Check(browser.Items.Count==2 && browser.Items[0].BackupCompletedUtc.StartsWith("2024"),"Dates missing.");
  browser.OpenBackupAsync(browser.Items[0],CancellationToken.None).GetAwaiter().GetResult();
  Check(browser.RelativePath=="" && browser.Items.Count==2,"Backup root missing.");
  BackupItem file=browser.Items[0];browser.Select(file);
  Check(browser.Review("E:\\Recovered").Contains("café [1].txt") && browser.Review("E:\\Recovered").Contains("2024"),"Confirmation does not bind selection and date.");
  browser.RestoreAsync("E:\\Recovered",CancellationToken.None).GetAwaiter().GetResult();
  Check(service.Last.RelativePath=="café [1].txt" && service.Last.SnapshotId==new string('a',64),"Literal selection lost.");
  Check(browser.RestoredPath=="E:\\Recovered\\Recovered-verified","Final verified location missing.");
  browser.Select(null);browser.RestoreAsync("E:\\Recovered",CancellationToken.None).GetAwaiter().GetResult();
  Check(service.Last.RelativePath=="","Whole backup selection lost.");
  service.Fail=true;browser.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
  Check(browser.Message=="Reconnect the backup drive." && browser.Items.Count==0,"Error did not clear stale choices.");
  service.Fail=false;service.Empty=true;browser.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
  Check(browser.Items.Count==0 && browser.Message.Contains("No completed"),"Empty backup guidance missing.");
  RestoreView view=new RestoreView(browser);
  Check(Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Restore to a new folder"),"Restore confirmation entry missing.");
  Check(!Find<Button>(view).Exists(b=>Convert.ToString(b.Content).Contains("Prepare")),"Standalone recovery exposes setup controls.");
  view.Close();app.Shutdown();Console.WriteLine("PASS: "+n+" restore browser assertions.");
 }
 static List<T> Find<T>(DependencyObject r) where T:DependencyObject {var a=new List<T>();if(r is T)a.Add((T)r);foreach(object c in LogicalTreeHelper.GetChildren(r))if(c is DependencyObject)a.AddRange(Find<T>((DependencyObject)c));return a;}
 class Fake:IRestoreService {public RestoreRequest Last;public bool Fail,Empty;
 public Task<SetupResult> InvokeRestoreAsync(string action,RestoreRequest request,CancellationToken token){Last=request;
  if(Fail)return Task.FromResult(SetupResult.ActionRequired("drive","Reconnect the backup drive."));
  SetupResult r=SetupResult.Done(Empty?"No completed originals were found.":"Choose files.");
  if(action=="RestoreSelection")r.RestoredPath="E:\\Recovered\\Recovered-verified";
  else if(!Empty && action=="ListBackups"){r.Items.Add(new BackupItem {SnapshotId=new string('a',64),Project="C:\\Old\\日本語",BackupCompletedUtc="2024-01-02T03:04:05Z",Name="January 2"});r.Items.Add(new BackupItem {SnapshotId=new string('b',64),Name="February 3"});}
  else if(!Empty){r.Items.Add(new BackupItem {Name="café [1].txt",RelativePath="café [1].txt",Type="file"});r.Items.Add(new BackupItem {Name="nested",RelativePath="nested",Type="dir"});}
  return Task.FromResult(r);
 }
 }
}
