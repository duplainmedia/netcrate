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
        public bool Prepared { get; set; }
        public bool RecoveryExported { get; set; }
        public bool RecoveryConfirmed { get; set; }
        public bool Connected { get; set; }
        public bool SampleVerified { get; set; }

        public SetupState()
        {
            Version = 1;
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
        public IList<SoftwareCheck> Software { get; set; }

        private SetupResult(bool succeeded, string code, string message)
        {
            Succeeded = succeeded;
            Code = code;
            Message = message;
            Software = new List<SoftwareCheck>();
        }

        public static SetupResult Done(string message) { return new SetupResult(true, "ok", message); }
        public static SetupResult ActionRequired(string code, string message) { return new SetupResult(false, code, message); }
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
