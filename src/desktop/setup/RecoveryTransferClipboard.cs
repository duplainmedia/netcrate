using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Threading;

namespace NetCrate.Setup
{
    public sealed class RecoveryClipboardPayload
    {
        public string Text { get; private set; }
        public IDictionary<string, byte[]> Formats { get; private set; }
        internal RecoveryClipboardPayload(string text)
        {
            Text = text;
            // Documented serialized DWORD-zero formats, not Boolean or text values.
            Formats = new Dictionary<string, byte[]> {
                { "CanIncludeInClipboardHistory", new byte[4] }, { "CanUploadToCloudClipboard", new byte[4] }
            };
        }
        public override string ToString() { return "Sensitive clipboard payload"; }
    }
    public interface IRecoveryClipboard
    {
        uint Write(RecoveryClipboardPayload payload);
        bool ClearIfOwned(uint sequence);
    }
    public interface IRecoveryExpiryScheduler { IDisposable Schedule(TimeSpan delay, Action callback); }

    public sealed class DispatcherRecoveryExpiryScheduler : IRecoveryExpiryScheduler
    {
        public IDisposable Schedule(TimeSpan delay, Action callback) { return new Expiry(delay, callback); }
        sealed class Expiry : IDisposable
        {
            readonly DispatcherTimer timer;
            public Expiry(TimeSpan delay, Action callback)
            {
                timer = new DispatcherTimer { Interval = delay };
                timer.Tick += delegate { timer.Stop(); callback(); }; timer.Start();
            }
            public void Dispose() { timer.Stop(); }
        }
    }

    public sealed class RecoveryClipboardLifetime : IDisposable
    {
        readonly IRecoveryClipboard clipboard;
        readonly IRecoveryExpiryScheduler scheduler;
        IDisposable expiry;
        uint sequence;
        int generation;
        bool owned, disposed;
        public RecoveryClipboardLifetime(IRecoveryClipboard clipboard, IRecoveryExpiryScheduler scheduler)
        { this.clipboard = clipboard; this.scheduler = scheduler; }
        public void Copy(RecoveryDocument document)
        {
            if (disposed) throw new ObjectDisposedException("RecoveryClipboardLifetime");
            // Native Write sets exclusions before publishing text in the same locked clipboard transaction.
            uint next = clipboard.Write(new RecoveryClipboardPayload(document.Contents));
            if (expiry != null) expiry.Dispose();
            sequence = next; owned = true; int current = ++generation;
            expiry = scheduler.Schedule(TimeSpan.FromMinutes(2), delegate { Expire(current); });
        }
        void Expire(int current)
        {
            if (disposed || current != generation || !owned) return;
            try { ClearNow(); }
            catch (Win32Exception)
            {
                // A briefly locked clipboard must not leave keys indefinitely. Recheck ownership on retry.
                expiry = scheduler.Schedule(TimeSpan.FromSeconds(1), delegate { Expire(current); });
            }
        }
        public bool ClearNow()
        {
            if (!owned) return false;
            bool cleared = clipboard.ClearIfOwned(sequence);
            owned = false; ++generation;
            if (expiry != null) { expiry.Dispose(); expiry = null; }
            return cleared;
        }
        public void Dispose()
        {
            if (disposed) return;
            // A busy clipboard is a failed cleanup attempt, not completed disposal.
            // Keep ownership and the scheduled expiry eligible until clearing can be retried.
            ClearNow();
            disposed = true;
            if (expiry != null) expiry.Dispose();
        }
    }

    // The window handle must remain alive until the clipboard lifetime is disposed on window close.
    public sealed class WindowsRecoveryClipboard : IRecoveryClipboard
    {
        readonly IntPtr owner;
        public WindowsRecoveryClipboard(IntPtr windowHandle)
        {
            if (windowHandle == IntPtr.Zero) throw new ArgumentException("An owning window handle is required.");
            owner = windowHandle;
        }
        public uint Write(RecoveryClipboardPayload payload)
        {
            Open();
            try
            {
                if (!EmptyClipboard()) throw new Win32Exception();
                try
                {
                    foreach (var format in payload.Formats)
                    {
                        uint id = RegisterClipboardFormat(format.Key);
                        if (id == 0) throw new Win32Exception();
                        Publish(id, format.Value);
                    }
                    byte[] text = Encoding.Unicode.GetBytes(payload.Text + "\0");
                    try { Publish(13, text); } finally { Array.Clear(text, 0, text.Length); }
                    return GetClipboardSequenceNumber();
                }
                catch { EmptyClipboard(); throw; }
            }
            finally { CloseClipboard(); }
        }
        public bool ClearIfOwned(uint sequence)
        {
            Open();
            try
            {
                // Both checks occur while the clipboard is locked, so another writer cannot race EmptyClipboard.
                if (GetClipboardOwner() != owner || GetClipboardSequenceNumber() != sequence) return false;
                if (!EmptyClipboard()) throw new Win32Exception();
                return true;
            }
            finally { CloseClipboard(); }
        }
        void Open()
        {
            for (int attempt = 0; attempt < 5; attempt++)
            {
                if (OpenClipboard(owner)) return;
                Thread.Sleep(20);
            }
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The clipboard is busy. Try again.");
        }
        static void Publish(uint format, byte[] bytes)
        {
            IntPtr memory = GlobalAlloc(0x0002, new UIntPtr((uint)bytes.Length));
            if (memory == IntPtr.Zero) throw new Win32Exception();
            try
            {
                IntPtr pointer = GlobalLock(memory);
                if (pointer == IntPtr.Zero) throw new Win32Exception();
                try { Marshal.Copy(bytes, 0, pointer, bytes.Length); } finally { GlobalUnlock(memory); }
                if (SetClipboardData(format, memory) == IntPtr.Zero) throw new Win32Exception();
                memory = IntPtr.Zero; // Clipboard owns the allocation after successful SetClipboardData.
            }
            finally { if (memory != IntPtr.Zero) GlobalFree(memory); }
        }
        [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool CloseClipboard();
        [DllImport("user32.dll", SetLastError = true)] static extern bool EmptyClipboard();
        [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
        [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint RegisterClipboardFormat(string name);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetClipboardData(uint format, IntPtr memory);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);
    }
}
