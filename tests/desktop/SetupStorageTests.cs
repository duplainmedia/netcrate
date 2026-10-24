using System;
using System.IO;
using System.Threading;
using NetCrate.Setup;

class SetupStorageTests
{
    private static int assertions;
    private static void Assert(bool value, string message)
    {
        if (!value) throw new Exception(message);
        assertions++;
    }

    public static void Main(string[] args)
    {
        string root = Path.Combine(args[0], "NetCrateSetupTest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string statePath = Path.Combine(root, "setup", "state.json");
            JsonSetupStore store = new JsonSetupStore(statePath);
            Assert(store.Load() == null, "A fresh setup returned existing state.");
            SetupState state = new SetupState { Role = ComputerRole.EditingComputer, Folder = Path.Combine(root, "Projects 日本語") };
            store.Save(state);
            Assert(store.Load().Folder == state.Folder, "Unicode folder choice did not survive a restart.");
            state.Step = SetupStep.Prepare;
            store.Save(state);
            Assert(store.Load().Step == SetupStep.Prepare, "Atomic replacement lost the saved step.");
            Assert(Directory.GetFiles(Path.GetDirectoryName(statePath)).Length == 1, "State writes left temporary files.");
            File.WriteAllText(statePath, "{ broken");
            bool corrupt = false;
            try { store.Load(); } catch (InvalidDataException) { corrupt = true; }
            Assert(corrupt, "Corrupt state silently replaced an installation identity.");
            File.WriteAllText(statePath, "{\"Version\":9,\"InstallationId\":\"x\"}");
            bool future = false;
            try { store.Load(); } catch (InvalidDataException) { future = true; }
            Assert(future, "An unsupported setup version was loaded.");
            File.WriteAllText(statePath, "{}");
            bool incomplete = false;
            try { store.Load(); } catch (InvalidDataException) { incomplete = true; }
            Assert(incomplete, "Missing state fields silently generated a new installation identity.");

            string folder = Path.Combine(root, "Projects 日本語");
            Directory.CreateDirectory(folder);
            WindowsSetupService service = new WindowsSetupService(Path.Combine(root, "no-engine"));
            SetupResult result = service.CheckFolderAsync(ComputerRole.EditingComputer, folder, CancellationToken.None).Result;
            Assert(result.Succeeded, "A writable ordinary folder was rejected.");
            result = service.CheckFolderAsync(ComputerRole.EditingComputer, Path.GetPathRoot(folder), CancellationToken.None).Result;
            Assert(!result.Succeeded, "An entire drive was accepted as the project folder.");
            result = service.CheckFolderAsync(ComputerRole.BackupServer, Path.Combine(folder, "missing"), CancellationToken.None).Result;
            Assert(!result.Succeeded, "An unavailable storage folder was accepted.");
            result = service.CheckFolderAsync(ComputerRole.None, folder, CancellationToken.None).Result;
            Assert(!result.Succeeded, "A folder was accepted before the computer role.");
            result = service.CheckSampleAsync(state, null, CancellationToken.None).Result;
            Assert(!result.Succeeded, "An absent pipeline passed the sample check.");
            result = service.CheckConnectionAsync(state, CancellationToken.None).Result;
            Assert(!result.Succeeded, "An absent pairing engine passed connection verification.");
            result = service.SaveRecoveryAsync(state, Path.Combine(root, "recovery.txt"), CancellationToken.None).Result;
            Assert(!result.Succeeded && !File.Exists(Path.Combine(root, "recovery.txt")), "Incomplete keys produced a misleading recovery file.");
            Console.WriteLine("PASS: " + assertions + " setup storage and native folder assertions.");
        }
        finally
        {
            if (Path.GetFileName(root).StartsWith("NetCrateSetupTest-") &&
                String.Equals(Path.GetDirectoryName(root), Path.GetFullPath(args[0]).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                Directory.Delete(root, true);
        }
    }
}
