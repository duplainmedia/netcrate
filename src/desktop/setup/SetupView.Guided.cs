using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Microsoft.Win32;
using Forms=System.Windows.Forms;
namespace NetCrate.Setup {
 public sealed partial class SetupView {
  readonly INetworkPairingService networkService;
  IRecoveryTransferService recoveryService;
  RecoveryClipboardLifetime clipboard;
  bool viewBusy,recoveryPage,manualMode,closingReady,closingCleanup,setupFinalized;
  string folderDraft,viewMessage="",localAddress="",peerAddress="";
  NetworkSetupStatus networkStatus=new NetworkSetupStatus();
  CancellationTokenSource networkCancellation;
  static string InstallDirectory { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"install"); } }
  static string StateRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"NetCrate","Engine"); } }
  static string SetupDirectory { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"NetCrate","Setup"); } }
  TextBox Input(string name,string value) {
   var box=new TextBox { Text=value ?? "",Background=Theme.Brush(Theme.Surface),Foreground=Theme.Brush(Theme.Text),BorderBrush=Theme.Brush(Theme.Border),Padding=new Thickness(10),Margin=new Thickness(0,8,0,12),MinHeight=40 };
   AutomationProperties.SetName(box,name);controls[name]=box;return box;
  }
  CheckBox Consent(string name,string text,bool selected,Action<bool> changed) {
   var box=new CheckBox { IsChecked=selected,Content=Text(text,13,Theme.Text),Foreground=Theme.Brush(Theme.Text),Margin=new Thickness(0,16,0,12),IsEnabled=!controller.Busy&&!viewBusy };
   AutomationProperties.SetName(box,name);controls[name]=box;box.Checked+=delegate{changed(true);};box.Unchecked+=delegate{changed(false);};return box;
  }
  void Secondary(StackPanel panel,string name,Action action) { var b=Button(name,action,false);b.Margin=new Thickness(0,12,0,0);b.HorizontalAlignment=HorizontalAlignment.Left;panel.Children.Add(b); }
  bool PreparationRetryNeeded { get { return !controller.State.Prepared&&controller.PreparationPlan!=null&&!controller.LastResult.Succeeded&&controller.LastResult.Code!="prepare-needed"; } }
  string PrimaryLabel() {
   if(controller.State.Step==SetupStep.Prepare) {
    if(recoveryPage)return "Continue";
    if(controller.State.Prepared)return controller.NeedsRecovery ? "Save recovery details" : "Continue";
    if(PreparationRetryNeeded)return "Review remaining software";
    return controller.PreparationPlan==null ? "Review software" : "Install and prepare";
   }
   if(controller.State.Step==SetupStep.Connect) {
    if(controller.State.Connected)return "Continue";
    if(manualMode)return "Check connection";
    if(networkStatus.Phase==NetworkSetupPhase.CompareConnection&&controller.State.Role==ComputerRole.BackupServer)return "Waiting for source confirmation";
    if(networkStatus.Phase==NetworkSetupPhase.CompareDevice&&controller.State.Role==ComputerRole.EditingComputer)return "Waiting for server confirmation";
    if(networkStatus.Phase==NetworkSetupPhase.CompareDevice||networkStatus.Phase==NetworkSetupPhase.CompareConnection)return "Codes match";
    if(networkStatus.Phase==NetworkSetupPhase.WaitingForPeer||networkStatus.Phase==NetworkSetupPhase.WaitingForAcknowledgment)return "Waiting for other computer";
    return controller.State.Role==ComputerRole.BackupServer ? "Allow temporary reception" : "Connect to Backup Server";
   }
   if(controller.State.Step==SetupStep.Check)return controller.State.Role==ComputerRole.BackupServer ? "Finish server setup" : controller.State.SampleVerified ? "Continue" : "Test backup and finish";
   return controller.State.Step==SetupStep.Complete ? (setupFinalized ? "Open NetCrate" : "Finish setup") : "_Continue";
  }
  bool firewallApproved;
  bool PrimaryEnabled() {
   if(controller.Busy||viewBusy)return false;
   switch(controller.State.Step) {
    case SetupStep.Computer:return controller.CanContinue;
    case SetupStep.Folders:return !String.IsNullOrWhiteSpace(folderDraft ?? controller.State.Folder);
    case SetupStep.Prepare:return recoveryPage ? controller.CanContinue : controller.State.Prepared||controller.PreparationPlan==null||PreparationRetryNeeded||controller.SoftwareAccepted;
    case SetupStep.Connect:
     if(controller.State.Connected||manualMode)return true;
     if(networkStatus.Phase==NetworkSetupPhase.WaitingForPeer||networkStatus.Phase==NetworkSetupPhase.WaitingForAcknowledgment)return false;
     if(networkStatus.Phase==NetworkSetupPhase.CompareConnection&&controller.State.Role==ComputerRole.BackupServer)return false;
     if(networkStatus.Phase==NetworkSetupPhase.CompareDevice&&controller.State.Role==ComputerRole.EditingComputer)return false;
     if(networkStatus.Phase==NetworkSetupPhase.CompareDevice||networkStatus.Phase==NetworkSetupPhase.CompareConnection)return !String.IsNullOrEmpty(networkStatus.ComparisonCode);
     return controller.State.Role!=ComputerRole.BackupServer||firewallApproved;
    case SetupStep.Check:return controller.State.Connected;
    default:return true;
   }
  }
  async Task PrimaryAsync() { await RunSafeAsync(async delegate {
   switch(controller.State.Step) {
    case SetupStep.Folders:
     await controller.ChooseFolderAsync(folderDraft ?? controller.State.Folder,CheckToken);if(!controller.CanContinue)return;break;
    case SetupStep.Prepare:
     if(!recoveryPage&&!controller.State.Prepared) {
      if(controller.PreparationPlan==null||PreparationRetryNeeded)await controller.ReviewSoftwareAsync(CheckToken);else await controller.PrepareAsync(CheckToken);
      return;
     }
     if(!recoveryPage&&controller.NeedsRecovery){recoveryPage=true;Render();return;}break;
    case SetupStep.Connect:
     if(!controller.State.Connected) { if(manualMode)await CheckManualConnectionAsync();else await NetworkActionAsync(false);return; }break;
    case SetupStep.Check:
     if(controller.State.Role==ComputerRole.EditingComputer&&!controller.State.SampleVerified){await controller.CheckSampleAsync(CheckToken);if(!controller.State.SampleVerified)return;}break;
    case SetupStep.Complete:
     if(!setupFinalized){await controller.FinishAsync(CheckToken);setupFinalized=controller.LastResult.Succeeded;Render();return;}SetupCompleted=true;Close();return;
   }
   controller.Continue();if(controller.State.Step==SetupStep.Complete){await controller.FinishAsync(CheckToken);setupFinalized=controller.LastResult.Succeeded;Render();}else await EnterStepAsync();FocusFirst();
  }); }
  async Task GoBackAsync() { await RunSafeAsync(async delegate {
   if(controller.State.Step==SetupStep.Connect)await StopNetworkAsync();
   if(recoveryPage&&controller.State.Step==SetupStep.Prepare){recoveryPage=false;Render();return;}
   controller.Back();await EnterStepAsync();FocusFirst();
  }); }
  async Task EnterStepAsync() {
   if(controller.State.Step==SetupStep.Prepare&&!controller.State.Prepared&&!checkingSoftware) {
    checkingSoftware=true;try {
     await RunSafeAsync(async delegate {await controller.ReviewSoftwareAsync(CheckToken);
      if(controller.PreparationPlan!=null&&AllPackagesReady(controller.PreparationPlan))await controller.InspectAsync(CheckToken);
     });
    }finally{checkingSoftware=false;}
   }
   if(controller.State.Step==SetupStep.Connect){
    if(manualMode)await RunSafeAsync(async delegate {InvalidateNetworkProof();await CheckManualConnectionAsync();});
    else await InspectNetworkAsync();
   }
  }
  static bool AllPackagesReady(SoftwarePreparationPlan plan){if(plan.ApplicationUpdateNeeded||plan.Packages==null||plan.Packages.Length==0)return false;foreach(var p in plan.Packages)if(!p.Available&&!String.Equals(p.Status,"Reused",StringComparison.Ordinal))return false;return true;}
  void PrepareScreen(StackPanel panel) {
   Heading(panel,controller.State.Prepared ? "This computer is prepared" : "Review software before installation","NetCrate uses private, pinned copies for your Windows account. Existing system versions are not replaced. Downloads and setup start only after your approval.");
   if(controller.PreparationPlan!=null) {
    if(controller.PreparationPlan.ApplicationUpdateNeeded)panel.Children.Add(Text("NetCrate "+controller.PreparationPlan.ApplicationVersion+" will be installed/updated for this Windows account.",13,Theme.Text));
    PlanRows(panel,controller.PreparationPlan);
   }
   foreach(var row in controller.SoftwareProgressRows.Values)panel.Children.Add(Text(row.Scope+" � "+row.Name+" "+row.Version+" · "+row.Phase+" ("+row.Completed+" / "+row.Total+")",13,row.Phase=="Failed" ? Theme.Warning : Theme.Muted));
   if(!controller.State.Prepared&&controller.PreparationPlan!=null)panel.Children.Add(Consent("Approve listed software","I approve the listed software, download sources and install locations.",controller.SoftwareAccepted,b=>controller.SetSoftwareAccepted(b)));
   panel.Children.Add(Text("Setup creates a shortcut. Background tasks start after pairing. Private network permissions are reviewed separately during connection setup.",12,Theme.Muted));
   if(controller.PreparationPlan!=null)Secondary(panel,"Check again",async ()=>await RunSafeAsync(()=>controller.ReviewSoftwareAsync(CheckToken)));
  }
  void PlanRows(StackPanel panel,SoftwarePreparationPlan plan) {
   foreach(var p in plan.Packages ?? new SoftwareCheck[0]) {
    var row=new Border{Background=Theme.Brush(Theme.Surface),BorderBrush=Theme.Brush(Theme.Border),BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(6),Padding=new Thickness(15),Margin=new Thickness(0,0,0,10)};
    var words=new StackPanel();row.Child=words;
    words.Children.Add(Text(p.Name+" "+p.Version+" · "+(p.Status ?? (p.Available ? "Ready / reused" : "Needed")),15,Theme.Text));
    words.Children.Add(Text(p.Purpose+"\n"+p.Scope+"\nInstall: "+p.Destination+"\nSource: "+p.Source+"\nLicense: "+p.License,12,Theme.Muted));panel.Children.Add(row);
   }
  }
  internal static SaveFileDialog CreateRecoverySaveDialog() {return new SaveFileDialog{Title="Save recovery details",FileName="NetCrate recovery",DefaultExt=".netcrate",Filter="NetCrate recovery|*.netcrate",OverwritePrompt=false};}
  void RecoveryScreen(StackPanel panel) {
   Heading(panel,"Keep your recovery details","You need this recovery document if the Backup Server fails. Save a file on an ordinary local folder, or copy the complete document to a password manager or private document.");
   Secondary(panel,"Save recovery file",async ()=>await SaveRecoveryAsync());
   Secondary(panel,"Copy recovery contents",async ()=>await CopyRecoveryAsync());
   panel.Children.Add(Text("Copied contents are sensitive. NetCrate excludes them from clipboard history and cloud sync and clears its own clipboard after two minutes. Copying alone does not confirm a saved copy.",12,Theme.Muted));
   if(controller.State.RecoveryExported) {
    if(!String.IsNullOrEmpty(controller.State.RecoverySavedPath)) {
     panel.Children.Add(Text("Saved locally: "+controller.State.RecoverySavedPath,14,Theme.Text));
     Secondary(panel,"Show file",()=>Process.Start(new ProcessStartInfo("explorer.exe","/select,\""+controller.State.RecoverySavedPath+"\""){UseShellExecute=true}));
     panel.Children.Add(Text("If this PC and this local copy are lost, recovery will be impossible. A separate accessible copy protects against that loss.",13,Theme.Warning));
     Secondary(panel,"Continue with local copy",()=>controller.ContinueWithLocalRecovery());
    }
    panel.Children.Add(Consent("Separate recovery copy confirmed","I have saved a separate accessible copy of the complete recovery details.",controller.State.RecoveryConfirmed,b=>controller.SetRecoveryConfirmed(b)));
   }
   Secondary(panel,"Clear clipboard now",()=>{try{if(clipboard!=null)clipboard.ClearNow();viewMessage="NetCrate's recovery clipboard contents were cleared, if still owned.";}catch(Win32Exception){viewMessage="The clipboard is busy. Try Clear clipboard now again.";}Render();});
   if(controller.State.RecoveryLocalOnly)panel.Children.Add(Text("Continuing with a local copy only. A separate copy has not been confirmed.",13,Theme.Warning));
  }
  IRecoveryTransferService ExistingRecoveryService() {
   if(recoveryService!=null)return recoveryService;
   var record=new JavaScriptSerializer().DeserializeObject(File.ReadAllText(Path.Combine(StateRoot,"tools.json"))) as Dictionary<string,object>;
   if(record==null)throw new IOException();
   string ps=FindTool(record,"PowerShell"),restic=FindTool(record,"Restic");
   if(String.IsNullOrEmpty(ps)||String.IsNullOrEmpty(restic))throw new IOException();
   recoveryService=new RecoveryTransferService(InstallDirectory,ps,restic);return recoveryService;
  }
  internal static string PlannedExecutable(SoftwareCheck package) {
   if(package==null||String.IsNullOrWhiteSpace(package.Destination)||!Path.IsPathRooted(package.Destination)||String.IsNullOrWhiteSpace(package.Executable))throw new IOException("Recovery tools are not ready.");
   string root=Path.GetFullPath(package.Destination).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;
   string executable=Path.GetFullPath(Path.Combine(root,package.Executable));
   if(!executable.StartsWith(root,StringComparison.OrdinalIgnoreCase)||!File.Exists(executable))throw new IOException("Recovery tools are not ready.");
   return executable;
  }
  static string FindTool(Dictionary<string,object> record,string name) {
   foreach(var item in record) {
    var nested=item.Value as Dictionary<string,object>;
    if(String.Equals(item.Key,name,StringComparison.OrdinalIgnoreCase)) {
     if(item.Value is string)return (string)item.Value;
     if(nested!=null){object executable;if(nested.TryGetValue("Executable",out executable))return Convert.ToString(executable);if(nested.TryGetValue("Path",out executable))return Convert.ToString(executable);}
    }
    if(nested!=null){string found=FindTool(nested,name);if(found!=null)return found;}
   }return null;
  }
  async Task SaveRecoveryAsync() {await RunLocalAsync(async delegate {
   var service=ExistingRecoveryService();var dialog=CreateRecoverySaveDialog();dialog.FileName=service.SuggestSavePath(StateRoot,controller.State.Folder);
   if(dialog.ShowDialog(this)!=true)return;
   var result=await service.SaveAsync(StateRoot,dialog.FileName,CheckToken);viewMessage=result.Message;
   if(result.Succeeded)controller.RecordRecoveryDelivery(result.SavedPath);
  });}
  async Task CopyRecoveryAsync(){await RunLocalAsync(async delegate{if(clipboard==null)throw new InvalidOperationException("Open the setup window before copying recovery details.");using(var document=await ExistingRecoveryService().ExportContentsAsync(StateRoot,CheckToken))clipboard.Copy(document);controller.RecordRecoveryDelivery(null);viewMessage="Recovery contents copied for two minutes. Save the complete document in your chosen private location.";});}
  async Task OpenIndependentRecoveryAsync(bool paste) {await RunLocalAsync(async delegate {
   if(recoveryService==null) {
    var windows=restoreService as WindowsSetupService ?? new WindowsSetupService(InstallDirectory);
    var result=await windows.ReviewRecoveryToolsAsync(CheckToken);
    var plan=result.PreparationPlan;if(!result.Succeeded||plan==null){viewMessage=result.Message;return;}
    if(plan.Changes!=null&&plan.Changes.Length>0) {
     string summary="Recovery needs these private tools before browsing backups:\n\n";
     foreach(var p in plan.Packages ?? new SoftwareCheck[0])summary+=p.Name+" "+p.Version+"\n"+p.Purpose+"\n"+p.Source+"\nLicense: "+p.License+"\nInstall: "+p.Destination+" ("+p.Scope+")\n\n";
     if(MessageBox.Show(this,summary+"Approve downloading and installing these tools?","Review recovery software",MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
     result=await windows.InstallRecoveryToolsAsync(plan.PlanId,new Progress<SoftwareProgress>(),CheckToken);if(!result.Succeeded){viewMessage=result.Message;return;}
     if(result.PreparationPlan!=null)plan=result.PreparationPlan;
    }
    string ps=null,restic=null;foreach(var p in plan.Packages ?? new SoftwareCheck[0]){if(p.Name=="PowerShell")ps=PlannedExecutable(p);if(p.Name=="Restic")restic=PlannedExecutable(p);}
    if(String.IsNullOrEmpty(ps)||String.IsNullOrEmpty(restic))throw new IOException();recoveryService=new RecoveryTransferService(InstallDirectory,ps,restic);
   }
   if(paste)RecoveryPasteWindow.Open(this,recoveryService);else NetCrate.RestoreView.OpenRecovery(this,restoreService);
  });}
  void CheckScreen(StackPanel panel){Heading(panel,"Verify a sample backup",controller.State.Role==ComputerRole.EditingComputer ? "Choose Test backup and finish to automatically back up a generated sample, restore a disposable copy and compare its contents." : "The Editing Computer starts the sample check. Finish local server setup, then keep this computer on and signed in while the source verifies its sample.");}
  void CompleteScreen(StackPanel panel){
   if(!setupFinalized){Heading(panel,"Finish setup","NetCrate is saving the verified setup and starting its background tasks. If the operation could not finish, choose Finish setup to retry.");return;}
   Heading(panel,controller.State.Role==ComputerRole.EditingComputer ? "Your computers are ready" : "Backup Server setup is complete",controller.State.Role==ComputerRole.EditingComputer ? "The sample backup and restore passed verification." : "Waiting for the Editing Computer's sample. A sample has not yet been verified here. Keep this computer on and signed in.");
  }

  void BuildFooter(Grid main) {
   var footer=new Grid{Margin=new Thickness(0,16,0,0)};footer.ColumnDefinitions.Add(new ColumnDefinition());footer.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});Grid.SetRow(footer,1);main.Children.Add(footer);
   var back=Button("_Back",async ()=>await GoBackAsync(),false);back.HorizontalAlignment=HorizontalAlignment.Left;back.Visibility=controller.State.Step==SetupStep.Computer ? Visibility.Hidden : Visibility.Visible;footer.Children.Add(back);
   var next=Button(PrimaryLabel(),async ()=>await PrimaryAsync(),true);next.IsEnabled=PrimaryEnabled();next.IsDefault=true;next.MinWidth=128;Grid.SetColumn(next,1);footer.Children.Add(next);
   if((controller.Busy&&!controller.IsInstalling)||viewBusy) {
    back.Visibility=Visibility.Collapsed;var cancel=Button("Cancel check",async ()=>await CancelCurrentAsync(),false);cancel.IsEnabled=!controller.IsInstalling;cancel.HorizontalAlignment=HorizontalAlignment.Left;footer.Children.Add(cancel);
   }
  }
  async Task CancelCurrentAsync() {
   if(checkCancellation!=null)checkCancellation.Cancel();
   if(networkCancellation!=null)networkCancellation.Cancel();
   if(controller.State.Step==SetupStep.Connect) {await StopNetworkAsync();viewMessage="Temporary reception stopped. Choose Connect again when both computers are ready.";Render();}
  }
  async Task RunLocalAsync(Func<Task> action){if(viewBusy)return;viewBusy=true;Render();try{await RunSafeAsync(action);}finally{viewBusy=false;Render();}}
  async Task RunSafeAsync(Func<Task> action){viewMessage="";var previous=checkCancellation;var current=new CancellationTokenSource();checkCancellation=current;try{await action();}catch(OperationCanceledException){viewMessage="Setup paused. Retry when both computers are ready.";}catch(IOException){viewMessage="This action could not finish. Check the exact selected path, free space and permissions. Choose an ordinary local folder outside NetCrate and backup storage.";}catch(UnauthorizedAccessException){viewMessage="The selected folder is not writable. Choose an ordinary folder owned by your Windows account.";}catch(InvalidOperationException error){viewMessage=error.Message;}catch(Win32Exception){viewMessage="Windows could not complete this action. Try again.";}finally{checkCancellation=previous;current.Dispose();Render();}}
  void ShowSaveError(){viewMessage="Setup choices could not be saved. Check free space and permissions in your Windows user folder.";Render();}
  void FocusFirst(){foreach(var c in controls.Values)if(c.IsEnabled){c.Focus();break;}}
  async void OnClosing(object sender,CancelEventArgs args){
   if(closingReady)return;
   if(controller.Busy||viewBusy){args.Cancel=true;if(!controller.IsInstalling&&checkCancellation!=null)checkCancellation.Cancel();if(networkCancellation!=null)networkCancellation.Cancel();viewMessage="Wait for the current action to stop, then close setup.";return;}
   try{if(clipboard!=null)clipboard.ClearNow();}catch(Win32Exception){args.Cancel=true;viewMessage="Clipboard is busy. Recovery expiry remains active; retry closing shortly.";Render();return;}
   args.Cancel=true;if(closingCleanup)return;closingCleanup=true;
   try{await StopNetworkAsync();closingReady=true;await Dispatcher.InvokeAsync(new Action(Close));}finally{closingCleanup=false;}
  }
  sealed class WindowOwner:Forms.IWin32Window{public IntPtr Handle{get;private set;}public WindowOwner(IntPtr h){Handle=h;}}
 }
}
