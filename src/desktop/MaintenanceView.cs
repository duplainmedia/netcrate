using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Threading;
using NetCrate.Setup;

namespace NetCrate {
 public sealed class BoundMaintenanceService : IMaintenanceService {
  readonly WindowsSetupService service; readonly SetupState state;
  public BoundMaintenanceService(WindowsSetupService service,SetupState state){this.service=service;this.state=state.Copy();}
  public Task<SetupResult> InvokeMaintenanceAsync(string action,MaintenanceRequest request,CancellationToken token){return service.InvokeMaintenanceAsync(action,state,request,token);}
 }
 public sealed class MaintenanceEditor {
  readonly IMaintenanceService service; bool messageIsError;
  public string Policy {get;set;} public int Count {get;set;} public string Message {get;private set;} public MaintenanceStatus Status {get;private set;}
  public MaintenanceEditor(IMaintenanceService service){this.service=service;Policy="KeepAll";Count=1;Message="Keep all backups is selected.";}
  async Task<bool> Run(string action,MaintenanceRequest request,CancellationToken token,bool preserveError=false){
   try {SetupResult result=await service.InvokeMaintenanceAsync(action,request,token);if(result.Maintenance!=null)Status=result.Maintenance;
    if(!result.Succeeded){Message=result.Message;messageIsError=true;}else if(!preserveError||!messageIsError){Message=result.Message;messageIsError=false;}return result.Succeeded;}
   catch(Exception){Message="Storage controls could not finish. Check the backup drive and try again.";messageIsError=true;return false;}
  }
  public Task<bool> RefreshAsync(CancellationToken token){return Run("StorageStatus",new MaintenanceRequest(),token,true);}
  public Task<bool> CheckAsync(CancellationToken token){return Run("CheckStorage",new MaintenanceRequest(),token);}
  public Task<bool> PreviewAsync(CancellationToken token){return Run("PreviewRetention",new MaintenanceRequest{Policy=Policy,Count=Count},token);}
  public Task<bool> ConfirmAsync(string previewId,CancellationToken token){return Run("ApplyRetention",new MaintenanceRequest{PreviewId=previewId,Confirm=true},token);}
 }
 public sealed class MaintenanceView : Window {
  readonly MaintenanceEditor editor; readonly Func<MaintenancePreview,bool> confirm; readonly TextBlock health=new TextBlock{TextWrapping=TextWrapping.Wrap},message=new TextBlock{TextWrapping=TextWrapping.Wrap},summary=new TextBlock{TextWrapping=TextWrapping.Wrap};
  readonly ComboBox policy=new ComboBox();readonly TextBox count=new TextBox{Text="1",Width=80,HorizontalAlignment=HorizontalAlignment.Left};readonly ListBox list=new ListBox{MinHeight=150};readonly StackPanel actions=new StackPanel{Orientation=Orientation.Horizontal};
  readonly DispatcherTimer refresh=new DispatcherTimer{Interval=TimeSpan.FromSeconds(10)};bool busy;
  public MaintenanceView(MaintenanceEditor editor):this(editor,null){}
  public MaintenanceView(MaintenanceEditor editor,Func<MaintenancePreview,bool> confirm){
   this.editor=editor;this.confirm=confirm??(p=>MessageBox.Show(this,"Remove "+p.CandidateCount+" backups in the displayed preview?","Confirm backup retention",MessageBoxButton.YesNo,MessageBoxImage.Warning)==MessageBoxResult.Yes);Title="Backup storage · NetCrate";Width=850;Height=650;MinWidth=640;MinHeight=480;
   var panel=new StackPanel{Margin=new Thickness(20)};Content=new ScrollViewer{Content=panel};
   panel.Children.Add(new TextBlock{Text="Keep this Backup Server on and signed in. Checks verify repository metadata and structure; they do not read all file data.",TextWrapping=TextWrapping.Wrap});panel.Children.Add(health);
   panel.Children.Add(Button("Check repositories now",async delegate{await Run(()=>editor.CheckAsync(CancellationToken.None));}));
   panel.Children.Add(new TextBlock{Text="Retention policy",Margin=new Thickness(0,14,0,4)});policy.Items.Add("Keep all backups");policy.Items.Add("Keep latest per folder");policy.SelectedIndex=0;AutomationProperties.SetName(policy,"Retention policy");panel.Children.Add(policy);
   panel.Children.Add(new TextBlock{Text="Number of latest backups to keep per folder"});AutomationProperties.SetName(count,"Number to keep per folder");panel.Children.Add(count);
   panel.Children.Add(new TextBlock{Text="Only completed folder backups can be removed. The newest backup per folder, media, older formats, records, and dependent backups are protected. Space saved cannot be estimated exactly.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,8,0,4)});
   panel.Children.Add(actions);actions.Children.Add(Button("Preview retention",async delegate{int n;if(policy.SelectedIndex==1&&(!Int32.TryParse(count.Text,out n)||n<1)){message.Text="Choose a whole number of at least one.";return;}editor.Policy=policy.SelectedIndex==0?"KeepAll":"KeepLatestPerFolder";editor.Count=policy.SelectedIndex==0?1:Int32.Parse(count.Text);await Run(()=>editor.PreviewAsync(CancellationToken.None));}));
   actions.Children.Add(Button("Confirm this preview",async delegate{var p=editor.Status==null?null:editor.Status.Preview;if(p==null){message.Text="Create and review a current preview first.";return;}if(this.confirm(p))await Run(()=>editor.ConfirmAsync(p.PreviewId,CancellationToken.None));}));
   actions.Children.Add(Button("Refresh",async delegate{await Run(()=>editor.RefreshAsync(CancellationToken.None));}));panel.Children.Add(summary);AutomationProperties.SetName(list,"Retention preview");panel.Children.Add(list);panel.Children.Add(message);
   refresh.Tick+=async delegate{await Run(()=>editor.RefreshAsync(CancellationToken.None));};Loaded+=async delegate{await Run(()=>editor.RefreshAsync(CancellationToken.None));refresh.Start();};Closed+=delegate{refresh.Stop();};
  }
  Button Button(string label,Action action){var b=new Button{Content=label,Margin=new Thickness(0,6,8,4),Padding=new Thickness(10,6,10,6)};AutomationProperties.SetName(b,label);b.Click+=delegate{action();};return b;}
  internal Task RefreshStatusAsync(){return Run(()=>editor.RefreshAsync(CancellationToken.None));}
  async Task Run(Func<Task<bool>> action){if(busy)return;busy=true;actions.IsEnabled=false;try{await action();Render();}finally{busy=false;actions.IsEnabled=true;}}
  static string Check(string name,MaintenanceCheck c){if(c==null)return name+": no check yet";string hint=c.Code=="locked"?" Another backup holds the repository; try again later.":c.Code=="unavailable"?" Reconnect the backup drive.":c.Code=="permission"?" Check drive permissions.":c.Code=="credentials"?" Reopen the owning installation.":c.State=="Failed"?" Check the drive and run the check again.":"";return name+": latest "+c.State+" at "+c.LastAttemptUtc+"; last success "+(String.IsNullOrEmpty(c.LastSuccessUtc)?"never":c.LastSuccessUtc)+hint;}
  static string OperationText(MaintenanceOperation op){
   string action=op.Action=="CheckStorage"?"Storage check":op.Action=="PreviewRetention"?"Retention preview":"Retention";
   string state=op.State=="Queued"?"waiting":op.State=="Running"?"in progress":op.State=="NeedsAttention"?"needs attention":"failed";
   string hint=op.Code=="preview-stale"?" Create a new preview.":op.Code=="preview-unavailable"?" Check the drive and backup records before retrying.":op.Code=="forget-uncertain"||op.Code=="prune-interrupted"?" Some cleanup may have completed; create a new preview.":op.Code=="endpoint-restart"?" Check the Backup Server connection.":op.Code=="interrupted"?" The operation stopped; review storage before retrying.":"";
   return action+": "+state+"."+hint;
  }
  void Render(){message.Text=editor.Message;var s=editor.Status;if(s==null)return;health.Text="Free space: "+(s.FreeBytes/(1024L*1024*1024))+" GiB"+(s.LowSpace?" · Low space: free at least 5 GiB.":"")+"\n"+Check("Originals",s.Health==null?null:s.Health.Primary)+"\n"+Check("Results",s.Health==null?null:s.Health.Results);var p=s.Preview;summary.Text=p==null?"No current preview.":"Preview: "+p.CandidateCount+" completed folder backups selected; "+p.ProtectedCount+" originals and records retained. Newest retained: "+(String.IsNullOrEmpty(p.NewestRetainedUtc)?"not available":p.NewestRetainedUtc)+"; expires "+p.ExpiresUtc;list.ItemsSource=p==null?null:p.Items;if(s.Operations!=null){int shown=0;foreach(var op in s.Operations)if((op.State=="Queued"||op.State=="Running"||op.State=="Failed"||op.State=="NeedsAttention")&&shown++<8)summary.Text+="\n"+OperationText(op);}}
 }
}
