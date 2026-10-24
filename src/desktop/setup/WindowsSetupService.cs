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
    public sealed class WindowsSetupService : ISetupService
    {
        private readonly string engineRoot;
        private readonly string setupRoot;
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 131072 };

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

        private async Task<SetupResult> InvokePreparationAsync(string action, SetupState state, CancellationToken token)
        {
            string script = Path.Combine(engineRoot, "Invoke-SetupAction.ps1");
            if (!File.Exists(script))
                return SetupResult.ActionRequired("installer-missing", "The setup files are missing. Download a complete NetCrate build and try again.");
            if (!JsonSetupStore.SafePath(setupRoot))
                return SetupResult.ActionRequired("setup-folder-linked", "The NetCrate setup folder contains a link. Check the folder before trying again.");
            Directory.CreateDirectory(setupRoot);
            string input = Path.Combine(setupRoot, "action-" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(input, json.Serialize(new { Version = 1, Role = state.Role.ToString() }));
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
                using (Process process = new Process { StartInfo = start })
                {
                    process.Start();
                    Task<string> output = process.StandardOutput.ReadToEndAsync();
                    Task<string> errors = process.StandardError.ReadToEndAsync();
                    // Finish the package manager operation before allowing another attempt.
                    // Cancelling an installer process can leave its child installer running.
                    await Task.Run(() => process.WaitForExit());
                    string text = await output;
                    await errors;
                    token.ThrowIfCancellationRequested();
                    Dictionary<string, object> record = json.DeserializeObject(text.Trim()) as Dictionary<string, object>;
                    if (record == null || !record.ContainsKey("Succeeded") || !record.ContainsKey("Message"))
                        throw new InvalidDataException("Invalid setup result.");
                    bool succeeded = process.ExitCode == 0 && record["Succeeded"] is bool && (bool)record["Succeeded"];
                    SetupResult result = succeeded ? SetupResult.Done(Convert.ToString(record["Message"]))
                        : SetupResult.ActionRequired(Convert.ToString(record["Code"]), Convert.ToString(record["Message"]));
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

        private static string Quote(string path)
        {
            if (path.IndexOf('"') >= 0 || path.IndexOf('\n') >= 0 || path.IndexOf('\r') >= 0)
                throw new ArgumentException("Invalid setup path.");
            return "\"" + path + "\"";
        }

        public Task<SetupResult> SaveRecoveryAsync(SetupState state, string path, CancellationToken token)
        { return Unavailable("recovery-not-available", "Recovery details will be available after repository and key setup are connected in this development build."); }

        public Task<SetupResult> ExportConnectionAsync(SetupState state, string path, CancellationToken token)
        { return Unavailable("pairing-not-available", "Computer pairing is not available in this development build yet."); }

        public Task<SetupResult> ImportConnectionAsync(SetupState state, string path, CancellationToken token)
        { return Unavailable("pairing-not-available", "Computer pairing is not available in this development build yet."); }

        public Task<SetupResult> CheckConnectionAsync(SetupState state, CancellationToken token)
        { return Unavailable("pairing-not-available", "Computer pairing is not available in this development build yet."); }

        public Task<SetupResult> CheckSampleAsync(SetupState state, IProgress<string> progress, CancellationToken token)
        { return Unavailable("sample-not-available", "The sample check will be available when both computer roles are connected. This build cannot verify the round trip yet."); }

        private static Task<SetupResult> Unavailable(string code, string message)
        { return Task.FromResult(SetupResult.ActionRequired(code, message)); }
    }
}
