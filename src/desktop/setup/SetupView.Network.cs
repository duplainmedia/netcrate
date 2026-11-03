using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Microsoft.Win32;
namespace NetCrate.Setup {
 public sealed partial class SetupView {
  CheckBox firewallConsent;
  bool updatingFirewall;
  string FirewallDescription() {return "Allow temporary inbound TCP 8201 on "+(String.IsNullOrWhiteSpace(localAddress)?"the selected local address":localAddress)+" only from "+(String.IsNullOrWhiteSpace(peerAddress)?"the intended source address":peerAddress)+" for the verified NetCrate setup helper, for up to 15 minutes. Windows may request administrator approval.";}
  void ResetFirewallConsent() {
   firewallApproved=false;
   if(firewallConsent!=null){updatingFirewall=true;try{firewallConsent.IsChecked=false;firewallConsent.Content=Text(FirewallDescription(),13,Theme.Text);}finally{updatingFirewall=false;}}
   UpdateFooter();
  }
  void ConnectScreen(StackPanel panel) {
   bool server=controller.State.Role==ComputerRole.BackupServer;
   string title="Connect your computers";
   string description=server ? "Select this computer's private address and the intended Editing Computer. Temporary reception accepts only that peer. On the Editing Computer, choose this Backup Server and connect." : "On the Backup Server, select this Editing Computer as the intended source and allow temporary reception. Then connect to its private address here.";
   switch(networkStatus.Phase) {
    case NetworkSetupPhase.CompareDevice:title=server ? "Confirm the Editing Computer" : "Waiting for the Backup Server";description=server ? "Compare the device code on both computers before accepting this source identity." : "On the Backup Server, compare the device code with this screen and choose Codes match.";break;
    case NetworkSetupPhase.CompareConnection:title=server ? "Waiting for the Editing Computer" : "Confirm the Backup Server";description=server ? "On the Editing Computer, compare the connection code with this screen and confirm when every group agrees." : "Compare the connection code with the Backup Server before trusting its encrypted reply and certificate.";break;
    case NetworkSetupPhase.WaitingForPeer:title=server ? "Waiting for the Editing Computer" : "Waiting for the Backup Server";description=server ? "On the Editing Computer, enter this Backup Server's address and choose Connect to Backup Server." : "On the Backup Server, compare the device code with this screen and choose Codes match.";break;
    case NetworkSetupPhase.WaitingForAcknowledgment:title=server ? "Waiting for the Editing Computer" : "Verifying the private connection";description="Keep both setup windows open. NetCrate checks both repositories and the connection acknowledgment automatically.";break;
    case NetworkSetupPhase.Connected:title="Your computers are connected";description="The private connection is verified. Continue to the sample backup step.";break;
    case NetworkSetupPhase.Failed:title="Retry the private connection";description="Check that both computers are on the same private network and that you selected the intended peer.";break;
   }
   if(manualMode){title="Exchange connection files";description="Use this fallback to transfer the existing signed connection files privately between your two computers.";}
   Heading(panel,title,description);

   if(manualMode){ManualScreen(panel);return;}
   panel.Children.Add(Text("Device names from NetBird are hints. Both code comparisons are still required to verify identity.",12,Theme.Muted));
   if(networkStatus.Phase==NetworkSetupPhase.Idle||networkStatus.Phase==NetworkSetupPhase.Failed||networkStatus.Phase==NetworkSetupPhase.ReceptionRequired) {
    panel.Children.Add(Text("This computer's private IPv4 address",13,Theme.Text));
    var local=Input("This computer private IPv4 address",localAddress);local.TextChanged+=delegate{localAddress=local.Text;ResetFirewallConsent();};panel.Children.Add(local);
    panel.Children.Add(Text(server ? "Intended Editing Computer private IPv4 address" : "Backup Server private IPv4 address",13,Theme.Text));
    var remote=Input("Other computer private IPv4 address",peerAddress);remote.TextChanged+=delegate{peerAddress=remote.Text;ResetFirewallConsent();};panel.Children.Add(remote);
    if(networkStatus.Peers!=null&&networkStatus.Peers.Length>0){
     var peers=new ComboBox{ItemsSource=networkStatus.Peers,Margin=new Thickness(0,0,0,12),MinHeight=40};AutomationProperties.SetName(peers,"Available private network peers");
     peers.SelectionChanged+=delegate{var p=peers.SelectedItem as NetworkSetupPeer;if(p!=null){peerAddress=p.Address;firewallApproved=false;Render();}};panel.Children.Add(peers);
    }
    if(server){firewallConsent=Consent("Approve temporary setup firewall rule",FirewallDescription(),firewallApproved,b=>{if(updatingFirewall)return;firewallApproved=b;Render();});panel.Children.Add(firewallConsent);}

    Secondary(panel,"Review NetBird options",async ()=>await ReviewNetBirdAsync());
   }
   switch(networkStatus.Phase) {
    case NetworkSetupPhase.WaitingForPeer:
     panel.Children.Add(Text(server ? "Waiting for the Editing Computer. On that computer, enter this Backup Server's private address and choose Connect to Backup Server." : "Waiting for the Backup Server to accept this source. Compare this device code on both screens and choose Codes match on the Backup Server.",15,Theme.Text));if(!server&&!String.IsNullOrEmpty(networkStatus.ComparisonCode))Code(panel);break;
    case NetworkSetupPhase.CompareDevice:
     panel.Children.Add(Text(server ? "Compare this device code with the Editing Computer. Choose Codes match only when every group agrees. This authorizes the intended source identity." : "Compare this device code on the Backup Server, then choose Codes match there. No repository secrets are released before the server confirms.",14,Theme.Text));Code(panel);break;
    case NetworkSetupPhase.CompareConnection:
     panel.Children.Add(Text(server ? "Compare this connection code with the Editing Computer. On the Editing Computer, choose Codes match only when both screens agree. This server waits for that confirmation." : "Compare this connection code with the Backup Server. It verifies the encrypted reply and the Backup Server certificate. Choose Codes match only when both screens agree.",14,Theme.Text));Code(panel);
     if(server&&networkStatus.CanRetryReception){
      panel.Children.Add(Text("If the Editing Computer is still waiting for the reply, retry delivery of this same reply to the same peer. The comparison code and pending identity stay the same.",13,Theme.Muted));
      firewallConsent=Consent("Approve temporary setup firewall rule",FirewallDescription(),firewallApproved,b=>{if(updatingFirewall)return;firewallApproved=b;Render();});panel.Children.Add(firewallConsent);
      var retry=Button("Retry reply delivery",async ()=>await RunSafeAsync(()=>NetworkActionAsync(false)),false);
      retry.IsEnabled=firewallApproved&&!viewBusy&&!controller.Busy;panel.Children.Add(retry);
     }
     break;
    case NetworkSetupPhase.WaitingForAcknowledgment:
     panel.Children.Add(Text("Waiting for the other computer's confirmation. Leave both setup windows open. NetCrate automatically verifies the repositories and acknowledgment after confirmation.",14,Theme.Text));break;
    case NetworkSetupPhase.Connected:panel.Children.Add(Text("The private connection, both repositories and the acknowledgment passed verification.",14,Theme.Text));break;
   }
   if(!String.IsNullOrEmpty(networkStatus.Message))panel.Children.Add(Text(networkStatus.Message,13,networkStatus.Phase==NetworkSetupPhase.Failed ? Theme.Warning : Theme.Muted));
   if(networkStatus.Phase==NetworkSetupPhase.CompareDevice||networkStatus.Phase==NetworkSetupPhase.CompareConnection)Secondary(panel,"Codes differ — stop",async ()=>{await StopNetworkAsync();viewMessage="Connection stopped. Check that you selected the intended computer, then start again.";Render();});
   if(networkStatus.Phase!=NetworkSetupPhase.Idle&&networkStatus.Phase!=NetworkSetupPhase.Connected)Secondary(panel,"Start again",async ()=>{if(MessageBox.Show(this,"Replace the current pending connection and request a fresh temporary reception lease?","Start connection again",MessageBoxButton.YesNo,MessageBoxImage.Question)==MessageBoxResult.Yes)await RunSafeAsync(()=>NetworkActionAsync(true));});
   Secondary(panel,"Use manual file exchange",async ()=>await RunLocalAsync(async delegate {await StopNetworkAsync();BindManualAddress(false);manualMode=true;await controller.HydrateManualPairingAsync(CheckToken);Render();}));
  }
  void Code(StackPanel panel){var code=Input("Code to compare on both computers",networkStatus.ComparisonCode);code.IsReadOnly=true;code.FontSize=24;code.FontFamily=new System.Windows.Media.FontFamily("Consolas");panel.Children.Add(code);}
  void UpdateFooter(){Control c;if(controls.TryGetValue(PrimaryLabel().Replace("_",""),out c))c.IsEnabled=PrimaryEnabled();}
  async Task InspectNetworkAsync(){await RunLocalAsync(async delegate{InvalidateNetworkProof();networkStatus=await networkService.InspectAsync(controller.State.Copy(),CheckToken);if(!String.IsNullOrEmpty(networkStatus.LocalAddress))localAddress=networkStatus.LocalAddress;if(!String.IsNullOrEmpty(networkStatus.PeerAddress))peerAddress=networkStatus.PeerAddress;AcceptNetworkProof();});StartPolling();}
  async Task NetworkActionAsync(bool again){await RunLocalAsync(async delegate{
   if(!again&&((networkStatus.Phase==NetworkSetupPhase.CompareDevice&&controller.State.Role==ComputerRole.BackupServer)||(networkStatus.Phase==NetworkSetupPhase.CompareConnection&&controller.State.Role==ComputerRole.EditingComputer)))networkStatus=await networkService.ConfirmAsync(controller.State.Copy(),networkStatus.ComparisonCode,CheckToken);
   else networkStatus=await networkService.StartAsync(controller.State.Copy(),new NetworkSetupRequest{LocalAddress=localAddress.Trim(),PeerAddress=peerAddress.Trim(),ApproveFirewall=firewallApproved,StartAgain=again},CheckToken);
   AcceptNetworkProof();
  });StartPolling();}
  void InvalidateNetworkProof(){
   if(!controller.Busy&&controller.State.Step==SetupStep.Connect&&controller.State.Prepared&&(controller.State.Connected||controller.State.SampleVerified))controller.InvalidateNetworkVerification();
  }
  void AcceptNetworkProof(){
   if(networkStatus.Phase==NetworkSetupPhase.Connected){if(!controller.State.Connected)controller.RecordNetworkVerified();}
   else InvalidateNetworkProof();
  }
  bool ShouldPoll(){return (networkStatus.Phase==NetworkSetupPhase.CompareDevice&&controller.State.Role==ComputerRole.EditingComputer)||networkStatus.Phase==NetworkSetupPhase.ReceptionRequired||networkStatus.Phase==NetworkSetupPhase.WaitingForPeer||networkStatus.Phase==NetworkSetupPhase.WaitingForAcknowledgment||(networkStatus.Phase==NetworkSetupPhase.CompareConnection&&controller.State.Role==ComputerRole.BackupServer);}
  void StartPolling(){
   if(networkCancellation!=null||controller.State.Step!=SetupStep.Connect||manualMode)return;
   if(!ShouldPoll())return;
   networkCancellation=new CancellationTokenSource();var source=networkCancellation;Dispatcher.BeginInvoke(new Action(()=>PollNetworkAsync(source)));
  }
  async void PollNetworkAsync(CancellationTokenSource source){
   try{while(!source.IsCancellationRequested&&controller.State.Step==SetupStep.Connect&&!manualMode){
    await Task.Delay(1500,source.Token);if(viewBusy||controller.Busy)continue;
    var status=await networkService.PollAsync(controller.State.Copy(),source.Token);source.Token.ThrowIfCancellationRequested();if(controller.State.Step!=SetupStep.Connect||manualMode)break;networkStatus=status;AcceptNetworkProof();Render();
    if(!ShouldPoll())break;
   }}catch(OperationCanceledException){}catch(Exception){if(source.IsCancellationRequested)return;networkStatus=new NetworkSetupStatus{Phase=NetworkSetupPhase.Failed,Message="Connection status could not be checked. Retry with both computers available."};AcceptNetworkProof();Render();}
   finally{if(networkCancellation==source)networkCancellation=null;source.Dispose();}
  }
  async Task StopNetworkAsync(){if(networkCancellation!=null)networkCancellation.Cancel();try{networkStatus=await networkService.StopAsync(CancellationToken.None);}catch(Exception){networkStatus=new NetworkSetupStatus{Phase=NetworkSetupPhase.Failed,Message="Temporary reception could not be stopped cleanly. Close setup and retry before connecting."};}InvalidateNetworkProof();firewallApproved=false;}
  async Task ReviewNetBirdAsync(){await RunSafeAsync(async delegate{
   await controller.ReviewNetworkSoftwareAsync(CheckToken);var result=controller.LastResult;if(!result.Succeeded)return;
   if(result.NetworkInstalled){await controller.OpenApprovedNetworkAsync(result.NetworkPlanId,CheckToken);return;}
   string details="NetBird is optional. You can use your existing private VPN or LAN instead. Installing NetBird creates a system service and requires administrator approval.\n\n";
   foreach(var p in result.Software)details+=p.Name+" "+p.Version+"\n"+p.Purpose+"\nSource: "+p.Source+"\nLicense: "+p.License+"\nInstall: "+p.Destination+" ("+p.Scope+")\n\n";
   if(MessageBox.Show(this,details+"Approve installing the reviewed NetBird software?","Review NetBird installation",MessageBoxButton.YesNo,MessageBoxImage.Question)==MessageBoxResult.Yes)await controller.OpenApprovedNetworkAsync(result.NetworkPlanId,CheckToken);
  });}
  void ManualScreen(StackPanel panel){
   bool source=controller.State.Role==ComputerRole.EditingComputer;
   panel.Children.Add(Text("This computer's private IPv4 address",13,Theme.Text));
   var address=Input("Manual pairing private IPv4 address",localAddress);
   address.TextChanged+=delegate {localAddress=address.Text;if(!String.Equals(NormalizeManualAddress(localAddress),NormalizeManualAddress(controller.State.NetworkAddress),StringComparison.Ordinal))InvalidateNetworkProof();};panel.Children.Add(address);
   panel.Children.Add(Text("Use an address on your LAN or existing private VPN. Leave blank to use NetBird automatically. Changing the bound address clears comparison codes; create or import fresh connection details afterward.",12,Theme.Muted));
   Secondary(panel,"Use this private address",async ()=>await RunSafeAsync(delegate {BindManualAddress(false);viewMessage=String.IsNullOrEmpty(controller.State.NetworkAddress) ? "Using automatic NetBird address selection." : "Manual pairing uses this computer's private address: "+controller.State.NetworkAddress;return Task.CompletedTask;}));
   panel.Children.Add(Text(source ? "1. Save a connection file and transfer it privately to the Backup Server.\n2. The server opens it and compares the device code with this screen.\n3. The server saves a reply. Transfer it here and open it, then compare the connection code on both computers." : "1. Open the connection file supplied by the Editing Computer.\n2. Compare the device code on both screens, then choose Codes match.\n3. Save a reply and transfer it privately to the Editing Computer. Compare the connection code after the source opens it.",14,Theme.Text));
   if(source)Secondary(panel,"Save connection file",ExportConnection);
   Secondary(panel,source?"Open reply file":"Open connection file",ImportConnection);
   if(!String.IsNullOrEmpty(controller.PairingCode)) {
    var code=Input("Code to compare with other computer",controller.PairingCode);code.IsReadOnly=true;panel.Children.Add(code);
    if(controller.PairingStage=="RequestImported"||controller.PairingStage=="ReplyImported")Secondary(panel,"Codes match",async ()=>await RunSafeAsync(ConfirmManualConnectionAsync));
   }
   if(!source&&(controller.PairingStage=="RequestConfirmed"||controller.PairingStage=="ReplySaved"))Secondary(panel,"Save reply file",ExportConnection);
   Secondary(panel,"Start a new connection",async ()=>{
    if(MessageBox.Show(this,"Clear the pending connection identity and codes? Existing backups and keys are preserved. This action does not open a listener or add a firewall rule.","Start a new connection",MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
    await RunLocalAsync(async delegate {await StopNetworkAsync();networkStatus=await networkService.ResetPendingAsync(controller.State.Copy(),CheckToken);if(networkStatus.Phase==NetworkSetupPhase.Idle)controller.RecordPairingReset();viewMessage=networkStatus.Message;});
   });
   Secondary(panel,"Return to automatic pairing",async ()=>{manualMode=false;await InspectNetworkAsync();});
  }
  static string NormalizeManualAddress(string value){
   if(String.IsNullOrWhiteSpace(value))return null;
   System.Net.IPAddress address;
   return System.Net.IPAddress.TryParse(value.Trim(),out address) ? address.ToString() : value.Trim();
  }
  void BindManualAddress(bool preserveImportedCode){
   string address=NormalizeManualAddress(localAddress);
   if(String.Equals(address,NormalizeManualAddress(controller.State.NetworkAddress),StringComparison.Ordinal))return;
   if(preserveImportedCode&&!String.IsNullOrEmpty(controller.PairingCode))throw new InvalidOperationException("The private address changed. Choose Use this private address, then create or import fresh connection details before comparing codes.");
   controller.UseNetworkAddress(address);localAddress=address ?? "";
  }
  internal Task ExportManualConnectionAsync(string path){BindManualAddress(false);return controller.ExportConnectionAsync(path,CheckToken);}
  internal Task ImportManualConnectionAsync(string path){BindManualAddress(false);return controller.ImportConnectionAsync(path,CheckToken);}
  async Task ConfirmManualConnectionAsync(){
   BindManualAddress(true);
   await controller.ConfirmConnectionAsync(controller.PairingCode,CheckToken);
   if(controller.State.Role==ComputerRole.EditingComputer&&controller.LastResult.Succeeded)await controller.CheckConnectionAsync(CheckToken);
  }
  async Task CheckManualConnectionAsync(){BindManualAddress(true);try{await controller.CheckConnectionAsync(CheckToken);}finally{if(!controller.State.Connected)InvalidateNetworkProof();}}
  async void ExportConnection(){bool source=controller.State.Role==ComputerRole.EditingComputer;var picker=new SaveFileDialog{Title=source?"Save connection file for Backup Server":"Save reply for Editing Computer",FileName=source?"NetCrate connection":"NetCrate reply",DefaultExt=".netcrate",Filter="NetCrate connection|*.netcrate"};if(picker.ShowDialog(this)==true)await RunSafeAsync(()=>ExportManualConnectionAsync(picker.FileName));}
  async void ImportConnection(){var picker=new OpenFileDialog{Title="Open the file from the other computer",Filter="NetCrate connection|*.netcrate",Multiselect=false};if(picker.ShowDialog(this)==true)await RunSafeAsync(()=>ImportManualConnectionAsync(picker.FileName));}
 }
}
