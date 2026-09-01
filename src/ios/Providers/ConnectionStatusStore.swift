import Combine

/// Connection state of the remote-agent (Bridge) provider, aggregated for
/// the sidebar title's connection dot. Sources: configured remoteAgent
/// instances (ProviderConfigStore) + live client states (RemoteAgentStore).
/// A single connected client means "connected"; any connecting client wins
/// over idle/failed so the spinner shows during transient reconnects.
/// CCPocketClient pushes every state flip here; the sidebar also calls
/// recompute() when the instance list changes.
@MainActor
final class ConnectionStatusStore: ObservableObject {
    static let shared = ConnectionStatusStore()

    enum Status: Equatable {
        case notConfigured
        case connecting
        case connected
        case disconnected
    }

    @Published private(set) var status: Status = .notConfigured

    private init() {}

    /// Recompute from configured instances + live client states.
    func recompute() {
        let hasInstance = ProviderConfigStore.shared.instances.contains {
            $0.providerType == .remoteAgent && $0.isEnabled
        }
        guard hasInstance else {
            status = .notConfigured
            return
        }
        let states = RemoteAgentStore.shared.liveStates()
        if states.contains(.connecting) {
            status = .connecting
        } else if states.contains(.connected) {
            status = .connected
        } else {
            status = .disconnected
        }
    }
}
