using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using NetCrate.Setup;

class SetupTests
{
    private static int assertions;

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        assertions++;
    }

    private static void Reject(Action action, string message)
    {
        bool rejected = false;
        try { action(); }
        catch (InvalidOperationException) { rejected = true; }
        Assert(rejected, message);
    }

    public static void Main()
    {
        Run().GetAwaiter().GetResult();
        Console.WriteLine("PASS: " + assertions + " guided setup assertions.");
    }

    private static async Task Run()
    {
        FakeSetupService service = new FakeSetupService();
        MemorySetupStore store = new MemorySetupStore();
        SetupController setup = new SetupController(service, store);
        Assert(setup.State.Step == SetupStep.Computer, "A new setup skipped the computer choice.");
        Assert(setup.State.BackupMode=="Folder","New setup did not default to ordinary backups.");
        setup.ChooseBackupMode("Media");
        Assert(setup.State.BackupMode=="Media"&&store.Load().BackupMode=="Media","The media choice was not persisted.");
        setup.ChooseBackupMode("Folder");
        Reject(() => setup.Continue(), "No computer role was accepted.");
        setup.ChooseComputer(ComputerRole.EditingComputer);
        setup.Continue();
        Assert(setup.State.Step == SetupStep.Folders, "The folder choice was skipped.");
        Reject(() => setup.Continue(), "A missing folder was accepted.");
        service.FolderResult = SetupResult.ActionRequired("folder-unavailable", "Reconnect the drive and choose the folder again.");
        await setup.ChooseFolderAsync(@"F:\Video Projects", CancellationToken.None);
        Assert(setup.State.Folder == null, "An inaccessible folder was saved.");
        service.FolderResult = SetupResult.Done("The folder is available.");
        await setup.ChooseFolderAsync(@"F:\Video Projects", CancellationToken.None);
        setup.Continue();
        Assert(setup.State.Step == SetupStep.Prepare, "A valid folder did not advance.");
        service.PrepareResult = SetupResult.ActionRequired("approval-denied", "Windows approval was declined. Choose Try again when you are ready.");
        await PrepareReviewed(setup, CancellationToken.None);
        Assert(!setup.State.Prepared && !setup.CanContinue, "Declined approval was treated as preparation success.");
        service.PrepareResult = SetupResult.Done("Required software is available.");
        await PrepareReviewed(setup, CancellationToken.None);
        Assert(setup.State.Prepared && setup.CanContinue, "Successful preparation did not unlock connection.");
        Reject(()=>setup.ChooseBackupMode("Media"),"Mode changed after preparation without returning to folder choices.");
        setup.Continue();
        service.ConnectionResult = SetupResult.ActionRequired("sign-in-needed", "Finish signing in to your private network.");
        setup.UseNetworkAddress("10.44.0.2");
        Assert(setup.State.NetworkAddress == "10.44.0.2", "An existing private connection choice was not saved.");
        Reject(() => setup.UseNetworkAddress("8.8.8.8"), "A public address was accepted as an existing private connection.");
        await setup.ConfirmConnectionAsync("1234 5678 9012 3456", CancellationToken.None);
        Assert(!setup.State.Connected, "Comparing codes was treated as a live connection check.");
        await setup.CheckConnectionAsync(CancellationToken.None);
        Assert(!setup.State.Connected && !setup.CanContinue, "Unfinished sign-in advanced setup.");
        service.ConnectionResult = SetupResult.ActionRequired("wrong-recipient", "Choose the connection file made for this computer.");
        await setup.ImportConnectionAsync("wrong.netcrate", CancellationToken.None);
        Assert(!setup.State.Connected, "A connection for a different recipient was accepted.");
        service.ConnectionResult = SetupResult.Done("The other computer answered.");
        await setup.CheckConnectionAsync(CancellationToken.None);
        setup.Continue();
        service.SampleResult = SetupResult.ActionRequired("peer-unavailable", "Turn on your Backup Server and try again.");
        await setup.CheckSampleAsync(CancellationToken.None);
        Assert(!setup.State.SampleVerified && !setup.CanContinue, "An unavailable peer passed the sample check.");
        service.SampleResult = SetupResult.Done("Sample media returned and passed verification.");
        await setup.CheckSampleAsync(CancellationToken.None);
        Assert(setup.CanContinue, "A verified sample did not unlock completion.");
        setup.Continue();
        Assert(setup.State.Step == SetupStep.Complete, "Verified setup could not finish.");

        SetupController resumed = new SetupController(service, store);
        Assert(!resumed.State.Connected && !resumed.State.SampleVerified && resumed.State.Step == SetupStep.Prepare,
            "Restart trusted stale software or peer readiness without rechecking.");
        resumed.Back();
        await resumed.ChooseFolderAsync(@"G:\New Projects", CancellationToken.None);
        Assert(!resumed.State.Prepared && !resumed.State.Connected, "Changing the folder retained old setup proof.");
        resumed.Back();
        resumed.ChooseComputer(ComputerRole.BackupServer);
        resumed.Continue();
        Assert(resumed.State.Folder == null, "Changing roles reused the editing folder as backup storage.");
        await resumed.ChooseFolderAsync(@"G:\Backup Storage", CancellationToken.None);
        resumed.Continue();
        await PrepareReviewed(resumed, CancellationToken.None);
        Assert(!resumed.CanContinue, "A backup server skipped independent recovery details.");
        service.RecoveryResult = SetupResult.ActionRequired("save-cancelled", "Choose where to save recovery details.");
        await resumed.SaveRecoveryAsync("cancelled", CancellationToken.None);
        Reject(() => resumed.ConfirmRecovery(), "An unsaved recovery copy was confirmed.");
        service.RecoveryResult = SetupResult.Done("Recovery details saved.");
        await resumed.SaveRecoveryAsync("recovery.netcrate", CancellationToken.None);
        resumed.ConfirmRecovery();
        Assert(resumed.CanContinue, "Saved and confirmed recovery details did not unlock connection.");
        resumed.SetRecoveryConfirmed(false);
        Assert(!resumed.CanContinue, "Unchecking recovery confirmation did not close the gate.");
        resumed.SetRecoveryConfirmed(true);
        resumed.Continue();
        await resumed.CheckConnectionAsync(CancellationToken.None);
        resumed.Continue();
        await resumed.CheckSampleAsync(CancellationToken.None);
        Assert(resumed.CanContinue && !resumed.State.SampleVerified,
            "The connected server could not finish local setup without claiming the editing computer's round trip.");

        FakeSetupService interruptedService = new FakeSetupService();
        SetupController interrupted = new SetupController(interruptedService, new MemorySetupStore());
        interrupted.ChooseComputer(ComputerRole.EditingComputer);
        interrupted.Continue();
        await interrupted.ChooseFolderAsync(@"F:\Video Projects", CancellationToken.None);
        interrupted.Continue();
        interruptedService.ThrowOnPrepare = true;
        await PrepareReviewed(interrupted, CancellationToken.None);
        Assert(!interrupted.Busy && !interrupted.State.Prepared && interrupted.LastResult.Code == "operation-failed",
            "An interrupted installation retained success or left the controls stuck.");
        interruptedService.ThrowOnPrepare = false;
        await PrepareReviewed(interrupted, CancellationToken.None);
        Assert(interrupted.State.Prepared, "Retry after interruption did not recover.");
        interruptedService.WaitOnPrepare = new TaskCompletionSource<SetupResult>();
        Task pending = PrepareReviewed(interrupted, CancellationToken.None);
        Assert(interrupted.Busy, "Preparation did not lock setup choices.");
        Reject(() => interrupted.ChooseComputer(ComputerRole.BackupServer), "The role changed during installation.");
        Reject(() => interrupted.Back(), "Navigation changed during installation.");
        interruptedService.WaitOnPrepare.SetResult(SetupResult.Done("Software checked."));
        await pending;
        CancellationTokenSource cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await PrepareReviewed(interrupted, cancelled.Token);
        Assert(!interrupted.Busy && !interrupted.State.Prepared, "Cancellation left a prepared checkpoint.");

        FailingStore failingStore = new FailingStore();
        SetupController failedSave = new SetupController(service, failingStore);
        bool saveFailed = false;
        try { failedSave.ChooseComputer(ComputerRole.EditingComputer); }
        catch (IOException) { saveFailed = true; }
        Assert(saveFailed && failedSave.State.Role == ComputerRole.None && !failedSave.CanContinue,
            "Failed persistence left an unsaved setup choice available for installation.");

        FakeSetupService recheckService = new FakeSetupService();
        SetupController recheck = new SetupController(recheckService, new MemorySetupStore());
        recheck.ChooseComputer(ComputerRole.EditingComputer);
        recheck.Continue();
        await recheck.ChooseFolderAsync(@"F:\Video Projects", CancellationToken.None);
        recheck.Continue();
        await PrepareReviewed(recheck, CancellationToken.None);
        recheck.Continue();
        recheck.Back();
        recheckService.PrepareResult = SetupResult.ActionRequired("software-missing", "Required software is no longer available.");
        await recheck.InspectAsync(CancellationToken.None);
        Assert(!recheck.State.Prepared && !recheck.State.Connected && !recheck.CanContinue,
            "Returning to preparation and failing its recheck retained the old preparation proof.");
        recheckService.PrepareResult = SetupResult.Done("Software checked.");
        await PrepareReviewed(recheck, CancellationToken.None);
        await recheck.InspectAsync(cancelled.Token);
        Assert(!recheck.State.Prepared && !recheck.CanContinue, "Cancelling a recheck retained preparation proof.");
    }

    private class MemorySetupStore : ISetupStore
    {
        private SetupState saved;
        public SetupState Load() { return saved == null ? null : saved.Copy(); }
        public void Save(SetupState state) { saved = state.Copy(); }
    }

    private class FailingStore : ISetupStore
    {
        public SetupState Load() { return null; }
        public void Save(SetupState state) { throw new IOException("Synthetic full disk."); }
    }

    private static async Task PrepareReviewed(SetupController setup, CancellationToken token) {
        await setup.ReviewSoftwareAsync(token);
        if (setup.PreparationPlan == null) return;
        setup.SetSoftwareAccepted(true);
        await setup.PrepareAsync(token);
    }
    private class FakeSetupService : ISetupService, ISoftwarePreparationService
    {
        public SetupResult FolderResult = SetupResult.Done("Folder checked.");
        public SetupResult PrepareResult = SetupResult.Done("Software checked.");
        public SetupResult ConnectionResult = SetupResult.Done("Peer checked.");
        public SetupResult RecoveryResult = SetupResult.Done("Recovery saved.");
        public SetupResult SampleResult = SetupResult.Done("Sample verified.");
        public bool ThrowOnPrepare;
        public TaskCompletionSource<SetupResult> WaitOnPrepare;
        public Task<SetupResult> ReviewSoftwareAsync(SetupState state,CancellationToken token) {
            var result=SetupResult.Done("Review private tools.");
            result.PreparationPlan=new SoftwarePreparationPlan {Version=1,PlanId=new string('a',64),Packages=new SoftwareCheck[0],Changes=new SoftwareCheck[0]};
            return Task.FromResult(result);
        }
        public Task<SetupResult> PrepareApprovedAsync(SetupState state,string plan,IProgress<SoftwareProgress> progress,CancellationToken token) {return PrepareAsync(state,null,token);}
        public Task<SetupResult> ReviewNetworkAsync(SetupState state,CancellationToken token) {return Task.FromResult(SetupResult.Done("Review."));}
        public Task<SetupResult> NetworkApprovedAsync(SetupState state,string plan,CancellationToken token) {return NetworkAsync(state,token);}

        public Task<SetupResult> CheckFolderAsync(ComputerRole role, string folder, CancellationToken token)
        { return Task.FromResult(FolderResult); }
        public Task<SetupResult> InspectAsync(SetupState state, CancellationToken token)
        { return Task.FromResult(PrepareResult); }
        public Task<SetupResult> PrepareAsync(SetupState state, IProgress<string> progress, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (ThrowOnPrepare) throw new IOException("Synthetic installation interruption.");
            return WaitOnPrepare == null ? Task.FromResult(PrepareResult) : WaitOnPrepare.Task;
        }
        public Task<SetupResult> SaveRecoveryAsync(SetupState state, string path, CancellationToken token)
        { return Task.FromResult(RecoveryResult); }
        public Task<SetupResult> ExportConnectionAsync(SetupState state, string path, CancellationToken token)
        { return Task.FromResult(ConnectionResult); }
        public Task<SetupResult> ImportConnectionAsync(SetupState state, string path, CancellationToken token)
        { return Task.FromResult(ConnectionResult); }
        public Task<SetupResult> CheckConnectionAsync(SetupState state, CancellationToken token)
        { return Task.FromResult(ConnectionResult); }
        public Task<SetupResult> ConfirmConnectionAsync(SetupState state, string code, CancellationToken token)
        { return Task.FromResult(ConnectionResult); }
        public Task<SetupResult> NetworkAsync(SetupState state, CancellationToken token)
        { return Task.FromResult(ConnectionResult); }
        public Task<SetupResult> FinishAsync(SetupState state, CancellationToken token)
        { return Task.FromResult(ConnectionResult); }
        public Task<SetupResult> CheckSampleAsync(SetupState state, IProgress<string> progress, CancellationToken token)
        { return Task.FromResult(SampleResult); }
    }
}
