using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using NetCrate;
using NetCrate.Setup;
class FakeMaintenance : IMaintenanceService {
 public string Action,FailAction,ThrowAction,StorageCode="available"; public MaintenanceRequest Request; public List<MaintenanceOperation> Operations=new List<MaintenanceOperation>();
 public Task<SetupResult> InvokeMaintenanceAsync(string action,MaintenanceRequest request,CancellationToken token){
  Action=action;Request=request;if(action==ThrowAction)throw new Exception("private diagnostic");
  if(action==FailAction)return Task.FromResult(SetupResult.ActionRequired("fixture","Choose a valid policy."));
  var r=SetupResult.Done("Refreshed");r.Maintenance=new MaintenanceStatus{StorageCode=StorageCode,FreeBytes=StorageCode=="unavailable"?-1:1024,Health=new MaintenanceHealth{Primary=new MaintenanceCheck{State="Failed",LastAttemptUtc="2026-11-03T05:00:00Z",LastSuccessUtc="2026-01-02T03:04:05Z"}},Preview=new MaintenancePreview{PreviewId="abc",CandidateCount=1,Items=new List<MaintenanceItem>()},Operations=Operations};return Task.FromResult(r);
 }
}
class MaintenanceViewTests {
 static List<T> Find<T>(DependencyObject p) where T:DependencyObject{var r=new List<T>();foreach(object c in LogicalTreeHelper.GetChildren(p)){var d=c as DependencyObject;if(d!=null){if(d is T)r.Add((T)d);r.AddRange(Find<T>(d));}}return r;}
 [STAThread] static void Main(){
  var app=new Application();var service=new FakeMaintenance();var editor=new MaintenanceEditor(service);
  if(editor.Policy!="KeepAll")throw new Exception("Retention must start with Keep all.");
  editor.PreviewAsync(CancellationToken.None).GetAwaiter().GetResult();
  if(service.Action!="PreviewRetention"||service.Request.Policy!="KeepAll")throw new Exception("Keep all preview was not explicit.");
  var view=new MaintenanceView(editor,p=>true);var choice=Find<ComboBox>(view)[0];var count=Find<TextBox>(view)[0];choice.SelectedIndex=1;count.Text="3";
  var preview=Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Preview retention");
  var check=Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Check repositories now");
  var confirm=Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Confirm this preview");
  foreach(string action in new[]{"PreviewRetention","CheckStorage","ApplyRetention"})foreach(bool thrown in new[]{false,true}){
   service.FailAction=thrown?null:action;service.ThrowAction=thrown?action:null;
   (action=="PreviewRetention"?preview:action=="CheckStorage"?check:confirm).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
   string error=editor.Message;if(!error.Contains(thrown?"could not":"valid policy")||error.Contains("private diagnostic"))throw new Exception("Failure was not shown safely.");
   service.FailAction=null;service.ThrowAction=null;view.RefreshStatusAsync().GetAwaiter().GetResult();
   if(choice.SelectedIndex!=1||count.Text!="3"||editor.Message!=error)throw new Exception("Polling discarded an error or unsaved policy.");
  }
  service.StorageCode="unavailable";view.RefreshStatusAsync().GetAwaiter().GetResult();
  if(!Find<TextBlock>(view).Exists(t=>t.Text.Contains("Reconnect the backup drive")&&t.Text.Contains("2026-01-02T03:04:05Z")))throw new Exception("Offline dialog hid the prior successful check.");
  service.StorageCode="unverified";view.RefreshStatusAsync().GetAwaiter().GetResult();
  if(preview.IsEnabled||confirm.IsEnabled||!check.IsEnabled)throw new Exception("Unverified storage enabled retention or disabled health checks.");
  service.StorageCode="available";view.RefreshStatusAsync().GetAwaiter().GetResult();
  confirm.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
  if(service.Action!="ApplyRetention"||service.Request.PreviewId!="abc"||!service.Request.Confirm)throw new Exception("Confirmation was not explicit and bound to preview.");
  service.Operations=new List<MaintenanceOperation>{new MaintenanceOperation{Action="ApplyRetention",State="Succeeded",CreatedUtc="2026-11-03T05:00:00Z"},new MaintenanceOperation{Action="PreviewRetention",State="Failed",Code="preview-limit",CreatedUtc="2026-11-03T04:59:00Z"}};
  view.RefreshStatusAsync().GetAwaiter().GetResult();
  if(!Find<TextBlock>(view).Exists(t=>t.Text.Contains("Retention: completed")&&t.Text.Contains("256")&&t.Text.Contains("newer build")))throw new Exception("Recent success or actionable limit was hidden after polling.");
  var reopened=new MaintenanceView(new MaintenanceEditor(service),p=>true);reopened.RefreshStatusAsync().GetAwaiter().GetResult();
  if(!Find<TextBlock>(reopened).Exists(t=>t.Text.Contains("Retention: completed")&&t.Text.Contains("256")))throw new Exception("Recent terminal outcome was hidden after reopen.");
  reopened.Close();
  view.Close();app.Shutdown();Console.WriteLine("PASS: maintenance default, buttons, explicit confirmation and persistent errors.");
 }
}
