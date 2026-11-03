using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using NetCrate;
using NetCrate.Setup;
class MaintenanceForegroundFixture {
 static List<T> Find<T>(DependencyObject parent) where T:DependencyObject {
  var result=new List<T>();foreach(object item in LogicalTreeHelper.GetChildren(parent)){var child=item as DependencyObject;if(child!=null){if(child is T)result.Add((T)child);result.AddRange(Find<T>(child));}}return result;
 }
 [STAThread] static int Main(string[] args) {
  if(args.Length!=5)return 2;
  string bridge=args[0],setup=args[1],id=args[2],requests=args[3],marker=args[4],operation=null,error=null;
  var serializer=new JavaScriptSerializer();var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
  var state=new SetupState{InstallationId=id,Role=ComputerRole.BackupServer};
  var editor=new MaintenanceEditor(new BoundMaintenanceService(new WindowsSetupService(bridge,setup),state));
  var view=new MaintenanceView(editor,p=>true){ShowInTaskbar=false,ShowActivated=false};
  view.Closed+=delegate {if(operation!=null)File.WriteAllText(marker,serializer.Serialize(new {OperationId=operation,State="Queued",WindowClosed=true}));app.Shutdown();};
  view.Loaded+=async delegate {
   try {
    for(int i=0;i<900&&(editor.Status==null||editor.Status.Preview==null);i++)await Task.Delay(100);
    var confirm=Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Confirm this preview");
    if(confirm==null||!confirm.IsEnabled||editor.Status==null||editor.Status.Preview==null)throw new Exception("The actual dialog did not load a confirmable preview.");
    confirm.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    for(int i=0;i<900;i++) {
     await Task.Delay(100);
     if(!Directory.Exists(requests))continue;
     foreach(string file in Directory.GetFiles(requests,"*.json")) {
      try {var record=serializer.DeserializeObject(File.ReadAllText(file)) as Dictionary<string,object>;
       if(record!=null&&Convert.ToString(record["Action"])=="ApplyRetention"&&Convert.ToString(record["State"])=="Queued") {operation=Convert.ToString(record["OperationId"]);break;}
      } catch(IOException) {} catch(InvalidOperationException) {}
     }
     if(operation!=null)break;
    }
    if(operation==null)throw new Exception("The dialog did not durably queue confirmed retention.");
   } catch(Exception ex){error=ex.Message;} finally {view.Close();}
  };
  app.Run(view);
  if(error!=null){Console.Error.WriteLine(error);return 1;}
  if(operation==null||!File.Exists(marker)){Console.Error.WriteLine("The dialog did not record its actual close.");return 1;}
  Console.WriteLine("PASS: confirmed retention was queued before the WPF window closed; helper exited.");return 0;
 }
}
