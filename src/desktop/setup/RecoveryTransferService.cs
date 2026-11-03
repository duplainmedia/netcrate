using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace NetCrate.Setup
{
    public interface IRecoveryTransferService
    {
        Task<RecoveryDocument> ExportContentsAsync(string stateRoot, CancellationToken token);
        Task<RecoverySaveResult> SaveAsync(string stateRoot, string destination, CancellationToken token);
        RecoveryPasteContext CreatePasteContext(string contents, string repositoryPath);
        string SuggestSavePath(string stateRoot, string storageRoot);
    }

    // Keep this object inside the explicit copy/paste action. Never serialize it or attach it to SetupState.
    public sealed class RecoveryDocument : IDisposable
    {
        string contents;
        internal RecoveryDocument(string contents) { Validate(contents); this.contents = contents; }
        public string Contents { get { if (contents == null) throw new ObjectDisposedException("RecoveryDocument"); return contents; } }
        public void Dispose() { contents = null; }
        public override string ToString() { return "Sensitive recovery document"; }
        internal static void Validate(string value)
        {
            try
            {
                if (String.IsNullOrEmpty(value) || Encoding.UTF8.GetByteCount(value) > 32768) throw new ArgumentException();
                var record = new JavaScriptSerializer { MaxJsonLength = 32768, RecursionLimit = 16 }.DeserializeObject(value) as Dictionary<string, object>;
                if (record == null || !record.ContainsKey("Version") || !(record["Version"] is int) || (int)record["Version"] != 1 ||
                    !record.ContainsKey("Kind") || !(record["Kind"] is string) || (string)record["Kind"] != "netcrate-recovery") throw new ArgumentException();
                foreach (string name in new[] { "Primary", "Results" })
                {
                    var repository = record.ContainsKey(name) ? record[name] as Dictionary<string, object> : null;
                    if (repository == null || !repository.ContainsKey("Id") || !(repository["Id"] is string) ||
                        !Regex.IsMatch((string)repository["Id"], "\\A[a-f0-9]{64}\\z") || !repository.ContainsKey("Password") ||
                        !(repository["Password"] is string) || ((string)repository["Password"]).Length < 1 || ((string)repository["Password"]).Length > 1024)
                        throw new ArgumentException();
                }
            }
            catch (Exception ex)
            {
                if (!(ex is ArgumentException) && !(ex is InvalidOperationException) && !(ex is FormatException) && !(ex is OverflowException) && !(ex is InvalidCastException)) throw;
                // Parser messages can contain user input. Do not retain an inner exception.
                throw new ArgumentException("Paste a complete valid NetCrate recovery document.");
            }
        }
    }

    public sealed class RecoverySaveResult
    {
        public bool Succeeded { get; internal set; }
        public string SavedPath { get; internal set; }
        public string Message { get; internal set; }
    }

    public sealed class RecoveryTransferService : IRecoveryTransferService
    {
        readonly string engineRoot, powerShellExe, resticExe, recoveryRoot;
        const string Failure = "Recovery details could not be transferred. Check the recovery details, folder and matching repository, then try again.";
        public RecoveryTransferService(string engineRoot, string powerShellExe, string resticExe)
            : this(engineRoot, powerShellExe, resticExe, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NetCrate", "IndependentRecovery")) { }
        public RecoveryTransferService(string engineRoot, string powerShellExe, string resticExe, string recoveryRoot)
        {
            this.engineRoot = Path.GetFullPath(engineRoot); this.powerShellExe = Path.GetFullPath(powerShellExe);
            this.resticExe = Path.GetFullPath(resticExe); this.recoveryRoot = Path.GetFullPath(recoveryRoot);
        }
        public async Task<RecoveryDocument> ExportContentsAsync(string stateRoot, CancellationToken token)
        {
            string output = await InvokeAsync("Export", stateRoot, null, null, null, token);
            try { return new RecoveryDocument(output); }
            catch (ArgumentException) { throw new IOException(Failure); }
        }
        public async Task<RecoverySaveResult> SaveAsync(string stateRoot, string destination, CancellationToken token)
        {
            destination = Path.GetFullPath(destination);
            if (File.Exists(destination) || Directory.Exists(destination))
                return new RecoverySaveResult { Message = "That destination already exists. Choose a new recovery filename; the existing file was preserved." };
            try
            {
                string output = await InvokeAsync("Save", stateRoot, destination, null, null, token);
                var record = Json().DeserializeObject(output) as Dictionary<string, object>;
                if (record == null || !record.ContainsKey("Succeeded") || !Object.Equals(record["Succeeded"], true)) throw new IOException();
                return new RecoverySaveResult { Succeeded = true, SavedPath = destination, Message = "Recovery file saved locally." };
            }
            catch (IOException) { return new RecoverySaveResult { Message = Failure }; }
        }
        public RecoveryPasteContext CreatePasteContext(string contents, string repositoryPath)
        {
            RecoveryDocument.Validate(contents);
            if (String.IsNullOrWhiteSpace(repositoryPath) || !Path.IsPathRooted(repositoryPath) || !File.Exists(Path.Combine(repositoryPath, "config")))
                throw new ArgumentException("Choose the existing originals repository folder containing config.");
            return new RecoveryPasteContext(this, contents, Path.GetFullPath(repositoryPath));
        }
        public string SuggestSavePath(string stateRoot, string storageRoot)
        {
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            foreach (string candidate in new[] { profile, Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) })
            {
                if (String.IsNullOrWhiteSpace(candidate) || !Directory.Exists(candidate))
                    continue;
                bool unsafePath = false;
                foreach (string cloud in new[] { Environment.GetEnvironmentVariable("OneDrive"), Environment.GetEnvironmentVariable("OneDriveConsumer"), Environment.GetEnvironmentVariable("OneDriveCommercial") })
                    if (!String.IsNullOrEmpty(cloud) && IsInside(candidate, cloud)) unsafePath = true;
                for (DirectoryInfo part = new DirectoryInfo(candidate); part != null; part = part.Parent)
                    if (((int)part.Attributes & (0x400 | 0x1000 | 0x40000 | 0x400000)) != 0) unsafePath = true;
                if (unsafePath) continue;
                string name = "NetCrate recovery " + DateTime.Now.ToString("yyyy-MM-dd") + ".netcrate";
                string path = Path.Combine(candidate, name);
                if (File.Exists(path) || Directory.Exists(path)) path = Path.Combine(candidate, "NetCrate recovery " + Guid.NewGuid().ToString("N").Substring(0, 8) + ".netcrate");
                if (Overlaps(path, stateRoot) || Overlaps(path, storageRoot) || Overlaps(path, engineRoot)) continue;
                return path;
            }
            throw new IOException("Choose an ordinary writable local folder outside NetCrate and backup storage.");
        }
        static bool IsInside(string path, string parent)
        {
            string p = Path.GetFullPath(path).TrimEnd('\\'), q = Path.GetFullPath(parent).TrimEnd('\\');
            return p.Equals(q, StringComparison.OrdinalIgnoreCase) || p.StartsWith(q + "\\", StringComparison.OrdinalIgnoreCase);
        }
        static bool Overlaps(string a, string b) { return !String.IsNullOrEmpty(b) && (IsInside(a, b) || IsInside(b, a)); }
        static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 }; }
        internal async Task<SetupResult> RestoreAsync(string contents, string repositoryPath, string action, RestoreRequest request, CancellationToken token)
        {
            if (action != "ListBackups" && action != "ListBackupChildren" && action != "RestoreSelection") throw new ArgumentException("Unsupported recovery action.");
            // The request contains selections only. Recovery contents travel in their own stdin frame.
            string selection = Json().Serialize(new { RepositoryPath = repositoryPath, SnapshotId = request.SnapshotId, RelativePath = request.RelativePath,
                DestinationParent = request.DestinationParent, Cursor = request.Cursor, BrowseDeadlineUtc = action == "RestoreSelection" ? null : DateTime.UtcNow.AddMinutes(30).ToString("o") });
            try
            {
                string output = await InvokeAsync(action, recoveryRoot, null, contents, selection, token);
                var record = Json().DeserializeObject(output) as Dictionary<string, object>;
                if (record == null || !record.ContainsKey("Succeeded") || !Object.Equals(record["Succeeded"], true)) throw new IOException();
                var result = SetupResult.Done(action == "RestoreSelection" ? "The selected files were verified and recovered." : "Choose a dated backup or a file or folder.");
                object value;
                if (record.TryGetValue("NextCursor", out value)) result.NextCursor = Convert.ToString(value);
                if (record.TryGetValue("RestoredPath", out value)) result.RestoredPath = Convert.ToString(value);
                if (record.TryGetValue("Items", out value) && value is object[]) foreach (object item in (object[])value) result.Items.Add(Json().ConvertToType<BackupItem>(item));
                return result;
            }
            catch (IOException) { return SetupResult.ActionRequired("recovery-transfer-failed", Failure); }
        }
        async Task<string> InvokeAsync(string action, string stateRoot, string destination, string contents, string selection, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            string script = Path.Combine(engineRoot, "Invoke-RecoveryTransfer.ps1");
            if (!File.Exists(script) || !File.Exists(powerShellExe)) throw new IOException(Failure);
            string arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action + " -StateRoot " + Quote(Path.GetFullPath(stateRoot));
            if (destination != null) arguments += " -Destination " + Quote(destination);
            if (contents != null) arguments += " -ResticExe " + Quote(resticExe);
            var start = new ProcessStartInfo(powerShellExe, arguments) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, StandardOutputEncoding = new UTF8Encoding(false, true) };
            start.EnvironmentVariables.Remove("PSModulePath");
            try
            {
                using (var process = new Process { StartInfo = start })
                {
                    process.Start();
                    Task<string> output = ReadBoundedAsync(process.StandardOutput, action == "Export" ? 32768 : 1048576);
                    Task errors = DiscardAsync(process.StandardError);
                    try
                    {
                        if (contents != null) { await WriteFrameAsync(process.StandardInput.BaseStream, contents); await WriteFrameAsync(process.StandardInput.BaseStream, selection); }
                        process.StandardInput.Close();
                        CancellationToken waitToken = action == "RestoreSelection" ? CancellationToken.None : token;
                        TimeSpan timeout = action == "RestoreSelection" ? TimeSpan.FromHours(24) : action.StartsWith("List", StringComparison.Ordinal) ? TimeSpan.FromMinutes(31) : TimeSpan.FromSeconds(90);
                        bool done = await InspectionProcess.WaitAsync(process, timeout, waitToken);
                        string text = await output; await errors;
                        if (!done || process.ExitCode != 0) throw new IOException(Failure);
                        return text;
                    }
                    finally { if (!process.HasExited) { process.Kill(); process.WaitForExit(2000); } }
                }
            }
            catch (System.ComponentModel.Win32Exception) { throw new IOException(Failure); }
            catch (InvalidOperationException) { throw new IOException(Failure); }
            catch (ArgumentException) { throw new IOException(Failure); }
        }
        static string Quote(string value)
        {
            if (value.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) >= 0) throw new ArgumentException("Choose an ordinary local path.");
            return "\"" + value.TrimEnd('\\') + "\"";
        }
        static async Task WriteFrameAsync(Stream stream, string value)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            try { byte[] length = BitConverter.GetBytes(bytes.Length); await stream.WriteAsync(length, 0, length.Length); await stream.WriteAsync(bytes, 0, bytes.Length); await stream.FlushAsync(); }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }
        static async Task<string> ReadBoundedAsync(StreamReader reader, int limit)
        {
            var result = new StringBuilder(); char[] buffer = new char[4096]; bool tooLarge = false; int read;
            while ((read = await reader.ReadAsync(buffer, 0, buffer.Length)) != 0)
            {
                if (result.Length + read > limit) tooLarge = true;
                if (!tooLarge) result.Append(buffer, 0, read);
                Array.Clear(buffer, 0, buffer.Length);
            }
            if (tooLarge) throw new IOException(Failure);
            return result.ToString();
        }
        static async Task DiscardAsync(StreamReader reader)
        {
            char[] buffer = new char[4096];
            while (await reader.ReadAsync(buffer, 0, buffer.Length) != 0) Array.Clear(buffer, 0, buffer.Length);
        }
    }

    public sealed class RecoveryPasteContext : IRestoreService, IDisposable
    {
        readonly RecoveryTransferService service;
        readonly string repositoryPath;
        string contents;
        internal RecoveryPasteContext(RecoveryTransferService service, string contents, string repositoryPath) { this.service = service; this.contents = contents; this.repositoryPath = repositoryPath; }
        public Task<SetupResult> InvokeRestoreAsync(string action, RestoreRequest request, CancellationToken token)
        {
            if (contents == null) throw new ObjectDisposedException("RecoveryPasteContext");
            return service.RestoreAsync(contents, repositoryPath, action, request, token);
        }
        public void Dispose() { contents = null; }
        public override string ToString() { return "Independent recovery context"; }
    }
}
