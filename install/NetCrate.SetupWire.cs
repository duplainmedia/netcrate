using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace NetCrate
{
    public sealed class SetupChannel : IDisposable
    {
        private readonly TcpClient client;
        public SslStream Stream { get; private set; }
        public string PresentedDER { get; private set; }
        internal SetupChannel(TcpClient client, SslStream stream, string presented)
        { this.client = client; Stream = stream; PresentedDER = presented; }
        public void Dispose() { try { Stream.Dispose(); } finally { client.Dispose(); } }
    }

    public static class SetupWire
    {
        private const int MaximumBytes = 128 * 1024;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint id);
        public static int PipeClientId(System.IO.Pipes.NamedPipeServerStream pipe)
        {
            uint id;
            if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out id)) throw new IOException();
            return (int)id;
        }
        private static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken token)
        {
            char[] chunk = new char[2048];
            var text = new StringBuilder();
            int count;
            while ((count = await reader.ReadAsync(chunk.AsMemory(), token).ConfigureAwait(false)) > 0)
            {
                if (text.Length + count > MaximumBytes) throw new InvalidDataException();
                text.Append(chunk, 0, count);
            }
            return text.ToString();
        }
        public static string ReadCli(System.Diagnostics.Process process)
        {
            using (var timeout = new CancellationTokenSource(5000))
            {
                var output = ReadBoundedAsync(process.StandardOutput, timeout.Token);
                var diagnostic = ReadBoundedAsync(process.StandardError, timeout.Token);
                Task.WhenAll(output, diagnostic, process.WaitForExitAsync(timeout.Token)).WaitAsync(timeout.Token).GetAwaiter().GetResult();
                if (process.ExitCode != 0) throw new IOException();
                return output.GetAwaiter().GetResult();
            }
        }
        public static void Validate(string text)
        {
            if (Utf8.GetByteCount(text) > MaximumBytes) throw new InvalidDataException();
            using (var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 32 }))
            {
                if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
                CheckMembers(document.RootElement);
            }
        }
        private static void CheckMembers(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Array)
                foreach (var item in element.EnumerateArray()) CheckMembers(item);
            if (element.ValueKind != JsonValueKind.Object) return;
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject())
            {
                if (!seen.Add(property.Name)) throw new InvalidDataException();
                CheckMembers(property.Value);
            }
        }
        public static string Read(Stream stream, int milliseconds)
        {
            using (var timeout = new CancellationTokenSource(milliseconds))
            {
                byte[] prefix = new byte[4];
                stream.ReadExactlyAsync(prefix.AsMemory(), timeout.Token).AsTask().GetAwaiter().GetResult();
                int length = IPAddress.NetworkToHostOrder(BitConverter.ToInt32(prefix, 0));
                if (length <= 0 || length > MaximumBytes) throw new InvalidDataException();
                byte[] message = new byte[length];
                stream.ReadExactlyAsync(message.AsMemory(), timeout.Token).AsTask().GetAwaiter().GetResult();
                string text = Utf8.GetString(message);
                Validate(text);
                return text;
            }
        }
        public static async Task<string> ReadOwnerCommandAsync(Stream stream)
        {
            byte[] prefix = new byte[4];
            if (await stream.ReadAsync(prefix.AsMemory(0, 1)).ConfigureAwait(false) == 0) throw new EndOfStreamException();
            using (var timeout = new CancellationTokenSource(15000))
            {
                await stream.ReadExactlyAsync(prefix.AsMemory(1), timeout.Token).ConfigureAwait(false);
                int length = IPAddress.NetworkToHostOrder(BitConverter.ToInt32(prefix, 0));
                if (length <= 0 || length > MaximumBytes) throw new InvalidDataException();
                byte[] content = new byte[length];
                await stream.ReadExactlyAsync(content.AsMemory(), timeout.Token).ConfigureAwait(false);
                string text = Utf8.GetString(content);
                Validate(text);
                return text;
            }
        }
        public static void Write(Stream stream, string text, int milliseconds)
        {
            Validate(text);
            byte[] bytes = Utf8.GetBytes(text);
            byte[] prefix = BitConverter.GetBytes(IPAddress.HostToNetworkOrder(bytes.Length));
            using (var timeout = new CancellationTokenSource(milliseconds))
            {
                stream.WriteAsync(prefix.AsMemory(), timeout.Token).AsTask().GetAwaiter().GetResult();
                stream.WriteAsync(bytes.AsMemory(), timeout.Token).AsTask().GetAwaiter().GetResult();
            }
        }
        public static async Task<SetupChannel> AcceptAsync(TcpListener listener, string peer, X509Certificate2 certificate)
        {
            TcpClient client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            try
            {
                if (!((IPEndPoint)client.Client.RemoteEndPoint).Address.Equals(IPAddress.Parse(peer)))
                    throw new InvalidDataException();
                var stream = new SslStream(client.GetStream(), false);
                using (var timeout = new CancellationTokenSource(5000))
                    await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
                        ServerCertificate = certificate, EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13
                    }, timeout.Token).ConfigureAwait(false);
                return new SetupChannel(client, stream, null);
            }
            catch { client.Dispose(); throw; }
        }
        public static SetupChannel Connect(string local, string peer, int port)
        {
            var client = new TcpClient(new IPEndPoint(IPAddress.Parse(local), 0));
            try
            {
                using (var timeout = new CancellationTokenSource(5000))
                    client.ConnectAsync(IPAddress.Parse(peer), port, timeout.Token).AsTask().GetAwaiter().GetResult();
                string pending = null;
                // Provisional trust applies to this stream only. The owner authenticates
                // the observed DER using the decrypted signed reply before activation.
                var stream = new SslStream(client.GetStream(), false, (sender, certificate, chain, errors) => {
                    if (certificate == null) return false;
                    pending = Convert.ToBase64String(certificate.GetRawCertData());
                    return true;
                });
                using (var timeout = new CancellationTokenSource(5000))
                    stream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {
                        TargetHost = peer, EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13
                    }, timeout.Token).GetAwaiter().GetResult();
                if (pending == null) throw new AuthenticationException();
                return new SetupChannel(client, stream, pending);
            }
            catch { client.Dispose(); throw; }
        }
    }
}
