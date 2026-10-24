using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace NetCrate
{
    public sealed class Settings
    {
        public string BackupRecords { get; set; }
        public string RunsRoot { get; set; }
        public string Outbox { get; set; }
        public string SourceState { get; set; }
        public string ReceiverState { get; set; }
        public string ProgressState { get; set; }
        public string ActiveRoot { get; set; }
        public string OutputRoot { get; set; }
        public string SnapshotRoot { get; set; }
        public string SourceComputer { get; set; }
        public string WorkerComputer { get; set; }

        public static string DefaultPath
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NetCrate", "settings.json"); }
        }

        public static Settings Local() { return Load(DefaultPath); }

        public static Settings Load(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("Set up this computer in NetCrate first.", path);
            try
            {
                if (new FileInfo(path).Length > 65536 || !Setup.JsonSetupStore.SafePath(path)) throw new InvalidDataException();
                Dictionary<string, object> data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
                if (data == null || !data.ContainsKey("Version") || !(data["Version"] is int) || (int)data["Version"] != 1)
                    throw new InvalidDataException();
                string role = Required(data, "Role");
                if (role != "Source" && role != "Worker") throw new InvalidDataException();
                string active = NormalizeRoot(Required(data, "ActiveRoot"));
                string state = NormalizeRoot(Required(data, "StateRoot"));
                string source = Host(Required(data, "SourceComputer"));
                string worker = Host(Required(data, "WorkerComputer"));
                if (source.Equals(worker, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
                Settings settings = FromRoots(active, state);
                settings.SourceComputer = source;
                settings.WorkerComputer = worker;
                return settings;
            }
            catch (InvalidDataException) { throw; }
            catch (Exception error)
            {
                if (error is IOException || error is UnauthorizedAccessException) throw;
                throw new InvalidDataException("NetCrate settings could not be read. Open setup to check this computer's choices.", error);
            }
        }

        private static string Required(Dictionary<string, object> data, string key)
        {
            object value;
            if (!data.TryGetValue(key, out value) || !(value is string) || String.IsNullOrWhiteSpace((string)value))
                throw new InvalidDataException("A required NetCrate setting is missing: " + key + ".");
            return (string)value;
        }

        private static string Host(string value)
        {
            if (!Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")) throw new InvalidDataException("A computer name is invalid.");
            return value;
        }

        private static string NormalizeRoot(string value)
        {
            if (!Regex.IsMatch(value, @"^[A-Za-z]:\\") || Regex.IsMatch(value, @"(^|[\\/])\.{1,2}([\\/]|$)") ||
                value.Substring(3).IndexOfAny(new[] { ':', '*', '?', '"', '<', '>', '|', '\r', '\n' }) >= 0)
                throw new InvalidDataException("Choose an ordinary local folder for NetCrate.");
            string full = Path.GetFullPath(value).TrimEnd('\\');
            if (full.Length < 4) throw new InvalidDataException("Choose a folder inside the drive.");
            return full;
        }

        internal static Settings FromRoots(string active, string state)
        {
            return new Settings
            {
                ActiveRoot = active,
                OutputRoot = active,
                SnapshotRoot = "/" + Char.ToUpperInvariant(active[0]) + active.Substring(2).Replace('\\', '/'),
                BackupRecords = Path.Combine(state, "BackupRecords"),
                RunsRoot = Path.Combine(state, "Runs"),
                Outbox = Path.Combine(state, "Outbox"),
                SourceState = Path.Combine(state, "SourceState"),
                ReceiverState = Path.Combine(state, "ReceiverState"),
                ProgressState = Path.Combine(state, "ProgressState")
            };
        }

        internal static Settings Preview(string root)
        {
            Settings settings = FromRoots(Path.Combine(root, "Projects"), Path.Combine(root, "State"));
            settings.SourceComputer = "EDIT-PC";
            settings.WorkerComputer = "BACKUP-PC";
            return settings;
        }
    }
}
