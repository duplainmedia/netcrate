using System;
using System.Threading;
using System.Threading.Tasks;
using NetCrate.Setup;
class SoftwareConsentTests {
 static int assertions;
 static void Check(bool value,string message){if(!value)throw new Exception(message);assertions++;}
 static async Task Reject(Func<Task> action){bool rejected=false;try{await action();}catch(InvalidOperationException){rejected=true;}Check(rejected,"Preparation accepted without reviewed software approval.");}
 static int Main(){try{Run().GetAwaiter().GetResult();Console.WriteLine("PASS: "+assertions+" software consent and recovery navigation assertions.");return 0;}catch(Exception e){Console.Error.WriteLine(e.Message);return 1;}}
 static async Task Run(){
  var service=new Service();var controller=new SetupController(service,new Store());
  controller.ChooseComputer(ComputerRole.EditingComputer);controller.Continue();await controller.ChooseFolderAsync(@"C:\Test Files",CancellationToken.None);controller.Continue();
  await controller.ReviewSoftwareAsync(CancellationToken.None);
  Check(controller.PreparationPlan.PlanId==new string('a',64)&&service.Installs==0,"Review installed software or lost the reviewed plan.");
  await Reject(()=>controller.PrepareAsync(CancellationToken.None));
  controller.SetSoftwareAccepted(true);
  Check(controller.SoftwareAccepted,"Explicit software acceptance was not recorded.");
  service.Stale=true;await controller.PrepareAsync(CancellationToken.None);
  Check(!controller.State.Prepared&&!controller.SoftwareAccepted,"A stale plan retained approval or prepared state.");
  service.Stale=false;await controller.ReviewSoftwareAsync(CancellationToken.None);controller.SetSoftwareAccepted(true);await controller.PrepareAsync(CancellationToken.None);
  Check(controller.State.Prepared&&service.Accepted==new string('a',64),"Preparation did not pass the explicitly reviewed identity.");
  int installs=service.Installs;await controller.InspectAsync(CancellationToken.None);
  Check(service.Installs==installs,"Read-only inspection installed software.");
  controller.Continue();service.Manual=SetupResult.Done("Imported.");service.Manual.PairingCode="1234 5678";service.Manual.PairingStage="ReplyImported";
  await controller.ImportConnectionAsync("reply.netcrate",CancellationToken.None);Check(controller.PairingCode=="1234 5678","Imported comparison evidence was lost.");
  service.Manual=SetupResult.ActionRequired("wrong-recipient","Wrong file.");await controller.ImportConnectionAsync("wrong.netcrate",CancellationToken.None);
  Check(String.IsNullOrEmpty(controller.PairingCode)&&String.IsNullOrEmpty(controller.PairingStage),"Failed import retained stale comparison evidence.");
  controller.Back();controller.Back();await controller.ChooseFolderAsync(@"C:\Other Files",CancellationToken.None);
  Check(!controller.SoftwareAccepted&&controller.PreparationPlan==null,"Changing a folder retained old software approval.");
  var worker=new SetupController(service,new Store());worker.ChooseComputer(ComputerRole.BackupServer);worker.Continue();await worker.ChooseFolderAsync(@"C:\Backup Storage",CancellationToken.None);worker.Continue();await worker.ReviewSoftwareAsync(CancellationToken.None);worker.SetSoftwareAccepted(true);await worker.PrepareAsync(CancellationToken.None);
  Check(worker.NeedsRecovery,"Server preparation skipped its recovery page.");
  worker.RecordRecoveryDelivery(@"C:\Recovery\keys.netcrate");worker.ContinueWithLocalRecovery();
  Check(worker.CanContinue&&worker.State.RecoveryLocalOnly&&!worker.State.RecoveryConfirmed,"Local recovery copy falsely claimed independent protection.");
 }
 class Store:ISetupStore{public SetupState Load(){return null;}public void Save(SetupState state){}}
 class Service:ISetupService,ISoftwarePreparationService {
  public int Installs;public string Accepted;public bool Stale;
  public SetupResult Manual=SetupResult.Done("Imported.");
  public Task<SetupResult> ReviewSoftwareAsync(SetupState state,CancellationToken token){var result=SetupResult.Done("Reviewed.");result.PreparationPlan=new SoftwarePreparationPlan{Version=1,PlanId=new string('a',64),Packages=new SoftwareCheck[0],Changes=new SoftwareCheck[0]};return Task.FromResult(result);}
  public Task<SetupResult> PrepareApprovedAsync(SetupState state,string plan,IProgress<SoftwareProgress> progress,CancellationToken token){Installs++;Accepted=plan;return Task.FromResult(Stale?SetupResult.ActionRequired("approval-needed","Review again."):SetupResult.Done("Ready."));}
  public Task<SetupResult> ReviewNetworkAsync(SetupState state,CancellationToken token){return Task.FromResult(SetupResult.Done("Installed."));}
  public Task<SetupResult> NetworkApprovedAsync(SetupState state,string plan,CancellationToken token){return Task.FromResult(SetupResult.Done("Network ready."));}
  public Task<SetupResult> CheckFolderAsync(ComputerRole role,string folder,CancellationToken token){return Task.FromResult(SetupResult.Done("Folder ready."));}
  public Task<SetupResult> InspectAsync(SetupState state,CancellationToken token){return Task.FromResult(SetupResult.Done("Verified."));}
  public Task<SetupResult> PrepareAsync(SetupState state,IProgress<string> progress,CancellationToken token){throw new Exception("Legacy opaque preparation was called.");}
  public Task<SetupResult> SaveRecoveryAsync(SetupState state,string path,CancellationToken token){return Task.FromResult(SetupResult.Done("Saved."));}
  public Task<SetupResult> ExportConnectionAsync(SetupState state,string path,CancellationToken token){return Task.FromResult(SetupResult.Done("Exported."));}
  public Task<SetupResult> ImportConnectionAsync(SetupState state,string path,CancellationToken token){return Task.FromResult(Manual);}
  public Task<SetupResult> ConfirmConnectionAsync(SetupState state,string code,CancellationToken token){return Task.FromResult(SetupResult.Done("Confirmed."));}
  public Task<SetupResult> NetworkAsync(SetupState state,CancellationToken token){return Task.FromResult(SetupResult.Done("Network."));}
  public Task<SetupResult> FinishAsync(SetupState state,CancellationToken token){return Task.FromResult(SetupResult.Done("Finished."));}
  public Task<SetupResult> CheckConnectionAsync(SetupState state,CancellationToken token){return Task.FromResult(SetupResult.Done("Connected."));}
  public Task<SetupResult> CheckSampleAsync(SetupState state,IProgress<string> progress,CancellationToken token){return Task.FromResult(SetupResult.Done("Verified."));}
 }
}
