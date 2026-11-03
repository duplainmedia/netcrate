using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.IO;
using NetCrate.Setup;
class WizardFlowTests {
 static int assertions;
 static void Assert(bool value,string message){if(!value)throw new Exception(message);assertions++;}
 [STAThread] static void Main(){var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
  var service=new FixtureService();var c=new SetupController(service,new Store());var view=new SetupView(c,null,new Pairing());
  Assert(Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Paste recovery details"),"Fresh recovery cannot paste a saved recovery document.");
  c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();
  var folder=Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Full folder path");Assert(folder!=null,"Folder selection has no editable full path.");
  folder.Text=@"C:\OrdinaryFiles";Assert(Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Continue").IsEnabled,"Typing a folder path did not enable validation and continuation.");
  Click(view,"Continue");Pump();
  Assert(c.PreparationPlan!=null,"Entering preparation did not automatically review the read-only software plan.");
  var install=Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Install and prepare");
  Assert(install!=null&&!install.IsEnabled,"Installation was available before software consent.");
  Snapshot(view,"software");
  var consent=Find<CheckBox>(view).Find(b=>AutomationProperties.GetName(b)=="Approve listed software");
  Assert(consent!=null,"Software approval is inaccessible.");consent.IsChecked=true;Pump();Click(view,"Install and prepare");Pump();
  Assert(c.State.Prepared,"Approving and installing did not prepare the computer.");
  Assert(Find<Button>(view).FindAll(b=>Object.Equals(b.Tag,"Primary")&&b.Visibility==Visibility.Visible).Count==1,"Preparation exposes competing primary actions.");
  Click(view,"Continue");Pump();
  Assert(Find<TextBox>(view).Exists(t=>AutomationProperties.GetName(t)=="Other computer private IPv4 address"),"Automatic pairing cannot select its intended peer.");
  Assert(!Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Save connection file"),"Normal pairing still requires a file exchange.");
  Click(view,"Use manual file exchange");Pump();Assert(Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Start a new connection"),"Manual fallback cannot explicitly clear expired or mismatched pending identity.");
  view.Close();Pump();
  PreparationRetry();
  VerifiedToolsResumeReadOnly();
  DefaultServiceWindowCloses();
  RecoveryToolPaths();
  ServerComparisonAndRecovery();
  PairingStates();
  ResumePollsAndFinish();
  RecheckingConnectionDropsOldProof();
  ManualPairingUsesTypedPrivateAddress();
  ManualServerReopenAndError();
  CancelledManualImport();
  ServerReceptionResume();
  app.Shutdown();Console.WriteLine("PASS: "+assertions+" guided wizard flow assertions.");
 }
 static void ServerComparisonAndRecovery(){
  var service=new FixtureService();var c=new SetupController(service,new Store());var pairing=new Pairing();var view=new SetupView(c,null,pairing);
  c.ChooseComputer(ComputerRole.BackupServer);c.Continue();c.ChooseFolderAsync(@"C:\BackupStorage",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();
  Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve listed software").IsChecked=true;Click(view,"Install and prepare");Pump();
  Click(view,"Save recovery details");Pump();
  Assert(Find<Button>(view).Exists(x=>AutomationProperties.GetName(x)=="Save recovery file"),"Server recovery did not get its own required page.");
  Assert(!Find<Button>(view).Find(x=>AutomationProperties.GetName(x)=="Continue").IsEnabled,"Server continued without recovery delivery.");
  c.RecordRecoveryDelivery(null);Assert(!Find<Button>(view).Exists(x=>AutomationProperties.GetName(x)=="Continue with local copy"),"Clipboard-only delivery incorrectly allows local-file continuation.");
  c.RecordRecoveryDelivery(@"C:\Recovery\saved.netcrate");c.RecordRecoveryDelivery(null);
  Assert(c.State.RecoverySavedPath==@"C:\Recovery\saved.netcrate"&&!c.State.RecoveryConfirmed,"Copying recovery contents forgot the saved local file or asserted a separate copy.");
  var copied=new RecoveryTestClipboard();var expiry=new RecoveryTestExpiry();
  using(var document=new RecoveryDocument("{\"Version\":1,\"Kind\":\"netcrate-recovery\",\"Primary\":{\"Id\":\""+new string('a',64)+"\",\"Password\":\"fixture-primary\"},\"Results\":{\"Id\":\""+new string('b',64)+"\",\"Password\":\"fixture-results\"}}"))
  using(var lifetime=new RecoveryClipboardLifetime(copied,expiry)){lifetime.Copy(document);c.RecordRecoveryDelivery(null);expiry.Callback();Assert(copied.Cleared&&c.State.RecoverySavedPath==@"C:\Recovery\saved.netcrate"&&!c.State.RecoveryConfirmed,"Recovery copy expiry lost local-file evidence or asserted a separate copy.");}
  Click(view,"Continue with local copy");
  Assert(c.State.RecoveryLocalOnly&&!c.State.RecoveryConfirmed,"Local recovery was falsely recorded as a separate protected copy.");
  Snapshot(view,"recovery");
  pairing.Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.Idle};Click(view,"Continue");Pump();
  Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="This computer private IPv4 address").Text="192.168.1.20";
  Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Other computer private IPv4 address").Text="192.168.1.10";
  var firewall=Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve temporary setup firewall rule");
  Assert(((TextBlock)firewall.Content).Text.Contains("192.168.1.20")&&((TextBlock)firewall.Content).Text.Contains("192.168.1.10"),"Firewall consent does not describe the exact current local and peer addresses.");
  firewall.IsChecked=true;Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Other computer private IPv4 address").Text="192.168.1.11";
  Assert(Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve temporary setup firewall rule").IsChecked==false,"Editing the intended peer retained visible approval for the old firewall rule.");
  Click(view,"Back");Pump();pairing.Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.CompareConnection,ComparisonCode="1234 5678"};Click(view,"Continue");Pump();
  Snapshot(view,"network-code");
  Assert(!Find<Button>(view).Exists(x=>AutomationProperties.GetName(x)=="Codes match"&&x.IsEnabled),"Server can wrongly confirm its own reply connection code.");
  Assert(!c.State.Connected,"Displaying a comparison code claimed network verification.");
  Assert(Find<TextBox>(view).Exists(x=>x.Text=="1234 5678"&&x.IsReadOnly),"Server cannot display the connection code for comparison on the source.");
  Click(view,"Back");Pump();pairing.Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.Connected};Click(view,"Continue");Pump();Click(view,"Continue");Pump();Click(view,"Finish server setup");Pump();
  Assert(c.State.Step==SetupStep.Complete&&c.LastResult.Message=="Fixture finish verified","Server finish did not complete its backend setup automatically.");
  Assert(Find<Border>(view).Exists(b=>AutomationProperties.GetName(b)=="Sample check: Waiting"),"Server completion falsely claims the source sample passed in the checklist.");
  view.Close();Pump();
 }
 static void VerifiedToolsResumeReadOnly(){
  var c=new SetupController(new FixtureService{PackagesReused=true},new Store());var view=new SetupView(c,null,new Pairing());c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();c.ChooseFolderAsync(@"C:\OrdinaryFiles",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();
  Assert(c.State.Prepared&&!c.SoftwareAccepted,"Verified private tools did not resume through read-only inspection without installation consent.");
  Assert(Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Continue"&&b.IsEnabled),"Read-only resumed preparation cannot continue.");view.Close();Pump();
 }
 static void DefaultServiceWindowCloses(){
  var view=new SetupView(new SetupController(new FixtureService(),new Store()));bool closed=false;view.Closed+=delegate{closed=true;};view.Show();Pump();view.Close();Pump();Assert(closed,"Default service setup window did not close after stopping its owned transport.");
 }
 static void PreparationRetry(){
  var service=new FixtureService{FailPreparation=true};var c=new SetupController(service,new Store());var view=new SetupView(c,null,new Pairing());c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();c.ChooseFolderAsync(@"C:\OrdinaryFiles",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve listed software").IsChecked=true;Click(view,"Install and prepare");Pump();
  Assert(!c.State.Prepared,"A failed package installation marked the computer prepared.");
  Click(view,"Review remaining software");Pump();
  Assert(!c.SoftwareAccepted&&!Find<Button>(view).Find(x=>AutomationProperties.GetName(x)=="Install and prepare").IsEnabled,"Retry reused old consent instead of refreshing the read-only plan.");
  view.Close();Pump();
 }
 static void RecoveryToolPaths(){
  string root=Path.Combine(Path.GetTempPath(),"NetCrateWizardTools-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
  try {string expected=Path.Combine(root,"pwsh.exe");File.WriteAllText(expected,"");
   Assert(SetupView.PlannedExecutable(new SoftwareCheck{Destination=root,Executable="pwsh.exe"})==expected,"Recovery tool executable was resolved against the current folder instead of its reviewed destination.");
   bool rejected=false;try{SetupView.PlannedExecutable(new SoftwareCheck{Destination=root,Executable="missing.exe"});}catch(IOException){rejected=true;}
   Assert(rejected,"Recovery opened before its reviewed tools actually existed.");
  }finally{Directory.Delete(root,true);}
 }
 static void PairingStates(){
  var phases=new[]{NetworkSetupPhase.Idle,NetworkSetupPhase.WaitingForPeer,NetworkSetupPhase.CompareDevice,NetworkSetupPhase.CompareConnection,NetworkSetupPhase.WaitingForAcknowledgment,NetworkSetupPhase.Connected,NetworkSetupPhase.Failed};
  foreach(var phase in phases){
   var c=new SetupController(new FixtureService(),new Store());var pair=new Pairing{Status=new NetworkSetupStatus{Phase=phase,ComparisonCode="ABCD EFGH",Message="Fixture network status"}};var view=new SetupView(c,null,pair);
   c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();c.ChooseFolderAsync(@"C:\OrdinaryFiles",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve listed software").IsChecked=true;Click(view,"Install and prepare");Pump();Click(view,"Continue");Pump();
   Assert(c.State.Connected==(phase==NetworkSetupPhase.Connected),"A pairing phase falsely claimed verified connection: "+phase);
   var primary=Find<Button>(view).Find(b=>Object.Equals(b.Tag,"Primary"));
   Assert(primary!=null,"Pairing has no current primary action: "+phase);
   if(phase==NetworkSetupPhase.WaitingForPeer||phase==NetworkSetupPhase.WaitingForAcknowledgment||phase==NetworkSetupPhase.CompareDevice)Assert(!primary.IsEnabled,"Waiting bypasses remote acknowledgment: "+phase);
   if(phase==NetworkSetupPhase.CompareDevice||phase==NetworkSetupPhase.CompareConnection)Assert(Find<TextBox>(view).Exists(t=>t.IsReadOnly&&t.Text=="ABCD EFGH"),"The required identity comparison is hidden: "+phase);
   if(phase==NetworkSetupPhase.WaitingForPeer)Assert(Find<TextBox>(view).Exists(t=>t.IsReadOnly&&t.Text=="ABCD EFGH"),"Source waiting for server device confirmation hides its device code.");
   if(phase==NetworkSetupPhase.CompareDevice)Snapshot(view,"source-device-code");
   if(phase==NetworkSetupPhase.WaitingForAcknowledgment)Snapshot(view,"network-waiting");
   view.Close();Pump();
  }
 }
 static void ResumePollsAndFinish(){
  foreach(var phase in new[]{NetworkSetupPhase.CompareDevice,NetworkSetupPhase.WaitingForAcknowledgment}){
   var c=new SetupController(new FixtureService(),new Store());var pairing=new Pairing{Status=new NetworkSetupStatus{Phase=phase,ComparisonCode="ABCD EFGH"},PollStatus=new NetworkSetupStatus{Phase=NetworkSetupPhase.Connected}};var view=new SetupView(c,null,pairing);
   c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();c.ChooseFolderAsync(@"C:\OrdinaryFiles",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve listed software").IsChecked=true;Click(view,"Install and prepare");Pump();Click(view,"Continue");Pump();
   var frame=new DispatcherFrame();var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(1800)};timer.Tick+=delegate{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
   Assert(c.State.Connected,"Resumed "+phase+" did not poll automatically to verified connection.");
   Click(view,"Continue");Pump();Click(view,"Test backup and finish");Pump();
   Assert(c.State.Step==SetupStep.Complete&&c.State.SampleVerified&&c.LastResult.Message=="Fixture finish verified","Source finish did not automatically run sample verification before completing backend setup.");
   view.Close();Pump();
  }
 }
 static void RecheckingConnectionDropsOldProof(){
  foreach(var phase in new[]{NetworkSetupPhase.WaitingForAcknowledgment,NetworkSetupPhase.Failed}){
   var c=new SetupController(new FixtureService(),new Store());var pairing=new Pairing{Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.Connected}};var view=new SetupView(c,null,pairing);
   c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();c.ChooseFolderAsync(@"C:\OrdinaryFiles",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();Find<CheckBox>(view).Find(x=>AutomationProperties.GetName(x)=="Approve listed software").IsChecked=true;Click(view,"Install and prepare");Pump();Click(view,"Continue");Pump();Click(view,"Continue");Pump();c.CheckSampleAsync(CancellationToken.None).GetAwaiter().GetResult();Assert(c.State.Connected&&c.State.SampleVerified,"The fixture did not establish current connection and sample proof.");
   pairing.InspectCompletion=new TaskCompletionSource<NetworkSetupStatus>();Click(view,"Back");Pump();
   Assert(!c.State.Connected&&!c.State.SampleVerified,"A fresh network inspection retained old connection or sample proof while pending.");
   pairing.InspectCompletion.SetResult(new NetworkSetupStatus{Phase=phase});Pump();
   Assert(!c.State.Connected&&!c.State.SampleVerified,"A fresh "+phase+" status retained old verified connection evidence.");
   Assert(!Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Continue"&&b.IsEnabled),"A stale connection permits continuing after "+phase);
   view.Close();Pump();
  }
 }
 static void ManualPairingUsesTypedPrivateAddress(){
  var service=new FixtureService{PackagesReused=true,RequiredManualAddress="192.168.1.20"};var c=new SetupController(service,new Store());var view=new SetupView(c,null,new Pairing());
  c.ChooseComputer(ComputerRole.EditingComputer);c.Continue();c.ChooseFolderAsync(@"C:\OrdinaryFiles",CancellationToken.None).GetAwaiter().GetResult();Click(view,"Continue");Pump();Click(view,"Continue");Pump();
  Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="This computer private IPv4 address").Text=" 192.168.1.20 ";Click(view,"Use manual file exchange");Pump();
  Assert(c.State.NetworkAddress=="192.168.1.20","Switching to manual pairing discarded the typed LAN address and still required NetBird.");
  var address=Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Manual pairing private IPv4 address");Assert(address!=null,"Manual pairing has no private address editor.");
  view.ExportManualConnectionAsync(@"C:\fixture-connection.netcrate").GetAwaiter().GetResult();Pump();
  Assert(c.LastResult.Succeeded&&c.PairingStage=="RequestSaved","Manual export did not use the bound LAN address.");
  view.ImportManualConnectionAsync(@"C:\fixture-reply.netcrate").GetAwaiter().GetResult();Pump();
  Assert(c.PairingCode=="ABCD EF01 2345 6789"&&c.PairingStage=="ReplyImported","The manual fixture did not supply an imported reply comparison.");
  Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Manual pairing private IPv4 address").Text="192.168.1.21";Click(view,"Codes match");Pump();
  Assert(!c.State.Connected&&c.State.NetworkAddress=="192.168.1.20"&&c.PairingCode=="ABCD EF01 2345 6789","Confirming with an unapplied changed address silently cleared imported identity evidence.");
  Find<TextBox>(view).Find(t=>AutomationProperties.GetName(t)=="Manual pairing private IPv4 address").Text=" 192.168.1.20 ";Click(view,"Use this private address");Pump();
  Assert(c.PairingCode=="ABCD EF01 2345 6789","Reapplying the same normalized private address cleared an imported comparison code.");
  Snapshot(view,"manual-private-address");
  Assert(!c.State.Connected,"Manual pairing claimed connection verification before the imported code was confirmed.");
  Click(view,"Codes match");Pump();
  Assert(c.State.Connected&&c.LastResult.Succeeded,"Manual confirmation cleared the imported code or lost the normalized LAN address.");
  Click(view,"Continue");Pump();c.CheckSampleAsync(CancellationToken.None).GetAwaiter().GetResult();service.ManualConnectionUnavailable=true;Click(view,"Back");Pump();
  Assert(!c.State.Connected&&!c.State.SampleVerified,"Returning to a failed manual connection retained old connection or sample proof.");
  view.Close();Pump();
 }
 static void ManualServerReopenAndError(){
  var service=new FixtureService{PackagesReused=true,RequiredManualAddress="192.168.1.20",DurableStage="RequestConfirmed",DurableCode="ABCD EF01 2345 6789"};
  var store=new ResumeStore{Saved=new SetupState{Role=ComputerRole.BackupServer,Folder=@"C:\BackupStorage",NetworkAddress="192.168.1.20",RecoveryExported=true,RecoverySavedPath=@"C:\Recovery\keys.netcrate",RecoveryLocalOnly=true}};
  var c=new SetupController(service,store);var view=new SetupView(c,null,new Pairing());view.Show();Pump();Click(view,"Continue");Pump();Click(view,"Use manual file exchange");Pump();
  Assert(c.PairingStage=="RequestConfirmed"&&Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Save reply file"),"Fresh controller manual entry cannot save its confirmed server reply.");
  service.RequiredManualAddress="192.168.1.99";c.ImportConnectionAsync("invalid.netcrate",CancellationToken.None).GetAwaiter().GetResult();Pump();
  Assert(String.IsNullOrEmpty(c.PairingStage),"Mismatched address retained a manual comparison.");
  service.RequiredManualAddress="192.168.1.20";service.ManualConnectionUnavailable=true;c.CheckConnectionAsync(CancellationToken.None).GetAwaiter().GetResult();Pump();
  Assert(!c.LastResult.Succeeded&&c.PairingStage=="RequestConfirmed"&&Find<Button>(view).Exists(b=>AutomationProperties.GetName(b)=="Save reply file"),"Manual error did not hydrate validated backend evidence while retaining its failure.");
  view.Close();Pump();
 }
 class RecoveryTestClipboard:IRecoveryClipboard{public bool Cleared;public uint Write(RecoveryClipboardPayload p){return 1;}public bool ClearIfOwned(uint t){Cleared=true;return true;}}
 class RecoveryTestExpiry:IRecoveryExpiryScheduler{public Action Callback;public IDisposable Schedule(TimeSpan delay,Action callback){Callback=callback;return new Empty();}class Empty:IDisposable{public void Dispose(){}}}
 class ResumeStore:ISetupStore{public SetupState Saved;public SetupState Load(){return Saved.Copy();}public void Save(SetupState s){Saved=s.Copy();}}
 static void CancelledManualImport(){
  var service=new FixtureService{PackagesReused=true,RequiredManualAddress="192.168.1.20"};
  var store=new ResumeStore{Saved=new SetupState{Role=ComputerRole.EditingComputer,Folder=@"C:\OrdinaryFiles",NetworkAddress="192.168.1.20"}};
  var c=new SetupController(service,store);var view=new SetupView(c,null,new Pairing());view.Show();Pump();Click(view,"Continue");Pump();Click(view,"Use manual file exchange");Pump();
  c.ExportConnectionAsync("request.netcrate",CancellationToken.None).GetAwaiter().GetResult();Pump();
  Assert(c.PairingStage=="RequestSaved","Cancellation fixture did not start with the old request comparison.");
  using(var cancel=new CancellationTokenSource()){
   service.CancelAfterImport=cancel;
   c.ImportConnectionAsync("reply.netcrate",cancel.Token).GetAwaiter().GetResult();Pump();
  }
  Assert(c.LastResult.Code=="cancelled"&&String.IsNullOrEmpty(c.PairingCode)&&String.IsNullOrEmpty(c.PairingStage),"Cancelled durable import retained the old request/device comparison.");
  Assert(!Find<TextBox>(view).Exists(t=>AutomationProperties.GetName(t)=="Code to compare with other computer"),"Cancelled import still displays a cached comparison.");
  service.CancelAfterImport=null;c.HydrateManualPairingAsync(CancellationToken.None).GetAwaiter().GetResult();Pump();
  Assert(c.PairingStage=="ReplyImported"&&c.PairingCode=="ABCD EF01 2345 6789","A later uncancelled backend read did not restore the durably imported reply.");
  view.Close();Pump();
 }
 static void ServerReceptionResume(){
  var pair=new Pairing{Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.ReceptionRequired,LocalAddress="192.168.1.20",PeerAddress="192.168.1.10"}};
  var store=new ResumeStore{Saved=new SetupState{Role=ComputerRole.BackupServer,Folder=@"C:\BackupStorage",NetworkAddress="192.168.1.20",RecoveryExported=true,RecoverySavedPath=@"C:\Recovery\keys.netcrate",RecoveryLocalOnly=true}};
  var c=new SetupController(new FixtureService{PackagesReused=true},store);var view=new SetupView(c,null,pair);view.Show();Pump();Click(view,"Continue");Pump();
  var primary=Find<Button>(view).Find(b=>Object.Equals(b.Tag,"Primary"));
  Assert(!primary.IsEnabled&&Find<CheckBox>(view).Exists(b=>AutomationProperties.GetName(b)=="Approve temporary setup firewall rule"),"Reception resume omitted fresh explicit firewall approval.");
  Assert(Find<TextBox>(view).Exists(b=>b.Text=="192.168.1.20")&&Find<TextBox>(view).Exists(b=>b.Text=="192.168.1.10"),"Reception resume lost the original address scope.");
  Find<CheckBox>(view).Find(b=>AutomationProperties.GetName(b)=="Approve temporary setup firewall rule").IsChecked=true;Pump();Click(view,"Allow temporary reception");Pump();
  Assert(pair.LastRequest!=null&&!pair.LastRequest.StartAgain&&pair.LastRequest.ApproveFirewall,"Reception resume requested identity replacement instead of reapproval.");
  view.Close();Pump();
  pair=new Pairing{Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.CompareConnection,ComparisonCode="ABCD EF01 2345 6789",LocalAddress="192.168.1.20",PeerAddress="192.168.1.10"}};
  var retryProperty=typeof(NetworkSetupStatus).GetProperty("CanRetryReception");if(retryProperty!=null)retryProperty.SetValue(pair.Status,true,null);
  c=new SetupController(new FixtureService{PackagesReused=true},store);view=new SetupView(c,null,pair);view.Show();Pump();Click(view,"Continue");Pump();
  Assert(Find<TextBox>(view).Exists(b=>b.IsReadOnly&&b.Text=="ABCD EF01 2345 6789"),"Delivered server reopen lost its comparison code.");
  var retry=Find<Button>(view).Find(b=>AutomationProperties.GetName(b)=="Retry reply delivery");
  Assert(retry!=null&&!retry.IsEnabled&&Find<CheckBox>(view).Exists(b=>AutomationProperties.GetName(b)=="Approve temporary setup firewall rule"),"Closed delivered reply cannot request fresh scoped reception while retaining its code.");
  var scope=(TextBlock)Find<CheckBox>(view).Find(b=>AutomationProperties.GetName(b)=="Approve temporary setup firewall rule").Content;
  Assert(scope.Text.Contains("192.168.1.20")&&scope.Text.Contains("192.168.1.10"),"Reply redelivery consent did not describe the original exact address scope.");
  Find<CheckBox>(view).Find(b=>AutomationProperties.GetName(b)=="Approve temporary setup firewall rule").IsChecked=true;Pump();Click(view,"Retry reply delivery");Pump();
  Assert(pair.LastRequest!=null&&!pair.LastRequest.StartAgain&&pair.LastRequest.ApproveFirewall&&pair.LastRequest.LocalAddress=="192.168.1.20"&&pair.LastRequest.PeerAddress=="192.168.1.10","Reply redelivery replaced the pending identity or bypassed fresh scoped approval.");
  Assert(Find<TextBox>(view).Exists(b=>b.IsReadOnly&&b.Text=="ABCD EF01 2345 6789"),"Reception retry hid the existing connection comparison.");view.Close();Pump();
 }
 static void Snapshot(SetupView view,string name){
  string directory=Path.Combine(Environment.CurrentDirectory,".superpowers","sdd","2026-11-03-guided-setup","ui");Directory.CreateDirectory(directory);
  if(!view.IsVisible){view.Show();Pump();}
  foreach(var size in new[]{new Size(1060,760),new Size(800,600)}){
   view.Width=size.Width;view.Height=size.Height;view.UpdateLayout();Pump();
   var content=(FrameworkElement)view.Content;content.UpdateLayout();
   var bitmap=new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth),(int)Math.Ceiling(content.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(content);
   var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var output=File.Create(Path.Combine(directory,name+"-"+(int)size.Width+".png")))encoder.Save(output);
   var primary=Find<Button>(view).Find(b=>Object.Equals(b.Tag,"Primary"));Assert(primary!=null&&primary.ActualHeight>=44,"Primary action is clipped at "+size.Width+" on "+name);
   var point=primary.TranslatePoint(new Point(0,0),content);Assert(point.X>=0&&point.Y>=0&&point.X+primary.ActualWidth<=content.ActualWidth+1&&point.Y+primary.ActualHeight<=content.ActualHeight+1,"Footer action falls outside visible window on "+name);
  }
 }
 static void Click(DependencyObject root,string name){var b=Find<Button>(root).Find(x=>AutomationProperties.GetName(x)==name);Assert(b!=null&&b.IsEnabled,"Unavailable action: "+name);b.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));}
 static void Pump(){var frame=new DispatcherFrame();Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));Dispatcher.PushFrame(frame);}
 static List<T> Find<T>(DependencyObject root)where T:DependencyObject{var list=new List<T>();if(root is T)list.Add((T)root);foreach(object child in LogicalTreeHelper.GetChildren(root))if(child is DependencyObject)list.AddRange(Find<T>((DependencyObject)child));return list;}
 class Store:ISetupStore{public SetupState Load(){return null;}public void Save(SetupState s){}}
 class FixtureService:ISetupService,ISoftwarePreparationService,IManualPairingStatusService{
  public bool FailPreparation,PackagesReused,ManualConnectionUnavailable;
  public string RequiredManualAddress;
  public CancellationTokenSource CancelAfterImport;
  public string DurableStage,DurableCode;
  public Task<SetupResult> ManualPairingStatusAsync(SetupState s,CancellationToken t){var r=SetupResult.Done("Manual status");if(RequiredManualAddress==null||s.NetworkAddress==RequiredManualAddress){r.PairingStage=DurableStage;r.PairingCode=DurableCode;}return Task.FromResult(r);}
  bool manualConfirmed;
  Task<SetupResult> ManualResult(SetupState state,string stage,string code){if(RequiredManualAddress==null)return Done();if(state.NetworkAddress!=RequiredManualAddress)return Task.FromResult(SetupResult.ActionRequired("netbird-unavailable","No NetBird adapter exists; the explicit LAN address is required."));if(stage!=null){DurableStage=stage;DurableCode=code;}var result=SetupResult.Done("Private-address pairing completed.");result.PairingCode=code;result.PairingStage=stage;return Task.FromResult(result);}
  Task<SetupResult> Done(){return Task.FromResult(SetupResult.Done("Ready"));}
  public Task<SetupResult> CheckFolderAsync(ComputerRole r,string f,CancellationToken t){return Done();}
  public Task<SetupResult> InspectAsync(SetupState s,CancellationToken t){return Done();}
  public Task<SetupResult> ReviewSoftwareAsync(SetupState s,CancellationToken t){var r=SetupResult.Done("Reviewed");r.PreparationPlan=new SoftwarePreparationPlan{PlanId="fixture-plan",Packages=new[]{new SoftwareCheck{Name="Restic",Version="0.19.1",Purpose="Encrypt backups",Source="https://restic.net",License="BSD",Destination=@"C:\Tools\restic",Scope="Private user copy",Status=PackagesReused?"Reused":"Needed"}},Changes=new SoftwareCheck[0]};return Task.FromResult(r);}
  public Task<SetupResult> PrepareApprovedAsync(SetupState s,string p,IProgress<SoftwareProgress> progress,CancellationToken t){return FailPreparation ? Task.FromResult(SetupResult.ActionRequired("download-failed","A package failed.")) : Done();}
  public Task<SetupResult> ReviewNetworkAsync(SetupState s,CancellationToken t){return Done();} public Task<SetupResult> NetworkApprovedAsync(SetupState s,string p,CancellationToken t){return Done();}
  public Task<SetupResult> PrepareAsync(SetupState s,IProgress<string> p,CancellationToken t){throw new Exception("Ungated preparation");}
  public Task<SetupResult> SaveRecoveryAsync(SetupState s,string p,CancellationToken t){return Done();}public Task<SetupResult> ExportConnectionAsync(SetupState s,string p,CancellationToken t){manualConfirmed=false;return ManualResult(s,"RequestSaved","ABCD EF01 2345 6789");}public Task<SetupResult> ImportConnectionAsync(SetupState s,string p,CancellationToken t){manualConfirmed=false;var imported=ManualResult(s,"ReplyImported","ABCD EF01 2345 6789");if(CancelAfterImport!=null)CancelAfterImport.Cancel();return imported;}public Task<SetupResult> ConfirmConnectionAsync(SetupState s,string p,CancellationToken t){if(RequiredManualAddress!=null&&p!="ABCD EF01 2345 6789")return Task.FromResult(SetupResult.ActionRequired("code-missing","The imported comparison code was lost."));manualConfirmed=RequiredManualAddress==null||s.NetworkAddress==RequiredManualAddress;return ManualResult(s,"ReplyConfirmed",p);}public Task<SetupResult> NetworkAsync(SetupState s,CancellationToken t){return Done();}public Task<SetupResult> FinishAsync(SetupState s,CancellationToken t){return Task.FromResult(SetupResult.Done("Fixture finish verified"));}public Task<SetupResult> CheckConnectionAsync(SetupState s,CancellationToken t){return RequiredManualAddress!=null&&!manualConfirmed ? Task.FromResult(SetupResult.ActionRequired("confirm-first","Compare the imported codes before checking the connection.")) : ManualConnectionUnavailable ? Task.FromResult(SetupResult.ActionRequired("offline","The private connection is offline.")) : ManualResult(s,null,null);}public Task<SetupResult> CheckSampleAsync(SetupState s,IProgress<string> p,CancellationToken t){return Done();}
 }
 class Pairing:INetworkPairingService{public NetworkSetupRequest LastRequest;public TaskCompletionSource<NetworkSetupStatus> InspectCompletion;public NetworkSetupStatus PollStatus;public NetworkSetupStatus Status=new NetworkSetupStatus{Phase=NetworkSetupPhase.Idle};public Task<NetworkSetupStatus> InspectAsync(SetupState s,CancellationToken t){return InspectCompletion==null ? Task.FromResult(Status) : InspectCompletion.Task;}public Task<NetworkSetupStatus> StartAsync(SetupState s,NetworkSetupRequest r,CancellationToken t){LastRequest=r;return InspectAsync(s,t);}public Task<NetworkSetupStatus> PollAsync(SetupState s,CancellationToken t){return Task.FromResult(PollStatus ?? Status);}public Task<NetworkSetupStatus> ConfirmAsync(SetupState s,string c,CancellationToken t){return InspectAsync(s,t);}public Task<NetworkSetupStatus> ResetPendingAsync(SetupState s,CancellationToken t){Status=new NetworkSetupStatus();return Task.FromResult(Status);}public Task<NetworkSetupStatus> StopAsync(CancellationToken t){return Task.FromResult(new NetworkSetupStatus());}public void Dispose(){}}
}
