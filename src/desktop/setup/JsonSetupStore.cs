using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace NetCrate.Setup
{
    public sealed class JsonSetupStore : ISetupStore
    {
        private readonly string path;
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 32768 };

        public JsonSetupStore(string path) { this.path = Path.GetFullPath(path); }

        public SetupState Load()
        {
            if (!File.Exists(path)) return null;
            try
            {
                if (new FileInfo(path).Length > 32768 || !SafePath(path)) throw new InvalidDataException();
                string text = File.ReadAllText(path);
                Dictionary<string, object> fields = json.DeserializeObject(text) as Dictionary<string, object>;
                if (fields == null || !fields.ContainsKey("Version") || !fields.ContainsKey("InstallationId") ||
                    !fields.ContainsKey("Role") || !fields.ContainsKey("Step")) throw new InvalidDataException();
                SetupState state = json.Deserialize<SetupState>(text);
                if (state == null || state.Version != 1 || !Regex.IsMatch(state.InstallationId ?? "", "^[a-f0-9]{32}$") ||
                    !Enum.IsDefined(typeof(ComputerRole), state.Role) || !Enum.IsDefined(typeof(SetupStep), state.Step))
                    throw new InvalidDataException();
                return state;
            }
            catch (Exception error)
            {
                if (error is UnauthorizedAccessException || error is IOException) throw;
                throw new InvalidDataException("Saved setup choices could not be read. Keep the file and check NetCrate's setup folder.", error);
            }
        }

        public void Save(SetupState state)
        {
            if (!SafePath(path)) throw new IOException("The setup folder contains a link. Choose an ordinary local folder.");
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".writing";
            try
            {
                File.WriteAllText(temporary, json.Serialize(state));
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        internal static bool SafePath(string path)
        {
            for (string part = Path.GetFullPath(path); !String.IsNullOrEmpty(part); part = Path.GetDirectoryName(part.TrimEnd('\\')))
            {
                if ((File.Exists(part) || Directory.Exists(part)) && (File.GetAttributes(part) & FileAttributes.ReparsePoint) != 0)
                    return false;
            }
            return true;
        }
    }
}
