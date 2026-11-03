using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace NetCrate.Setup
{
    internal static class InspectionProcess
    {
        internal static TimeSpan BrowseBudget { get { return TimeSpan.FromMinutes(30); } }
        internal static TimeSpan TimeoutFor(string action) {
            if (action == "ListBackups" || action == "ListBackupChildren") return BrowseBudget + TimeSpan.FromSeconds(10);
            return TimeSpan.FromSeconds(action == "CheckSample" ? 1250 : 90);
        }
        internal static async Task<bool> WaitAsync(Process process, TimeSpan timeout, CancellationToken token)
        {
            Stopwatch elapsed = Stopwatch.StartNew();
            try
            {
                while (!process.HasExited)
                {
                    token.ThrowIfCancellationRequested();
                    if (elapsed.Elapsed >= timeout)
                    {
                        StopProbeTree(process);
                        return false;
                    }
                    await Task.Delay(50, token);
                }
                return true;
            }
            catch (OperationCanceledException)
            {
                StopProbeTree(process);
                throw;
            }
        }

        private static void StopProbeTree(Process process)
        {
            if (process.HasExited) return;
            // Only read-only inspection processes use this path. Package installers
            // keep their separate completion policy to prevent overlapping installs.
            try
            {
                string taskkill = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "taskkill.exe");
                ProcessStartInfo start = new ProcessStartInfo(taskkill, "/PID " + process.Id + " /T /F")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (Process stop = Process.Start(start))
                {
                    if (!stop.WaitForExit(2000)) stop.Kill();
                }
            }
            catch (System.ComponentModel.Win32Exception) { }
            catch (InvalidOperationException) { }
            if (!process.HasExited) process.Kill();
            process.WaitForExit(2000);
        }
    }
}
