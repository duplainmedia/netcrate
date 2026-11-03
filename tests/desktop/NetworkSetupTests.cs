using System;
using System.Threading;
using NetCrate.Setup;

class NetworkSetupTests
{
    static int Main(string[] args)
    {
        try { return Run(args); } catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
    }
    static int Run(string[] args)
    {
        var state = new SetupState { Role = ComputerRole.BackupServer, Prepared = true, Folder = args[1] };
        if (args.Length > 2)
        {
            state.InstallationId = new string('1',32);
            state.Folder = args[2]; state.BackupMode = "Folder";
            using (var active = new WindowsNetworkPairingService(args[0], args[1]))
            {
                var status = active.InspectAsync(state, CancellationToken.None).GetAwaiter().GetResult();
                if (status.Phase != NetworkSetupPhase.Idle || !String.IsNullOrEmpty(status.ComparisonCode))
                    throw new Exception("Owned helper inspection failed: " + status.Message);
                string runtime = System.IO.Directory.GetParent(args[1]).FullName + @"\Engine\Tools\PowerShell\7.6.5\pwsh.exe";
                System.Diagnostics.Process child = null;
                foreach (var candidate in System.Diagnostics.Process.GetProcessesByName("pwsh"))
                {
                    try { if (String.Equals(candidate.MainModule.FileName, runtime, StringComparison.OrdinalIgnoreCase)) { child = candidate; break; } }
                    catch (System.ComponentModel.Win32Exception) { }
                    candidate.Dispose();
                }
                if (child == null) throw new Exception("Desktop did not own a helper.");
                bool locked = false;
                try { System.IO.File.AppendAllText(System.IO.Path.Combine(args[0], "NetCrate.NetworkSetup.psm1"), "# tamper"); }
                catch (System.IO.IOException) { locked = true; }
                if (!locked) throw new Exception("The running helper module was writable.");
                using (child)
                {
                    active.StopAsync(CancellationToken.None).GetAwaiter().GetResult();
                    if (!child.WaitForExit(5000)) throw new Exception("Owned helper survived cancellation.");
                }
                var reset = active.ResetPendingAsync(state, CancellationToken.None).GetAwaiter().GetResult();
                if (reset.Phase != NetworkSetupPhase.Idle ||
                    System.IO.File.Exists(System.IO.Path.Combine(System.IO.Directory.GetParent(args[1]).FullName, "Engine", "Secrets", "inbound-request.json")))
                    throw new Exception("Manual reset did not retire the pending request without a listener.");
                active.StopAsync(CancellationToken.None).GetAwaiter().GetResult();
                var gate = (SemaphoreSlim)typeof(WindowsNetworkPairingService).GetField("gate",
                    System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(active);
                gate.Wait();
                var queued = active.InspectAsync(state, CancellationToken.None);
                active.StopAsync(CancellationToken.None).GetAwaiter().GetResult();
                gate.Release();
                try { queued.GetAwaiter().GetResult(); } catch (OperationCanceledException) { }
                foreach (var candidate in System.Diagnostics.Process.GetProcessesByName("pwsh"))
                    using (candidate)
                    {
                        try { if (String.Equals(candidate.MainModule.FileName, runtime, StringComparison.OrdinalIgnoreCase)) throw new Exception("A queued operation opened a helper after Stop."); }
                        catch (System.ComponentModel.Win32Exception) { }
                    }
                foreach (var name in new[] { "Invoke-NetworkSetupHost.ps1", "NetCrate.NetworkSetup.psm1", "NetCrate.Engine.psm1" })
                {
                    string target = System.IO.Path.Combine(args[0], name);
                    byte[] originalModule = System.IO.File.ReadAllBytes(target);
                    System.IO.File.AppendAllText(target, "\r\n# tampered module\r\n");
                    if (active.InspectAsync(state, CancellationToken.None).GetAwaiter().GetResult().Phase != NetworkSetupPhase.Failed)
                        throw new Exception("Modified helper code was admitted: " + name);
                    System.IO.File.WriteAllBytes(target, originalModule);
                }
                var guardian = System.IO.Path.Combine(args[0], "NetCrate.SetupLease.ps1");
                var original = System.IO.File.ReadAllBytes(guardian);
                System.IO.File.AppendAllText(guardian, "\r\n# changed guardian\r\n");
                if (active.InspectAsync(state, CancellationToken.None).GetAwaiter().GetResult().Phase != NetworkSetupPhase.Failed)
                    throw new Exception("The launcher accepted modified guardian bytes.");
                System.IO.File.WriteAllBytes(guardian, original);
                var library = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(runtime), "Modules", "Microsoft.PowerShell.Management", "Microsoft.PowerShell.Management.psd1");
                byte[] originalLibrary = System.IO.File.ReadAllBytes(library);
                System.IO.File.AppendAllText(library, "\r\n# changed runtime module\r\n");
                if (active.InspectAsync(state, CancellationToken.None).GetAwaiter().GetResult().Phase != NetworkSetupPhase.Failed)
                    throw new Exception("A modified PowerShell module was admitted.");
                System.IO.File.WriteAllBytes(library, originalLibrary);
                using (var changed = new System.IO.FileStream(runtime, System.IO.FileMode.Append)) changed.WriteByte(0);
                var rejected = active.InspectAsync(state, CancellationToken.None).GetAwaiter().GetResult();
                if (rejected.Phase != NetworkSetupPhase.Failed) throw new Exception("A changed helper interpreter was executed.");
                Console.WriteLine("PASS actual owner-only helper pipe, generated backend inspection, process job cancellation.");
            }
            return 0;
        }
        using (var service = new WindowsNetworkPairingService(args[0], args[1]))
        {
            var denied = service.StartAsync(state, new NetworkSetupRequest {
                LocalAddress = "100.64.0.1", PeerAddress = "100.64.0.2"
            }, CancellationToken.None).GetAwaiter().GetResult();
            if (denied.Phase != NetworkSetupPhase.Failed || !String.IsNullOrEmpty(denied.ComparisonCode)) return 1;
            var missing = service.InspectAsync(state, CancellationToken.None).GetAwaiter().GetResult();
            if (missing.Phase != NetworkSetupPhase.Failed || missing.Message.Contains(args[1])) return 2;
            var stopped = service.StopAsync(CancellationToken.None).GetAwaiter().GetResult();
            if (stopped.Phase != NetworkSetupPhase.Idle) return 3;
            Console.WriteLine("PASS desktop approval gate, missing runtime inspection, stop and nonsecret results.");
        }
        return 0;
    }
}
