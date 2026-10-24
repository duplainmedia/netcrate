using System;
using System.Threading;
using System.Threading.Tasks;

namespace NetCrate.Setup
{
    public interface ISetupService
    {
        Task<SetupResult> CheckFolderAsync(ComputerRole role, string folder, CancellationToken token);
        Task<SetupResult> InspectAsync(SetupState state, CancellationToken token);
        Task<SetupResult> PrepareAsync(SetupState state, IProgress<string> progress, CancellationToken token);
        Task<SetupResult> SaveRecoveryAsync(SetupState state, string path, CancellationToken token);
        Task<SetupResult> ExportConnectionAsync(SetupState state, string path, CancellationToken token);
        Task<SetupResult> ImportConnectionAsync(SetupState state, string path, CancellationToken token);
        Task<SetupResult> CheckConnectionAsync(SetupState state, CancellationToken token);
        Task<SetupResult> CheckSampleAsync(SetupState state, IProgress<string> progress, CancellationToken token);
    }
}
