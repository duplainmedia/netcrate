using System;
using System.Threading;
using System.Threading.Tasks;

namespace NetCrate.Setup
{
    public interface IManualPairingStatusService {
        Task<SetupResult> ManualPairingStatusAsync(SetupState state, CancellationToken token);
    }
    public interface ISoftwarePreparationService {
        Task<SetupResult> ReviewSoftwareAsync(SetupState state, CancellationToken token);
        Task<SetupResult> PrepareApprovedAsync(SetupState state, string planId, IProgress<SoftwareProgress> progress, CancellationToken token);
        Task<SetupResult> ReviewNetworkAsync(SetupState state, CancellationToken token);
        Task<SetupResult> NetworkApprovedAsync(SetupState state, string planId, CancellationToken token);
    }
    public interface ISetupService
    {
        Task<SetupResult> CheckFolderAsync(ComputerRole role, string folder, CancellationToken token);
        Task<SetupResult> InspectAsync(SetupState state, CancellationToken token);
        Task<SetupResult> PrepareAsync(SetupState state, IProgress<string> progress, CancellationToken token);
        Task<SetupResult> SaveRecoveryAsync(SetupState state, string path, CancellationToken token);
        Task<SetupResult> ExportConnectionAsync(SetupState state, string path, CancellationToken token);
        Task<SetupResult> ImportConnectionAsync(SetupState state, string path, CancellationToken token);
        Task<SetupResult> ConfirmConnectionAsync(SetupState state, string code, CancellationToken token);
        Task<SetupResult> NetworkAsync(SetupState state, CancellationToken token);
        Task<SetupResult> FinishAsync(SetupState state, CancellationToken token);
        Task<SetupResult> CheckConnectionAsync(SetupState state, CancellationToken token);
        Task<SetupResult> CheckSampleAsync(SetupState state, IProgress<string> progress, CancellationToken token);
    }
}
