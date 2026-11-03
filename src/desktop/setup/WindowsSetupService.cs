using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace NetCrate.Setup
{
    public sealed class WindowsSetupService : ISetupService, IRestoreService
    {
        private readonly string engineRoot;
        private readonly string setupRoot;
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 1048576 };

        public WindowsSetupService(string engineRoot) : this(engineRoot,
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NetCrate", "Setup")) { }

        public WindowsSetupService(string engineRoot, string setupRoot)
        {
            this.engineRoot = Path.GetFullPath(engineRoot);
            this.setupRoot = Path.GetFullPath(setupRoot);
        }

        public Task<SetupResult> CheckFolderAsync(ComputerRole role, string folder, CancellationToken token)
        {
            return Task.Run(() => CheckFolder(role, folder, token), token);
        }

        private SetupResult CheckFolder(ComputerRole role, string folder, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (role == ComputerRole.None || String.IsNullOrWhiteSpace(folder) || !Path.IsPathRooted(folder) || folder.StartsWith("\\\\"))
                return SetupResult.ActionRequired("choose-local-folder", "Choose a folder on a drive connected to this computer.");
            try
            {
                string full = Path.GetFullPath(folder).TrimEnd('\\');
                if (String.Equals(full, Path.GetPathRoot(full).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    return SetupResult.ActionRequired("choose-folder", "Choose a folder inside the drive.");
                if (!Directory.Exists(full))
                    return SetupResult.ActionRequired("folder-unavailable", "Reconnect the drive and choose the folder again.");
                string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows).TrimEnd('\\');
                if (full.Equals(windows, StringComparison.OrdinalIgnoreCase) || full.StartsWith(windows + "\\", StringComparison.OrdinalIgnoreCase) ||
                    full.IndexOfAny(new[] { '*', '?', '"', '<', '>', '|' }) >= 0)
                    return SetupResult.ActionRequired("choose-folder", "Choose your project or backup folder instead of a Windows folder.");
                if (!JsonSetupStore.SafePath(full))
                    return SetupResult.ActionRequired("linked-folder", "Choose a local folder outside a linked or cloud-managed folder.");
                string probe = Path.Combine(full, ".netcrate-check-" + Guid.NewGuid().ToString("N"));
                using (FileStream stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose))
                    stream.WriteByte(0);
                DriveInfo drive = new DriveInfo(Path.GetPathRoot(full));
                long required = role == ComputerRole.BackupServer ? 5L * 1024 * 1024 * 1024 : 1024L * 1024 * 1024;
                if (drive.AvailableFreeSpace < required)
                    return SetupResult.ActionRequired("space-needed", "Free some space on this drive, then choose the folder again.");
                return SetupResult.Done("The folder is available and writable.");
            }
            catch (UnauthorizedAccessException)
            { return SetupResult.ActionRequired("folder-permission", "NetCrate cannot write to this folder. Choose another folder or check its Windows permissions."); }
            catch (IOException)
            { return SetupResult.ActionRequired("folder-unavailable", "Reconnect the drive and choose the folder again."); }
            catch (ArgumentException)
            { return SetupResult.ActionRequired("choose-folder", "Choose an ordinary local folder."); }
        }

        public Task<SetupResult> InspectAsync(SetupState state, CancellationToken token)
        { return InvokePreparationAsync("Inspect", state, token); }

        public async Task<SetupResult> PrepareAsync(SetupState state, IProgress<string> progress, CancellationToken token)
        {
            SetupResult folder = await CheckFolderAsync(state.Role, state.Folder, token);
            if (!folder.Succeeded) return folder;
            if (progress != null) progress.Report("Checking required software. Windows may ask you to approve an installation.");
            return await InvokePreparationAsync("Prepare", state, token);
        }

        public async Task<SetupResult> InvokePreparationAsync(string action, SetupState state, CancellationToken token, string path = null, string code = null, RestoreRequest restore = null, ScheduleRequest schedule = null, MaintenanceRequest maintenance = null)
        {
            string[] actions = { "Inspect", "Prepare", "Network", "SaveRecovery", "ExportConnection", "ImportConnection", "ConfirmConnection", "CheckConnection", "CheckSample", "Finish", "QueueBackup", "ListBackups", "ListBackupChildren", "RestoreSelection", "ListSchedules", "SaveSchedule", "DisableSchedule", "StorageStatus", "CheckStorage", "PreviewRetention", "ApplyRetention" };
            if (Array.IndexOf(actions, action) < 0) throw new ArgumentException("Unsupported action.");
            token.ThrowIfCancellationRequested();
            string script = Path.Combine(engineRoot, "Invoke-SetupAction.ps1");
            if (!File.Exists(script))
                return SetupResult.ActionRequired("installer-missing", "The setup files are missing. Download a complete NetCrate build and try again.");
            if (!JsonSetupStore.SafePath(setupRoot))
                return SetupResult.ActionRequired("setup-folder-linked", "The NetCrate setup folder contains a link. Check the folder before trying again.");
            Directory.CreateDirectory(setupRoot);
            string input = Path.Combine(setupRoot, "action-" + Guid.NewGuid().ToString("N") + ".json");
            object payload = restore == null ? (object)new { Version = 1, InstallationId = state.InstallationId, Role = state.Role.ToString(), BackupMode = state.BackupMode, Folder = state.Folder, NetworkAddress = state.NetworkAddress, Path = path, PairingCode = code }
                : new { Version = 1, InstallationId = restore.InstallationId, Role = "EditingComputer", RecoveryFile = restore.RecoveryFile, RepositoryPath = restore.RepositoryPath, SnapshotId = restore.SnapshotId, RelativePath = restore.RelativePath, DestinationParent = restore.DestinationParent, Cursor = restore.Cursor, BrowseDeadlineUtc = action == "ListBackups" || action == "ListBackupChildren" ? DateTime.UtcNow.Add(InspectionProcess.BrowseBudget).ToString("o") : null };
            if (schedule != null) payload = new { Version = 1, InstallationId = state.InstallationId, Role = state.Role.ToString(), BackupMode = state.BackupMode, Folder = state.Folder, Path = schedule.Project, TimeOfDay = schedule.TimeOfDay, Enabled = schedule.Enabled };
            if (maintenance != null) {
                if (action == "StorageStatus" || action == "CheckStorage") payload = new { Version=1, InstallationId=state.InstallationId, Role="BackupServer" };
                else if (action == "PreviewRetention" && maintenance.Policy == "KeepAll") payload = new { Version=1, InstallationId=state.InstallationId, Role="BackupServer", Policy=maintenance.Policy };
                else if (action == "PreviewRetention") payload = new { Version=1, InstallationId=state.InstallationId, Role="BackupServer", Policy=maintenance.Policy, Count=maintenance.Count };
                else payload = new { Version=1, InstallationId=state.InstallationId, Role="BackupServer", PreviewId=maintenance.PreviewId, Confirm=maintenance.Confirm };
            }
            File.WriteAllText(input, json.Serialize(payload), new UTF8Encoding(false));
            try
            {
                string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
                ProcessStartInfo start = new ProcessStartInfo(powershell,
                    "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action + " -InputFile " + Quote(input));
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                start.StandardOutputEncoding = Encoding.UTF8;
                // Each PowerShell host resolves its own bundled modules, even when launched from another host.
                start.EnvironmentVariables.Remove("PSModulePath");
                using (Process process = new Process { StartInfo = start })
                {
                    process.Start();
                    Task<string> output = process.StandardOutput.ReadToEndAsync();
                    Task<string> errors = process.StandardError.ReadToEndAsync();
                    // Finish the package manager operation before allowing another attempt.
                    // Cancelling an installer process can leave its child installer running.
                    // Recovery also waits through native verification/publication and owned staging cleanup.
                    if (action != "Prepare" && action != "Network" && action != "ConfirmConnection" && action != "RestoreSelection")
                    {
                        bool finished = await InspectionProcess.WaitAsync(process, InspectionProcess.TimeoutFor(action), token);
                        if (!finished) {
                            if (action == "ListBackups" || action == "ListBackupChildren")
                                return SetupResult.ActionRequired("backup-browse-timeout", "Reading the backup took too long. Reconnect the drive or private connection, then choose Refresh. You can cancel browsing and try again later.");
                            return SetupResult.ActionRequired("probe-timeout", "A software check took too long. Close other installers, then choose Try again.");
                        }
                    }
                    else await Task.Run(() => process.WaitForExit());
                    string text = await output;
                    await errors;
                    if (action != "RestoreSelection") token.ThrowIfCancellationRequested();
                    Dictionary<string, object> record = json.DeserializeObject(text.Trim()) as Dictionary<string, object>;
                    if (record == null || !record.ContainsKey("Succeeded") || !record.ContainsKey("Message"))
                        throw new InvalidDataException("Invalid setup result.");
                    bool succeeded = process.ExitCode == 0 && record["Succeeded"] is bool && (bool)record["Succeeded"];
                    SetupResult result = succeeded ? SetupResult.Done(Convert.ToString(record["Message"]))
                        : SetupResult.ActionRequired(Convert.ToString(record["Code"]), Convert.ToString(record["Message"]));
                    object value;
                    if (record.TryGetValue("OperationId", out value)) result.OperationId = Convert.ToString(value);
                    if (record.TryGetValue("PairingCode", out value)) result.PairingCode = Convert.ToString(value);
                    if (record.TryGetValue("PairingStage", out value)) result.PairingStage = Convert.ToString(value);
                    if (record.TryGetValue("NextCursor", out value)) result.NextCursor = Convert.ToString(value);
                    if (record.TryGetValue("RestoredPath", out value)) result.RestoredPath = Convert.ToString(value);
                    if (record.TryGetValue("Schedules", out value) && value is object[]) {
                        object[] schedules = (object[])value;
                        if (schedules.Length > 256) throw new InvalidDataException("There are too many schedules.");
                        foreach (object item in schedules) result.Schedules.Add(json.ConvertToType<ScheduleItem>(item));
                    }
                    if (record.TryGetValue("Items", out value) && value is object[]) {
                        object[] items = (object[])value;
                        if (items.Length > 200) throw new InvalidDataException("The backup page is too large.");
                        foreach (object item in items) result.Items.Add(json.ConvertToType<BackupItem>(item));
                    }
                    if (record.TryGetValue("Maintenance", out value) && value != null) {
                        result.Maintenance = json.ConvertToType<MaintenanceStatus>(value);
                        if (result.Maintenance.Operations != null && result.Maintenance.Operations.Count > 256) throw new InvalidDataException("Too many storage operations.");
                        if (result.Maintenance.Preview != null && result.Maintenance.Preview.Items != null && result.Maintenance.Preview.Items.Count > 256) throw new InvalidDataException("The retention preview is too large.");
                    }
                    object software;
                    if (record.TryGetValue("Software", out software) && software is object[])
                        foreach (object item in (object[])software)
                        {
                            Dictionary<string, object> data = item as Dictionary<string, object>;
                            if (data == null) continue;
                            result.Software.Add(new SoftwareCheck { Name = Convert.ToString(data["Name"]), Purpose = Convert.ToString(data["Purpose"]),
                                Version = Convert.ToString(data["Version"]), Available = data["Available"] is bool && (bool)data["Available"] });
                        }
                    return result;
                }
            }
            finally { if (File.Exists(input)) File.Delete(input); }
        }

        public Task<SetupResult> InvokeRestoreAsync(string action, RestoreRequest request, CancellationToken token) {
            if (action != "ListBackups" && action != "ListBackupChildren" && action != "RestoreSelection") throw new ArgumentException("Unsupported recovery action.");
            return InvokePreparationAsync(action, new SetupState(), token, null, null, request);
        }
        public Task<SetupResult> InvokeScheduleAsync(string action, SetupState state, ScheduleRequest request, CancellationToken token) {
            if (action != "ListSchedules" && action != "SaveSchedule" && action != "DisableSchedule") throw new ArgumentException("Unsupported schedule action.");
            return InvokePreparationAsync(action, state, token, null, null, null, request);
        }
        public Task<SetupResult> InvokeMaintenanceAsync(string action, SetupState state, MaintenanceRequest request, CancellationToken token) {
            if (action != "StorageStatus" && action != "CheckStorage" && action != "PreviewRetention" && action != "ApplyRetention") throw new ArgumentException("Unsupported storage action.");
            return InvokePreparationAsync(action, state, token, null, null, null, null, request);
        }
        private static string Quote(string path)
        {
            if (path.IndexOf('"') >= 0 || path.IndexOf('\n') >= 0 || path.IndexOf('\r') >= 0)
                throw new ArgumentException("Invalid setup path.");
            return "\"" + path + "\"";
        }

        public Task<SetupResult> SaveRecoveryAsync(SetupState state, string path, CancellationToken token)
        { return InvokePreparationAsync("SaveRecovery", state, token, path); }

        public Task<SetupResult> ExportConnectionAsync(SetupState state, string path, CancellationToken token)
        { return InvokePreparationAsync("ExportConnection", state, token, path); }

        public Task<SetupResult> ImportConnectionAsync(SetupState state, string path, CancellationToken token)
        { return InvokePreparationAsync("ImportConnection", state, token, path); }

        public Task<SetupResult> ConfirmConnectionAsync(SetupState state, string code, CancellationToken token)
        { return InvokePreparationAsync("ConfirmConnection", state, token, null, code); }

        public Task<SetupResult> NetworkAsync(SetupState state, CancellationToken token)
        { return InvokePreparationAsync("Network", state, token); }

        public Task<SetupResult> FinishAsync(SetupState state, CancellationToken token)
        { return InvokePreparationAsync("Finish", state, token); }

        public Task<SetupResult> CheckConnectionAsync(SetupState state, CancellationToken token)
        { return InvokePreparationAsync("CheckConnection", state, token); }

        public Task<SetupResult> CheckSampleAsync(SetupState state, IProgress<string> progress, CancellationToken token)
        { return InvokePreparationAsync("CheckSample", state, token); }

        private static Task<SetupResult> Unavailable(string code, string message)
        { return Task.FromResult(SetupResult.ActionRequired(code, message)); }
    }
}
