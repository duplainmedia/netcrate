using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using NetCrate.Setup;

class InspectionTests
{
    static int assertions;
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); assertions++; }
    static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--hang") { Thread.Sleep(Timeout.Infinite); return; }
        if (args.Length > 0 && args[0] == "--finish") return;
        Run().GetAwaiter().GetResult();
        Console.WriteLine("PASS: " + assertions + " native inspection timeout and cancellation assertions.");
    }

    static Process StartFixture()
    {
        ProcessStartInfo start = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--hang");
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        return Process.Start(start);
    }

    static async Task Run()
    {
        Stopwatch elapsed = Stopwatch.StartNew();
        using (Process child = StartFixture())
        {
            Task<bool> waiting = InspectionProcess.WaitAsync(child, TimeSpan.FromMilliseconds(200), CancellationToken.None);
            Task winner = await Task.WhenAny(waiting, Task.Delay(4000));
            if (winner != waiting)
            {
                if (!child.HasExited) child.Kill();
                Assert(false, "An unbounded inspection wait did not return after its deadline.");
            }
            bool finished = await waiting;
            Assert(!finished && child.HasExited, "A hung inspection did not time out and stop its process.");
        }
        Assert(elapsed.Elapsed < TimeSpan.FromSeconds(8), "Inspection timeout did not return promptly.");
        using (Process child = StartFixture())
        using (CancellationTokenSource cancel = new CancellationTokenSource(200))
        {
            bool cancelled = false;
            try { await InspectionProcess.WaitAsync(child, TimeSpan.FromSeconds(30), cancel.Token); }
            catch (OperationCanceledException) { cancelled = true; }
            Assert(cancelled && child.HasExited, "Cancelling inspection left its process running.");
        }
        using (Process child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--finish") { UseShellExecute = false, CreateNoWindow = true }))
        {
            // A separate fixture argument exits without running the tests again.
            bool finished = await InspectionProcess.WaitAsync(child, TimeSpan.FromSeconds(5), CancellationToken.None);
            Assert(finished, "A successful inspection was treated as a timeout.");
        }
    }
}
