using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NetCrate.Setup
{
    // The helper blocks waiting for the desktop's first pipe command until the
    // job is assigned. Closing the desktop's only job handle terminates it.
    internal sealed class NetworkSetupJob : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)] struct Limits {
            public long ProcessTime, JobTime; public uint Flags;
            public UIntPtr MinSet, MaxSet; public uint ProcessLimit; public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct Extended {
            public Limits Limits;
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref Extended limits, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint id);
        readonly SafeFileHandle handle;
        internal NetworkSetupJob(Process process)
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle.IsInvalid) throw new Win32Exception();
            var limits = new Extended(); limits.Limits.Flags = 0x2000;
            if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(typeof(Extended))) ||
                !AssignProcessToJobObject(handle, process.Handle)) { handle.Dispose(); throw new Win32Exception(); }
        }
        internal static bool OwnsPipe(NamedPipeServerStream pipe, Process process)
        { uint id; return GetNamedPipeClientProcessId(pipe.SafePipeHandle, out id) && id == process.Id && !process.HasExited; }
        public void Dispose() { handle.Dispose(); }
    }
}
