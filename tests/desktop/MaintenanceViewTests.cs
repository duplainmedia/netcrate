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
 public string Action,FailAction,ThrowAction; public MaintenanceRequest Request;
 public Task<SetupResult> InvokeMaintenanceAsync(string action,MaintenanceRequest request,CancellationToken token){
  Action=action;Request=request;if(action==ThrowAction)throw new Exception("private diagnostic");
  if(action==FailAction)return Task.FromResult(SetupResult.ActionRequired("fixture","Choose a valid policy."));
  var r=SetupResult.Done("Refreshed");r.Maintenance=new MaintenanceStatus{Preview=new MaintenancePreview{PreviewId="abc",CandidateCount=1,Items=new List<MaintenanceItem>()},Operations=new List<MaintenanceOperation>()};return Task.FromResult(r);
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
  confirm.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
  if(service.Action!="ApplyRetention"||service.Request.PreviewId!="abc"||!service.Request.Confirm)throw new Exception("Confirmation was not explicit and bound to preview.");
  view.Close();app.Shutdown();Console.WriteLine("PASS: maintenance default, buttons, explicit confirmation and persistent errors.");
 }
}
