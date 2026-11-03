using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace NetCrate.Setup
{
    public sealed class WindowsNetworkPairingService : INetworkPairingService
    {
        private readonly string installDirectory, root;
        private readonly object sync = new object();
        private readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 131072, RecursionLimit = 32 };
        private NamedPipeServerStream pipe;
        private Process process;
        private NetworkSetupJob job;
        private NetworkSetupTrust trust;
        private bool firewallScriptChecked;
        private bool disposed;
        private long generation;
        private string identity;

        public WindowsNetworkPairingService(string installDirectory, string setupDirectory)
        {
            this.installDirectory = Path.GetFullPath(installDirectory);
            root = Path.Combine(Directory.GetParent(Path.GetFullPath(setupDirectory)).FullName, "Engine");
        }
        public Task<NetworkSetupStatus> InspectAsync(SetupState state, CancellationToken token)
        { return DispatchAsync("Inspect", state, null, null, token); }
        public Task<NetworkSetupStatus> StartAsync(SetupState state, NetworkSetupRequest request, CancellationToken token)
        {
            if (request == null || (state.Role == ComputerRole.BackupServer && !request.ApproveFirewall))
                return Task.FromResult(Failed("Approve the temporary firewall permission before listening."));
            var scope = new NetworkSetupRequest { LocalAddress = request.LocalAddress, PeerAddress = request.PeerAddress,
                ApproveFirewall = request.ApproveFirewall, StartAgain = request.StartAgain };
            return DispatchAsync("Start", state, scope, null, token);
        }
        public Task<NetworkSetupStatus> PollAsync(SetupState state, CancellationToken token)
        { return DispatchAsync("Poll", state, null, null, token); }
        public Task<NetworkSetupStatus> ConfirmAsync(SetupState state, string code, CancellationToken token)
        { return DispatchAsync("Confirm", state, null, code, token); }
        public Task<NetworkSetupStatus> ResetPendingAsync(SetupState state, CancellationToken token)
        {
            lock (sync)
            {
                token.ThrowIfCancellationRequested();
                ++generation; CloseTransport();
                return DispatchAsync("Reset", state, null, null, token);
            }
        }
        public Task<NetworkSetupStatus> StopAsync(CancellationToken token)
        {
            lock (sync) { ++generation; CloseTransport(); }
            return Task.FromResult(new NetworkSetupStatus { Phase = NetworkSetupPhase.Idle, Message = "The temporary connection is closed." });
        }
        static NetworkSetupStatus Failed(string message)
        { return new NetworkSetupStatus { Phase = NetworkSetupPhase.Failed, Message = message }; }

        private async Task<NetworkSetupStatus> DispatchAsync(string action, SetupState state, NetworkSetupRequest request, string code, CancellationToken token)
        {
            state = state.Copy();
            long operation;
            lock (sync) { operation = generation; }
            await gate.WaitAsync(token).ConfigureAwait(false);
            try
            {
                if (disposed) throw new ObjectDisposedException("Network setup");
                token.ThrowIfCancellationRequested();
                using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    deadline.CancelAfter(TimeSpan.FromSeconds(100));
                    using (deadline.Token.Register(() => CloseGeneration(operation)))
                    {
                        return await Task.Run(() =>
                        {
                            deadline.Token.ThrowIfCancellationRequested();
                            string owner = state.InstallationId + "|" + state.Role + "|" + state.BackupMode + "|" + state.Folder;
                            NamedPipeServerStream current; Process child; bool created; string guardian = null;
                            lock (sync)
                            {
                                deadline.Token.ThrowIfCancellationRequested();
                                if (disposed || operation != generation) throw new OperationCanceledException();
                                if (pipe != null && (identity != owner || process.HasExited)) CloseTransport();
                                created = pipe == null;
                                if (created || action == "Start") guardian = ReadApprovedGuardian();
                                if (created) OpenTransport(owner);
                                if (action == "Confirm" && state.Role == ComputerRole.BackupServer && !firewallScriptChecked)
                                {
                                    trust.VerifyCopy("install/Set-NetCrateFirewall.ps1", Path.Combine(root, "App", "install", "Set-NetCrateFirewall.ps1"));
                                    firewallScriptChecked = true;
                                }
                                current = pipe; child = process;
                            }
                            if (created)
                            {
                                var connected = current.WaitForConnectionAsync(deadline.Token);
                                var startup = Stopwatch.StartNew();
                                while (!connected.IsCompleted)
                                {
                                    deadline.Token.ThrowIfCancellationRequested();
                                    if (child.HasExited || startup.Elapsed.TotalSeconds > 15) throw new IOException();
                                    Thread.Sleep(40);
                                }
                                connected.GetAwaiter().GetResult();
                                if (!NetworkSetupJob.OwnsPipe(current, child)) throw new IOException();
                            }
                            var choices = new { Role = state.Role.ToString(), state.InstallationId, state.Folder, state.BackupMode, state.NetworkAddress };
                            string lease = action == "Start" && state.Role == ComputerRole.BackupServer && request.ApproveFirewall
                                ? Guid.NewGuid().ToString("N") : null;
                            WriteMessage(current, json.Serialize(new { Action = action, State = choices, Request = request, Code = code, Lease = lease }));
                            string response = ReadMessage(current);
                            var record = json.Deserialize<Dictionary<string,object>>(response);
                            if (record.ContainsKey("Kind"))
                            {
                                if (record.Count != 2 || Convert.ToString(record["Kind"]) != "OpenLease" || lease == null ||
                                    Convert.ToString(record["Lease"]) != lease) throw new InvalidDataException();
                                deadline.Token.ThrowIfCancellationRequested();
                                using (var elevated = LaunchGuardian(guardian, state.InstallationId, request, lease, child))
                                    WriteMessage(current, json.Serialize(new { Kind = "Guardian", Lease = lease, ProcessId = elevated.Id }));
                                response = ReadMessage(current);
                            }
                            var result = json.Deserialize<NetworkSetupStatus>(response);
                            if (result == null || !Enum.IsDefined(typeof(NetworkSetupPhase), result.Phase) ||
                                result.Message == null || result.Message.Length > 300 || result.Peers == null || result.Peers.Length > 128 ||
                                (!String.IsNullOrEmpty(result.ComparisonCode) && !Regex.IsMatch(result.ComparisonCode, "^[0-9A-F]{4}( [0-9A-F]{4}){3}$")))
                                throw new InvalidDataException();
                            lock (sync) { if (operation != generation) throw new OperationCanceledException(); }
                            return result;
                        }, deadline.Token).ConfigureAwait(false);
                    }
                }
            }
            catch (Exception ex)
            {
                lock (sync)
                {
                    if (operation != generation) throw new OperationCanceledException();
                    CloseTransport();
                }
                token.ThrowIfCancellationRequested();
                if (ex is OutOfMemoryException) throw;
                return Failed("The private setup helper stopped. Check the prepared software and both private addresses, then start again.");
            }
            finally { gate.Release(); }
        }
        private static string CheckedFile(string path)
        {
            path = Path.GetFullPath(path);
            if (!File.Exists(path)) throw new FileNotFoundException();
            for (string part = path; part != null; part = Path.GetDirectoryName(part))
                if ((File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0) throw new IOException();
            return path;
        }
        private static string Quote(string value)
        {
            if (value.IndexOfAny(new[] { '"', '\r', '\n' }) >= 0) throw new ArgumentException();
            return "\"" + value + "\"";
        }
        private string ReadApprovedGuardian()
        {
            string path = CheckedFile(Path.Combine(installDirectory, "NetCrate.SetupLease.ps1"));
            byte[] bytes;
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (input.Length <= 0 || input.Length > 16384) throw new InvalidDataException();
                bytes = ReadBytes(input, (int)input.Length);
            }
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                // The release checkout uses CRLF. Source archives can use LF.
                string digest = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
                if (digest != "0F126607B065B432DD7AD10A6664BF86102CD2DDC893C454496060804C7E0E98" &&
                    digest != "E24D6BA1C52219B63F036CA63A29F07967F7D06B06B1E842142D5A025C24D9F3")
                    throw new InvalidDataException();
            }
            // Only the desktop constructs the elevated command from this snapshot.
            return Convert.ToBase64String(bytes);
        }
        static IPAddress PrivateAddress(string text)
        {
            IPAddress address;
            if (!IPAddress.TryParse(text, out address) || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork ||
                address.ToString() != text) throw new InvalidDataException();
            byte[] b = address.GetAddressBytes();
            if (!(b[0] == 10 || b[0] == 172 && b[1] >= 16 && b[1] <= 31 || b[0] == 192 && b[1] == 168 ||
                b[0] == 100 && b[1] >= 64 && b[1] <= 127)) throw new InvalidDataException();
            return address;
        }
        Process LaunchGuardian(string guardian, string installationId, NetworkSetupRequest approved, string lease, Process child)
        {
            if (guardian == null || !approved.ApproveFirewall || !Regex.IsMatch(installationId, "^[a-f0-9]{32}$")) throw new InvalidDataException();
            var local = PrivateAddress(approved.LocalAddress);
            if (local.Equals(PrivateAddress(approved.PeerAddress))) throw new InvalidDataException();
            bool assigned = false;
            foreach (var adapter in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                if (adapter.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up)
                    foreach (var item in adapter.GetIPProperties().UnicastAddresses)
                        if (local.Equals(item.Address)) assigned = true;
            if (!assigned || child.HasExited) throw new InvalidDataException();
            var binding = new { InstallationId = installationId, Lease = lease, LocalAddress = approved.LocalAddress,
                PeerAddress = approved.PeerAddress, Program = child.MainModule.FileName, HelperPid = child.Id,
                StartTicks = child.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) };
            string data = Convert.ToBase64String(Utf8.GetBytes(json.Serialize(binding)));
            string command = "$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')\n" + Utf8.GetString(Convert.FromBase64String(guardian)) +
                "\nInvoke-NetCrateLeaseGuardian ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + data + "')) | ConvertFrom-Json)";
            string systemShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            return Process.Start(new ProcessStartInfo(systemShell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " +
                Convert.ToBase64String(Encoding.Unicode.GetBytes(command))) {
                UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden
            });
        }
        private void OpenTransport(string owner)
        {
            trust = new NetworkSetupTrust();
            var runtimeDirectory = Path.Combine(root, "Tools", "PowerShell", "7.6.5");
            trust.Verify(Directory.GetParent(installDirectory).FullName, runtimeDirectory);
            var catalogPath = CheckedFile(Path.Combine(installDirectory, "Dependencies.json"));
            var catalog = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(catalogPath));
            string version = null;
            foreach (var record in (System.Collections.IEnumerable)catalog["Packages"])
            {
                var package = (Dictionary<string, object>)record;
                if (Convert.ToString(package["Name"]) == "PowerShell") version = Convert.ToString(package["Version"]);
            }
            if (version == null || !Regex.IsMatch(version, @"^\d+\.\d+\.\d+$")) throw new InvalidDataException();
            string runtime = CheckedFile(Path.Combine(root, "Tools", "PowerShell", version, "pwsh.exe"));
            string helper = CheckedFile(Path.Combine(installDirectory, "Invoke-NetworkSetupHost.ps1"));
            string pipeName = "nc-setup-" + Guid.NewGuid().ToString("N");
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
            pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security);
            var launch = new ProcessStartInfo(runtime, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
                Quote(helper) + " -PipeName " + pipeName + " -Root " + Quote(root))
                { UseShellExecute = false, CreateNoWindow = true };
            launch.WorkingDirectory = runtimeDirectory;
            foreach (string key in new List<string>(System.Linq.Enumerable.Cast<string>(launch.EnvironmentVariables.Keys)))
            {
                if (Regex.IsMatch(key, "^(DOTNET_|COMPlus_|CORECLR_|COR_|PSMODULEPATH$|PSExecutionPolicyPreference$)", RegexOptions.IgnoreCase))
                    launch.EnvironmentVariables.Remove(key);
            }
            launch.EnvironmentVariables["SystemRoot"] = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            launch.EnvironmentVariables["WINDIR"] = launch.EnvironmentVariables["SystemRoot"];
            launch.EnvironmentVariables["PSModulePath"] = Path.Combine(runtimeDirectory, "Modules");
            launch.EnvironmentVariables["PATH"] = runtimeDirectory + ";" + Environment.SystemDirectory;
            // Hash of pwsh.exe inside the verified catalog PowerShell 7.6.5 archive.
            // Keep the binary read-locked between verification and process creation.
            using (var binary = new FileStream(runtime, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                if (version != "7.6.5" || BitConverter.ToString(sha.ComputeHash(binary)).Replace("-", "") !=
                    "362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139") throw new InvalidDataException();
                process = Process.Start(launch);
            }
            try { job = new NetworkSetupJob(process); }
            catch { if (!process.HasExited) process.Kill(); throw; }
            identity = owner;
        }
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static void WriteMessage(Stream stream, string text)
        {
            byte[] bytes = Utf8.GetBytes(text);
            if (bytes.Length > 131072) throw new InvalidDataException();
            byte[] prefix = BitConverter.GetBytes(IPAddress.HostToNetworkOrder(bytes.Length));
            stream.Write(prefix, 0, 4); stream.Write(bytes, 0, bytes.Length); stream.Flush();
        }
        private static byte[] ReadBytes(Stream stream, int length)
        {
            byte[] result = new byte[length]; int offset = 0;
            while (offset < length)
            {
                int read = stream.Read(result, offset, length - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return result;
        }
        private static string ReadMessage(Stream stream)
        {
            int length = IPAddress.NetworkToHostOrder(BitConverter.ToInt32(ReadBytes(stream, 4), 0));
            if (length <= 0 || length > 131072) throw new InvalidDataException();
            return Utf8.GetString(ReadBytes(stream, length));
        }
        private void CloseGeneration(long operation)
        {
            lock (sync) { if (operation == generation) CloseTransport(); }
        }
        private void CloseTransport()
        {
            lock (sync)
            {
                if (job != null) { job.Dispose(); job = null; }
                if (process != null) { process.Dispose(); process = null; }
                if (pipe != null) { pipe.Dispose(); pipe = null; }
                if (trust != null) { trust.Dispose(); trust = null; }
                firewallScriptChecked = false;
                identity = null;
            }
        }
        public void Dispose()
        {
            lock (sync) { ++generation; disposed = true; CloseTransport(); }
        }
    }
}
