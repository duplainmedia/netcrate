using System;
using System.Threading;
using System.Threading.Tasks;

namespace NetCrate.Setup
{
    public enum NetworkSetupPhase { Idle, WaitingForPeer, CompareDevice, CompareConnection, WaitingForAcknowledgment, Connected, Failed, ReceptionRequired }
    public sealed class NetworkSetupPeer
    {
        public string Name { get; set; }
        public string Address { get; set; }
        public override string ToString() { return Name + " (" + Address + ")"; }
    }
    public sealed class NetworkSetupStatus
    {
        public NetworkSetupPhase Phase { get; set; }
        public string LocalAddress { get; set; }
        public string PeerAddress { get; set; }
        public string ComparisonCode { get; set; }
        public string Message { get; set; }
        public NetworkSetupPeer[] Peers { get; set; }
        public NetworkSetupStatus() { Peers = new NetworkSetupPeer[0]; }
    }
    public sealed class NetworkSetupRequest
    {
        public string LocalAddress { get; set; }
        public string PeerAddress { get; set; }
        public bool ApproveFirewall { get; set; }
        public bool StartAgain { get; set; }
    }
    public interface INetworkPairingService : IDisposable
    {
        Task<NetworkSetupStatus> InspectAsync(SetupState state, CancellationToken token);
        Task<NetworkSetupStatus> StartAsync(SetupState state, NetworkSetupRequest request, CancellationToken token);
        Task<NetworkSetupStatus> PollAsync(SetupState state, CancellationToken token);
        Task<NetworkSetupStatus> ConfirmAsync(SetupState state, string code, CancellationToken token);
        Task<NetworkSetupStatus> ResetPendingAsync(SetupState state, CancellationToken token);
        Task<NetworkSetupStatus> StopAsync(CancellationToken token);
    }
}
