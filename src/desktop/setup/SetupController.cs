using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace NetCrate.Setup
{
    public sealed class SetupController
    {
        private readonly ISetupService service;
        private readonly ISetupStore store;
        private SetupState lastSaved;

        public SetupState State { get; private set; }
        public SetupResult LastResult { get; private set; }
        public bool Busy { get; private set; }
        public bool IsInstalling { get; private set; }
        public string ProgressMessage { get; private set; }
        public string PairingCode { get; private set; }
        public string PairingStage { get; private set; }
        public event EventHandler Changed;

        public SetupController(ISetupService service, ISetupStore store)
        {
            this.service = service;
            this.store = store;
            State = store.Load() ?? new SetupState();
            // Stored choices help resume setup, but are not proof of current readiness.
            State.InvalidateChecks();
            State.Step = State.Role == ComputerRole.None ? SetupStep.Computer
                : String.IsNullOrEmpty(State.Folder) ? SetupStep.Folders : SetupStep.Prepare;
            lastSaved = State.Copy();
            LastResult = SetupResult.Done("");
        }

        public bool CanContinue
        {
            get
            {
                if (Busy) return false;
                switch (State.Step)
                {
                    case SetupStep.Computer: return State.Role != ComputerRole.None;
                    case SetupStep.Folders: return !String.IsNullOrEmpty(State.Folder);
                    case SetupStep.Prepare: return State.Prepared &&
                        (State.Role != ComputerRole.BackupServer || State.RecoveryConfirmed);
                    case SetupStep.Connect: return State.Connected;
                    case SetupStep.Check: return State.Role == ComputerRole.BackupServer ? State.Connected : State.SampleVerified;
                    default: return false;
                }
            }
        }

        private void RequireIdle()
        {
            if (Busy) throw new InvalidOperationException("Wait for the current check to finish.");
        }

        private void Notify(bool save)
        {
            if (save)
            {
                try
                {
                    store.Save(State);
                    lastSaved = State.Copy();
                }
                catch (Exception error)
                {
                    if (!(error is IOException) && !(error is UnauthorizedAccessException)) throw;
                    State = lastSaved.Copy();
                    State.InvalidateChecks();
                    LastResult = SetupResult.ActionRequired("save-failed", "Your setup choices could not be saved. Check the free space in your Windows user folder, then reopen NetCrate.");
                    Notify(false);
                    throw;
                }
            }
            EventHandler handler = Changed;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        public void ChooseComputer(ComputerRole role)
        {
            RequireIdle();
            if (State.Step != SetupStep.Computer || role == ComputerRole.None || !Enum.IsDefined(typeof(ComputerRole), role))
                throw new InvalidOperationException("Choose which computer you are setting up.");
            if (State.Role != role)
            {
                State.Role = role;
                State.Folder = null;
                State.NetworkAddress = null;
                State.RecoveryExported = false;
                State.RecoveryConfirmed = false;
                State.InvalidateChecks();
            }
            Notify(true);
        }

        public void Continue()
        {
            RequireIdle();
            if (!CanContinue) throw new InvalidOperationException("Finish this step before continuing.");
            State.Step++;
            LastResult = SetupResult.Done("");
            Notify(true);
        }

        public void Back()
        {
            RequireIdle();
            if (State.Step > SetupStep.Computer) State.Step--;
            LastResult = SetupResult.Done("");
            Notify(true);
        }

        public async Task ChooseFolderAsync(string folder, CancellationToken token)
        {
            RequireIdle();
            if (State.Step != SetupStep.Folders) throw new InvalidOperationException("Return to Choose folders first.");
            State.Folder = null;
            State.InvalidateChecks();
            State.RecoveryExported = false;
            State.RecoveryConfirmed = false;
            await RunAsync(() => service.CheckFolderAsync(State.Role, folder, token), token);
            if (LastResult.Succeeded) State.Folder = folder;
            Notify(true);
        }

        public async Task InspectAsync(CancellationToken token)
        {
            RequireIdle();
            State.InvalidateChecks();
            await RunAsync(() => service.InspectAsync(State.Copy(), token), token);
            State.Prepared = LastResult.Succeeded;
            Notify(true);
        }

        public async Task PrepareAsync(CancellationToken token)
        {
            RequireIdle();
            if (State.Step != SetupStep.Prepare) throw new InvalidOperationException("Return to Prepare this computer first.");
            State.InvalidateChecks();
            IsInstalling = true;
            try
            {
                await RunAsync(() => service.PrepareAsync(State.Copy(), Progress(), token), token);
                State.Prepared = LastResult.Succeeded;
                Notify(true);
            }
            finally
            {
                IsInstalling = false;
                Notify(false);
            }
        }

        public async Task SaveRecoveryAsync(string path, CancellationToken token)
        {
            RequireIdle();
            if (!State.Prepared || State.Role != ComputerRole.BackupServer)
                throw new InvalidOperationException("Prepare the Backup Server before saving recovery details.");
            await RunAsync(() => service.SaveRecoveryAsync(State.Copy(), path, token), token);
            if (LastResult.Succeeded) State.RecoveryExported = true;
            Notify(true);
        }

        public void ConfirmRecovery()
        {
            SetRecoveryConfirmed(true);
        }

        public void SetRecoveryConfirmed(bool confirmed)
        {
            RequireIdle();
            if (confirmed && (!State.Prepared || !State.RecoveryExported))
                throw new InvalidOperationException("Save your recovery details before confirming.");
            State.RecoveryConfirmed = confirmed;
            Notify(true);
        }

        public Task ExportConnectionAsync(string path, CancellationToken token)
        {
            RequireIdle();
            RequireConnectionStep();
            return RunAsync(() => service.ExportConnectionAsync(State.Copy(), path, token), token);
        }

        public async Task ImportConnectionAsync(string path, CancellationToken token)
        {
            RequireIdle();
            RequireConnectionStep();
            State.Connected = false;
            // Importing a file is not a successful network check.
            await RunAsync(() => service.ImportConnectionAsync(State.Copy(), path, token), token);
            Notify(true);
        }

        public async Task CheckConnectionAsync(CancellationToken token)
        {
            RequireIdle();
            RequireConnectionStep();
            State.Connected = false;
            await RunAsync(() => service.CheckConnectionAsync(State.Copy(), token), token);
            State.Connected = LastResult.Succeeded;
            Notify(true);
        }

        private void RequireConnectionStep()
        {
            if (State.Step != SetupStep.Connect || !State.Prepared)
                throw new InvalidOperationException("Prepare this computer before connecting.");
        }

        public Task ConfirmConnectionAsync(string code, CancellationToken token)
        {
            RequireIdle(); RequireConnectionStep();
            State.Connected = false;
            return RunInstallationAsync(() => service.ConfirmConnectionAsync(State.Copy(), code, token), token);
        }

        public void UseNetworkAddress(string address)
        {
            RequireIdle(); RequireConnectionStep();
            System.Net.IPAddress ip;
            if (!String.IsNullOrWhiteSpace(address))
            {
                if (!System.Net.IPAddress.TryParse(address, out ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
                    throw new InvalidOperationException("Enter this computer's private IPv4 address.");
                byte[] bytes = ip.GetAddressBytes();
                if (!(bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                    (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127)))
                    throw new InvalidOperationException("Use an address on your private network.");
                address = ip.ToString();
            }
            State.NetworkAddress = address;
            State.Connected = false; State.SampleVerified = false;
            PairingCode = ""; PairingStage = "";
            LastResult = SetupResult.Done(String.IsNullOrWhiteSpace(address) ? "Automatic NetBird address selection is enabled." : "Using this computer's existing private connection: " + address);
            Notify(true);
        }

        public Task NetworkAsync(CancellationToken token)
        {
            RequireIdle(); RequireConnectionStep();
            return RunInstallationAsync(() => service.NetworkAsync(State.Copy(), token), token);
        }

        private async Task RunInstallationAsync(Func<Task<SetupResult>> action, CancellationToken token)
        {
            IsInstalling = true;
            try { await RunAsync(action, token); }
            finally { IsInstalling = false; Notify(false); }
        }

        public Task FinishAsync(CancellationToken token)
        {
            RequireIdle();
            if (State.Step != SetupStep.Complete || !State.Connected || (State.Role == ComputerRole.EditingComputer && !State.SampleVerified))
                throw new InvalidOperationException("Finish the connection and sample checks first.");
            return RunAsync(() => service.FinishAsync(State.Copy(), token), token);
        }

        public async Task CheckSampleAsync(CancellationToken token)
        {
            RequireIdle();
            if (State.Step != SetupStep.Check || !State.Connected)
                throw new InvalidOperationException("Connect both computers before checking the round trip.");
            State.SampleVerified = false;
            await RunAsync(() => service.CheckSampleAsync(State.Copy(), Progress(), token), token);
            State.SampleVerified = State.Role == ComputerRole.EditingComputer && LastResult.Succeeded;
            Notify(true);
        }

        private IProgress<string> Progress()
        {
            return new Progress<string>(message =>
            {
                ProgressMessage = message;
                Notify(false);
            });
        }

        private async Task RunAsync(Func<Task<SetupResult>> operation, CancellationToken token)
        {
            Busy = true;
            ProgressMessage = "Checking this computer...";
            Notify(false);
            try
            {
                token.ThrowIfCancellationRequested();
                LastResult = await operation();
                token.ThrowIfCancellationRequested();
                if (LastResult == null) throw new InvalidOperationException("No check result was returned.");
                if (!String.IsNullOrEmpty(LastResult.PairingCode)) PairingCode = LastResult.PairingCode;
                if (!String.IsNullOrEmpty(LastResult.PairingStage)) PairingStage = LastResult.PairingStage;
            }
            catch (OperationCanceledException)
            {
                LastResult = SetupResult.ActionRequired("cancelled", "Setup paused. Choose Try again to continue.");
            }
            catch (Exception)
            {
                // The service returns safe messages for expected failures. Never show raw process output here.
                LastResult = SetupResult.ActionRequired("operation-failed", "This step could not finish. Check that the drive is connected, then choose Try again.");
            }
            finally
            {
                Busy = false;
                ProgressMessage = "";
                Notify(true);
            }
        }
    }
}
