using System;
using System.IO;
using NetCrate;

class SettingsTests
{
    private static int assertions;
    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); assertions++; }
    private static void Reject(Action action, string message)
    {
        bool rejected = false;
        try { action(); } catch (InvalidDataException) { rejected = true; }
        Assert(rejected, message);
    }
    static void Main(string[] args)
    {
        string path = Path.Combine(args[0], "settings-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            bool missing = false;
            try { Settings.Load(path); } catch (FileNotFoundException) { missing = true; }
            Assert(missing, "A missing configuration silently loaded deployment defaults.");
            File.WriteAllText(path, "{\"Version\":1,\"Role\":\"Source\",\"ActiveRoot\":\"F:\\\\Video Projects 日本語\",\"StateRoot\":\"C:\\\\NetCrate State\",\"SourceComputer\":\"EDIT-PC\",\"WorkerComputer\":\"BACKUP-PC\"}");
            Settings settings = Settings.Load(path);
            Assert(settings.BackupMode == "Media", "Legacy desktop settings lost media behavior.");
            Assert(settings.ActiveRoot == @"F:\Video Projects 日本語", "The project root changed.");
            Assert(settings.SnapshotRoot == "/F/Video Projects 日本語", "The snapshot path was bound to a specific drive.");
            Assert(settings.Outbox == @"C:\NetCrate State\Outbox", "State paths were not derived from configuration.");
            Assert(settings.SourceComputer == "EDIT-PC" && settings.WorkerComputer == "BACKUP-PC", "Host identities were replaced with deployment values.");
            string valid = File.ReadAllText(path);
            File.WriteAllText(path,valid.Replace("\"Version\":1", "\"Version\":1,\"BackupMode\":\"Folder\""));
            Assert(Settings.Load(path).BackupMode=="Folder","Explicit Folder mode was not loaded.");
            File.WriteAllText(path,valid.Replace("\"Version\":1", "\"Version\":1,\"BackupMode\":\"Other\""));
            Reject(()=>Settings.Load(path),"An unknown backup mode was accepted.");
            File.WriteAllText(path, valid.Replace("\"Source\"", "\"Other\""));
            Reject(() => Settings.Load(path), "An unknown computer role was accepted.");
            File.WriteAllText(path, valid.Replace("F:\\\\Video Projects 日本語", "F:\\\\Video Projects\\\\..\\\\escape"));
            Reject(() => Settings.Load(path), "A traversing project root was accepted.");
            File.WriteAllText(path, "{}");
            Reject(() => Settings.Load(path), "A missing configuration field was accepted.");
            Console.WriteLine("PASS: " + assertions + " desktop settings assertions.");
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }
}
