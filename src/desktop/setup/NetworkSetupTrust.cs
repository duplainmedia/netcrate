using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace NetCrate.Setup
{
    // Hold verified files until the desktop terminates its helper. Directory
    // handles also prevent their ancestors being renamed underneath those locks.
    internal sealed class NetworkSetupTrust : IDisposable
    {
        readonly List<IDisposable> handles = new List<IDisposable>();
        readonly HashSet<string> directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string,string> expected = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr sa,
            uint disposition, uint flags, IntPtr template);

        internal void Verify(string appRoot, string runtimeRoot)
        {
            var resource = typeof(NetworkSetupTrust).Assembly.GetManifestResourceStream("NetCrate.NetworkSetupTrust");
            if (resource == null) throw new InvalidDataException("Missing compiled setup manifest.");
            using (var reader = new StreamReader(resource, Encoding.UTF8))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (line.Length < 66 || line[64] != ' ') throw new InvalidDataException();
                    var relative = line.Substring(65);
                    expected.Add(relative, line.Substring(0,64));
                    VerifyCopy(relative, Path.Combine(appRoot, relative));
                }
            }
            if (!expected.ContainsKey("install/Invoke-NetworkSetupHost.ps1") ||
                !expected.ContainsKey("install/NetCrate.NetworkSetup.psm1")) throw new InvalidDataException();
            var files = new List<string>();
            VerifyRuntime(runtimeRoot, runtimeRoot, files);
            files.Sort(StringComparer.Ordinal);
            // Digest of sorted path/TAB/SHA256/LF rows for every file in the
            // catalog-verified upstream PowerShell 7.6.5 Windows x64 archive.
            using (var sha = SHA256.Create())
            {
                var digest = Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(String.Join("\n", files) + "\n")));
                if (files.Count != 658 || digest != "7D926216183FBF610ABBC5EB7F6297079C8C39A6D34EF9CE1B48505AC3C5C8EB")
                    throw new InvalidDataException("The installed PowerShell release changed.");
            }
        }

        internal void VerifyCopy(string relative, string path)
        {
            if (HashAndHold(path) != expected[relative]) throw new InvalidDataException("Setup code changed.");
        }
        void VerifyRuntime(string root, string directory, List<string> rows)
        {
            HoldDirectory(directory);
            foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
            {
                var attributes = File.GetAttributes(entry);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
                if ((attributes & FileAttributes.Directory) != 0) { VerifyRuntime(root, entry, rows); continue; }
                string name = entry.Substring(root.Length + 1).Replace('\\','/');
                if (name == ".netcrate-package.json") continue;
                if (rows.Count >= 658) throw new InvalidDataException();
                rows.Add(name + "\t" + HashAndHold(entry).ToLowerInvariant());
            }
        }
        string HashAndHold(string path)
        {
            HoldDirectory(Path.GetDirectoryName(path));
            var handle = CreateFile(path, 0x80000000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Could not secure setup code."); }
            handles.Add(handle);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
            var input = new FileStream(handle, FileAccess.Read);
            handles.Add(input);
            using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(input));
        }
        void HoldDirectory(string path)
        {
            path = Path.GetFullPath(path);
            if (directories.Contains(path)) return;
            string parent = Path.GetDirectoryName(path);
            if (parent != null) HoldDirectory(parent);
            var handle = CreateFile(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Could not secure setup directory."); }
            handles.Add(handle);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
            directories.Add(path);
        }
        static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", ""); }
        public void Dispose()
        {
            for (int i = handles.Count - 1; i >= 0; --i) handles[i].Dispose();
            handles.Clear(); directories.Clear(); expected.Clear();
        }
    }
}
