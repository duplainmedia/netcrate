using System;
using System.Collections.Generic;

namespace NetCrate.Setup
{
    public enum ComputerRole { None, EditingComputer, BackupServer }
    public enum SetupStep { Computer, Folders, Prepare, Connect, Check, Complete }

    public sealed class SetupState
    {
        public int Version { get; set; }
        public string InstallationId { get; set; }
        public ComputerRole Role { get; set; }
        public SetupStep Step { get; set; }
        public string Folder { get; set; }
        public string BackupMode { get; set; }
        public string NetworkAddress { get; set; }
        public bool Prepared { get; set; }
        public bool RecoveryExported { get; set; }
        public bool RecoveryConfirmed { get; set; }
        public bool Connected { get; set; }
        public bool SampleVerified { get; set; }

        public SetupState()
        {
            Version = 1;
            BackupMode = "Folder";
            InstallationId = Guid.NewGuid().ToString("N");
        }

        public SetupState Copy() { return (SetupState)MemberwiseClone(); }

        public void InvalidateChecks()
        {
            Prepared = false;
            Connected = false;
            SampleVerified = false;
        }
    }

    public sealed class SetupResult
    {
        public bool Succeeded { get; private set; }
        public string Code { get; private set; }
        public string Message { get; private set; }
        public string PairingCode { get; set; }
        public string PairingStage { get; set; }
        public IList<SoftwareCheck> Software { get; set; }        public IList<BackupItem> Items { get; set; }
        public string NextCursor { get; set; }
        public string RestoredPath { get; set; }
        public IList<ScheduleItem> Schedules { get; set; }

        private SetupResult(bool succeeded, string code, string message)
        {
            Succeeded = succeeded;
            Code = code;
            Message = message;
            Software = new List<SoftwareCheck>(); Items = new List<BackupItem>(); Schedules = new List<ScheduleItem>();
        }

        public static SetupResult Done(string message) { return new SetupResult(true, "ok", message); }
        public static SetupResult ActionRequired(string code, string message) { return new SetupResult(false, code, message); }
    }

    public sealed class BackupItem {
        public string Name { get; set; }
        public string Type { get; set; }
        public string SnapshotId { get; set; }
        public string RelativePath { get; set; }
        public string Project { get; set; }
        public string SourceComputer { get; set; }
        public string BackupCompletedUtc { get; set; }
        public string Completion { get; set; }
        public long Size { get; set; }
        public override string ToString() { return Name; }
    }
    // Ephemeral action context. Never persisted with setup state; contains paths only.
    public sealed class RestoreRequest {
        public string InstallationId { get; set; }
        public string RecoveryFile { get; set; }
        public string RepositoryPath { get; set; }
        public string SnapshotId { get; set; }
        public string RelativePath { get; set; }
        public string DestinationParent { get; set; }
        public string Cursor { get; set; }
        public RestoreRequest Copy() { return (RestoreRequest)MemberwiseClone(); }
    }
    public interface IRestoreService {
        System.Threading.Tasks.Task<SetupResult> InvokeRestoreAsync(string action, RestoreRequest request, System.Threading.CancellationToken token);
    }
    public sealed class ScheduleItem {
        public string Id { get; set; }
        public string Project { get; set; }
        public string TimeOfDay { get; set; }
        public bool Enabled { get; set; }
        public int Revision { get; set; }
        public string NextDueUtc { get; set; }
        public string TimeZone { get; set; }
        public string Status { get; set; }
        public string NextRun { get { DateTimeOffset date; return !Enabled?"Disabled":DateTimeOffset.TryParse(NextDueUtc,out date)?date.ToLocalTime().ToString("yyyy-MM-dd HH:mm zzz")+" ("+TimeZone+")":"Next run unavailable"; } }
        public override string ToString(){return Project+" · "+TimeOfDay+" · "+NextRun+(String.IsNullOrEmpty(Status)?"":" · "+Status);}
    }
    public sealed class ScheduleRequest {
        public string Project { get; set; }
        public string TimeOfDay { get; set; }
        public bool Enabled { get; set; }
    }
    public interface IScheduleService {
        System.Threading.Tasks.Task<SetupResult> InvokeScheduleAsync(string action, ScheduleRequest request, System.Threading.CancellationToken token);
    }
    public sealed class SoftwareCheck
    {
        public string Name { get; set; }
        public string Purpose { get; set; }
        public string Version { get; set; }
        public bool Available { get; set; }
    }

    public interface ISetupStore
    {
        SetupState Load();
        void Save(SetupState state);
    }
}
