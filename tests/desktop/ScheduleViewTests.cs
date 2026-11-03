using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.IO;
using NetCrate;
using NetCrate.Setup;
class ScheduleViewTests {
 static int n;static void Check(bool v,string m){if(!v)throw new Exception(m);n++;}
 [STAThread] static void Main(string[] args){
  Application app=new Application();Fake service=new Fake();ScheduleEditor editor=new ScheduleEditor(service);
  editor.RefreshAsync(CancellationToken.None).GetAwaiter().GetResult();Check(editor.Items.Count==0&&editor.Message.Contains("No automatic"),"Empty guidance missing.");
  editor.SaveAsync("C:\\Files\\日本語","09:15",true,CancellationToken.None).GetAwaiter().GetResult();
  Check(service.Last.Project=="C:\\Files\\日本語"&&service.Last.TimeOfDay=="09:15"&&service.Last.Enabled,"Save lost selected folder or daily time.");
  Check(editor.Items.Count==1&&editor.Items[0].NextRun.Contains("2026")&&editor.Items[0].NextRun.Contains("Eastern"),"Full next date and zone missing.");
  ScheduleItem utc=new ScheduleItem{Enabled=true,NextDueUtc="2026-11-03T14:15:00Z",TimeZone="UTC"};
  ScheduleItem pacific=new ScheduleItem{Enabled=true,NextDueUtc="2026-11-03T14:15:00Z",TimeZone="Pacific Standard Time"};
  Check(utc.NextRun.Contains("14:15 +00:00")&&pacific.NextRun.Contains("06:15 -08:00"),"Displayed date used a stale app-local zone instead of the response zone.");
  utc.CatchUpPending=true;Check(utc.NextRun.Contains("Catch-up pending")&&utc.NextRun.Contains("14:15 +00:00"),"Outstanding catch-up was displayed as an ordinary future run.");
  editor.DisableAsync(editor.Items[0],CancellationToken.None).GetAwaiter().GetResult();Check(service.Action=="DisableSchedule"&&!editor.Items[0].Enabled,"Disable not persisted.");
  service.Fail=true;editor.SaveAsync("C:\\Files","oops",true,CancellationToken.None).GetAwaiter().GetResult();Check(editor.Message=="Choose a valid daily time.","Persistent error missing.");
  service.Fail=false;editor.RefreshAsync(CancellationToken.None,true).GetAwaiter().GetResult();Check(editor.Message=="Choose a valid daily time.","Background refresh erased a persistent action error.");
  ScheduleView view=new ScheduleView(editor,delegate{return "C:\\Files";});
  Check(Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Save schedule"),"Save command inaccessible.");
  Check(Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Disable schedule"),"Disable command inaccessible.");
  Check(Find<TextBlock>(view).Exists(t=>t.Text.Contains("signed in")),"Signed-in prerequisite missing.");
  ListBox list=Find<ListBox>(view)[0];list.SelectedItem=editor.Items[0];
  TextBox daily=Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Daily local time");daily.Text="12:34";
  service.Items=new List<ScheduleItem>{new ScheduleItem{Project="C:\\Files\\日本語",Enabled=true,TimeOfDay="09:15",NextDueUtc="2026-11-03T14:15:00Z",TimeZone="UTC"}};
  view.RefreshStatusAsync().GetAwaiter().GetResult();
  Check(((ScheduleItem)list.SelectedItem).NextRun.Contains("14:15 +00:00")&&daily.Text=="12:34"&&editor.Message=="Choose a valid daily time.","Long-lived schedule refresh lost zone coherence, unsaved time or action error.");
  view.Close();app.Shutdown();
  if(args.Length>0){
   string root=Path.Combine(args[0],"schedule-native-"+Guid.NewGuid().ToString("N")),engine=Path.Combine(root,"Bridge"),setup=Path.Combine(root,"Setup");Directory.CreateDirectory(engine);
   File.WriteAllText(Path.Combine(engine,"Invoke-SetupAction.ps1"),@"param($Action,$InputFile)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$s=Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8|ConvertFrom-Json
@{Succeeded=$true;Code='ok';Message=$s.TimeOfDay;Schedules=@(@{Project=$s.Path;TimeOfDay=$s.TimeOfDay;Enabled=$s.Enabled;NextDueUtc='2026-11-03T14:15:00Z';TimeZone='Eastern Standard Time';CatchUpPending=$true})}|ConvertTo-Json -Depth 8 -Compress
",new System.Text.UTF8Encoding(false));
   WindowsSetupService native=new WindowsSetupService(engine,setup);SetupState state=new SetupState {Role=ComputerRole.EditingComputer,Folder="C:\\Files",BackupMode="Folder"};
   SetupResult result=native.InvokeScheduleAsync("SaveSchedule",state,new ScheduleRequest{Project="C:\\Files\\日本語",TimeOfDay="09:15",Enabled=true},CancellationToken.None).GetAwaiter().GetResult();
   Check(result.Succeeded&&result.Schedules.Count==1&&result.Schedules[0].Project=="C:\\Files\\日本語"&&result.Message=="09:15"&&result.Items.Count==0&&result.Schedules[0].CatchUpPending&&result.Schedules[0].NextRun.Contains("Catch-up pending"),"Native schedule payload or typed response changed.");
   Check(Directory.GetFiles(setup).Length==0,"Native schedule request was retained.");
  }
  Console.WriteLine("PASS: "+n+" schedule view assertions.");
 }
 static List<T> Find<T>(DependencyObject p) where T:DependencyObject{var r=new List<T>();foreach(object c in LogicalTreeHelper.GetChildren(p)){DependencyObject d=c as DependencyObject;if(d!=null){if(d is T)r.Add((T)d);r.AddRange(Find<T>(d));}}return r;}
 class Fake:IScheduleService {
  public ScheduleRequest Last;public string Action;public bool Fail;public List<ScheduleItem> Items=new List<ScheduleItem>();
  public Task<SetupResult> InvokeScheduleAsync(string action,ScheduleRequest request,CancellationToken token){Action=action;Last=request;
   if(Fail)return Task.FromResult(SetupResult.ActionRequired("time","Choose a valid daily time."));
   if(action=="SaveSchedule")Items=new List<ScheduleItem>{new ScheduleItem{Project=request.Project,TimeOfDay=request.TimeOfDay,Enabled=request.Enabled,NextDueUtc="2026-11-03T14:15:00Z",TimeZone="Eastern Standard Time"}};
   if(action=="DisableSchedule")Items[0].Enabled=false;
   var result=SetupResult.Done("Saved.");result.Schedules=Items;return Task.FromResult(result);
  }
 }
}
